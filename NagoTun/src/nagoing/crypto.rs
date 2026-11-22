//! nagoing v2 암호 층 — 인증된 핸드셰이크, 세션 AEAD, 재전송(리플레이) 방어.
//!
//! v1은 공유 PSK로 ChaCha20 keystream을 씌우기만 해서(무결성·인증 없음), PSK를 아는 누구나(공개 소스) 프레임을
//! 만들어 넣거나, 남의 HELLO를 다시 보내 그 세션의 반환 경로를 가로챌 수 있었다. v2는:
//!
//! - **HELLO 인증**: 클라의 WireGuard 개인키 × 서버의 WireGuard 공개키(X25519)로 고정 비밀을 만들고, 그 비밀로
//!   HELLO/HELLO_ACK에 MAC을 단다. 새 키 배포가 필요 없다(클라 설정에 이미 privateKey·serverPub가 있고, 서버는
//!   wg0의 개인키를 쓴다). PSK를 알아도 남의 WG 개인키 없이는 그 세션을 가로챌 수 없고, 가짜 서버도 ACK를 못 만든다.
//! - **리플레이 방어(핸드셰이크)**: HELLO에 시각(±HELLO_SKEW)과 16바이트 난수를 넣고, 서버가 창 안의 난수를 기억한다.
//! - **세션 AEAD**: 연결(HELLO)마다 양쪽 난수로 새 세션 키를 뽑아 ChaCha20-Poly1305(ring, SIMD)로 프레임을 봉인한다.
//!   nonce는 64비트 카운터라 겹칠 수 없고, 받는 쪽은 2048칸 리플레이 창으로 같은 패킷의 재전송을 버린다.
//!   v3: 큰 프레임은 앞 64바이트(nagoing 헤더 + WG 헤더)만 봉인하고 나머지(이미 WG 암호문)는 그대로 싣는다. 카운터·
//!   헤더는 인증되므로 재전송·위조 방어는 같고, 뒤쪽을 바꾸면 안쪽 WireGuard가 버린다(경로상 공격자가 패킷을 버리는
//!   것과 같음). 대신 nagoing이 바이트마다 하던 두 번째 암호화가 사라진다.
//! - **카운터 가리기**: 카운터를 평문으로 두면 증가하는 숫자가 지문이 되므로, QUIC 헤더 보호처럼 태그를 표본으로
//!   만든 마스크로 XOR해 싣는다.
//!
//! PSK는 이제 HELLO 자체를 가리는(DPI가 내용을 못 보게) 용도로만 쓰인다 — 보안은 위의 키들이 맡는다.
//! WG 고정키를 다른 프로토콜에 다시 쓰지만, X25519 결과는 HKDF의 별도 라벨("nagoing-v2 …")로만 쓴다.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use ring::aead::quic::{self, HeaderProtectionKey};
use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, CHACHA20_POLY1305};
use ring::{hkdf, hmac};
use x25519_dalek::{PublicKey, StaticSecret};

use super::rand_bytes;

pub const TAG_LEN: usize = 16;
/// 세션 메시지 앞의 (가린) 카운터 길이 — 64비트 카운터의 아래 40비트만 싣고 받는 쪽이 복원한다(QUIC 패킷 번호처럼).
/// 마스크는 ring의 QUIC 헤더 보호(ChaCha20, 어셈블리)가 정확히 5바이트를 준다.
pub const CTR_LEN: usize = 5;
const CTR_BITS: u32 = 40;
/// 핸드셰이크 메시지 앞의 무작위 nonce 길이.
const HS_NONCE_LEN: usize = 12;
/// 세션 메시지가 붙이는 바이트(카운터 + 태그).
pub const SESSION_OVERHEAD: usize = CTR_LEN + TAG_LEN;

pub const VERSION: u8 = 3;

/// 이 길이 이하의 평문 프레임은 통째로 봉인한다(컨트롤·작은 DATA — 패딩까지 다 가려진다).
const FULL_SEAL_MAX: usize = 320;
/// 그보다 큰 프레임은 앞 이만큼만 봉인한다(nagoing 프레임 헤더 + WG 헤더 16바이트 + 여유).
/// 나머지는 이미 WireGuard가 암호화·인증한 바이트(또는 그 XOR 패리티)라 다시 암호화할 필요가 없다 —
/// v2는 1400바이트를 통째로 한 번 더 암호화해서 폰 CPU의 큰 몫을 썼다(callgrind: AEAD가 사용자 명령의 ~78%).
const SEAL_HEAD: usize = 64;

/// 봉인할 앞부분 길이.
fn sealed_len(plain_len: usize) -> usize {
    if plain_len <= FULL_SEAL_MAX { plain_len } else { SEAL_HEAD }
}
const HELLO: u8 = 0x01;
const ACK: u8 = 0x02;
/// HELLO 시각 허용 오차(초). 폰 시계는 NTP로 맞춰져 있어 넉넉하다.
pub const HELLO_SKEW: u64 = 180;

// ── 작은 도구 ────────────────────────────────────────────────────────────────

struct Len32;
impl hkdf::KeyType for Len32 {
    fn len(&self) -> usize {
        32
    }
}

fn hkdf32(salt: &[u8], ikm: &[u8], info: &[u8]) -> [u8; 32] {
    let prk = hkdf::Salt::new(hkdf::HKDF_SHA256, salt).extract(ikm);
    let mut out = [0u8; 32];
    // 길이 32는 HKDF-SHA256 한도(255×32) 안이라 실패하지 않는다.
    if let Ok(okm) = prk.expand(&[info], Len32) {
        let _ = okm.fill(&mut out);
    }
    out
}

fn aead_key(k: &[u8; 32]) -> LessSafeKey {
    // 32바이트 키는 CHACHA20_POLY1305의 키 길이와 같아 실패하지 않는다.
    LessSafeKey::new(UnboundKey::new(&CHACHA20_POLY1305, k).expect("chacha20-poly1305 key"))
}

fn ctr_nonce(ctr: u64) -> Nonce {
    let mut n = [0u8; 12];
    n[4..].copy_from_slice(&ctr.to_le_bytes());
    Nonce::assume_unique_for_key(n)
}

fn mac16(key: &[u8; 32], label: &[u8], parts: &[&[u8]]) -> [u8; 16] {
    let k = hmac::Key::new(hmac::HMAC_SHA256, key);
    let mut ctx = hmac::Context::with_key(&k);
    ctx.update(b"nagoing-v2 ");
    ctx.update(label);
    for p in parts {
        ctx.update(p);
    }
    let tag = ctx.sign();
    let mut out = [0u8; 16];
    out.copy_from_slice(&tag.as_ref()[..16]);
    out
}

/// 시간이 일정한 비교(MAC 검증에서 몇 바이트가 맞았는지 새지 않게).
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ── 고정 키(WireGuard 키를 그대로 쓴다) ──────────────────────────────────────

/// 내 X25519 고정 키. 클라는 WG 개인키, 서버는 wg0 개인키.
pub struct Identity {
    secret: StaticSecret,
    public: [u8; 32],
}

impl Identity {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        let secret = StaticSecret::from(bytes);
        let public = PublicKey::from(&secret).to_bytes();
        Identity { secret, public }
    }

    /// 시험용 무작위 키.
    pub fn generate() -> Self {
        let mut b = [0u8; 32];
        rand_bytes(&mut b);
        Self::from_bytes(b)
    }

    pub fn public(&self) -> [u8; 32] {
        self.public
    }

    /// 상대 공개키와의 고정 비밀(HELLO MAC·세션 키의 재료). 약한 공개키(모두 0 등)면 None.
    pub fn shared(&self, peer: &[u8; 32]) -> Option<[u8; 32]> {
        let dh = self.secret.diffie_hellman(&PublicKey::from(*peer));
        if !dh.was_contributory() {
            return None;
        }
        Some(hkdf32(b"nagoing-v2", dh.as_bytes(), b"static"))
    }
}

// ── 핸드셰이크(PSK로 가리고, 고정 비밀로 인증) ──────────────────────────────

/// PSK로 핸드셰이크 메시지를 가리는 키. 인증은 안에 든 MAC이 맡는다.
pub struct HandshakeKey(LessSafeKey);

impl HandshakeKey {
    pub fn from_psk(psk: &[u8]) -> Self {
        HandshakeKey(aead_key(&hkdf32(b"nagoing-v2 psk", psk, b"handshake")))
    }

    /// `[nonce 12][AEAD(평문)]`. 핸드셰이크는 드물어서 무작위 96비트 nonce로 충분하다.
    fn seal(&self, plain: &[u8]) -> Vec<u8> {
        let mut nonce = [0u8; HS_NONCE_LEN];
        rand_bytes(&mut nonce);
        let mut out = Vec::with_capacity(HS_NONCE_LEN + plain.len() + TAG_LEN);
        out.extend_from_slice(&nonce);
        out.extend_from_slice(plain);
        let tag = self
            .0
            .seal_in_place_separate_tag(Nonce::assume_unique_for_key(nonce), Aad::empty(), &mut out[HS_NONCE_LEN..])
            .expect("seal");
        out.extend_from_slice(tag.as_ref());
        out
    }

    fn open<'a>(&self, msg: &'a mut [u8]) -> Option<&'a [u8]> {
        if msg.len() < HS_NONCE_LEN + TAG_LEN {
            return None;
        }
        let (n, body) = msg.split_at_mut(HS_NONCE_LEN);
        let nonce = Nonce::try_assume_unique_for_key(n).ok()?;
        self.0.open_in_place(nonce, Aad::empty(), body).ok().map(|p| &*p)
    }
}

/// 클라 → 서버 첫 메시지.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientHello {
    pub session: u64,
    pub ts: u64,
    pub random: [u8; 16],
    pub static_pub: [u8; 32],
}

const HELLO_LEN: usize = 2 + 8 + 8 + 16 + 32 + 16;

impl ClientHello {
    pub fn new(session: u64, static_pub: [u8; 32]) -> Self {
        let mut random = [0u8; 16];
        rand_bytes(&mut random);
        ClientHello { session, ts: now_unix(), random, static_pub }
    }

    fn mac(&self, k_static: &[u8; 32]) -> [u8; 16] {
        mac16(k_static, b"hello", &[&self.session.to_le_bytes(), &self.ts.to_le_bytes(), &self.random, &self.static_pub])
    }

    /// 봉인한 HELLO. `pad_to`까지 평문을 무작위로 채운다(UDP는 QUIC Initial처럼 크게).
    pub fn seal(&self, hs: &HandshakeKey, k_static: &[u8; 32], pad_to: usize) -> Vec<u8> {
        let mut p = Vec::with_capacity(pad_to.max(HELLO_LEN));
        p.push(HELLO);
        p.push(VERSION);
        p.extend_from_slice(&self.session.to_le_bytes());
        p.extend_from_slice(&self.ts.to_le_bytes());
        p.extend_from_slice(&self.random);
        p.extend_from_slice(&self.static_pub);
        p.extend_from_slice(&self.mac(k_static));
        pad(&mut p, pad_to);
        hs.seal(&p)
    }

    /// PSK로 풀고 모양을 읽는다. MAC은 아직 확인 안 함 → `verify`(서버가 고정 비밀을 구한 뒤).
    pub fn open(hs: &HandshakeKey, msg: &mut [u8]) -> Option<(ClientHello, [u8; 16])> {
        let p = hs.open(msg)?;
        if p.len() < HELLO_LEN || p[0] != HELLO || p[1] != VERSION {
            return None;
        }
        let h = ClientHello {
            session: u64::from_le_bytes(p[2..10].try_into().ok()?),
            ts: u64::from_le_bytes(p[10..18].try_into().ok()?),
            random: p[18..34].try_into().ok()?,
            static_pub: p[34..66].try_into().ok()?,
        };
        let mac: [u8; 16] = p[66..82].try_into().ok()?;
        Some((h, mac))
    }

    pub fn verify(&self, mac: &[u8; 16], k_static: &[u8; 32]) -> bool {
        ct_eq(mac, &self.mac(k_static))
    }

    /// 시각이 허용 범위 안인가(오래된 HELLO의 재전송 거부).
    pub fn fresh(&self, now: u64) -> bool {
        now.abs_diff(self.ts) <= HELLO_SKEW
    }
}

/// 서버 → 클라 응답. 클라는 MAC으로 진짜 서버(그 WG 개인키를 가진)인지 확인한다.
pub struct ServerAck {
    pub session: u64,
    pub random: [u8; 16],
}

const ACK_LEN: usize = 2 + 8 + 16 + 16;

impl ServerAck {
    fn mac(&self, k_static: &[u8; 32], client_random: &[u8; 16]) -> [u8; 16] {
        mac16(k_static, b"ack", &[&self.session.to_le_bytes(), client_random, &self.random])
    }

    pub fn seal(&self, hs: &HandshakeKey, k_static: &[u8; 32], client_random: &[u8; 16], pad_to: usize) -> Vec<u8> {
        let mut p = Vec::with_capacity(pad_to.max(ACK_LEN));
        p.push(ACK);
        p.push(VERSION);
        p.extend_from_slice(&self.session.to_le_bytes());
        p.extend_from_slice(&self.random);
        p.extend_from_slice(&self.mac(k_static, client_random));
        pad(&mut p, pad_to);
        hs.seal(&p)
    }

    /// 풀어서 MAC까지 확인한다(이 HELLO에 대한 진짜 서버 응답일 때만 Some).
    pub fn open(hs: &HandshakeKey, msg: &mut [u8], k_static: &[u8; 32], hello: &ClientHello) -> Option<ServerAck> {
        let p = hs.open(msg)?;
        if p.len() < ACK_LEN || p[0] != ACK || p[1] != VERSION {
            return None;
        }
        let ack = ServerAck {
            session: u64::from_le_bytes(p[2..10].try_into().ok()?),
            random: p[10..26].try_into().ok()?,
        };
        let ok = ack.session == hello.session && ct_eq(&p[26..42], &ack.mac(k_static, &hello.random));
        ok.then_some(ack)
    }
}

/// 평문 끝을 무작위 길이로 채운다(길이 지문 가리기). 받는 쪽은 앞의 고정 필드만 읽는다.
fn pad(p: &mut Vec<u8>, pad_to: usize) {
    if p.len() < pad_to {
        let start = p.len();
        p.resize(pad_to, 0);
        rand_bytes(&mut p[start..]);
    }
}

// ── 세션 ─────────────────────────────────────────────────────────────────────

/// 2048칸 리플레이 창(WireGuard와 같은 크기). 창보다 오래됐거나 이미 받은 카운터는 거절한다.
pub struct ReplayWindow {
    top: u64,
    any: bool,
    bits: [u64; (WINDOW / 64) as usize],
}

const WINDOW: u64 = 2048;

impl Default for ReplayWindow {
    fn default() -> Self {
        ReplayWindow { top: 0, any: false, bits: [0; (WINDOW / 64) as usize] }
    }
}

impl ReplayWindow {
    /// 다음에 올 것으로 보는 카운터(아무것도 안 받았으면 0).
    fn expected(&self) -> u64 {
        if self.any { self.top + 1 } else { 0 }
    }

    fn bit(ctr: u64) -> (usize, u64) {
        let i = ctr % WINDOW;
        ((i / 64) as usize, 1u64 << (i % 64))
    }

    /// 처음 보는 카운터면 기록하고 true, 재전송이거나 너무 오래됐으면 false.
    pub fn accept(&mut self, ctr: u64) -> bool {
        if !self.any || ctr > self.top {
            if !self.any || ctr - self.top >= WINDOW {
                self.bits = [0; (WINDOW / 64) as usize];
            } else {
                for c in self.top + 1..ctr {
                    let (w, m) = Self::bit(c);
                    self.bits[w] &= !m;
                }
            }
            let (w, m) = Self::bit(ctr);
            self.bits[w] |= m;
            self.top = ctr;
            self.any = true;
            return true;
        }
        if self.top - ctr >= WINDOW {
            return false;
        }
        let (w, m) = Self::bit(ctr);
        if self.bits[w] & m != 0 {
            return false;
        }
        self.bits[w] |= m;
        true
    }
}

/// 한 세션(=한 번의 HELLO)의 방향별 키·카운터·리플레이 창.
pub struct SessionKeys {
    tx: LessSafeKey,
    rx: LessSafeKey,
    tx_hp: HeaderProtectionKey,
    rx_hp: HeaderProtectionKey,
    tx_ctr: AtomicU64,
    window: Mutex<ReplayWindow>,
}

impl SessionKeys {
    /// 양쪽 난수로 이번 세션 키를 뽑는다. client=true면 클라 쪽(c2s로 보내고 s2c를 받음).
    pub fn derive(k_static: &[u8; 32], client_random: &[u8; 16], server_random: &[u8; 16], client: bool) -> Self {
        let mut salt = [0u8; 32];
        salt[..16].copy_from_slice(client_random);
        salt[16..].copy_from_slice(server_random);
        let c2s = hkdf32(&salt, k_static, b"nagoing-v2 c2s key");
        let s2c = hkdf32(&salt, k_static, b"nagoing-v2 s2c key");
        let c2s_hp = hkdf32(&salt, k_static, b"nagoing-v2 c2s hp");
        let s2c_hp = hkdf32(&salt, k_static, b"nagoing-v2 s2c hp");
        let (tx, rx, tx_hp, rx_hp) = if client { (c2s, s2c, c2s_hp, s2c_hp) } else { (s2c, c2s, s2c_hp, c2s_hp) };
        SessionKeys {
            tx: aead_key(&tx),
            rx: aead_key(&rx),
            tx_hp: HeaderProtectionKey::new(&quic::CHACHA20, &tx_hp).expect("hp key"),
            rx_hp: HeaderProtectionKey::new(&quic::CHACHA20, &rx_hp).expect("hp key"),
            tx_ctr: AtomicU64::new(0),
            window: Mutex::new(ReplayWindow::default()),
        }
    }

    /// 태그(맨 끝 16바이트)를 표본으로 카운터를 가리는 5바이트 마스크(QUIC 헤더 보호 그대로, ring 어셈블리).
    fn mask(hp: &HeaderProtectionKey, tag: &[u8]) -> [u8; CTR_LEN] {
        hp.new_mask(tag).unwrap_or([0; CTR_LEN])
    }

    /// 아래 40비트만 받은 카운터를 다음에 올 값(창의 맨 위 + 1)에 가장 가까운 64비트 값으로 복원한다(RFC 9000 A.3).
    fn expand_ctr(expected: u64, low: u64) -> u64 {
        let win = 1u64 << CTR_BITS;
        let half = win / 2;
        let cand = (expected & !(win - 1)) | low;
        if cand.saturating_add(half) <= expected {
            cand + win
        } else if cand > expected.saturating_add(half) && cand >= win {
            cand - win
        } else {
            cand
        }
    }

    /// 평문 프레임을 봉인해 out에 `[가린 카운터 8][봉인한 앞부분][나머지 그대로][태그 16]`으로 쓴다.
    pub fn seal(&self, plain: &[u8], out: &mut Vec<u8>) {
        let ctr = self.tx_ctr.fetch_add(1, Ordering::Relaxed);
        let head = sealed_len(plain.len());
        out.clear();
        out.reserve(SESSION_OVERHEAD + plain.len());
        out.extend_from_slice(&[0u8; CTR_LEN]);
        out.extend_from_slice(plain);
        let tag = self
            .tx
            .seal_in_place_separate_tag(ctr_nonce(ctr), Aad::empty(), &mut out[CTR_LEN..CTR_LEN + head])
            .expect("seal");
        out.extend_from_slice(tag.as_ref());
        let mask = Self::mask(&self.tx_hp, tag.as_ref());
        for (i, b) in ctr.to_le_bytes()[..CTR_LEN].iter().enumerate() {
            out[i] = b ^ mask[i];
        }
    }

    /// 받은 메시지를 제자리에서 풀어 평문을 돌려준다. 위조·변조됐거나 이미 받은(재전송) 것이면 None.
    pub fn open<'a>(&self, msg: &'a mut [u8]) -> Option<&'a [u8]> {
        if msg.len() < SESSION_OVERHEAD {
            return None;
        }
        let mask = Self::mask(&self.rx_hp, &msg[msg.len() - TAG_LEN..]);
        let mut cb = [0u8; 8];
        for i in 0..CTR_LEN {
            cb[i] = msg[i] ^ mask[i];
        }
        let expected = self.window.lock().unwrap().expected();
        let ctr = Self::expand_ctr(expected, u64::from_le_bytes(cb));
        let end = msg.len() - TAG_LEN;
        let tag = ring::aead::Tag::try_from(&msg[end..]).ok()?;
        let head = sealed_len(end - CTR_LEN);
        self.rx
            .open_in_place_separate_tag(ctr_nonce(ctr), Aad::empty(), tag, &mut msg[CTR_LEN..CTR_LEN + head], 0..)
            .ok()?;
        // 인증된 뒤에만 창에 기록한다(위조 패킷이 창을 밀어 진짜를 막지 못하게).
        if !self.window.lock().unwrap().accept(ctr) {
            return None;
        }
        Some(&msg[CTR_LEN..end])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (Identity, Identity) {
        (Identity::generate(), Identity::generate())
    }

    #[test]
    fn static_secret_agrees() {
        let (c, s) = pair();
        assert_eq!(c.shared(&s.public()), s.shared(&c.public()));
        assert!(c.shared(&[0u8; 32]).is_none()); // 약한 공개키 거절
    }

    #[test]
    fn handshake_roundtrip_and_auth() {
        let hs = HandshakeKey::from_psk(b"psk");
        let (c, s) = pair();
        let k = c.shared(&s.public()).unwrap();
        let hello = ClientHello::new(42, c.public());
        let mut wire = hello.seal(&hs, &k, 1100);
        assert!(wire.len() >= 1100);
        let (got, mac) = ClientHello::open(&hs, &mut wire).unwrap();
        assert_eq!(got, hello);
        let ks = s.shared(&got.static_pub).unwrap();
        assert!(got.verify(&mac, &ks));
        assert!(got.fresh(now_unix()));
        assert!(!got.fresh(now_unix() + HELLO_SKEW + 5));

        // 다른 키(남의 WG 키를 모름)로 만든 MAC은 통과 못 함 = 세션 가로채기 불가.
        let (evil, _) = pair();
        let forged = ClientHello { static_pub: c.public(), ..ClientHello::new(42, evil.public()) };
        let mut w2 = forged.seal(&hs, &evil.shared(&s.public()).unwrap(), 0);
        let (g2, m2) = ClientHello::open(&hs, &mut w2).unwrap();
        assert!(!g2.verify(&m2, &s.shared(&g2.static_pub).unwrap()));

        // ACK: 진짜 서버의 것만 받아들인다.
        let ack = ServerAck { session: 42, random: [7; 16] };
        let mut aw = ack.seal(&hs, &ks, &hello.random, 0);
        assert!(ServerAck::open(&hs, &mut aw.clone(), &k, &hello).is_some());
        let other = ClientHello::new(42, c.public()); // 다른 HELLO(난수)에 대한 응답으로는 안 맞음
        assert!(ServerAck::open(&hs, &mut aw, &k, &other).is_none());

        // PSK가 다르면 아예 안 풀림.
        let mut w3 = hello.seal(&hs, &k, 0);
        assert!(ClientHello::open(&HandshakeKey::from_psk(b"other"), &mut w3).is_none());
    }

    #[test]
    fn session_seal_open_replay_tamper() {
        let (c, s) = pair();
        let k = c.shared(&s.public()).unwrap();
        let (cr, sr) = ([1u8; 16], [2u8; 16]);
        let ck = SessionKeys::derive(&k, &cr, &sr, true);
        let sk = SessionKeys::derive(&k, &cr, &sr, false);

        let mut wire = Vec::new();
        ck.seal(b"hello frame", &mut wire);
        let replay = wire.clone();
        assert_eq!(sk.open(&mut wire).unwrap(), b"hello frame");
        // 같은 패킷 다시 → 거절(리플레이).
        assert!(sk.open(&mut replay.clone()).is_none());
        // 한 비트라도 바꾸면 거절(위조).
        let mut w = Vec::new();
        ck.seal(b"x", &mut w);
        w[CTR_LEN] ^= 1;
        assert!(sk.open(&mut w).is_none());
        // 방향이 섞이면 거절(자기 패킷을 되돌려 보내는 반사).
        let mut own = Vec::new();
        ck.seal(b"y", &mut own);
        assert!(ck.open(&mut own).is_none());
        // 같은 평문도 카운터가 달라 선 위 바이트가 다르고, 앞 8바이트(가린 카운터)도 0,1,2처럼 안 보인다.
        let (mut a, mut b) = (Vec::new(), Vec::new());
        ck.seal(b"same", &mut a);
        ck.seal(b"same", &mut b);
        assert_ne!(a, b);
        assert_ne!(&a[..CTR_LEN], &3u64.to_le_bytes()[..CTR_LEN]); // a의 카운터는 3
    }

    // 큰 프레임은 앞부분만 봉인: 앞(헤더)을 건드리면 거절, 평문 뒤쪽은 선 위에 그대로(=이미 WG 암호문이라 괜찮음),
    // 작은 프레임은 통째로 봉인. 어느 쪽이든 왕복은 정확해야 한다.
    #[test]
    fn partial_seal_large_frames() {
        let (c, s) = pair();
        let k = c.shared(&s.public()).unwrap();
        let ck = SessionKeys::derive(&k, &[3; 16], &[4; 16], true);
        let sk = SessionKeys::derive(&k, &[3; 16], &[4; 16], false);
        let big: Vec<u8> = (0..1400u32).map(|i| (i * 7) as u8).collect();
        let mut w = Vec::new();
        ck.seal(&big, &mut w);
        assert_eq!(w.len(), SESSION_OVERHEAD + big.len());
        assert_eq!(&w[CTR_LEN + SEAL_HEAD..w.len() - TAG_LEN], &big[SEAL_HEAD..]); // 뒤쪽은 그대로
        assert_ne!(&w[CTR_LEN..CTR_LEN + SEAL_HEAD], &big[..SEAL_HEAD]); // 앞쪽은 가려짐
        assert_eq!(sk.open(&mut w.clone()).unwrap(), &big[..]);
        let mut t = w.clone();
        t[CTR_LEN + 3] ^= 1; // 헤더 변조 → 거절
        assert!(sk.open(&mut t).is_none());

        let small = vec![0u8; 300]; // 0으로 채운 패딩도 통째로 가려져야 한다
        let mut w2 = Vec::new();
        ck.seal(&small, &mut w2);
        assert!(w2[CTR_LEN..w2.len() - TAG_LEN].iter().any(|&b| b != 0));
        assert_eq!(sk.open(&mut w2).unwrap(), &small[..]);
    }

    #[test]
    fn counter_expands_from_40_bits() {
        let w = 1u64 << 40;
        assert_eq!(SessionKeys::expand_ctr(0, 0), 0);
        assert_eq!(SessionKeys::expand_ctr(10, 7), 7); // 조금 늦게 온 것
        assert_eq!(SessionKeys::expand_ctr(w + 5, 3), w + 3); // 40비트를 넘긴 뒤
        assert_eq!(SessionKeys::expand_ctr(w - 2, 1), w + 1); // 경계를 막 넘은 것
        assert_eq!(SessionKeys::expand_ctr(w + 1, w - 3), w - 3); // 경계 앞에서 늦게 온 것
    }

    #[test]
    fn replay_window_rules() {
        let mut w = ReplayWindow::default();
        assert!(w.accept(5));
        assert!(!w.accept(5));
        assert!(w.accept(3)); // 순서 뒤바뀜은 허용
        assert!(!w.accept(3));
        assert!(w.accept(3000));
        assert!(!w.accept(5)); // 창(2048) 밖으로 밀려남
        assert!(w.accept(3000 - 2047));
        assert!(!w.accept(3000 - 2048));
        assert!(w.accept(10_000_000)); // 크게 건너뛰어도 됨
        assert!(w.accept(10_000_000 - 1));
    }
}
