// WSPR encode/receive interface for Swift.
#ifndef WSPR_GLUE_H
#define WSPR_GLUE_H

#ifdef __cplusplus
extern "C" {
#endif

struct wspr_spot {
    char call[13];
    char grid[7];
    int power_dbm;
    float snr;
    float dt;
    float drift;
    double freq_hz;
};

// Build the 162 channel symbols for a type-1 WSPR message. Returns 1 on
// success, 0 for unpackable callsign/grid.
int wspr_channel_symbols(const char* callsign, const char* grid4, int power_dbm,
                         unsigned char* symbols162);

// Synthesize a WSPR transmission: 1 s lead silence + 110.6 s of 4-FSK at
// audio frequency f0_hz. Returns samples written or negative on error.
int wspr_tx(const char* callsign, const char* grid4, int power_dbm,
            float f0_hz, int sample_rate, float* samples, int max_samples);

// Decode a ~120 s slot of 12 kHz mono audio (WSPR sub-band around 1500 Hz).
// Returns number of spots written, or negative on error.
int wspr_rx(const float* audio, int n_samples, int sample_rate,
            const char* rcall, const char* rgrid, int dial_hz,
            struct wspr_spot* spots, int max_spots);

#ifdef __cplusplus
}
#endif

#endif // WSPR_GLUE_H
