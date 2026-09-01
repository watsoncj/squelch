#ifndef _INCLUDE_CONSTANTS_H_
#define _INCLUDE_CONSTANTS_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

#define FT8_SYMBOL_PERIOD (0.160f) ///< FT8 symbol duration, defines tone deviation in Hz and symbol rate
#define FT8_SLOT_TIME     (15.0f)  ///< FT8 slot period

#define FT4_SYMBOL_PERIOD (0.048f) ///< FT4 symbol duration, defines tone deviation in Hz and symbol rate
#define FT4_SLOT_TIME     (7.5f)   ///< FT4 slot period

// Define FT8 symbol counts
// FT8 message structure:
//     S D1 S D2 S
// S  - sync block (7 symbols of Costas pattern)
// D1 - first data block (29 symbols each encoding 3 bits)
#define FT8_ND          (58) ///< Data symbols
#define FT8_NN          (79) ///< Total channel symbols (FT8_NS + FT8_ND)
#define FT8_LENGTH_SYNC (7)  ///< Length of each sync group
#define FT8_NUM_SYNC    (3)  ///< Number of sync groups
#define FT8_SYNC_OFFSET (36) ///< Offset between sync groups

// Define FT4 symbol counts
// FT4 message structure:
//     R Sa D1 Sb D2 Sc D3 Sd R
// R  - ramping symbol (no payload information conveyed)
// Sx - one of four _different_ sync blocks (4 symbols of Costas pattern)
// Dy - data block (29 symbols each encoding 2 bits)
#define FT4_ND          (87)  ///< Data symbols
#define FT4_NR          (2)   ///< Ramp symbols (beginning + end)
#define FT4_NN          (105) ///< Total channel symbols (FT4_NS + FT4_ND + FT4_NR)
#define FT4_LENGTH_SYNC (4)   ///< Length of each sync group
#define FT4_NUM_SYNC    (4)   ///< Number of sync groups
#define FT4_SYNC_OFFSET (33)  ///< Offset between sync groups

// Define LDPC parameters
#define FTX_LDPC_N       (174)                  ///< Number of bits in the encoded message (payload with LDPC checksum bits)
#define FTX_LDPC_K       (91)                   ///< Number of payload bits (including CRC)
#define FTX_LDPC_M       (83)                   ///< Number of LDPC checksum bits (FTX_LDPC_N - FTX_LDPC_K)
#define FTX_LDPC_N_BYTES ((FTX_LDPC_N + 7) / 8) ///< Number of whole bytes needed to store 174 bits (full message)
#define FTX_LDPC_K_BYTES ((FTX_LDPC_K + 7) / 8) ///< Number of whole bytes needed to store 91 bits (payload + CRC only)

// Define CRC parameters
#define FT8_CRC_POLYNOMIAL ((uint16_t)0x2757u) ///< CRC-14 polynomial without the leading (MSB) 1
#define FT8_CRC_WIDTH      (14)

typedef enum
{
    FTX_PROTOCOL_FT4,
    FTX_PROTOCOL_FT8,
    // JS8 speeds. All share FT8's 79-symbol / 8-tone frame geometry but use
    // different Costas patterns, symbol periods, the LDPC(174,87) code with a
    // 12-bit CRC, and no Gray mapping. See js8/js8.h.
    FTX_PROTOCOL_JS8_NORMAL, ///< 160 ms symbols, 15 s period ("NORMAL", speed 0)
    FTX_PROTOCOL_JS8_FAST,   ///< 100 ms symbols, 10 s period ("FAST", speed 1)
    FTX_PROTOCOL_JS8_TURBO,  ///<  50 ms symbols,  6 s period ("JS8 40", speed 2)
    FTX_PROTOCOL_JS8_SLOW,   ///< 320 ms symbols, 30 s period ("SLOW", speed 4)
    FTX_PROTOCOL_JS8_ULTRA,  ///<  32 ms symbols,  4 s period ("JS8 60", speed 8, experimental)
} ftx_protocol_t;

/// True for any of the JS8 speeds.
int ftx_protocol_is_js8(ftx_protocol_t protocol);
/// Symbol duration in seconds (also the reciprocal of the tone spacing).
float ftx_protocol_symbol_period(ftx_protocol_t protocol);
/// Transmission period (slot length) in seconds.
float ftx_protocol_slot_time(ftx_protocol_t protocol);
/// Delay from the slot boundary to the first symbol, in seconds.
float ftx_protocol_start_delay(ftx_protocol_t protocol);
/// Number of channel symbols in one transmission (79 or 105).
int ftx_protocol_num_tones(ftx_protocol_t protocol);
/// Costas sync pattern for the three 7-symbol sync blocks (JS8 and FT8).
/// Returns a pointer to 3 rows of 7 tones.
const uint8_t (*ftx_protocol_costas7(ftx_protocol_t protocol))[7];

/// Costas 7x7 tone pattern for synchronization
extern const uint8_t kFT8_Costas_pattern[7];
extern const uint8_t kFT4_Costas_pattern[4][4];
/// FT8's Costas pattern repeated for each of the three sync blocks
extern const uint8_t kFT8_Costas_blocks[3][7];
/// JS8 NORMAL uses one pattern in all three sync blocks; the other speeds
/// use three distinct patterns (one per block).
extern const uint8_t kJS8_Costas_original[3][7];
extern const uint8_t kJS8_Costas_modified[3][7];

/// Gray code map to encode 8 symbols (tones)
extern const uint8_t kFT8_Gray_map[8];
extern const uint8_t kFT4_Gray_map[4];

extern const uint8_t kFT4_XOR_sequence[10];

/// Parity generator matrix for (174,91) LDPC code, stored in bitpacked format (MSB first)
extern const uint8_t kFTX_LDPC_generator[FTX_LDPC_M][FTX_LDPC_K_BYTES];

/// LDPC(174,91) parity check matrix, containing 83 rows,
/// each row describes one parity check,
/// each number is an index into the codeword (1-origin).
/// The codeword bits mentioned in each row must xor to zero.
/// From WSJT-X's ldpc_174_91_c_reordered_parity.f90.
extern const uint8_t kFTX_LDPC_Nm[FTX_LDPC_M][7];

/// Mn from WSJT-X's bpdecode174.f90. Each row corresponds to a codeword bit.
/// The numbers indicate which three parity checks (rows in Nm) refer to the codeword bit.
/// The numbers use 1 as the origin (first entry).
extern const uint8_t kFTX_LDPC_Mn[FTX_LDPC_N][3];

/// Number of rows (columns in C/C++) in the array Nm.
extern const uint8_t kFTX_LDPC_Num_rows[FTX_LDPC_M];

#ifdef __cplusplus
}
#endif

#endif // _INCLUDE_CONSTANTS_H_
