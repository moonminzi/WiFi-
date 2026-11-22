//! nagoing 손실 보정(FEC) — 인터리브 XOR 패리티.
//!
//! 왜 이렇게: 지하철·엘리베이터에서는 패킷이 **연속으로**(버스트) 빠진다. XOR 패리티 하나는 한 그룹에서
//! 한 조각만 되살릴 수 있으므로, 연속 패킷을 서로 다른 그룹에 번갈아 넣는다(인터리브). 그러면 G개 연속
//! 손실이 각 그룹에 하나씩만 떨어져 전부 복구된다. 비용은 데이터 k개마다 패리티 1개(= 1/k 추가 전송).
//!
//! - group = seq % groups   (연속 seq는 서로 다른 그룹으로 감)
//! - 한 그룹에 데이터 k개가 차면 그 그룹의 패리티(그때까지 조각들의 XOR)를 내보내고 세대(gen)를 올린다
//! - 복구: 패리티 + (k-1)개 데이터가 모이면 빠진 하나 = 패리티 XOR 나머지
//!
//! 재전송을 기다리지 않으므로(= WireGuard/TCP의 재전송보다 먼저 메움) 끊김이 줄어든다.
//! 데이터 조각은 받은 즉시 위로 넘기고(이 모듈은 건드리지 않음), 이 모듈은 **빠진 것만** 되살려 넘긴다.

use std::collections::HashMap;
use std::time::{Duration, Instant};

/// 조각 하나. Data는 입력 payload를 빌려 쓰고(복사 없음), Parity는 계산한 버퍼를 빌려 쓴다.
pub enum ShardRef<'a> {
    Data { seq: u32, group: u16, gen: u16, index: u8, k: u8, payload: &'a [u8] },
    Parity { group: u16, gen: u16, k: u8, payload: &'a [u8] },
}

struct GroupEnc {
    gen: u16,
    count: u8,
    acc: Vec<u8>,           // 조각들의 [len:u16 LE][bytes] XOR 누적
    first: Option<Instant>, // 이 세대 첫 조각을 넣은 시각(덜 찬 그룹 내보내기용)
}

pub struct FecEncoder {
    k: u8,
    groups: u16,
    seq: u32,
    state: Vec<GroupEnc>,
}

impl FecEncoder {
    /// k: 그룹당 데이터 조각 수(>=2), groups: 인터리브 깊이(>=1, 견딜 수 있는 연속 손실 길이).
    pub fn new(k: u8, groups: u16) -> Self {
        let k = k.max(2);
        let groups = groups.max(1);
        let state = (0..groups).map(|_| GroupEnc { gen: 0, count: 0, acc: Vec::new(), first: None }).collect();
        FecEncoder { k, groups, seq: 0, state }
    }

    /// 데이터그램 하나를 넣는다. 먼저 Data 조각을 emit하고, 그룹이 차면 Parity 조각도 emit한다.
    pub fn push<F: FnMut(ShardRef)>(&mut self, payload: &[u8], mut emit: F) {
        let seq = self.seq;
        self.seq = self.seq.wrapping_add(1);
        let g = (seq % self.groups as u32) as usize;
        let (gen, index, k) = {
            let st = &self.state[g];
            (st.gen, st.count, self.k)
        };
        emit(ShardRef::Data { seq, group: g as u16, gen, index, k, payload });

        // 패리티 누적: [len:u16][payload]를 XOR
        let st = &mut self.state[g];
        let need = 2 + payload.len();
        if st.acc.len() < need {
            st.acc.resize(need, 0);
        }
        let lb = (payload.len() as u16).to_le_bytes();
        st.acc[0] ^= lb[0];
        st.acc[1] ^= lb[1];
        xor_into(&mut st.acc[2..], payload);
        st.count += 1;
        st.first.get_or_insert_with(Instant::now);

        if st.count >= self.k {
            Self::close(st, g as u16, &mut emit);
        }
    }

    /// 그룹의 패리티를 내보내고(k = 지금까지 넣은 조각 수) 다음 세대로 넘어간다.
    fn close<F: FnMut(ShardRef)>(st: &mut GroupEnc, group: u16, emit: &mut F) {
        emit(ShardRef::Parity { group, gen: st.gen, k: st.count, payload: &st.acc });
        st.acc.clear();
        st.count = 0;
        st.first = None;
        st.gen = st.gen.wrapping_add(1);
    }

    /// 덜 찬 채로 max_age 넘게 기다린 그룹의 패리티를 지금 내보낸다(그 그룹은 그 개수로 닫힌다).
    /// 트래픽이 드물면(핸드셰이크·DNS·통화) 그룹이 k개로 차기까지 한참 걸려 복구가 너무 늦거나 아예 안 됐다.
    /// 대용량 전송은 그룹이 max_age 전에 차므로 추가 비용이 없다.
    pub fn flush_stale<F: FnMut(ShardRef)>(&mut self, max_age: Duration, mut emit: F) {
        for (g, st) in self.state.iter_mut().enumerate() {
            if st.first.is_some_and(|t| t.elapsed() >= max_age) {
                Self::close(st, g as u16, &mut emit);
            }
        }
    }

    /// 아직 패리티를 안 낸(덜 찬) 그룹이 있는가 — 있으면 호출자가 짧은 주기로 flush_stale을 불러야 한다.
    pub fn has_pending(&self) -> bool {
        self.state.iter().any(|st| st.count > 0)
    }
}

/// dst ^= src (dst가 src보다 길거나 같다). 8바이트씩 — 컴파일러가 SIMD로 펴서 바이트 루프보다 훨씬 빠르다.
fn xor_into(dst: &mut [u8], src: &[u8]) {
    let dst = &mut dst[..src.len()];
    let mut d8 = dst.chunks_exact_mut(8);
    let mut s8 = src.chunks_exact(8);
    for (d, s) in (&mut d8).zip(&mut s8) {
        let v = u64::from_ne_bytes([d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]])
            ^ u64::from_ne_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]);
        d.copy_from_slice(&v.to_ne_bytes());
    }
    for (d, s) in d8.into_remainder().iter_mut().zip(s8.remainder()) {
        *d ^= s;
    }
}

/// 한 그룹(세대)의 복구 상태. 받은 조각을 따로 저장하지 않고 **XOR 누적 하나**만 든다:
/// acc = 패리티 ⊕ 받은 데이터들 → 데이터가 k-1개 왔으면 acc가 곧 빠진 조각이다(패킷마다 할당·복사 없음).
struct GroupDec {
    k: u8,
    seen: [u64; 4], // 받은 데이터 index 비트(k ≤ 255)
    have_data: u8,
    have_parity: bool,
    acc: Vec<u8>, // [len:u16][payload] 표현들의 XOR(짧은 건 0으로 늘린 것)
    done: bool,
}

impl GroupDec {
    fn new(k: u8) -> Self {
        GroupDec { k, seen: [0; 4], have_data: 0, have_parity: false, acc: Vec::new(), done: false }
    }

    fn mix(&mut self, len_prefix: Option<u16>, bytes: &[u8]) {
        let off = if len_prefix.is_some() { 2 } else { 0 };
        let need = off + bytes.len();
        if self.acc.len() < need {
            self.acc.resize(need, 0);
        }
        if let Some(l) = len_prefix {
            let lb = l.to_le_bytes();
            self.acc[0] ^= lb[0];
            self.acc[1] ^= lb[1];
        }
        xor_into(&mut self.acc[off..], bytes);
    }
}

#[derive(Default)]
pub struct FecDecoder {
    groups: HashMap<u32, GroupDec>, // key = (group as u32) << 16 | gen
    latest_gen: HashMap<u16, u16>,
}

fn key_of(group: u16, gen: u16) -> u32 {
    ((group as u32) << 16) | gen as u32
}

/// 최신보다 이만큼 넘게 과거인 세대가 오면 순서 뒤바뀜이 아니라 상대 인코더 리셋으로 본다.
/// (64세대 = 그룹당 64·k 패킷 — 그만큼 뒤늦게 도착하는 재정렬은 현실에 없다.)
const RESET_GAP: u16 = 64;

/// a가 b보다 (wrapping 기준) 이만큼 이상 오래됐는가.
fn gen_distance(newer: u16, older: u16) -> u16 {
    newer.wrapping_sub(older)
}

impl FecDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    fn touch(&mut self, group: u16, gen: u16) {
        let latest = self.latest_gen.entry(group).or_insert(gen);
        if gen_distance(gen, *latest) < 0x8000 {
            if gen == *latest {
                return; // 같은 세대 — 정리할 것 없음(패킷마다 표를 훑지 않게)
            }
            *latest = gen;
        } else if gen_distance(*latest, gen) > RESET_GAP {
            // 지금보다 한참 '과거' 세대 = 상대 인코더가 새로 시작했다(서버 재시작·세션 재생성으로 gen이 0부터).
            // 옛 기준을 들고 있으면 새 세대가 전부 '오래된 것'으로 지워져 FEC가 영영 안 된다 → 이 그룹을 새로 시작.
            *latest = gen;
            self.groups.retain(|&kk, _| (kk >> 16) as u16 != group);
            return;
        } else {
            return; // 조금 늦게 온 옛 세대 — 그대로 둔다
        }
        // 세대가 넘어갈 때만: 같은 그룹에서 현재 세대보다 4 이상 오래된 것 버림(메모리 상한).
        let cur = gen;
        self.groups.retain(|&kk, _| {
            let g = (kk >> 16) as u16;
            let ge = (kk & 0xFFFF) as u16;
            g != group || gen_distance(cur, ge) < 4
        });
    }

    /// 데이터 조각 도착. (받은 조각 자체는 호출자가 이미 위로 넘겼다고 가정; 여기서는 복구용으로만 섞는다.)
    /// 복구되는 빠진 조각이 있으면 deliver로 넘긴다.
    pub fn on_data<F: FnMut(&[u8])>(&mut self, group: u16, gen: u16, index: u8, k: u8, payload: &[u8], deliver: F) {
        self.touch(group, gen);
        let entry = self.groups.entry(key_of(group, gen)).or_insert_with(|| GroupDec::new(k));
        if entry.done || index >= entry.k {
            return;
        }
        let (w, bit) = ((index / 64) as usize, 1u64 << (index % 64));
        if entry.seen[w] & bit != 0 {
            return; // 중복
        }
        entry.seen[w] |= bit;
        entry.have_data += 1;
        entry.mix(Some(payload.len() as u16), payload);
        Self::try_recover(entry, deliver);
    }

    /// 패리티 조각 도착. 복구 가능하면 deliver로 넘긴다.
    pub fn on_parity<F: FnMut(&[u8])>(&mut self, group: u16, gen: u16, k: u8, payload: &[u8], deliver: F) {
        self.touch(group, gen);
        let entry = self.groups.entry(key_of(group, gen)).or_insert_with(|| GroupDec::new(k));
        if entry.done || entry.have_parity {
            return;
        }
        // 덜 찬 채 닫힌 그룹(flush_stale)은 패리티의 k가 데이터 조각들의 k보다 작다 → 그 개수로 줄인다.
        if k >= 1 && k < entry.k {
            entry.k = k;
            let mut n = 0u32;
            for i in 0..k {
                if entry.seen[(i / 64) as usize] & (1u64 << (i % 64)) != 0 {
                    n += 1;
                }
            }
            entry.have_data = n as u8;
        }
        entry.have_parity = true;
        entry.mix(None, payload);
        Self::try_recover(entry, deliver);
    }

    /// 패리티 + (k-1)개 데이터가 섞였으면 누적이 곧 빠진 하나다.
    fn try_recover<F: FnMut(&[u8])>(entry: &mut GroupDec, mut deliver: F) {
        if entry.done || !entry.have_parity {
            return;
        }
        if entry.have_data >= entry.k {
            entry.done = true; // 다 왔다 — 복구할 것 없음
            return;
        }
        if entry.have_data + 1 != entry.k || entry.acc.len() < 2 {
            return; // 2개 이상 빠짐(복구 불가) — 더 오길 기다린다
        }
        let len = u16::from_le_bytes([entry.acc[0], entry.acc[1]]) as usize;
        if 2 + len <= entry.acc.len() {
            deliver(&entry.acc[2..2 + len]);
        }
        entry.done = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone)]
    enum Owned {
        Data { group: u16, gen: u16, index: u8, k: u8, payload: Vec<u8> },
        Parity { group: u16, gen: u16, k: u8, payload: Vec<u8> },
    }

    fn collect(enc: &mut FecEncoder, payloads: &[Vec<u8>]) -> Vec<Owned> {
        let mut out = Vec::new();
        for p in payloads {
            enc.push(p, |s| match s {
                ShardRef::Data { group, gen, index, k, payload, .. } =>
                    out.push(Owned::Data { group, gen, index, k, payload: payload.to_vec() }),
                ShardRef::Parity { group, gen, k, payload } =>
                    out.push(Owned::Parity { group, gen, k, payload: payload.to_vec() }),
            });
        }
        out
    }

    // 손실 집합(emission 순서상의 인덱스)만큼 버리고, 나머지를 디코더에 먹여 복구분을 모은다.
    fn run(shards: &[Owned], drop_positions: &[usize]) -> Vec<Vec<u8>> {
        let mut dec = FecDecoder::new();
        let mut recovered = Vec::new();
        for (i, s) in shards.iter().enumerate() {
            if drop_positions.contains(&i) {
                continue;
            }
            match s {
                Owned::Data { group, gen, index, k, payload } =>
                    dec.on_data(*group, *gen, *index, *k, payload, |r| recovered.push(r.to_vec())),
                Owned::Parity { group, gen, k, payload } =>
                    dec.on_parity(*group, *gen, *k, payload, |r| recovered.push(r.to_vec())),
            }
        }
        recovered
    }

    #[test]
    fn single_group_recovers_one_loss() {
        let mut enc = FecEncoder::new(4, 1);
        let payloads: Vec<Vec<u8>> = (0..4u8).map(|i| vec![i; 10 + i as usize]).collect();
        let shards = collect(&mut enc, &payloads);
        // shards = [D0,D1,D2,D3,Parity]. 두 번째 데이터(D1)를 버림.
        let rec = run(&shards, &[1]);
        assert_eq!(rec.len(), 1);
        assert_eq!(rec[0], payloads[1]);
    }

    #[test]
    fn interleave_recovers_burst() {
        // k=3, groups=4 → 최대 4연속 손실 복구.
        let mut enc = FecEncoder::new(3, 4);
        let payloads: Vec<Vec<u8>> = (0..12u8).map(|i| vec![i.wrapping_mul(7); 20 + (i as usize % 5)]).collect();
        let shards = collect(&mut enc, &payloads);
        // emission 순서에서 데이터 인덱스 2,3,4,5를 연속으로 버린다(= 4연속 버스트).
        // (데이터는 payload 순서대로 나오고, 패리티는 그룹이 찰 때 중간중간 섞인다.)
        let data_positions: Vec<usize> = shards.iter().enumerate()
            .filter(|(_, s)| matches!(s, Owned::Data { .. })).map(|(i, _)| i).collect();
        let burst: Vec<usize> = data_positions[2..6].to_vec();
        let rec = run(&shards, &burst);
        // 버린 4개가 모두 복구돼야 한다.
        let mut recset: Vec<Vec<u8>> = rec;
        recset.sort();
        let mut want: Vec<Vec<u8>> = burst.iter().map(|&pos| match &shards[pos] {
            Owned::Data { payload, .. } => payload.clone(),
            _ => unreachable!(),
        }).collect();
        want.sort();
        assert_eq!(recset, want);
    }

    #[test]
    fn two_losses_same_group_not_recovered() {
        let mut enc = FecEncoder::new(4, 1);
        let payloads: Vec<Vec<u8>> = (0..4u8).map(|i| vec![i; 8]).collect();
        let shards = collect(&mut enc, &payloads);
        // 같은 그룹의 데이터 두 개(0,1) 손실 → 복구 불가, 잘못된 데이터도 내놓지 않아야 함.
        let rec = run(&shards, &[0, 1]);
        assert!(rec.is_empty());
    }

    // 상대 인코더가 새로 시작해 gen이 0으로 돌아가도(서버 재시작) 디코더가 계속 복구해야 한다.
    #[test]
    fn recovers_after_encoder_restart() {
        let payloads: Vec<Vec<u8>> = (0..64u8).map(|i| vec![i; 30]).collect();
        let mut dec = FecDecoder::new();
        let mut enc = FecEncoder::new(4, 2);
        // 세대를 한참 올려 둔다(그룹당 100세대).
        for _ in 0..100 {
            for p in &payloads[..8] {
                enc.push(p, |s| match s {
                    ShardRef::Data { group, gen, index, k, payload, .. } =>
                        dec.on_data(group, gen, index, k, payload, |_| {}),
                    ShardRef::Parity { group, gen, k, payload } =>
                        dec.on_parity(group, gen, k, payload, |_| {}),
                });
            }
        }
        // 인코더 재시작 → gen 0부터. 첫 데이터 조각 하나를 잃는다.
        let shards = collect(&mut FecEncoder::new(4, 2), &payloads[..8]);
        let mut recovered = Vec::new();
        for (i, s) in shards.iter().enumerate() {
            if i == 0 {
                continue;
            }
            match s {
                Owned::Data { group, gen, index, k, payload } =>
                    dec.on_data(*group, *gen, *index, *k, payload, |r| recovered.push(r.to_vec())),
                Owned::Parity { group, gen, k, payload } =>
                    dec.on_parity(*group, *gen, *k, payload, |r| recovered.push(r.to_vec())),
            }
        }
        assert_eq!(recovered, vec![payloads[0].clone()]);
    }

    // 드문 트래픽: 그룹이 k개로 안 차도 flush_stale이 그 개수로 닫아 패리티를 내보내고, 빠진 조각을 되살린다.
    #[test]
    fn partial_group_flush_recovers() {
        let mut enc = FecEncoder::new(8, 4);
        // 3개만 보냄 → 그룹 0,1,2에 하나씩(덜 참). 아직 패리티 없음.
        let payloads: Vec<Vec<u8>> = (0..3u8).map(|i| vec![i + 1; 50 + i as usize]).collect();
        let mut shards = collect(&mut enc, &payloads);
        assert!(shards.iter().all(|s| matches!(s, Owned::Data { .. })));
        assert!(enc.has_pending());
        enc.flush_stale(Duration::ZERO, |s| {
            if let ShardRef::Parity { group, gen, k, payload } = s {
                shards.push(Owned::Parity { group, gen, k, payload: payload.to_vec() });
            }
        });
        assert!(!enc.has_pending());
        // 두 번째 데이터(그룹 1의 유일한 조각)를 잃어도 그룹 1의 패리티(k=1)로 되살린다.
        let rec = run(&shards, &[1]);
        assert_eq!(rec, vec![payloads[1].clone()]);

        // 그룹에 두 조각이 있다가 flush되는 경우(k=2): 하나를 잃어도 복구.
        let mut enc = FecEncoder::new(8, 1);
        let two = vec![vec![7u8; 40], vec![9u8; 60]];
        let mut shards = collect(&mut enc, &two);
        enc.flush_stale(Duration::ZERO, |s| {
            if let ShardRef::Parity { group, gen, k, payload } = s {
                assert_eq!(k, 2);
                shards.push(Owned::Parity { group, gen, k, payload: payload.to_vec() });
            }
        });
        assert_eq!(run(&shards, &[0]), vec![two[0].clone()]);
        // 다음 세대는 다시 k=8 그룹으로 정상 동작.
        let eight: Vec<Vec<u8>> = (0..8u8).map(|i| vec![i; 30]).collect();
        let shards = collect(&mut enc, &eight);
        assert_eq!(run(&shards, &[3]), vec![eight[3].clone()]);
    }

    // 막 넣은 그룹은 max_age 전에는 내보내지 않는다(대용량에서 추가 비용 없음).
    #[test]
    fn fresh_group_not_flushed() {
        let mut enc = FecEncoder::new(8, 2);
        enc.push(&[1, 2, 3], |_| {});
        let mut n = 0;
        enc.flush_stale(Duration::from_secs(60), |_| n += 1);
        assert_eq!(n, 0);
        assert!(enc.has_pending());
    }

    #[test]
    fn parity_loss_is_harmless() {
        let mut enc = FecEncoder::new(4, 1);
        let payloads: Vec<Vec<u8>> = (0..4u8).map(|i| vec![i; 8]).collect();
        let shards = collect(&mut enc, &payloads);
        // 패리티만 잃음 → 복구할 것도 없고(데이터는 다 왔음) 터지지 않아야 함.
        let parity_pos = shards.iter().position(|s| matches!(s, Owned::Parity { .. })).unwrap();
        let rec = run(&shards, &[parity_pos]);
        assert!(rec.is_empty());
    }
}
