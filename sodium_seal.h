#ifndef SODIUM_SEAL_H
#define SODIUM_SEAL_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint64_t u64;
typedef int64_t gf[16];

static const u8 _0[16] = {0};
static const u8 _9[32] = {9};
static const gf _121665 = {0xDB41,1};
static const u8 sigma[16] = "expand 32-byte k";

static u64 L32(u64 x, int c) { return (x << c) | ((x & 0xffffffff) >> (32 - c)); }
static u64 ld32(const u8 *x) {
    u64 u = x[3];
    u = (u << 8) | x[2];
    u = (u << 8) | x[1];
    return (u << 8) | x[0];
}
static void st32(u8 *x, u64 u) {
    for (int i = 0; i < 4; ++i) { x[i] = u; u >>= 8; }
}

static void core_salsa(u8 *out, const u8 *in, const u8 *k, const u8 *c, int h) {
    u64 w[16], x[16], y[16], t[4];
    int i, j, m;
    for (i = 0; i < 4; ++i) {
        x[5*i] = ld32(c+4*i);
        x[1+i] = ld32(k+4*i);
        x[6+i] = ld32(in+4*i);
        x[11+i] = ld32(k+16+4*i);
    }
    for (i = 0; i < 16; ++i) y[i] = x[i];
    for (i = 0; i < 20; ++i) {
        for (j = 0; j < 4; ++j) {
            for (m = 0; m < 4; ++m) t[m] = x[(5*j+4*m)%16];
            t[1] ^= L32(t[0]+t[3], 7);
            t[2] ^= L32(t[1]+t[0], 9);
            t[3] ^= L32(t[2]+t[1], 13);
            t[0] ^= L32(t[3]+t[2], 18);
            for (m = 0; m < 4; ++m) w[4*j+(j+m)%4] = t[m];
        }
        for (m = 0; m < 16; ++m) x[m] = w[m];
    }
    if (h) {
        for (i = 0; i < 16; ++i) x[i] += y[i];
        for (i = 0; i < 4; ++i) {
            x[5*i] -= ld32(c+4*i);
            x[6+i] -= ld32(in+4*i);
        }
        for (i = 0; i < 4; ++i) {
            st32(out+4*i, x[5*i]);
            st32(out+16+4*i, x[6+i]);
        }
    } else {
        for (i = 0; i < 16; ++i) st32(out+4*i, x[i]+y[i]);
    }
}

static void crypto_stream_salsa20_xor(u8 *c, const u8 *m, u64 b, const u8 *n, const u8 *k) {
    u8 z[16], x[64];
    u64 u, i;
    if (!b) return;
    for (i = 0; i < 16; ++i) z[i] = 0;
    for (i = 0; i < 8; ++i) z[i] = n[i];
    while (b >= 64) {
        core_salsa(x, z, k, sigma, 0);
        for (i = 0; i < 64; ++i) c[i] = (m ? m[i] : 0) ^ x[i];
        u = 1;
        for (i = 8; i < 16; ++i) { u += (u64)z[i]; z[i] = u; u >>= 8; }
        b -= 64; c += 64; if (m) m += 64;
    }
    if (b) {
        core_salsa(x, z, k, sigma, 0);
        for (i = 0; i < b; ++i) c[i] = (m ? m[i] : 0) ^ x[i];
    }
}

static void crypto_stream_xsalsa20_xor(u8 *c, const u8 *m, u64 d, const u8 *n, const u8 *k) {
    u8 s[32];
    core_salsa(s, n, k, sigma, 1);
    crypto_stream_salsa20_xor(c, m, d, n+16, s);
}

static void add1305(u64 *h, const u64 *c) {
    u64 j, u = 0;
    for (j = 0; j < 17; ++j) { u += h[j] + c[j]; h[j] = u & 255; u >>= 8; }
}

static const u64 minusp[17] = {5,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,252};

static void crypto_onetimeauth(u8 *out, const u8 *m, u64 n, const u8 *k) {
    u64 s, i, j, u, x[17], r[17], h[17], c[17], g[17];
    for (j = 0; j < 17; ++j) r[j] = h[j] = 0;
    for (j = 0; j < 16; ++j) r[j] = k[j];
    r[3] &= 15; r[4] &= 252; r[7] &= 15; r[8] &= 252; r[11] &= 15; r[12] &= 252; r[15] &= 15;
    while (n > 0) {
        for (j = 0; j < 17; ++j) c[j] = 0;
        for (j = 0; (j < 16) && (j < n); ++j) c[j] = m[j];
        c[j] = 1;
        m += j; n -= j;
        add1305(h, c);
        for (i = 0; i < 17; ++i) {
            x[i] = 0;
            for (j = 0; j < 17; ++j) x[i] += h[j] * ((j <= i) ? r[i - j] : 320 * r[i + 17 - j]);
        }
        for (i = 0; i < 17; ++i) h[i] = x[i];
        u = 0;
        for (j = 0; j < 16; ++j) { u += h[j]; h[j] = u & 255; u >>= 8; }
        u += h[16]; h[16] = u & 3;
        u = 5 * (u >> 2);
        for (j = 0; j < 16; ++j) { u += h[j]; h[j] = u & 255; u >>= 8; }
        u += h[16]; h[16] = u;
    }
    for (j = 0; j < 17; ++j) g[j] = h[j];
    add1305(h, minusp);
    s = -(h[16] >> 7);
    for (j = 0; j < 17; ++j) h[j] ^= s & (g[j] ^ h[j]);
    for (j = 0; j < 16; ++j) c[j] = k[j + 16];
    c[16] = 0;
    add1305(h, c);
    for (j = 0; j < 16; ++j) out[j] = h[j];
}

static void car25519(gf o) {
    int i; int64_t c;
    for (i = 0; i < 16; ++i) {
        o[i] += (1LL << 16);
        c = o[i] >> 16;
        o[(i+1)*(i<15)] += c - 1 + 37*(c-1)*(i==15);
        o[i] -= (uint64_t)c << 16;
    }
}

static void sel25519(gf p, gf q, int b) {
    int64_t t, i, c = ~(b - 1);
    for (i = 0; i < 16; ++i) { t = c & (p[i] ^ q[i]); p[i] ^= t; q[i] ^= t; }
}

static void pack25519(u8 *o, const gf n) {
    int i, j, b;
    gf m, t;
    for (i = 0; i < 16; ++i) t[i] = n[i];
    car25519(t); car25519(t); car25519(t);
    for (j = 0; j < 2; ++j) {
        m[0] = t[0] - 0xffed;
        for (i = 1; i < 15; ++i) { m[i] = t[i] - 0xffff - ((m[i-1] >> 16) & 1); m[i-1] &= 0xffff; }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        b = (m[15] >> 16) & 1;
        m[14] &= 0xffff;
        sel25519(t, m, 1 - b);
    }
    for (i = 0; i < 16; ++i) { o[2*i] = t[i] & 0xff; o[2*i+1] = t[i] >> 8; }
}

static void unpack25519(gf o, const u8 *n) {
    for (int i = 0; i < 16; ++i) o[i] = n[2*i] + ((int64_t)n[2*i+1] << 8);
    o[15] &= 0x7fff;
}

static void A(gf o, const gf a, const gf b) { for (int i = 0; i < 16; ++i) o[i] = a[i] + b[i]; }
static void Z(gf o, const gf a, const gf b) { for (int i = 0; i < 16; ++i) o[i] = a[i] - b[i]; }
static void M(gf o, const gf a, const gf b) {
    int64_t i, j, t[31];
    for (i = 0; i < 31; ++i) t[i] = 0;
    for (i = 0; i < 16; ++i) for (j = 0; j < 16; ++j) t[i+j] += a[i] * b[j];
    for (i = 0; i < 15; ++i) t[i] += 38 * t[i+16];
    for (i = 0; i < 16; ++i) o[i] = t[i];
    car25519(o); car25519(o);
}
static void S(gf o, const gf a) { M(o, a, a); }
static void inv25519(gf o, const gf i) {
    gf c; int a;
    for (a = 0; a < 16; ++a) c[a] = i[a];
    for (a = 253; a >= 0; --a) { S(c, c); if (a != 2 && a != 4) M(c, c, i); }
    for (a = 0; a < 16; ++a) o[a] = c[a];
}

static void crypto_scalarmult(u8 *q, const u8 *n, const u8 *p) {
    u8 z[32];
    int64_t x[80], r, i;
    gf a, b, c, d, e, f;
    for (i = 0; i < 31; ++i) z[i] = n[i];
    z[31] = (n[31] & 127) | 64;
    z[0] &= 248;
    unpack25519(x, p);
    for (i = 0; i < 16; ++i) { b[i] = x[i]; d[i] = a[i] = c[i] = 0; }
    a[0] = d[0] = 1;
    for (i = 254; i >= 0; --i) {
        r = (z[i >> 3] >> (i & 7)) & 1;
        sel25519(a, b, r);
        sel25519(c, d, r);
        A(e, a, c);
        Z(a, a, c);
        A(c, b, d);
        Z(b, b, d);
        S(d, e);
        S(f, a);
        M(a, c, a);
        M(c, b, e);
        A(e, a, c);
        Z(a, a, c);
        S(b, a);
        Z(c, d, f);
        M(a, c, _121665);
        A(a, a, d);
        M(c, c, a);
        M(a, d, f);
        M(d, b, x);
        S(b, e);
        sel25519(a, b, r);
        sel25519(c, d, r);
    }
    for (i = 0; i < 16; ++i) { x[i+16] = a[i]; x[i+32] = c[i]; x[i+48] = b[i]; x[i+64] = d[i]; }
    inv25519(x+32, x+32);
    M(x+16, x+16, x+32);
    pack25519(q, x+16);
}

static const u64 b2b_IV[8] = {
    0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
    0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
    0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
    0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL
};

static const u8 b2b_sigma[12][16] = {
    { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    { 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    { 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
    { 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
    { 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
    { 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
    { 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
    { 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
    { 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
    { 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
    { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    { 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 }
};

#define B2B_ROTR64(x, y) (((x) >> (y)) | ((x) << (64 - (y))))
#define B2B_G(r, i, a, b, c, d) do { \
    a = a + b + m[b2b_sigma[r][2*i]]; \
    d = B2B_ROTR64(d ^ a, 32); \
    c = c + d; \
    b = B2B_ROTR64(b ^ c, 24); \
    a = a + b + m[b2b_sigma[r][2*i+1]]; \
    d = B2B_ROTR64(d ^ a, 16); \
    c = c + d; \
    b = B2B_ROTR64(b ^ c, 63); \
} while (0)

static void blake2b_seal_nonce(u8 *nonce24, const u8 *epk32, const u8 *pk32) {
    u64 h[8], v[16], m[16];
    memset(m, 0, sizeof(m));
    memcpy((u8 *)m, epk32, 32);
    memcpy((u8 *)m + 32, pk32, 32);
    for (int i = 0; i < 8; ++i) h[i] = b2b_IV[i];
    h[0] ^= 0x01010018ULL;
    for (int i = 0; i < 8; ++i) { v[i] = h[i]; v[i + 8] = b2b_IV[i]; }
    v[12] ^= 64ULL;
    v[14] ^= ~0ULL;
    for (int r = 0; r < 12; ++r) {
        B2B_G(r, 0, v[0], v[4], v[8],  v[12]);
        B2B_G(r, 1, v[1], v[5], v[9],  v[13]);
        B2B_G(r, 2, v[2], v[6], v[10], v[14]);
        B2B_G(r, 3, v[3], v[7], v[11], v[15]);
        B2B_G(r, 4, v[0], v[5], v[10], v[15]);
        B2B_G(r, 5, v[1], v[6], v[11], v[12]);
        B2B_G(r, 6, v[2], v[7], v[8],  v[13]);
        B2B_G(r, 7, v[3], v[4], v[9],  v[14]);
    }
    for (int i = 0; i < 8; ++i) h[i] ^= v[i] ^ v[i + 8];
    memcpy(nonce24, h, 24);
}

static void sodium_crypto_box_seal(u8 *sealed_out, const u8 *m, u64 mlen, const u8 *pk) {
    u8 esk[32], epk[32], nonce[24], k[32];
    arc4random_buf(esk, 32);
    crypto_scalarmult(epk, esk, _9);
    blake2b_seal_nonce(nonce, epk, pk);
    
    crypto_scalarmult(k, esk, pk);
    u8 shared_key[32];
    core_salsa(shared_key, _0, k, sigma, 1);
    
    u64 d = mlen + 32;
    u8 *m_pad = (u8 *)calloc(d, 1);
    u8 *c_pad = (u8 *)calloc(d, 1);
    memcpy(m_pad + 32, m, mlen);
    
    crypto_stream_xsalsa20_xor(c_pad, m_pad, d, nonce, shared_key);
    crypto_onetimeauth(c_pad + 16, c_pad + 32, d - 32, c_pad);
    
    memcpy(sealed_out, epk, 32);
    memcpy(sealed_out + 32, c_pad + 16, mlen + 16);
    
    free(m_pad);
    free(c_pad);
}

#endif
