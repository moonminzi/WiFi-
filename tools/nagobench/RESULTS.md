# nagoing lossy-link bench — 2026-11-01

EC2 c7i.xlarge, two network namespaces, netem both directions (delay, loss, 200 Mbit cap).
iperf3 download (`-R`, 15 s, first 3 s omitted). Sender congestion control: CUBIC (most websites,
phone uploads) or BBR (our server's TCP accel proxy). Mbps; retransmits in brackets.

- **wg** = kernel WireGuard (what most commercial VPNs run)
- **xor** = nagoing as shipped today (XOR parity, k=8, interleave 8)
- **rs** = nagoing Reed-Solomon, parity adapts to measured loss

| RTT | loss | sender | wg | xor | rs |
|---|---|---|---|---|---|
| 40 | 0 | cubic | **183.1** | 157.3 | 173.4 |
| 40 | 0 | bbr | **180.1** | 154.6 | 170.4 |
| 40 | 1% | cubic | 2.8 (40) | 12.9 (37) | **132.2 (0)** |
| 40 | 1% | bbr | **180.1** (2458) | 156.0 | 132.9 (0) |
| 40 | 3% | cubic | 1.4 (60) | 2.5 (81) | **120.6 (0)** |
| 40 | 3% | bbr | **178.3** (7571) | 158.3 | 119.0 (1) |
| 150 | 0 | cubic | **183.1** | 157.3 | 166.5 |
| 150 | 0 | bbr | **177.2** | 152.2 | 167.5 |
| 150 | 0.5% | cubic | 1.7 (10) | 16.3 (12) | **48.7 (0)** |
| 150 | 0.5% | bbr | 42.2 (268) | **153.8** | 137.4 (0) |
| 150 | 1% | cubic | 1.3 (13) | 6.4 (20) | **131.0 (0)** |
| 150 | 1% | bbr | **178.9** (2427) | 157.1 | 130.2 (0) |
| 150 | 2% | cubic | 0.6 (15) | 5.6 (40) | **125.4 (0)** |
| 150 | 2% | bbr | **177.5** (5065) | 161.0 | 121.3 (0) |
| 150 | 5% | cubic | 0.3 (22) | 1.0 (26) | **109.9 (0)** |
| 150 | 5% | bbr | **159.7** (12441) | 146.0 | 107.2 (0) |
| 150 | bursty (GE ~1.4%) | cubic | 2.4 (10) | 36.2 (7) | **139.7 (0)** |
| 150 | bursty (GE ~1.4%) | bbr | **178.2** (1007) | 152.8 | 137.0 (10) |

Notes
- rs hides loss completely from the inner TCP (0 retransmits) — CUBIC goes from ~1 Mbps to 110–140 Mbps.
- With a BBR sender plain WG keeps its throughput under random loss (BBR ignores it) but retransmits a lot;
  rs pays its parity overhead there (up to ~37% at 3–5% loss).
- 150 ms / 0.5% cubic (48.7): the run started right after the 0% run (clean shape k=48, m=1); losses before
  the first REPORT cut CUBIC's window and it regrows slowly at 150 ms. Tuning item: react faster / keep m=2 when clean.
- Found and fixed during the bench: ClientHandle::stats() self-deadlock (froze the upload path).
