// JS8 frame codec: 72-bit payload + 3-bit frame type -> 79 channel symbols.
//
// JS8 (JS8Call) keeps FT8's 79-symbol, 8-tone frame with three 7-symbol
// Costas sync blocks at symbols 0, 36 and 72, but differs from FT8 in:
//   * sync patterns (see kJS8_Costas_* in ft8/constants.h)
//   * the code: LDPC(174,87) over 72 payload + 3 type + 12 CRC bits
//   * CRC-12 (poly 0xC06, computed over the 75 message bits followed by a
//     zero bit) XOR 42
//   * no Gray mapping: each data symbol carries 3 bits MSB first
//   * symbol order: the 87 parity bits ride in symbols 7-35, the 87
//     message bits in symbols 43-71
// Implemented from the protocol description; the LDPC tables are ft8_lib's
// MIT-licensed (174,87) tables (js8_tables.c).
#ifndef _INCLUDE_JS8_H_
#define _INCLUDE_JS8_H_

#include <stdint.h>
#include <stdbool.h>
#include <ft8/constants.h>

#ifdef __cplusplus
extern "C" {
#endif

#define JS8_NN (79)
#define JS8_PAYLOAD_BYTES (9) ///< 72 payload bits, MSB first

/// CRC-12 of an 87-bit message buffer (11 bytes) whose CRC field (low 5 bits
/// of byte 9 and byte 10) is zero.
uint16_t js8_crc12(const uint8_t a87[11]);

/// Build the 79 tones (0..7) for a payload and 3-bit frame type.
void js8_encode(const uint8_t payload[JS8_PAYLOAD_BYTES], uint8_t type, ftx_protocol_t protocol, uint8_t tones[JS8_NN]);

/// Given the 87 decoded message bits (one byte per bit, codeword positions
/// 87..173), verify the CRC and unpack payload/type. Returns false on CRC
/// mismatch. crc receives the transmitted CRC either way.
bool js8_unpack_bits(const uint8_t bits87[87], uint8_t payload[JS8_PAYLOAD_BYTES], uint8_t* type, uint16_t* crc);

/// Hard-decision decode of a tone sequence (for test vectors): checks that
/// the codeword satisfies every parity check and the CRC. Returns false if
/// either fails.
bool js8_decode_tones(const uint8_t tones[JS8_NN], uint8_t payload[JS8_PAYLOAD_BYTES], uint8_t* type);

#ifdef __cplusplus
}
#endif

#endif
