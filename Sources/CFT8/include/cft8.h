// Simplified C interface over ft8_lib for Swift interop.
#ifndef CFT8_H
#define CFT8_H

#include "wspr_glue.h"

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cft8_decoder cft8_decoder_t;

typedef struct {
    float snr;      // approximate SNR in dB
    float time_sec; // signal start offset within the slot, seconds
    float freq_hz;  // audio frequency offset, Hz
    int score;      // Costas sync score
    char text[64];  // decoded message text
} cft8_result_t;

// Create a decoder for the given input sample rate (mono float samples).
// ft4 = false decodes FT8 (15 s slots), true decodes FT4 (7.5 s slots).
cft8_decoder_t* cft8_create(int sample_rate, bool ft4);

// Feed one slot's worth of audio (~15 s). Safe to pass fewer samples;
// extra samples beyond the slot capacity are ignored.
void cft8_feed(cft8_decoder_t* dec, const float* samples, int num_samples);

// Decode everything accumulated since the last reset.
// Returns the number of results written (up to max_results).
int cft8_decode(cft8_decoder_t* dec, cft8_result_t* results, int max_results);

// Clear accumulated audio to prepare for the next slot.
// The callsign hash table survives resets (needed for hashed callsigns).
void cft8_reset(cft8_decoder_t* dec);

void cft8_destroy(cft8_decoder_t* dec);

// Encode a message ("K1ABC W0CJW -05", "CQ W0CJW DM79", …) into audio:
// 0.5 s of leading silence + GFSK tones (12.64 s FT8 / 5.04 s FT4) at base
// frequency frequency_hz. Writes at most max_samples mono float samples.
// Returns the number of samples written, or a negative ftx_message_rc_t
// error code if the message cannot be packed.
int cft8_encode(const char* message, float frequency_hz, int sample_rate,
                bool ft4, float* samples, int max_samples);

#ifdef __cplusplus
}
#endif

#endif // CFT8_H
