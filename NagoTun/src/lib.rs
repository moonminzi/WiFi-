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
use engine::device::{DeviceConfig, DeviceHandle, MakeExternalNeptun, MakeExternalNeptunNoop};

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

/// 엔진 설정(앱·시험이 같이 쓴다).
fn device_config(threads: u32, queue: u32) -> DeviceConfig {
    DeviceConfig {
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
        // nagoing을 바로 붙이면(nago_nagoing_attach) 여기 꽂힌다. 비어 있으면 UDP 소켓 그대로.
        external_net: Default::default(),
    }
}

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
    tun_start(tun_fd, uapi, threads, queue, Arc::new(MakeExternalNeptunNoop))
}

/// [`nago_tun_start`]에 소켓 빼기(`protect`)를 더한 것. 엔진이 서버로 가는 UDP 소켓을 만들 때마다 부른다
/// (안드로이드: 앱도 VPN 안에 있어서 엔진 소켓만 `VpnService.protect`로 터널 밖으로 뺀다).
pub(crate) fn tun_start(
    tun_fd: c_int,
    uapi: *const c_char,
    threads: u32,
    queue: u32,
    protect: Arc<dyn MakeExternalNeptun>,
) -> *mut NagoTun {
    let Some(cmd) = text(uapi).map(|c| normalize(&c)) else {
        return fail("uapi is not utf-8".into());
    };
    let tun = match TunSocket::new_from_fd(tun_fd) {
        Ok(t) => t,
        Err(e) => return fail(format!("tun fd {tun_fd}: {e:?}")),
    };
    let mut config = device_config(threads, queue);
    config.protect = protect;
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

/// WireGuard 설정의 base64 키(32바이트)를 바이트로.
fn key32(b64: &str) -> Option<[u8; 32]> {
    base64::engine::general_purpose::STANDARD.decode(b64.trim()).ok()?.try_into().ok()
}

/// nagoing 클라이언트를 띄운다. 실패하면 NULL(사유는 nago_tun_last_error).
/// - `psk`: 서버와 공유하는 핸드셰이크 가리기 PSK(인증 아님)
/// - `private_key`/`server_pub`: WireGuard 설정의 클라 개인키·서버 공개키(base64). HELLO 인증·세션 키에 쓴다
/// - `server_ip` + `udp_port`/`tcp_port`: 서버 프록시 주소(TCP 443 = HTTPS, UDP는 전용 포트 51821)
/// - `local_ip`/`local_port`: NepTUN이 WG 패킷을 보낼 로컬 주소(보통 127.0.0.1)
/// - `fec_k`/`fec_groups`/`fec_on`: 손실 보정. fec_on=0이면 끔
/// - `prefer`: 0 auto(UDP→TCP), 1 udp, 2 tcp
/// - `sni`: TLS 1.3 ClientHello의 SNI(NULL이면 기본값)
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
    private_key: *const c_char,
    server_pub: *const c_char,
) -> *mut NagoingClient {
    nagoing_start(
        psk, server_ip, udp_port, tcp_port, local_ip, local_port, fec_k, fec_groups, fec_on, prefer, sni, private_key,
        server_pub, None,
    )
}

/// [`nago_nagoing_client_start`]에 소켓 빼기(`protect`, 안드로이드)를 더한 것.
#[allow(clippy::too_many_arguments)]
pub(crate) fn nagoing_start(
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
    private_key: *const c_char,
    server_pub: *const c_char,
    protect: Option<nagoing::proxy::Protect>,
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
    let (Some(identity), Some(server_pub)) =
        (text(private_key).as_deref().and_then(key32), text(server_pub).as_deref().and_then(key32))
    else {
        return fail("nagoing: private_key/server_pub must be base64 32-byte keys".into());
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
        identity,
        server_pub,
        protect,
    };
    match nagoing::run_client(cfg) {
        Ok(handle) => Box::into_raw(Box::new(NagoingClient { handle })),
        Err(e) => fail(format!("nagoing start: {e}")),
    }
}

/// 엔진 → nagoing: 엔진이 암호화한 WG 데이터그램을 nagoing 송신으로 바로 넘긴다(엔진 스레드에서).
struct NagoingNet(nagoing::DatagramSender);

impl engine::device::ExternalNet for NagoingNet {
    fn send(&self, packet: &[u8]) {
        self.0.send(packet);
    }
}

/// 엔진(nago_tun)과 nagoing을 바로 잇는다 — 로컬 UDP 홉(127.0.0.1) 없이 엔진이 암호화한 패킷을 nagoing이 바로
/// 봉인해 보내고, 받은 건 바로 복호화해 tun에 쓴다. 0이면 성공. 붙이기 전·뗀 뒤엔 로컬 UDP 포트로 그대로 돈다.
/// 엔진이나 nagoing 어느 쪽을 먼저 멈춰도 된다(nagoing이 멈출 땐 엔진에서 스스로 떨어진다).
#[no_mangle]
pub extern "C" fn nago_nagoing_attach(client: *mut NagoingClient, tun: *mut NagoTun) -> c_int {
    let (Some(client), Some(tun)) = (unsafe { client.as_ref() }, unsafe { tun.as_ref() }) else {
        return -1;
    };
    // 엔진 쪽(보내기)을 먼저 꽂는다. 받기(sink)를 먼저 꽂으면 그사이 받은 패킷이 '바깥 전송 없음'으로 버려진다
    // (반대 순서면 그사이엔 로컬 UDP로 받아 그대로 처리된다).
    tun.handle.set_external_net(Some(Arc::new(NagoingNet(client.handle.sender()))));
    let rx = tun.handle.external_receiver();
    let detach_rx = rx.clone();
    client.handle.attach(
        Arc::new(move |p: &[u8]| {
            rx.receive(p);
        }),
        Box::new(move || detach_rx.detach()),
    );
    0
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
    use super::*;

    // 엔진 두 개(클라·서버 wg0)를 가짜 tun으로 띄우고 사이에 nagoing을 둔다. 클라 엔진의 UDP 엔드포인트는 일부러
    // 아무도 안 듣는 포트(127.0.0.1:9)라, WG 핸드셰이크와 데이터가 오가면 nago_nagoing_attach의 직결 경로로만 간 것이다.
    #[cfg(target_os = "linux")]
    #[test]
    fn engine_attached_to_nagoing_end_to_end() {
        use std::os::fd::IntoRawFd;
        use std::os::unix::net::UnixDatagram;
        use std::time::{Duration, Instant};

        fn hex(b: &[u8]) -> String {
            b.iter().map(|x| format!("{x:02x}")).collect()
        }
        fn mock_tun() -> (TunSocket, UnixDatagram) {
            let (near, far) = UnixDatagram::pair().unwrap();
            near.set_nonblocking(true).unwrap();
            far.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            (TunSocket::new_mock_from_fd(near.into_raw_fd()), far)
        }
        // 최소 IPv4 헤더 + 페이로드(엔진은 목적지로 피어를, 출발지로 allowed_ip를 본다).
        fn ipv4(src: [u8; 4], dst: [u8; 4], payload: &[u8]) -> Vec<u8> {
            let mut p = vec![0x45, 0, 0, 0, 0, 0, 0x40, 0, 64, 17, 0, 0];
            p.extend_from_slice(&src);
            p.extend_from_slice(&dst);
            p.extend_from_slice(payload);
            let len = p.len() as u16;
            p[2..4].copy_from_slice(&len.to_be_bytes());
            p
        }

        let mut ck = [0u8; 32];
        let mut sk = [0u8; 32];
        nagoing::rand_bytes(&mut ck);
        nagoing::rand_bytes(&mut sk);
        let (cpub, spub) = (nagoing::Identity::from_bytes(ck).public(), nagoing::Identity::from_bytes(sk).public());

        // 서버 wg0(엔진, UDP 47820)
        let (stun, sfar) = mock_tun();
        let server_wg = DeviceHandle::new_with_mock_tun(stun, 1420, device_config(1, 0)).unwrap();
        assert_eq!(errno_of(&server_wg.send_uapi_cmd(&format!(
            "set=1\nprivate_key={}\nlisten_port=47820\npublic_key={}\nallowed_ip=10.9.0.2/32\n\n", hex(&sk), hex(&cpub)
        ))), 0);
        let relay = nagoing::run_server(nagoing::ServerConfig {
            psk: "p".into(),
            udp_bind: "127.0.0.1:0".parse().unwrap(),
            tcp_bind: "127.0.0.1:0".parse().unwrap(),
            upstream: "127.0.0.1:47820".parse().unwrap(),
            fec: nagoing::FecParams::default(),
            identity: sk,
            tls_cert_pem: nagoing::testcert::CERT_PEM.into(),
            tls_key_pem: nagoing::testcert::KEY_PEM.into(),
        })
        .unwrap();

        // 클라: nagoing(로컬 포트는 폴백용으로만) + 엔진(엔드포인트 = 죽은 포트)
        let client = nagoing::run_client(nagoing::ClientConfig {
            psk: "p".into(),
            server_udp: relay.udp_addr(),
            server_tcp: relay.tcp_addr(),
            local_bind: "127.0.0.1:0".parse().unwrap(),
            fec: nagoing::FecParams::default(),
            prefer: nagoing::Prefer::Udp,
            sni: "x".into(),
            identity: ck,
            server_pub: spub,
            protect: None,
        })
        .unwrap();
        let (ctun, cfar) = mock_tun();
        let client_wg = DeviceHandle::new_with_mock_tun(ctun, 1380, device_config(1, 0)).unwrap();
        assert_eq!(errno_of(&client_wg.send_uapi_cmd(&format!(
            "set=1\nprivate_key={}\npublic_key={}\nendpoint=127.0.0.1:9\nallowed_ip=10.9.0.1/32\n\n", hex(&ck), hex(&spub)
        ))), 0);
        let tun = Box::into_raw(Box::new(NagoTun { handle: client_wg }));
        let ncl = Box::into_raw(Box::new(NagoingClient { handle: client }));
        let start = Instant::now();
        while unsafe { &*ncl }.handle.stats().kind.is_none() && start.elapsed() < Duration::from_secs(5) {
            std::thread::sleep(Duration::from_millis(50));
        }
        assert_eq!(nago_nagoing_attach(ncl, tun), 0);

        // 올리기: 클라 tun → 엔진 암호화 → (직결) nagoing → 서버 → wg0 복호화 → 서버 tun
        let up = ipv4([10, 9, 0, 2], [10, 9, 0, 1], b"hello over attached nagoing");
        let mut buf = [0u8; 2048];
        let mut got_up = None;
        for _ in 0..20 {
            cfar.send(&up).unwrap(); // 첫 패킷은 핸드셰이크 대기열에 들어간다 — 몇 번 보낸다
            sfar.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
            if let Ok(n) = sfar.recv(&mut buf) {
                got_up = Some(buf[..n].to_vec());
                break;
            }
        }
        assert_eq!(got_up.as_deref(), Some(&up[..]), "올리기가 직결 경로로 안 감");

        // 내리기: 서버 tun → wg0 → nagoing → (직결) 엔진 복호화 → 클라 tun
        let down = ipv4([10, 9, 0, 1], [10, 9, 0, 2], b"and back down");
        sfar.send(&down).unwrap();
        let n = cfar.recv(&mut buf).expect("내리기가 직결 경로로 안 옴");
        assert_eq!(&buf[..n], &down[..]);

        // 클라를 먼저 멈춰도(엔진에서 스스로 떨어짐) 엔진은 멀쩡하다.
        nago_nagoing_client_stop(ncl);
        cfar.send(&up).unwrap(); // 이제 UDP(죽은 포트)로 가서 버려질 뿐, 터지지 않는다
        nago_tun_stop(tun);
        relay.stop();
        server_wg.trigger_exit();
    }

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
