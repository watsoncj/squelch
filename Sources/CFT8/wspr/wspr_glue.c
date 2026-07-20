// WSPR encode + receive front-end for RadioFun.
// Decoding uses the vendored wsprd chain (K1JT/K9AN/VA2GKA, GPL v3) with
// kiss_fft substituted for FFTW. The encoder implements the standard WSPR
// packing as the exact inverse of wsprd_utils' unpackers.
#include "../include/wspr_glue.h"
#include "wsprd.h"
#include "fano.h"
#include "wsprd_utils.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

extern uint8_t pr3vector[162];

// --- Packing (inverse of unpackcall / unpackgrid / unpack50) ---------------

static int charValueFull(char ch) { // 0-9, A-Z, space → 0..36
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'A' && ch <= 'Z') return ch - 'A' + 10;
    if (ch == ' ') return 36;
    return -1;
}

static int charValueLetterSpace(char ch) { // A-Z → 0..25, space → 26
    if (ch >= 'A' && ch <= 'Z') return ch - 'A';
    if (ch == ' ') return 26;
    return -1;
}

// Standard callsign → 28-bit integer. Third slot of the 6-char field must
// hold the digit; shorter calls pad left/right with spaces.
static int packcall(const char* callsign, int32_t* n1) {
    char field[7] = "      ";
    size_t len = strlen(callsign);
    if (len < 3 || len > 6)
        return 0;

    char upper[7];
    for (size_t i = 0; i < len; i++)
        upper[i] = (char)toupper((unsigned char)callsign[i]);
    upper[len] = '\0';

    if (len >= 3 && isdigit((unsigned char)upper[2])) {
        memcpy(field, upper, len);
    } else if (len >= 2 && isdigit((unsigned char)upper[1]) && len <= 5) {
        field[0] = ' ';
        memcpy(field + 1, upper, len);
    } else {
        return 0;
    }

    int c0 = charValueFull(field[0]);
    int c1 = charValueFull(field[1]);
    int c2 = field[2] >= '0' && field[2] <= '9' ? field[2] - '0' : -1;
    int c3 = charValueLetterSpace(field[3]);
    int c4 = charValueLetterSpace(field[4]);
    int c5 = charValueLetterSpace(field[5]);
    if (c0 < 0 || c1 < 0 || c1 > 35 || c2 < 0 || c3 < 0 || c4 < 0 || c5 < 0)
        return 0;

    int32_t n = c0;
    n = n * 36 + c1;
    n = n * 10 + c2;
    n = n * 27 + c3;
    n = n * 27 + c4;
    n = n * 27 + c5;
    *n1 = n;
    return 1;
}

// 4-char grid + power (dBm) → 22-bit integer.
static int packgridpower(const char* grid, int power_dbm, int32_t* n2) {
    if (strlen(grid) < 4)
        return 0;
    char g0 = (char)toupper((unsigned char)grid[0]);
    char g1 = (char)toupper((unsigned char)grid[1]);
    if (g0 < 'A' || g0 > 'R' || g1 < 'A' || g1 > 'R')
        return 0;
    if (!isdigit((unsigned char)grid[2]) || !isdigit((unsigned char)grid[3]))
        return 0;

    int lonIndex = 10 * (g0 - 'A') + (grid[2] - '0'); // (180 - dlong) / 2
    int latIndex = 10 * (g1 - 'A') + (grid[3] - '0'); // dlat + 90
    int dlong = 180 - 2 * lonIndex;
    int qlon = (dlong + 178) / 2;
    int32_t ngrid = qlon * 180 + latIndex;
    if (ngrid < 0 || ngrid >= 32400)
        return 0;
    if (power_dbm < 0) power_dbm = 0;
    if (power_dbm > 60) power_dbm = 60;
    *n2 = ngrid * 128 + power_dbm + 64;
    return 1;
}

static void pack50(int32_t n1, int32_t n2, unsigned char* dat) {
    memset(dat, 0, 11);
    dat[0] = (n1 >> 20) & 0xFF;
    dat[1] = (n1 >> 12) & 0xFF;
    dat[2] = (n1 >> 4) & 0xFF;
    dat[3] = (unsigned char)(((n1 & 0xF) << 4) | ((n2 >> 18) & 0xF));
    dat[4] = (n2 >> 10) & 0xFF;
    dat[5] = (n2 >> 2) & 0xFF;
    dat[6] = (unsigned char)((n2 & 0x3) << 6);
}

// Inverse of wsprd_utils' deinterleave: place input bit p at bit-reversed
// position j.
static void interleave(unsigned char* sym) {
    unsigned char tmp[162];
    unsigned char p = 0, i = 0, j;
    while (p < 162) {
        j = (unsigned char)((((uint64_t)i * 0x80200802ULL) & 0x0884422110ULL) * 0x0101010101ULL >> 32);
        if (j < 162) {
            tmp[j] = sym[p];
            p++;
        }
        i++;
    }
    memcpy(sym, tmp, 162);
}

int wspr_channel_symbols(const char* callsign, const char* grid4, int power_dbm,
                         unsigned char* symbols162) {
    int32_t n1, n2;
    if (!packcall(callsign, &n1) || !packgridpower(grid4, power_dbm, &n2))
        return 0;

    unsigned char data[11];
    pack50(n1, n2, data);

    unsigned char coded[176];
    encode(coded, data, 11);

    unsigned char bits[162];
    memcpy(bits, coded, 162);
    interleave(bits);

    for (int i = 0; i < 162; i++)
        symbols162[i] = (unsigned char)(pr3vector[i] + 2 * bits[i]);
    return 1;
}

int wspr_tx(const char* callsign, const char* grid4, int power_dbm,
            float f0_hz, int sample_rate, float* samples, int max_samples) {
    unsigned char chan[162];
    if (!wspr_channel_symbols(callsign, grid4, power_dbm, chan))
        return -1;

    const double tone_spacing = 12000.0 / 8192.0; // 1.4648 Hz
    const int spsym = (int)((double)sample_rate * 8192.0 / 12000.0 + 0.5);
    const int lead = sample_rate; // 1 s: WSPR transmissions start at :01
    const int total = lead + 162 * spsym;
    if (total > max_samples)
        return -2;

    memset(samples, 0, (size_t)lead * sizeof(float));
    double phi = 0;
    int pos = lead;
    for (int i = 0; i < 162; i++) {
        double freq = f0_hz + ((double)chan[i] - 1.5) * tone_spacing;
        double dphi = 2.0 * M_PI * freq / (double)sample_rate;
        for (int k = 0; k < spsym; k++) {
            samples[pos++] = 0.5f * (float)sin(phi);
            phi = fmod(phi + dphi, 2.0 * M_PI);
        }
    }
    return total;
}

// --- Receive front-end ------------------------------------------------------

#define WSPR_DECIM 32
#define WSPR_FIR_TAPS 240
#define WSPR_CENTER_HZ 1500.0

int wspr_rx(const float* audio, int n_samples, int sample_rate,
            const char* rcall, const char* rgrid, int dial_hz,
            struct wspr_spot* spots, int max_spots) {
    if (sample_rate != 12000)
        return -1;

    // Windowed-sinc lowpass, cutoff ~170 Hz, for the ×32 decimation
    static float taps[WSPR_FIR_TAPS];
    static int taps_ready = 0;
    if (!taps_ready) {
        const double fc = 170.0 / 12000.0;
        for (int i = 0; i < WSPR_FIR_TAPS; i++) {
            double x = i - (WSPR_FIR_TAPS - 1) / 2.0;
            double sinc = x == 0 ? 2.0 * M_PI * fc : sin(2.0 * M_PI * fc * x) / x;
            double window = 0.54 - 0.46 * cos(2.0 * M_PI * i / (WSPR_FIR_TAPS - 1));
            taps[i] = (float)(sinc * window);
        }
        taps_ready = 1;
    }

    int out_count = (n_samples - WSPR_FIR_TAPS) / WSPR_DECIM;
    if (out_count < 40000) // need most of the 110.6 s transmission
        return -1;
    if (out_count > 46000)
        out_count = 46000;

    float* idat = malloc((size_t)out_count * sizeof(float));
    float* qdat = malloc((size_t)out_count * sizeof(float));
    if (!idat || !qdat) {
        free(idat);
        free(qdat);
        return -1;
    }

    const double omega = 2.0 * M_PI * WSPR_CENTER_HZ / 12000.0;
    for (int m = 0; m < out_count; m++) {
        int base = m * WSPR_DECIM;
        double si = 0, sq = 0;
        for (int t = 0; t < WSPR_FIR_TAPS; t++) {
            int idx = base + t;
            double ph = omega * (double)idx;
            double s = audio[idx] * taps[t];
            si += s * cos(ph);
            sq += -s * sin(ph);
        }
        idat[m] = (float)si;
        qdat[m] = (float)sq;
    }

    struct decoder_options options;
    memset(&options, 0, sizeof(options));
    options.freq = dial_hz;
    options.usehashtable = 0;
    options.npasses = 2;
    options.subtraction = 1;
    options.quickmode = 0;
    snprintf(options.rcall, sizeof(options.rcall), "%s", rcall ? rcall : "");
    snprintf(options.rloc, sizeof(options.rloc), "%s", rgrid ? rgrid : "");

    struct decoder_results results[50];
    memset(results, 0, sizeof(results));
    int n_results = 0;
    wspr_decode(idat, qdat, out_count, options, results, &n_results);

    free(idat);
    free(qdat);

    int count = n_results < max_spots ? n_results : max_spots;
    for (int i = 0; i < count; i++) {
        struct wspr_spot* s = &spots[i];
        snprintf(s->call, sizeof(s->call), "%s", results[i].call);
        snprintf(s->grid, sizeof(s->grid), "%s", results[i].loc);
        s->power_dbm = atoi(results[i].pwr);
        s->snr = results[i].snr;
        s->dt = results[i].dt;
        s->drift = results[i].drift;
        s->freq_hz = results[i].freq * 1e6; // wsprd reports MHz
    }
    return count;
}
