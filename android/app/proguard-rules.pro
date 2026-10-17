# WireGuard GoBackend: 네이티브(libwg-go)와 연결되는 클래스는 이름을 그대로 둔다
-keep class com.wireguard.android.backend.** { *; }
-keep class com.wireguard.config.** { *; }
-keep class com.wireguard.crypto.** { *; }

# NepTUN(NagoTun) JNI: 네이티브 함수 이름이 Java_com_nago_vpn_NeptunNative_* 로 고정
-keep class com.nago.vpn.NeptunNative { native <methods>; }
