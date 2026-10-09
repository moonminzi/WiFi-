//! 리눅스에서 nago_tun 시험용: TUN을 만들어 그 fd로 nago_tun_start를 부른다(iOS에서 utun fd를 넘기는 것과 같은 경로).
//! 사용: linux_tun <tun 이름> <UAPI 파일> <스레드 수>   — Ctrl-C/kill 할 때까지 돈다.
use std::ffi::CString;
use std::{env, fs, thread, time::Duration};

#[repr(C)]
struct IfReq {
    name: [u8; 16],
    flags: libc::c_short,
    _pad: [u8; 22],
}

const TUNSETIFF: libc::c_ulong = 0x4004_54ca;

fn main() {
    let args: Vec<String> = env::args().collect();
    let (name, uapi_path, threads) = (&args[1], &args[2], args[3].parse::<u32>().unwrap());
    let fd = unsafe { libc::open(b"/dev/net/tun\0".as_ptr() as *const _, libc::O_RDWR) };
    assert!(fd >= 0, "open /dev/net/tun failed");
    let mut req = IfReq { name: [0; 16], flags: (libc::IFF_TUN | libc::IFF_NO_PI) as libc::c_short, _pad: [0; 22] };
    req.name[..name.len()].copy_from_slice(name.as_bytes());
    assert!(unsafe { libc::ioctl(fd, TUNSETIFF as _, &req) } >= 0, "TUNSETIFF failed");

    let uapi = CString::new(fs::read_to_string(uapi_path).unwrap()).unwrap();
    let tun = nago_tun::nago_tun_start(fd, uapi.as_ptr(), threads);
    if tun.is_null() {
        let mut buf = vec![0u8; 512];
        let n = nago_tun::nago_tun_last_error(buf.as_mut_ptr() as *mut _, buf.len());
        eprintln!("nago_tun_start failed: {}", String::from_utf8_lossy(&buf[..n.min(511)]));
        std::process::exit(1);
    }
    println!("started {name} threads={threads}");
    loop {
        thread::sleep(Duration::from_secs(5));
        let mut buf = vec![0u8; 2048];
        let n = nago_tun::nago_tun_get(tun, buf.as_mut_ptr() as *mut _, buf.len());
        let s = String::from_utf8_lossy(&buf[..n.min(buf.len() - 1)]);
        let pick: Vec<&str> = s.lines().filter(|l| l.starts_with("rx_bytes") || l.starts_with("tx_bytes") || l.starts_with("last_handshake_time_sec")).collect();
        println!("{}", pick.join(" "));
    }
}
