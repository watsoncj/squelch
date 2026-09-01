#ifndef _INCLUDE_LDPC_H_
#define _INCLUDE_LDPC_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

// codeword is 174 log-likelihoods.
// plain is a return value, 174 ints, to be 0 or 1.
// iters is how hard to try.
// ok == 87 means success.
void ldpc_decode(float codeword[], int max_iters, uint8_t plain[], int* ok);

void bp_decode(float codeword[], int max_iters, uint8_t plain[], int* ok);

/// Describes a rate-1/2 (174,K) LDPC code by its parity-check tables.
/// Every codeword bit participates in exactly three checks.
typedef struct
{
    int num_checks;              ///< M: number of parity checks (rows of nm)
    const uint8_t (*nm)[7];      ///< per check: 1-origin codeword bit indices
    const uint8_t (*mn)[3];      ///< per codeword bit: 1-origin check indices
    const uint8_t* num_rows;     ///< per check: number of valid entries in nm
} ldpc_code_t;

extern const ldpc_code_t kLDPC_174_91; ///< FT8/FT4
extern const ldpc_code_t kLDPC_174_87; ///< JS8

/// Belief-propagation decode of a 174-bit codeword for the given code.
/// ok receives the number of unsatisfied parity checks (0 = success).
void bp_decode_code(const ldpc_code_t* code, float codeword[], int max_iters, uint8_t plain[], int* ok);

#ifdef __cplusplus
}
#endif

#endif // _INCLUDE_LDPC_H_
