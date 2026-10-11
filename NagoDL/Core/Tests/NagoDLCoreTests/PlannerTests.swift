import XCTest
@testable import NagoDLCore

final class PlannerTests: XCTestCase {
    let planner = SegmentPlanner(minPiece: 100)

    func testInitialSplitIsEvenAndCoversFile() {
        let segs = planner.initialSegments(total: 1003, connections: 4)
        XCTAssertEqual(segs.count, 4)
        XCTAssertEqual(segs.first?.start, 0)
        XCTAssertEqual(segs.last?.end, 1002)
        for (a, b) in zip(segs, segs.dropFirst()) { XCTAssertEqual(a.end + 1, b.start) }
        XCTAssertEqual(segs.reduce(0) { $0 + $1.length }, 1003)
    }

    func testInitialSplitRespectsMinPiece() {
        XCTAssertEqual(planner.initialSegments(total: 250, connections: 8).count, 2)
        XCTAssertEqual(planner.initialSegments(total: 50, connections: 8).count, 1)
        XCTAssertEqual(planner.initialSegments(total: 0, connections: 8).count, 0)
    }

    func testIdleSegmentIsPickedBeforeSplitting() {
        var segs = [Segment(start: 0, end: 999, received: 10), Segment(start: 1000, end: 1999, received: 0)]
        let pick = planner.pickWork(&segs, busy: [0])
        XCTAssertEqual(pick, 1000)
        XCTAssertEqual(segs.count, 2)
    }

    func testSplitTakesBackHalfOfLargestRemaining() {
        var segs = [Segment(start: 0, end: 999, received: 900), Segment(start: 1000, end: 1999, received: 200)]
        let pick = planner.pickWork(&segs, busy: [0, 1000])
        // 1000번 구간: 다음 위치 1200, 남은 800 → 1600에서 자른다
        XCTAssertEqual(pick, 1600)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[1].end, 1599)
        XCTAssertEqual(segs[2], Segment(start: 1600, end: 1999))
    }

    func testNoSplitBelowTwoPieces() {
        var segs = [Segment(start: 0, end: 999, received: 850)]
        XCTAssertNil(planner.pickWork(&segs, busy: [0]))
        XCTAssertEqual(segs.count, 1)
    }

    func testExternalSegmentsAreNotTouched() {
        var segs = [Segment(start: 0, end: 999, received: 0, external: true)]
        XCTAssertNil(planner.pickWork(&segs, busy: []))
        XCTAssertNil(planner.pickWork(&segs, busy: [0]))
    }

    func testCompactMergesDoneAndEmptyNeighbours() {
        var segs = [
            Segment(start: 0, end: 99, received: 100),
            Segment(start: 100, end: 199, received: 100),
            Segment(start: 200, end: 299, received: 30),
            Segment(start: 300, end: 399, received: 0),
            Segment(start: 400, end: 499, received: 10),
        ]
        SegmentPlanner.compact(&segs, busy: [])
        // [0,99]+[100,199]+[200,299 (30)] → [0,299] 230받음, 그 뒤 빈 [300,399]도 붙는다
        XCTAssertEqual(segs, [Segment(start: 0, end: 399, received: 230), Segment(start: 400, end: 499, received: 10)])
    }

    func testCompactLeavesBusyAndExternalAlone() {
        var segs = [
            Segment(start: 0, end: 99, received: 100),
            Segment(start: 100, end: 199, received: 0),
            Segment(start: 200, end: 299, received: 0, external: true),
        ]
        SegmentPlanner.compact(&segs, busy: [100])
        XCTAssertEqual(segs.count, 3)
    }

    func testChunkForBackgroundKeepsReceivedPrefix() {
        let segs = [Segment(start: 0, end: 999, received: 100), Segment(start: 1000, end: 1999, received: 1000)]
        let out = SegmentPlanner.chunkForBackground(segs, chunk: 300)
        XCTAssertEqual(out.first, Segment(start: 0, end: 99, received: 100))
        let ext = out.filter(\.external)
        XCTAssertEqual(ext.first?.start, 100)
        XCTAssertEqual(ext.last?.end, 999)
        XCTAssertEqual(ext.reduce(0) { $0 + $1.length }, 900)
        XCTAssertEqual(ext.count, 3)
        for (a, b) in zip(ext, ext.dropFirst()) { XCTAssertEqual(a.end + 1, b.start) }
        XCTAssertEqual(out.last, Segment(start: 1000, end: 1999, received: 1000))
    }
}

final class MetaTests: XCTestCase {
    func testContentRange() {
        XCTAssertEqual(ContentRange.parse("bytes 0-499/1234"), ContentRange(start: 0, end: 499, total: 1234))
        XCTAssertEqual(ContentRange.parse("bytes 10-19/*"), ContentRange(start: 10, end: 19, total: nil))
        XCTAssertNil(ContentRange.parse("bytes 10-9/100"))
        XCTAssertNil(ContentRange.parse("bytes 0-100/100"))
        XCTAssertEqual(ContentRange.unsatisfiedTotal("bytes */0"), 0)
        XCTAssertEqual(ContentRange.unsatisfiedTotal("bytes */77"), 77)
        XCTAssertNil(ContentRange.unsatisfiedTotal("bytes 0-1/2"))
    }

    func testContentDisposition() {
        XCTAssertEqual(ContentDisposition.filename(from: "attachment; filename=\"a b.zip\""), "a b.zip")
        XCTAssertEqual(ContentDisposition.filename(from: "attachment; filename*=UTF-8''%ED%95%9C%EA%B8%80.zip; filename=\"x.zip\""), "한글.zip")
        XCTAssertEqual(ContentDisposition.filename(from: "attachment; filename*=iso-8859-1'en'%A3%20rates.txt"), "£ rates.txt")
        XCTAssertEqual(ContentDisposition.filename(from: "inline; filename=\"semi;colon\\\".txt\""), "semi;colon\".txt")
        // UTF-8 바이트가 Latin-1로 읽혀 깨진 이름
        let broken = String(decoding: Array("사진.jpg".utf8).map { UInt16($0) }, as: UTF16.self)
        XCTAssertEqual(ContentDisposition.filename(from: "attachment; filename=\"\(broken)\""), "사진.jpg")
        XCTAssertTrue(ContentDisposition.isAttachment("Attachment; filename=a"))
    }

    func testSuggestedNames() {
        let u = URL(string: "https://example.com/path/My%20File.bin?x=1")!
        XCTAssertEqual(FileNamer.suggestedName(url: u), "My File.bin")
        XCTAssertEqual(FileNamer.suggestedName(url: URL(string: "https://example.com/")!, mimeType: "application/zip"), "example_com.zip")
        XCTAssertEqual(FileNamer.suggestedName(url: URL(string: "https://e.com/get")!, mimeType: "video/mp4"), "get.mp4")
        XCTAssertEqual(FileNamer.sanitize("a/b:c?.mp4"), "a_b_c_.mp4")
        XCTAssertEqual(FileNamer.sanitize("..hidden.."), "hidden")
        let long = String(repeating: "가", count: 120) + ".mp4"
        let s = FileNamer.sanitize(long)
        XCTAssertLessThanOrEqual(s.utf8.count, 200)
        XCTAssertTrue(s.hasSuffix(".mp4"))
    }

    func testUniqueName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.zip").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a (1).zip").path, contents: Data())
        XCTAssertEqual(FileNamer.uniqueName("a.zip", in: dir), "a (2).zip")
        XCTAssertEqual(FileNamer.uniqueName("b.zip", in: dir), "b.zip")
        XCTAssertEqual(FileNamer.uniqueName("b.zip", in: dir, reserved: ["b.zip"]), "b (1).zip")
    }

    func testExternalKeyRoundTrip() {
        let k = ExternalKey(download: UUID(), kind: .range, a: 123, b: 456789)
        XCTAssertEqual(ExternalKey(string: k.description), k)
        XCTAssertNil(ExternalKey(string: "nope"))
    }

    func testFormat() {
        XCTAssertEqual(ByteFormat.size(512), "512 B")
        XCTAssertEqual(ByteFormat.size(1536), "1.5 KB")
        XCTAssertEqual(ByteFormat.duration(65), "1m 05s")
        XCTAssertEqual(ByteFormat.duration(3725), "1h 02m")
    }

    func testSpeedMeter() {
        var m = SpeedMeter(window: 4)
        for i in 0..<20 { m.add(1000, now: Double(i) * 0.2) }
        let v = m.bytesPerSecond(now: 4.0)
        XCTAssertEqual(v, 5000, accuracy: 1500)
        XCTAssertEqual(m.bytesPerSecond(now: 100), 0)
    }
}
