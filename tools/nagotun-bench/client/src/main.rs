//! NagoTun 벤치 클라이언트. 리눅스 TUN을 만들어(안드로이드 VpnService처럼 IFF_TUN|IFF_NO_PI, MTU 1420)
//! 엔진에 넘기고, 죽일 때까지 떠 있는다. 상태(rx/tx)는 끝날 때 한 줄로 찍는다.
//!
//!     nagotun-bench-client <tun> <addr> <private_key_b64> <server_pub_b64> <endpoint> [threads] [mtu] [queue]
//! queue: 0 = 이벤트 루프에서 바로 처리(NagoTun 기본), 1 이상 = 작업 스레드 대기열(NepTUN 방식)
use std::ffi::{c_char, CString};
use std::net::Ipv4Addr;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use nago_tun::*;

unsafe fn ifreq_named(name: &str) -> libc::ifreq {
    let mut ifr: libc::ifreq = std::mem::zeroed();
    for (i, c) in name.bytes().enumerate() {
        ifr.ifr_name[i] = c as c_char;
    }
    ifr
}

fn sockaddr_in(ip: Ipv4Addr) -> libc::sockaddr {
    let mut sin: libc::sockaddr_in = unsafe { std::mem::zeroed() };
    sin.sin_family = libc::AF_INET as _;
    sin.sin_addr.s_addr = u32::from_ne_bytes(ip.octets());
    unsafe { std::mem::transmute::<libc::sockaddr_in, libc::sockaddr>(sin) }
}

fn make_tun(name: &str, addr: Ipv4Addr, mtu: i32) -> RawFd {
    unsafe {
        let fd = libc::open(b"/dev/net/tun\0".as_ptr() as _, libc::O_RDWR);
        assert!(fd >= 0, "open tun: {}", std::io::Error::last_os_error());
        let mut ifr = ifreq_named(name);
        ifr.ifr_ifru.ifru_flags = (libc::IFF_TUN | libc::IFF_NO_PI) as _;
        assert!(libc::ioctl(fd, libc::TUNSETIFF as _, &ifr) >= 0, "TUNSETIFF: {}", std::io::Error::last_os_error());
        let s = libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0);
        let mut r = ifreq_named(name);
        r.ifr_ifru.ifru_addr = sockaddr_in(addr);
        assert!(libc::ioctl(s, libc::SIOCSIFADDR as _, &r) >= 0, "SIOCSIFADDR");
        let mut r = ifreq_named(name);
        r.ifr_ifru.ifru_netmask = sockaddr_in(Ipv4Addr::new(255, 255, 255, 0));
        assert!(libc::ioctl(s, libc::SIOCSIFNETMASK as _, &r) >= 0, "SIOCSIFNETMASK");
        let mut r = ifreq_named(name);
        r.ifr_ifru.ifru_mtu = mtu;
        assert!(libc::ioctl(s, libc::SIOCSIFMTU as _, &r) >= 0, "SIOCSIFMTU");
        let mut r = ifreq_named(name);
        assert!(libc::ioctl(s, libc::SIOCGIFFLAGS as _, &mut r) >= 0);
        r.ifr_ifru.ifru_flags |= (libc::IFF_UP | libc::IFF_RUNNING) as libc::c_short;
        assert!(libc::ioctl(s, libc::SIOCSIFFLAGS as _, &r) >= 0, "SIOCSIFFLAGS");
        libc::close(s);
        fd
    }
}

static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 6 {
        eprintln!("usage: {} <tun> <addr> <private_key> <server_pub> <endpoint> [threads] [mtu] [queue]", a[0]);
        std::process::exit(2);
    }
    let threads: u32 = a.get(6).and_then(|v| v.parse().ok()).unwrap_or(4);
    let mtu: i32 = a.get(7).and_then(|v| v.parse().ok()).unwrap_or(1420);
    let queue: u32 = a.get(8).and_then(|v| v.parse().ok()).unwrap_or(0);
    let fd = make_tun(&a[1], a[2].parse().expect("addr"), mtu);
    let uapi = CString::new(format!(
        "set=1\nprivate_key={}\nreplace_peers=true\npublic_key={}\nendpoint={}\npersistent_keepalive_interval=25\nreplace_allowed_ips=true\nallowed_ip=0.0.0.0/0\n\n",
        a[3], a[4], a[5]
    ))
    .unwrap();
    let h = nago_tun_start(fd, uapi.as_ptr(), threads, queue);
    if h.is_null() {
        let mut buf = vec![0u8; 512];
        let n = nago_tun_last_error(buf.as_mut_ptr() as *mut c_char, buf.len());
        eprintln!("start failed: {}", String::from_utf8_lossy(&buf[..n.min(511)]));
        std::process::exit(1);
    }
    unsafe {
        libc::signal(libc::SIGTERM, on_signal as usize);
        libc::signal(libc::SIGINT, on_signal as usize);
    }
    println!("up threads={threads} mtu={mtu} queue={queue}");
    while !STOP.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(200));
    }
    let mut buf = vec![0u8; 4096];
    let n = nago_tun_get(h, buf.as_mut_ptr() as *mut c_char, buf.len());
    let text = String::from_utf8_lossy(&buf[..n.min(4095)]).into_owned();
    let stats: Vec<&str> = text.lines().filter(|l| l.starts_with("rx_bytes") || l.starts_with("tx_bytes")).collect();
    println!("stats {}", stats.join(" "));
    nago_tun_stop(h);
}
