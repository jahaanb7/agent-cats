import Darwin
import Foundation

/// One JSON request per connection. A live approval keeps its connection open until resolved.
final class EventServer {
    private let path: String
    private let queue: DispatchQueue
    private let handler: ([String: Any], HookReply) -> Void
    private var fd: Int32 = -1
    private var lockFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let io = DispatchQueue(label: "agentcats.socket", attributes: .concurrent)

    init(path: String, queue: DispatchQueue, handler: @escaping ([String: Any], HookReply) -> Void) {
        self.path = path; self.queue = queue; self.handler = handler
    }

    @discardableResult func start() -> Bool {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A second app/CLI must not unlink the live app's socket.
        lockFD = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { return false }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); lockFD = -1; return false }
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard ok == 0 else { return false }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else { return false }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume(); source = src
        return true
    }

    private func acceptOne() {
        let c = accept(fd, nil, nil)
        guard c >= 0 else { return }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var nosig: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        io.async { [queue, handler] in
            defer { close(c) }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 16384)
            while data.count < 4_000_000 {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
                if data.contains(0x0A) { break }
            }
            guard data.count < 4_000_000,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            let reply = HookReply()
            queue.async { handler(obj, reply) }
            while reply.response() == nil {
                var byte: UInt8 = 0
                let n = recv(c, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                // Interactive clients keep their write side open so EOF means cancellation.
                if ApprovalProtocol.supports(obj), n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    reply.complete([:]); return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard var output = try? JSONSerialization.data(withJSONObject: reply.response() ?? [:]) else { return }
            output.append(0x0A)
            output.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = write(c, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    offset += n
                }
            }
        }
    }

    deinit {
        source?.cancel()
        if fd >= 0 { close(fd) }
        if lockFD >= 0 { unlink(path); flock(lockFD, LOCK_UN); close(lockFD) }
    }
}
