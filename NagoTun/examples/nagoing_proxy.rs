//! nagoing 실제 중계기 — 서버(AWS, wg0 앞단) 또는 클라이언트(리눅스에서 수동 시험)로 띄운다.
//!
//! 서버: UDP(QUIC 모양)·TCP(진짜 TLS 1.3)를 둘 다 듣고, 인증·복호화해 wg0로 넘긴다.
//!   cargo run --release --example nagoing_proxy -- server <psk> <udp_bind> <tcp_bind> <wg0> <wg_key_file> <tls_cert.pem> <tls_key.pem>
//!   예) ... server mysecret 0.0.0.0:51821 0.0.0.0:443 127.0.0.1:51820 /etc/nago/wg.key /etc/nago/tls.crt /etc/nago/tls.key
//!   - wg_key_file: wg0의 WireGuard 개인키(base64, `wg show wg0 private-key` 결과). HELLO 인증에 쓴다.
//!   - 인증서는 자체서명이면 된다(클라는 검증하지 않고 안쪽 HELLO_ACK로 서버를 인증한다).
//!   - 경로 대신 이름만 주면 systemd LoadCredential 폴더($CREDENTIALS_DIRECTORY)에서 찾는다.
//!
//! 클라이언트: NepTUN의 endpoint를 local_bind로 돌려 주면 그 패킷을 받아 서버로 봉인해 보낸다.
//!   cargo run --release --example nagoing_proxy -- client <psk> <server_ip> <udp_port> <tcp_port> <local_bind> <auto|udp|tcp> <server_pub_b64> [client_key_file]
//!   - server_pub_b64: 서버 wg0 공개키. client_key_file을 안 주면 무작위 키(핸드셰이크 시험용).
//!
//! Ctrl-C로 멈출 때까지 5초마다 상태를 찍는다.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

use base64::Engine;
use nago_tun::nagoing::{run_client, run_server, ClientConfig, FecParams, Prefer, ServerConfig};

fn die(msg: String) -> ! {
    eprintln!("{msg}");
    std::process::exit(2);
}

fn parse<T: std::str::FromStr>(s: &str, what: &str) -> T {
    s.parse().unwrap_or_else(|_| die(format!("잘못된 {what}: {s}")))
}

/// 경로가 없으면 systemd 자격증명 폴더에서 찾는다(LoadCredential=이름:경로).
fn resolve(name: &str) -> PathBuf {
    let p = PathBuf::from(name);
    if p.exists() {
        return p;
    }
    match std::env::var_os("CREDENTIALS_DIRECTORY") {
        Some(dir) => PathBuf::from(dir).join(name),
        None => p,
    }
}

fn read(name: &str, what: &str) -> Vec<u8> {
    let p = resolve(name);
    std::fs::read(&p).unwrap_or_else(|e| die(format!("{what} 읽기 실패 {}: {e}", p.display())))
}

fn key32(b64: &str, what: &str) -> [u8; 32] {
    base64::engine::general_purpose::STANDARD
        .decode(b64.trim())
        .ok()
        .and_then(|v| v.try_into().ok())
        .unwrap_or_else(|| die(format!("잘못된 {what}(base64 32바이트 키여야 함)")))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("server") => {
            if args.len() < 9 {
                die("usage: nagoing_proxy server <psk> <udp_bind> <tcp_bind> <wg0> <wg_key_file> <tls_cert.pem> <tls_key.pem>".into());
            }
            let key = String::from_utf8_lossy(&read(&args[6], "wg 개인키")).into_owned();
            let cfg = ServerConfig {
                psk: args[2].clone(),
                udp_bind: parse::<SocketAddr>(&args[3], "udp_bind"),
                tcp_bind: parse::<SocketAddr>(&args[4], "tcp_bind"),
                upstream: parse::<SocketAddr>(&args[5], "wg0"),
                fec: FecParams::default(),
                identity: key32(&key, "wg 개인키"),
                tls_cert_pem: read(&args[7], "tls 인증서"),
                tls_key_pem: read(&args[8], "tls 키"),
            };
            let handle = run_server(cfg).unwrap_or_else(|e| {
                eprintln!("서버 시작 실패: {e}");
                std::process::exit(1);
            });
            println!("nagoing 서버 · udp {} · tls {} · wg0 {}", handle.udp_addr(), handle.tcp_addr(), args[5]);
            loop {
                thread::sleep(Duration::from_secs(5));
                println!("서버 복구(FEC)={}", handle.recovered());
            }
        }
        Some("client") => {
            if args.len() < 9 {
                die("usage: nagoing_proxy client <psk> <server_ip> <udp_port> <tcp_port> <local_bind> <auto|udp|tcp> <server_pub_b64> [client_key_file]".into());
            }
            let ip: std::net::IpAddr = parse(&args[3], "server_ip");
            let udp_port: u16 = parse(&args[4], "udp_port");
            let tcp_port: u16 = parse(&args[5], "tcp_port");
            let prefer = match args[7].as_str() {
                "udp" => Prefer::Udp,
                "tcp" => Prefer::Tcp,
                _ => Prefer::Auto,
            };
            let identity = match args.get(9) {
                Some(f) => key32(&String::from_utf8_lossy(&read(f, "클라 개인키")), "클라 개인키"),
                None => {
                    let mut k = [0u8; 32];
                    nago_tun::nagoing::rand_bytes(&mut k);
                    k
                }
            };
            let cfg = ClientConfig {
                psk: args[2].clone(),
                server_udp: SocketAddr::new(ip, udp_port),
                server_tcp: SocketAddr::new(ip, tcp_port),
                local_bind: parse::<SocketAddr>(&args[6], "local_bind"),
                fec: FecParams::default(),
                prefer,
                sni: "www.cloudflare.com".into(),
                identity,
                server_pub: key32(&args[8], "server_pub"),
            };
            let handle = run_client(cfg).unwrap_or_else(|e| {
                eprintln!("클라 시작 실패: {e}");
                std::process::exit(1);
            });
            println!("nagoing 클라 · NagoTun endpoint를 {} 로 돌리세요", args[6]);
            loop {
                thread::sleep(Duration::from_secs(5));
                println!("{}", handle.stats().summary());
            }
        }
        _ => die("usage: nagoing_proxy <server|client> ...".into()),
    }
}
