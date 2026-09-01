#ifndef _INCLUDE_JS8_TABLES_H_
#define _INCLUDE_JS8_TABLES_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define JS8_LDPC_N       (174)
#define JS8_LDPC_K       (87)   ///< 72 payload bits + 3 type bits + 12 CRC bits
#define JS8_LDPC_M       (87)
#define JS8_LDPC_K_BYTES (11)
#define JS8_LDPC_N_BYTES (22)

extern const uint8_t kJS8_LDPC_generator[JS8_LDPC_M][JS8_LDPC_K_BYTES];
extern const uint8_t kJS8_LDPC_colorder[JS8_LDPC_N];
extern const uint8_t kJS8_LDPC_Nm[JS8_LDPC_M][7];
extern const uint8_t kJS8_LDPC_Mn[JS8_LDPC_N][3];
extern const uint8_t kJS8_LDPC_Num_rows[JS8_LDPC_M];

#ifdef __cplusplus
}
#endif

#endif
