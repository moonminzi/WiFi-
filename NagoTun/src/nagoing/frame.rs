//! nagoing 프레임 코덱 — 전송 위로 오가는 한 "메시지"를 만들고 읽는다.
//!
//! 선 위의 한 메시지(inner message) 모양: `[nonce: 8B][ciphertext]`.
//! ciphertext는 아래 Frame 본문을 obfs(ChaCha20)로 가린 것. nonce 8바이트는 평문으로 실어
//! 수신 측이 같은 keystream을 만들 수 있게 한다(dir는 송신 측과 합의한 상수).
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

/// 디코드된 프레임. DATA/PARITY의 payload는 복호화된 버퍼를 빌려 쓴다(복사 없음).
#[derive(Debug)]
pub enum Frame<'a> {
    Hello { session: u64, version: u8 },
    HelloAck { session: u64 },
    /// FEC 데이터 조각. group/gen/index/k로 어느 그룹의 몇 번째인지 알린다. payload = 안쪽 WG 데이터그램.
    Data { seq: u32, group: u16, gen: u16, index: u8, k: u8, payload: &'a [u8] },
    /// FEC 패리티 조각. payload = 그룹 안 데이터들의 (길이프리픽스+패딩) XOR.
    Parity { group: u16, gen: u16, k: u8, payload: &'a [u8] },
    Ping { token: u64 },
    Pong { token: u64 },
}

fn put_u16(v: &mut Vec<u8>, n: u16) { v.extend_from_slice(&n.to_le_bytes()); }
fn put_u32(v: &mut Vec<u8>, n: u32) { v.extend_from_slice(&n.to_le_bytes()); }
fn put_u64(v: &mut Vec<u8>, n: u64) { v.extend_from_slice(&n.to_le_bytes()); }

/// 프레임을 inner message(`[nonce8][ciphertext]`)로 만들어 out에 쓴다.
/// nonce 8바이트는 (dir, counter)에서 나오는 것과 같아야 수신 측이 복호화할 수 있다 → counter를 그대로 싣는다.
pub fn encode(frame: &Frame, key: &[u8; 32], dir: u8, counter: u64, out: &mut Vec<u8>) {
    out.clear();
    // nonce: counter 8바이트를 평문으로(= obfs::apply에 넘기는 counter와 동일)
    out.extend_from_slice(&counter.to_le_bytes());
    let body_start = out.len();
    match *frame {
        Frame::Hello { session, version } => { out.push(HELLO); put_u64(out, session); out.push(version); }
        Frame::HelloAck { session } => { out.push(HELLO_ACK); put_u64(out, session); }
        Frame::Data { seq, group, gen, index, k, payload } => {
            out.push(DATA); put_u32(out, seq); put_u16(out, group); put_u16(out, gen);
            out.push(index); out.push(k); out.extend_from_slice(payload);
        }
        Frame::Parity { group, gen, k, payload } => {
            out.push(PARITY); put_u16(out, group); put_u16(out, gen); out.push(k);
            out.extend_from_slice(payload);
        }
        Frame::Ping { token } => { out.push(PING); put_u64(out, token); }
        Frame::Pong { token } => { out.push(PONG); put_u64(out, token); }
    }
    obfs::apply(key, dir, counter, &mut out[body_start..]);
}

/// inner message를 제자리에서 복호화해 Frame으로 읽는다. dir는 송신 측 방향(수신자 기준 반대).
/// msg는 `[nonce8][ciphertext]`. 복호화 후 Frame이 msg 뒷부분을 빌린다.
pub fn decode<'a>(msg: &'a mut [u8], key: &[u8; 32], dir: u8) -> Option<Frame<'a>> {
    if msg.len() < NONCE_LEN + 1 {
        return None;
    }
    let counter = u64::from_le_bytes(msg[0..8].try_into().ok()?);
    let body = &mut msg[NONCE_LEN..];
    obfs::apply(key, dir, counter, body);
    let (tag, rest) = body.split_first()?;
    match *tag {
        HELLO => {
            let session = u64::from_le_bytes(rest.get(0..8)?.try_into().ok()?);
            let version = *rest.get(8)?;
            Some(Frame::Hello { session, version })
        }
        HELLO_ACK => {
            let session = u64::from_le_bytes(rest.get(0..8)?.try_into().ok()?);
            Some(Frame::HelloAck { session })
        }
        DATA => {
            let seq = u32::from_le_bytes(rest.get(0..4)?.try_into().ok()?);
            let group = u16::from_le_bytes(rest.get(4..6)?.try_into().ok()?);
            let gen = u16::from_le_bytes(rest.get(6..8)?.try_into().ok()?);
            let index = *rest.get(8)?;
            let k = *rest.get(9)?;
            let payload = rest.get(10..)?;
            Some(Frame::Data { seq, group, gen, index, k, payload })
        }
        PARITY => {
            let group = u16::from_le_bytes(rest.get(0..2)?.try_into().ok()?);
            let gen = u16::from_le_bytes(rest.get(2..4)?.try_into().ok()?);
            let k = *rest.get(4)?;
            let payload = rest.get(5..)?;
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

    fn roundtrip(frame: Frame) -> Vec<u8> {
        let key = obfs::derive_key(b"psk");
        let mut buf = Vec::new();
        encode(&frame, &key, obfs::DIR_C2S, 123, &mut buf);
        buf
    }

    #[test]
    fn hello_roundtrip() {
        let mut buf = roundtrip(Frame::Hello { session: 0xDEAD_BEEF_1234, version: PROTOCOL_VERSION });
        let key = obfs::derive_key(b"psk");
        match decode(&mut buf, &key, obfs::DIR_C2S).unwrap() {
            Frame::Hello { session, version } => {
                assert_eq!(session, 0xDEAD_BEEF_1234);
                assert_eq!(version, PROTOCOL_VERSION);
            }
            other => panic!("wrong frame: {other:?}"),
        }
    }

    #[test]
    fn data_roundtrip() {
        let payload = b"inner wireguard datagram bytes";
        let mut buf = roundtrip(Frame::Data { seq: 7, group: 3, gen: 2, index: 1, k: 4, payload });
        let key = obfs::derive_key(b"psk");
        match decode(&mut buf, &key, obfs::DIR_C2S).unwrap() {
            Frame::Data { seq, group, gen, index, k, payload: p } => {
                assert_eq!((seq, group, gen, index, k), (7, 3, 2, 1, 4));
                assert_eq!(p, payload);
            }
            other => panic!("wrong frame: {other:?}"),
        }
    }

    #[test]
    fn wrong_key_or_dir_does_not_decode_cleanly() {
        // 다른 키로 복호화하면 tag가 깨져 보통 None이 된다(무작위 바이트 → 알 수 없는 tag).
        let mut buf = roundtrip(Frame::Ping { token: 1 });
        let other = obfs::derive_key(b"different");
        // 깨진 해석이 유효한 Ping이 되는 일은 사실상 없다.
        let got = decode(&mut buf, &other, obfs::DIR_C2S);
        assert!(!matches!(got, Some(Frame::Ping { token: 1 })));
    }

    #[test]
    fn on_wire_has_no_fixed_header() {
        // 같은 프레임도 counter(nonce)가 다르면 본문 바이트가 달라져 고정 패턴이 안 보인다.
        let key = obfs::derive_key(b"psk");
        let mut a = Vec::new();
        let mut b = Vec::new();
        encode(&Frame::Data { seq: 0, group: 0, gen: 0, index: 0, k: 4, payload: &[0u8; 16] }, &key, obfs::DIR_C2S, 1, &mut a);
        encode(&Frame::Data { seq: 0, group: 0, gen: 0, index: 0, k: 4, payload: &[0u8; 16] }, &key, obfs::DIR_C2S, 2, &mut b);
        assert_ne!(&a[NONCE_LEN..], &b[NONCE_LEN..]);
    }
}
