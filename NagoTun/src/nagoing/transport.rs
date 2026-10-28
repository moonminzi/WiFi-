//! nagoing 전송 계층 — inner message(`[nonce8][ciphertext]`)를 선 위로 나르는 두 가지 방법.
//!
//! - UDP(QUIC 모양): 데이터그램 하나 = 짧은 헤더(QUIC short-header 꼴) + inner message. 손실·지연이
//!   그대로 드러나므로 FEC가 의미 있다. UDP 443이 열린 망에서 가장 가볍고 빠르다.
//! - TCP(TLS 흉내): 접속 직후 ClientHello 모양 레코드를 보내고(서버는 ServerHello 모양으로 답),
//!   이후 application_data 레코드로 inner message를 나른다. TCP 443은 거의 안 막혀서 폴백에 쓴다.
//!
//! 여기 TLS/QUIC "모양"은 DPI를 지나가기 위한 **근사**다. 진짜 TLS 핸드셰이크/진짜 QUIC가 아니라,
//! 중간 장비가 첫 바이트·레코드 모양으로 분류할 때 HTTPS/QUIC로 보이게 하는 수준이다(운영용으로는
//! uTLS/실제 QUIC로 올리는 게 다음 단계). 안쪽 기밀성은 WireGuard가 책임지므로 이 흉내가 보안을 지진 않는다.
//!
//! 송신 반(TxHalf)과 수신 반(RxHalf)을 나눈 이유: 업로드 스레드(send)와 다운로드 스레드(recv)가 한 소켓을
//! 서로 막지 않게 하기 위해서다. UDP는 소켓을 try_clone으로 둘로, TCP도 스트림을 try_clone으로 둘로 쪼갠다.

use std::io::{self, Read, Write};
use std::net::{TcpStream, UdpSocket};

const MAX_MSG: usize = 2048;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Udp,
    Tcp,
}

// ── UDP (QUIC short-header 꼴) ────────────────────────────────────────────────
// 첫 바이트 0b01xxxxxx(0x40 세트) = QUIC short header 폼. 뒤에 4바이트 connection id.
const QUIC_FLAG: u8 = 0x41;
const QUIC_HDR: usize = 5;

pub fn udp_wrap(inner: &[u8], cid: u32, out: &mut Vec<u8>) {
    out.clear();
    out.push(QUIC_FLAG);
    out.extend_from_slice(&cid.to_be_bytes());
    out.extend_from_slice(inner);
}

/// 받은 데이터그램에서 inner message 부분을 돌려준다(헤더가 안 맞으면 None).
pub fn udp_unwrap(datagram: &[u8]) -> Option<&[u8]> {
    if datagram.len() < QUIC_HDR || datagram[0] & 0xC0 != 0x40 {
        return None;
    }
    Some(&datagram[QUIC_HDR..])
}

// ── TLS 레코드 ────────────────────────────────────────────────────────────────
const REC_HANDSHAKE: u8 = 0x16;
const REC_APPDATA: u8 = 0x17;

/// 레코드 하나로 payload를 감싼다. 길이는 TLS처럼 big-endian.
pub fn tls_record(content_type: u8, payload: &[u8], out: &mut Vec<u8>) {
    out.clear();
    out.push(content_type);
    out.extend_from_slice(&[0x03, 0x03]); // 레코드 버전(1.3도 레코드는 0x0303)
    out.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    out.extend_from_slice(payload);
}

/// ClientHello 모양 핸드셰이크 레코드(SNI 포함). 진짜 암호 협상은 아니고 모양만 맞춘다.
pub fn client_hello(sni: &str, random: &[u8; 32]) -> Vec<u8> {
    let name = sni.as_bytes();
    let mut sni_ext = Vec::new();
    sni_ext.extend_from_slice(&[0x00, 0x00]); // extension type: server_name
    let server_name_list_len = 3 + name.len();
    sni_ext.extend_from_slice(&((server_name_list_len + 2) as u16).to_be_bytes()); // ext length
    sni_ext.extend_from_slice(&(server_name_list_len as u16).to_be_bytes());       // list length
    sni_ext.push(0x00); // name type: host_name
    sni_ext.extend_from_slice(&(name.len() as u16).to_be_bytes());
    sni_ext.extend_from_slice(name);

    let mut hs = Vec::new();
    hs.extend_from_slice(&[0x03, 0x03]); // client_version
    hs.extend_from_slice(random);
    hs.push(0x00); // session_id length
    let suites: [u8; 6] = [0x13, 0x01, 0x13, 0x02, 0x00, 0xff];
    hs.extend_from_slice(&(suites.len() as u16).to_be_bytes());
    hs.extend_from_slice(&suites);
    hs.extend_from_slice(&[0x01, 0x00]); // compression: 1 method, null
    hs.extend_from_slice(&(sni_ext.len() as u16).to_be_bytes());
    hs.extend_from_slice(&sni_ext);

    let mut body = Vec::new();
    body.push(0x01); // client_hello
    let l = hs.len();
    body.extend_from_slice(&[(l >> 16) as u8, (l >> 8) as u8, l as u8]);
    body.extend_from_slice(&hs);

    let mut rec = Vec::new();
    rec.push(REC_HANDSHAKE);
    rec.extend_from_slice(&[0x03, 0x01]); // ClientHello 레코드 버전은 보통 0x0301
    rec.extend_from_slice(&(body.len() as u16).to_be_bytes());
    rec.extend_from_slice(&body);
    rec
}

/// ServerHello 모양 핸드셰이크 레코드(최소 구성).
pub fn server_hello(random: &[u8; 32]) -> Vec<u8> {
    let mut hs = Vec::new();
    hs.extend_from_slice(&[0x03, 0x03]);
    hs.extend_from_slice(random);
    hs.push(0x00);
    hs.extend_from_slice(&[0x13, 0x01]);
    hs.push(0x00);
    hs.extend_from_slice(&[0x00, 0x00]);

    let mut body = Vec::new();
    body.push(0x02); // server_hello
    let l = hs.len();
    body.extend_from_slice(&[(l >> 16) as u8, (l >> 8) as u8, l as u8]);
    body.extend_from_slice(&hs);

    let mut rec = Vec::new();
    rec.push(REC_HANDSHAKE);
    rec.extend_from_slice(&[0x03, 0x03]);
    rec.extend_from_slice(&(body.len() as u16).to_be_bytes());
    rec.extend_from_slice(&body);
    rec
}

pub const RECORD_APPDATA: u8 = REC_APPDATA;

// ── 송신/수신 반 ──────────────────────────────────────────────────────────────

pub trait TxHalf: Send {
    fn send_msg(&mut self, inner: &[u8]) -> io::Result<()>;
}

pub trait RxHalf: Send {
    /// inner message 하나를 받아 buf에 쓰고 길이를 돌려준다. 읽기 타임아웃이면 WouldBlock/TimedOut.
    fn recv_msg(&mut self, buf: &mut [u8]) -> io::Result<usize>;
}

pub struct UdpTx {
    sock: UdpSocket,
    cid: u32,
    scratch: Vec<u8>,
}

impl UdpTx {
    pub fn new(sock: UdpSocket, cid: u32) -> Self {
        UdpTx { sock, cid, scratch: Vec::new() }
    }
}

impl TxHalf for UdpTx {
    fn send_msg(&mut self, inner: &[u8]) -> io::Result<()> {
        udp_wrap(inner, self.cid, &mut self.scratch);
        self.sock.send(&self.scratch)?;
        Ok(())
    }
}

pub struct UdpRx {
    sock: UdpSocket,
    rbuf: [u8; MAX_MSG + QUIC_HDR],
}

impl UdpRx {
    pub fn new(sock: UdpSocket) -> Self {
        UdpRx { sock, rbuf: [0u8; MAX_MSG + QUIC_HDR] }
    }
}

impl RxHalf for UdpRx {
    fn recv_msg(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.sock.recv(&mut self.rbuf)?;
        let inner = udp_unwrap(&self.rbuf[..n])
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "bad udp header"))?;
        if inner.len() > buf.len() {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "msg too large"));
        }
        buf[..inner.len()].copy_from_slice(inner);
        Ok(inner.len())
    }
}

pub struct TcpTx {
    stream: TcpStream,
    scratch: Vec<u8>,
}

impl TcpTx {
    pub fn new(stream: TcpStream) -> Self {
        TcpTx { stream, scratch: Vec::new() }
    }
    /// 완성된 레코드(예: ServerHello)를 그대로 보낸다.
    pub fn send_raw(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.stream.write_all(bytes)
    }
}

impl TxHalf for TcpTx {
    fn send_msg(&mut self, inner: &[u8]) -> io::Result<()> {
        tls_record(REC_APPDATA, inner, &mut self.scratch);
        self.stream.write_all(&self.scratch)
    }
}

/// TLS 레코드를 버퍼에 모아 하나씩 떼어 주는 수신 반. 읽기 타임아웃으로 중간에 끊겨도
/// 받은 바이트를 들고 있다가 이어 붙이므로 프레임이 깨지지 않는다(짧은 타임아웃으로 종료 폴링 가능).
pub struct TcpRx {
    stream: TcpStream,
    acc: Vec<u8>,
    tmp: [u8; 4096],
}

impl TcpRx {
    pub fn new(stream: TcpStream) -> Self {
        TcpRx { stream, acc: Vec::new(), tmp: [0u8; 4096] }
    }
}

impl RxHalf for TcpRx {
    fn recv_msg(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            if self.acc.len() >= 5 {
                let len = u16::from_be_bytes([self.acc[3], self.acc[4]]) as usize;
                if len > buf.len() {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "tls record too large"));
                }
                if self.acc.len() >= 5 + len {
                    buf[..len].copy_from_slice(&self.acc[5..5 + len]);
                    self.acc.drain(0..5 + len);
                    return Ok(len);
                }
            }
            match self.stream.read(&mut self.tmp) {
                Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "peer closed")),
                Ok(n) => self.acc.extend_from_slice(&self.tmp[..n]),
                Err(e) => return Err(e), // WouldBlock/TimedOut 포함 — 호출자가 '아직 없음'으로 처리
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn udp_wrap_unwrap() {
        let mut out = Vec::new();
        udp_wrap(b"hello inner", 0x11223344, &mut out);
        assert_eq!(out[0] & 0xC0, 0x40);
        assert_eq!(udp_unwrap(&out).unwrap(), b"hello inner");
        assert!(udp_unwrap(b"\x00ab").is_none());
    }

    #[test]
    fn tls_record_shape() {
        let mut out = Vec::new();
        tls_record(REC_APPDATA, b"payload", &mut out);
        assert_eq!(out[0], 0x17);
        assert_eq!(&out[1..3], &[0x03, 0x03]);
        assert_eq!(u16::from_be_bytes([out[3], out[4]]) as usize, 7);
        assert_eq!(&out[5..], b"payload");
    }

    #[test]
    fn client_hello_has_sni() {
        let ch = client_hello("www.cloudflare.com", &[0u8; 32]);
        assert_eq!(ch[0], REC_HANDSHAKE);
        assert_eq!(ch[5], 0x01);
        let needle = b"www.cloudflare.com";
        assert!(ch.windows(needle.len()).any(|w| w == needle));
    }
}
