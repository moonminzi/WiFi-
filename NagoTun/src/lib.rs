//! NAGO VPN — NepTUN(WireGuard) 엔진을 iOS 터널 확장(Swift)과 안드로이드 앱(JNI, src/android.rs)에서 부르기 위한 C 인터페이스.
//!
//! OS가 만든 터널(iOS utun, 안드로이드 VpnService TUN) 파일 디스크립터를 그대로 넘겨받아 NepTUN 장치를 띄우고,
//! 설정은 WireGuard UAPI 문자열(set=1 …)로 넣는다. 패킷 처리는 NepTUN의 스레드들이 utun과 UDP를 직접 읽고 쓴다.

use std::ffi::{c_char, c_int, CStr};
use std::ptr;
use std::sync::{Arc, Mutex};

use base64::Engine;

use neptun::device::tun::TunSocket;
use neptun::device::{DeviceConfig, DeviceHandle, MakeExternalNeptunNoop};

#[cfg(target_os = "android")]
mod android;

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

/// 터널을 시작한다. 실패하면 NULL.
/// - `tun_fd`: iOS utun 또는 안드로이드 TUN 디스크립터(네트워크 설정을 적용한 뒤에 넘겨야 MTU가 맞다). 엔진이 닫는다
/// - `uapi`: "set=1\nprivate_key=…\npublic_key=…\nendpoint=…\nallowed_ip=…\n\n"
/// - `threads`: 이벤트 루프 스레드 수(NordVPN과 같게 아이폰 1, 안드로이드 4)
#[no_mangle]
pub extern "C" fn nago_tun_start(tun_fd: c_int, uapi: *const c_char, threads: u32) -> *mut NagoTun {
    let Some(cmd) = text(uapi).map(|c| normalize(&c)) else {
        return fail("uapi is not utf-8".into());
    };
    let tun = match TunSocket::new_from_fd(tun_fd) {
        Ok(t) => t,
        Err(e) => return fail(format!("tun fd {tun_fd}: {e:?}")),
    };
    let config = DeviceConfig {
        n_threads: threads.clamp(1, 8) as usize,
        // NordVPN(libtelio)과 같게: 애플은 끄고, 안드로이드는 서버마다 connect한 소켓을 쓴다
        use_connected_socket: cfg!(target_os = "android"),
        #[cfg(target_os = "linux")]
        use_multi_queue: false,
        open_uapi_socket: false,
        protect: Arc::new(MakeExternalNeptunNoop),
        firewall_process_inbound_callback: None,
        firewall_process_outbound_callback: None,
        skt_buffer_size: None,
        // 스레드 사이 대기열(묶음당 최대 50패킷). 크면 다운로드가 몰릴 때 패킷이 쌓여 그만큼 핑이 오른다
        // (기본 500묶음이면 수백 ms, 채널 하나가 40MB까지 커져 iOS 확장 메모리 한도 50MB에도 걸림).
        // 8묶음(약 600KB)이면 300Mbps에서 쌓이는 지연이 20ms 안팎이고, 넘치면 TCP가 속도를 맞춘다.
        inter_thread_channel_size: Some(8),
        max_inter_thread_batched_pkts: None,
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
