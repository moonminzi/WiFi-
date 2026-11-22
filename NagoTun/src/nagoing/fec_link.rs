//! 보내는 쪽(FecTx)·받는 쪽(FecRx) FEC 묶음: 예전 XOR(fec.rs)과 Reed-Solomon(fec_rs.rs)을 함께 다룬다.
//!
//! - 받는 쪽은 둘 다 늘 알아듣는다.
//! - 보내는 쪽은 XOR로 시작하고, 상대가 REPORT(= RS 할 줄 앎 + 잰 손실률)를 한 번이라도 보내면 RS로 바꾼다.
//!   예전 앱·서버는 REPORT를 안 보내고, 받은 REPORT·RS 프레임은 모르는 태그라 버린다 → 서로 섞여도 깨지지 않는다.
//! - RS 패리티 수 m은 상대가 잰 손실률로 정한다(남는 그룹 실패 확률 RS_TARGET 아래).

use std::time::{Duration, Instant};

use super::fec::{FecDecoder, FecEncoder, ShardRef};
use super::fec_rs::{choose_m, RsDecoder, RsEncoder, RsShard};
use super::frame::Frame;
use super::proxy::FecParams;

/// 덜 찬 그룹을 닫는 시간. RS는 짧게 — 되살린 패킷이 늦으면 안쪽 TCP가 이미 손실로 본다.
const XOR_MAX_AGE: Duration = Duration::from_millis(200);
const RS_MAX_AGE: Duration = Duration::from_millis(25);
/// 손실 보고 주기·최소 표본
const REPORT_EVERY: Duration = Duration::from_millis(250);
const REPORT_MIN_SAMPLES: u64 = 64;
/// 그룹 실패 확률 목표. CUBIC 같은 손실 기반 TCP는 남는 손실 0.01%에도 크게 느려져서 낮게 잡는다.
const RS_TARGET: f64 = 1e-6;
/// 깨끗한 회선에서 쓰는 큰 묶음
const CLEAN_K: u8 = 48;

fn xor_frame(s: ShardRef) -> Frame {
    match s {
        ShardRef::Data { group, gen, index, k, payload, .. } => Frame::Data { group, gen, index, k, payload },
        ShardRef::Parity { group, gen, k, payload } => Frame::Parity { group, gen, k, payload },
    }
}

fn rs_frame(s: RsShard) -> Frame {
    match s {
        RsShard::Data { group, gen, index, k, payload } => Frame::RsData { group, gen, index, k, payload },
        RsShard::Parity { group, gen, k, m, j, payload } => Frame::RsParity { group, gen, k, m, j, payload },
    }
}

pub struct FecTx {
    params: FecParams,
    xor: FecEncoder,
    rs: Option<RsEncoder>,
    /// 상대가 알려 준 손실률(부드럽게)
    loss: f64,
}

impl FecTx {
    pub fn new(params: FecParams) -> Self {
        FecTx { params, xor: FecEncoder::new(params.k, params.groups), rs: None, loss: 0.0 }
    }

    pub fn rs_active(&self) -> bool {
        self.rs.is_some()
    }

    /// 지금 RS 패리티 수(0 = XOR 중)
    pub fn rs_m(&self) -> u8 {
        self.rs.as_ref().map_or(0, RsEncoder::m)
    }

    /// 지금 RS 묶음의 데이터 수(0 = XOR 중)
    pub fn rs_k(&self) -> u8 {
        self.rs.as_ref().map_or(0, RsEncoder::k)
    }

    pub fn loss_ppm(&self) -> u32 {
        (self.loss * 1e6) as u32
    }

    pub fn push<F: FnMut(&Frame)>(&mut self, payload: &[u8], mut emit: F) {
        if !self.params.enabled {
            emit(&Frame::Data { group: 0, gen: 0, index: 0, k: 0, payload });
        } else if let Some(rs) = self.rs.as_mut() {
            rs.push(payload, |s| emit(&rs_frame(s)));
        } else {
            self.xor.push(payload, |s| emit(&xor_frame(s)));
        }
    }

    pub fn flush_stale<F: FnMut(&Frame)>(&mut self, mut emit: F) {
        if !self.params.enabled {
            return;
        }
        if let Some(rs) = self.rs.as_mut() {
            rs.flush_stale(RS_MAX_AGE, |s| emit(&rs_frame(s)));
        } else {
            self.xor.flush_stale(XOR_MAX_AGE, |s| emit(&xor_frame(s)));
        }
    }

    pub fn has_pending(&self) -> bool {
        self.params.enabled && self.rs.as_ref().map_or_else(|| self.xor.has_pending(), RsEncoder::has_pending)
    }

    /// 덜 찬 그룹이 있을 때 다시 확인할 주기
    pub fn tick(&self) -> Duration {
        if self.rs.is_some() { Duration::from_millis(8) } else { Duration::from_millis(20) }
    }

    /// 상대의 REPORT. 처음 받으면 RS로 바꾼다(남은 XOR 그룹은 그대로 버린다 — 순간 하나뿐).
    pub fn on_report(&mut self, loss_ppm: u32, samples: u32) {
        if !self.params.enabled || !self.params.rs {
            return;
        }
        let rs = self.rs.get_or_insert_with(|| RsEncoder::new(self.params.rs_k, self.params.rs_groups, 2));
        if samples > 0 {
            let p = (loss_ppm as f64 / 1e6).min(0.5);
            // 오를 때는 바로, 내릴 때는 천천히(손실은 몰려 온다)
            self.loss = if p > self.loss { p } else { self.loss * 0.7 + p * 0.3 };
            // 잰 값보다 조금 높게 잡는다(표본 오차·버스트)
            let p = (self.loss * 1.5).max(0.00002);
            // 깨끗한 회선: 48개당 패리티 1개(≈2%)로 충분하면 그렇게 — WireGuard 단독과 거의 같은 대역폭.
            // 손실이 보이면 짧은 묶음(rs_k)으로 돌아가 필요한 만큼 패리티를 붙인다(되살린 패킷이 빨리 도착).
            if choose_m(CLEAN_K, p, RS_TARGET) == 1 {
                rs.set_shape(CLEAN_K, 1);
            } else {
                let k = self.params.rs_k;
                rs.set_shape(k, choose_m(k, p, RS_TARGET));
            }
        }
    }
}

#[derive(Default)]
pub struct FecRx {
    xor: FecDecoder,
    rs: RsDecoder,
    last_report: Option<Instant>,
    /// 마지막으로 잰 손실률(표본이 모자란 주기엔 이걸 다시 보낸다)
    last_ppm: u32,
}

impl FecRx {
    pub fn new() -> Self {
        Self::default()
    }

    /// 데이터 프레임 처리: 받은 데이터는 deliver(payload, false), FEC로 되살린 건 deliver(rec, true).
    /// 데이터 프레임이 아니면 false.
    pub fn inbound<F: FnMut(&[u8], bool)>(&mut self, frame: &Frame, mut deliver: F) -> bool {
        match *frame {
            Frame::Data { group, gen, index, k, payload } => {
                deliver(payload, false);
                if k >= 2 {
                    self.xor.on_data(group, gen, index, k, payload, |r| deliver(r, true));
                }
            }
            Frame::Parity { group, gen, k, payload } => {
                self.xor.on_parity(group, gen, k, payload, |r| deliver(r, true));
            }
            Frame::RsData { group, gen, index, k, payload } => {
                deliver(payload, false);
                self.rs.on_data(group, gen, index, k, payload, |r| deliver(r, true));
            }
            Frame::RsParity { group, gen, k, m, j, payload } => {
                self.rs.on_parity(group, gen, k, m, j, payload, |r| deliver(r, true));
            }
            _ => return false,
        }
        true
    }

    /// 보고할 때가 됐으면 REPORT 프레임을 돌려준다(처음엔 바로 — RS 할 줄 안다고 알리게).
    pub fn report_due(&mut self) -> Option<Frame<'static>> {
        if self.last_report.is_some_and(|t| t.elapsed() < REPORT_EVERY) {
            return None;
        }
        self.last_report = Some(Instant::now());
        let (ppm, n) = match self.rs.meter.take(REPORT_MIN_SAMPLES) {
            Some((ppm, n)) => {
                self.last_ppm = ppm;
                (ppm, n.min(u32::MAX as u64) as u32)
            }
            None => (self.last_ppm, 0),
        };
        Some(Frame::Report { loss_ppm: ppm, samples: n })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params() -> FecParams {
        FecParams::default()
    }

    /// 두 끝을 메모리로 잇는다: a→b 데이터 + b→a REPORT. RS로 바뀌고 손실에 맞춰 m이 커지는지.
    #[test]
    fn switches_to_rs_and_adapts() {
        let mut tx = FecTx::new(params());
        let mut rx = FecRx::new();
        let mut x: u64 = 99;
        let mut rnd = move || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        };
        let (mut sent, mut got) = (0usize, 0usize);
        for round in 0..40 {
            for i in 0..400u32 {
                let payload = vec![(i % 251) as u8; 200 + (i as usize * 13) % 1100];
                sent += 1;
                let mut frames: Vec<Vec<u8>> = Vec::new();
                tx.push(&payload, |f| {
                    let mut b = Vec::new();
                    super::super::frame::encode(f, &mut b);
                    frames.push(b);
                });
                for b in frames {
                    if rnd() % 1000 < 30 {
                        continue; // 3% 손실
                    }
                    let f = super::super::frame::decode(&b).unwrap();
                    rx.inbound(&f, |_, _| got += 1);
                }
            }
            if let Some(Frame::Report { loss_ppm, samples }) = rx.report_due() {
                tx.on_report(loss_ppm, samples);
            }
            rx.last_report = None; // 시험에선 매 라운드 보고
            if round == 0 {
                assert!(tx.rs_active(), "first report switches to RS");
            }
        }
        assert!(tx.rs_m() >= 3, "m {}", tx.rs_m());
        let residual = 1.0 - got as f64 / sent as f64;
        assert!(residual < 0.01, "residual {residual}"); // 첫 라운드(XOR) 손실 포함
    }

    #[test]
    fn clean_link_uses_big_groups() {
        let mut tx = FecTx::new(params());
        tx.on_report(0, 1000);
        assert_eq!((tx.rs_k(), tx.rs_m()), (CLEAN_K, 1));
        tx.on_report(20_000, 1000); // 2%
        assert_eq!(tx.rs_k(), 16);
        assert!(tx.rs_m() >= 3);
        // 손실이 사라지면 천천히 다시 큰 묶음으로
        for _ in 0..60 {
            tx.on_report(0, 1000);
        }
        assert_eq!((tx.rs_k(), tx.rs_m()), (CLEAN_K, 1));
    }

    #[test]
    fn old_peer_stays_xor() {
        let mut tx = FecTx::new(params());
        let mut n = 0;
        tx.push(&[1, 2, 3], |f| {
            assert!(matches!(f, Frame::Data { .. }));
            n += 1;
        });
        assert_eq!(n, 1);
        assert!(!tx.rs_active());
    }
}
