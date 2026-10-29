//! NAGO VPN — NagoTun(WireGuard) 엔진(engine/, NepTUN 포크)을 iOS 터널 확장(Swift)과 안드로이드 앱(JNI, src/android.rs)에서 부르기 위한 C 인터페이스.
//!
//! OS가 만든 터널(iOS utun, 안드로이드 VpnService TUN) 파일 디스크립터를 그대로 넘겨받아 엔진 장치를 띄우고,
//! 설정은 WireGuard UAPI 문자열(set=1 …)로 넣는다. 패킷 처리는 엔진의 스레드들이 utun과 UDP를 직접 읽고 쓴다.

use std::ffi::{c_char, c_int, CStr};
use std::net::{IpAddr, SocketAddr};
use std::ptr;
use std::sync::{Arc, Mutex};

use base64::Engine;

use engine::device::tun::TunSocket;
use engine::device::{DeviceConfig, DeviceHandle, MakeExternalNeptunNoop};

#[cfg(target_os = "android")]
mod android;

// WireGuard 아래에 끼우는 난독화·손실보정·빠른전환 전송 층. WG(엔진)는 건드리지 않는다.
pub mod nagoing;

/// Swift 쪽에서는 불투명 포인터로만 다룬다.
pub struct NagoTun {
    handle: DeviceHandle,
}

static LAST_ERROR: Mutex<String> = Mutex::new(String::new());

fn fail<T>(message: String) -> *mut T {
    if let Ok(mut e) = LAST_ERROR.lock() {
        *e = message;
    }
    ptr::null_mut()
}

/// UAPI는 키를 16진수로 받는다(값 안의 '='로 줄을 자르기 때문에 base64를 그대로 넣으면 EPROTO).
/// Swift/WireGuard 설정은 base64라서 여기서 바꿔 준다.
fn normalize(cmd: &str) -> String {
    let mut out = String::with_capacity(cmd.len() + 64);
    for line in cmd.split_inclusive('\n') {
        let body = line.trim_end_matches('\n');
        let converted = body.split_once('=').and_then(|(key, value)| {
            if !matches!(key, "private_key" | "public_key" | "preshared_key") || value.len() != 44 {
                return None;
            }
            let bytes = base64::engine::general_purpose::STANDARD.decode(value).ok()?;
            (bytes.len() == 32).then(|| format!("{key}={}", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()))
        });
        out.push_str(converted.as_deref().unwrap_or(body));
        if line.ends_with('\n') {
            out.push('\n');
        }
    }
    out
}

fn text(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok().map(str::to_owned)
}

fn errno_of(response: &str) -> c_int {
    response
        .lines()
        .find_map(|l| l.strip_prefix("errno="))
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(-1)
}

/// UDP 소켓 버퍼(받기·보내기). wireguard-go와 같은 7MB. 받는 쪽이 잠깐 밀릴 때 커널이 패킷을 버리지 않게 한다.
/// 리눅스·안드로이드는 시스템 상한(rmem_max)에서 조용히 잘리고, 실패해도 NepTUN은 경고만 남긴다.
/// 애플에서는 NepTUN이 이 값을 쓰지 않아서 iOS 터널 확장(NeptunEngine.swift)이 소켓을 찾아 직접 키운다.
const SOCKET_BUFFER: usize = 7 << 20;

/// 터널을 시작한다. 실패하면 NULL.
/// - `tun_fd`: iOS utun 또는 안드로이드 TUN 디스크립터(네트워크 설정을 적용한 뒤에 넘겨야 MTU가 맞다). 엔진이 닫는다
/// - `uapi`: "set=1\nprivate_key=…\npublic_key=…\nendpoint=…\nallowed_ip=…\n\n"
/// - `threads`: 이벤트 루프 스레드 수(아이폰 기본 2, 안드로이드 4).
///   애플은 패킷을 이벤트 루프에서 바로 처리한다(읽기→암호화→보내기 / 받기→복호화→쓰기). utun 읽기와 UDP 받기는
///   kqueue EV_DISPATCH라 한 번에 한 스레드만 잡으므로, 2개면 올리기(받는 중의 ACK 포함)와 내려받기가 다른 코어에서 돈다.
///   피어 잠금은 암·복호화하는 동안만 잡고 send/write는 잠금 밖이라 둘이 겹친다
/// - `queue`: 애플 밖(안드로이드·리눅스)에서만 쓰는 스레드 사이 대기열 묶음 수(0이면 8).
///   애플에선 NepTUN이 이 대기열(packet_workers)을 아예 만들지 않아서 값이 아무 영향이 없다
#[no_mangle]
pub extern "C" fn nago_tun_start(tun_fd: c_int, uapi: *const c_char, threads: u32, queue: u32) -> *mut NagoTun {
    let Some(cmd) = text(uapi).map(|c| normalize(&c)) else {
        return fail("uapi is not utf-8".into());
    };
    let tun = match TunSocket::new_from_fd(tun_fd) {
        Ok(t) => t,
        Err(e) => return fail(format!("tun fd {tun_fd}: {e:?}")),
    };
    let config = DeviceConfig {
        n_threads: threads.clamp(1, 4) as usize,
        // NordVPN(libtelio)과 같게: 애플은 끄고, 안드로이드는 서버마다 connect한 소켓을 쓴다
        use_connected_socket: cfg!(target_os = "android"),
        #[cfg(target_os = "linux")]
        use_multi_queue: false,
        open_uapi_socket: false,
        protect: Arc::new(MakeExternalNeptunNoop),
        firewall_process_inbound_callback: None,
        firewall_process_outbound_callback: None,
        skt_buffer_size: Some(SOCKET_BUFFER),
        // 스레드 사이 대기열(애플 밖에서만 쓰임, 묶음당 최대 50패킷). 가득 차면 이벤트 루프가 기다린다(블로킹 send).
        // 크면 다운로드가 몰릴 때 패킷이 쌓여 그만큼 핑이 오른다(NepTUN 기본 500묶음이면 수백 ms).
        // 8묶음(약 600KB)이면 300Mbps에서 쌓이는 지연이 20ms 안팎이고, 순간 버스트는 위의 소켓 버퍼가 받는다.
        inter_thread_channel_size: Some(if queue == 0 { 8 } else { queue.clamp(1, 64) as usize }),
        max_inter_thread_batched_pkts: None,
        // 애플 밖: queue가 0이면 패킷을 이벤트 루프에서 바로 처리한다(작업 스레드 없음, NagoTun 기본).
        // 1 이상이면 NepTUN처럼 그 크기의 대기열로 작업 스레드에 넘긴다(비교용)
        inline_packets: queue == 0,
    };
    let handle = match DeviceHandle::new_with_tun(tun, config) {
        Ok(h) => h,
        Err(e) => return fail(format!("device: {e:?}")),
    };
    let errno = errno_of(&handle.send_uapi_cmd(&cmd));
    if errno != 0 {
        handle.trigger_exit();
        return fail(format!("uapi set: errno {errno}"));
    }
    Box::into_raw(Box::new(NagoTun { handle }))
}

/// 설정을 바꾼다(예: 서버 주소). 0이면 성공, 아니면 UAPI errno.
#[no_mangle]
pub extern "C" fn nago_tun_set(tun: *mut NagoTun, uapi: *const c_char) -> c_int {
    let (Some(tun), Some(cmd)) = (unsafe { tun.as_ref() }, text(uapi)) else {
        return -1;
    };
    errno_of(&tun.handle.send_uapi_cmd(&normalize(&cmd)))
}

/// 마지막 실패 이유를 buf에 쓴다(항상 NUL로 끝남). 돌려주는 값은 전체 길이.
#[no_mangle]
pub extern "C" fn nago_tun_last_error(buf: *mut c_char, len: usize) -> usize {
    let message = LAST_ERROR.lock().map(|e| e.clone()).unwrap_or_default();
    if !buf.is_null() && len > 0 {
        let n = message.len().min(len - 1);
        unsafe {
            ptr::copy_nonoverlapping(message.as_ptr(), buf as *mut u8, n);
            *buf.add(n) = 0;
        }
    }
    message.len()
}

/// 상태(UAPI get=1 응답: rx_bytes, tx_bytes, last_handshake_time_sec …)를 buf에 쓴다.
/// 돌려주는 값은 전체 길이(buf가 작으면 잘림, 항상 NUL로 끝남).
#[no_mangle]
pub extern "C" fn nago_tun_get(tun: *mut NagoTun, buf: *mut c_char, len: usize) -> usize {
    let Some(tun) = (unsafe { tun.as_ref() }) else {
        return 0;
    };
    let out = tun.handle.send_uapi_cmd("get=1\n\n");
    if !buf.is_null() && len > 0 {
        let n = out.len().min(len - 1);
        unsafe {
            ptr::copy_nonoverlapping(out.as_ptr(), buf as *mut u8, n);
            *buf.add(n) = 0;
        }
    }
    out.len()
}

/// 와이파이↔셀룰러 전환 등 네트워크가 바뀌었을 때 부른다(UDP 소켓을 새로 만듦).
#[no_mangle]
pub extern "C" fn nago_tun_network_changed(tun: *mut NagoTun) {
    if let Some(tun) = unsafe { tun.as_ref() } {
        tun.handle.drop_connected_sockets();
    }
}

/// 터널을 멈추고 해제한다. 이후 포인터는 쓰면 안 된다.
#[no_mangle]
pub extern "C" fn nago_tun_stop(tun: *mut NagoTun) {
    if tun.is_null() {
        return;
    }
    let tun = unsafe { Box::from_raw(tun) };
    tun.handle.trigger_exit();
    drop(tun);
}

// ── nagoing 클라이언트 FFI (iOS 터널 확장 / 안드로이드에서 부른다) ────────────────
//
// WireGuard는 그대로 두고, NepTUN이 로컬 UDP로 보내는 WG 패킷을 nagoing 프록시가 받아 난독화·FEC해
// 443으로 서버에 보낸다. 쓰는 쪽은 NepTUN의 endpoint를 nagoing 로컬 포트(127.0.0.1:local_port)로
// 돌려 주면 된다. 서버에는 nagoing 서버 프록시(examples/nagoing_proxy.rs)가 떠 있어야 한다.

/// 불투명 포인터로만 다룬다.
pub struct NagoingClient {
    handle: nagoing::ClientHandle,
}

fn parse_addr(ip: &str, port: u16) -> Option<SocketAddr> {
    ip.parse::<IpAddr>().ok().map(|ip| SocketAddr::new(ip, port))
}

/// nagoing 클라이언트를 띄운다. 실패하면 NULL(사유는 nago_tun_last_error).
/// - `psk`: 서버와 공유하는 난독화 PSK(인증 아님 — 진짜 보안은 안쪽 WG)
/// - `server_ip` + `udp_port`/`tcp_port`: 서버 프록시 주소(TCP 443 = HTTPS, UDP는 전용 포트 51821)
/// - `local_ip`/`local_port`: NepTUN이 WG 패킷을 보낼 로컬 주소(보통 127.0.0.1)
/// - `fec_k`/`fec_groups`/`fec_on`: 손실 보정. fec_on=0이면 끔
/// - `prefer`: 0 auto(UDP→TCP), 1 udp, 2 tcp
/// - `sni`: TCP 폴백 ClientHello에 넣을 이름(NULL이면 기본값)
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn nago_nagoing_client_start(
    psk: *const c_char,
    server_ip: *const c_char,
    udp_port: u16,
    tcp_port: u16,
    local_ip: *const c_char,
    local_port: u16,
    fec_k: u8,
    fec_groups: u16,
    fec_on: c_int,
    prefer: c_int,
    sni: *const c_char,
) -> *mut NagoingClient {
    let (Some(psk), Some(server_ip), Some(local_ip)) = (text(psk), text(server_ip), text(local_ip)) else {
        return fail("nagoing: psk/server_ip/local_ip not utf-8".into());
    };
    let (Some(server_udp), Some(server_tcp), Some(local_bind)) = (
        parse_addr(&server_ip, udp_port),
        parse_addr(&server_ip, tcp_port),
        parse_addr(&local_ip, local_port),
    ) else {
        return fail(format!("nagoing: bad address {server_ip} / {local_ip}"));
    };
    let prefer = match prefer {
        1 => nagoing::Prefer::Udp,
        2 => nagoing::Prefer::Tcp,
        _ => nagoing::Prefer::Auto,
    };
    let cfg = nagoing::ClientConfig {
        psk,
        server_udp,
        server_tcp,
        local_bind,
        fec: nagoing::FecParams { k: fec_k, groups: fec_groups, enabled: fec_on != 0 },
        prefer,
        sni: text(sni).unwrap_or_else(|| "www.cloudflare.com".into()),
    };
    match nagoing::run_client(cfg) {
        Ok(handle) => Box::into_raw(Box::new(NagoingClient { handle })),
        Err(e) => fail(format!("nagoing start: {e}")),
    }
}

/// 와이파이↔셀룰러 전환 등 경로가 바뀌면 부른다(전송을 빠르게 다시 수립).
#[no_mangle]
pub extern "C" fn nago_nagoing_network_changed(client: *mut NagoingClient) {
    if let Some(c) = unsafe { client.as_ref() } {
        c.handle.network_changed();
    }
}

/// 상태 한 줄("udp · tx 123 · rx 120 · fec+4")을 buf에 쓴다(항상 NUL로 끝남). 돌려주는 값은 전체 길이.
#[no_mangle]
pub extern "C" fn nago_nagoing_stats(client: *mut NagoingClient, buf: *mut c_char, len: usize) -> usize {
    let summary = match unsafe { client.as_ref() } {
        Some(c) => c.handle.stats().summary(),
        None => String::new(),
    };
    if !buf.is_null() && len > 0 {
        let n = summary.len().min(len - 1);
        unsafe {
            ptr::copy_nonoverlapping(summary.as_ptr(), buf as *mut u8, n);
            *buf.add(n) = 0;
        }
    }
    summary.len()
}

/// 멈추고 해제한다. 이후 포인터는 쓰면 안 된다.
#[no_mangle]
pub extern "C" fn nago_nagoing_client_stop(client: *mut NagoingClient) {
    if client.is_null() {
        return;
    }
    let NagoingClient { handle } = *unsafe { Box::from_raw(client) };
    handle.stop();
}

#[cfg(test)]
mod tests {
    use super::normalize;

    #[test]
    fn base64_keys_become_hex() {
        let key = "cEpo505uD47/u8fC24tEIqixpjgGhWWv3HEhhEUlrlw=";
        let out = normalize(&format!("set=1\nprivate_key={key}\nendpoint=1.2.3.4:443\nallowed_ip=0.0.0.0/0\n\n"));
        let line = out.lines().nth(1).unwrap();
        assert_eq!(line.len(), "private_key=".len() + 64);
        assert!(line.starts_with("private_key=704a68e7"));
        assert!(out.ends_with("allowed_ip=0.0.0.0/0\n\n"));
        assert!(out.contains("endpoint=1.2.3.4:443\n"));
    }
}
