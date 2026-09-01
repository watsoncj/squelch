// Simplified C interface over ft8_lib for Swift interop.
#ifndef CFT8_H
#define CFT8_H


#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cft8_decoder cft8_decoder_t;

// Waveform/protocol selection. Values mirror ft8_lib's ftx_protocol_t.
typedef enum {
    CFT8_PROTOCOL_FT4 = 0,
    CFT8_PROTOCOL_FT8 = 1,
    CFT8_PROTOCOL_JS8_NORMAL = 2, // 15 s period, 160 ms symbols
    CFT8_PROTOCOL_JS8_FAST = 3,   // 10 s, 100 ms
    CFT8_PROTOCOL_JS8_TURBO = 4,  //  6 s,  50 ms ("JS8 40")
    CFT8_PROTOCOL_JS8_SLOW = 5,   // 30 s, 320 ms
    CFT8_PROTOCOL_JS8_ULTRA = 6,  //  4 s,  32 ms ("JS8 60", experimental)
} cft8_protocol_t;

typedef struct {
    float snr;      // approximate SNR in dB
    float time_sec; // signal start offset within the slot, seconds
    float freq_hz;  // audio frequency offset, Hz
    int score;      // Costas sync score
    char text[64];  // decoded message text (FT8/FT4); empty for JS8
    uint8_t js8_payload[9]; // JS8: 72 payload bits, MSB first
    uint8_t js8_type;       // JS8: 3-bit frame type (0 normal, 1 first, 2 last, 4 data)
} cft8_result_t;

// Per-protocol timing, seconds.
float cft8_symbol_period(cft8_protocol_t protocol);   // also 1 / tone spacing
float cft8_slot_seconds(cft8_protocol_t protocol);    // transmission period
float cft8_start_delay(cft8_protocol_t protocol);     // slot boundary -> first symbol
float cft8_transmission_seconds(cft8_protocol_t protocol); // first symbol -> last

// Create a decoder for the given input sample rate (mono float samples).
cft8_decoder_t* cft8_create(int sample_rate, cft8_protocol_t protocol);

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
// error code if the message cannot be packed. FT8/FT4 only.
int cft8_encode(const char* message, float frequency_hz, int sample_rate,
                cft8_protocol_t protocol, float* samples, int max_samples);

// Encode one JS8 frame (72-bit payload, MSB first, plus 3-bit frame type)
// into audio: the speed's start delay of silence + 79 GFSK tones. Returns
// the number of samples written, or -100 if max_samples is too small.
int cft8_encode_js8(const uint8_t payload[9], int type, float frequency_hz,
                    int sample_rate, cft8_protocol_t protocol,
                    float* samples, int max_samples);

// JS8 tone-level helpers (for tests and diagnostics).
void cft8_js8_tones(const uint8_t payload[9], int type, cft8_protocol_t protocol, uint8_t tones[79]);
bool cft8_js8_decode_tones(const uint8_t tones[79], uint8_t payload[9], int* type);

#ifdef __cplusplus
}
#endif

#endif // CFT8_H
