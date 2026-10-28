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
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
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

enum Return {
    Udp { sock: Arc<UdpSocket>, addr: SocketAddr, cid: u32 },
    Tcp { tx: Arc<Mutex<TcpTx>> },
}

impl Return {
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
    tx_ctr: AtomicU64,      // s2c nonce
    fec_on: bool,
    alive: Arc<AtomicBool>,
    recovered: Arc<AtomicU64>, // client→wg 방향에서 FEC로 되살린 조각 수(서버 전체 합산)
}

impl Session {
    fn send_frame(&self, key: &[u8; 32], frame: &Frame) -> io::Result<()> {
        let ctr = self.tx_ctr.fetch_add(1, Ordering::Relaxed);
        let mut out = Vec::new();
        frame::encode(frame, key, DIR_S2C, ctr, &mut out);
        self.ret.lock().unwrap().send(&out)
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
    stop: AtomicBool,
    recovered: Arc<AtomicU64>,
}

impl ServerInner {
    /// 세션을 찾거나 만든다. 이미 있으면 반환 경로(ret)만 새 것으로 바꾼다(재접속/망 전환).
    fn attach(self: &Arc<Self>, session_id: u64, ret: Return) -> io::Result<Arc<Session>> {
        let mut map = self.sessions.lock().unwrap();
        if let Some(s) = map.get(&session_id) {
            *s.ret.lock().unwrap() = ret;
            return Ok(s.clone());
        }
        let wg = UdpSocket::bind(if self.upstream.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" })?;
        wg.connect(self.upstream)?;
        wg.set_read_timeout(Some(READ_TIMEOUT))?;
        let session = Arc::new(Session {
            wg,
            ret: Mutex::new(ret),
            enc: Mutex::new(FecEncoder::new(self.fec.k, self.fec.groups)),
            dec: Mutex::new(FecDecoder::new()),
            tx_ctr: AtomicU64::new(0),
            fec_on: self.fec.enabled,
            alive: Arc::new(AtomicBool::new(true)),
            recovered: self.recovered.clone(),
        });
        map.insert(session_id, session.clone());
        drop(map);
        self.clone().spawn_downpump(session.clone());
        Ok(session)
    }

    /// wg0→client 펌프: wg0에서 읽은 응답을 FEC로 조각내 클라이언트에게 보낸다.
    fn spawn_downpump(self: Arc<Self>, session: Arc<Session>) {
        thread::spawn(move || {
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
        });
    }

    fn route(self: &Arc<Self>, session_id: Option<u64>, frame: Frame) {
        if let Some(id) = session_id {
            if let Some(s) = self.sessions.lock().unwrap().get(&id) {
                s.inbound(frame);
            }
        }
    }
}

pub struct ServerHandle {
    inner: Arc<ServerInner>,
    threads: Vec<JoinHandle<()>>,
    tcp_conns: Arc<Mutex<Vec<TcpStream>>>,
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
        for c in self.tcp_conns.lock().unwrap().iter() {
            let _ = c.shutdown(std::net::Shutdown::Both);
        }
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
        stop: AtomicBool::new(false),
        recovered: Arc::new(AtomicU64::new(0)),
    });

    let udp = Arc::new(UdpSocket::bind(cfg.udp_bind)?);
    udp.set_read_timeout(Some(READ_TIMEOUT))?;
    let udp_addr = udp.local_addr()?;
    let listener = TcpListener::bind(cfg.tcp_bind)?;
    let tcp_addr = listener.local_addr()?;
    listener.set_nonblocking(true)?;

    let tcp_conns: Arc<Mutex<Vec<TcpStream>>> = Arc::new(Mutex::new(Vec::new()));
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
        let conns = tcp_conns.clone();
        threads.push(thread::spawn(move || server_tcp_loop(inner, listener, conns)));
    }

    Ok(ServerHandle { inner, threads, tcp_conns, udp_addr, tcp_addr })
}

fn server_udp_loop(inner: Arc<ServerInner>, udp: Arc<UdpSocket>) {
    let mut buf = [0u8; MAX_MSG + 8];
    while !inner.stop.load(Ordering::Relaxed) {
        let (n, from) = match udp.recv_from(&mut buf) {
            Ok(v) => v,
            Err(e) if is_timeout(&e) => continue,
            Err(_) => continue,
        };
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
                let cid = rand_u64() as u32;
                let ret = Return::Udp { sock: udp.clone(), addr: from, cid };
                match inner.attach(session, ret) {
                    Ok(s) => {
                        inner.by_udp.lock().unwrap().insert(from, session);
                        let _ = s.send_frame(&inner.key, &Frame::HelloAck { session });
                    }
                    Err(_) => continue,
                }
            }
            Frame::Ping { token } => {
                let id = inner.by_udp.lock().unwrap().get(&from).copied();
                if let Some(id) = id {
                    if let Some(s) = inner.sessions.lock().unwrap().get(&id) {
                        // 반환 경로를 최신 주소로 갱신하고 Pong.
                        *s.ret.lock().unwrap() = Return::Udp { sock: udp.clone(), addr: from, cid: rand_u64() as u32 };
                        let _ = s.send_frame(&inner.key, &Frame::Pong { token });
                    }
                }
            }
            Frame::Data { .. } | Frame::Parity { .. } => {
                let id = inner.by_udp.lock().unwrap().get(&from).copied();
                inner.route(id, frame);
            }
            _ => {}
        }
    }
}

fn server_tcp_loop(inner: Arc<ServerInner>, listener: TcpListener, conns: Arc<Mutex<Vec<TcpStream>>>) {
    while !inner.stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _peer)) => {
                if let Ok(clone) = stream.try_clone() {
                    conns.lock().unwrap().push(clone);
                }
                let inner = inner.clone();
                thread::spawn(move || {
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
    let tx = Arc::new(Mutex::new(TcpTx::new(stream)));
    tx.lock().unwrap().send_raw(&server_hello(&random))?;

    let mut session: Option<Arc<Session>> = None;
    while !inner.stop.load(Ordering::Relaxed) {
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
        match frame {
            Frame::Hello { session: id, .. } => {
                let ret = Return::Tcp { tx: tx.clone() };
                if let Ok(s) = inner.attach(id, ret) {
                    let _ = s.send_frame(&inner.key, &Frame::HelloAck { session: id });
                    session = Some(s);
                }
            }
            Frame::Ping { token } => {
                if let Some(s) = &session {
                    let _ = s.send_frame(&inner.key, &Frame::Pong { token });
                }
            }
            Frame::Data { .. } | Frame::Parity { .. } => {
                if let Some(s) = &session {
                    s.inbound(frame);
                }
            }
            _ => {}
        }
    }
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
    tx_ctr: AtomicU64,
    stop: AtomicBool,
    rebind: AtomicBool,
    st_sent: AtomicU64,
    st_recv: AtomicU64,
    st_recovered: AtomicU64,
    st_kind: AtomicU8, // 0 none, 1 udp, 2 tcp
}

impl ClientInner {
    fn send_frame(&self, frame: &Frame) {
        let ctr = self.tx_ctr.fetch_add(1, Ordering::Relaxed);
        let mut out = Vec::new();
        frame::encode(frame, &self.key, DIR_C2S, ctr, &mut out);
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

    // 전송 수립(자동 선택). HELLO를 보내고 HELLO_ACK를 기다린다.
    fn establish(&self) -> io::Result<Conn> {
        if matches!(self.cfg.prefer, Prefer::Auto | Prefer::Udp) {
            match self.try_udp() {
                Ok(v) => return Ok(v),
                Err(_) if matches!(self.cfg.prefer, Prefer::Udp) => {
                    return Err(io::Error::new(io::ErrorKind::TimedOut, "udp handshake failed"));
                }
                Err(_) => {}
            }
        }
        self.try_tcp()
    }

    fn hello_bytes(&self) -> Vec<u8> {
        let ctr = self.tx_ctr.fetch_add(1, Ordering::Relaxed);
        let mut out = Vec::new();
        frame::encode(&Frame::Hello { session: self.session_id, version: PROTOCOL_VERSION },
                      &self.key, DIR_C2S, ctr, &mut out);
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
        let stream = TcpStream::connect(self.cfg.server_tcp)?;
        stream.set_nodelay(true)?;
        stream.set_read_timeout(Some(HANDSHAKE_TIMEOUT.max(Duration::from_secs(3))))?;
        let mut random = [0u8; 32];
        rand_bytes(&mut random);
        // ClientHello(모양) 보내고 ServerHello(모양) 한 레코드 받기.
        let mut tx = TcpTx::new(stream.try_clone()?);
        tx.send_raw(&transport::client_hello(&self.cfg.sni, &random))?;
        let mut rx = TcpRx::new(stream.try_clone()?);
        let mut buf = [0u8; MAX_MSG];
        rx.recv_msg(&mut buf)?; // ServerHello 버림

        // HELLO 보내고 HELLO_ACK 기다리기.
        tx.send_msg(&self.hello_bytes())?;
        let deadline = Instant::now() + HANDSHAKE_TIMEOUT.max(Duration::from_secs(3));
        loop {
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
        tx_ctr: AtomicU64::new(0),
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
                inner.rebind.store(false, Ordering::Relaxed);
            }
            Err(_) => {
                thread::sleep(Duration::from_secs(1));
                continue;
            }
        }
        let mut last_ping = Instant::now();
        while !inner.stop.load(Ordering::Relaxed) && !inner.rebind.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(200));
            if last_ping.elapsed() >= KEEPALIVE {
                last_ping = Instant::now();
                inner.send_frame(&Frame::Ping { token: rand_u64() });
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
