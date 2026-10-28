//! nagoing — WireGuard 아래에 끼우는 난독화·손실보정·빠른전환 전송 층.
//!
//! WireGuard(NepTUN)는 하나도 바뀌지 않는다. NepTUN이 로컬 UDP로 보낸 WG 데이터그램을 클라이언트
//! 프록시가 받아 ① 난독화해 443(UDP→막히면 TCP)으로 서버에 보내고, 서버 프록시가 풀어 wg0로 넘긴다.
//! ② 인터리브 FEC로 버스트 손실을 되살리고, ③ session_id로 세션을 묶어 망 전환 시 WG 재핸드셰이크 없이
//! 이어 간다.
//!
//! 구성:
//! - `obfs`      ChaCha20 keystream(난독화. 보안은 안쪽 WG가 책임)
//! - `frame`     프레임 인코드/디코드
//! - `fec`       인터리브 XOR 손실 보정
//! - `transport` UDP(QUIC 모양)·TCP(TLS 흉내) 전송
//! - `proxy`     클라이언트·서버 중계 루프
//!
//! 리눅스 검증: `examples/nagoing_loopback.rs`(손실 주입 + 폴백), `examples/nagoing_proxy.rs`(실제 중계).

pub mod fec;
pub mod frame;
pub mod obfs;
pub mod proxy;
pub mod transport;

pub use proxy::{
    run_client, run_server, ClientConfig, ClientHandle, ClientStats, FecParams, Prefer,
    ServerConfig, ServerHandle,
};
pub use transport::Kind;

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static RNG_STATE: AtomicU64 = AtomicU64::new(0);

/// 가벼운 난수(보안용 아님): session_id, connection id, TLS random 등 유일성에만 쓴다.
/// SystemTime으로 한 번 시드하고 splitmix64로 뽑는다.
pub fn rand_u64() -> u64 {
    let mut s = RNG_STATE.load(Ordering::Relaxed);
    if s == 0 {
        let seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x9E37_79B9_7F4A_7C15)
            ^ (&RNG_STATE as *const _ as u64);
        s = seed | 1;
    }
    // splitmix64
    s = s.wrapping_add(0x9E37_79B9_7F4A_7C15);
    RNG_STATE.store(s, Ordering::Relaxed);
    let mut z = s;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// buf를 난수로 채운다.
pub fn rand_bytes(buf: &mut [u8]) {
    let mut i = 0;
    while i < buf.len() {
        let r = rand_u64().to_le_bytes();
        let n = (buf.len() - i).min(8);
        buf[i..i + n].copy_from_slice(&r[..n]);
        i += n;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rand_is_nonzero_and_varies() {
        let a = rand_u64();
        let b = rand_u64();
        assert_ne!(a, b);
        let mut buf = [0u8; 16];
        rand_bytes(&mut buf);
        assert!(buf.iter().any(|&x| x != 0));
    }
}
