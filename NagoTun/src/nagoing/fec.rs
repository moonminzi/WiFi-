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
        for (i, &b) in payload.iter().enumerate() {
            st.acc[2 + i] ^= b;
        }
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

struct GroupDec {
    k: u8,
    data: Vec<Option<Vec<u8>>>, // index -> [len:u16][payload] 형태로 저장
    have_data: u8,
    parity: Option<Vec<u8>>,
    done: bool,
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
            *latest = gen;
        } else if gen_distance(*latest, gen) > RESET_GAP {
            // 지금보다 한참 '과거' 세대 = 상대 인코더가 새로 시작했다(서버 재시작·세션 재생성으로 gen이 0부터).
            // 옛 기준을 들고 있으면 새 세대가 전부 '오래된 것'으로 지워져 FEC가 영영 안 된다 → 이 그룹을 새로 시작.
            *latest = gen;
            self.groups.retain(|&kk, _| (kk >> 16) as u16 != group);
        }
        // 오래된 세대 정리: 같은 그룹에서 현재 세대보다 4 이상 오래된 것 버림(메모리 상한).
        let cur = *self.latest_gen.get(&group).unwrap();
        self.groups.retain(|&kk, _| {
            let g = (kk >> 16) as u16;
            let ge = (kk & 0xFFFF) as u16;
            g != group || gen_distance(cur, ge) < 4
        });
    }

    /// 데이터 조각 도착. (받은 조각 자체는 호출자가 이미 위로 넘겼다고 가정; 여기서는 복구용으로만 모은다.)
    /// 복구되는 빠진 조각이 있으면 deliver로 넘긴다.
    pub fn on_data<F: FnMut(&[u8])>(&mut self, group: u16, gen: u16, index: u8, k: u8, payload: &[u8], deliver: F) {
        self.touch(group, gen);
        let entry = self.groups.entry(key_of(group, gen)).or_insert_with(|| GroupDec {
            k,
            data: (0..k).map(|_| None).collect(),
            have_data: 0,
            parity: None,
            done: false,
        });
        if entry.done || index as usize >= entry.data.len() {
            return;
        }
        if entry.data[index as usize].is_none() {
            // [len:u16][payload]로 저장(복구 계산과 같은 표현)
            let mut buf = Vec::with_capacity(2 + payload.len());
            buf.extend_from_slice(&(payload.len() as u16).to_le_bytes());
            buf.extend_from_slice(payload);
            entry.data[index as usize] = Some(buf);
            entry.have_data += 1;
        }
        Self::try_recover(entry, deliver);
    }

    /// 패리티 조각 도착. 복구 가능하면 deliver로 넘긴다.
    pub fn on_parity<F: FnMut(&[u8])>(&mut self, group: u16, gen: u16, k: u8, payload: &[u8], deliver: F) {
        self.touch(group, gen);
        let entry = self.groups.entry(key_of(group, gen)).or_insert_with(|| GroupDec {
            k,
            data: (0..k).map(|_| None).collect(),
            have_data: 0,
            parity: None,
            done: false,
        });
        if entry.done {
            return;
        }
        // 덜 찬 채 닫힌 그룹(flush_stale)은 패리티의 k가 데이터 조각들의 k보다 작다 → 그 개수로 줄인다.
        if k >= 1 && k < entry.k {
            entry.k = k;
            entry.data.truncate(k as usize);
            entry.have_data = entry.data.iter().filter(|d| d.is_some()).count() as u8;
        }
        if entry.parity.is_none() {
            entry.parity = Some(payload.to_vec());
        }
        Self::try_recover(entry, deliver);
    }

    /// 패리티 + (k-1)개 데이터가 있으면 빠진 하나를 복구한다.
    fn try_recover<F: FnMut(&[u8])>(entry: &mut GroupDec, mut deliver: F) {
        if entry.done {
            return;
        }
        let parity = match &entry.parity {
            Some(p) => p,
            None => return,
        };
        if entry.have_data + 1 != entry.k {
            return; // 빠진 게 0개(복구 불필요)거나 2개 이상(복구 불가)
        }
        // 빠진 index 찾기
        let missing = match entry.data.iter().position(|d| d.is_none()) {
            Some(i) => i,
            None => return,
        };
        // recovered = parity XOR (나머지 데이터들), 모두 [len:u16][payload] 표현, 0으로 확장
        let mut rec = parity.clone();
        for d in entry.data.iter().flatten() {
            if rec.len() < d.len() {
                rec.resize(d.len(), 0);
            }
            for (i, &b) in d.iter().enumerate() {
                rec[i] ^= b;
            }
        }
        // 앞 2바이트 = 원래 길이
        if rec.len() < 2 {
            entry.done = true;
            return;
        }
        let len = u16::from_le_bytes([rec[0], rec[1]]) as usize;
        if 2 + len <= rec.len() {
            deliver(&rec[2..2 + len]);
        }
        // 복구한 조각을 채워 넣고 완료 표시
        entry.data[missing] = Some(rec);
        entry.have_data += 1;
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
