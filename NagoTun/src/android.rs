//! 안드로이드 앱(Kotlin `com.nago.vpn.NeptunNative`·`NagoingNative`)에서 부르는 JNI 함수. 실제 일은 lib.rs의 C 인터페이스가 한다.
//!
//! 앱도 VPN 안에 있다(iOS처럼 — 앱의 속도 측정·네트워크 검사·출구 확인이 터널을 지나게). 대신 서버로 가는 소켓
//! (엔진의 UDP, nagoing의 UDP·TCP)은 만들 때마다 `VpnService.protect(fd)`로 터널 밖으로 뺀다(wireguard-go와 같은 방식).

use std::ffi::{c_char, CString};
use std::os::fd::RawFd;
use std::ptr;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use engine::device::MakeExternalNeptun;
use jni::objects::{GlobalRef, JClass, JObject, JString, JValue};
use jni::sys::{jint, jlong, jstring};
use jni::{JNIEnv, JavaVM};

use crate::{NagoTun, NagoingClient};

/// protect가 실패한 횟수(앱이 로그에 남긴다). 실패한 소켓은 터널로 돌아 들어가 연결이 안 된다.
static PROTECT_FAILURES: AtomicU32 = AtomicU32::new(0);

/// `VpnService.protect(int)`를 부르는 손잡이. 엔진 스레드(자바가 모르는 스레드)에서도 불리므로 그때마다 붙였다 뗀다.
struct Protector {
    vm: JavaVM,
    service: GlobalRef,
}

impl Protector {
    fn new(env: &mut JNIEnv, service: &JObject) -> Option<Arc<Self>> {
        Some(Arc::new(Self { vm: env.get_java_vm().ok()?, service: env.new_global_ref(service).ok()? }))
    }

    fn protect(&self, fd: RawFd) -> bool {
        let ok = match self.vm.attach_current_thread() {
            Ok(mut env) => {
                let result = env.call_method(self.service.as_obj(), "protect", "(I)Z", &[JValue::Int(fd)]).and_then(|v| v.z());
                if env.exception_check().unwrap_or(false) {
                    let _ = env.exception_clear();
                }
                matches!(result, Ok(true))
            }
            Err(_) => false,
        };
        if !ok {
            PROTECT_FAILURES.fetch_add(1, Ordering::Relaxed);
        }
        ok
    }
}

impl MakeExternalNeptun for Protector {
    fn make_external(&self, socket: RawFd) {
        self.protect(socket);
    }
}

fn c_text(env: &mut JNIEnv, text: &JString) -> Option<CString> {
    let value: String = env.get_string(text).ok()?.into();
    CString::new(value).ok()
}

fn java_text(env: &JNIEnv, text: &str) -> jstring {
    env.new_string(text).map(|s| s.into_raw()).unwrap_or(ptr::null_mut())
}

/// 터널 시작. 실패하면 0(이유는 lastError). `service`(VpnService)로 엔진 소켓을 터널 밖으로 뺀다.
#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NeptunNative_start(
    mut env: JNIEnv,
    _class: JClass,
    service: JObject,
    tun_fd: jint,
    uapi: JString,
    threads: jint,
) -> jlong {
    let (Some(cmd), Some(protector)) = (c_text(&mut env, &uapi), Protector::new(&mut env, &service)) else {
        return 0;
    };
    crate::tun_start(tun_fd, cmd.as_ptr(), threads.max(1) as u32, 0, protector) as jlong
}

/// 지금까지 protect가 실패한 횟수
#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NeptunNative_protectFailures(_env: JNIEnv, _class: JClass) -> jint {
    PROTECT_FAILURES.load(Ordering::Relaxed) as jint
}

/// 설정 변경(서버 주소 바꾸기 등). 0이면 성공, 아니면 UAPI errno.
#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NeptunNative_set(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    uapi: JString,
) -> jint {
    match c_text(&mut env, &uapi) {
        Some(cmd) => crate::nago_tun_set(handle as *mut NagoTun, cmd.as_ptr()),
        None => -1,
    }
}

/// UAPI get=1 응답(last_handshake_time_sec, rx_bytes, tx_bytes …)
#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NeptunNative_get(env: JNIEnv, _class: JClass, handle: jlong) -> jstring {
    let mut buf = vec![0u8; 4096];
    let n = crate::nago_tun_get(handle as *mut NagoTun, buf.as_mut_ptr() as *mut c_char, buf.len());
    let text = String::from_utf8_lossy(&buf[..n.min(buf.len() - 1)]).into_owned();
    java_text(&env, &text)
}

/// 와이파이↔모바일 데이터 전환 때 UDP 소켓을 새로 만든다.
#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NeptunNative_networkChanged(_env: JNIEnv, _class: JClass, handle: jlong) {
    crate::nago_tun_network_changed(handle as *mut NagoTun);
}

/// 터널을 멈추고 해제한다(utun fd도 엔진이 닫음).
#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NeptunNative_stop(_env: JNIEnv, _class: JClass, handle: jlong) {
    crate::nago_tun_stop(handle as *mut NagoTun);
}

#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NeptunNative_lastError(env: JNIEnv, _class: JClass) -> jstring {
    let mut buf = vec![0u8; 512];
    let n = crate::nago_tun_last_error(buf.as_mut_ptr() as *mut c_char, buf.len());
    let text = String::from_utf8_lossy(&buf[..n.min(buf.len() - 1)]).into_owned();
    java_text(&env, &text)
}

// ── nagoing(막힌 망 우회) ───────────────────────────────────────────────────────────────

/// 난독화 PSK. 보안이 아니라 DPI 회피용이라 모든 클라가 공유한다(iOS NagoingSettings.psk와 같음).
const NAGOING_PSK: &str = "nago-obfs-v1";

/// nagoing 클라이언트 시작. 실패하면 0(이유는 NeptunNative.lastError). 서버로 가는 소켓은 `service`로 protect한다.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "system" fn Java_com_nago_vpn_NagoingNative_start(
    mut env: JNIEnv,
    _class: JClass,
    service: JObject,
    server_ip: JString,
    udp_port: jint,
    tcp_port: jint,
    local_port: jint,
    fec_k: jint,
    fec_groups: jint,
    fec_on: jint,
    prefer: jint,
    sni: JString,
    private_key: JString,
    server_pub: JString,
) -> jlong {
    let (Some(ip), Some(sni), Some(key), Some(pub_key), Some(protector)) = (
        c_text(&mut env, &server_ip),
        c_text(&mut env, &sni),
        c_text(&mut env, &private_key),
        c_text(&mut env, &server_pub),
        Protector::new(&mut env, &service),
    ) else {
        return 0;
    };
    let psk = CString::new(NAGOING_PSK).unwrap_or_default();
    let local = CString::new("127.0.0.1").unwrap_or_default();
    crate::nagoing_start(
        psk.as_ptr(),
        ip.as_ptr(),
        udp_port as u16,
        tcp_port as u16,
        local.as_ptr(),
        local_port as u16,
        fec_k.clamp(1, 255) as u8,
        fec_groups.clamp(1, 65535) as u16,
        fec_on,
        prefer,
        sni.as_ptr(),
        key.as_ptr(),
        pub_key.as_ptr(),
        Some(Arc::new(move |fd| protector.protect(fd))),
    ) as jlong
}

/// 엔진(NeptunNative 손잡이)에 바로 붙인다. 0이면 성공.
#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NagoingNative_attach(_env: JNIEnv, _class: JClass, client: jlong, tun: jlong) -> jint {
    crate::nago_nagoing_attach(client as *mut NagoingClient, tun as *mut NagoTun)
}

#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NagoingNative_networkChanged(_env: JNIEnv, _class: JClass, client: jlong) {
    crate::nago_nagoing_network_changed(client as *mut NagoingClient);
}

/// 상태 한 줄("udp · tx .. · rx .. · fec+..")
#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NagoingNative_stats(env: JNIEnv, _class: JClass, client: jlong) -> jstring {
    let mut buf = vec![0u8; 256];
    let n = crate::nago_nagoing_stats(client as *mut NagoingClient, buf.as_mut_ptr() as *mut c_char, buf.len());
    let text = String::from_utf8_lossy(&buf[..n.min(buf.len() - 1)]).into_owned();
    java_text(&env, &text)
}

/// 멈추고 해제한다(연결 수립 중이면 몇 초 기다릴 수 있다 — 메인 스레드에서 부르지 않는다).
#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NagoingNative_stop(_env: JNIEnv, _class: JClass, client: jlong) {
    crate::nago_nagoing_client_stop(client as *mut NagoingClient);
}
