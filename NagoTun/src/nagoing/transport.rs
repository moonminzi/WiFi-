//! nagoing 전송 계층 — 봉인된 메시지(핸드셰이크 / 데이터)를 선 위로 나르는 두 가지 방법.
//!
//! - UDP(QUIC 모양): 핸드셰이크는 QUIC long header(Initial처럼 버전 1·연결 ID·길이)로, 클라 HELLO는 진짜
//!   QUIC Initial처럼 1200바이트로 채운다. 데이터는 QUIC short header(`0b01xxxxxx` + 4바이트 연결 ID).
//!   손실·지연이 그대로 드러나므로 FEC가 의미 있다.
//! - TCP(진짜 TLS 1.3, rustls): 흉내가 아니라 실제 TLS 핸드셰이크를 한다. 선 위에는 진짜 ClientHello(SNI·ALPN)와
//!   암호화된 레코드만 보이고, TLS 1.3이라 서버 인증서도 암호화된다. 그 안에서 `[len u16][kind][body]`로 메시지를
//!   나눈다. 클라는 인증서를 검증하지 않는다(서버마다 자체서명) — 서버 인증은 안쪽 HELLO_ACK의 MAC(서버 WG 키)이
//!   맡으므로 TLS를 가로채도 세션을 못 만든다. 서버는 nagoing이 아닌 접속(능동 탐침)에 HTTP 404를 돌려준다.
//!
//! 송신 반(TxHalf)과 수신 반(RxHalf)을 나눈 이유: 업로드 스레드와 다운로드 스레드가 한 연결을 서로 막지 않게.
//! UDP는 소켓을 둘로, TLS는 연결 상태(rustls)를 잠금으로 공유하고 소켓만 둘로 쪼갠다.

use std::io::{self, Read, Write};
use std::net::{TcpStream, UdpSocket};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{ring as tls_ring, verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::{Connection, DigitallySignedStruct, SignatureScheme};

const MAX_MSG: usize = 2048;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Udp,
    Tcp,
}

/// 메시지 종류. 핸드셰이크(HELLO/ACK)는 PSK로, 데이터는 세션 키로 열어야 해서 받는 쪽이 미리 안다.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MsgKind {
    Handshake,
    Data,
}

fn invalid(msg: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

// ── UDP (QUIC 모양) ───────────────────────────────────────────────────────────

/// short header: 첫 바이트 `0b01xxxxxx`(하위 6비트 무작위) + 4바이트 연결 ID.
pub const SHORT_HDR: usize = 5;
/// long header: 첫 바이트 + 버전 4 + DCID 길이·8 + SCID 길이·8 + 토큰 길이 1 + 길이 2.
pub const LONG_HDR: usize = 1 + 4 + 1 + 8 + 1 + 8 + 1 + 2;
/// 클라 HELLO가 든 UDP 데이터그램 크기(QUIC Initial 최소 크기와 같게).
pub const QUIC_INITIAL_SIZE: usize = 1200;

pub fn udp_wrap(kind: MsgKind, inner: &[u8], cid: u32, out: &mut Vec<u8>) {
    out.clear();
    let mut r = [0u8; 13];
    super::rand_bytes(&mut r);
    match kind {
        MsgKind::Data => {
            out.push(0x40 | (r[0] & 0x3f));
            out.extend_from_slice(&cid.to_be_bytes());
        }
        MsgKind::Handshake => {
            out.push(0xC0 | (r[0] & 0x03)); // long header, Initial, 패킷 번호 길이 비트
            out.extend_from_slice(&1u32.to_be_bytes()); // QUIC v1
            out.push(8);
            out.extend_from_slice(&cid.to_be_bytes()); // DCID 앞 4바이트 = 연결 ID(세션 찾기용)
            out.extend_from_slice(&r[1..5]);
            out.push(8);
            out.extend_from_slice(&r[5..13]); // SCID
            out.push(0); // 토큰 없음
            out.extend_from_slice(&(0x4000u16 | inner.len() as u16).to_be_bytes()); // 2바이트 varint 길이
        }
    }
    out.extend_from_slice(inner);
}

/// 데이터그램을 읽어 (종류, 연결 ID, 안쪽 메시지). 모양이 안 맞으면 None.
pub fn udp_parse(d: &[u8]) -> Option<(MsgKind, u32, &[u8])> {
    let cid = |b: &[u8]| u32::from_be_bytes([b[0], b[1], b[2], b[3]]);
    match d.first()? & 0xC0 {
        0x40 if d.len() >= SHORT_HDR => Some((MsgKind::Data, cid(&d[1..5]), &d[SHORT_HDR..])),
        0xC0 if d.len() >= LONG_HDR => {
            if d[1..5] != [0, 0, 0, 1] || d[5] != 8 || d[14] != 8 || d[23] != 0 || d[24] & 0xC0 != 0x40 {
                return None;
            }
            let len = (u16::from_be_bytes([d[24], d[25]]) & 0x3fff) as usize;
            let inner = d.get(LONG_HDR..LONG_HDR + len)?;
            Some((MsgKind::Handshake, cid(&d[6..10]), inner))
        }
        _ => None,
    }
}

// ── 송신/수신 반 ──────────────────────────────────────────────────────────────

pub trait TxHalf: Send {
    fn send_msg(&mut self, kind: MsgKind, inner: &[u8]) -> io::Result<()>;
}

pub trait RxHalf: Send {
    /// 메시지 하나를 받아 buf에 쓰고 (종류, 길이)를 돌려준다. 읽기 타임아웃이면 WouldBlock/TimedOut.
    fn recv_msg(&mut self, buf: &mut [u8]) -> io::Result<(MsgKind, usize)>;
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
    fn send_msg(&mut self, kind: MsgKind, inner: &[u8]) -> io::Result<()> {
        udp_wrap(kind, inner, self.cid, &mut self.scratch);
        self.sock.send(&self.scratch)?;
        Ok(())
    }
}

pub struct UdpRx {
    sock: UdpSocket,
    rbuf: [u8; MAX_MSG + LONG_HDR],
}

impl UdpRx {
    pub fn new(sock: UdpSocket) -> Self {
        UdpRx { sock, rbuf: [0u8; MAX_MSG + LONG_HDR] }
    }
}

impl RxHalf for UdpRx {
    fn recv_msg(&mut self, buf: &mut [u8]) -> io::Result<(MsgKind, usize)> {
        // 모양이 안 맞는 데이터그램은 버리고 다음 것을 기다린다. UDP에선 패킷 하나가 이상하다고 전송이 깨진 게
        // 아니므로, 에러로 올려 재접속(rebind)을 부르지 않는다. 기다림은 소켓 읽기 제한(타임아웃)이 끊는다.
        loop {
            let n = self.sock.recv(&mut self.rbuf)?;
            let Some((kind, _, inner)) = udp_parse(&self.rbuf[..n]) else { continue };
            if inner.len() > buf.len() {
                continue;
            }
            buf[..inner.len()].copy_from_slice(inner);
            return Ok((kind, inner.len()));
        }
    }
}

// ── TLS 1.3 (rustls) ──────────────────────────────────────────────────────────

fn provider() -> Arc<CryptoProvider> {
    static P: OnceLock<Arc<CryptoProvider>> = OnceLock::new();
    P.get_or_init(|| Arc::new(tls_ring::default_provider())).clone()
}

/// 인증서는 믿지 않되(서버마다 자체서명) 서명 자체는 검사하는 검증기. 서버 인증은 안쪽 HELLO_ACK MAC이 맡는다.
#[derive(Debug)]
struct AnyCert(Arc<CryptoProvider>);

impl ServerCertVerifier for AnyCert {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

pub(crate) fn client_config() -> io::Result<Arc<rustls::ClientConfig>> {
    static C: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    if let Some(c) = C.get() {
        return Ok(c.clone());
    }
    let p = provider();
    let mut cfg = rustls::ClientConfig::builder_with_provider(p.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|_| invalid("tls versions"))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AnyCert(p)))
        .with_no_client_auth();
    // 브라우저처럼 h2·http/1.1을 제안한다(서버는 http/1.1을 고른다).
    cfg.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok(C.get_or_init(|| Arc::new(cfg)).clone())
}

/// 서버 TLS 설정. 인증서·키는 PEM(setup-nagoing.sh가 서버마다 만든 자체서명).
pub fn tls_server_config(cert_pem: &[u8], key_pem: &[u8]) -> io::Result<Arc<rustls::ServerConfig>> {
    use rustls::pki_types::pem::PemObject;
    let certs: Vec<CertificateDer<'static>> = CertificateDer::pem_slice_iter(cert_pem)
        .collect::<Result<_, _>>()
        .map_err(|_| invalid("bad tls cert pem"))?;
    if certs.is_empty() {
        return Err(invalid("no tls cert"));
    }
    let key = PrivateKeyDer::from_pem_slice(key_pem).map_err(|_| invalid("bad tls key pem"))?;
    let mut cfg = rustls::ServerConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|_| invalid("tls versions"))?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|_| invalid("tls cert/key mismatch"))?;
    cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(Arc::new(cfg))
}

/// 한 TLS 연결의 공유 상태. 쓰기는 이 소켓으로(쓰기 제한이 걸린), 읽기는 TlsRx가 든 복제 소켓으로.
struct TlsShared {
    conn: Mutex<Connection>,
    sock: TcpStream,
}

impl TlsShared {
    fn flush(conn: &mut Connection, mut sock: &TcpStream) -> io::Result<()> {
        while conn.wants_write() {
            conn.write_tls(&mut sock)?;
        }
        Ok(())
    }

    fn shutdown(&self) {
        let _ = self.sock.shutdown(std::net::Shutdown::Both);
    }
}

pub struct TlsTx {
    shared: Arc<TlsShared>,
    scratch: Vec<u8>,
}

impl TlsTx {
    /// 프레이밍 없이 평문을 보내고 연결을 닫는다(능동 탐침에 HTTP 응답을 줄 때).
    pub fn send_plain_and_close(&mut self, bytes: &[u8]) {
        let mut conn = self.shared.conn.lock().unwrap();
        let _ = conn.writer().write_all(bytes);
        conn.send_close_notify();
        let _ = TlsShared::flush(&mut conn, &self.shared.sock);
        drop(conn);
        self.shared.shutdown();
    }

    /// 연결을 끊는다(어긋났거나 끝낼 때). 같은 소켓을 읽는 TlsRx도 곧 EOF/에러로 빠져나간다.
    pub fn shutdown(&self) {
        self.shared.shutdown();
    }
}

impl TxHalf for TlsTx {
    fn send_msg(&mut self, kind: MsgKind, inner: &[u8]) -> io::Result<()> {
        self.scratch.clear();
        self.scratch.extend_from_slice(&((inner.len() + 1) as u16).to_be_bytes());
        self.scratch.push(match kind {
            MsgKind::Handshake => 1,
            MsgKind::Data => 2,
        });
        self.scratch.extend_from_slice(inner);
        let mut conn = self.shared.conn.lock().unwrap();
        let res = conn.writer().write_all(&self.scratch).and_then(|_| TlsShared::flush(&mut conn, &self.shared.sock));
        drop(conn);
        if res.is_err() {
            // 쓰기가 TLS 레코드 중간에 끊기면 스트림이 어긋나 다시 못 쓴다 → 닫는다.
            self.shared.shutdown();
        }
        res
    }
}

pub struct TlsRx {
    shared: Arc<TlsShared>,
    rsock: TcpStream,
    acc: Vec<u8>,
    tmp: Box<[u8; 16384]>,
    eof: bool,
}

impl TlsRx {
    /// 버퍼에 완성된 메시지가 있으면 꺼낸다. 길이가 말이 안 되면 InvalidData(=nagoing이 아닌 상대).
    fn take(&mut self, buf: &mut [u8]) -> io::Result<Option<(MsgKind, usize)>> {
        if self.acc.len() < 2 {
            return Ok(None);
        }
        let len = u16::from_be_bytes([self.acc[0], self.acc[1]]) as usize;
        if len == 0 || len > buf.len() + 1 || len > MAX_MSG + 1 {
            return Err(invalid("bad frame length"));
        }
        if self.acc.len() < 2 + len {
            return Ok(None);
        }
        let kind = match self.acc[2] {
            1 => MsgKind::Handshake,
            2 => MsgKind::Data,
            _ => return Err(invalid("bad frame kind")),
        };
        let n = len - 1;
        buf[..n].copy_from_slice(&self.acc[3..3 + n]);
        self.acc.drain(..2 + len);
        Ok(Some((kind, n)))
    }
}

impl TlsRx {
    /// rustls가 풀어 둔 평문을 모두 꺼내 acc에 붙인다(필드를 따로 받아 tmp 빌림과 겹치지 않게).
    fn drain(acc: &mut Vec<u8>, eof: &mut bool, conn: &mut Connection) -> io::Result<()> {
        let mut pt = [0u8; 4096];
        loop {
            match conn.reader().read(&mut pt) {
                Ok(0) => {
                    *eof = true; // close_notify
                    return Ok(());
                }
                Ok(k) => acc.extend_from_slice(&pt[..k]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(e) => return Err(e),
            }
        }
    }
}

impl RxHalf for TlsRx {
    fn recv_msg(&mut self, buf: &mut [u8]) -> io::Result<(MsgKind, usize)> {
        let shared = self.shared.clone();
        loop {
            if let Some(m) = self.take(buf)? {
                return Ok(m);
            }
            // 핸드셰이크를 마칠 때 같이 읽힌 첫 데이터처럼, rustls 안에 이미 풀린 평문이 있을 수 있다.
            {
                let mut conn = shared.conn.lock().unwrap();
                Self::drain(&mut self.acc, &mut self.eof, &mut conn)?;
            }
            if let Some(m) = self.take(buf)? {
                return Ok(m);
            }
            if self.eof {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "peer closed"));
            }
            // 소켓 읽기는 잠금 밖에서(보내는 쪽을 막지 않게). 타임아웃이면 그대로 올린다('아직 없음').
            let n = self.rsock.read(&mut self.tmp[..])?;
            if n == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "peer closed"));
            }
            let mut conn = shared.conn.lock().unwrap();
            let mut rd: &[u8] = &self.tmp[..n];
            while !rd.is_empty() {
                conn.read_tls(&mut rd)?;
                conn.process_new_packets().map_err(|_| invalid("tls error"))?;
                Self::drain(&mut self.acc, &mut self.eof, &mut conn)?;
            }
            // 받은 것에 답할 게 있으면(키 갱신 등) 보낸다.
            TlsShared::flush(&mut conn, &shared.sock)?;
        }
    }
}

/// 핸드셰이크를 마치고 송신·수신 반으로 나눈다. 스트림의 읽기 제한(짧게)으로 데드라인을 확인한다.
/// `cancel`이 true를 돌려주면(프록시 stop) 데드라인 전이라도 그만둔다.
fn finish(conn: Connection, mut stream: TcpStream, deadline: Instant, cancel: &dyn Fn() -> bool) -> io::Result<(TlsTx, TlsRx)> {
    let mut conn = conn;
    while conn.is_handshaking() {
        if cancel() {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "stopped"));
        }
        if Instant::now() > deadline {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "tls handshake timeout"));
        }
        match conn.complete_io(&mut stream) {
            Ok(_) => {}
            Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => {}
            Err(e) => return Err(e),
        }
    }
    let rsock = stream.try_clone()?;
    let shared = Arc::new(TlsShared { conn: Mutex::new(conn), sock: stream });
    Ok((
        TlsTx { shared: shared.clone(), scratch: Vec::new() },
        TlsRx { shared, rsock, acc: Vec::new(), tmp: Box::new([0u8; 16384]), eof: false },
    ))
}

/// 클라 쪽 TLS 1.3. sni가 도메인이 아니면(빈 값·IP) SNI 없이 서버 IP로.
pub fn tls_client(stream: TcpStream, sni: &str, deadline: Instant, cancel: &dyn Fn() -> bool) -> io::Result<(TlsTx, TlsRx)> {
    let name = ServerName::try_from(sni.to_owned())
        .or_else(|_| stream.peer_addr().map(|a| ServerName::IpAddress(a.ip().into())))
        .map_err(|_| invalid("bad sni"))?;
    let conn = rustls::ClientConnection::new(client_config()?, name).map_err(|_| invalid("tls client"))?;
    finish(Connection::Client(conn), stream, deadline, cancel)
}

/// 서버 쪽 TLS 1.3.
pub fn tls_server(
    stream: TcpStream,
    cfg: Arc<rustls::ServerConfig>,
    deadline: Instant,
    cancel: &dyn Fn() -> bool,
) -> io::Result<(TlsTx, TlsRx)> {
    let conn = rustls::ServerConnection::new(cfg).map_err(|_| invalid("tls server"))?;
    finish(Connection::Server(conn), stream, deadline, cancel)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::time::Duration;

    #[test]
    fn udp_short_and_long_headers() {
        let mut out = Vec::new();
        udp_wrap(MsgKind::Data, b"inner", 0x11223344, &mut out);
        assert_eq!(out[0] & 0xC0, 0x40);
        assert_eq!(udp_parse(&out), Some((MsgKind::Data, 0x11223344, &b"inner"[..])));

        udp_wrap(MsgKind::Handshake, &[9u8; 300], 0xAABBCCDD, &mut out);
        assert_eq!(out[0] & 0xC0, 0xC0);
        assert_eq!(&out[1..5], &[0, 0, 0, 1]); // QUIC v1처럼 보임
        let (k, cid, inner) = udp_parse(&out).unwrap();
        assert_eq!((k, cid, inner.len()), (MsgKind::Handshake, 0xAABBCCDD, 300));
        assert!(udp_parse(b"\x00abc").is_none());
        assert!(udp_parse(&out[..LONG_HDR + 10]).is_none()); // 길이가 모자라면 거절
    }

    #[test]
    fn tls13_roundtrip_both_directions() {
        let cfg = tls_server_config(super::super::testcert::CERT_PEM.as_bytes(), super::super::testcert::KEY_PEM.as_bytes()).unwrap();
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let srv = std::thread::spawn(move || {
            let (s, _) = l.accept().unwrap();
            s.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
            let (mut tx, mut rx) = tls_server(s, cfg, Instant::now() + Duration::from_secs(3), &|| false).unwrap();
            let mut buf = [0u8; 2048];
            let (k, n) = loop {
                match rx.recv_msg(&mut buf) {
                    Ok(m) => break m,
                    Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => continue,
                    Err(e) => panic!("{e}"),
                }
            };
            assert_eq!(k, MsgKind::Handshake);
            tx.send_msg(MsgKind::Data, &buf[..n]).unwrap(); // 메아리
        });
        let s = TcpStream::connect(addr).unwrap();
        s.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
        let (mut tx, mut rx) = tls_client(s, "www.example.com", Instant::now() + Duration::from_secs(3), &|| false).unwrap();
        tx.send_msg(MsgKind::Handshake, b"over real tls").unwrap();
        let mut buf = [0u8; 2048];
        let (k, n) = loop {
            match rx.recv_msg(&mut buf) {
                Ok(m) => break m,
                Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => continue,
                Err(e) => panic!("{e}"),
            }
        };
        assert_eq!((k, &buf[..n]), (MsgKind::Data, &b"over real tls"[..]));
        srv.join().unwrap();
    }
}
