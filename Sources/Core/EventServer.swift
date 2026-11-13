import Darwin
import Foundation

/// Unix-domain socket the hook CLI talks to. One JSON object per connection.
/// Phase 1 always answers `{}` (no decision), so agents fall back to their normal prompts.
final class EventServer {
    private let path: String
    private let queue: DispatchQueue
    private let handler: ([String: Any]) -> Void
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let io = DispatchQueue(label: "agentcats.socket", attributes: .concurrent)

    init(path: String, queue: DispatchQueue, handler: @escaping ([String: Any]) -> Void) {
        self.path = path; self.queue = queue; self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard ok == 0 else { close(fd); return false }
        chmod(path, 0o600)   // only this user may talk to the app
        guard listen(fd, 32) == 0 else { close(fd); return false }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
        return true
    }

    private func acceptOne() {
        let c = accept(fd, nil, nil)
        guard c >= 0 else { return }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var nosig: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        io.async { [self] in
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 16384)
            while data.count < 4_000_000 {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
                if buf[n - 1] == 0x0A { break }
            }
            let reply = "{}\n"
            _ = reply.withCString { write(c, $0, strlen($0)) }
            close(c)
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                queue.async { self.handler(obj) }
            }
        }
    }

    deinit {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(path)
    }
}
