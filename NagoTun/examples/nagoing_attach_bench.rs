//! 엔진 ↔ nagoing 직결(nago_nagoing_attach) 전후의 클라 쪽 CPU를 잰다(리눅스).
//!
//! 두 프로세스로 띄운다 — 폰(클라) 쪽 비용만 따로 재려고:
//!   서버:  cargo run --release --example nagoing_attach_bench -- server
//!          (nagoing 서버 + WG 서버 엔진 + 가짜 tun에서 받은 IP 패킷을 출발지·목적지를 바꿔 되돌려 주는 메아리)
//!   클라:  cargo run --release --example nagoing_attach_bench -- client <hop|attached> [초] [창]
//!          hop      = 예전 방식: 엔진 → 127.0.0.1(nagoing 로컬 포트) → nagoing (패킷마다 sendto/recvfrom + 스레드 넘김)
//!          attached = 직결: 엔진이 암호화한 걸 nagoing이 바로 봉인·전송, 받은 건 바로 복호화→tun
//!          plain    = 비교 기준: nagoing 없이 WG만(엔진 → 서버 WG 직접). nagoing이 더하는 비용의 바닥
//!
//! 클라는 가짜 tun에 MTU 크기 IPv4 패킷을 창(기본 64)만큼 띄워 두고 돌아오는 대로 다시 보낸다(왕복 = 올리기+내리기).
//! 끝나면 처리량과 **클라 프로세스의 1GB당 CPU초**(getrusage, 사용자+시스템)를 찍는다.

use std::net::SocketAddr;
use std::os::fd::IntoRawFd;
use std::os::unix::net::UnixDatagram;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use engine::device::tun::TunSocket;
use engine::device::{DeviceConfig, DeviceHandle, MakeExternalNeptunNoop};
use nago_tun::nagoing::{self, FecParams, Identity, Prefer};

const SKEY: [u8; 32] = [2; 32];
const CKEY: [u8; 32] = [1; 32];
const WG_PORT: u16 = 47830;
const RELAY_UDP: u16 = 47831;
const RELAY_TCP: u16 = 47832;
const LOCAL: u16 = 47833;
const MTU: usize = 1380;

/// NAGO_BENCH_FEC=0이면 FEC 끔(양쪽 같게 줄 것).
fn bench_fec() -> FecParams {
    FecParams { enabled: std::env::var("NAGO_BENCH_FEC").map(|v| v != "0").unwrap_or(true), ..FecParams::default() }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn lo(p: u16) -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], p))
}

fn config() -> DeviceConfig {
    // 앱(iOS·안드로이드)과 같은 방식: 이벤트 루프 1개, 패킷을 루프에서 바로 처리.
    DeviceConfig {
        n_threads: 1,
        use_connected_socket: false,
        use_multi_queue: false,
        open_uapi_socket: false,
        protect: Arc::new(MakeExternalNeptunNoop),
        firewall_process_inbound_callback: None,
        firewall_process_outbound_callback: None,
        skt_buffer_size: Some(7 << 20),
        inter_thread_channel_size: Some(8),
        max_inter_thread_batched_pkts: None,
        inline_packets: true,
        external_net: Default::default(),
    }
}

fn mock_tun() -> (TunSocket, UnixDatagram) {
    let (near, far) = UnixDatagram::pair().unwrap();
    near.set_nonblocking(true).unwrap();
    (TunSocket::new_mock_from_fd(near.into_raw_fd()), far)
}

fn ipv4(src: [u8; 4], dst: [u8; 4], len: usize) -> Vec<u8> {
    let mut p = vec![0x5au8; len];
    p[..12].copy_from_slice(&[0x45, 0, 0, 0, 0, 0, 0x40, 0, 64, 17, 0, 0]);
    p[12..16].copy_from_slice(&src);
    p[16..20].copy_from_slice(&dst);
    p[2..4].copy_from_slice(&(len as u16).to_be_bytes());
    p
}

fn cpu_secs() -> f64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    let t = |tv: libc::timeval| tv.tv_sec as f64 + tv.tv_usec as f64 / 1e6;
    t(ru.ru_utime) + t(ru.ru_stime)
}

fn server() {
    let cpub = Identity::from_bytes(CKEY).public();
    let (tun, far) = mock_tun();
    let wg = DeviceHandle::new_with_mock_tun(tun, MTU + 40, config()).unwrap();
    wg.send_uapi_cmd(&format!(
        "set=1\nprivate_key={}\nlisten_port={WG_PORT}\npublic_key={}\nallowed_ip=10.9.0.2/32\n\n",
        hex(&SKEY),
        hex(&cpub)
    ));
    let _relay = nagoing::run_server(nagoing::ServerConfig {
        psk: "bench".into(),
        udp_bind: lo(RELAY_UDP),
        tcp_bind: lo(RELAY_TCP),
        upstream: lo(WG_PORT),
        fec: bench_fec(),
        identity: SKEY,
        tls_cert_pem: nagoing::testcert::CERT_PEM.into(),
        tls_key_pem: nagoing::testcert::KEY_PEM.into(),
    })
    .unwrap();
    println!("server ready (wg udp {WG_PORT}, nagoing udp {RELAY_UDP})");
    // 메아리: 받은 IP 패킷의 출발지·목적지를 바꿔 되돌린다.
    let mut buf = [0u8; 2048];
    loop {
        if let Ok(n) = far.recv(&mut buf) {
            let p = &mut buf[..n];
            if n >= 20 {
                let (a, b) = p[12..20].split_at_mut(4);
                a.swap_with_slice(b);
            }
            let _ = far.send(p);
        }
    }
}

fn client(mode: &str, secs: u64, window: usize) {
    let attached = mode == "attached";
    let spub = Identity::from_bytes(SKEY).public();
    let ncl = nagoing::run_client(nagoing::ClientConfig {
        psk: "bench".into(),
        server_udp: lo(RELAY_UDP),
        server_tcp: lo(RELAY_TCP),
        local_bind: lo(LOCAL),
        fec: bench_fec(),
        prefer: Prefer::Udp,
        sni: "x".into(),
        identity: CKEY,
        server_pub: spub,
        protect: None,
    })
    .unwrap();
    let (tun, far) = mock_tun();
    let wg = DeviceHandle::new_with_mock_tun(tun, MTU, config()).unwrap();
    // hop: 엔진이 nagoing 로컬 포트로 UDP를 보낸다(예전). attached: 엔드포인트는 죽은 포트, 직결로만 오간다.
    let endpoint = match mode {
        "attached" => "127.0.0.1:9".to_string(),
        "plain" => format!("127.0.0.1:{WG_PORT}"),
        _ => format!("127.0.0.1:{LOCAL}"),
    };
    wg.send_uapi_cmd(&format!(
        "set=1\nprivate_key={}\npublic_key={}\nendpoint={endpoint}\npersistent_keepalive_interval=25\nallowed_ip=10.9.0.1/32\n\n",
        hex(&CKEY),
        hex(&spub)
    ));
    let start = Instant::now();
    while ncl.stats().kind.is_none() && start.elapsed() < Duration::from_secs(5) {
        thread::sleep(Duration::from_millis(50));
    }
    if attached {
        wg.set_external_net(Some(Arc::new(Link(ncl.sender()))));
        let rx = wg.external_receiver();
        let d = rx.clone();
        ncl.attach(Arc::new(move |p: &[u8]| { rx.receive(p); }), Box::new(move || d.detach()));
    }

    let pkt = ipv4([10, 9, 0, 2], [10, 9, 0, 1], MTU);
    far.set_read_timeout(Some(Duration::from_millis(300))).unwrap();
    let mut buf = [0u8; 2048];
    // 예열(핸드셰이크)
    let warm = Instant::now();
    loop {
        far.send(&pkt).unwrap();
        if far.recv(&mut buf).is_ok() || warm.elapsed() > Duration::from_secs(10) {
            break;
        }
    }
    let stop = Arc::new(AtomicBool::new(false));
    for _ in 0..window {
        far.send(&pkt).unwrap();
    }
    let (t0, c0) = (Instant::now(), cpu_secs());
    let mut round = 0u64;
    while t0.elapsed() < Duration::from_secs(secs) {
        match far.recv(&mut buf) {
            Ok(_) => {
                round += 1;
                let _ = far.send(&pkt);
            }
            Err(_) => {
                for _ in 0..window {
                    let _ = far.send(&pkt);
                }
            }
        }
    }
    let (dt, dc) = (t0.elapsed().as_secs_f64(), cpu_secs() - c0);
    stop.store(true, Ordering::Relaxed);
    // 왕복 하나 = 올리기 MTU + 내리기 MTU
    let gb = round as f64 * 2.0 * MTU as f64 / 1e9;
    println!(
        "{mode:9}: {:6.0} Mbps (각 방향)  ·  클라 CPU {:5.2}s / {:4.1}s  ·  1GB당 CPU {:5.2}초",
        round as f64 * MTU as f64 * 8.0 / dt / 1e6,
        dc,
        dt,
        dc / gb
    );
    ncl.stop();
    wg.trigger_exit();
}

struct Link(nagoing::DatagramSender);

impl engine::device::ExternalNet for Link {
    fn send(&self, packet: &[u8]) {
        self.0.send(packet);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("server") => server(),
        Some("client") => client(
            args.get(2).map(String::as_str).unwrap_or("attached"),
            args.get(3).and_then(|s| s.parse().ok()).unwrap_or(8),
            args.get(4).and_then(|s| s.parse().ok()).unwrap_or(64),
        ),
        _ => eprintln!("usage: nagoing_attach_bench <server | client <hop|attached|plain> [secs] [window]>"),
    }
}
