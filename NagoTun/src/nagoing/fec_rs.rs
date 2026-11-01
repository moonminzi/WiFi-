//! nagoing 손실 보정 v2 — Reed-Solomon(소거 부호, GF(2^8) Cauchy) + 손실률에 맞춰 바뀌는 패리티 수.
//!
//! XOR 패리티(fec.rs)는 그룹마다 하나만 되살린다. 그래서 무작위 손실 2%에서도 두 개 빠진 그룹이 생겨 손실이
//! 0.1~0.2% 남고, 그 남은 손실이 터널 안 TCP를 크게 깎는다(먼 서버일수록: 처리량 ∝ 1/(RTT·√손실)).
//! 여기서는 데이터 k개마다 패리티 m개를 붙이고, **k+m개 중 아무 k개만 오면 전부 되살린다**.
//! m은 상대가 알려 주는 손실률(REPORT)로 정한다 — 남는 손실이 1e-4 아래가 되는 가장 작은 m.
//!
//! - 데이터 조각은 그대로 바로 위로 넘긴다(지연 없음). 빠진 것만 그룹이 k개 모이면 되살려 넘긴다.
//! - 그룹은 짧게(인터리브 2) — 되살린 패킷이 너무 늦으면 안쪽 TCP가 이미 손실로 보고 속도를 줄인다.
//!   여러 개 손실을 한 그룹에서 메우므로 XOR처럼 깊은 인터리브가 필요 없다.
//! - 조각 표현: [len:u16 LE][payload]를 그룹에서 가장 긴 것에 맞춰 0으로 늘린 것(패리티 길이 = 그것).

use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

// ── GF(2^8), 다항식 0x11d ───────────────────────────────────────────────────

struct Gf {
    exp: [u8; 512],
    log: [u8; 256],
    /// mul[a][b] — 바이트 루프에서 행 하나(256바이트)만 보며 곱한다
    mul: Box<[[u8; 256]; 256]>,
}

fn gf() -> &'static Gf {
    static GF: OnceLock<Gf> = OnceLock::new();
    GF.get_or_init(|| {
        let mut exp = [0u8; 512];
        let mut log = [0u8; 256];
        let mut x: u16 = 1;
        for i in 0..255 {
            exp[i] = x as u8;
            log[x as usize] = i as u8;
            x <<= 1;
            if x & 0x100 != 0 {
                x ^= 0x11d;
            }
        }
        for i in 255..512 {
            exp[i] = exp[i - 255];
        }
        let mut mul = Box::new([[0u8; 256]; 256]);
        for a in 1..256 {
            for b in 1..256 {
                mul[a][b] = exp[log[a] as usize + log[b] as usize];
            }
        }
        Gf { exp, log, mul }
    })
}

fn gf_inv(a: u8) -> u8 {
    let g = gf();
    g.exp[255 - g.log[a as usize] as usize]
}

/// 패리티 j(0..m), 데이터 i(0..k)의 계수: 1/(x_j ⊕ y_i), x_j = 128+j, y_i = i (겹치지 않음 → Cauchy, MDS)
fn coef(j: usize, i: usize) -> u8 {
    gf_inv(((128 + j) ^ i) as u8)
}

/// dst ^= c·src
fn mul_add(dst: &mut [u8], src: &[u8], c: u8) {
    if c == 0 {
        return;
    }
    if c == 1 {
        for (d, s) in dst.iter_mut().zip(src) {
            *d ^= s;
        }
        return;
    }
    let row = &gf().mul[c as usize];
    for (d, s) in dst.iter_mut().zip(src) {
        *d ^= row[*s as usize];
    }
}

/// 받은 조각(행 번호: 0..k 데이터, k.. 패리티) k개로 만든 k×k 행렬의 역행렬. 특이하면 None(Cauchy라 생기지 않음).
fn invert_rows(k: usize, rows: &[usize]) -> Option<Vec<Vec<u8>>> {
    let g = gf();
    let mut a: Vec<Vec<u8>> = rows
        .iter()
        .map(|&r| (0..k).map(|i| if r < k { (r == i) as u8 } else { coef(r - k, i) }).collect())
        .collect();
    let mut inv: Vec<Vec<u8>> = (0..k).map(|r| (0..k).map(|c| (r == c) as u8).collect()).collect();
    for col in 0..k {
        let piv = (col..k).find(|&r| a[r][col] != 0)?;
        a.swap(col, piv);
        inv.swap(col, piv);
        let p = gf_inv(a[col][col]);
        for c in 0..k {
            a[col][c] = g.mul[p as usize][a[col][c] as usize];
            inv[col][c] = g.mul[p as usize][inv[col][c] as usize];
        }
        for r in 0..k {
            if r != col && a[r][col] != 0 {
                let f = a[r][col];
                for c in 0..k {
                    let (x, y) = (a[col][c], inv[col][c]);
                    a[r][c] ^= g.mul[f as usize][x as usize];
                    inv[r][c] ^= g.mul[f as usize][y as usize];
                }
            }
        }
    }
    Some(inv)
}

// ── 부호기 ───────────────────────────────────────────────────────────────────

/// 조각 하나. Data는 입력을 빌려 쓰고, Parity는 계산한 버퍼를 빌려 쓴다.
pub enum RsShard<'a> {
    Data { group: u16, gen: u16, index: u8, k: u8, payload: &'a [u8] },
    Parity { group: u16, gen: u16, k: u8, m: u8, j: u8, payload: &'a [u8] },
}

struct GroupEnc {
    gen: u16,
    k: u8, // 이 그룹의 데이터 수 — 그룹을 시작할 때 정하고 끝까지 안 바꾼다(받는 쪽이 k로 묶음을 맞춘다)
    shards: Vec<Vec<u8>>, // [len][payload]
    first: Option<Instant>,
}

pub struct RsEncoder {
    k: u8,
    m: u8,
    groups: u16,
    seq: u32,
    state: Vec<GroupEnc>,
    parity: Vec<Vec<u8>>,
}

impl RsEncoder {
    pub fn new(k: u8, groups: u16, m: u8) -> Self {
        let k = k.clamp(2, 64);
        let groups = groups.max(1);
        let state = (0..groups).map(|_| GroupEnc { gen: 0, k, shards: Vec::with_capacity(k as usize), first: None }).collect();
        RsEncoder { k, m: m.clamp(1, k), groups, seq: 0, state, parity: Vec::new() }
    }

    pub fn k(&self) -> u8 {
        self.k
    }

    pub fn m(&self) -> u8 {
        self.m
    }

    /// 다음에 닫히는 그룹부터 패리티 수를 바꾼다.
    pub fn set_m(&mut self, m: u8) {
        self.m = m.clamp(1, self.k);
    }

    /// 묶음 모양(k, m)을 바꾼다. k는 다음에 시작하는 그룹부터, m은 다음에 닫히는 그룹부터.
    pub fn set_shape(&mut self, k: u8, m: u8) {
        self.k = k.clamp(2, 64);
        self.m = m.clamp(1, self.k);
    }

    pub fn push<F: FnMut(RsShard)>(&mut self, payload: &[u8], mut emit: F) {
        let g = (self.seq % self.groups as u32) as usize;
        self.seq = self.seq.wrapping_add(1);
        let st = &mut self.state[g];
        if st.shards.is_empty() {
            st.k = self.k;
        }
        let k = st.k;
        let index = st.shards.len() as u8;
        emit(RsShard::Data { group: g as u16, gen: st.gen, index, k, payload });
        let mut s = Vec::with_capacity(2 + payload.len());
        s.extend_from_slice(&(payload.len() as u16).to_le_bytes());
        s.extend_from_slice(payload);
        st.shards.push(s);
        st.first.get_or_insert_with(Instant::now);
        if st.shards.len() >= k as usize {
            Self::close(&mut self.state[g], g as u16, self.m, &mut self.parity, &mut emit);
        }
    }

    fn close<F: FnMut(RsShard)>(st: &mut GroupEnc, group: u16, m: u8, parity: &mut Vec<Vec<u8>>, emit: &mut F) {
        let n = st.shards.len();
        if n == 0 {
            return;
        }
        let len = st.shards.iter().map(Vec::len).max().unwrap_or(0);
        let m = m.min(n as u8).max(1) as usize;
        parity.resize_with(m, Vec::new);
        for (j, p) in parity.iter_mut().enumerate().take(m) {
            p.clear();
            p.resize(len, 0);
            for (i, d) in st.shards.iter().enumerate() {
                mul_add(&mut p[..d.len()], d, coef(j, i));
            }
        }
        for (j, p) in parity.iter().enumerate().take(m) {
            emit(RsShard::Parity { group, gen: st.gen, k: n as u8, m: m as u8, j: j as u8, payload: p });
        }
        st.shards.clear();
        st.first = None;
        st.gen = st.gen.wrapping_add(1);
    }

    /// 덜 찬 채로 max_age 넘게 기다린 그룹을 그 개수로 닫는다(드문 트래픽도 복구되게).
    pub fn flush_stale<F: FnMut(RsShard)>(&mut self, max_age: Duration, mut emit: F) {
        for g in 0..self.state.len() {
            if self.state[g].first.is_some_and(|t| t.elapsed() >= max_age) {
                Self::close(&mut self.state[g], g as u16, self.m, &mut self.parity, &mut emit);
            }
        }
    }

    pub fn has_pending(&self) -> bool {
        self.state.iter().any(|st| !st.shards.is_empty())
    }
}

// ── 복호기 ───────────────────────────────────────────────────────────────────

struct GroupDec {
    k: u8,          // 데이터 조각 수(패리티가 오면 그 k로 확정)
    m: u8,          // 0 = 아직 패리티를 못 봄
    shards: Vec<Option<Vec<u8>>>, // 0..k 데이터, k..k+m 패리티
    data_seen: u64, // 받은 데이터 index 비트(복구 전)
    received: u16,  // 받은 조각 수(데이터+패리티)
    done: bool,
}

/// 받는 쪽 손실 측정: 그룹이 정리될 때 (보낸 수, 받은 수)를 더한다.
#[derive(Default)]
pub struct LossMeter {
    sent: u64,
    lost: u64,
}

impl LossMeter {
    fn add(&mut self, sent: u64, received: u64) {
        self.sent += sent;
        self.lost += sent.saturating_sub(received);
    }

    /// 지금까지의 손실률(ppm)과 표본 수를 돌려주고 비운다. 표본이 너무 적으면 None.
    pub fn take(&mut self, min_samples: u64) -> Option<(u32, u64)> {
        if self.sent < min_samples {
            return None;
        }
        let ppm = (self.lost * 1_000_000 / self.sent.max(1)) as u32;
        let n = self.sent;
        *self = LossMeter::default();
        Some((ppm, n))
    }
}

#[derive(Default)]
pub struct RsDecoder {
    groups: HashMap<u32, GroupDec>,
    latest_gen: HashMap<u16, u16>,
    pub meter: LossMeter,
}

fn key_of(group: u16, gen: u16) -> u32 {
    ((group as u32) << 16) | gen as u32
}

const RESET_GAP: u16 = 64;
/// 그룹을 이만큼 세대 뒤까지 들고 있다(늦게 온 조각을 받으려고). 그보다 오래되면 정리하며 손실을 센다.
const KEEP_GENS: u16 = 3;

impl RsDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    fn retire(meter: &mut LossMeter, g: &GroupDec) {
        if g.m > 0 {
            meter.add(g.k as u64 + g.m as u64, g.received as u64);
        }
    }

    fn touch(&mut self, group: u16, gen: u16) {
        let latest = self.latest_gen.entry(group).or_insert(gen);
        let ahead = gen.wrapping_sub(*latest);
        if ahead == 0 {
            return;
        }
        if ahead >= 0x8000 {
            if latest.wrapping_sub(gen) > RESET_GAP {
                // 상대 부호기가 새로 시작했다(재시작) — 이 그룹을 새로 센다
                *latest = gen;
                self.groups.retain(|&kk, _| (kk >> 16) as u16 != group);
            }
            return;
        }
        *latest = gen;
        let meter = &mut self.meter;
        self.groups.retain(|&kk, g| {
            let keep = (kk >> 16) as u16 != group || gen.wrapping_sub((kk & 0xFFFF) as u16) <= KEEP_GENS;
            if !keep {
                Self::retire(meter, g);
            }
            keep
        });
    }

    fn entry(&mut self, group: u16, gen: u16, k: u8) -> &mut GroupDec {
        self.touch(group, gen);
        self.groups.entry(key_of(group, gen)).or_insert_with(|| GroupDec {
            k,
            m: 0,
            shards: vec![None; k as usize],
            data_seen: 0,
            received: 0,
            done: false,
        })
    }

    /// 데이터 조각(호출자가 이미 위로 넘김). 되살린 조각이 있으면 deliver로.
    pub fn on_data<F: FnMut(&[u8])>(&mut self, group: u16, gen: u16, index: u8, k: u8, payload: &[u8], deliver: F) {
        if k < 1 || k > 64 {
            return;
        }
        let e = self.entry(group, gen, k);
        if index >= e.k || e.data_seen & (1u64 << index) != 0 {
            return;
        }
        if e.done {
            e.data_seen |= 1u64 << index; // 늦게 온 조각도 손실 측정에는 센다
            e.received += 1;
            return;
        }
        e.data_seen |= 1u64 << index;
        e.received += 1;
        let mut s = Vec::with_capacity(2 + payload.len());
        s.extend_from_slice(&(payload.len() as u16).to_le_bytes());
        s.extend_from_slice(payload);
        e.shards[index as usize] = Some(s);
        Self::try_recover(e, deliver);
    }

    pub fn on_parity<F: FnMut(&[u8])>(&mut self, group: u16, gen: u16, k: u8, m: u8, j: u8, payload: &[u8], deliver: F) {
        if k < 1 || k > 64 || m < 1 || j >= m {
            return;
        }
        let e = self.entry(group, gen, k);
        if e.done {
            e.received += 1;
            return;
        }
        if e.m == 0 {
            // 덜 찬 채 닫힌 그룹이면 패리티의 k가 진짜 데이터 수다
            if k < e.k {
                e.shards.truncate(k as usize);
                e.data_seen &= (1u64 << k) - 1;
                e.received = e.data_seen.count_ones() as u16;
            }
            e.k = k.min(e.k);
            e.m = m;
            e.shards.resize(e.k as usize + m as usize, None);
        }
        let slot = e.k as usize + j as usize;
        if slot >= e.shards.len() || e.shards[slot].is_some() {
            return;
        }
        e.shards[slot] = Some(payload.to_vec());
        e.received += 1;
        Self::try_recover(e, deliver);
    }

    fn try_recover<F: FnMut(&[u8])>(e: &mut GroupDec, mut deliver: F) {
        let k = e.k as usize;
        if e.done || e.m == 0 {
            return;
        }
        let have_data = e.shards[..k].iter().filter(|s| s.is_some()).count();
        if have_data == k {
            e.done = true;
            e.shards.iter_mut().for_each(|s| *s = None);
            return;
        }
        if (e.received as usize) < k {
            return;
        }
        // 받은 조각 k개를 고른다(데이터 먼저)
        let rows: Vec<usize> = (0..e.shards.len()).filter(|&i| e.shards[i].is_some()).take(k).collect();
        if rows.len() < k {
            return;
        }
        let len = rows.iter().map(|&r| e.shards[r].as_ref().unwrap().len()).max().unwrap_or(0);
        let Some(inv) = invert_rows(k, &rows) else { return };
        let mut out = vec![0u8; len];
        for t in 0..k {
            if e.shards[t].is_some() {
                continue;
            }
            out.iter_mut().for_each(|b| *b = 0);
            for (c, &r) in rows.iter().enumerate() {
                let s = e.shards[r].as_ref().unwrap();
                mul_add(&mut out[..s.len()], s, inv[t][c]);
            }
            let plen = u16::from_le_bytes([out[0], out[1]]) as usize;
            if 2 + plen <= out.len() {
                deliver(&out[2..2 + plen]);
            }
        }
        e.done = true;
        e.shards.iter_mut().for_each(|s| *s = None);
    }
}

/// 남는 그룹 실패 확률이 target 아래가 되는 가장 작은 m(1..=k). p: 조각 손실률.
pub fn choose_m(k: u8, p: f64, target: f64) -> u8 {
    let p = p.clamp(0.0, 0.5);
    for m in 1..=k {
        let n = (k + m) as u32;
        // P(손실 > m) = 1 - Σ_{i=0..m} C(n,i) p^i (1-p)^(n-i)
        let mut cdf = 0.0;
        let mut c = 1.0; // C(n,i)
        for i in 0..=m as u32 {
            cdf += c * p.powi(i as i32) * (1.0 - p).powi((n - i) as i32);
            c = c * (n - i) as f64 / (i + 1) as f64;
        }
        if 1.0 - cdf < target {
            return m;
        }
    }
    k
}

#[cfg(test)]
mod tests {
    use super::*;

    enum Owned {
        Data { group: u16, gen: u16, index: u8, k: u8, payload: Vec<u8> },
        Parity { group: u16, gen: u16, k: u8, m: u8, j: u8, payload: Vec<u8> },
    }

    fn encode(enc: &mut RsEncoder, payloads: &[Vec<u8>]) -> Vec<Owned> {
        let mut out = Vec::new();
        for p in payloads {
            enc.push(p, |s| out.push(own(s)));
        }
        out
    }

    fn own(s: RsShard) -> Owned {
        match s {
            RsShard::Data { group, gen, index, k, payload } => Owned::Data { group, gen, index, k, payload: payload.to_vec() },
            RsShard::Parity { group, gen, k, m, j, payload } => Owned::Parity { group, gen, k, m, j, payload: payload.to_vec() },
        }
    }

    fn run(dec: &mut RsDecoder, shards: &[Owned], drop: &[usize]) -> Vec<Vec<u8>> {
        let mut rec = Vec::new();
        for (i, s) in shards.iter().enumerate() {
            if drop.contains(&i) {
                continue;
            }
            match s {
                Owned::Data { group, gen, index, k, payload } => dec.on_data(*group, *gen, *index, *k, payload, |r| rec.push(r.to_vec())),
                Owned::Parity { group, gen, k, m, j, payload } => dec.on_parity(*group, *gen, *k, *m, *j, payload, |r| rec.push(r.to_vec())),
            }
        }
        rec
    }

    fn payloads(n: usize, seed: u8) -> Vec<Vec<u8>> {
        (0..n).map(|i| (0..(40 + (i * 37) % 1300)).map(|b| (b as u8).wrapping_mul(31).wrapping_add(i as u8 ^ seed)).collect()).collect()
    }

    #[test]
    fn recovers_any_m_losses() {
        // k=8, m=3: 그룹(8+3) 중 아무 3개를 잃어도 데이터는 전부 돌아온다
        let data = payloads(8, 1);
        for drop in [vec![0, 1, 2], vec![3, 7, 9], vec![5, 8, 10], vec![0, 4, 7]] {
            let mut enc = RsEncoder::new(8, 1, 3);
            let shards = encode(&mut enc, &data);
            assert_eq!(shards.len(), 11);
            let mut dec = RsDecoder::new();
            let mut rec = run(&mut dec, &shards, &drop);
            let mut want: Vec<Vec<u8>> = drop.iter().filter(|&&i| i < 8).map(|&i| data[i].clone()).collect();
            rec.sort();
            want.sort();
            assert_eq!(rec, want, "drop {drop:?}");
        }
    }

    #[test]
    fn too_many_losses_give_nothing_wrong() {
        let data = payloads(8, 2);
        let mut enc = RsEncoder::new(8, 1, 2);
        let shards = encode(&mut enc, &data);
        let mut dec = RsDecoder::new();
        assert!(run(&mut dec, &shards, &[0, 1, 2]).is_empty());
    }

    #[test]
    fn interleaved_and_partial_groups() {
        let data = payloads(20, 3);
        let mut enc = RsEncoder::new(8, 2, 2);
        let mut shards = encode(&mut enc, &data); // 그룹 0·1 각각 8개 차서 닫힘, 남은 4개는 덜 참
        enc.flush_stale(Duration::ZERO, |s| shards.push(own(s)));
        assert!(!enc.has_pending());
        // 데이터 조각 위치를 찾아 연속 4개 버림(인터리브 2 → 그룹마다 2개씩)
        let pos: Vec<usize> = shards.iter().enumerate().filter(|(_, s)| matches!(s, Owned::Data { .. })).map(|(i, _)| i).collect();
        let drop: Vec<usize> = pos[3..7].to_vec();
        let mut dec = RsDecoder::new();
        let mut rec = run(&mut dec, &shards, &drop);
        rec.sort();
        let mut want: Vec<Vec<u8>> = (3..7).map(|i| data[i].clone()).collect();
        want.sort();
        assert_eq!(rec, want);
        // 덜 찬 그룹(마지막 4개 = 그룹당 2개)에서도 복구
        let last: Vec<usize> = pos[16..20].to_vec();
        let mut dec = RsDecoder::new();
        let mut rec = run(&mut dec, &shards, &last[..2]);
        rec.sort();
        let mut want = vec![data[16].clone(), data[17].clone()];
        want.sort();
        assert_eq!(rec, want);
    }

    #[test]
    fn random_loss_stress() {
        // 결정적 의사난수로 5% 손실, m=3: 거의 다 복구되고, 되살린 건 전부 원본과 같아야 한다
        let mut x: u64 = 0x1234_5678;
        let mut rnd = || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        };
        let data = payloads(4000, 7);
        let mut enc = RsEncoder::new(8, 2, 3);
        let mut shards = encode(&mut enc, &data);
        enc.flush_stale(Duration::ZERO, |s| shards.push(own(s)));
        let drop: Vec<usize> = (0..shards.len()).filter(|_| rnd() % 100 < 5).collect();
        let lost_data: Vec<Vec<u8>> = drop.iter().filter_map(|&i| match &shards[i] {
            Owned::Data { payload, .. } => Some(payload.clone()),
            _ => None,
        }).collect();
        let mut dec = RsDecoder::new();
        let rec = run(&mut dec, &shards, &drop);
        for r in &rec {
            assert!(lost_data.contains(r));
        }
        let residual = (lost_data.len() - rec.len()) as f64 / data.len() as f64;
        assert!(residual < 0.002, "residual {residual}");
        assert!(rec.len() as f64 > lost_data.len() as f64 * 0.95);
    }

    #[test]
    fn shape_change_mid_stream_decodes() {
        // 그룹 도중에 k를 16→48→8로 바꿔도 각 그룹은 시작할 때의 k로 끝나고, 손실은 제대로 되살아난다
        let data = payloads(200, 11);
        let mut enc = RsEncoder::new(16, 1, 2);
        let mut shards = Vec::new();
        for (i, p) in data.iter().enumerate() {
            if i == 10 {
                enc.set_shape(48, 1);
            }
            if i == 90 {
                enc.set_shape(8, 3);
            }
            enc.push(p, |s| shards.push(own(s)));
        }
        enc.flush_stale(Duration::ZERO, |s| shards.push(own(s)));
        let pos: Vec<usize> = shards.iter().enumerate().filter(|(_, s)| matches!(s, Owned::Data { .. })).map(|(i, _)| i).collect();
        // 그룹마다 하나씩 잃게: 데이터 3, 20, 70, 100, 150, 199
        let drop: Vec<usize> = [3, 20, 70, 100, 150, 199].iter().map(|&i| pos[i]).collect();
        let mut dec = RsDecoder::new();
        let mut rec = run(&mut dec, &shards, &drop);
        rec.sort();
        let mut want: Vec<Vec<u8>> = [3, 20, 70, 100, 150, 199].iter().map(|&i| data[i].clone()).collect();
        want.sort();
        assert_eq!(rec, want);
    }

    #[test]
    fn meter_counts_losses() {
        let data = payloads(80, 9);
        let mut enc = RsEncoder::new(8, 1, 2);
        let shards = encode(&mut enc, &data); // 10그룹 × 10조각
        let mut dec = RsDecoder::new();
        run(&mut dec, &shards, &[0, 15, 33]);
        // 다음 세대들이 와야 정리되며 세어진다 — 한 번 더 보내 밀어낸다
        let more = payloads(80, 10);
        let shards2 = encode(&mut enc, &more);
        run(&mut dec, &shards2, &[]);
        let (ppm, n) = dec.meter.take(50).unwrap();
        assert!(n >= 60, "n {n}");
        assert!(ppm > 0 && ppm < 100_000, "ppm {ppm}");
    }

    #[test]
    fn choose_m_grows_with_loss() {
        assert_eq!(choose_m(8, 0.0, 1e-4), 1);
        let a = choose_m(8, 0.01, 1e-4);
        let b = choose_m(8, 0.05, 1e-4);
        let c = choose_m(8, 0.15, 1e-4);
        assert!(a >= 2 && a < b && b < c, "{a} {b} {c}");
        assert!(c <= 8);
    }
}
