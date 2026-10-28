//! nagoing 프레임 코덱 — 전송 위로 오가는 한 "메시지"를 만들고 읽는다.
//!
//! 선 위의 한 메시지(inner message) 모양: `[nonce: 8B(무작위)][ciphertext]`.
//! ciphertext는 아래 Frame 본문을 obfs(ChaCha20)로 가린 것. nonce 8바이트는 **패킷마다 무작위**로 만들어
//! 평문으로 싣는다 → 클라끼리 키스트림이 겹치지 않고, 고정된 평문 카운터 지문도 사라진다.
//!
//! 컨트롤 프레임(HELLO 등)과 작은 DATA(WG 핸드셰이크 148/92·keepalive)에는 무작위 길이 패딩을 붙여
//! 크기 지문을 가린다. 대용량 DATA는 처리량을 위해 패딩하지 않는다.
//!
//! 전송별 바깥 포장(QUIC 모양 UDP 헤더 / TLS 레코드)은 transport.rs가 이 inner message에 덧씌운다.

use super::obfs;

pub const HELLO: u8 = 0x01;
pub const HELLO_ACK: u8 = 0x02;
pub const DATA: u8 = 0x10;
pub const PARITY: u8 = 0x11;
pub const PING: u8 = 0x20;
pub const PONG: u8 = 0x21;

pub const NONCE_LEN: usize = 8;
pub const PROTOCOL_VERSION: u8 = 1;

/// 패딩을 붙일 기준(이보다 작은 payload만). WG 핸드셰이크(148/92)·keepalive를 덮고, 대용량은 안 건드린다.
const PAD_THRESHOLD: usize = 256;

/// 디코드된 프레임. DATA/PARITY의 payload는 복호화된 버퍼를 빌려 쓴다(복사 없음).
#[derive(Debug)]
pub enum Frame<'a> {
    Hello { session: u64, version: u8 },
    HelloAck { session: u64 },
    Data { seq: u32, group: u16, gen: u16, index: u8, k: u8, payload: &'a [u8] },
    Parity { group: u16, gen: u16, k: u8, payload: &'a [u8] },
    Ping { token: u64 },
    Pong { token: u64 },
}

fn put_u16(v: &mut Vec<u8>, n: u16) { v.extend_from_slice(&n.to_le_bytes()); }
fn put_u32(v: &mut Vec<u8>, n: u32) { v.extend_from_slice(&n.to_le_bytes()); }
fn put_u64(v: &mut Vec<u8>, n: u64) { v.extend_from_slice(&n.to_le_bytes()); }

/// 프레임을 inner message(`[nonce8][ciphertext]`)로 만들어 out에 쓴다.
pub fn encode(frame: &Frame, key: &[u8; 32], dir: u8, out: &mut Vec<u8>) {
    out.clear();
    let mut nonce = [0u8; NONCE_LEN];
    super::rand_bytes(&mut nonce);
    out.extend_from_slice(&nonce);
    let body_start = out.len();

    let mut padit = true; // 컨트롤 프레임은 작아서 항상 패딩
    match *frame {
        Frame::Hello { session, version } => { out.push(HELLO); put_u64(out, session); out.push(version); }
        Frame::HelloAck { session } => { out.push(HELLO_ACK); put_u64(out, session); }
        Frame::Data { seq, group, gen, index, k, payload } => {
            out.push(DATA); put_u32(out, seq); put_u16(out, group); put_u16(out, gen);
            out.push(index); out.push(k); put_u16(out, payload.len() as u16);
            out.extend_from_slice(payload);
            padit = payload.len() < PAD_THRESHOLD;
        }
        Frame::Parity { group, gen, k, payload } => {
            out.push(PARITY); put_u16(out, group); put_u16(out, gen); out.push(k);
            put_u16(out, payload.len() as u16); out.extend_from_slice(payload);
            padit = payload.len() < PAD_THRESHOLD;
        }
        Frame::Ping { token } => { out.push(PING); put_u64(out, token); }
        Frame::Pong { token } => { out.push(PONG); put_u64(out, token); }
    }
    if padit {
        let mut r = [0u8; 1];
        super::rand_bytes(&mut r);
        let pad = (r[0] & 0x1f) as usize; // 0..=31 바이트. 복호화 뒤 무시된다(payload 길이로 자름)
        out.resize(out.len() + pad, 0);
    }
    obfs::apply(key, dir, &nonce, &mut out[body_start..]);
}

/// inner message를 제자리에서 복호화해 Frame으로 읽는다. 뒤에 붙은 패딩은 무시한다.
pub fn decode<'a>(msg: &'a mut [u8], key: &[u8; 32], dir: u8) -> Option<Frame<'a>> {
    if msg.len() < NONCE_LEN + 1 {
        return None;
    }
    let mut nonce = [0u8; NONCE_LEN];
    nonce.copy_from_slice(&msg[0..NONCE_LEN]);
    let body = &mut msg[NONCE_LEN..];
    obfs::apply(key, dir, &nonce, body);
    let (tag, rest) = body.split_first()?;
    match *tag {
        HELLO => Some(Frame::Hello {
            session: u64::from_le_bytes(rest.get(0..8)?.try_into().ok()?),
            version: *rest.get(8)?,
        }),
        HELLO_ACK => Some(Frame::HelloAck {
            session: u64::from_le_bytes(rest.get(0..8)?.try_into().ok()?),
        }),
        DATA => {
            let seq = u32::from_le_bytes(rest.get(0..4)?.try_into().ok()?);
            let group = u16::from_le_bytes(rest.get(4..6)?.try_into().ok()?);
            let gen = u16::from_le_bytes(rest.get(6..8)?.try_into().ok()?);
            let index = *rest.get(8)?;
            let k = *rest.get(9)?;
            let plen = u16::from_le_bytes(rest.get(10..12)?.try_into().ok()?) as usize;
            let payload = rest.get(12..12 + plen)?;
            Some(Frame::Data { seq, group, gen, index, k, payload })
        }
        PARITY => {
            let group = u16::from_le_bytes(rest.get(0..2)?.try_into().ok()?);
            let gen = u16::from_le_bytes(rest.get(2..4)?.try_into().ok()?);
            let k = *rest.get(4)?;
            let plen = u16::from_le_bytes(rest.get(5..7)?.try_into().ok()?) as usize;
            let payload = rest.get(7..7 + plen)?;
            Some(Frame::Parity { group, gen, k, payload })
        }
        PING => Some(Frame::Ping { token: u64::from_le_bytes(rest.get(0..8)?.try_into().ok()?) }),
        PONG => Some(Frame::Pong { token: u64::from_le_bytes(rest.get(0..8)?.try_into().ok()?) }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_roundtrip() {
        let key = obfs::derive_key(b"psk");
        let mut buf = Vec::new();
        encode(&Frame::Hello { session: 0xDEAD_BEEF_1234, version: PROTOCOL_VERSION }, &key, obfs::DIR_C2S, &mut buf);
        match decode(&mut buf, &key, obfs::DIR_C2S).unwrap() {
            Frame::Hello { session, version } => {
                assert_eq!(session, 0xDEAD_BEEF_1234);
                assert_eq!(version, PROTOCOL_VERSION);
            }
            other => panic!("wrong frame: {other:?}"),
        }
    }

    #[test]
    fn data_roundtrip_with_padding() {
        let key = obfs::derive_key(b"psk");
        let payload = b"inner wireguard datagram bytes"; // < 256 → 패딩됨
        let mut buf = Vec::new();
        encode(&Frame::Data { seq: 7, group: 3, gen: 2, index: 1, k: 4, payload }, &key, obfs::DIR_C2S, &mut buf);
        match decode(&mut buf, &key, obfs::DIR_C2S).unwrap() {
            Frame::Data { seq, group, gen, index, k, payload: p } => {
                assert_eq!((seq, group, gen, index, k), (7, 3, 2, 1, 4));
                assert_eq!(p, payload); // 패딩을 떼고 정확히 payload만
            }
            other => panic!("wrong frame: {other:?}"),
        }
    }

    #[test]
    fn large_data_not_padded() {
        let key = obfs::derive_key(b"psk");
        let payload = vec![0xABu8; 1300];
        let mut buf = Vec::new();
        encode(&Frame::Data { seq: 0, group: 0, gen: 0, index: 0, k: 8, payload: &payload }, &key, obfs::DIR_C2S, &mut buf);
        // 8(nonce) + 13(헤더: tag+seq+group+gen+index+k+plen) + 1300(payload), 패딩 없음
        assert_eq!(buf.len(), NONCE_LEN + 13 + 1300);
        match decode(&mut buf, &key, obfs::DIR_C2S).unwrap() {
            Frame::Data { payload: p, .. } => assert_eq!(p, &payload[..]),
            other => panic!("wrong frame: {other:?}"),
        }
    }

    #[test]
    fn nonce_is_random_each_call() {
        // 같은 프레임도 호출마다 nonce가 달라 선 위 바이트가 전부 달라진다(고정 지문 없음).
        let key = obfs::derive_key(b"psk");
        let mut a = Vec::new();
        let mut b = Vec::new();
        encode(&Frame::Ping { token: 1 }, &key, obfs::DIR_C2S, &mut a);
        encode(&Frame::Ping { token: 1 }, &key, obfs::DIR_C2S, &mut b);
        assert_ne!(a, b); // nonce(앞 8B)부터 다름
    }
}
