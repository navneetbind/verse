import Foundation

/// Reads Firefox native-messaging frames from stdin: a 4-byte little-endian
/// length prefix followed by that many bytes of UTF-8 JSON. Runs the blocking
/// read on a background thread and hands each JSON payload to `onMessage` on the
/// main queue. On EOF (browser disconnected) calls `onEOF`.
final class NativeHost {
    var onMessage: ((String) -> Void)?
    var onEOF: (() -> Void)?

    private let fd: Int32 = 0 // stdin
    private let outQueue = DispatchQueue(label: "verse.out")

    func start() {
        Thread.detachNewThread { [weak self] in self?.loop() }
    }

    /// Send a JSON message back to the browser (native-messaging frame on stdout).
    func send(_ obj: [String: Any]) {
        outQueue.async {
            guard let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
            var len = UInt32(body.count).littleEndian
            let header = Data(bytes: &len, count: 4)
            FileHandle.standardOutput.write(header)
            FileHandle.standardOutput.write(body)
        }
    }

    private func loop() {
        while true {
            guard let header = readExactly(4) else { break }
            let len = header.withUnsafeBytes { $0.load(as: UInt32.self) } // native = LE on arm64
            if len == 0 || len > 10_000_000 { break }
            guard let body = readExactly(Int(len)) else { break }
            let str = String(decoding: body, as: UTF8.self)
            DispatchQueue.main.async { self.onMessage?(str) }
        }
        DispatchQueue.main.async { self.onEOF?() }
    }

    /// Read exactly `n` bytes or return nil on EOF/error.
    private func readExactly(_ n: Int) -> Data? {
        var buf = Data(count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { raw -> Int in
                let base = raw.baseAddress!.advanced(by: got)
                return read(fd, base, n - got)
            }
            if r <= 0 { return nil } // 0 = EOF, <0 = error
            got += r
        }
        return buf
    }
}
