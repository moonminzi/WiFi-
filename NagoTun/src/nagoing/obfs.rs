//! ChaCha20 블록 함수(RFC 8439 §2.3).
//!
//! v1에서는 이걸로 프레임 전체를 PSK keystream으로 가렸지만, v2는 암호화·무결성을 세션 AEAD(ring)가 맡는다.
//! 여기 남은 블록 함수는 crypto.rs가 패킷 카운터를 가리는 마스크(QUIC 헤더 보호와 같은 생각)를 만들 때만 쓴다.

/// ChaCha20 한 블록(64바이트) — RFC 8439 §2.3. counter는 state[12], nonce 12바이트는 state[13..16].
pub fn chacha20_block(key: &[u8; 32], counter: u32, nonce: &[u8; 12]) -> [u8; 64] {
    const C: [u32; 4] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]; // "expand 32-byte k"
    let mut s = [0u32; 16];
    s[0..4].copy_from_slice(&C);
    for i in 0..8 {
        s[4 + i] = u32::from_le_bytes([key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]]);
    }
    s[12] = counter;
    for i in 0..3 {
        s[13 + i] = u32::from_le_bytes([nonce[4 * i], nonce[4 * i + 1], nonce[4 * i + 2], nonce[4 * i + 3]]);
    }

    let mut x = s;
    #[inline(always)]
    fn qr(x: &mut [u32; 16], a: usize, b: usize, c: usize, d: usize) {
        x[a] = x[a].wrapping_add(x[b]); x[d] ^= x[a]; x[d] = x[d].rotate_left(16);
        x[c] = x[c].wrapping_add(x[d]); x[b] ^= x[c]; x[b] = x[b].rotate_left(12);
        x[a] = x[a].wrapping_add(x[b]); x[d] ^= x[a]; x[d] = x[d].rotate_left(8);
        x[c] = x[c].wrapping_add(x[d]); x[b] ^= x[c]; x[b] = x[b].rotate_left(7);
    }
    for _ in 0..10 {
        // 세로(열) 4번
        qr(&mut x, 0, 4, 8, 12); qr(&mut x, 1, 5, 9, 13); qr(&mut x, 2, 6, 10, 14); qr(&mut x, 3, 7, 11, 15);
        // 대각선 4번
        qr(&mut x, 0, 5, 10, 15); qr(&mut x, 1, 6, 11, 12); qr(&mut x, 2, 7, 8, 13); qr(&mut x, 3, 4, 9, 14);
    }

    let mut out = [0u8; 64];
    for i in 0..16 {
        out[4 * i..4 * i + 4].copy_from_slice(&x[i].wrapping_add(s[i]).to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // RFC 8439 §2.3.2 테스트 벡터.
    #[test]
    fn rfc8439_block() {
        let mut key = [0u8; 32];
        for (i, slot) in key.iter_mut().enumerate() {
            *slot = i as u8;
        }
        let nonce = [0, 0, 0, 9, 0, 0, 0, 0x4a, 0, 0, 0, 0];
        let out = chacha20_block(&key, 1, &nonce);
        let expected: [u8; 64] = [
            0x10, 0xf1, 0xe7, 0xe4, 0xd1, 0x3b, 0x59, 0x15, 0x50, 0x0f, 0xdd, 0x1f, 0xa3, 0x20, 0x71, 0xc4,
            0xc7, 0xd1, 0xf4, 0xc7, 0x33, 0xc0, 0x68, 0x03, 0x04, 0x22, 0xaa, 0x9a, 0xc3, 0xd4, 0x6c, 0x4e,
            0xd2, 0x82, 0x64, 0x46, 0x07, 0x9f, 0xaa, 0x09, 0x14, 0xc2, 0xd7, 0x05, 0xd9, 0x8b, 0x02, 0xa2,
            0xb5, 0x12, 0x9c, 0xd1, 0xde, 0x16, 0x4e, 0xb9, 0xcb, 0xd0, 0x83, 0xe8, 0xa2, 0x50, 0x3c, 0x4e,
        ];
        assert_eq!(out, expected);
    }
}
