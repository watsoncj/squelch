#include "fine.h"
#include "constants.h"
#include "encode.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define SPS FT8_FINE_SPS
#define TONE_HZ 6.25f

#define LLR_VARIANCE 24.0f // LLR variance handed to BP (ft8_lib's own scaling)
// Fewer of the 21 sync symbols than this on their expected tone: not a
// signal worth four LDPC attempts. Noise alone averages 21/8.
#define MIN_SYNC 6
#define LLR_VARIANTS 4

static float tone_cos[8][SPS], tone_sin[8][SPS];

bool ft8_fine_init(ft8_fine_t* me, int sample_rate, float slot_seconds)
{
    memset(me, 0, sizeof(*me));
    for (int k = 0; k < 8; ++k)
        for (int n = 0; n < SPS; ++n)
        {
            tone_cos[k][n] = cosf(2 * (float)M_PI * k * n / SPS);
            tone_sin[k][n] = sinf(2 * (float)M_PI * k * n / SPS);
        }
    me->nfft = (int)(sample_rate * slot_seconds);
    me->nbase = (int)(FT8_FINE_RATE * slot_seconds);
    if (me->nfft % 2 || sample_rate % FT8_FINE_RATE)
        return false;
    me->df = (float)sample_rate / me->nfft;
    me->fwd = kiss_fftr_alloc(me->nfft, 0, NULL, NULL);
    me->inv = kiss_fft_alloc(me->nbase, 1, NULL, NULL);
    me->padded = malloc(me->nfft * sizeof(float));
    me->spec = malloc((me->nfft / 2 + 1) * sizeof(kiss_fft_cpx));
    me->bins = malloc(me->nbase * sizeof(kiss_fft_cpx));
    me->base = malloc(me->nbase * sizeof(kiss_fft_cpx));
    me->rot = malloc(me->nbase * sizeof(kiss_fft_cpx));
    return me->fwd && me->inv && me->padded && me->spec && me->bins && me->base && me->rot;
}

void ft8_fine_free(ft8_fine_t* me)
{
    free(me->fwd);
    free(me->inv);
    free(me->padded);
    free(me->spec);
    free(me->bins);
    free(me->base);
    free(me->rot);
    memset(me, 0, sizeof(*me));
}

static int compare_float(const void* a, const void* b)
{
    float x = *(const float*)a, y = *(const float*)b;
    return (x > y) - (x < y);
}

void ft8_fine_load(ft8_fine_t* me, const float* audio, int num_samples)
{
    int n = num_samples < me->nfft ? num_samples : me->nfft;
    memcpy(me->padded, audio, n * sizeof(float));
    memset(me->padded + n, 0, (me->nfft - n) * sizeof(float));
    kiss_fftr(me->fwd, me->padded, me->spec);

    // Noise floor per 25 Hz cell: the 15th percentile of the bin powers
    // within ±150 Hz. Noise power in a bin is exponentially distributed,
    // so that percentile sits at -ln(0.85) of the mean; signals only occupy
    // the upper part of the distribution unless the band is packed solid.
    enum { kStride = 6, kMaxPick = 1024 };
    float pick[kMaxPick];
    int half = (int)(150.0f / me->df);
    for (int cell = 0; cell < FT8_FINE_FLOOR_CELLS; ++cell)
    {
        int mid = (int)((cell + 0.5f) * 25.0f / me->df);
        int count = 0;
        for (int k = mid - half; k <= mid + half && count < kMaxPick; k += kStride)
        {
            if (k <= 0 || k >= me->nfft / 2)
                continue;
            pick[count++] = me->spec[k].r * me->spec[k].r + me->spec[k].i * me->spec[k].i;
        }
        if (count < 16)
        {
            me->floor_power[cell] = 0;
            continue;
        }
        qsort(pick, count, sizeof(float), compare_float);
        me->floor_power[cell] = pick[count * 15 / 100] / 0.1625f;
    }
}

// Shift the 62.5 Hz around the signal down to DC and resample to 200 Hz by
// keeping just those spectrum bins: tone k lands on k * 6.25 Hz.
static float to_baseband(ft8_fine_t* me, float freq_hz)
{
    int center = (int)lroundf(freq_hz / me->df);
    int lo = (int)lroundf((freq_hz - 1.5f * TONE_HZ) / me->df);
    int hi = (int)lroundf((freq_hz + 8.5f * TONE_HZ) / me->df);
    int edge = (int)lroundf(TONE_HZ / me->df);
    memset(me->bins, 0, me->nbase * sizeof(kiss_fft_cpx));
    for (int k = lo; k <= hi; ++k)
    {
        if (k <= 0 || k >= me->nfft / 2)
            continue;
        float w = 1.0f;
        if (k - lo < edge)
            w = 0.5f * (1 - cosf((float)M_PI * (k - lo) / edge));
        else if (hi - k < edge)
            w = 0.5f * (1 - cosf((float)M_PI * (hi - k) / edge));
        int dst = (k - center + me->nbase) % me->nbase;
        me->bins[dst].r = me->spec[k].r * w;
        me->bins[dst].i = me->spec[k].i * w;
    }
    kiss_fft(me->inv, me->bins, me->base);
    return center * me->df;
}

// Matched filter for one tone over one symbol starting at sample `start`
static inline void correlate(const kiss_fft_cpx* x, int nx, int start, int tone, float* re, float* im)
{
    float sr = 0, si = 0;
    if (start >= 0 && start + SPS <= nx)
    {
        const kiss_fft_cpx* p = x + start;
        const float* c = tone_cos[tone];
        const float* s = tone_sin[tone];
        for (int n = 0; n < SPS; ++n)
        {
            sr += p[n].r * c[n] + p[n].i * s[n];
            si += p[n].i * c[n] - p[n].r * s[n];
        }
    }
    *re = sr;
    *im = si;
}

static void rotate(const ft8_fine_t* me, float delta_hz, int from, int to)
{
    if (from < 0)
        from = 0;
    if (to > me->nbase)
        to = me->nbase;
    float w = -2 * (float)M_PI * delta_hz / FT8_FINE_RATE;
    for (int n = from; n < to; ++n)
    {
        float c = cosf(w * n), s = sinf(w * n);
        me->rot[n].r = me->base[n].r * c - me->base[n].i * s;
        me->rot[n].i = me->base[n].r * s + me->base[n].i * c;
    }
}

// Sync quality: the share of each sync symbol's energy that sits on the
// expected Costas tone, summed over the 21 sync symbols. Working in shares
// rather than raw energy keeps a stronger overlapping signal from pulling
// the search onto its own tone grid — no symbol can count for more than 1.
static float sync_power(const ft8_fine_t* me, int start)
{
    float total = 0;
    for (int m = 0; m < 3; ++m)
        for (int k = 0; k < 7; ++k)
        {
            int sym = start + (36 * m + k) * SPS;
            float all = 0, expected = 0;
            for (int t = 0; t < 8; ++t)
            {
                float re, im;
                correlate(me->rot, me->nbase, sym, t, &re, &im);
                float p = re * re + im * im;
                all += p;
                if (t == kFT8_Costas_pattern[k])
                    expected = p;
            }
            if (all > 0)
                total += expected / all;
        }
    return total;
}

static void normalize(float* llr)
{
    float sum = 0, sum2 = 0;
    for (int i = 0; i < FTX_LDPC_N; ++i)
    {
        sum += llr[i];
        sum2 += llr[i] * llr[i];
    }
    float var = (sum2 - sum * sum / FTX_LDPC_N) / FTX_LDPC_N;
    if (var <= 0)
        return;
    float scale = sqrtf(LLR_VARIANCE / var);
    for (int i = 0; i < FTX_LDPC_N; ++i)
        llr[i] *= scale;
}

// Bit metrics from `group` consecutive symbols detected jointly: the tones
// of a symbol group add coherently (FT8's phase is continuous and each
// tone completes whole cycles per symbol), so the best joint hypothesis
// with a bit set, minus the best with it clear, is that bit's metric.
static void group_llr(float (*cr)[8], float (*ci)[8], int first_sym, int group, bool relative, float* llr)
{
    int combos = 1 << (3 * group);
    int bits = 3 * group;
    float best1[9], best0[9];
    for (int b = 0; b < bits; ++b)
        best1[b] = best0[b] = -1;
    for (int j = 0; j < combos; ++j)
    {
        float re = 0, im = 0;
        for (int g = 0; g < group; ++g)
        {
            int v = (j >> (3 * (group - 1 - g))) & 7;
            int tone = kFT8_Gray_map[v];
            re += cr[first_sym + g][tone];
            im += ci[first_sym + g][tone];
        }
        float mag = sqrtf(re * re + im * im);
        for (int b = 0; b < bits; ++b)
        {
            if (j & (1 << (bits - 1 - b)))
            {
                if (mag > best1[b])
                    best1[b] = mag;
            }
            else if (mag > best0[b])
                best0[b] = mag;
        }
    }
    for (int b = 0; b < bits; ++b)
    {
        llr[b] = best1[b] - best0[b];
        if (relative)
        {
            // Scale by the group's own strength, so a burst of interference
            // can't outvote the rest of the message with confident wrong bits
            float top = best1[b] > best0[b] ? best1[b] : best0[b];
            llr[b] = top > 0 ? llr[b] / top : 0;
        }
    }
}

static void extract_llr(float (*cr)[8], float (*ci)[8], int nsym, bool relative, float* log174)
{
    for (int half = 0; half < 2; ++half)
    {
        int sym0 = half ? 43 : 7; // first data symbol of the half
        for (int d = 0; d < 29;)
        {
            int group = (29 - d) < nsym ? (29 - d) : nsym;
            group_llr(cr, ci, sym0 + d, group, relative, log174 + 3 * (29 * half + d));
            d += group;
        }
    }
    normalize(log174);
}

bool ft8_fine_decode(ft8_fine_t* me, float freq_hz, float time_sec, int max_iterations,
                     ftx_message_t* message, ft8_fine_result_t* out)
{
    float base_hz = to_baseband(me, freq_hz);
    int center = (int)lroundf(time_sec * FT8_FINE_RATE);
    int span_lo = center - 28, span_hi = center + 28 + FT8_NN * SPS;

    // Coarse: 1 Hz × 10 ms grid over ±2 Hz, ±120 ms
    float best = -1e30f, best_delta = 0;
    int best_start = center;
    for (int fi = -2; fi <= 2; ++fi)
    {
        rotate(me, (float)fi, span_lo, span_hi);
        for (int ds = -24; ds <= 24; ds += 2)
        {
            float p = sync_power(me, center + ds);
            if (p > best)
            {
                best = p;
                best_delta = (float)fi;
                best_start = center + ds;
            }
        }
    }
    // Fine: 0.2 Hz × 5 ms around the coarse peak
    float coarse_delta = best_delta;
    int coarse_start = best_start;
    for (int fi = -4; fi <= 4; ++fi)
    {
        float delta = coarse_delta + 0.2f * fi;
        rotate(me, delta, span_lo, span_hi);
        for (int ds = -2; ds <= 2; ++ds)
        {
            float p = sync_power(me, coarse_start + ds);
            if (p > best)
            {
                best = p;
                best_delta = delta;
                best_start = coarse_start + ds;
            }
        }
    }
    rotate(me, best_delta, span_lo, span_hi);

    float cr[FT8_NN][8], ci[FT8_NN][8];
    for (int s = 0; s < FT8_NN; ++s)
        for (int k = 0; k < 8; ++k)
            correlate(me->rot, me->nbase, best_start + s * SPS, k, &cr[s][k], &ci[s][k]);

    int sync = 0;
    for (int m = 0; m < 3; ++m)
        for (int k = 0; k < 7; ++k)
        {
            int s = 36 * m + k, top = 0;
            float top_p = -1;
            for (int t = 0; t < 8; ++t)
            {
                float p = cr[s][t] * cr[s][t] + ci[s][t] * ci[s][t];
                if (p > top_p)
                {
                    top_p = p;
                    top = t;
                }
            }
            sync += (top == kFT8_Costas_pattern[k]);
        }

    out->freq_hz = base_hz + best_delta;
    out->time_sec = (float)best_start / FT8_FINE_RATE;
    out->sync = sync;
    out->snr_db = -30;
    if (sync < MIN_SYNC)
        return false;

    bool ok = false;
    for (int v = 0; v < LLR_VARIANTS && !ok; ++v)
    {
        // 1-, 2- and 3-symbol detection, then single symbols again with
        // each symbol's metrics scaled to its own strength
        int nsym = v < 3 ? v + 1 : 1;
        float log174[FTX_LDPC_N];
        ftx_decode_status_t status;
        extract_llr(cr, ci, nsym, v == 3, log174);
        ok = ftx_decode_llr(log174, max_iterations, message, &status);
    }
    if (!ok)
        return false;

    // SNR from the decoded tones: power on the sent tone against the tones
    // at least two away (the neighbours carry the GFSK transitions).
    uint8_t tones[FT8_NN];
    ft8_encode(message->payload, tones);
    double sig = 0, noise = 0;
    int nn = 0, ns = 0;
    for (int s = 0; s < FT8_NN; ++s)
    {
        if (cr[s][0] == 0 && ci[s][0] == 0 && cr[s][7] == 0 && ci[s][7] == 0)
            continue; // symbol outside the captured audio
        for (int t = 0; t < 8; ++t)
        {
            double p = cr[s][t] * cr[s][t] + ci[s][t] * ci[s][t];
            if (t == tones[s])
            {
                sig += p;
                ++ns;
            }
            else if (abs(t - tones[s]) >= 2)
            {
                noise += p;
                ++nn;
            }
        }
    }
    if (ns > 0 && nn > 0)
    {
        sig /= ns;
        noise /= nn;
        // The off-tone estimate is exact for weak signals but bottoms out
        // on a strong signal's own leakage; the slot's spectral floor has
        // no such limit. A matched filter passes nbase * SPS bins' worth
        // of noise power. Take whichever is lower.
        int cell = (int)((out->freq_hz + 3.5f * TONE_HZ) / 25.0f);
        if (cell >= 0 && cell < FT8_FINE_FLOOR_CELLS && me->floor_power[cell] > 0)
        {
            double floor = (double)me->floor_power[cell] * me->nbase * SPS;
            if (floor < noise)
                noise = floor;
        }
        double ratio = sig / noise - 1;
        if (ratio < 1e-3)
            ratio = 1e-3;
        // one 6.25 Hz bin of noise -> 2500 Hz reference
        float snr = (float)(10 * log10(ratio) - 10 * log10(2500.0 / TONE_HZ));
        out->snr_db = snr < -24 ? -24 : snr;
    }
    return true;
}
