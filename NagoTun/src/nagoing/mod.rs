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

/// buf를 OS 난수로 채운다(getrandom: 리눅스 getrandom(2)/iOS SecRandom/안드로이드). 스레드 안전·암호급.
/// 패킷 nonce, session_id, connection id, TLS random에 쓴다.
pub fn rand_bytes(buf: &mut [u8]) {
    if getrandom::getrandom(buf).is_err() {
        // 극히 드문 실패 — 적어도 서로 다른 값이 나오게 시간 기반으로 채운다(nonce 유일성 유지).
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0);
        for (i, b) in buf.iter_mut().enumerate() {
            *b = (t >> ((i % 8) * 8)) as u8 ^ (i as u8).wrapping_mul(31);
        }
    }
}

/// 난수 u64.
pub fn rand_u64() -> u64 {
    let mut b = [0u8; 8];
    rand_bytes(&mut b);
    u64::from_le_bytes(b)
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
