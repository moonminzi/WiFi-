//! nagoing 난독화 계층 — ChaCha20 keystream(RFC 8439)으로 프레임 본문을 XOR한다.
//!
//! 여기서 하는 암호화는 **보안이 아니라 난독화**다. 진짜 기밀성·무결성은 안쪽 WireGuard가 책임진다.
//! 이 층의 목적은 하나뿐: 선(wire) 위의 바이트를 무작위로 보이게 만들어 DPI가 WireGuard의
//! 고정된 헤더(첫 바이트 0x01~0x04 + 4바이트 0)를 알아보지 못하게 하는 것. 그래서 외부 crypto 의존성을
//! 더하지 않고 ChaCha20 블록 함수를 직접 넣었다(iOS/Android 교차 컴파일에서 새 의존성 사고를 피함).
//!
//! 키는 공유 PSK에서 뽑는다(모든 클라가 같은 난독화 키를 쓴다 — 인증이 아니므로 괜찮다). nonce는
//! 방향(dir) 1바이트 + 카운터 8바이트로 만들어 두 방향이 같은 (key,nonce)를 쓰지 않게 한다.

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

/// 방향 + 패킷 nonce(8바이트, 패킷마다 무작위)로 12바이트 ChaCha nonce를 만든다: [dir, 0,0,0, nonce8].
/// nonce8은 선 위에 평문으로 실어 수신 측이 같은 keystream을 만든다. 무작위라 클라끼리 키스트림이 겹치지 않는다.
fn nonce_for(dir: u8, nonce8: &[u8; 8]) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[0] = dir;
    n[4..12].copy_from_slice(nonce8);
    n
}

/// data를 keystream으로 제자리 XOR한다. (dir, nonce8)이 nonce를 정하므로 같은 값으로 다시 부르면 복호화된다.
pub fn apply(key: &[u8; 32], dir: u8, nonce8: &[u8; 8], data: &mut [u8]) {
    let nonce = nonce_for(dir, nonce8);
    let mut block_ctr: u32 = 0;
    let mut off = 0;
    let total = data.len();
    while off < total {
        let ks = chacha20_block(key, block_ctr, &nonce);
        let end = (off + 64).min(total);
        for (i, b) in data[off..end].iter_mut().enumerate() {
            *b ^= ks[i];
        }
        off += 64;
        block_ctr += 1;
    }
}

/// PSK(임의 길이)에서 32바이트 난독화 키를 뽑는다. 보안용 KDF가 아니라 확산용이다.
pub fn derive_key(psk: &[u8]) -> [u8; 32] {
    let mut key = [0u8; 32];
    for (i, &b) in psk.iter().enumerate() {
        key[i % 32] ^= b.wrapping_add((i as u8).wrapping_mul(31));
    }
    // ChaCha20 블록 한 번으로 섞어 PSK의 구조가 키에 남지 않게 한다.
    let block = chacha20_block(&key, 0, &[0u8; 12]);
    key.copy_from_slice(&block[0..32]);
    key
}

/// 송신 방향(dir=1 클라→서버, dir=2 서버→클라).
pub const DIR_C2S: u8 = 1;
pub const DIR_S2C: u8 = 2;

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

    #[test]
    fn apply_roundtrip() {
        let key = derive_key(b"nago-secret");
        let nonce = [9u8, 8, 7, 6, 5, 4, 3, 2];
        let mut data = b"the quick brown fox jumps over the lazy dog, several times over".to_vec();
        let original = data.clone();
        apply(&key, DIR_C2S, &nonce, &mut data);
        assert_ne!(data, original); // 실제로 가려졌는지
        apply(&key, DIR_C2S, &nonce, &mut data);
        assert_eq!(data, original); // 같은 (dir,nonce)로 되돌아옴
    }

    #[test]
    fn direction_separation() {
        // 같은 nonce라도 방향이 다르면 다른 keystream → 평문 누출 없음.
        let key = derive_key(b"k");
        let nonce = [1u8, 2, 3, 4, 5, 6, 7, 8];
        let mut a = vec![0u8; 32];
        let mut b = vec![0u8; 32];
        apply(&key, DIR_C2S, &nonce, &mut a);
        apply(&key, DIR_S2C, &nonce, &mut b);
        assert_ne!(a, b);
    }

    #[test]
    fn derive_is_stable_and_spreads() {
        assert_eq!(derive_key(b"abc"), derive_key(b"abc"));
        assert_ne!(derive_key(b"abc"), derive_key(b"abd"));
    }
}
