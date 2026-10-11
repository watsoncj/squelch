// Baseband FT8 demodulator: refines a waterfall candidate against the slot
// audio itself and demodulates with symbol-matched filters.
#ifndef FT8_FINE_H
#define FT8_FINE_H

#include "decode.h"
#include <fft/kiss_fftr.h>
#include <stdbool.h>

#define FT8_FINE_RATE 200 // baseband sample rate, Hz
#define FT8_FINE_SPS 32   // samples per symbol at that rate
#define FT8_FINE_FLOOR_CELLS 160 // 25 Hz cells, 0…4 kHz

typedef struct
{
    int nfft;  // slot length in input samples
    int nbase; // slot length in baseband samples
    float df;  // spectrum bin width, Hz
    kiss_fftr_cfg fwd;
    kiss_fft_cfg inv;
    float* padded;
    kiss_fft_cpx* spec; // nfft/2+1 bins of the slot
    kiss_fft_cpx* bins; // nbase scratch
    kiss_fft_cpx* base; // nbase baseband samples
    kiss_fft_cpx* rot;  // nbase, frequency-corrected
    float floor_power[FT8_FINE_FLOOR_CELLS]; // noise power per spectrum bin, by 25 Hz cell
} ft8_fine_t;

typedef struct
{
    float freq_hz;  // tone 0 frequency
    float time_sec; // start of symbol 0 within the slot
    float snr_db;   // in 2500 Hz
    int sync;       // sync symbols whose strongest tone is the expected one (0…21)
} ft8_fine_result_t;

bool ft8_fine_init(ft8_fine_t* me, int sample_rate, float slot_seconds);
void ft8_fine_free(ft8_fine_t* me);
/// Transform the slot audio; call once per pass before ft8_fine_decode.
void ft8_fine_load(ft8_fine_t* me, const float* audio, int num_samples);
/// Refine (freq_hz, time_sec) and try to decode. `out` is filled whenever
/// sync refinement ran, decoded or not.
bool ft8_fine_decode(ft8_fine_t* me, float freq_hz, float time_sec, int max_iterations,
                     ftx_message_t* message, ft8_fine_result_t* out);

#endif
