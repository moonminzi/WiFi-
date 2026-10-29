//! nagoing 프록시 — 클라이언트(폰)와 서버(AWS)의 중계 루프.
//!
//! 클라이언트: NepTUN이 로컬 UDP(127.0.0.1:local)로 보낸 WireGuard 데이터그램을 받아 FEC로 조각내고
//! 난독화해 전송(UDP 443→막히면 TLS/TCP 443)으로 서버에 보낸다. 반대로 서버에서 온 조각은 풀어서
//! NepTUN에게 돌려준다. WireGuard 자체는 로컬 소켓만 보므로 하나도 바뀌지 않는다.
//!
//! 서버: UDP(QUIC 모양)와 TCP(TLS 흉내)를 동시에 듣고, 세션별로 wg0(127.0.0.1:51820)에 UDP로 중계한다.
//! 세션은 session_id로 묶어 둬서, 클라이언트가 와이파이↔LTE로 바뀌어 주소가 달라져도(=재접속) 같은
//! wg0 소켓을 계속 쓴다. 그러면 서버가 보는 WireGuard 피어 엔드포인트가 안 바뀌어 WG 재핸드셰이크 없이
//! 이어진다(③ 빠른 전환의 핵심).

use std::collections::HashMap;
use std::io;
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use super::fec::{FecDecoder, FecEncoder, ShardRef};
use super::frame::{self, Frame, PROTOCOL_VERSION};
use super::obfs::{self, DIR_C2S, DIR_S2C};
use super::transport::{
    self, server_hello, Kind, RxHalf, TcpRx, TcpTx, TxHalf, UdpRx, UdpTx,
};
use super::{rand_bytes, rand_u64};

/// 수립된 전송 한 벌: 송신 반·수신 반·종류.
type Conn = (Box<dyn TxHalf>, Box<dyn RxHalf>, Kind);

const READ_TIMEOUT: Duration = Duration::from_millis(500);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(1500);
const KEEPALIVE: Duration = Duration::from_secs(5);
const HELLO_RETRIES: usize = 3;
const MAX_MSG: usize = 2048;
/// TCP 쓰기 제한. 한 클라이언트의 멈춘 쓰기가 잠금을 오래 쥐지 못하게 한다(①#2).
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);
/// 클라이언트가 이만큼 아무것도 못 받으면 전송을 다시 세운다(서버 재시작·NAT 변경 복구, #1).
const CLIENT_STALE: Duration = Duration::from_secs(15);
/// 서버가 이만큼 조용한 세션은 정리한다(자원 누수 방지, #5).
const SESSION_IDLE: Duration = Duration::from_secs(300);
/// 서버 TCP 연결이 이만큼 아무 프레임도 못 받으면 끊는다. 클라는 5초마다 PING하므로 살아 있는 연결은 안 걸린다.
/// 망을 바꾼 폰의 옛 연결(FIN 없이 사라짐)이나 레코드 하나만 보내고 붙어 있는 연결이 스레드·fd를 영영 쥐지 못하게.
const TCP_IDLE: Duration = if cfg!(test) { Duration::from_secs(2) } else { Duration::from_secs(30) };
/// 동시 TCP 연결 상한(연결마다 스레드 하나). 넘으면 새 연결은 바로 닫는다 — 스레드 고갈로 프로세스가 죽지 않게.
const MAX_TCP_CONNS: usize = 1024;
/// 세션 상한(세션마다 wg0 소켓 + 내려받기 스레드). PSK는 공개 소스에 있으므로 HELLO 남발을 막는다.
const MAX_SESSIONS: usize = 4096;
/// auto에서 UDP가 붙었다가 조용해지면(=도중에 막힘) 이 시간 동안은 TCP를 먼저 해 본다.
const UDP_PENALTY: Duration = Duration::from_secs(300);

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

/// ShardRef를 Frame으로.
fn shard_frame<'a>(shard: ShardRef<'a>) -> Frame<'a> {
    match shard {
        ShardRef::Data { seq, group, gen, index, k, payload } =>
            Frame::Data { seq, group, gen, index, k, payload },
        ShardRef::Parity { group, gen, k, payload } =>
            Frame::Parity { group, gen, k, payload },
    }
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
}

/// 클라이언트로 돌려보낼 경로. 복제가 싸서(Arc) 잠금 안에서는 복제만 하고 실제 전송은 잠금 밖에서 한다.
#[derive(Clone)]
enum Return {
    Udp { sock: Arc<UdpSocket>, addr: SocketAddr, cid: u32 },
    Tcp { tx: Arc<Mutex<TcpTx>> },
}

impl Return {
    fn send_frame(&self, key: &[u8; 32], frame: &Frame) -> io::Result<()> {
        let mut out = Vec::new();
        frame::encode(frame, key, DIR_S2C, &mut out);
        self.send(&out)
    }

    fn send(&self, inner: &[u8]) -> io::Result<()> {
        match self {
            Return::Udp { sock, addr, cid } => {
                let mut wrapped = Vec::new();
                transport::udp_wrap(inner, *cid, &mut wrapped);
                sock.send_to(&wrapped, *addr)?;
                Ok(())
            }
            Return::Tcp { tx } => tx.lock().unwrap().send_msg(inner),
        }
    }
}

struct Session {
    wg: UdpSocket, // wg0에 connect
    ret: Mutex<Return>,
    enc: Mutex<FecEncoder>, // wg→client
    dec: Mutex<FecDecoder>, // client→wg
    fec_on: bool,
    alive: Arc<AtomicBool>,
    recovered: Arc<AtomicU64>, // client→wg 방향에서 FEC로 되살린 조각 수(서버 전체 합산)
    last_seen: AtomicU64,      // 마지막 수신 시각(ms). 유휴 정리에 쓴다
}

impl Session {
    /// ★ ret 잠금은 경로를 복제하는 동안만 쥔다. 멈춘 TCP 쓰기(최대 WRITE_TIMEOUT)를 ret 잠금 안에서 하면,
    ///    같은 세션의 HELLO(망 전환)를 처리하려고 ret을 바꾸려는 UDP 루프가 그동안 멈춰 모든 UDP 클라가 선다(#2).
    fn send_frame(&self, key: &[u8; 32], frame: &Frame) -> io::Result<()> {
        let ret = self.ret.lock().unwrap().clone();
        ret.send_frame(key, frame)
    }

    fn touch(&self) {
        self.last_seen.store(now_ms(), Ordering::Relaxed);
    }

    /// 클라이언트→wg0: 받은 조각은 바로 wg0로, FEC로 되살린 조각도 wg0로.
    fn inbound(&self, frame: Frame) {
        match frame {
            Frame::Data { group, gen, index, k, payload, .. } => {
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
    key: [u8; 32],
    upstream: SocketAddr,
    fec: FecParams,
    sessions: Mutex<HashMap<u64, Arc<Session>>>,
    by_udp: Mutex<HashMap<SocketAddr, u64>>,
    by_cid: Mutex<HashMap<u32, u64>>, // 클라이언트 cid → 세션. NAT로 주소가 바뀌어도 cid로 찾는다(#1)
    stop: AtomicBool,
    recovered: Arc<AtomicU64>,
    tcp_conns: AtomicUsize, // 지금 살아 있는 TCP 연결 스레드 수(MAX_TCP_CONNS 상한)
}

impl ServerInner {
    /// 세션을 찾거나 만든다. 이미 있으면 반환 경로(ret)만 새 것으로 바꾼다(재접속/망 전환).
    /// ★ 세션 표(sessions) 잠금을 쥔 채로는 절대 ret 잠금을 기다리지 않는다. ret은 멈춘 TCP 쓰기가
    ///    오래 쥘 수 있어서(쓰기 제한은 있지만), 그걸 표 잠금과 겹치면 서버 전체가 멈춘다(#2).
    fn attach(self: &Arc<Self>, session_id: u64, ret: Return) -> io::Result<Arc<Session>> {
        // 1) 이미 있으면 표 잠금을 먼저 풀고(clone 후 release) 밖에서 ret만 교체.
        if let Some(s) = self.sessions.lock().unwrap().get(&session_id).cloned() {
            *s.ret.lock().unwrap() = ret;
            s.touch();
            return Ok(s);
        }
        // 2) 새 세션. 소켓 바인드는 블로킹이 아니라 표 잠금 안에서 해도 되지만, ret 잠금은 절대 안 건드린다.
        let wg = UdpSocket::bind(if self.upstream.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" })?;
        wg.connect(self.upstream)?;
        wg.set_read_timeout(Some(READ_TIMEOUT))?;
        let mut map = self.sessions.lock().unwrap();
        if let Some(s) = map.get(&session_id).cloned() {
            // 그사이 다른 HELLO가 만들었으면 표 잠금을 풀고 ret만 교체.
            drop(map);
            *s.ret.lock().unwrap() = ret;
            s.touch();
            return Ok(s);
        }
        if map.len() >= MAX_SESSIONS {
            return Err(io::Error::other("too many sessions"));
        }
        let session = Arc::new(Session {
            wg,
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
            // 스레드를 못 만들면(자원 고갈) 세션을 되돌린다. thread::spawn이었다면 panic → panic=abort로 서버가 죽었다.
            self.sessions.lock().unwrap().remove(&session_id);
            return Err(e);
        }
        Ok(session)
    }

    /// UDP 데이터그램의 세션을 찾는다. 주소로 먼저, 없으면 cid로(통신사 NAT가 포트를 바꾼 경우) 찾아
    /// 반환 경로를 새 주소로 갱신한다(#1). 세션 표·cid 표 잠금을 쥔 채 ret을 만지지 않는다.
    fn resolve_udp(&self, from: SocketAddr, cid: Option<u32>, udp: &Arc<UdpSocket>) -> Option<Arc<Session>> {
        if let Some(id) = self.by_udp.lock().unwrap().get(&from).copied() {
            if let Some(s) = self.sessions.lock().unwrap().get(&id).cloned() {
                return Some(s);
            }
        }
        let cid = cid?;
        let id = self.by_cid.lock().unwrap().get(&cid).copied()?;
        let s = self.sessions.lock().unwrap().get(&id).cloned()?;
        self.by_udp.lock().unwrap().insert(from, id);
        *s.ret.lock().unwrap() = Return::Udp { sock: udp.clone(), addr: from, cid };
        Some(s)
    }

    /// wg0→client 펌프: wg0에서 읽은 응답을 FEC로 조각내 클라이언트에게 보낸다.
    fn spawn_downpump(self: Arc<Self>, session: Arc<Session>) -> io::Result<()> {
        thread::Builder::new().name("nagoing-down".into()).spawn(move || {
            let mut buf = [0u8; MAX_MSG];
            while session.alive.load(Ordering::Relaxed) && !self.stop.load(Ordering::Relaxed) {
                match session.wg.recv(&mut buf) {
                    Ok(n) => {
                        let payload = &buf[..n];
                        if session.fec_on {
                            let key = &self.key;
                            session.enc.lock().unwrap().push(payload, |shard| {
                                let _ = session.send_frame(key, &shard_frame(shard));
                            });
                        } else {
                            let _ = session.send_frame(&self.key, &Frame::Data {
                                seq: 0, group: 0, gen: 0, index: 0, k: 0, payload,
                            });
                        }
                    }
                    Err(e) if is_timeout(&e) => continue,
                    Err(_) => break,
                }
            }
        })?;
        Ok(())
    }

    /// 유휴 세션을 정리한다(자원 누수 방지, #5). SESSION_IDLE 동안 조용하면 내려받기 스레드를 멈추고
    /// 세션·주소·cid 표에서 뺀다.
    fn reap(&self) {
        let cutoff = now_ms().saturating_sub(SESSION_IDLE.as_millis() as u64);
        let dead: Vec<u64> = self.sessions.lock().unwrap().iter()
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
        // TCP 연결 스레드는 stop 플래그를 READ_TIMEOUT마다 확인해 스스로 빠진다(fd를 따로 들고 있지 않음).
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

pub fn run_server(cfg: ServerConfig) -> io::Result<ServerHandle> {
    let inner = Arc::new(ServerInner {
        key: obfs::derive_key(cfg.psk.as_bytes()),
        upstream: cfg.upstream,
        fec: cfg.fec,
        sessions: Mutex::new(HashMap::new()),
        by_udp: Mutex::new(HashMap::new()),
        by_cid: Mutex::new(HashMap::new()),
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

    // UDP 수신 루프
    {
        let inner = inner.clone();
        let udp = udp.clone();
        threads.push(thread::spawn(move || server_udp_loop(inner, udp)));
    }
    // TCP accept 루프
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
                    if inner.stop.load(Ordering::Relaxed) { return; }
                    thread::sleep(Duration::from_millis(500));
                }
                inner.reap();
            }
        }));
    }

    Ok(ServerHandle { inner, threads, udp_addr, tcp_addr })
}

fn server_udp_loop(inner: Arc<ServerInner>, udp: Arc<UdpSocket>) {
    let mut buf = [0u8; MAX_MSG + 8];
    while !inner.stop.load(Ordering::Relaxed) {
        let (n, from) = match udp.recv_from(&mut buf) {
            Ok(v) => v,
            Err(e) if is_timeout(&e) => continue,
            Err(_) => continue,
        };
        let cid = transport::udp_cid(&buf[..n]);
        let inner_msg = match transport::udp_unwrap(&buf[..n]) {
            Some(m) => m,
            None => continue,
        };
        let mut msg = inner_msg.to_vec();
        let frame = match frame::decode(&mut msg, &inner.key, DIR_C2S) {
            Some(f) => f,
            None => continue,
        };
        match frame {
            Frame::Hello { session, .. } => {
                let ret_cid = cid.unwrap_or_else(|| rand_u64() as u32);
                let ret = Return::Udp { sock: udp.clone(), addr: from, cid: ret_cid };
                match inner.attach(session, ret.clone()) {
                    Ok(_) => {
                        inner.by_udp.lock().unwrap().insert(from, session);
                        if let Some(c) = cid {
                            inner.by_cid.lock().unwrap().insert(c, session);
                        }
                        // 답은 HELLO가 온 그 경로로 바로(세션 ret을 거치면 그사이 바뀐 TCP 경로로 갈 수 있다).
                        let _ = ret.send_frame(&inner.key, &Frame::HelloAck { session });
                    }
                    Err(_) => continue,
                }
            }
            Frame::Ping { token } => {
                if let Some(s) = inner.resolve_udp(from, cid, &udp) {
                    s.touch();
                    // PONG은 PING이 온 주소로 바로 보낸다. 이 UDP 루프는 모든 클라가 같이 쓰므로
                    // 세션의 (멈췄을 수도 있는) TCP 경로로 쓰다가 막히면 안 된다.
                    let ret = Return::Udp { sock: udp.clone(), addr: from, cid: cid.unwrap_or(0) };
                    let _ = ret.send_frame(&inner.key, &Frame::Pong { token });
                }
            }
            Frame::Data { .. } | Frame::Parity { .. } => {
                if let Some(s) = inner.resolve_udp(from, cid, &udp) {
                    s.touch();
                    s.inbound(frame);
                }
            }
            _ => {}
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
    // 멈춘 쓰기가 ret 잠금을 오래 쥐지 못하게 쓰기 제한을 둔다(#2).
    stream.set_write_timeout(Some(WRITE_TIMEOUT))?;
    let read = stream.try_clone()?;
    // 짧은 타임아웃으로 종료를 폴링. TcpRx가 버퍼드라 타임아웃에 프레임이 깨지지 않는다.
    read.set_read_timeout(Some(READ_TIMEOUT))?;
    let mut rx = TcpRx::new(read);
    let mut buf = [0u8; MAX_MSG];

    // ClientHello(모양) 하나 읽어 버리고 ServerHello(모양) 보낸다. 핸드셰이크는 데드라인까지 기다린다.
    let deadline = Instant::now() + HANDSHAKE_TIMEOUT.max(Duration::from_secs(3));
    loop {
        if Instant::now() > deadline {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "no client-hello"));
        }
        match rx.recv_msg(&mut buf) {
            Ok(_) => break,
            Err(ref e) if is_timeout(e) => continue,
            Err(e) => return Err(e),
        }
    }
    let mut random = [0u8; 32];
    rand_bytes(&mut random);
    // 끝낼 때 소켓을 닫는 손잡이. tx는 세션 ret에도 들려 있어서 이 스레드가 끝나도 fd가 안 닫힐 수 있다.
    let ctl = stream.try_clone()?;
    let tx = Arc::new(Mutex::new(TcpTx::new(stream)));
    tx.lock().unwrap().send_raw(&server_hello(&random))?;
    let ret = Return::Tcp { tx };

    let mut session: Option<Arc<Session>> = None;
    let mut last_frame = Instant::now();
    while !inner.stop.load(Ordering::Relaxed) {
        // 살아 있는 클라는 5초마다 PING한다. TCP_IDLE 동안 프레임이 없으면 죽은 연결(망 전환으로 FIN 없이
        // 사라진 옛 연결, 레코드 하나 보내고 붙어만 있는 연결)로 보고 스레드·fd를 놓는다.
        if last_frame.elapsed() > TCP_IDLE {
            break;
        }
        let n = match rx.recv_msg(&mut buf) {
            Ok(n) => n,
            Err(ref e) if is_timeout(e) => continue,
            Err(_) => break,
        };
        let mut msg = buf[..n].to_vec();
        let frame = match frame::decode(&mut msg, &inner.key, DIR_C2S) {
            Some(f) => f,
            None => continue,
        };
        last_frame = Instant::now();
        match frame {
            Frame::Hello { session: id, .. } => {
                if let Ok(s) = inner.attach(id, ret.clone()) {
                    let _ = ret.send_frame(&inner.key, &Frame::HelloAck { session: id });
                    session = Some(s);
                }
            }
            Frame::Ping { token } => {
                if let Some(s) = &session {
                    s.touch();
                    // PONG은 이 연결로(세션 ret은 그사이 다른 경로로 바뀌었을 수 있다).
                    let _ = ret.send_frame(&inner.key, &Frame::Pong { token });
                }
            }
            Frame::Data { .. } | Frame::Parity { .. } => {
                if let Some(s) = &session {
                    s.touch();
                    s.inbound(frame);
                }
            }
            _ => {}
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
}

struct ClientInner {
    key: [u8; 32],
    session_id: u64,
    cfg: ClientConfig,
    local: UdpSocket,
    peer: Mutex<Option<SocketAddr>>,
    tx: Mutex<Option<Box<dyn TxHalf>>>,
    rx: Mutex<Option<Box<dyn RxHalf>>>,
    enc: Mutex<FecEncoder>, // c2s
    dec: Mutex<FecDecoder>, // s2c
    last_rx: AtomicU64,     // 마지막 수신 시각(ms). 오래 조용하면 전송을 다시 세운다(#1)
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
        let mut out = Vec::new();
        frame::encode(frame, &self.key, DIR_C2S, &mut out);
        let mut g = self.tx.lock().unwrap();
        if let Some(tx) = g.as_mut() {
            if tx.send_msg(&out).is_err() {
                self.rebind.store(true, Ordering::Relaxed);
            } else {
                self.st_sent.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    fn deliver(&self, payload: &[u8]) {
        if let Some(addr) = *self.peer.lock().unwrap() {
            let _ = self.local.send_to(payload, addr);
        }
    }

    fn handle_down(&self, frame: Frame) {
        match frame {
            Frame::Data { group, gen, index, k, payload, .. } => {
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

    // 전송 수립(자동 선택). HELLO를 보내고 HELLO_ACK를 기다린다.
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

    fn hello_bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        frame::encode(&Frame::Hello { session: self.session_id, version: PROTOCOL_VERSION },
                      &self.key, DIR_C2S, &mut out);
        out
    }

    fn try_udp(&self) -> io::Result<Conn> {
        let server = self.cfg.server_udp;
        let bind = if server.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
        let sock = UdpSocket::bind(bind)?;
        sock.connect(server)?;
        sock.set_read_timeout(Some(HANDSHAKE_TIMEOUT))?;
        let cid = rand_u64() as u32;
        let mut rbuf = [0u8; MAX_MSG + 8];
        for _ in 0..HELLO_RETRIES {
            // stop()이 수립 중에도 빨리 끝나게(확장의 stopTunnel·watchdog이 join을 기다린다).
            if self.stopped() {
                return Err(Self::stopped_err());
            }
            let hello = self.hello_bytes();
            let mut wrapped = Vec::new();
            transport::udp_wrap(&hello, cid, &mut wrapped);
            sock.send(&wrapped)?;
            match sock.recv(&mut rbuf) {
                Ok(n) => {
                    if let Some(inner) = transport::udp_unwrap(&rbuf[..n]) {
                        let mut m = inner.to_vec();
                        if let Some(Frame::HelloAck { session }) = frame::decode(&mut m, &self.key, DIR_S2C) {
                            if session == self.session_id {
                                sock.set_read_timeout(Some(READ_TIMEOUT))?;
                                let rx_sock = sock.try_clone()?;
                                return Ok((
                                    Box::new(UdpTx::new(sock, cid)),
                                    Box::new(UdpRx::new(rx_sock)),
                                    Kind::Udp,
                                ));
                            }
                        }
                    }
                }
                Err(ref e) if is_timeout(e) => continue,
                Err(e) => return Err(e),
            }
        }
        Err(io::Error::new(io::ErrorKind::TimedOut, "no udp hello-ack"))
    }

    fn try_tcp(&self) -> io::Result<Conn> {
        // connect에 제한을 둬서 SYN이 사라지는 망에서 오래 매달리지 않게 한다(#6).
        let stream = TcpStream::connect_timeout(&self.cfg.server_tcp, Duration::from_secs(3))?;
        stream.set_nodelay(true)?;
        // 짧은 읽기 제한으로 데드라인·stop을 자주 확인한다(TcpRx가 버퍼드라 타임아웃에 레코드가 안 깨진다).
        stream.set_read_timeout(Some(READ_TIMEOUT))?;
        // 멈춘 쓰기가 tx 잠금을 오래 쥐지 못하게 한다(#2).
        stream.set_write_timeout(Some(WRITE_TIMEOUT))?;
        if self.stopped() {
            return Err(Self::stopped_err());
        }
        let mut random = [0u8; 32];
        rand_bytes(&mut random);
        // ClientHello(모양) 보내고 ServerHello(모양) 한 레코드 받기.
        let mut tx = TcpTx::new(stream.try_clone()?);
        tx.send_raw(&transport::client_hello(&self.cfg.sni, &random))?;
        let mut rx = TcpRx::new(stream.try_clone()?);
        let mut buf = [0u8; MAX_MSG];
        let deadline = Instant::now() + HANDSHAKE_TIMEOUT.max(Duration::from_secs(3));
        loop {
            if self.stopped() {
                return Err(Self::stopped_err());
            }
            if Instant::now() > deadline {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "no server-hello"));
            }
            match rx.recv_msg(&mut buf) {
                Ok(_) => break, // ServerHello 버림
                Err(ref e) if is_timeout(e) => continue,
                Err(e) => return Err(e),
            }
        }

        // HELLO 보내고 HELLO_ACK 기다리기.
        tx.send_msg(&self.hello_bytes())?;
        let deadline = Instant::now() + HANDSHAKE_TIMEOUT.max(Duration::from_secs(3));
        loop {
            if self.stopped() {
                return Err(Self::stopped_err());
            }
            if Instant::now() > deadline {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "no tcp hello-ack"));
            }
            match rx.recv_msg(&mut buf) {
                Ok(n) => {
                    let mut m = buf[..n].to_vec();
                    if let Some(Frame::HelloAck { session }) = frame::decode(&mut m, &self.key, DIR_S2C) {
                        if session == self.session_id {
                            break;
                        }
                    }
                }
                Err(ref e) if is_timeout(e) => continue,
                Err(e) => return Err(e),
            }
        }
        stream.set_read_timeout(Some(READ_TIMEOUT))?;
        Ok((Box::new(tx), Box::new(rx), Kind::Tcp))
    }
}

pub struct ClientHandle {
    inner: Arc<ClientInner>,
    threads: Vec<JoinHandle<()>>,
}

impl ClientHandle {
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
            Some(Kind::Tcp) => "tcp",
            None => "down",
        };
        format!("{k} · tx {} · rx {} · fec+{}", self.sent, self.recv, self.recovered)
    }
}

pub fn run_client(cfg: ClientConfig) -> io::Result<ClientHandle> {
    let local = UdpSocket::bind(cfg.local_bind)?;
    local.set_read_timeout(Some(READ_TIMEOUT))?;
    let inner = Arc::new(ClientInner {
        key: obfs::derive_key(cfg.psk.as_bytes()),
        session_id: rand_u64(),
        local,
        peer: Mutex::new(None),
        tx: Mutex::new(None),
        rx: Mutex::new(None),
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

fn client_up_loop(inner: Arc<ClientInner>) {
    let mut buf = [0u8; MAX_MSG];
    let fec_on = inner.cfg.fec.enabled;
    while !inner.stop.load(Ordering::Relaxed) {
        let (n, from) = match inner.local.recv_from(&mut buf) {
            Ok(v) => v,
            Err(ref e) if is_timeout(e) => continue,
            Err(_) => continue,
        };
        *inner.peer.lock().unwrap() = Some(from);
        let payload = &buf[..n];
        if fec_on {
            inner.enc.lock().unwrap().push(payload, |shard| {
                inner.send_frame(&shard_frame(shard));
            });
        } else {
            inner.send_frame(&Frame::Data { seq: 0, group: 0, gen: 0, index: 0, k: 0, payload });
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
            Ok(n) => {
                inner.st_recv.fetch_add(1, Ordering::Relaxed);
                let mut m = buf[..n].to_vec();
                if let Some(frame) = frame::decode(&mut m, &inner.key, DIR_S2C) {
                    // 살아 있음 표시(#1 stale 판단)는 제대로 풀린 프레임에만. 어긋난 TCP 스트림의 쓰레기 바이트가
                    // 계속 들어와도 '살아 있다'고 착각해 재접속을 안 하는 일이 없게.
                    inner.last_rx.store(now_ms(), Ordering::Relaxed);
                    inner.handle_down(frame);
                }
            }
            Err(ref e) if is_timeout(e) => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(_) => {
                // 전송이 깨졌거나 아직 없음 → 재수립 요청하고 잠깐 쉰다.
                inner.rebind.store(true, Ordering::Relaxed);
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

fn client_supervisor(inner: Arc<ClientInner>) {
    while !inner.stop.load(Ordering::Relaxed) {
        match inner.establish() {
            Ok((tx, rx, kind)) => {
                *inner.tx.lock().unwrap() = Some(tx);
                *inner.rx.lock().unwrap() = Some(rx);
                inner.st_kind.store(match kind { Kind::Udp => 1, Kind::Tcp => 2 }, Ordering::Relaxed);
                inner.last_rx.store(now_ms(), Ordering::Relaxed); // 방금 붙음 → stale 타이머 리셋
                inner.rebind.store(false, Ordering::Relaxed);
            }
            Err(_) => {
                if inner.stop.load(Ordering::Relaxed) { break; }
                thread::sleep(Duration::from_secs(1));
                continue;
            }
        }
        let mut last_ping = Instant::now();
        // keepalive PING(5초)에 PONG이 오면 last_rx가 갱신된다. CLIENT_STALE 동안 아무것도 못 받으면
        // 서버 재시작/NAT 변경으로 보고 전송을 다시 세운다(#1). 서울처럼 IP가 안 바뀌어도 복구된다.
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
        inner.st_kind.store(0, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    fn loopback(port: u16) -> SocketAddr {
        SocketAddr::from((Ipv4Addr::LOCALHOST, port))
    }

    // 받은 걸 그대로 돌려보내는 가짜 wg0(에코)을 띄우고 주소·정지 핸들을 돌려준다.
    fn spawn_echo() -> (SocketAddr, Arc<AtomicBool>, JoinHandle<()>) {
        let wg = UdpSocket::bind(loopback(0)).unwrap();
        let addr = wg.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stop2 = stop.clone();
        let handle = thread::spawn(move || {
            wg.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
            let mut buf = [0u8; 2048];
            while !stop2.load(Ordering::Relaxed) {
                if let Ok((n, from)) = wg.recv_from(&mut buf) {
                    let _ = wg.send_to(&buf[..n], from);
                }
            }
        });
        (addr, stop, handle)
    }

    // 클라 로컬로 패킷을 밀어 서버(→에코 wg0)를 돌아 되돌아오는지 센다.
    fn roundtrip(prefer: Prefer, udp_bind: SocketAddr, tcp_bind: SocketAddr, local_bind: SocketAddr) -> u32 {
        let (wg_addr, wg_stop, wg_thread) = spawn_echo();
        let fec = FecParams { k: 4, groups: 4, enabled: true };
        let server = run_server(ServerConfig {
            psk: "secret".into(),
            udp_bind, tcp_bind, upstream: wg_addr, fec,
        }).unwrap();
        let client = run_client(ClientConfig {
            psk: "secret".into(),
            server_udp: udp_bind, server_tcp: tcp_bind, local_bind, fec, prefer,
            sni: "www.cloudflare.com".into(),
        }).unwrap();

        thread::sleep(Duration::from_millis(500)); // 전송 수립 대기

        let neptun = UdpSocket::bind(loopback(0)).unwrap();
        neptun.connect(local_bind).unwrap();
        neptun.set_read_timeout(Some(Duration::from_millis(800))).unwrap();

        let mut got = 0;
        for i in 0..20u8 {
            let payload = vec![i; 40 + i as usize];
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
    fn end_to_end_tcp_echo() {
        let got = roundtrip(Prefer::Tcp, loopback(39011), loopback(39012), loopback(39013));
        assert!(got >= 18, "tcp 왕복 {got}/20");
    }

    // PSK 없이 레코드 하나만 보내고 붙어 있는 연결(또는 망 전환으로 버려진 옛 연결)을 서버가 TCP_IDLE 뒤 끊는지.
    #[test]
    fn server_drops_idle_tcp() {
        use std::io::{Read, Write};
        let (wg_addr, wg_stop, wg_thread) = spawn_echo();
        let server = run_server(ServerConfig {
            psk: "secret".into(),
            udp_bind: loopback(0), tcp_bind: loopback(0), upstream: wg_addr, fec: FecParams::default(),
        }).unwrap();
        let mut s = TcpStream::connect(server.tcp_addr()).unwrap();
        s.write_all(&[0x16, 0x03, 0x01, 0x00, 0x00]).unwrap(); // 빈 '레코드' 하나
        s.set_read_timeout(Some(Duration::from_secs(6))).unwrap();
        let start = Instant::now();
        let mut buf = [0u8; 512];
        let closed = loop {
            match s.read(&mut buf) {
                Ok(0) => break true,
                Ok(_) => continue, // ServerHello
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
        // accept만 되고(백로그) 아무 답도 안 하는 서버.
        let mute = TcpListener::bind(loopback(0)).unwrap();
        let client = run_client(ClientConfig {
            psk: "secret".into(),
            server_udp: loopback(9), server_tcp: mute.local_addr().unwrap(), local_bind: loopback(0),
            fec: FecParams::default(), prefer: Prefer::Tcp, sni: "www.cloudflare.com".into(),
        }).unwrap();
        thread::sleep(Duration::from_millis(300)); // ServerHello 기다리는 중
        let start = Instant::now();
        client.stop();
        assert!(start.elapsed() < Duration::from_millis(1500), "stop {:?}", start.elapsed());
    }

    // UDP 서버가 없으면(막힌 망 흉내) 자동으로 TCP로 폴백하는지.
    #[test]
    fn auto_falls_back_to_tcp() {
        let (wg_addr, wg_stop, wg_thread) = spawn_echo();
        let fec = FecParams { k: 4, groups: 4, enabled: true };
        let tcp_bind = loopback(39022);
        // udp_bind은 서버를 안 띄운 포트 → UDP HELLO가 실패하고 TCP로 내려가야 한다.
        let dead_udp = loopback(39021);
        let server = run_server(ServerConfig {
            psk: "secret".into(),
            udp_bind: loopback(39023), // 서버는 다른 UDP 포트에서 듣는다(클라는 모름)
            tcp_bind, upstream: wg_addr, fec,
        }).unwrap();
        let local_bind = loopback(39024);
        let client = run_client(ClientConfig {
            psk: "secret".into(),
            server_udp: dead_udp, server_tcp: tcp_bind, local_bind, fec,
            prefer: Prefer::Auto, sni: "www.cloudflare.com".into(),
        }).unwrap();

        thread::sleep(Duration::from_millis(600));
        // 데드 UDP라도 핸드셰이크 타임아웃(최대 ~4.5s)까지 기다릴 수 있으므로 넉넉히.
        let mut kind = client.stats().kind;
        let start = Instant::now();
        while kind.is_none() && start.elapsed() < Duration::from_secs(8) {
            thread::sleep(Duration::from_millis(200));
            kind = client.stats().kind;
        }
        client.stop();
        server.stop();
        wg_stop.store(true, Ordering::Relaxed);
        let _ = wg_thread.join();
        assert_eq!(kind, Some(Kind::Tcp), "자동 선택이 TCP로 폴백해야 한다");
    }
}
