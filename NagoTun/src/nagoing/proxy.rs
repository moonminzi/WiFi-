//! nagoing 프록시 — 클라이언트(폰)와 서버(AWS)의 중계 루프.
//!
//! 클라이언트: NepTUN이 로컬 UDP(127.0.0.1:local)로 보낸 WireGuard 데이터그램을 받아 FEC로 조각내고
//! 세션 키로 봉인해 전송(UDP 51821 QUIC 모양 → 막히면 진짜 TLS 1.3 / TCP 443)으로 서버에 보낸다. 반대로 서버에서 온
//! 조각은 열어서 NepTUN에게 돌려준다. WireGuard 자체는 로컬 소켓만 보므로 하나도 바뀌지 않는다.
//!
//! 서버: UDP와 TCP(TLS)를 동시에 듣고, 세션별로 wg0(127.0.0.1:51820)에 UDP로 중계한다. 세션은 session_id와
//! 클라의 WG 공개키로 묶어 둬서, 클라이언트가 와이파이↔LTE로 바뀌어 주소가 달라져도(=재접속) 같은 wg0 소켓을 계속
//! 쓴다 → 서버가 보는 WG 피어 엔드포인트가 안 바뀌어 WG 재핸드셰이크 없이 이어진다(③ 빠른 전환).
//!
//! v2 보안(crypto.rs): HELLO는 클라 WG 키 × 서버 WG 키로 인증되고(남의 세션 가로채기 불가), 시각 창 + 난수 캐시로
//! 재전송을 막는다. 데이터는 HELLO마다 새로 뽑은 세션 키로 AEAD 봉인되고 2048칸 리플레이 창을 지난다.
//! 서버는 **인증된** 패킷이 올 때만 반환 경로를 새 주소로 바꾼다(위조 패킷으로 경로를 돌릴 수 없음).

use std::collections::HashMap;
use std::io;
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use super::crypto::{self, ClientHello, HandshakeKey, Identity, ServerAck, SessionKeys};
use super::fec::{FecDecoder, FecEncoder, ShardRef};
use super::frame::{self, Frame};
use super::transport::{self, Kind, MsgKind, RxHalf, TlsTx, TxHalf, UdpRx, UdpTx};
use super::{rand_bytes, rand_u64};

pub use super::crypto::VERSION as PROTOCOL_VERSION;

/// 수립된 전송 한 벌: 송신 반·수신 반·종류·세션 키.
type Conn = (Box<dyn TxHalf>, Box<dyn RxHalf>, Kind, Arc<SessionKeys>);

const READ_TIMEOUT: Duration = Duration::from_millis(500);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(1500);
/// TCP 접속·TLS 핸드셰이크·HELLO 응답 각각의 제한.
const TCP_STEP_TIMEOUT: Duration = Duration::from_secs(3);
const KEEPALIVE: Duration = Duration::from_secs(5);
const HELLO_RETRIES: usize = 3;
const MAX_MSG: usize = 2048;
/// TCP 쓰기 제한. 한 클라이언트의 멈춘 쓰기가 잠금을 오래 쥐지 못하게 한다.
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);
/// 클라이언트가 이만큼 아무것도 못 받으면 전송을 다시 세운다(서버 재시작·NAT 변경 복구).
const CLIENT_STALE: Duration = Duration::from_secs(15);
/// 서버가 이만큼 조용한 세션은 정리한다(자원 누수 방지).
const SESSION_IDLE: Duration = Duration::from_secs(300);
/// 서버 TCP 연결이 이만큼 인증된 프레임을 못 받으면 끊는다. 클라는 5초마다 PING하므로 살아 있는 연결은 안 걸린다.
/// 망을 바꾼 폰의 옛 연결(FIN 없이 사라짐)이 스레드·fd를 영영 쥐지 못하게.
const TCP_IDLE: Duration = if cfg!(test) { Duration::from_secs(2) } else { Duration::from_secs(30) };
/// 동시 TCP 연결 상한(연결마다 스레드 하나). 넘으면 새 연결은 바로 닫는다 — 스레드 고갈로 프로세스가 죽지 않게.
const MAX_TCP_CONNS: usize = 1024;
/// 세션 상한(세션마다 wg0 소켓 + 내려받기 스레드). 아무 WG 키로나 HELLO를 만들 수 있으므로 남발을 막는다.
const MAX_SESSIONS: usize = 4096;
/// 기억할 HELLO 난수 상한(리플레이 캐시). 넘치면 만료된 것부터 지운다.
const MAX_HELLO_CACHE: usize = 65_536;
/// auto에서 UDP가 붙었다가 조용해지면(=도중에 막힘) 이 시간 동안은 TCP를 먼저 해 본다.
const UDP_PENALTY: Duration = Duration::from_secs(300);
/// 덜 찬 FEC 그룹은 이만큼 기다린 뒤 그 개수로 닫아 패리티를 낸다(드문 트래픽도 복구되게).
/// 대용량 전송은 그룹이 이보다 먼저 차서 추가 비용이 없다.
const FEC_MAX_AGE: Duration = Duration::from_millis(200);
/// 덜 찬 그룹이 있을 때 읽기 제한을 이만큼으로 줄여 FEC_MAX_AGE를 제때 확인한다(없으면 READ_TIMEOUT).
const FEC_TICK: Duration = Duration::from_millis(20);
/// UDP 핸드셰이크 평문을 이만큼 채우면 데이터그램이 QUIC Initial 크기(1200)가 된다.
const UDP_HS_PAD: usize = transport::QUIC_INITIAL_SIZE - transport::LONG_HDR - 12 - crypto::TAG_LEN;
/// TLS 안의 HELLO는 진짜 브라우저의 첫 요청 크기쯤으로.
const TCP_HS_PAD: usize = 400;
/// nagoing이 아닌 TLS 접속(능동 탐침)에 주는 응답 — 평범한 웹 서버처럼 보이게.
const HTTP_404: &[u8] = b"HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

/// 단조 증가 ms(유휴 판단용).
fn now_ms() -> u64 {
    use std::sync::OnceLock;
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_millis() as u64
}

#[derive(Clone, Copy)]
pub struct FecParams {
    pub k: u8,
    pub groups: u16,
    pub enabled: bool,
}

impl Default for FecParams {
    fn default() -> Self {
        // k=8 → 12.5% 추가, groups=8 → 최대 8연속 손실 복구.
        FecParams { k: 8, groups: 8, enabled: true }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Prefer {
    Auto,
    Udp,
    Tcp,
}

// ── 공통 헬퍼 ────────────────────────────────────────────────────────────────

fn is_timeout(e: &io::Error) -> bool {
    matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut)
}

/// ShardRef를 Frame으로(seq는 선에 싣지 않는다 — 디코더가 안 쓴다).
fn shard_frame<'a>(shard: ShardRef<'a>) -> Frame<'a> {
    match shard {
        ShardRef::Data { group, gen, index, k, payload, .. } => Frame::Data { group, gen, index, k, payload },
        ShardRef::Parity { group, gen, k, payload } => Frame::Parity { group, gen, k, payload },
    }
}

thread_local! {
    /// 봉인용 버퍼(평문·봉인본). 패킷마다 Vec 둘을 새로 잡지 않게 스레드마다 하나씩 다시 쓴다.
    static SEAL_BUFS: std::cell::RefCell<(Vec<u8>, Vec<u8>)> = const { std::cell::RefCell::new((Vec::new(), Vec::new())) };
}

/// 프레임을 평문으로 만들고 세션 키로 봉인해 `f`에 넘긴다(버퍼는 스레드마다 재사용 — `f` 안에서 다시 봉인하지 말 것).
fn with_sealed<R>(keys: &SessionKeys, frame: &Frame, f: impl FnOnce(&[u8]) -> R) -> R {
    SEAL_BUFS.with(|b| {
        let (plain, out) = &mut *b.borrow_mut();
        frame::encode(frame, plain);
        keys.seal(plain, out);
        f(out)
    })
}

/// 시험용: 봉인본을 새 Vec으로.
#[cfg(test)]
fn seal_frame(keys: &SessionKeys, frame: &Frame) -> Vec<u8> {
    with_sealed(keys, frame, |b| b.to_vec())
}

// ══════════════════════════════════════════════════════════════════════════════
// 서버
// ══════════════════════════════════════════════════════════════════════════════

pub struct ServerConfig {
    pub psk: String,
    pub udp_bind: SocketAddr,
    pub tcp_bind: SocketAddr,
    pub upstream: SocketAddr, // wg0, 보통 127.0.0.1:51820
    pub fec: FecParams,
    /// 서버 고정 키 = wg0의 WireGuard 개인키(클라가 이미 아는 serverPub의 짝).
    pub identity: [u8; 32],
    /// TCP 443 TLS 1.3용 인증서·키(PEM). 클라는 검증하지 않으므로 자체서명이면 된다.
    pub tls_cert_pem: Vec<u8>,
    pub tls_key_pem: Vec<u8>,
}

thread_local! {
    /// UDP 바깥 포장 버퍼(스레드마다 재사용).
    static WRAP_BUF: std::cell::RefCell<Vec<u8>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// 클라이언트로 돌려보낼 경로. 복제가 싸서(Arc) 잠금 안에서는 복제만 하고 실제 전송은 잠금 밖에서 한다.
#[derive(Clone)]
enum Return {
    Udp { sock: Arc<UdpSocket>, addr: SocketAddr, cid: u32 },
    Tcp { tx: Arc<Mutex<TlsTx>> },
}

impl Return {
    fn send(&self, kind: MsgKind, inner: &[u8]) -> io::Result<()> {
        match self {
            Return::Udp { sock, addr, cid } => WRAP_BUF.with(|w| {
                let wrapped = &mut *w.borrow_mut();
                transport::udp_wrap(kind, inner, *cid, wrapped);
                sock.send_to(wrapped, *addr)?;
                Ok(())
            }),
            Return::Tcp { tx } => tx.lock().unwrap().send_msg(kind, inner),
        }
    }
}

struct Session {
    wg: UdpSocket, // wg0에 connect
    /// 이 세션을 연 클라의 WG 공개키. 다른 키의 HELLO로는 이 세션에 붙을 수 없다(가로채기 방지).
    static_pub: [u8; 32],
    keys: Mutex<Arc<SessionKeys>>, // 마지막 HELLO로 뽑은 세션 키
    ret: Mutex<Return>,
    enc: Mutex<FecEncoder>, // wg→client
    dec: Mutex<FecDecoder>, // client→wg
    fec_on: bool,
    alive: Arc<AtomicBool>,
    recovered: Arc<AtomicU64>, // client→wg 방향에서 FEC로 되살린 조각 수(서버 전체 합산)
    last_seen: AtomicU64,      // 마지막 인증된 수신 시각(ms). 유휴 정리에 쓴다
}

impl Session {
    fn keys(&self) -> Arc<SessionKeys> {
        self.keys.lock().unwrap().clone()
    }

    /// 지금의 반환 경로로 봉인해 보낸다. ★ ret 잠금은 경로를 복제하는 동안만 쥔다 — 멈춘 TCP 쓰기를 잠금 안에서 하면
    /// 같은 세션의 HELLO(망 전환)로 ret을 바꾸려는 UDP 루프가 그동안 멈춰 모든 UDP 클라가 선다.
    fn send_frame(&self, frame: &Frame) -> io::Result<()> {
        let ret = self.ret.lock().unwrap().clone();
        with_sealed(&self.keys(), frame, |b| ret.send(MsgKind::Data, b))
    }

    fn touch(&self) {
        self.last_seen.store(now_ms(), Ordering::Relaxed);
    }

    /// 클라이언트→wg0: 받은 조각은 바로 wg0로, FEC로 되살린 조각도 wg0로.
    fn inbound(&self, frame: Frame) {
        match frame {
            Frame::Data { group, gen, index, k, payload } => {
                let _ = self.wg.send(payload);
                if k >= 2 {
                    let (wg, rc) = (&self.wg, &self.recovered);
                    self.dec.lock().unwrap().on_data(group, gen, index, k, payload, |rec| {
                        rc.fetch_add(1, Ordering::Relaxed);
                        let _ = wg.send(rec);
                    });
                }
            }
            Frame::Parity { group, gen, k, payload } => {
                let (wg, rc) = (&self.wg, &self.recovered);
                self.dec.lock().unwrap().on_parity(group, gen, k, payload, |rec| {
                    rc.fetch_add(1, Ordering::Relaxed);
                    let _ = wg.send(rec);
                });
            }
            _ => {}
        }
    }
}

struct ServerInner {
    hs: HandshakeKey,
    identity: Identity,
    tls: Arc<rustls::ServerConfig>,
    upstream: SocketAddr,
    fec: FecParams,
    sessions: Mutex<HashMap<u64, Arc<Session>>>,
    by_udp: Mutex<HashMap<SocketAddr, u64>>,
    by_cid: Mutex<HashMap<u32, u64>>, // 클라이언트 cid → 세션. NAT로 주소가 바뀌어도 cid로 찾는다
    hello_seen: Mutex<HashMap<[u8; 16], u64>>, // HELLO 난수 → 만료 시각(초). 리플레이 캐시
    stop: AtomicBool,
    recovered: Arc<AtomicU64>,
    tcp_conns: AtomicUsize, // 지금 살아 있는 TCP 연결 스레드 수(MAX_TCP_CONNS 상한)
}

impl ServerInner {
    /// HELLO를 확인하고(시각·MAC·리플레이) 세션을 붙인 뒤, 봉인한 ACK를 돌려준다. 하나라도 어긋나면 None(무응답).
    fn accept_hello(self: &Arc<Self>, msg: &mut [u8], ret: Return, pad: usize) -> Option<(u64, Arc<Session>, Vec<u8>)> {
        let (hello, mac) = ClientHello::open(&self.hs, msg)?;
        if !hello.fresh(crypto::now_unix()) {
            return None;
        }
        let k = self.identity.shared(&hello.static_pub)?;
        if !hello.verify(&mac, &k) {
            return None;
        }
        // MAC이 맞는 HELLO만 캐시에 넣는다(아무 바이트로 캐시를 채우지 못하게).
        if !self.remember_hello(&hello.random) {
            return None;
        }
        let mut s_random = [0u8; 16];
        rand_bytes(&mut s_random);
        let keys = Arc::new(SessionKeys::derive(&k, &hello.random, &s_random, false));
        let s = self.attach(hello.session, hello.static_pub, ret, keys).ok()?;
        let ack = ServerAck { session: hello.session, random: s_random }.seal(&self.hs, &k, &hello.random, pad);
        Some((hello.session, s, ack))
    }

    /// 처음 보는 HELLO 난수면 기억하고 true, 이미 봤으면(재전송) false.
    fn remember_hello(&self, random: &[u8; 16]) -> bool {
        let now = crypto::now_unix();
        let mut seen = self.hello_seen.lock().unwrap();
        if seen.len() >= MAX_HELLO_CACHE {
            seen.retain(|_, exp| *exp > now);
        }
        if seen.len() >= MAX_HELLO_CACHE || seen.contains_key(random) {
            return false;
        }
        seen.insert(*random, now + 2 * crypto::HELLO_SKEW);
        true
    }

    /// 세션을 찾거나 만든다. 이미 있으면(같은 WG 키일 때만) 반환 경로와 세션 키를 새 것으로 바꾼다(재접속/망 전환).
    /// ★ 세션 표 잠금을 쥔 채로는 절대 ret 잠금을 기다리지 않는다(표 잠금과 겹치면 서버 전체가 멈춘다).
    fn attach(self: &Arc<Self>, session_id: u64, static_pub: [u8; 32], ret: Return, keys: Arc<SessionKeys>) -> io::Result<Arc<Session>> {
        let reattach = |s: Arc<Session>, ret: Return, keys: Arc<SessionKeys>| -> io::Result<Arc<Session>> {
            if s.static_pub != static_pub {
                return Err(io::Error::new(io::ErrorKind::PermissionDenied, "session belongs to another key"));
            }
            *s.keys.lock().unwrap() = keys;
            *s.ret.lock().unwrap() = ret;
            s.touch();
            Ok(s)
        };
        if let Some(s) = self.sessions.lock().unwrap().get(&session_id).cloned() {
            return reattach(s, ret, keys);
        }
        let wg = UdpSocket::bind(if self.upstream.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" })?;
        wg.connect(self.upstream)?;
        wg.set_read_timeout(Some(READ_TIMEOUT))?;
        let mut map = self.sessions.lock().unwrap();
        if let Some(s) = map.get(&session_id).cloned() {
            drop(map);
            return reattach(s, ret, keys);
        }
        if map.len() >= MAX_SESSIONS {
            return Err(io::Error::other("too many sessions"));
        }
        let session = Arc::new(Session {
            wg,
            static_pub,
            keys: Mutex::new(keys),
            ret: Mutex::new(ret),
            enc: Mutex::new(FecEncoder::new(self.fec.k, self.fec.groups)),
            dec: Mutex::new(FecDecoder::new()),
            fec_on: self.fec.enabled,
            alive: Arc::new(AtomicBool::new(true)),
            recovered: self.recovered.clone(),
            last_seen: AtomicU64::new(now_ms()),
        });
        map.insert(session_id, session.clone());
        drop(map);
        if let Err(e) = self.clone().spawn_downpump(session.clone()) {
            // 스레드를 못 만들면(자원 고갈) 세션을 되돌린다(thread::spawn이었다면 panic=abort로 서버가 죽었다).
            self.sessions.lock().unwrap().remove(&session_id);
            return Err(e);
        }
        Ok(session)
    }

    /// UDP 데이터의 세션 후보를 찾는다(주소로 먼저, 없으면 cid로). 아직 아무것도 바꾸지 않는다 —
    /// 반환 경로는 패킷이 그 세션 키로 인증된 뒤에만 바꾼다.
    fn find_udp(&self, from: SocketAddr, cid: u32) -> Option<(u64, Arc<Session>)> {
        let id = self.by_udp.lock().unwrap().get(&from).copied();
        let id = match id {
            Some(id) => id,
            None => self.by_cid.lock().unwrap().get(&cid).copied()?,
        };
        let s = self.sessions.lock().unwrap().get(&id).cloned()?;
        Some((id, s))
    }

    /// 세션의 UDP 주소와 cid를 등록한다. 같은 세션의 옛 항목은 지운다 — 클라는 UDP 소켓을 한 번에 하나만 쓰므로,
    /// 안 지우면 NAT가 포트를 바꾸거나 망을 옮길 때마다 표가 쌓여 오래 붙은 세션에서 메모리가 계속 는다.
    fn bind_udp(&self, id: u64, from: SocketAddr, cid: u32) {
        {
            let mut by_udp = self.by_udp.lock().unwrap();
            by_udp.retain(|_, v| *v != id);
            by_udp.insert(from, id);
        }
        let mut by_cid = self.by_cid.lock().unwrap();
        by_cid.retain(|_, v| *v != id);
        by_cid.insert(cid, id);
    }

    /// wg0→client 펌프: wg0에서 읽은 응답을 FEC로 조각내 봉인해 클라이언트에게 보낸다.
    fn spawn_downpump(self: Arc<Self>, session: Arc<Session>) -> io::Result<()> {
        thread::Builder::new().name("nagoing-down".into()).spawn(move || {
            let mut buf = [0u8; MAX_MSG];
            let mut timeout = READ_TIMEOUT;
            while session.alive.load(Ordering::Relaxed) && !self.stop.load(Ordering::Relaxed) {
                match session.wg.recv(&mut buf) {
                    Ok(n) => {
                        let payload = &buf[..n];
                        if session.fec_on {
                            session.enc.lock().unwrap().push(payload, |shard| {
                                let _ = session.send_frame(&shard_frame(shard));
                            });
                        } else {
                            let _ = session.send_frame(&Frame::Data { group: 0, gen: 0, index: 0, k: 0, payload });
                        }
                    }
                    Err(e) if is_timeout(&e) => {}
                    Err(_) => break,
                }
                if session.fec_on {
                    // 덜 찬 그룹을 제때 닫고, 남은 게 있으면 짧은 주기로 다시 확인한다.
                    let mut enc = session.enc.lock().unwrap();
                    enc.flush_stale(FEC_MAX_AGE, |shard| {
                        let _ = session.send_frame(&shard_frame(shard));
                    });
                    let want = if enc.has_pending() { FEC_TICK } else { READ_TIMEOUT };
                    drop(enc);
                    if want != timeout && session.wg.set_read_timeout(Some(want)).is_ok() {
                        timeout = want;
                    }
                }
            }
        })?;
        Ok(())
    }

    /// 유휴 세션과 만료된 HELLO 기억을 정리한다(자원 누수 방지).
    fn reap(&self) {
        let now = crypto::now_unix();
        self.hello_seen.lock().unwrap().retain(|_, exp| *exp > now);
        let cutoff = now_ms().saturating_sub(SESSION_IDLE.as_millis() as u64);
        let dead: Vec<u64> = self
            .sessions
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, s)| s.last_seen.load(Ordering::Relaxed) < cutoff)
            .map(|(id, _)| *id)
            .collect();
        if dead.is_empty() {
            return;
        }
        for id in &dead {
            if let Some(s) = self.sessions.lock().unwrap().remove(id) {
                s.alive.store(false, Ordering::Relaxed);
            }
        }
        self.by_udp.lock().unwrap().retain(|_, id| !dead.contains(id));
        self.by_cid.lock().unwrap().retain(|_, id| !dead.contains(id));
    }
}

pub struct ServerHandle {
    inner: Arc<ServerInner>,
    threads: Vec<JoinHandle<()>>,
    udp_addr: SocketAddr,
    tcp_addr: SocketAddr,
}

impl ServerHandle {
    /// 실제로 바인드된 주소(포트 0으로 띄웠을 때 유용).
    pub fn udp_addr(&self) -> SocketAddr {
        self.udp_addr
    }
    pub fn tcp_addr(&self) -> SocketAddr {
        self.tcp_addr
    }
    /// 클라→wg 방향에서 FEC로 되살린 조각 수(모든 세션 합산).
    pub fn recovered(&self) -> u64 {
        self.inner.recovered.load(Ordering::Relaxed)
    }

    pub fn stop(mut self) {
        self.inner.stop.store(true, Ordering::Relaxed);
        for s in self.inner.sessions.lock().unwrap().values() {
            s.alive.store(false, Ordering::Relaxed);
        }
        // TCP 연결 스레드는 stop 플래그를 READ_TIMEOUT마다 확인해 스스로 빠진다.
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

pub fn run_server(cfg: ServerConfig) -> io::Result<ServerHandle> {
    let inner = Arc::new(ServerInner {
        hs: HandshakeKey::from_psk(cfg.psk.as_bytes()),
        identity: Identity::from_bytes(cfg.identity),
        tls: transport::tls_server_config(&cfg.tls_cert_pem, &cfg.tls_key_pem)?,
        upstream: cfg.upstream,
        fec: cfg.fec,
        sessions: Mutex::new(HashMap::new()),
        by_udp: Mutex::new(HashMap::new()),
        by_cid: Mutex::new(HashMap::new()),
        hello_seen: Mutex::new(HashMap::new()),
        stop: AtomicBool::new(false),
        recovered: Arc::new(AtomicU64::new(0)),
        tcp_conns: AtomicUsize::new(0),
    });

    let udp = Arc::new(UdpSocket::bind(cfg.udp_bind)?);
    udp.set_read_timeout(Some(READ_TIMEOUT))?;
    let udp_addr = udp.local_addr()?;
    let listener = TcpListener::bind(cfg.tcp_bind)?;
    let tcp_addr = listener.local_addr()?;
    listener.set_nonblocking(true)?;

    let mut threads = Vec::new();
    {
        let inner = inner.clone();
        let udp = udp.clone();
        threads.push(thread::spawn(move || server_udp_loop(inner, udp)));
    }
    {
        let inner = inner.clone();
        threads.push(thread::spawn(move || server_tcp_loop(inner, listener)));
    }
    // 유휴 세션 정리 루프
    {
        let inner = inner.clone();
        threads.push(thread::spawn(move || {
            while !inner.stop.load(Ordering::Relaxed) {
                for _ in 0..60 {
                    if inner.stop.load(Ordering::Relaxed) {
                        return;
                    }
                    thread::sleep(Duration::from_millis(500));
                }
                inner.reap();
            }
        }));
    }

    Ok(ServerHandle { inner, threads, udp_addr, tcp_addr })
}

fn server_udp_loop(inner: Arc<ServerInner>, udp: Arc<UdpSocket>) {
    let mut buf = [0u8; MAX_MSG + transport::LONG_HDR];
    while !inner.stop.load(Ordering::Relaxed) {
        let (n, from) = match udp.recv_from(&mut buf) {
            Ok(v) => v,
            Err(_) => continue, // 타임아웃 포함
        };
        let Some((kind, cid, body)) = transport::udp_parse(&buf[..n]) else { continue };
        // 안쪽 메시지가 buf의 어디인지(제자리에서 열려고 — 패킷마다 복사·할당하지 않게).
        let (start, len) = (body.as_ptr() as usize - buf.as_ptr() as usize, body.len());
        let msg = &mut buf[start..start + len];
        match kind {
            MsgKind::Handshake => {
                let ret = Return::Udp { sock: udp.clone(), addr: from, cid };
                if let Some((id, _, ack)) = inner.accept_hello(msg, ret.clone(), UDP_HS_PAD) {
                    inner.bind_udp(id, from, cid);
                    // 답은 HELLO가 온 그 경로로 바로.
                    let _ = ret.send(MsgKind::Handshake, &ack);
                }
            }
            MsgKind::Data => {
                let Some((id, s)) = inner.find_udp(from, cid) else { continue };
                let keys = s.keys();
                let Some(plain) = keys.open(msg) else { continue }; // 위조·변조·재전송은 여기서 버림
                let Some(frame) = frame::decode(plain) else { continue };
                // 인증된 패킷이 새 주소에서 왔으면(NAT 리바인드) 반환 경로를 그리로 옮긴다.
                let moved = !matches!(&*s.ret.lock().unwrap(), Return::Udp { addr, .. } if *addr == from);
                if moved {
                    *s.ret.lock().unwrap() = Return::Udp { sock: udp.clone(), addr: from, cid };
                    inner.bind_udp(id, from, cid);
                }
                s.touch();
                match frame {
                    Frame::Ping { token } => {
                        // PONG은 PING이 온 주소로 바로(이 루프는 모든 클라가 같이 쓰므로 TCP 경로로 쓰다 막히면 안 됨).
                        let direct = Return::Udp { sock: udp.clone(), addr: from, cid };
                        let _ = with_sealed(&keys, &Frame::Pong { token }, |b| direct.send(MsgKind::Data, b));
                    }
                    Frame::Data { .. } | Frame::Parity { .. } => s.inbound(frame),
                    Frame::Pong { .. } => {}
                }
            }
        }
    }
}

/// TCP 연결 수를 세는 표식. 연결 스레드가 끝나면(어떻게 끝나든) 수를 되돌린다.
struct ConnSlot(Arc<ServerInner>);

impl Drop for ConnSlot {
    fn drop(&mut self) {
        self.0.tcp_conns.fetch_sub(1, Ordering::Relaxed);
    }
}

fn server_tcp_loop(inner: Arc<ServerInner>, listener: TcpListener) {
    while !inner.stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _peer)) => {
                // 상한을 넘으면 바로 닫는다(stream drop). 연결마다 스레드라 무제한이면 스레드 고갈 → panic=abort.
                if inner.tcp_conns.fetch_add(1, Ordering::Relaxed) >= MAX_TCP_CONNS {
                    inner.tcp_conns.fetch_sub(1, Ordering::Relaxed);
                    continue;
                }
                let slot = ConnSlot(inner.clone());
                let inner = inner.clone();
                // 실패해도 클로저(slot 포함)가 버려지며 수가 되돌아간다.
                let _ = thread::Builder::new().name("nagoing-tcp".into()).spawn(move || {
                    let _slot = slot;
                    let _ = server_tcp_conn(inner, stream);
                });
            }
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(100));
            }
            Err(_) => break,
        }
    }
}

fn server_tcp_conn(inner: Arc<ServerInner>, stream: TcpStream) -> io::Result<()> {
    stream.set_nodelay(true)?;
    stream.set_write_timeout(Some(WRITE_TIMEOUT))?;
    // 짧은 읽기 제한으로 데드라인·종료를 자주 확인한다(TLS 수신 반은 버퍼드라 타임아웃에 레코드가 안 깨진다).
    stream.set_read_timeout(Some(READ_TIMEOUT))?;
    // 끝낼 때 소켓을 닫는 손잡이. tx는 세션 ret에도 들려 있어서 이 스레드가 끝나도 fd가 안 닫힐 수 있다.
    let ctl = stream.try_clone()?;
    let stopped = || inner.stop.load(Ordering::Relaxed);
    let (tx, mut rx) = transport::tls_server(stream, inner.tls.clone(), Instant::now() + TCP_STEP_TIMEOUT, &stopped)?;
    let tx = Arc::new(Mutex::new(tx));
    let ret = Return::Tcp { tx: tx.clone() };
    let mut buf = [0u8; MAX_MSG];

    // 첫 메시지는 올바른 HELLO여야 한다. 아니면(능동 탐침·브라우저) 평범한 웹 서버처럼 404를 주고 닫는다.
    let deadline = Instant::now() + TCP_STEP_TIMEOUT;
    let first = loop {
        if Instant::now() > deadline || stopped() {
            break None;
        }
        match rx.recv_msg(&mut buf) {
            Ok(m) => break Some(m),
            Err(ref e) if is_timeout(e) => continue,
            Err(_) => break None,
        }
    };
    let accepted = match first {
        Some((MsgKind::Handshake, n)) => {
            let mut msg = buf[..n].to_vec();
            inner.accept_hello(&mut msg, ret.clone(), TCP_HS_PAD)
        }
        _ => None,
    };
    let Some((_, mut session, ack)) = accepted else {
        tx.lock().unwrap().send_plain_and_close(HTTP_404);
        return Ok(());
    };
    ret.send(MsgKind::Handshake, &ack)?;

    let mut last_frame = Instant::now();
    while !stopped() {
        // 살아 있는 클라는 5초마다 PING한다. TCP_IDLE 동안 인증된 프레임이 없으면 죽은 연결로 보고 놓는다.
        if last_frame.elapsed() > TCP_IDLE {
            break;
        }
        let (kind, n) = match rx.recv_msg(&mut buf) {
            Ok(m) => m,
            Err(ref e) if is_timeout(e) => continue,
            Err(_) => break,
        };
        let mut msg = buf[..n].to_vec();
        match kind {
            MsgKind::Handshake => {
                // 같은 연결에서 다시 HELLO(드묾) — 새 세션 키로.
                if let Some((_, s, ack)) = inner.accept_hello(&mut msg, ret.clone(), TCP_HS_PAD) {
                    session = s;
                    last_frame = Instant::now();
                    let _ = ret.send(MsgKind::Handshake, &ack);
                }
            }
            MsgKind::Data => {
                let keys = session.keys();
                let Some(plain) = keys.open(&mut msg) else { continue };
                let Some(frame) = frame::decode(plain) else { continue };
                last_frame = Instant::now();
                session.touch();
                match frame {
                    // PONG은 이 연결로(세션 ret은 그사이 다른 경로로 바뀌었을 수 있다).
                    Frame::Ping { token } => {
                        let _ = with_sealed(&keys, &Frame::Pong { token }, |b| ret.send(MsgKind::Data, b));
                    }
                    Frame::Data { .. } | Frame::Parity { .. } => session.inbound(frame),
                    Frame::Pong { .. } => {}
                }
            }
        }
    }
    let _ = ctl.shutdown(std::net::Shutdown::Both);
    Ok(())
}

// ══════════════════════════════════════════════════════════════════════════════
// 클라이언트
// ══════════════════════════════════════════════════════════════════════════════

#[derive(Clone)]
pub struct ClientConfig {
    pub psk: String,
    pub server_udp: SocketAddr,
    pub server_tcp: SocketAddr,
    pub local_bind: SocketAddr, // NepTUN이 보내는 127.0.0.1:local
    pub fec: FecParams,
    pub prefer: Prefer,
    pub sni: String,
    /// 클라 고정 키 = 이 기기의 WireGuard 개인키.
    pub identity: [u8; 32],
    /// 서버의 WireGuard 공개키(설정의 serverPub). HELLO_ACK가 진짜 서버의 것인지 이걸로 확인한다.
    pub server_pub: [u8; 32],
}

struct ClientInner {
    hs: HandshakeKey,
    static_pub: [u8; 32],
    k_static: [u8; 32], // 내 WG 키 × 서버 WG 키
    session_id: u64,
    cfg: ClientConfig,
    local: UdpSocket,
    peer: Mutex<Option<SocketAddr>>,
    /// 엔진에 바로 붙었을 때 받은 WG 데이터그램을 넘길 곳(로컬 UDP 대신). 비어 있으면 로컬 소켓으로.
    sink: RwLock<Option<Sink>>,
    /// 엔진에서 떼어 낼 때 부를 것(엔진 쪽 바깥 전송 자리를 비운다). stop에서 부른다.
    detach: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    tx: Mutex<Option<Box<dyn TxHalf>>>,
    rx: Mutex<Option<Box<dyn RxHalf>>>,
    keys: Mutex<Option<Arc<SessionKeys>>>,
    enc: Mutex<FecEncoder>, // c2s
    dec: Mutex<FecDecoder>, // s2c
    last_rx: AtomicU64,     // 마지막 인증된 수신 시각(ms). 오래 조용하면 전송을 다시 세운다
    udp_bad_until: AtomicU64, // 이 시각(ms)까지는 auto에서 TCP를 먼저(붙었던 UDP가 도중에 막힌 망)
    stop: AtomicBool,
    rebind: AtomicBool,
    st_sent: AtomicU64,
    st_recv: AtomicU64,
    st_recovered: AtomicU64,
    st_kind: AtomicU8, // 0 none, 1 udp, 2 tcp
}

impl ClientInner {
    fn send_frame(&self, frame: &Frame) {
        let Some(keys) = self.keys.lock().unwrap().clone() else { return };
        with_sealed(&keys, frame, |out| {
            let mut g = self.tx.lock().unwrap();
            if let Some(tx) = g.as_mut() {
                if tx.send_msg(MsgKind::Data, out).is_err() {
                    self.rebind.store(true, Ordering::Relaxed);
                } else {
                    self.st_sent.fetch_add(1, Ordering::Relaxed);
                }
            }
        });
    }

    fn deliver(&self, payload: &[u8]) {
        // 엔진에 바로 붙어 있으면 시스템 호출 없이 엔진에 넣는다(로컬 UDP 홉 없음).
        if let Some(sink) = self.sink.read().unwrap().clone() {
            sink(payload);
            return;
        }
        if let Some(addr) = *self.peer.lock().unwrap() {
            let _ = self.local.send_to(payload, addr);
        }
    }

    /// WG 데이터그램 하나를 FEC로 조각내 봉인해 보낸다(로컬 소켓에서 받았든 엔진이 바로 넘겼든 같은 길).
    fn send_wg(&self, payload: &[u8]) {
        if self.cfg.fec.enabled {
            self.enc.lock().unwrap().push(payload, |shard| self.send_frame(&shard_frame(shard)));
        } else {
            self.send_frame(&Frame::Data { group: 0, gen: 0, index: 0, k: 0, payload });
        }
    }

    fn handle_down(&self, frame: Frame) {
        match frame {
            Frame::Data { group, gen, index, k, payload } => {
                self.deliver(payload);
                if k >= 2 {
                    self.dec.lock().unwrap().on_data(group, gen, index, k, payload, |rec| {
                        self.st_recovered.fetch_add(1, Ordering::Relaxed);
                        self.deliver(rec);
                    });
                }
            }
            Frame::Parity { group, gen, k, payload } => {
                self.dec.lock().unwrap().on_parity(group, gen, k, payload, |rec| {
                    self.st_recovered.fetch_add(1, Ordering::Relaxed);
                    self.deliver(rec);
                });
            }
            _ => {}
        }
    }

    fn stopped(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }

    fn stopped_err() -> io::Error {
        io::Error::new(io::ErrorKind::Interrupted, "stopped")
    }

    /// 새 HELLO(난수·시각이 매번 새로).
    fn new_hello(&self) -> ClientHello {
        ClientHello::new(self.session_id, self.static_pub)
    }

    // 전송 수립(자동 선택). 인증된 HELLO를 보내고, 진짜 서버의 HELLO_ACK가 오면 세션 키를 뽑는다.
    fn establish(&self) -> io::Result<Conn> {
        // auto인데 이 망에서 UDP가 붙었다 막힌 적이 있으면, 한동안은 TCP 먼저(UDP HELLO만 통과하고 데이터는
        // 막는 DPI에서 UDP 재접속만 되풀이하지 않게). TCP가 안 되면 그때 UDP.
        if self.cfg.prefer == Prefer::Auto && now_ms() < self.udp_bad_until.load(Ordering::Relaxed) {
            return self.try_tcp().or_else(|e| if self.stopped() { Err(e) } else { self.try_udp() });
        }
        if matches!(self.cfg.prefer, Prefer::Auto | Prefer::Udp) {
            match self.try_udp() {
                Ok(v) => return Ok(v),
                Err(_) if matches!(self.cfg.prefer, Prefer::Udp) => {
                    return Err(io::Error::new(io::ErrorKind::TimedOut, "udp handshake failed"));
                }
                Err(e) if self.stopped() => return Err(e),
                Err(_) => {}
            }
        }
        self.try_tcp()
    }

    fn try_udp(&self) -> io::Result<Conn> {
        let server = self.cfg.server_udp;
        let bind = if server.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
        let sock = UdpSocket::bind(bind)?;
        sock.connect(server)?;
        sock.set_read_timeout(Some(READ_TIMEOUT))?;
        let cid = rand_u64() as u32;
        let mut rbuf = [0u8; MAX_MSG + transport::LONG_HDR];
        let mut wrapped = Vec::new();
        for _ in 0..HELLO_RETRIES {
            // stop()이 수립 중에도 빨리 끝나게(확장의 stopTunnel·watchdog이 join을 기다린다).
            if self.stopped() {
                return Err(Self::stopped_err());
            }
            let hello = self.new_hello();
            transport::udp_wrap(MsgKind::Handshake, &hello.seal(&self.hs, &self.k_static, UDP_HS_PAD), cid, &mut wrapped);
            sock.send(&wrapped)?;
            let deadline = Instant::now() + HANDSHAKE_TIMEOUT;
            while Instant::now() < deadline && !self.stopped() {
                let n = match sock.recv(&mut rbuf) {
                    Ok(n) => n,
                    Err(ref e) if is_timeout(e) => continue,
                    Err(e) => return Err(e),
                };
                let Some((MsgKind::Handshake, _, body)) = transport::udp_parse(&rbuf[..n]) else { continue };
                let mut m = body.to_vec();
                if let Some(ack) = ServerAck::open(&self.hs, &mut m, &self.k_static, &hello) {
                    let keys = Arc::new(SessionKeys::derive(&self.k_static, &hello.random, &ack.random, true));
                    let rx_sock = sock.try_clone()?;
                    return Ok((Box::new(UdpTx::new(sock, cid)), Box::new(UdpRx::new(rx_sock)), Kind::Udp, keys));
                }
            }
        }
        Err(io::Error::new(io::ErrorKind::TimedOut, "no udp hello-ack"))
    }

    fn try_tcp(&self) -> io::Result<Conn> {
        // connect에 제한을 둬서 SYN이 사라지는 망에서 오래 매달리지 않게 한다.
        let stream = TcpStream::connect_timeout(&self.cfg.server_tcp, TCP_STEP_TIMEOUT)?;
        stream.set_nodelay(true)?;
        // 짧은 읽기 제한으로 데드라인·stop을 자주 확인한다.
        stream.set_read_timeout(Some(READ_TIMEOUT))?;
        // 멈춘 쓰기가 tx 잠금을 오래 쥐지 못하게 한다.
        stream.set_write_timeout(Some(WRITE_TIMEOUT))?;
        let stopped = || self.stopped();
        let (mut tx, mut rx) = transport::tls_client(stream, &self.cfg.sni, Instant::now() + TCP_STEP_TIMEOUT, &stopped)?;

        let hello = self.new_hello();
        tx.send_msg(MsgKind::Handshake, &hello.seal(&self.hs, &self.k_static, TCP_HS_PAD))?;
        let deadline = Instant::now() + TCP_STEP_TIMEOUT;
        let mut buf = [0u8; MAX_MSG];
        loop {
            if self.stopped() {
                return Err(Self::stopped_err());
            }
            if Instant::now() > deadline {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "no tcp hello-ack"));
            }
            match rx.recv_msg(&mut buf) {
                Ok((MsgKind::Handshake, n)) => {
                    let mut m = buf[..n].to_vec();
                    if let Some(ack) = ServerAck::open(&self.hs, &mut m, &self.k_static, &hello) {
                        let keys = Arc::new(SessionKeys::derive(&self.k_static, &hello.random, &ack.random, true));
                        return Ok((Box::new(tx), Box::new(rx), Kind::Tcp, keys));
                    }
                }
                Ok(_) => {}
                Err(ref e) if is_timeout(e) => continue,
                Err(e) => return Err(e),
            }
        }
    }
}

/// 받은 WG 데이터그램을 엔진에 넣는 함수(엔진에 바로 붙일 때).
pub type Sink = Arc<dyn Fn(&[u8]) + Send + Sync>;

/// 엔진이 내보낸 WG 데이터그램을 nagoing으로 바로 보내는 손잡이(엔진 스레드에서 부른다).
#[derive(Clone)]
pub struct DatagramSender(Arc<ClientInner>);

impl DatagramSender {
    pub fn send(&self, payload: &[u8]) {
        if !self.0.stop.load(Ordering::Relaxed) {
            self.0.send_wg(payload);
        }
    }
}

pub struct ClientHandle {
    inner: Arc<ClientInner>,
    threads: Vec<JoinHandle<()>>,
}

impl ClientHandle {
    /// 엔진에 바로 붙일 때 엔진 쪽에 꽂을 송신 손잡이.
    pub fn sender(&self) -> DatagramSender {
        DatagramSender(self.inner.clone())
    }

    /// 엔진에 바로 붙인다: 받은 WG 데이터그램은 `sink`로(로컬 UDP 대신), 떼어 낼 땐 `detach`를 부른다.
    /// 붙이기 전·뗀 뒤에는 로컬 UDP 포트로 그대로 동작한다(폴백).
    pub fn attach(&self, sink: Sink, detach: Box<dyn FnOnce() + Send>) {
        self.detach_engine();
        *self.inner.detach.lock().unwrap() = Some(detach);
        *self.inner.sink.write().unwrap() = Some(sink);
    }

    /// 엔진에서 떼어 낸다(로컬 UDP로 돌아감).
    pub fn detach_engine(&self) {
        *self.inner.sink.write().unwrap() = None;
        if let Some(detach) = self.inner.detach.lock().unwrap().take() {
            detach();
        }
    }

    /// 와이파이↔LTE 전환 등 경로가 바뀌었을 때 호출 → 전송을 새로 수립한다(③ 빠른 전환).
    pub fn network_changed(&self) {
        // 새 망에서는 UDP를 다시 먼저 해 본다(옛 망에서 막혔던 기억은 버림).
        self.inner.udp_bad_until.store(0, Ordering::Relaxed);
        self.inner.rebind.store(true, Ordering::Relaxed);
    }

    /// NepTUN이 WG 패킷을 보낼 로컬 주소(포트 0으로 띄웠을 때 유용).
    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.inner.local.local_addr()
    }

    pub fn stats(&self) -> ClientStats {
        let kind = match self.inner.st_kind.load(Ordering::Relaxed) {
            1 => Some(Kind::Udp),
            2 => Some(Kind::Tcp),
            _ => None,
        };
        ClientStats {
            kind,
            sent: self.inner.st_sent.load(Ordering::Relaxed),
            recv: self.inner.st_recv.load(Ordering::Relaxed),
            recovered: self.inner.st_recovered.load(Ordering::Relaxed),
        }
    }

    pub fn stop(mut self) {
        // 엔진이 더는 이 클라를 부르지 않게(그리고 엔진이 쥔 참조를 놓게) 먼저 떼어 낸다.
        self.detach_engine();
        self.inner.stop.store(true, Ordering::Relaxed);
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

pub struct ClientStats {
    pub kind: Option<Kind>,
    pub sent: u64,
    pub recv: u64,
    pub recovered: u64,
}

impl ClientStats {
    pub fn summary(&self) -> String {
        let k = match self.kind {
            Some(Kind::Udp) => "udp",
            Some(Kind::Tcp) => "tls",
            None => "down",
        };
        format!("{k} · tx {} · rx {} · fec+{}", self.sent, self.recv, self.recovered)
    }
}

pub fn run_client(cfg: ClientConfig) -> io::Result<ClientHandle> {
    let identity = Identity::from_bytes(cfg.identity);
    let k_static = identity
        .shared(&cfg.server_pub)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "bad server public key"))?;
    let local = UdpSocket::bind(cfg.local_bind)?;
    local.set_read_timeout(Some(READ_TIMEOUT))?;
    let inner = Arc::new(ClientInner {
        hs: HandshakeKey::from_psk(cfg.psk.as_bytes()),
        static_pub: identity.public(),
        k_static,
        session_id: rand_u64(),
        local,
        peer: Mutex::new(None),
        sink: RwLock::new(None),
        detach: Mutex::new(None),
        tx: Mutex::new(None),
        rx: Mutex::new(None),
        keys: Mutex::new(None),
        enc: Mutex::new(FecEncoder::new(cfg.fec.k, cfg.fec.groups)),
        dec: Mutex::new(FecDecoder::new()),
        last_rx: AtomicU64::new(0),
        udp_bad_until: AtomicU64::new(0),
        stop: AtomicBool::new(false),
        rebind: AtomicBool::new(false),
        st_sent: AtomicU64::new(0),
        st_recv: AtomicU64::new(0),
        st_recovered: AtomicU64::new(0),
        st_kind: AtomicU8::new(0),
        cfg,
    });

    let mut threads = Vec::new();
    // 업로드: NepTUN→서버
    {
        let inner = inner.clone();
        threads.push(thread::spawn(move || client_up_loop(inner)));
    }
    // 다운로드: 서버→NepTUN
    {
        let inner = inner.clone();
        threads.push(thread::spawn(move || client_down_loop(inner)));
    }
    // 감독: 전송 수립·재수립·keepalive
    {
        let inner = inner.clone();
        threads.push(thread::spawn(move || client_supervisor(inner)));
    }

    Ok(ClientHandle { inner, threads })
}

/// WireGuard 메시지처럼 생겼는가: 첫 바이트 타입 1~4 + 0 세 개, 타입별 길이(핸드셰이크 148/92, 쿠키 64,
/// 데이터 32 이상). 로컬 포트로 들어온 다른 것(같은 기기의 다른 앱 등)을 걸러 낸다.
/// ★ 데이터 길이를 16의 배수로 보면 안 된다 — 규격은 16바이트 패딩을 권하지만 NepTUN(BoringTun)은 패딩하지 않아서
///   (engine/src/noise/session.rs의 TODO) 대부분의 데이터 패킷이 버려졌다(2.1.5 build 36~2.1.6의 버그).
fn looks_like_wg(p: &[u8]) -> bool {
    if p.len() < 32 || p[1..4] != [0, 0, 0] {
        return false;
    }
    match p[0] {
        1 => p.len() == 148,
        2 => p.len() == 92,
        3 => p.len() == 64,
        4 => true, // 32 이상은 위에서 확인. 패딩이 없어 길이는 아무 값
        _ => false,
    }
}

fn client_up_loop(inner: Arc<ClientInner>) {
    let mut buf = [0u8; MAX_MSG];
    let fec_on = inner.cfg.fec.enabled;
    let mut timeout = READ_TIMEOUT;
    while !inner.stop.load(Ordering::Relaxed) {
        match inner.local.recv_from(&mut buf) {
            // 기기 안(루프백)에서 온 WG 모양 패킷만 받고, 그 보낸 곳을 내려받기 대상으로 삼는다(다른 앱이 51822로
            // 뭘 보내도 내려받기가 그쪽으로 새지 않게). NepTUN이 소켓을 다시 열어 포트가 바뀌어도 바로 따라간다.
            Ok((n, from)) if from.ip().is_loopback() && looks_like_wg(&buf[..n]) => {
                *inner.peer.lock().unwrap() = Some(from);
                inner.send_wg(&buf[..n]);
            }
            Ok(_) => {}
            Err(_) => {} // 타임아웃 포함
        }
        if fec_on {
            // 덜 찬 그룹을 제때 닫고(드문 트래픽도 복구), 남은 게 있으면 짧은 주기로 다시 확인한다.
            let mut enc = inner.enc.lock().unwrap();
            enc.flush_stale(FEC_MAX_AGE, |shard| inner.send_frame(&shard_frame(shard)));
            let want = if enc.has_pending() { FEC_TICK } else { READ_TIMEOUT };
            drop(enc);
            if want != timeout && inner.local.set_read_timeout(Some(want)).is_ok() {
                timeout = want;
            }
        }
    }
}

fn client_down_loop(inner: Arc<ClientInner>) {
    let mut buf = [0u8; MAX_MSG];
    while !inner.stop.load(Ordering::Relaxed) {
        let res = {
            let mut g = inner.rx.lock().unwrap();
            match g.as_mut() {
                Some(rx) => rx.recv_msg(&mut buf),
                None => Err(io::Error::new(io::ErrorKind::WouldBlock, "no transport")),
            }
        };
        match res {
            Ok((MsgKind::Data, n)) => {
                inner.st_recv.fetch_add(1, Ordering::Relaxed);
                let Some(keys) = inner.keys.lock().unwrap().clone() else { continue };
                // 받은 버퍼에서 바로 연다(복사 없음).
                let Some(plain) = keys.open(&mut buf[..n]) else { continue }; // 위조·재전송 버림
                if let Some(frame) = frame::decode(plain) {
                    // 살아 있음 표시(stale 판단)는 인증된 프레임에만.
                    inner.last_rx.store(now_ms(), Ordering::Relaxed);
                    inner.handle_down(frame);
                }
            }
            Ok((MsgKind::Handshake, _)) => {} // 늦게 온 ACK 등 — 수립은 감독이 한다
            Err(ref e) if is_timeout(e) => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(_) => {
                // 전송이 깨짐 → 재수립 요청하고 잠깐 쉰다.
                inner.rebind.store(true, Ordering::Relaxed);
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

fn client_supervisor(inner: Arc<ClientInner>) {
    while !inner.stop.load(Ordering::Relaxed) {
        match inner.establish() {
            Ok((tx, rx, kind, keys)) => {
                *inner.keys.lock().unwrap() = Some(keys);
                *inner.tx.lock().unwrap() = Some(tx);
                *inner.rx.lock().unwrap() = Some(rx);
                inner.st_kind.store(match kind { Kind::Udp => 1, Kind::Tcp => 2 }, Ordering::Relaxed);
                inner.last_rx.store(now_ms(), Ordering::Relaxed); // 방금 붙음 → stale 타이머 리셋
                inner.rebind.store(false, Ordering::Relaxed);
            }
            Err(_) => {
                if inner.stop.load(Ordering::Relaxed) {
                    break;
                }
                thread::sleep(Duration::from_secs(1));
                continue;
            }
        }
        let mut last_ping = Instant::now();
        // keepalive PING(5초)에 PONG이 오면 last_rx가 갱신된다. CLIENT_STALE 동안 아무것도 못 받으면
        // 서버 재시작/NAT 변경으로 보고 전송을 다시 세운다.
        while !inner.stop.load(Ordering::Relaxed) && !inner.rebind.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(200));
            if last_ping.elapsed() >= KEEPALIVE {
                last_ping = Instant::now();
                inner.send_frame(&Frame::Ping { token: rand_u64() });
            }
            let quiet = now_ms().saturating_sub(inner.last_rx.load(Ordering::Relaxed));
            if quiet > CLIENT_STALE.as_millis() as u64 {
                if inner.st_kind.load(Ordering::Relaxed) == 1 {
                    // 붙었던 UDP가 조용해짐 = 도중에 막혔을 수 있다 → 한동안 auto는 TCP 먼저.
                    inner.udp_bad_until.store(now_ms() + UDP_PENALTY.as_millis() as u64, Ordering::Relaxed);
                }
                inner.rebind.store(true, Ordering::Relaxed);
            }
        }
        // 현재 전송 내려놓기(다운로드 루프가 rx 잠금을 놓을 때까지 최대 READ_TIMEOUT 대기).
        *inner.tx.lock().unwrap() = None;
        *inner.rx.lock().unwrap() = None;
        *inner.keys.lock().unwrap() = None;
        inner.st_kind.store(0, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::Ipv4Addr;

    fn loopback(port: u16) -> SocketAddr {
        SocketAddr::from((Ipv4Addr::LOCALHOST, port))
    }

    // 받은 걸 그대로 돌려보내는 가짜 wg0(에코)을 띄우고 주소·정지 핸들·받은 개수를 돌려준다.
    fn spawn_echo() -> (SocketAddr, Arc<AtomicBool>, JoinHandle<()>, Arc<AtomicU64>) {
        let wg = UdpSocket::bind(loopback(0)).unwrap();
        let addr = wg.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let count = Arc::new(AtomicU64::new(0));
        let (stop2, count2) = (stop.clone(), count.clone());
        let handle = thread::spawn(move || {
            wg.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
            let mut buf = [0u8; 2048];
            while !stop2.load(Ordering::Relaxed) {
                if let Ok((n, from)) = wg.recv_from(&mut buf) {
                    count2.fetch_add(1, Ordering::Relaxed);
                    let _ = wg.send_to(&buf[..n], from);
                }
            }
        });
        (addr, stop, handle, count)
    }

    fn server_cfg(udp_bind: SocketAddr, tcp_bind: SocketAddr, upstream: SocketAddr, fec: FecParams, key: [u8; 32]) -> ServerConfig {
        ServerConfig {
            psk: "secret".into(),
            udp_bind,
            tcp_bind,
            upstream,
            fec,
            identity: key,
            tls_cert_pem: super::super::testcert::CERT_PEM.as_bytes().to_vec(),
            tls_key_pem: super::super::testcert::KEY_PEM.as_bytes().to_vec(),
        }
    }

    fn random_key() -> [u8; 32] {
        let mut k = [0u8; 32];
        rand_bytes(&mut k);
        k
    }

    fn client_cfg(udp: SocketAddr, tcp: SocketAddr, local: SocketAddr, fec: FecParams, prefer: Prefer, server_key: &[u8; 32]) -> ClientConfig {
        ClientConfig {
            psk: "secret".into(),
            server_udp: udp,
            server_tcp: tcp,
            local_bind: local,
            fec,
            prefer,
            sni: "www.cloudflare.com".into(),
            identity: random_key(),
            server_pub: Identity::from_bytes(*server_key).public(),
        }
    }

    fn wg_packet(i: u8) -> Vec<u8> {
        // WG 데이터 메시지 모양(타입 4). NepTUN처럼 패딩 없는 아무 길이로 — 16의 배수만 쓰면 길이 필터 버그를 놓친다.
        let mut p = vec![i; 33 + 7 * i as usize];
        p[0..4].copy_from_slice(&[4, 0, 0, 0]);
        p
    }

    // 클라 로컬로 패킷을 밀어 서버(→에코 wg0)를 돌아 되돌아오는지 센다.
    fn roundtrip(prefer: Prefer, udp_bind: SocketAddr, tcp_bind: SocketAddr, local_bind: SocketAddr) -> u32 {
        let (wg_addr, wg_stop, wg_thread, _) = spawn_echo();
        let fec = FecParams { k: 4, groups: 4, enabled: true };
        let skey = random_key();
        let server = run_server(server_cfg(udp_bind, tcp_bind, wg_addr, fec, skey)).unwrap();
        let client = run_client(client_cfg(udp_bind, tcp_bind, local_bind, fec, prefer, &skey)).unwrap();

        thread::sleep(Duration::from_millis(600)); // 전송 수립 대기

        let neptun = UdpSocket::bind(loopback(0)).unwrap();
        neptun.connect(local_bind).unwrap();
        neptun.set_read_timeout(Some(Duration::from_millis(800))).unwrap();

        let mut got = 0;
        for i in 0..20u8 {
            let payload = wg_packet(i);
            neptun.send(&payload).unwrap();
            let mut rbuf = [0u8; 2048];
            if let Ok(n) = neptun.recv(&mut rbuf) {
                if rbuf[..n] == payload[..] {
                    got += 1;
                }
            }
        }

        let kind = client.stats().kind;
        client.stop();
        server.stop();
        wg_stop.store(true, Ordering::Relaxed);
        let _ = wg_thread.join();
        // 요청한 전송이 실제로 쓰였는지 확인.
        match prefer {
            Prefer::Udp => assert_eq!(kind, Some(Kind::Udp)),
            Prefer::Tcp => assert_eq!(kind, Some(Kind::Tcp)),
            Prefer::Auto => {}
        }
        got
    }

    #[test]
    fn end_to_end_udp_echo() {
        let got = roundtrip(Prefer::Udp, loopback(39001), loopback(39002), loopback(39003));
        assert!(got >= 18, "udp 왕복 {got}/20");
    }

    #[test]
    fn end_to_end_tls_echo() {
        let got = roundtrip(Prefer::Tcp, loopback(39011), loopback(39012), loopback(39013));
        assert!(got >= 18, "tls 왕복 {got}/20");
    }

    // 서버 WG 키를 잘못 알면(가짜 서버·MITM) 클라가 ACK를 안 믿어 세션이 안 선다.
    #[test]
    fn wrong_server_key_never_connects() {
        let (wg_addr, wg_stop, wg_thread, _) = spawn_echo();
        let fec = FecParams::default();
        let (udp, tcp, local) = (loopback(39041), loopback(39042), loopback(39043));
        let server = run_server(server_cfg(udp, tcp, wg_addr, fec, random_key())).unwrap();
        let client = run_client(client_cfg(udp, tcp, local, fec, Prefer::Udp, &random_key())).unwrap();
        thread::sleep(Duration::from_millis(1800));
        let kind = client.stats().kind;
        client.stop();
        server.stop();
        wg_stop.store(true, Ordering::Relaxed);
        let _ = wg_thread.join();
        assert_eq!(kind, None);
    }

    // 리플레이: 같은 HELLO를 다시 보내면 ACK가 없고, 같은 데이터 패킷을 다시 보내면 wg0에 한 번만 간다.
    // 가로채기: 남의 session_id로 다른 WG 키의 HELLO를 보내도 그 세션에 못 붙는다.
    #[test]
    fn replay_and_hijack_rejected() {
        let (wg_addr, wg_stop, wg_thread, count) = spawn_echo();
        let fec = FecParams { k: 4, groups: 4, enabled: false };
        let skey = random_key();
        let server = run_server(server_cfg(loopback(0), loopback(0), wg_addr, fec, skey)).unwrap();
        let spub = Identity::from_bytes(skey).public();
        let hs = HandshakeKey::from_psk(b"secret");
        let me = Identity::generate();
        let k = me.shared(&spub).unwrap();

        let sock = UdpSocket::bind(loopback(0)).unwrap();
        sock.connect(server.udp_addr()).unwrap();
        sock.set_read_timeout(Some(Duration::from_millis(400))).unwrap();
        let mut rbuf = [0u8; 4096];
        let mut wire = Vec::new();
        let ask = |wire: &[u8], rbuf: &mut [u8]| -> Option<Vec<u8>> {
            sock.send(wire).unwrap();
            let n = sock.recv(rbuf).ok()?;
            let (kind, _, body) = transport::udp_parse(&rbuf[..n])?;
            (kind == MsgKind::Handshake).then(|| body.to_vec())
        };

        let hello = ClientHello::new(777, me.public());
        transport::udp_wrap(MsgKind::Handshake, &hello.seal(&hs, &k, UDP_HS_PAD), 5, &mut wire);
        assert_eq!(wire.len(), transport::QUIC_INITIAL_SIZE); // QUIC Initial 크기
        let mut ack_body = ask(&wire, &mut rbuf).expect("첫 HELLO엔 ACK");
        let ack = ServerAck::open(&hs, &mut ack_body, &k, &hello).expect("진짜 서버 ACK");
        assert!(ask(&wire, &mut rbuf).is_none(), "같은 HELLO 재전송엔 ACK 없음");

        // 데이터 한 개를 두 번 보낸다 → wg0엔 한 번만.
        let keys = SessionKeys::derive(&k, &hello.random, &ack.random, true);
        let sealed = seal_frame(&keys, &Frame::Data { group: 0, gen: 0, index: 0, k: 0, payload: b"one wg packet" });
        transport::udp_wrap(MsgKind::Data, &sealed, 5, &mut wire);
        sock.send(&wire).unwrap();
        sock.send(&wire).unwrap();
        thread::sleep(Duration::from_millis(300));
        assert_eq!(count.load(Ordering::Relaxed), 1, "재전송된 데이터가 wg0까지 감");

        // 다른 WG 키로 같은 session_id(777) HELLO → 가로채기 거절(ACK 없음).
        let evil = Identity::generate();
        let ke = evil.shared(&spub).unwrap();
        let fake = ClientHello::new(777, evil.public());
        transport::udp_wrap(MsgKind::Handshake, &fake.seal(&hs, &ke, UDP_HS_PAD), 6, &mut wire);
        assert!(ask(&wire, &mut rbuf).is_none(), "남의 세션 가로채기");

        // 오래된 시각의 HELLO(제대로 서명됐어도) → 거절.
        let stale = ClientHello { ts: crypto::now_unix() - crypto::HELLO_SKEW - 30, ..ClientHello::new(778, me.public()) };
        transport::udp_wrap(MsgKind::Handshake, &stale.seal(&hs, &k, UDP_HS_PAD), 7, &mut wire);
        assert!(ask(&wire, &mut rbuf).is_none(), "오래된 HELLO");

        server.stop();
        wg_stop.store(true, Ordering::Relaxed);
        let _ = wg_thread.join();
    }

    // 진짜 TLS로 붙어 nagoing이 아닌 걸 보내면(능동 탐침·브라우저) 평범한 HTTP 404가 온다.
    #[test]
    fn active_probe_gets_http_404() {
        let (wg_addr, wg_stop, wg_thread, _) = spawn_echo();
        let server = run_server(server_cfg(loopback(0), loopback(0), wg_addr, FecParams::default(), random_key())).unwrap();
        let tcp = TcpStream::connect(server.tcp_addr()).unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let conn = rustls::ClientConnection::new(
            transport::client_config().unwrap(),
            rustls::pki_types::ServerName::try_from("example.com").unwrap(),
        )
        .unwrap();
        let mut tls = rustls::StreamOwned::new(conn, tcp);
        tls.write_all(b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n").unwrap();
        let mut resp = Vec::new();
        let _ = tls.read_to_end(&mut resp);
        assert!(resp.starts_with(b"HTTP/1.1 404"), "got {:?}", String::from_utf8_lossy(&resp));
        server.stop();
        wg_stop.store(true, Ordering::Relaxed);
        let _ = wg_thread.join();
    }

    // TLS도 아닌 바이트만 보내고 붙어 있는 연결(또는 망 전환으로 버려진 연결)을 서버가 곧 끊는지.
    #[test]
    fn server_drops_idle_tcp() {
        let (wg_addr, wg_stop, wg_thread, _) = spawn_echo();
        let server = run_server(server_cfg(loopback(0), loopback(0), wg_addr, FecParams::default(), random_key())).unwrap();
        let mut s = TcpStream::connect(server.tcp_addr()).unwrap();
        s.write_all(&[0x16, 0x03, 0x01, 0x00, 0x00]).unwrap(); // 빈 '레코드' 하나
        s.set_read_timeout(Some(Duration::from_secs(6))).unwrap();
        let start = Instant::now();
        let mut buf = [0u8; 512];
        let closed = loop {
            match s.read(&mut buf) {
                Ok(0) => break true,
                Ok(_) => continue,
                Err(ref e) if is_timeout(e) => break false,
                Err(_) => break true, // RST
            }
        };
        server.stop();
        wg_stop.store(true, Ordering::Relaxed);
        let _ = wg_thread.join();
        assert!(closed, "유휴 TCP 연결이 안 끊김");
        assert!(start.elapsed() < Duration::from_secs(5), "끊기까지 {:?}", start.elapsed());
    }

    // 수립 중(서버가 답을 안 함)에도 stop()이 오래 매달리지 않는지 — 확장의 stopTunnel·watchdog이 기다린다.
    #[test]
    fn client_stop_is_quick_while_establishing() {
        // accept만 되고(백로그) 아무 답도 안 하는 서버 — TLS 핸드셰이크가 멈춘다.
        let mute = TcpListener::bind(loopback(0)).unwrap();
        let client = run_client(client_cfg(
            loopback(9),
            mute.local_addr().unwrap(),
            loopback(0),
            FecParams::default(),
            Prefer::Tcp,
            &random_key(),
        ))
        .unwrap();
        thread::sleep(Duration::from_millis(300));
        let start = Instant::now();
        client.stop();
        assert!(start.elapsed() < Duration::from_millis(1500), "stop {:?}", start.elapsed());
    }

    #[test]
    fn wg_shape_filter() {
        let mut data = vec![0u8; 48];
        data[0] = 4;
        assert!(looks_like_wg(&data));
        assert!(looks_like_wg(&{ let mut h = vec![0u8; 148]; h[0] = 1; h }));
        assert!(!looks_like_wg(&{ let mut h = vec![0u8; 149]; h[0] = 1; h })); // 핸드셰이크 길이 틀림
        assert!(!looks_like_wg(&[7u8; 48])); // 타입 아님
        assert!(looks_like_wg(&data[..41])); // 패딩 없는 데이터(NepTUN)도 받아야 한다 — 16 단위로 보면 대부분 버려진다
        assert!(!looks_like_wg(b"GET / HTTP/1.1\r\n\r\n"));
    }

    // 기기 안 다른 프로그램이 로컬 포트로 WG 아닌 걸 보내도 내려받기 대상(peer)이 그쪽으로 안 바뀌는지.
    #[test]
    fn stray_local_packet_does_not_steal_peer() {
        let (wg_addr, wg_stop, wg_thread, _) = spawn_echo();
        let fec = FecParams { k: 4, groups: 4, enabled: true };
        let (udp_bind, tcp_bind, local_bind) = (loopback(39031), loopback(39032), loopback(39033));
        let skey = random_key();
        let server = run_server(server_cfg(udp_bind, tcp_bind, wg_addr, fec, skey)).unwrap();
        let client = run_client(client_cfg(udp_bind, tcp_bind, local_bind, fec, Prefer::Udp, &skey)).unwrap();
        thread::sleep(Duration::from_millis(500));
        let neptun = UdpSocket::bind(loopback(0)).unwrap();
        neptun.connect(local_bind).unwrap();
        neptun.set_read_timeout(Some(Duration::from_millis(800))).unwrap();
        let other = UdpSocket::bind(loopback(0)).unwrap();
        let mut got = 0;
        for i in 0..10u8 {
            let p = wg_packet(i);
            neptun.send(&p).unwrap();
            other.send_to(b"not wireguard at all", local_bind).unwrap(); // 끼어들기
            let mut rbuf = [0u8; 2048];
            if let Ok(n) = neptun.recv(&mut rbuf) {
                if rbuf[..n] == p[..] {
                    got += 1;
                }
            }
        }
        client.stop();
        server.stop();
        wg_stop.store(true, Ordering::Relaxed);
        let _ = wg_thread.join();
        assert!(got >= 9, "끼어든 패킷 때문에 내려받기가 샘: {got}/10");
    }

    // UDP 서버가 없으면(막힌 망 흉내) 자동으로 TLS/TCP로 폴백하는지.
    #[test]
    fn auto_falls_back_to_tls() {
        let (wg_addr, wg_stop, wg_thread, _) = spawn_echo();
        let fec = FecParams { k: 4, groups: 4, enabled: true };
        let tcp_bind = loopback(39022);
        let dead_udp = loopback(39021); // 서버를 안 띄운 포트 → UDP HELLO가 실패해야 한다
        let skey = random_key();
        let server = run_server(server_cfg(loopback(39023), tcp_bind, wg_addr, fec, skey)).unwrap();
        let client = run_client(client_cfg(dead_udp, tcp_bind, loopback(39024), fec, Prefer::Auto, &skey)).unwrap();
        // 데드 UDP라도 핸드셰이크 타임아웃(최대 ~4.5s)까지 기다릴 수 있으므로 넉넉히.
        let mut kind = client.stats().kind;
        let start = Instant::now();
        while kind.is_none() && start.elapsed() < Duration::from_secs(9) {
            thread::sleep(Duration::from_millis(200));
            kind = client.stats().kind;
        }
        client.stop();
        server.stop();
        wg_stop.store(true, Ordering::Relaxed);
        let _ = wg_thread.join();
        assert_eq!(kind, Some(Kind::Tcp), "자동 선택이 TLS로 폴백해야 한다");
    }
}
