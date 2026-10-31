//! nagoing 프레임 코덱 — 세션 AEAD가 봉인할 **평문** 프레임을 만들고 읽는다.
//!
//! v2에서 암호화·무결성·리플레이 방어는 crypto.rs의 세션 키가 맡고, 핸드셰이크(HELLO/ACK)도 거기서 따로 다룬다.
//! 여기는 데이터 평면의 프레임 모양만: DATA(FEC 메타 + WG 데이터그램), PARITY, PING/PONG.
//!
//! 컨트롤 프레임과 작은 DATA(WG 핸드셰이크 148/92·keepalive)에는 무작위 길이 패딩을 붙여 크기 지문을 가린다
//! (암호문 길이가 평문 길이를 그대로 드러내므로). 대용량 DATA는 처리량을 위해 패딩하지 않는다.

pub const DATA: u8 = 0x10;
pub const PARITY: u8 = 0x11;
pub const PING: u8 = 0x20;
pub const PONG: u8 = 0x21;

/// 패딩을 붙일 기준(이보다 작은 payload만). WG 핸드셰이크(148/92)·keepalive를 덮고, 대용량은 안 건드린다.
const PAD_THRESHOLD: usize = 256;

/// 디코드된 프레임. DATA/PARITY의 payload는 복호화된 버퍼를 빌려 쓴다(복사 없음).
#[derive(Debug)]
pub enum Frame<'a> {
    Data { group: u16, gen: u16, index: u8, k: u8, payload: &'a [u8] },
    Parity { group: u16, gen: u16, k: u8, payload: &'a [u8] },
    Ping { token: u64 },
    Pong { token: u64 },
}

fn put_u16(v: &mut Vec<u8>, n: u16) {
    v.extend_from_slice(&n.to_le_bytes());
}

/// 프레임을 평문으로 out에 쓴다(봉인은 호출자가 SessionKeys::seal로).
pub fn encode(frame: &Frame, out: &mut Vec<u8>) {
    out.clear();
    let mut padit = true; // 컨트롤 프레임은 작아서 항상 패딩
    match *frame {
        Frame::Data { group, gen, index, k, payload } => {
            out.push(DATA);
            put_u16(out, group);
            put_u16(out, gen);
            out.push(index);
            out.push(k);
            put_u16(out, payload.len() as u16);
            out.extend_from_slice(payload);
            padit = payload.len() < PAD_THRESHOLD;
        }
        Frame::Parity { group, gen, k, payload } => {
            out.push(PARITY);
            put_u16(out, group);
            put_u16(out, gen);
            out.push(k);
            put_u16(out, payload.len() as u16);
            out.extend_from_slice(payload);
            padit = payload.len() < PAD_THRESHOLD;
        }
        Frame::Ping { token } => {
            out.push(PING);
            out.extend_from_slice(&token.to_le_bytes());
        }
        Frame::Pong { token } => {
            out.push(PONG);
            out.extend_from_slice(&token.to_le_bytes());
        }
    }
    if padit {
        let mut r = [0u8; 1];
        super::rand_bytes(&mut r);
        let pad = (r[0] & 0x1f) as usize; // 0..=31 바이트. 읽을 때 payload 길이로 잘라 무시된다
        out.resize(out.len() + pad, 0);
    }
}

/// 평문 프레임을 읽는다. 뒤에 붙은 패딩은 무시한다.
pub fn decode(body: &[u8]) -> Option<Frame<'_>> {
    let (tag, rest) = body.split_first()?;
    let u16_at = |i: usize| -> Option<u16> { Some(u16::from_le_bytes(rest.get(i..i + 2)?.try_into().ok()?)) };
    let u64_at = |i: usize| -> Option<u64> { Some(u64::from_le_bytes(rest.get(i..i + 8)?.try_into().ok()?)) };
    match *tag {
        DATA => {
            let plen = u16_at(6)? as usize;
            Some(Frame::Data {
                group: u16_at(0)?,
                gen: u16_at(2)?,
                index: *rest.get(4)?,
                k: *rest.get(5)?,
                payload: rest.get(8..8 + plen)?,
            })
        }
        PARITY => {
            let plen = u16_at(5)? as usize;
            Some(Frame::Parity { group: u16_at(0)?, gen: u16_at(2)?, k: *rest.get(4)?, payload: rest.get(7..7 + plen)? })
        }
        PING => Some(Frame::Ping { token: u64_at(0)? }),
        PONG => Some(Frame::Pong { token: u64_at(0)? }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_roundtrip_with_padding() {
        let payload = b"inner wireguard datagram bytes"; // < 256 → 패딩됨
        let mut buf = Vec::new();
        encode(&Frame::Data { group: 3, gen: 2, index: 1, k: 4, payload }, &mut buf);
        match decode(&buf).unwrap() {
            Frame::Data { group, gen, index, k, payload: p } => {
                assert_eq!((group, gen, index, k), (3, 2, 1, 4));
                assert_eq!(p, payload); // 패딩을 떼고 정확히 payload만
            }
            other => panic!("wrong frame: {other:?}"),
        }
    }

    #[test]
    fn large_data_not_padded() {
        let payload = vec![0xABu8; 1300];
        let mut buf = Vec::new();
        encode(&Frame::Data { group: 0, gen: 0, index: 0, k: 8, payload: &payload }, &mut buf);
        // 9(헤더: tag+group+gen+index+k+plen) + 1300(payload), 패딩 없음
        assert_eq!(buf.len(), 9 + 1300);
        match decode(&buf).unwrap() {
            Frame::Data { payload: p, .. } => assert_eq!(p, &payload[..]),
            other => panic!("wrong frame: {other:?}"),
        }
    }

    #[test]
    fn parity_and_ping_roundtrip() {
        let mut buf = Vec::new();
        encode(&Frame::Parity { group: 7, gen: 9, k: 3, payload: b"xor" }, &mut buf);
        assert!(matches!(decode(&buf), Some(Frame::Parity { group: 7, gen: 9, k: 3, payload: b"xor" })));
        encode(&Frame::Ping { token: 77 }, &mut buf);
        assert!(matches!(decode(&buf), Some(Frame::Ping { token: 77 })));
        assert!(decode(&[0x99, 1, 2]).is_none());
        assert!(decode(&[DATA, 0, 0]).is_none()); // 잘린 프레임
    }
}
