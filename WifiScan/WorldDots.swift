import Foundation

/// route 지도에 찍는 점 세계 지도. 메르카토르 평면을 0.5° 칸으로 나눠 칸마다 바다/땅/나갈 국가를 적었다.
/// 데이터(`rle`, 칸 수)는 WorldDotsData.swift — tools/worldgrid.py로 만든다.
enum WorldDots {
    /// 칸 값: 0 바다, 1 땅, 2… `VPNRegion.allCases` 순서의 나라(`VPNRegion.mapCode`)
    struct Level {
        /// 0.5° 칸 몇 개를 한 점으로 묶었는지
        let stride: Int
        let cols: Int
        let rows: Int
        /// 점 하나의 크기(°)
        let cell: Double
        let cells: [UInt8]

        /// 경도 방향은 지구를 한 바퀴 돌아 이어진다
        func value(col: Int, row: Int) -> UInt8 {
            cells[row * cols + ((col % cols) + cols) % cols]
        }
    }

    /// 0.5° · 1° · 2° · 4° 네 단계. 화면에서 점 간격이 알맞은 단계를 골라 그린다.
    static let levels: [Level] = {
        let fine = decode()
        return [1, 2, 4, 8].map { coarsen(fine, by: $0) }
    }()

    private static func decode() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cols * rows)
        let lines = rle.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (row, line) in lines.prefix(rows).enumerated() {
            let bytes = Array(line.utf8)
            var i = row * cols
            let end = i + cols
            var k = 0
            while k < bytes.count {
                let value = code(bytes[k])
                k += 1
                var count = 0
                while k < bytes.count, bytes[k] >= 48, bytes[k] <= 57 {
                    count = count * 10 + Int(bytes[k] - 48)
                    k += 1
                }
                let stop = min(i + max(count, 1), end)
                if value != 0 {
                    for x in i..<stop { out[x] = value }
                }
                i = stop
            }
        }
        return out
    }

    /// 나라 글자. `VPNRegion.allCases` 순서(tools/worldgrid.py의 LETTERS와 같아야 함)
    private static let letters = Array("kjugsdfewcbai".utf8)

    private static func code(_ byte: UInt8) -> UInt8 {
        if byte == UInt8(ascii: "#") { return 1 }
        return letters.firstIndex(of: byte).map { UInt8(2 + $0) } ?? 0
    }

    /// s×s 칸을 점 하나로. 30% 넘게 땅이면 점을 찍고, 그중 한 나라가 20% 넘게 차지하면 그 나라 점.
    private static func coarsen(_ fine: [UInt8], by s: Int) -> Level {
        let lc = cols / s, lr = rows / s
        guard s > 1 else { return Level(stride: 1, cols: lc, rows: lr, cell: step, cells: fine) }
        var cells = [UInt8](repeating: 0, count: lc * lr)
        var counts = [Int](repeating: 0, count: 2 + letters.count)
        let area = s * s
        for row in 0..<lr {
            for col in 0..<lc {
                for c in counts.indices { counts[c] = 0 }
                for b in 0..<s {
                    let base = (row * s + b) * cols + col * s
                    for a in 0..<s { counts[Int(fine[base + a])] += 1 }
                }
                guard (area - counts[0]) * 10 >= area * 3 else { continue }
                var best = 1
                for c in 2..<counts.count where counts[c] > counts[best] && counts[c] * 5 >= area { best = c }
                cells[row * lc + col] = UInt8(best)
            }
        }
        return Level(stride: s, cols: lc, rows: lr, cell: step * Double(s), cells: cells)
    }
}
