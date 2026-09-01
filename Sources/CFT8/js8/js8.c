#include "js8.h"
#include "js8_tables.h"
#include <ft8/ldpc.h>
#include <string.h>

static uint8_t parity8(uint8_t x)
{
    x ^= x >> 4;
    x ^= x >> 2;
    x ^= x >> 1;
    return x & 1;
}

// Plain modulo-2 division of the first `num_bits` bits of `message` by the
// CRC-12 polynomial (register initialised to zero, no reflection).
static uint16_t crc12_bits(const uint8_t* message, int num_bits)
{
    const uint16_t poly = 0xC06;
    uint16_t remainder = 0;
    for (int i = 0; i < num_bits; ++i)
    {
        if (i % 8 == 0)
            remainder ^= (uint16_t)(message[i / 8] << 4);
        if (remainder & 0x800)
            remainder = (uint16_t)((remainder << 1) ^ poly);
        else
            remainder = (uint16_t)(remainder << 1);
    }
    return remainder & 0xFFF;
}

uint16_t js8_crc12(const uint8_t a87[11])
{
    // 72 payload + 3 type bits, then one zero bit, then the 12-bit register.
    // (Equivalent to an "augmented" CRC over all 88 bits with the CRC field
    // zeroed.) JS8 XORs the result with 42 to keep its frames from passing
    // an FT8-v1 decoder's check.
    return crc12_bits(a87, 76) ^ 42;
}

// LDPC(174,87) systematic encode. itmp = [87 parity bits, 87 message bits];
// codeword[colorder[k]] = itmp[k].
static void encode174_87(const uint8_t message[JS8_LDPC_K_BYTES], uint8_t codeword[JS8_LDPC_N_BYTES])
{
    memset(codeword, 0, JS8_LDPC_N_BYTES);
    int col = 0;
    for (int i = 0; i < JS8_LDPC_M; ++i)
    {
        uint8_t nsum = 0;
        for (int j = 0; j < JS8_LDPC_K_BYTES; ++j)
            nsum ^= parity8(message[j] & kJS8_LDPC_generator[i][j]);
        if (nsum & 1)
        {
            uint8_t pos = kJS8_LDPC_colorder[col];
            codeword[pos / 8] |= (uint8_t)(0x80u >> (pos % 8));
        }
        ++col;
    }
    for (int j = 0; j < JS8_LDPC_K; ++j)
    {
        if (message[j / 8] & (0x80u >> (j % 8)))
        {
            uint8_t pos = kJS8_LDPC_colorder[col];
            codeword[pos / 8] |= (uint8_t)(0x80u >> (pos % 8));
        }
        ++col;
    }
}

void js8_encode(const uint8_t payload[JS8_PAYLOAD_BYTES], uint8_t type, ftx_protocol_t protocol, uint8_t tones[JS8_NN])
{
    uint8_t a87[JS8_LDPC_K_BYTES];
    memcpy(a87, payload, JS8_PAYLOAD_BYTES);
    a87[9] = (uint8_t)((type & 0x07) << 5);
    a87[10] = 0;
    uint16_t crc = js8_crc12(a87);
    a87[9] |= (uint8_t)((crc >> 7) & 0x1F);
    a87[10] = (uint8_t)((crc & 0x7F) << 1);

    uint8_t codeword[JS8_LDPC_N_BYTES];
    encode174_87(a87, codeword);

    const uint8_t (*costas)[7] = ftx_protocol_costas7(protocol);
    int bit = 0;
    for (int i = 0; i < JS8_NN; ++i)
    {
        if (i < 7)
            tones[i] = costas[0][i];
        else if (i >= 36 && i < 43)
            tones[i] = costas[1][i - 36];
        else if (i >= 72)
            tones[i] = costas[2][i - 72];
        else
        {
            uint8_t t = 0;
            for (int b = 0; b < 3; ++b, ++bit)
            {
                t = (uint8_t)(t << 1);
                if (codeword[bit / 8] & (0x80u >> (bit % 8)))
                    t |= 1;
            }
            tones[i] = t;
        }
    }
}

bool js8_unpack_bits(const uint8_t bits87[87], uint8_t payload[JS8_PAYLOAD_BYTES], uint8_t* type, uint16_t* crc)
{
    uint8_t a87[JS8_LDPC_K_BYTES] = { 0 };
    for (int i = 0; i < 87; ++i)
        if (bits87[i])
            a87[i / 8] |= (uint8_t)(0x80u >> (i % 8));

    uint16_t extracted = (uint16_t)(((a87[9] & 0x1F) << 7) | (a87[10] >> 1));
    a87[9] &= 0xE0;
    a87[10] = 0;
    uint16_t computed = js8_crc12(a87);
    if (crc)
        *crc = extracted;
    if (extracted != computed)
        return false;
    memcpy(payload, a87, JS8_PAYLOAD_BYTES);
    *type = (uint8_t)(a87[9] >> 5);
    return true;
}

bool js8_decode_tones(const uint8_t tones[JS8_NN], uint8_t payload[JS8_PAYLOAD_BYTES], uint8_t* type)
{
    uint8_t cw[JS8_LDPC_N];
    int bit = 0;
    for (int i = 0; i < JS8_NN; ++i)
    {
        if (i < 7 || (i >= 36 && i < 43) || i >= 72)
            continue;
        cw[bit++] = (tones[i] >> 2) & 1;
        cw[bit++] = (tones[i] >> 1) & 1;
        cw[bit++] = tones[i] & 1;
    }
    for (int m = 0; m < JS8_LDPC_M; ++m)
    {
        uint8_t x = 0;
        for (int i = 0; i < kJS8_LDPC_Num_rows[m]; ++i)
            x ^= cw[kJS8_LDPC_Nm[m][i] - 1];
        if (x)
            return false;
    }
    uint16_t crc;
    return js8_unpack_bits(cw + JS8_LDPC_M, payload, type, &crc);
}
