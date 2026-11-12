// An on-demand LaunchServices child supervisor; ACP remains opaque bytes.
import Darwin
import Foundation

private var interrupted: sig_atomic_t = 0
private let bufferLimit = 262_144
private let configurationLimit = 65_536
// Darwin's _IOR('f', 127, int); the function-like FIONREAD macro is not imported.
private let bytesAvailableRequest = UInt(0x40000000) | (UInt(MemoryLayout<Int32>.size) << 16)
    | (UInt(102) << 8) | UInt(127)

private enum Failure: String, Error {
    case arguments, socket, configuration, executable, directory, spawn, transport
}

private struct Configuration: Decodable {
    let version: Int
    let executable: String
    let cwd: String
    let arguments: [String]
    let path: String
}

private func now() -> Double { ProcessInfo.processInfo.systemUptime }
private func closeFD(_ fd: inout Int32) {
    if fd >= 0 { Darwin.close(fd); fd = -1 }
}

private func closeOnExec(_ fd: Int32) throws {
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.transport }
}

private func nonblocking(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure.transport }
}

private func safeString(_ value: String, limit: Int = 16_384) -> Bool {
    !value.utf8.contains(0) && value.utf8.count <= limit
}

private func waitFor(_ fd: Int32, _ events: Int16, until deadline: Double) throws {
    while interrupted == 0 && now() < deadline {
        var item = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&item, 1, Int32(min(100, max(1, (deadline - now()) * 1_000))))
        if result < 0 && errno == EINTR { continue }
        guard result >= 0 else { throw Failure.transport }
        if item.revents & events != 0 { return }
        if item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw Failure.transport }
    }
    throw Failure.transport
}

private func readExactly(_ fd: Int32, count: Int, until deadline: Double) throws -> Data {
    var data = Data(count: count)
    var position = 0
    while position < count {
        try waitFor(fd, Int16(POLLIN), until: deadline)
        let result = data.withUnsafeMutableBytes { bytes in
            Darwin.read(fd, bytes.baseAddress!.advanced(by: position), count - position)
        }
        if result < 0 && (errno == EINTR || errno == EAGAIN) { continue }
        guard result > 0 else { throw Failure.transport }
        position += result
    }
    return data
}

private func writeAll(_ fd: Int32, data: Data, until deadline: Double) throws {
    var position = 0
    while position < data.count {
        try waitFor(fd, Int16(POLLOUT), until: deadline)
        let result = data.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress!.advanced(by: position), data.count - position)
        }
        if result < 0 && (errno == EINTR || errno == EAGAIN) { continue }
        guard result > 0 else { throw Failure.transport }
        position += result
    }
}

private func acknowledge(_ socket: Int32, _ body: [String: Any]) throws {
    let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    var length = UInt32(payload.count).bigEndian
    var frame = withUnsafeBytes(of: &length) { Data($0) }
    frame.append(payload)
    try writeAll(socket, data: frame, until: now() + 2)
}

private func connectSocket(_ path: String) throws -> Int32 {
    guard path.hasPrefix("/"), safeString(path, limit: 103) else { throw Failure.socket }
    let parent = (path as NSString).deletingLastPathComponent
    guard (parent as NSString).lastPathComponent.hasPrefix("clutch-muse-gui-") else { throw Failure.socket }
    var directory = stat()
    var endpoint = stat()
    guard lstat(parent, &directory) == 0,
          directory.st_mode & S_IFMT == S_IFDIR,
          directory.st_uid == getuid(), directory.st_mode & 0o777 == 0o700,
          lstat(path, &endpoint) == 0,
          endpoint.st_mode & S_IFMT == S_IFSOCK,
          endpoint.st_uid == getuid(), endpoint.st_mode & 0o777 == 0o600 else { throw Failure.socket }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure.socket }
    do {
        try closeOnExec(fd)
        try nonblocking(fd)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw Failure.socket }
            try waitFor(fd, Int16(POLLOUT), until: now() + 10)
            var connectionError: Int32 = 0
            var errorSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &connectionError, &errorSize) == 0,
                  connectionError == 0 else { throw Failure.socket }
        }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        var current = stat()
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid(),
              lstat(path, &current) == 0, current.st_dev == endpoint.st_dev,
              current.st_ino == endpoint.st_ino else { throw Failure.socket }
        return fd
    } catch {
        Darwin.close(fd)
        throw Failure.socket
    }
}

private func configuration(from socket: Int32) throws -> Configuration {
    do {
        let deadline = now() + 10
        let header = try readExactly(socket, count: 4, until: deadline)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= configurationLimit else { throw Failure.configuration }
        let payload = try readExactly(socket, count: Int(length), until: deadline)
        let config = try JSONDecoder().decode(Configuration.self, from: payload)
        guard config.version == 1, config.arguments.count <= 64,
              safeString(config.executable), safeString(config.cwd), safeString(config.path),
              config.arguments.allSatisfy({ safeString($0) }),
              config.executable.hasPrefix("/"), config.cwd.hasPrefix("/") else { throw Failure.configuration }
        return config
    } catch { throw Failure.configuration }
}

private struct Child {
    let pid: pid_t
    var input: Int32
    var output: Int32
    var groupStopped = false
}

private func hasExited(_ pid: pid_t) throws -> Bool {
    var status = siginfo_t()
    let result = waitid(P_PID, id_t(pid), &status, WEXITED | WNOHANG | WNOWAIT)
    if result < 0 && errno == EINTR { return false }
    guard result == 0 else { throw Failure.transport }
    return status.si_pid == pid
}

private func spawnMuse(_ config: Configuration) throws -> Child {
    guard let resolved = realpath(config.executable, nil) else { throw Failure.executable }
    defer { free(resolved) }
    let executable = String(cString: resolved)
    var info = stat()
    guard stat(executable, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == 0 || info.st_uid == getuid(), access(executable, X_OK) == 0 else { throw Failure.executable }
    guard stat(config.cwd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          chdir(config.cwd) == 0 else { throw Failure.directory }
    guard setenv("PATH", config.path, 1) == 0, setenv("MUSE_EXPERIMENTAL_ACP", "on", 1) == 0 else { throw Failure.spawn }

    var input = [Int32](repeating: -1, count: 2)
    var output = [Int32](repeating: -1, count: 2)
    guard pipe(&input) == 0 else { throw Failure.spawn }
    guard pipe(&output) == 0 else {
        input.forEach { Darwin.close($0) }; throw Failure.spawn
    }
    var success = false
    defer {
        Darwin.close(input[0]); Darwin.close(output[1])
        if !success { Darwin.close(input[1]); Darwin.close(output[0]) }
    }
    for descriptor in input + output { try closeOnExec(descriptor) }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.spawn }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.spawn }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
          posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0,
          posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0 else { throw Failure.spawn }
    var mask = sigset_t()
    sigemptyset(&mask)
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for number in [SIGPIPE, SIGTERM, SIGINT] { sigaddset(&defaults, number) }
    guard posix_spawnattr_setsigmask(&attributes, &mask) == 0,
          posix_spawnattr_setsigdefault(&attributes, &defaults) == 0 else { throw Failure.spawn }
    let arguments = ([executable, "acp"] + config.arguments).map { strdup($0)! } + [nil]
    defer { arguments.forEach { if let argument = $0 { free(argument) } } }
    var pid: pid_t = 0
    let result = arguments.withUnsafeBufferPointer {
        posix_spawn(&pid, executable, &actions, &attributes, $0.baseAddress!, environ)
    }
    guard result == 0 else { throw Failure.spawn }
    // Keep the child unreaped until its owned process group has been stopped.
    // That pins its PID and prevents cleanup from targeting a reused group ID.
    var child = Child(pid: pid, input: input[1], output: output[0])
    do {
        try nonblocking(child.input)
        try nonblocking(child.output)
    } catch {
        closeFD(&child.input); closeFD(&child.output)
        kill(-pid, SIGKILL)
        while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
        // These descriptors were closed above rather than in the failure defer.
        input[1] = -1; output[0] = -1
        throw Failure.spawn
    }
    success = true
    return child
}

private func finish(_ child: inout Child) {
    closeFD(&child.input)
    if !child.groupStopped {
        kill(-child.pid, SIGTERM)
        let deadline = now() + 0.75
        // Do not reap before the final group signal, even if the leader exits early.
        while now() < deadline { usleep(25_000) }
        kill(-child.pid, SIGKILL)
        child.groupStopped = true
    }
    while waitpid(child.pid, nil, 0) < 0 && errno == EINTR {}
    closeFD(&child.output)
}

private func appendRead(_ fd: Int32, to buffer: inout Data, limit: Int = 65_536) throws -> Bool {
    var bytes = [UInt8](repeating: 0, count: min(limit, 65_536, bufferLimit - buffer.count))
    if bytes.isEmpty { return true }
    let result = Darwin.read(fd, &bytes, bytes.count)
    if result > 0 { buffer.append(contentsOf: bytes.prefix(result)); return true }
    if result == 0 { return false }
    if errno == EAGAIN || errno == EINTR { return true }
    throw Failure.transport
}

private func flush(_ buffer: inout Data, to fd: Int32) throws {
    if buffer.isEmpty { return }
    let count = buffer.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    if count > 0 { buffer.removeFirst(count); return }
    if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
    throw Failure.transport
}

private func relay(_ socket: Int32, child: inout Child) throws {
    var toMuse = Data()
    var toBroker = Data()
    var outputOpen = true
    var childExited = false
    var drainDeadline: Double?
    var finalPipeBytes: Int?
    while interrupted == 0 {
        if try !childExited && hasExited(child.pid) {
            childExited = true
            closeFD(&child.input)
            toMuse.removeAll()
            kill(-child.pid, SIGTERM)
            drainDeadline = now() + 0.75
        }
        if let deadline = drainDeadline, now() >= deadline, !child.groupStopped {
            kill(-child.pid, SIGKILL)
            child.groupStopped = true
            // Bound inherited-pipe cleanup, not delivery to a slow consumer.
            // The leader has finished writing; retain the finite queued tail.
            var available: Int32 = 0
            guard ioctl(child.output, bytesAvailableRequest, &available) == 0, available >= 0 else {
                throw Failure.transport
            }
            finalPipeBytes = Int(available)
            if available == 0 {
                outputOpen = false
                closeFD(&child.output)
            }
        }
        var items = [
            pollfd(fd: socket, events: Int16((!childExited && toMuse.count < bufferLimit ? POLLIN : 0) | (!toBroker.isEmpty ? POLLOUT : 0)), revents: 0),
            pollfd(fd: outputOpen && toBroker.count < bufferLimit ? child.output : -1,
                   events: Int16(outputOpen && toBroker.count < bufferLimit ? POLLIN : 0), revents: 0),
            pollfd(fd: child.input, events: Int16(!toMuse.isEmpty ? POLLOUT : 0), revents: 0),
        ]
        let result = poll(&items, nfds_t(items.count), 100)
        if result < 0 && errno == EINTR { continue }
        guard result >= 0 else { throw Failure.transport }
        if items[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
        if items[0].revents & Int16(POLLIN) != 0, !(try appendRead(socket, to: &toMuse)) { return }
        if items[0].revents & Int16(POLLOUT) != 0 { try flush(&toBroker, to: socket) }
        if items[1].revents & Int16(POLLIN | POLLHUP) != 0, outputOpen {
            let previousCount = toBroker.count
            outputOpen = try appendRead(child.output, to: &toBroker, limit: finalPipeBytes ?? 65_536)
            if let remaining = finalPipeBytes {
                finalPipeBytes = remaining - (toBroker.count - previousCount)
                if finalPipeBytes == 0 {
                    outputOpen = false
                    closeFD(&child.output)
                }
            }
        }
        if items[2].revents & Int16(POLLOUT) != 0 { try flush(&toMuse, to: child.input) }
        if items[1].revents & Int16(POLLERR | POLLNVAL) != 0 { throw Failure.transport }
        if !childExited && items[2].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
            childExited = true
            closeFD(&child.input)
            toMuse.removeAll()
            kill(-child.pid, SIGTERM)
            drainDeadline = now() + 0.75
        }
        if !outputOpen && toBroker.isEmpty { return }
    }
}

private func run() -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM) { _ in interrupted = 1 }
    signal(SIGINT) { _ in interrupted = 1 }
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--socket" else { return 1 }
    var socket: Int32 = -1
    var ready = false
    defer { closeFD(&socket) }
    do {
        socket = try connectSocket(CommandLine.arguments[2])
        let config = try configuration(from: socket)
        var child = try spawnMuse(config)
        defer { finish(&child) }
        try acknowledge(socket, ["version": 1, "ready": true, "pid": child.pid, "pgid": child.pid])
        ready = true
        try relay(socket, child: &child)
        return 0
    } catch {
        if socket >= 0 && !ready {
            try? acknowledge(socket, ["version": 1, "ready": false,
                                      "stage": (error as? Failure)?.rawValue ?? Failure.transport.rawValue])
        }
        closeFD(&socket)
        return 1
    }
}

exit(run())
