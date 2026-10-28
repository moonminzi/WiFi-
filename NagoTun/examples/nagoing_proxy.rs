//! nagoing 실제 중계기 — 서버(AWS, wg0 앞단) 또는 클라이언트(리눅스에서 수동 시험)로 띄운다.
//!
//! 서버: UDP(QUIC 모양)·TCP(TLS 흉내)를 둘 다 듣고, 풀어서 wg0로 넘긴다.
//!   cargo run --release --example nagoing_proxy -- server <psk> <udp_bind> <tcp_bind> <wg0>
//!   예) ... server mysecret 0.0.0.0:443 0.0.0.0:443 127.0.0.1:51820
//!   (UDP 443과 TCP 443은 프로토콜이 달라 같이 바인드된다.)
//!
//! 클라이언트: NepTUN의 endpoint를 local_bind로 돌려 주면 그 패킷을 받아 서버로 난독화 전송한다.
//!   cargo run --release --example nagoing_proxy -- client <psk> <server_ip> <udp_port> <tcp_port> <local_bind> [auto|udp|tcp]
//!   예) ... client mysecret 1.2.3.4 443 443 127.0.0.1:51820 auto
//!
//! Ctrl-C로 멈출 때까지 5초마다 상태를 찍는다.

use std::net::SocketAddr;
use std::thread;
use std::time::Duration;

use nago_tun::nagoing::{
    run_client, run_server, ClientConfig, FecParams, Prefer, ServerConfig,
};

fn parse<T: std::str::FromStr>(s: &str, what: &str) -> T {
    s.parse().unwrap_or_else(|_| {
        eprintln!("잘못된 {what}: {s}");
        std::process::exit(2);
    })
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("server") => {
            if args.len() < 6 {
                eprintln!("usage: nagoing_proxy server <psk> <udp_bind> <tcp_bind> <wg0>");
                std::process::exit(2);
            }
            let cfg = ServerConfig {
                psk: args[2].clone(),
                udp_bind: parse::<SocketAddr>(&args[3], "udp_bind"),
                tcp_bind: parse::<SocketAddr>(&args[4], "tcp_bind"),
                upstream: parse::<SocketAddr>(&args[5], "wg0"),
                fec: FecParams::default(),
            };
            let handle = run_server(cfg).unwrap_or_else(|e| {
                eprintln!("서버 시작 실패: {e}");
                std::process::exit(1);
            });
            println!("nagoing 서버 · udp {} · tcp {} · wg0 {}",
                     handle.udp_addr(), handle.tcp_addr(), args[5]);
            loop {
                thread::sleep(Duration::from_secs(5));
                println!("서버 복구(FEC)={}", handle.recovered());
            }
        }
        Some("client") => {
            if args.len() < 7 {
                eprintln!("usage: nagoing_proxy client <psk> <server_ip> <udp_port> <tcp_port> <local_bind> [auto|udp|tcp]");
                std::process::exit(2);
            }
            let ip: std::net::IpAddr = parse(&args[3], "server_ip");
            let udp_port: u16 = parse(&args[4], "udp_port");
            let tcp_port: u16 = parse(&args[5], "tcp_port");
            let prefer = match args.get(7).map(String::as_str) {
                Some("udp") => Prefer::Udp,
                Some("tcp") => Prefer::Tcp,
                _ => Prefer::Auto,
            };
            let cfg = ClientConfig {
                psk: args[2].clone(),
                server_udp: SocketAddr::new(ip, udp_port),
                server_tcp: SocketAddr::new(ip, tcp_port),
                local_bind: parse::<SocketAddr>(&args[6], "local_bind"),
                fec: FecParams::default(),
                prefer,
                sni: "www.cloudflare.com".into(),
            };
            let handle = run_client(cfg).unwrap_or_else(|e| {
                eprintln!("클라 시작 실패: {e}");
                std::process::exit(1);
            });
            println!("nagoing 클라 · NepTUN endpoint를 {} 로 돌리세요", args[6]);
            loop {
                thread::sleep(Duration::from_secs(5));
                println!("{}", handle.stats().summary());
            }
        }
        _ => {
            eprintln!("usage: nagoing_proxy <server|client> ...");
            std::process::exit(2);
        }
    }
}
