import Darwin
import Foundation

var failures = 0
func check(_ result: Bool, _ name: String) {
    print("\(result ? "PASS" : "FAIL") \(name)")
    if !result { failures += 1 }
}
let path = "/tmp/ac-test-\(getpid()).sock"
let queue = DispatchQueue(label: "test.monitor")
var held: HookReply?
let received = DispatchSemaphore(value: 0)
let server = EventServer(path: path, queue: queue) { object, reply in
    if object["test"] as? String == "hold" {
        held = reply
        received.signal()
    } else if ApprovalProtocol.supports(object) {
        reply.complete(ApprovalProtocol.response(object["test"] as? String == "deny" ? .deny : .allow))
    } else { reply.complete([:]) }
}
guard server.start() else {
    print("FAIL cannot bind isolated test socket (errno \(errno))")
    exit(1)
}

func connectClient() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
        for (i, b) in path.utf8.enumerated() { bytes[i] = b }
    }
    let rc = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if rc != 0 { close(fd); return -1 }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}
func sendObject(_ object: [String: Any], fd: Int32) {
    var data = try! JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}
func receive(_ fd: Int32) -> [String: Any]? {
    var bytes = [UInt8](repeating: 0, count: 4096)
    let n = read(fd, &bytes, bytes.count)
    guard n > 0 else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(bytes.prefix(n)))) as? [String: Any]
}
func transaction(_ object: [String: Any], halfClose: Bool = false) -> [String: Any]? {
    let fd = connectClient()
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    sendObject(object, fd: fd)
    if halfClose { shutdown(fd, SHUT_WR) }
    return receive(fd)
}
func behavior(_ value: [String: Any]?) -> String? {
    let output = value?["hookSpecificOutput"] as? [String: Any]
    return (output?["decision"] as? [String: Any])?["behavior"] as? String
}
var object: [String: Any] = ["_agent": "claude", "hook_event_name": "PermissionRequest",
    "_waitForDecision": true, "session_id": "fixture", "tool_name": "Bash", "tool_input": ["command": "echo fixture"]]
check(behavior(transaction(object)) == "allow", "allow response crosses real socket")
object["test"] = "deny"
check(behavior(transaction(object)) == "deny", "deny response crosses real socket")
check(transaction(["hook_event_name": "Stop"], halfClose: true)?.isEmpty == true, "old observation client receives empty acknowledgement")
do {
    let second = EventServer(path: path, queue: queue) { _, reply in reply.complete([:]) }
    check(!second.start(), "second listener cannot replace active socket")
}
check(behavior(transaction(object)) == "deny", "original listener survives second listener cleanup")
object["test"] = "hold"
let fd = connectClient()
sendObject(object, fd: fd)
check(received.wait(timeout: .now() + 2) == .success, "pending approval reaches handler")
check(transaction(["hook_event_name": "Stop"], halfClose: true)?.isEmpty == true, "waiting approval does not block other events")
queue.sync { _ = held?.complete(ApprovalProtocol.response(.allow)) }
check(behavior(receive(fd)) == "allow", "delayed user decision reaches waiting client")
close(fd)
let cancelled = connectClient()
sendObject(object, fd: cancelled)
_ = received.wait(timeout: .now() + 2)
close(cancelled)
Thread.sleep(forTimeInterval: 0.2)
let pending = queue.sync { held?.pending ?? true }
check(!pending, "client disconnect cancels waiting approval")
let late = queue.sync { held?.complete(ApprovalProtocol.response(.allow)) ?? true }
check(!late, "cannot approve disconnected client")
try? FileManager.default.removeItem(atPath: path + ".lock")
print("\(failures) socket test failures")
exit(failures == 0 ? 0 : 1)
