// Swift-friendly wrapper around ft8_lib's monitor/decode pipeline.
// The candidate scan + LDPC decode + duplicate filtering follows
// ft8_lib's demo/decode_ft8.c (MIT license).
#include "include/cft8.h"

#include <ft8/decode.h>
#include <ft8/message.h>
#include <ft8/encode.h>
#include <ft8/constants.h>
#include <common/monitor.h>
#include <js8/js8.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

enum {
    kMinScore = 10,
    kMaxCandidates = 140,
    kLDPCIterations = 25,
    kMaxDecoded = 50,
    kHashtableSize = 256,
    // JS8 digs deeper: fixture measurements (JS8Call's media/tests) show
    // finer time alignment is worth +3 decodes of 33, and the extra CPU
    // (~0.1 s per 15 s slot) is nothing. FT8/FT4 keep the proven settings.
    kJS8TimeOSR = 8,
    kJS8MinScore = 4,
    kJS8MaxCandidates = 500,
    kJS8LDPCIterations = 30,
};

typedef struct {
    char callsign[12];
    uint32_t hash; // 8 MSBs: age, 22 LSBs: hash value
} hash_entry_t;

struct cft8_decoder {
    monitor_t mon;
    hash_entry_t hashtable[kHashtableSize];
    // Raw slot audio, kept for the subtract-and-rescan passes (JS8).
    float* audio;
    int audio_len;
    int audio_cap;
};

// ft8_lib's hash interface takes plain function pointers with no context
// argument, so the table of the decoder currently decoding is stashed here.
// All cft8_* calls must come from a single thread.
static hash_entry_t* g_active_table;

static void hashtable_add(const char* callsign, uint32_t hash)
{
    hash_entry_t* table = g_active_table;
    uint16_t hash10 = (hash >> 12) & 0x3FFu;
    int idx = (hash10 * 23) % kHashtableSize;
    for (int probes = 0; probes < kHashtableSize && table[idx].callsign[0] != '\0'; ++probes)
    {
        if (((table[idx].hash & 0x3FFFFFu) == hash) && (0 == strcmp(table[idx].callsign, callsign)))
        {
            table[idx].hash &= 0x3FFFFFu; // reset age
            return;
        }
        idx = (idx + 1) % kHashtableSize;
    }
    strncpy(table[idx].callsign, callsign, 11);
    table[idx].callsign[11] = '\0';
    table[idx].hash = hash & 0x3FFFFFu;
}

static bool hashtable_lookup(ftx_callsign_hash_type_t hash_type, uint32_t hash, char* callsign)
{
    hash_entry_t* table = g_active_table;
    uint8_t shift = (hash_type == FTX_CALLSIGN_HASH_10_BITS) ? 12 : (hash_type == FTX_CALLSIGN_HASH_12_BITS ? 10 : 0);
    uint16_t hash10 = (hash >> (12 - shift)) & 0x3FFu;
    int idx = (hash10 * 23) % kHashtableSize;
    for (int probes = 0; probes < kHashtableSize && table[idx].callsign[0] != '\0'; ++probes)
    {
        if (((table[idx].hash & 0x3FFFFFu) >> shift) == hash)
        {
            strcpy(callsign, table[idx].callsign);
            return true;
        }
        idx = (idx + 1) % kHashtableSize;
    }
    callsign[0] = '\0';
    return false;
}

static void hashtable_age(hash_entry_t* table, uint8_t max_age)
{
    for (int idx = 0; idx < kHashtableSize; ++idx)
    {
        if (table[idx].callsign[0] == '\0')
            continue;
        uint8_t age = (uint8_t)(table[idx].hash >> 24);
        if (age > max_age)
        {
            table[idx].callsign[0] = '\0';
            table[idx].hash = 0;
        }
        else
        {
            table[idx].hash = (((uint32_t)age + 1u) << 24) | (table[idx].hash & 0x3FFFFFu);
        }
    }
}

static ftx_callsign_hash_interface_t hash_if = {
    .lookup_hash = hashtable_lookup,
    .save_hash = hashtable_add,
};

static ftx_protocol_t to_ftx(cft8_protocol_t protocol)
{
    switch (protocol)
    {
    case CFT8_PROTOCOL_FT4: return FTX_PROTOCOL_FT4;
    case CFT8_PROTOCOL_JS8_NORMAL: return FTX_PROTOCOL_JS8_NORMAL;
    case CFT8_PROTOCOL_JS8_FAST: return FTX_PROTOCOL_JS8_FAST;
    case CFT8_PROTOCOL_JS8_TURBO: return FTX_PROTOCOL_JS8_TURBO;
    case CFT8_PROTOCOL_JS8_SLOW: return FTX_PROTOCOL_JS8_SLOW;
    case CFT8_PROTOCOL_JS8_ULTRA: return FTX_PROTOCOL_JS8_ULTRA;
    case CFT8_PROTOCOL_FT8:
    default: return FTX_PROTOCOL_FT8;
    }
}

float cft8_symbol_period(cft8_protocol_t protocol) { return ftx_protocol_symbol_period(to_ftx(protocol)); }
float cft8_slot_seconds(cft8_protocol_t protocol) { return ftx_protocol_slot_time(to_ftx(protocol)); }
float cft8_start_delay(cft8_protocol_t protocol) { return ftx_protocol_start_delay(to_ftx(protocol)); }
float cft8_transmission_seconds(cft8_protocol_t protocol)
{
    ftx_protocol_t p = to_ftx(protocol);
    return ftx_protocol_num_tones(p) * ftx_protocol_symbol_period(p);
}

cft8_decoder_t* cft8_create(int sample_rate, cft8_protocol_t protocol)
{
    cft8_decoder_t* dec = calloc(1, sizeof(cft8_decoder_t));
    if (!dec)
        return NULL;
    ftx_protocol_t ftx = to_ftx(protocol);
    monitor_config_t cfg = {
        .f_min = 200,
        .f_max = 3000,
        .sample_rate = sample_rate,
        .time_osr = ftx_protocol_is_js8(ftx) ? kJS8TimeOSR : 2,
        .freq_osr = 2,
        .protocol = ftx,
    };
    monitor_init(&dec->mon, &cfg);
    if (ftx_protocol_is_js8(ftx))
    {
        dec->audio_cap = (int)(ftx_protocol_slot_time(ftx) * sample_rate);
        dec->audio = malloc(dec->audio_cap * sizeof(float));
    }
    return dec;
}

void cft8_feed(cft8_decoder_t* dec, const float* samples, int num_samples)
{
    if (dec->audio)
    {
        int room = dec->audio_cap - dec->audio_len;
        int take = num_samples < room ? num_samples : room;
        memcpy(dec->audio + dec->audio_len, samples, take * sizeof(float));
        dec->audio_len += take;
    }
    const int block = dec->mon.block_size;
    for (int pos = 0; pos + block <= num_samples; pos += block)
    {
        if (dec->mon.wf.num_blocks >= dec->mon.wf.max_blocks)
            break;
        monitor_process(&dec->mon, samples + pos);
    }
}

static void gfsk_pulse(int n_spsym, float symbol_bt, float* pulse);

// Coherent subtraction of one decoded JS8 signal from the slot audio
// (WSJT-X's subtractft8 scheme, adapted to a real-valued signal): build
// the reference GFSK phase, demodulate the audio against it, low-pass the
// product to recover the slowly varying complex envelope — which absorbs
// the residual frequency/phase error — then reconstruct and subtract.
static void subtract_js8(float* audio, int n_audio, const uint8_t tones[JS8_NN],
                         float f0, float dt_sec, float symbol_period, int rate)
{
    int n_spsym = (int)(0.5f + rate * symbol_period);
    int n_wave = JS8_NN * n_spsym;
    int start = (int)lroundf(dt_sec * rate);
    int refined_start = start;

    float* pulse = malloc(3 * n_spsym * sizeof(float));
    float* phi = malloc(n_wave * sizeof(float));
    float* pr = malloc(n_wave * sizeof(float));
    float* pi_ = malloc(n_wave * sizeof(float));
    if (!pulse || !phi || !pr || !pi_)
        goto done;
    gfsk_pulse(n_spsym, 2.0f /* JS8 shares FT8's BT */, pulse);

    // Reference phase, replicating synth_gfsk's pulse-shaped frequency
    float dphi_peak = 2 * M_PI / n_spsym; // hmod = 1
    float phase = 0;
    for (int k = 0; k < n_wave; ++k)
    {
        float dphi = 2 * M_PI * f0 / rate;
        int i = k / n_spsym;
        for (int m = i - 1; m <= i + 1; ++m)
        {
            if (m < 0 || m >= JS8_NN)
                continue;
            int j = k - (m - 1) * n_spsym; // index into the symbol's 3-symbol pulse span
            if (j >= 0 && j < 3 * n_spsym)
                dphi += dphi_peak * tones[m] * pulse[j];
        }
        phi[k] = phase;
        phase = fmodf(phase + dphi, 2 * M_PI);
    }

    // The candidate's estimates are coarse in two ways that ruin an
    // otherwise −30 dB subtraction: frequency is quantized to half a tone
    // spacing (±1.6 Hz), and time_sec carries the STFT analysis-window
    // bias (a couple hundred ms). Refine both against the audio itself —
    // the chunked-coherent envelope energy peaks at the true offsets.
    {
        int stride = n_spsym / 8 ? n_spsym / 8 : 1;
        double best_energy;
        // energy of the demod product for a (start, freq-delta) hypothesis
        #define REF_ENERGY(S, WD, OUT)                                         \
            do                                                                 \
            {                                                                  \
                double er = 0, ei = 0, en = 0;                                 \
                int count = 0;                                                 \
                for (int k = 0; k < n_wave; k += stride)                       \
                {                                                              \
                    int n = (S) + k;                                           \
                    float a = (n >= 0 && n < n_audio) ? audio[n] : 0.0f;       \
                    float ph = phi[k] + (WD) * k;                              \
                    er += a * cosf(ph);                                        \
                    ei += -a * sinf(ph);                                       \
                    if (++count == 64)                                         \
                    {                                                          \
                        en += er * er + ei * ei;                               \
                        er = ei = 0;                                           \
                        count = 0;                                             \
                    }                                                          \
                }                                                              \
                en += er * er + ei * ei;                                       \
                (OUT) = en;                                                    \
            } while (0)

        // Pass A: time, 20 ms steps over [−400 ms, +100 ms] around the estimate
        best_energy = -1;
        for (int ds = -(rate * 2 / 5); ds <= rate / 10; ds += rate / 50)
        {
            double e;
            REF_ENERGY(start + ds, 0.0f, e);
            if (e > best_energy)
            {
                best_energy = e;
                refined_start = start + ds;
            }
        }
        // Pass B: frequency, ±1.6 Hz in 0.2 Hz steps
        float best_delta = 0;
        best_energy = -1;
        for (float delta = -1.6f; delta <= 1.6f; delta += 0.2f)
        {
            double e;
            REF_ENERGY(refined_start, 2 * (float)M_PI * delta / rate, e);
            if (e > best_energy)
            {
                best_energy = e;
                best_delta = delta;
            }
        }
        // Pass C: time again, stepping down to near-sample resolution —
        // the subtraction residual is set by symbol-boundary misalignment
        // (2.5 ms of error already costs ~15 dB)
        float w_best = 2 * (float)M_PI * best_delta / rate;
        int spans[3] = { rate * 3 / 100, rate / 200, rate / 2000 }; // ±30 ms, ±5 ms, ±0.5 ms
        int steps[3] = { rate / 200, rate / 2000, 1 };              // 5 ms, 0.5 ms, 1 sample
        for (int level = 0; level < 3; ++level)
        {
            int coarse = refined_start;
            int step = steps[level] > 0 ? steps[level] : 1;
            best_energy = -1;
            for (int ds = -spans[level]; ds <= spans[level]; ds += step)
            {
                double e;
                REF_ENERGY(coarse + ds, w_best, e);
                if (e > best_energy)
                {
                    best_energy = e;
                    refined_start = coarse + ds;
                }
            }
        }
        #undef REF_ENERGY
        for (int k = 0; k < n_wave; ++k)
            phi[k] = fmodf(phi[k] + w_best * k, 2 * (float)M_PI);
    }
    start = refined_start;

    // Prefix sums of the demodulated product z = audio · conj(ref)
    double sr = 0, si = 0;
    for (int k = 0; k < n_wave; ++k)
    {
        int n = start + k;
        float a = (n >= 0 && n < n_audio) ? audio[n] : 0.0f;
        sr += a * cosf(phi[k]);
        si += -a * sinf(phi[k]);
        pr[k] = (float)sr;
        pi_[k] = (float)si;
    }

    // Moving-average envelope (~117 ms, WSJT-X's NFILT), reconstruct, subtract
    int w = 1400 * rate / 12000;
    if (w < 16)
        w = 16;
    for (int k = 0; k < n_wave; ++k)
    {
        int n = start + k;
        if (n < 0 || n >= n_audio)
            continue;
        int lo = k - w / 2 - 1;
        int hi = k + w / 2;
        if (hi >= n_wave)
            hi = n_wave - 1;
        float base_r = lo >= 0 ? pr[lo] : 0.0f;
        float base_i = lo >= 0 ? pi_[lo] : 0.0f;
        int count = hi - (lo >= 0 ? lo : -1);
        float cr = (pr[hi] - base_r) / count;
        float ci = (pi_[hi] - base_i) / count;
        audio[n] -= 2.0f * (cr * cosf(phi[k]) - ci * sinf(phi[k]));
    }

done:
    free(pulse);
    free(phi);
    free(pr);
    free(pi_);
}

int cft8_decode(cft8_decoder_t* dec, cft8_result_t* results, int max_results)
{
    g_active_table = dec->hashtable;
    if (max_results > kMaxDecoded)
        max_results = kMaxDecoded;

    monitor_t* mon = &dec->mon;
    const ftx_waterfall_t* wf = &mon->wf;
    bool js8 = ftx_protocol_is_js8(wf->protocol);
    int iterations = js8 ? kJS8LDPCIterations : kLDPCIterations;
    int sample_rate = (int)lroundf(mon->block_size / mon->symbol_period);

    ftx_message_t decoded[kMaxDecoded];
    ftx_message_t* decoded_hashtable[kMaxDecoded] = { 0 };
    int num_out = 0;
    int subtracted = 0; // results already removed from the audio
    // Subtract-and-rescan: decode, coherently subtract what decoded,
    // rebuild the waterfall from the cleaned audio, scan again for the
    // signals the strong ones were sitting on.
    int max_passes = (js8 && dec->audio && dec->audio_len > 0) ? 3 : 1;

    for (int pass = 0; pass < max_passes && num_out < max_results; ++pass)
    {
        if (pass > 0)
        {
            if (subtracted == num_out)
                break; // last pass found nothing new
            for (; subtracted < num_out; ++subtracted)
            {
                cft8_result_t* r = &results[subtracted];
                uint8_t tones[JS8_NN];
                js8_encode(r->js8_payload, r->js8_type, wf->protocol, tones);
                subtract_js8(dec->audio, dec->audio_len, tones, r->freq_hz, r->time_sec,
                             mon->symbol_period, sample_rate);
            }
            monitor_reset(mon);
            for (int pos = 0; pos + mon->block_size <= dec->audio_len; pos += mon->block_size)
            {
                if (mon->wf.num_blocks >= mon->wf.max_blocks)
                    break;
                monitor_process(mon, dec->audio + pos);
            }
        }

        ftx_candidate_t candidates[kJS8MaxCandidates];
        int num_candidates = ftx_find_candidates(wf, js8 ? kJS8MaxCandidates : kMaxCandidates,
                                                 candidates, js8 ? kJS8MinScore : kMinScore);

        for (int idx = 0; idx < num_candidates && num_out < max_results; ++idx)
        {
            const ftx_candidate_t* cand = &candidates[idx];

            ftx_message_t message;
            ftx_decode_status_t status;
            if (!ftx_decode_candidate(wf, cand, iterations, &message, &status))
                continue;

            // Duplicate check (same payload decoded from a different candidate)
            int idx_hash = message.hash % kMaxDecoded;
            bool duplicate = false;
            while (decoded_hashtable[idx_hash] != NULL)
            {
                if ((decoded_hashtable[idx_hash]->hash == message.hash)
                    && (0 == memcmp(decoded_hashtable[idx_hash]->payload, message.payload, sizeof(message.payload))))
                {
                    duplicate = true;
                    break;
                }
                idx_hash = (idx_hash + 1) % kMaxDecoded;
            }
            if (duplicate)
                continue;

            memcpy(&decoded[idx_hash], &message, sizeof(message));
            decoded_hashtable[idx_hash] = &decoded[idx_hash];

            char text[FTX_MAX_MESSAGE_LENGTH] = { 0 };
            if (js8)
            {
                // Raw bits go to Swift; the JS8 frame layer lives there.
            }
            else
            {
                ftx_message_offsets_t offsets; // out-param; ftx_message_decode requires it non-NULL
                if (FTX_MESSAGE_RC_OK != ftx_message_decode(&message, &hash_if, text, &offsets))
                    continue;
            }

            cft8_result_t* res = &results[num_out++];
            memset(res, 0, sizeof(*res));
            res->score = cand->score;
            res->snr = cand->score * 0.5f - 24.0f; // rough SNR estimate from sync score
            res->freq_hz = (mon->min_bin + cand->freq_offset + (float)cand->freq_sub / wf->freq_osr) / mon->symbol_period;
            res->time_sec = (cand->time_offset + (float)cand->time_sub / wf->time_osr) * mon->symbol_period;
            strncpy(res->text, text, sizeof(res->text) - 1);
            res->text[sizeof(res->text) - 1] = '\0';
            memcpy(res->js8_payload, message.payload, 9);
            res->js8_type = (uint8_t)(message.payload[9] >> 5);
        }
    }

    hashtable_age(dec->hashtable, 10);
    return num_out;
}

void cft8_reset(cft8_decoder_t* dec)
{
    monitor_reset(&dec->mon);
    dec->audio_len = 0;
}

void cft8_destroy(cft8_decoder_t* dec)
{
    if (!dec)
        return;
    monitor_free(&dec->mon);
    free(dec->audio);
    free(dec);
}

// --- Transmit side ---------------------------------------------------------
// GFSK pulse shaping and synthesis ported from ft8_lib's demo/gen_ft8.c (MIT).

#define FT8_SYMBOL_BT 2.0f
#define FT4_SYMBOL_BT 1.0f
#define GFSK_CONST_K 5.336446f // pi * sqrt(2 / log(2))

static void gfsk_pulse(int n_spsym, float symbol_bt, float* pulse)
{
    for (int i = 0; i < 3 * n_spsym; ++i)
    {
        float t = i / (float)n_spsym - 1.5f;
        float arg1 = GFSK_CONST_K * symbol_bt * (t + 0.5f);
        float arg2 = GFSK_CONST_K * symbol_bt * (t - 0.5f);
        pulse[i] = (erff(arg1) - erff(arg2)) / 2;
    }
}

static void synth_gfsk(const uint8_t* symbols, int n_sym, float f0, float symbol_bt,
                       float symbol_period, int signal_rate, float* signal)
{
    int n_spsym = (int)(0.5f + signal_rate * symbol_period);
    int n_wave = n_sym * n_spsym;
    float hmod = 1.0f;

    float dphi_peak = 2 * M_PI * hmod / n_spsym;
    int dphi_len = n_wave + 2 * n_spsym;
    float* dphi = malloc(dphi_len * sizeof(float));
    float* pulse = malloc(3 * n_spsym * sizeof(float));
    if (!dphi || !pulse)
    {
        free(dphi);
        free(pulse);
        return;
    }

    for (int i = 0; i < dphi_len; ++i)
    {
        dphi[i] = 2 * M_PI * f0 / signal_rate;
    }

    gfsk_pulse(n_spsym, symbol_bt, pulse);

    for (int i = 0; i < n_sym; ++i)
    {
        int ib = i * n_spsym;
        for (int j = 0; j < 3 * n_spsym; ++j)
        {
            dphi[j + ib] += dphi_peak * symbols[i] * pulse[j];
        }
    }
    // Extend first and last symbols into the dummy guard periods
    for (int j = 0; j < 2 * n_spsym; ++j)
    {
        dphi[j] += dphi_peak * pulse[j + n_spsym] * symbols[0];
        dphi[j + n_sym * n_spsym] += dphi_peak * pulse[j] * symbols[n_sym - 1];
    }

    float phi = 0;
    for (int k = 0; k < n_wave; ++k)
    {
        signal[k] = sinf(phi);
        phi = fmodf(phi + dphi[k + n_spsym], 2 * M_PI);
    }

    // Raised-cosine envelope on the edges to avoid key clicks
    int n_ramp = n_spsym / 8;
    for (int i = 0; i < n_ramp; ++i)
    {
        float env = (1 - cosf(2 * M_PI * i / (2 * n_ramp))) / 2;
        signal[i] *= env;
        signal[n_wave - 1 - i] *= env;
    }

    free(dphi);
    free(pulse);
}

// Lead silence + GFSK-shaped tones. Shared by the FT8/FT4 and JS8 paths.
static int synth_frame(const uint8_t* tones, int n_tones, float symbol_period, float symbol_bt,
                       float lead_seconds, float frequency_hz, int sample_rate,
                       float* samples, int max_samples)
{
    int n_spsym = (int)(0.5f + sample_rate * symbol_period);
    int lead_silence = (int)(0.5f + sample_rate * lead_seconds);
    int n_signal = n_tones * n_spsym;
    int total = lead_silence + n_signal;
    if (total > max_samples)
        return -100;

    memset(samples, 0, lead_silence * sizeof(float));
    synth_gfsk(tones, n_tones, frequency_hz, symbol_bt, symbol_period, sample_rate, samples + lead_silence);
    return total;
}

int cft8_encode_js8(const uint8_t payload[9], int type, float frequency_hz,
                    int sample_rate, cft8_protocol_t protocol,
                    float* samples, int max_samples)
{
    ftx_protocol_t p = to_ftx(protocol);
    if (!ftx_protocol_is_js8(p))
        return -101;
    uint8_t tones[JS8_NN];
    js8_encode(payload, (uint8_t)type, p, tones);
    return synth_frame(tones, JS8_NN, ftx_protocol_symbol_period(p), FT8_SYMBOL_BT,
                       ftx_protocol_start_delay(p), frequency_hz, sample_rate, samples, max_samples);
}

void cft8_js8_tones(const uint8_t payload[9], int type, cft8_protocol_t protocol, uint8_t tones[79])
{
    js8_encode(payload, (uint8_t)type, to_ftx(protocol), tones);
}

bool cft8_js8_decode_tones(const uint8_t tones[79], uint8_t payload[9], int* type)
{
    uint8_t t = 0;
    bool ok = js8_decode_tones(tones, payload, &t);
    if (type)
        *type = t;
    return ok;
}

int cft8_encode(const char* message, float frequency_hz, int sample_rate,
                cft8_protocol_t protocol, float* samples, int max_samples)
{
    ftx_message_t msg;
    ftx_message_rc_t rc = ftx_message_encode(&msg, NULL, message);
    if (rc != FTX_MESSAGE_RC_OK)
        return -(int)rc;

    uint8_t tones[FT4_NN]; // FT4_NN (105) > FT8_NN (79)
    int n_tones;
    float symbol_period, symbol_bt;
    if (protocol == CFT8_PROTOCOL_FT4)
    {
        ft4_encode(msg.payload, tones);
        n_tones = FT4_NN;
        symbol_period = FT4_SYMBOL_PERIOD;
        symbol_bt = FT4_SYMBOL_BT;
    }
    else
    {
        ft8_encode(msg.payload, tones);
        n_tones = FT8_NN;
        symbol_period = FT8_SYMBOL_PERIOD;
        symbol_bt = FT8_SYMBOL_BT;
    }

    // 0.5 s lead silence, matching WSJT-X timing
    return synth_frame(tones, n_tones, symbol_period, symbol_bt, 0.5f, frequency_hz, sample_rate, samples, max_samples);
}
