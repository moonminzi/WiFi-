import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// 클래스 안에 close()/write() 같은 이름이 있어서 POSIX 함수는 파일 밖 이름으로 감싸 둔다.
private func posixOpen(_ path: String, _ flags: Int32) -> Int32 { open(path, flags, mode_t(0o644)) }
private func posixClose(_ fd: Int32) { _ = close(fd) }
private func posixPwrite(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int, _ off: Int64) -> Int { pwrite(fd, p, n, off_t(off)) }
private func posixPread(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ n: Int, _ off: Int64) -> Int { pread(fd, p, n, off_t(off)) }
private func posixTruncate(_ fd: Int32, _ size: Int64) -> Int32 { ftruncate(fd, off_t(size)) }
private func posixSync(_ fd: Int32) { _ = fsync(fd) }

/// 파일 입출력 오류. ENOSPC면 사람이 읽을 문장으로 바꿔 준다.
public struct FileIOError: Error, LocalizedError, Equatable {
    public let code: Int32
    public let operation: String

    public var isNoSpace: Bool { code == ENOSPC }

    public var errorDescription: String? {
        if code == ENOSPC { return "저장 공간이 부족해요" }
        return "\(operation) 실패: \(String(cString: strerror(code)))"
    }
}

/// 여러 연결이 받은 조각을 각자 위치에 쓰는 파일. 엔진 큐 하나에서만 쓴다.
public final class FileSink {
    public let url: URL
    private var fd: Int32

    public init(url: URL, truncate: Bool = false) throws {
        self.url = url
        let flags = O_RDWR | O_CREAT | (truncate ? O_TRUNC : 0)
        let fd = posixOpen(url.path, flags)
        guard fd >= 0 else { throw FileIOError(code: errno, operation: "파일 열기") }
        self.fd = fd
    }

    deinit {
        if fd >= 0 { posixClose(fd) }
    }

    public func write(_ data: Data, at offset: Int64) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            try write(raw, at: offset)
        }
    }

    public func write(_ raw: UnsafeRawBufferPointer, at offset: Int64) throws {
        guard var p = raw.baseAddress, fd >= 0 else { return }
        var left = raw.count
        var off = offset
        while left > 0 {
            let n = posixPwrite(fd, p, left, off)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileIOError(code: errno, operation: "쓰기")
            }
            p = p.advanced(by: n)
            left -= n
            off += Int64(n)
        }
    }

    /// 다른 파일(백그라운드 세션이 받은 조각)을 통째로 offset 위치에 복사한다.
    public func copy(from source: URL, at offset: Int64, expectedLength: Int64? = nil) throws -> Int64 {
        let input = posixOpen(source.path, O_RDONLY)
        guard input >= 0 else { throw FileIOError(code: errno, operation: "조각 열기") }
        defer { posixClose(input) }
        let chunk = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var copied: Int64 = 0
        while true {
            if let expectedLength, copied >= expectedLength { break }
            var want = chunk
            if let expectedLength { want = Int(min(Int64(chunk), expectedLength - copied)) }
            let n = posixPread(input, buffer, want, copied)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileIOError(code: errno, operation: "조각 읽기")
            }
            if n == 0 { break }
            try write(UnsafeRawBufferPointer(start: buffer, count: n), at: offset + copied)
            copied += Int64(n)
        }
        return copied
    }

    public func truncate(to size: Int64) throws {
        if posixTruncate(fd, size) != 0 { throw FileIOError(code: errno, operation: "크기 조정") }
    }

    public func synchronize() {
        if fd >= 0 { posixSync(fd) }
    }

    public func close() {
        if fd >= 0 {
            posixClose(fd)
            fd = -1
        }
    }
}

/// 큰 파일을 순서대로 쓰는 버퍼 달린 출력(리먹스용).
public final class BufferedFileWriter {
    private let sink: FileSink
    private var buffer: [UInt8] = []
    private let capacity: Int
    public private(set) var position: Int64 = 0

    public init(url: URL, capacity: Int = 1 << 20) throws {
        sink = try FileSink(url: url, truncate: true)
        self.capacity = capacity
        buffer.reserveCapacity(capacity)
    }

    public func write(_ bytes: [UInt8]) throws {
        try write(bytes[...])
    }

    public func write(_ bytes: ArraySlice<UInt8>) throws {
        if buffer.count + bytes.count > capacity { try flush() }
        if bytes.count >= capacity {
            try bytes.withUnsafeBytes { try sink.write($0, at: position) }
        } else {
            buffer.append(contentsOf: bytes)
        }
        position += Int64(bytes.count)
    }

    public func write(_ data: Data) throws {
        try write([UInt8](data))
    }

    public func flush() throws {
        guard !buffer.isEmpty else { return }
        let start = position - Int64(buffer.count)
        try buffer.withUnsafeBytes { try sink.write($0, at: start) }
        buffer.removeAll(keepingCapacity: true)
    }

    /// 이미 쓴 자리를 고친다(mdat 크기처럼 나중에 알게 되는 값).
    public func patch(_ bytes: [UInt8], at offset: Int64) throws {
        try flush()
        try bytes.withUnsafeBytes { try sink.write($0, at: offset) }
    }

    public func close() throws {
        try flush()
        sink.close()
    }
}
