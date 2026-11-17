// agentcats-hook <claude|codex>
//
// Registered as a command hook. Reads the hook JSON from stdin, tags it with the agent's pid/tty,
// Ordinary events are observation-only. With --approvals, Claude PermissionRequest
// waits for a user decision. Unavailable/expired connections fall through to the agent.
import Darwin
import Foundation

let agent = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "claude"
let input = FileHandle.standardInput.readDataToEndOfFile()
guard var obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }

obj["_agent"] = agent
obj["_waitForDecision"] = CommandLine.arguments.contains("--approvals")
let interactive = ApprovalProtocol.supports(obj)
if let a = ProcInfo.agentAncestor(from: getppid()) {
    obj["_pid"] = Int(a.pid)
    if let t = ProcInfo.tty(a.pid) { obj["_tty"] = t }
}
let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
obj["_ts"] = fmt.string(from: Date())

guard var line = try? JSONSerialization.data(withJSONObject: obj) else { exit(0) }
line.append(0x0A)

func send(_ data: Data, to path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var nosig: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in bytes.enumerated() { buf[i] = b }
        buf[bytes.count] = 0
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
    guard rc == 0 else { return false }
    let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard wrote == data.count else { return false }
    if !interactive { shutdown(fd, SHUT_WR) }
    if interactive {
        tv.tv_sec = Int(ApprovalProtocol.timeout + 3)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    var buf = [UInt8](repeating: 0, count: 4096)
    var response = Data()
    while response.count < 65536 {
        let n = read(fd, &buf, buf.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        response.append(buf, count: n)
        if response.contains(0x0A) { break }
    }
    if interactive, let valid = ApprovalProtocol.validatedResponse(response) {
        FileHandle.standardOutput.write(valid)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    return true
}

func spool(_ data: Data) {
    let dir = Paths.supportDir
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fd = open(Paths.spool, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var st = stat()
    if fstat(fd, &st) == 0, st.st_size > 5_000_000 { return }   // app has been off for ages; don't grow forever
    flock(fd, LOCK_EX)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    flock(fd, LOCK_UN)
}

if !send(line, to: Paths.socket) {
    // Spool is telemetry only; never resurrect an approval after the hook has exited.
    obj["_waitForDecision"] = false
    if var event = try? JSONSerialization.data(withJSONObject: obj) { event.append(0x0A); spool(event) }
}
exit(0)
