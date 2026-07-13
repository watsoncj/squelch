// Swift-friendly wrapper around ft8_lib's monitor/decode pipeline.
// The candidate scan + LDPC decode + duplicate filtering follows
// ft8_lib's demo/decode_ft8.c (MIT license).
#include "include/cft8.h"

#include <ft8/decode.h>
#include <ft8/message.h>
#include <ft8/encode.h>
#include <ft8/constants.h>
#include <common/monitor.h>

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
};

typedef struct {
    char callsign[12];
    uint32_t hash; // 8 MSBs: age, 22 LSBs: hash value
} hash_entry_t;

struct cft8_decoder {
    monitor_t mon;
    hash_entry_t hashtable[kHashtableSize];
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

cft8_decoder_t* cft8_create(int sample_rate, bool ft4)
{
    cft8_decoder_t* dec = calloc(1, sizeof(cft8_decoder_t));
    if (!dec)
        return NULL;
    monitor_config_t cfg = {
        .f_min = 200,
        .f_max = 3000,
        .sample_rate = sample_rate,
        .time_osr = 2,
        .freq_osr = 2,
        .protocol = ft4 ? FTX_PROTOCOL_FT4 : FTX_PROTOCOL_FT8,
    };
    monitor_init(&dec->mon, &cfg);
    return dec;
}

void cft8_feed(cft8_decoder_t* dec, const float* samples, int num_samples)
{
    const int block = dec->mon.block_size;
    for (int pos = 0; pos + block <= num_samples; pos += block)
    {
        if (dec->mon.wf.num_blocks >= dec->mon.wf.max_blocks)
            break;
        monitor_process(&dec->mon, samples + pos);
    }
}

int cft8_decode(cft8_decoder_t* dec, cft8_result_t* results, int max_results)
{
    g_active_table = dec->hashtable;
    if (max_results > kMaxDecoded)
        max_results = kMaxDecoded;

    const ftx_waterfall_t* wf = &dec->mon.wf;
    ftx_candidate_t candidates[kMaxCandidates];
    int num_candidates = ftx_find_candidates(wf, kMaxCandidates, candidates, kMinScore);

    ftx_message_t decoded[kMaxDecoded];
    ftx_message_t* decoded_hashtable[kMaxDecoded] = { 0 };
    int num_out = 0;

    for (int idx = 0; idx < num_candidates && num_out < max_results; ++idx)
    {
        const ftx_candidate_t* cand = &candidates[idx];

        ftx_message_t message;
        ftx_decode_status_t status;
        if (!ftx_decode_candidate(wf, cand, kLDPCIterations, &message, &status))
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

        char text[FTX_MAX_MESSAGE_LENGTH];
        ftx_message_offsets_t offsets; // out-param; ftx_message_decode requires it non-NULL
        if (FTX_MESSAGE_RC_OK != ftx_message_decode(&message, &hash_if, text, &offsets))
            continue;

        cft8_result_t* res = &results[num_out++];
        res->score = cand->score;
        res->snr = cand->score * 0.5f - 24.0f; // rough SNR estimate from sync score
        res->freq_hz = (dec->mon.min_bin + cand->freq_offset + (float)cand->freq_sub / wf->freq_osr) / dec->mon.symbol_period;
        res->time_sec = (cand->time_offset + (float)cand->time_sub / wf->time_osr) * dec->mon.symbol_period;
        strncpy(res->text, text, sizeof(res->text) - 1);
        res->text[sizeof(res->text) - 1] = '\0';
    }

    hashtable_age(dec->hashtable, 10);
    return num_out;
}

void cft8_reset(cft8_decoder_t* dec)
{
    monitor_reset(&dec->mon);
}

void cft8_destroy(cft8_decoder_t* dec)
{
    if (!dec)
        return;
    monitor_free(&dec->mon);
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

int cft8_encode(const char* message, float frequency_hz, int sample_rate,
                bool ft4, float* samples, int max_samples)
{
    ftx_message_t msg;
    ftx_message_rc_t rc = ftx_message_encode(&msg, NULL, message);
    if (rc != FTX_MESSAGE_RC_OK)
        return -(int)rc;

    uint8_t tones[FT4_NN]; // FT4_NN (105) > FT8_NN (79)
    int n_tones;
    float symbol_period, symbol_bt;
    if (ft4)
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

    int n_spsym = (int)(0.5f + sample_rate * symbol_period);
    int lead_silence = sample_rate / 2; // 0.5 s, matching WSJT-X timing
    int n_signal = n_tones * n_spsym;
    int total = lead_silence + n_signal;
    if (total > max_samples)
        return -100;

    memset(samples, 0, lead_silence * sizeof(float));
    synth_gfsk(tones, n_tones, frequency_hz, symbol_bt, symbol_period, sample_rate, samples + lead_silence);
    return total;
}
