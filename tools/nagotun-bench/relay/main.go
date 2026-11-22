// 벤치용 UDP 중계: 클라이언트 ↔ 서버 사이에서 한쪽마다 지연을 넣고(-delay), 원하면 대역폭(-rate)과
// 병목 대기열 크기(-queue)를 흉내 낸다. 한국 → AWS 리전 같은 왕복 시간에서 엔진이 어떻게 버티는지 보는 데 쓴다.
// WireGuard는 UDP라 이 중계만 지나면 된다(커널 netem 없이).
package main

import (
	"flag"
	"log"
	"net"
	"sync/atomic"
	"time"
)

type pkt struct {
	due  time.Time
	data []byte
}

func main() {
	listen := flag.String("listen", "10.201.0.1:51820", "client side address")
	upstream := flag.String("upstream", "10.202.0.2:51820", "server address")
	delay := flag.Duration("delay", 0, "one-way delay each direction (RTT = 2x)")
	rate := flag.Float64("rate", 0, "bottleneck rate in Mbit/s each direction (0 = none)")
	queue := flag.Int("queue", 0, "bottleneck queue in KB (drop-tail, 0 = BDP-ish 2x)")
	flag.Parse()

	laddr, err := net.ResolveUDPAddr("udp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	front, err := net.ListenUDP("udp", laddr)
	if err != nil {
		log.Fatal(err)
	}
	uaddr, err := net.ResolveUDPAddr("udp", *upstream)
	if err != nil {
		log.Fatal(err)
	}
	back, err := net.DialUDP("udp", nil, uaddr)
	if err != nil {
		log.Fatal(err)
	}
	for _, c := range []*net.UDPConn{front, back} {
		c.SetReadBuffer(16 << 20)
		c.SetWriteBuffer(16 << 20)
	}
	limit := *queue * 1024
	if limit == 0 && *rate > 0 {
		// 대기열 = 대역폭 × 왕복 시간(최소 64KB)
		limit = int(*rate * 1e6 / 8 * (2 * delay.Seconds()))
		if limit < 64*1024 {
			limit = 64 * 1024
		}
	}
	var client atomic.Pointer[net.UDPAddr]
	var drops atomic.Int64

	pipe := func(name string, read func([]byte) (int, error), write func([]byte) error) {
		q := make(chan pkt, 1<<16)
		var queued atomic.Int64
		go func() {
			var next time.Time // 병목에서 다음 패킷이 나갈 수 있는 때
			for p := range q {
				due := p.due
				if *rate > 0 {
					if next.Before(due) {
						next = due
					}
					next = next.Add(time.Duration(float64(len(p.data)*8) / (*rate * 1e6) * float64(time.Second)))
					due = next
				}
				if d := time.Until(due); d > 0 {
					time.Sleep(d)
				}
				write(p.data)
				queued.Add(-int64(len(p.data)))
			}
		}()
		for {
			buf := make([]byte, 2048)
			n, err := read(buf)
			if err != nil {
				log.Printf("%s read: %v", name, err)
				continue
			}
			if limit > 0 && queued.Load()+int64(n) > int64(limit) {
				drops.Add(1)
				continue
			}
			queued.Add(int64(n))
			select {
			case q <- pkt{time.Now().Add(*delay), buf[:n]}:
			default:
				drops.Add(1)
				queued.Add(-int64(n))
			}
		}
	}

	go pipe("c2s", func(b []byte) (int, error) {
		n, addr, err := front.ReadFromUDP(b)
		if err == nil {
			client.Store(addr)
		}
		return n, err
	}, func(b []byte) error { _, err := back.Write(b); return err })
	go pipe("s2c", back.Read, func(b []byte) error {
		if a := client.Load(); a != nil {
			_, err := front.WriteToUDP(b, a)
			return err
		}
		return nil
	})
	log.Printf("relay %s <-> %s delay %v rate %.0f Mbit/s queue %d KB", *listen, *upstream, *delay, *rate, limit/1024)
	for range time.Tick(5 * time.Second) {
		if d := drops.Load(); d > 0 {
			log.Printf("drops %d", d)
		}
	}
}
