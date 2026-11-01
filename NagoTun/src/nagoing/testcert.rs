//! 시험·데모용 자체서명 TLS 인증서(localhost, P-256). 개인키가 공개돼 있으니 **운영 서버에서 쓰지 말 것** —
//! 운영은 setup-nagoing.sh가 서버마다 새로 만든다. (클라는 인증서를 검증하지 않고 안쪽 HELLO MAC으로 서버를 인증한다.)

pub const CERT_PEM: &str = "\
-----BEGIN CERTIFICATE-----
MIIBfzCCASWgAwIBAgIUTtAjCkPg6egPFv59cSBealuHHTIwCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAzMDAxMzMwMloYDzIxMjYxMDA2
MDEzMzAyWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAAQpd3UESpge6OrcziRAj1hjhcmR+SMcn9cpS4JBqp+HoM3+ZNn3v5K7
6SVt94DcJv+oFde3Zw7reMyMHvUUCazno1MwUTAdBgNVHQ4EFgQUatY6H7d67hE/
Ip76WrGd1sx3xgAwHwYDVR0jBBgwFoAUatY6H7d67hE/Ip76WrGd1sx3xgAwDwYD
VR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAoVFomEn1Cyr7SanOR1qB
tyXacgsYwtWvJzQus/LFNh0CIErUGkUOXP6MLNJXgpte9j1i0qM5wVscGcShrX32
E4xK
-----END CERTIFICATE-----
";

pub const KEY_PEM: &str = "\
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgaD8SdE9H02UbQ4nS
QNC965m+PG63OR+BddVzOvFeg/2hRANCAAQpd3UESpge6OrcziRAj1hjhcmR+SMc
n9cpS4JBqp+HoM3+ZNn3v5K76SVt94DcJv+oFde3Zw7reMyMHvUUCazn
-----END PRIVATE KEY-----
";
