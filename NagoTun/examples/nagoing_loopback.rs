//! nagoing 리눅스 PoC — 서버·클라이언트를 한 프로세스에 띄우고 중간에 손실을 주입해
//! ① 난독화 전송 ② FEC 손실 보정 ③ 자동 폴백이 실제로 동작하는지 눈으로 확인한다.
//!
//! 실행: cargo run --example nagoing_loopback
//!
//! 세 장면:
//!   A. 손실 없는 왕복(UDP 전송 수립 확인)
//!   B. 버스트 손실 주입 — FEC 끔 vs 켬 왕복 성공률 비교
//!   C. UDP를 막아 둔 망 흉내 — 자동으로 TCP(TLS 흉내)로 폴백

use std::collections::HashSet;
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use nago_tun::nagoing::{
    run_client, run_server, ClientConfig, FecParams, Kind, Prefer, ServerConfig,
};

fn lo(port: u16) -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], port))
}

/// 전송이 수립될 때까지(최대 timeout) 기다린다.
fn wait_established(client: &nago_tun::nagoing::ClientHandle, timeout: Duration) {
    let start = Instant::now();
    while client.stats().kind.is_none() && start.elapsed() < timeout {
        thread::sleep(Duration::from_millis(100));
    }
}

/// 받은 걸 그대로 돌려보내는 가짜 wg0.
fn spawn_echo() -> (SocketAddr, Arc<AtomicBool>) {
    let sock = UdpSocket::bind(lo(0)).unwrap();
    let addr = sock.local_addr().unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    thread::spawn(move || {
        sock.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
        let mut buf = [0u8; 2048];
        while !s.load(Ordering::Relaxed) {
            if let Ok((n, from)) = sock.recv_from(&mut buf) {
                let _ = sock.send_to(&buf[..n], from);
            }
        }
    });
    (addr, stop)
}

/// 클라↔서버 사이를 중계하면서, 클라→서버 방향 데이터그램을 버스트로 떨군다(지하철/엘리베이터 흉내).
/// 처음 warmup개는 통과시켜(핸드셰이크 보호) 그 뒤부터 period개마다 burst개 연속으로 버린다. 떨군 개수를 센다.
fn spawn_lossy_relay(server_udp: SocketAddr, warmup: u64, period: u64, burst: u64) -> (SocketAddr, Arc<AtomicBool>, Arc<AtomicU64>) {
    let front = UdpSocket::bind(lo(0)).unwrap(); // 클라가 보는 "서버"
    let addr = front.local_addr().unwrap();
    let back = UdpSocket::bind(lo(0)).unwrap(); // 진짜 서버로 보내는 소켓
    back.connect(server_udp).unwrap();
    front.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    back.set_read_timeout(Some(Duration::from_millis(100))).unwrap();

    let stop = Arc::new(AtomicBool::new(false));
    let dropped = Arc::new(AtomicU64::new(0));
    let client_addr: Arc<std::sync::Mutex<Option<SocketAddr>>> = Arc::new(std::sync::Mutex::new(None));

    // 클라 → (손실) → 서버
    {
        let (front, back) = (front.try_clone().unwrap(), back.try_clone().unwrap());
        let (stop, dropped, client_addr) = (stop.clone(), dropped.clone(), client_addr.clone());
        thread::spawn(move || {
            let mut buf = [0u8; 2048];
            let mut seen: u64 = 0;
            while !stop.load(Ordering::Relaxed) {
                if let Ok((n, from)) = front.recv_from(&mut buf) {
                    *client_addr.lock().unwrap() = Some(from);
                    let in_burst = seen >= warmup && (seen - warmup) % period < burst;
                    seen += 1;
                    if in_burst {
                        dropped.fetch_add(1, Ordering::Relaxed);
                        continue; // 떨어뜨림
                    }
                    let _ = back.send(&buf[..n]);
                }
            }
        });
    }
    // 서버 → 클라 (손실 없음)
    {
        let (front, back) = (front, back);
        let (stop, client_addr) = (stop.clone(), client_addr.clone());
        thread::spawn(move || {
            let mut buf = [0u8; 2048];
            while !stop.load(Ordering::Relaxed) {
                if let Ok(n) = back.recv(&mut buf) {
                    if let Some(to) = *client_addr.lock().unwrap() {
                        let _ = front.send_to(&buf[..n], to);
                    }
                }
            }
        });
    }
    (addr, stop, dropped)
}

/// 가짜 NepTUN: 클라 로컬로 N개 보내고, 돌아온 인덱스를 모아 성공 수를 돌려준다.
fn roundtrip_count(client_local: SocketAddr, n: u16) -> usize {
    let neptun = UdpSocket::bind(lo(0)).unwrap();
    neptun.connect(client_local).unwrap();

    // 보내는 스레드
    let sender = neptun.try_clone().unwrap();
    thread::spawn(move || {
        for i in 0..n {
            let mut payload = vec![0u8; 60];
            payload[0..2].copy_from_slice(&i.to_le_bytes());
            let _ = sender.send(&payload);
            thread::sleep(Duration::from_millis(2));
        }
    });

    // 돌아오는 것 모으기
    neptun.set_read_timeout(Some(Duration::from_millis(300))).unwrap();
    let mut got = HashSet::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut buf = [0u8; 2048];
    while Instant::now() < deadline && got.len() < n as usize {
        match neptun.recv(&mut buf) {
            Ok(m) if m >= 2 => {
                got.insert(u16::from_le_bytes([buf[0], buf[1]]));
            }
            _ => {}
        }
    }
    got.len()
}

fn main() {
    let psk = "nagoing-demo-psk";
    let n: u16 = 100;

    println!("== nagoing 리눅스 PoC ==\n");

    // ── A. 손실 없는 왕복 ──────────────────────────────────────────────
    {
        let (wg, wg_stop) = spawn_echo();
        let server = run_server(ServerConfig {
            psk: psk.into(), udp_bind: lo(0), tcp_bind: lo(0), upstream: wg,
            fec: FecParams::default(),
        }).unwrap();
        let client = run_client(ClientConfig {
            psk: psk.into(),
            server_udp: server.udp_addr(), server_tcp: server.tcp_addr(),
            local_bind: lo(0), fec: FecParams::default(), prefer: Prefer::Udp,
            sni: "www.cloudflare.com".into(),
        }).unwrap();
        thread::sleep(Duration::from_millis(500));
        let local = client.local_addr().unwrap();
        let got = roundtrip_count(local, n);
        println!("A. 손실 없음 (UDP/QUIC 모양): {got}/{n} 왕복  ·  전송={}", client.stats().summary());
        client.stop();
        server.stop();
        wg_stop.store(true, Ordering::Relaxed);
    }

    // ── B. 버스트 손실 — FEC 끔 vs 켬 ──────────────────────────────────
    for fec_on in [false, true] {
        let (wg, wg_stop) = spawn_echo();
        // k=4, groups=4 → 4연속 손실까지 복구, 패리티 비용 25%.
        let fec = FecParams { k: 4, groups: 4, enabled: fec_on };
        let server = run_server(ServerConfig {
            psk: psk.into(), udp_bind: lo(0), tcp_bind: lo(0), upstream: wg, fec,
        }).unwrap();
        // 핸드셰이크(앞 8개)는 통과, 이후 20개마다 3개 연속 손실(약 15%, 버스트).
        let (relay, relay_stop, dropped) = spawn_lossy_relay(server.udp_addr(), 8, 20, 3);
        let client = run_client(ClientConfig {
            psk: psk.into(),
            server_udp: relay, server_tcp: server.tcp_addr(),
            local_bind: lo(0), fec, prefer: Prefer::Udp,
            sni: "www.cloudflare.com".into(),
        }).unwrap();
        wait_established(&client, Duration::from_secs(5));
        let local = client.local_addr().unwrap();
        let got = roundtrip_count(local, n);
        let label = if fec_on { "FEC 켬 " } else { "FEC 끔 " };
        println!("B. 버스트 손실 {label}: {got}/{n} 왕복  ·  떨군 조각={}  ·  서버 복구={}  ·  {}",
                 dropped.load(Ordering::Relaxed), server.recovered(), client.stats().summary());
        client.stop();
        server.stop();
        relay_stop.store(true, Ordering::Relaxed);
        wg_stop.store(true, Ordering::Relaxed);
    }

    // ── C. UDP 막힌 망 — TCP 자동 폴백 ─────────────────────────────────
    {
        let (wg, wg_stop) = spawn_echo();
        let server = run_server(ServerConfig {
            psk: psk.into(), udp_bind: lo(0), tcp_bind: lo(0), upstream: wg,
            fec: FecParams::default(),
        }).unwrap();
        // 클라에게 알려 주는 UDP 주소는 아무도 안 듣는 죽은 포트 → UDP 핸드셰이크 실패 → TCP로.
        let dead_udp = lo(1); // 포트 1: 바인드 안 됨
        let client = run_client(ClientConfig {
            psk: psk.into(),
            server_udp: dead_udp, server_tcp: server.tcp_addr(),
            local_bind: lo(0), fec: FecParams::default(), prefer: Prefer::Auto,
            sni: "www.cloudflare.com".into(),
        }).unwrap();

        // 폴백까지 최대 몇 초 기다린다.
        let start = Instant::now();
        while client.stats().kind.is_none() && start.elapsed() < Duration::from_secs(8) {
            thread::sleep(Duration::from_millis(200));
        }
        let kind = match client.stats().kind {
            Some(Kind::Udp) => "udp",
            Some(Kind::Tcp) => "tcp(TLS 흉내)",
            None => "실패",
        };
        let local = client.local_addr().unwrap();
        let got = roundtrip_count(local, n);
        println!("C. UDP 막힘 → 폴백 전송={kind}: {got}/{n} 왕복  ·  {}", client.stats().summary());
        client.stop();
        server.stop();
        wg_stop.store(true, Ordering::Relaxed);
    }

    println!("\n완료.");
}
