//! 안드로이드 앱(Kotlin `com.nago.vpn.NeptunNative`)에서 부르는 JNI 함수. 실제 일은 lib.rs의 C 인터페이스가 한다.
//! 엔진의 UDP 소켓은 앱을 VPN에서 빼 두는 방식(VpnService.Builder.addDisallowedApplication)으로
//! 터널 밖으로 나가므로 소켓마다 protect()를 부를 필요가 없다.

use std::ffi::{c_char, CString};
use std::ptr;

use jni::objects::{JClass, JString};
use jni::sys::{jint, jlong, jstring};
use jni::JNIEnv;

use crate::NagoTun;

fn c_text(env: &mut JNIEnv, text: &JString) -> Option<CString> {
    let value: String = env.get_string(text).ok()?.into();
    CString::new(value).ok()
}

fn java_text(env: &JNIEnv, text: &str) -> jstring {
    env.new_string(text).map(|s| s.into_raw()).unwrap_or(ptr::null_mut())
}

/// 터널 시작. 실패하면 0(이유는 lastError).
#[no_mangle]
pub extern "system" fn Java_com_nago_vpn_NeptunNative_start(
    mut env: JNIEnv,
    _class: JClass,
    tun_fd: jint,
    uapi: JString,
    threads: jint,
) -> jlong {
    let Some(cmd) = c_text(&mut env, &uapi) else {
        return 0;
    };
    crate::nago_tun_start(tun_fd, cmd.as_ptr(), threads.max(1) as u32, 0) as jlong
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
