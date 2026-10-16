import Darwin
import Foundation

/// What to run. Stdout is a pseudo-terminal when the CLI only streams to a TTY (Claude).
nonisolated struct CLICommand: Sendable {
  var executable: String
  var arguments: [String]
  var environment: [String: String]
  var currentDirectory: String
  var stdoutIsTerminal = false
}

nonisolated struct CLIExit: Sendable, Equatable {
  /// Exit code, or 128 + signal number when the process was killed.
  var status: Int32
  /// The end of stderr, kept for the error message the user sees. Never logged.
  var stderr: String
  var stdoutBytes: Int
  var stderrBytes: Int
}

nonisolated enum CLIProcess {
  /// How long a cancelled process gets between SIGTERM and SIGKILL.
  static let terminationGrace: DispatchTimeInterval = .milliseconds(800)
  /// How long output may keep flowing after the process exits, for example from a
  /// grandchild that inherited stdout. The process group is killed after that.
  static let drainGrace: DispatchTimeInterval = .milliseconds(400)
  static let stderrLimit = 8_192

  /// Runs `command` to completion and hands decoded stdout to `onStdout` in order.
  /// Returns only after the process is reaped and every descriptor is closed. Cancellation
  /// terminates the whole process group, escalating to SIGKILL, and then throws.
  @concurrent
  static func run(
    _ command: CLICommand,
    onStdout: @Sendable (String) async -> Void
  ) async throws -> CLIExit {
    try Task.checkCancellation()
    let child = try ChildProcess(command)
    return try await withTaskCancellationHandler {
      var decoder = UTF8StreamDecoder()
      var stderr = Data()
      var stdoutBytes = 0
      var stderrBytes = 0
      var status: Int32 = -1
      var cancelled = false
      for await event in child.events {
        switch event {
        case .stdout(let data):
          stdoutBytes += data.count
          let text = decoder.decode(data)
          if !text.isEmpty, !Task.isCancelled {
            await onStdout(text)
          }
        case .stderr(let data):
          stderrBytes += data.count
          stderr.append(data)
          if stderr.count > stderrLimit {
            stderr.removeFirst(stderr.count - stderrLimit)
          }
        case .exit(let code, let wasCancelled):
          status = code
          cancelled = wasCancelled
        }
      }
      // A cancelled iteration ends early; the child still has to be reaped first.
      await child.waitUntilFinished()
      if cancelled || Task.isCancelled {
        throw CancellationError()
      }
      let tail = decoder.finish()
      if !tail.isEmpty {
        await onStdout(tail)
      }
      return CLIExit(
        status: status,
        stderr: String(decoding: stderr, as: UTF8.self),
        stdoutBytes: stdoutBytes,
        stderrBytes: stderrBytes
      )
    } onCancel: {
      child.cancel()
    }
  }
}

/// One spawned process and the descriptors it writes to. The child leads its own process
/// group so termination reaches anything it started. Every mutable field is confined to
/// `queue`, so the event stream sees reads, exit and cancellation in one order.
nonisolated private final class ChildProcess: @unchecked Sendable {
  enum Event: Sendable {
    case stdout(Data)
    case stderr(Data)
    case exit(status: Int32, cancelled: Bool)
  }

  let events: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation
  private let queue = DispatchQueue(label: "com.frank.translate.child-process")
  private let pid: pid_t

  private var readers: [DispatchSourceRead] = []
  private var openReaders = 0
  private var exitSource: DispatchSourceProcess?
  private var status: Int32?
  private var cancelled = false
  private var finished = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  init(_ command: CLICommand) throws {
    (events, continuation) = AsyncStream<Event>.makeStream()
    let stdout = try command.stdoutIsTerminal ? PseudoTerminal.open() : Self.pipe()
    let stderr: (read: Int32, write: Int32)
    do {
      stderr = try Self.pipe()
    } catch {
      close(stdout.read)
      close(stdout.write)
      throw error
    }

    let spawned = Self.spawn(command, stdout: stdout.write, stderr: stderr.write)
    // The child has its own copies now, or failed to start.
    close(stdout.write)
    close(stderr.write)
    guard case .success(let pid) = spawned else {
      close(stdout.read)
      close(stderr.read)
      if case .failure(let code) = spawned {
        throw TranslatorError.launchFailed(code)
      }
      throw TranslatorError.launchFailed(-1)
    }
    self.pid = pid

    queue.sync {
      watch(stdout.read) { .stdout($0) }
      watch(stderr.read) { .stderr($0) }
      let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
      source.setEventHandler { [weak self] in self?.reap() }
      exitSource = source
      source.resume()
    }
    // The process may have exited before the source was armed.
    queue.async { [weak self] in self?.reap() }
  }

  func cancel() {
    queue.async { [self] in
      guard !finished, !cancelled else { return }
      cancelled = true
      if status != nil {
        // Exited already; only stragglers holding the pipes are left.
        closeEverything()
        return
      }
      kill(-pid, SIGTERM)
      queue.asyncAfter(deadline: .now() + CLIProcess.terminationGrace) { [self] in
        guard status == nil else { return }
        kill(-pid, SIGKILL)
        // SIGKILL can't be ignored; the extra wait only covers a process stuck in the kernel.
        queue.asyncAfter(deadline: .now() + CLIProcess.terminationGrace) { [self] in
          guard !finished else { return }
          closeEverything()
          finish(status: 128 + SIGKILL)
        }
      }
    }
  }

  func waitUntilFinished() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        if finished {
          continuation.resume()
        } else {
          finishWaiters.append(continuation)
        }
      }
    }
  }

  // MARK: Queue-confined

  private func watch(_ fd: Int32, as event: @escaping @Sendable (Data) -> Event) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self, weak source] in
      guard let self, let source else { return }
      self.drain(fd, source: source, as: event)
    }
    source.setCancelHandler {
      close(fd)
    }
    readers.append(source)
    openReaders += 1
    source.resume()
  }

  private func drain(_ fd: Int32, source: DispatchSourceRead, as event: (Data) -> Event) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count > 0 {
        continuation.yield(event(Data(buffer[0..<count])))
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN { return }
      // EOF, or EIO from a PTY whose other side closed.
      closeReader(source)
      return
    }
  }

  private func closeReader(_ source: DispatchSourceRead) {
    guard !source.isCancelled else { return }
    source.cancel()
    openReaders -= 1
    finishIfDrained()
  }

  private func reap() {
    guard status == nil else { return }
    var raw: Int32 = 0
    let result = waitpid(pid, &raw, WNOHANG)
    guard result == pid else { return }
    exitSource?.cancel()
    exitSource = nil
    let signal = raw & 0x7f
    status = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
    if cancelled {
      closeEverything()
      return
    }
    queue.asyncAfter(deadline: .now() + CLIProcess.drainGrace) { [self] in
      guard !finished else { return }
      closeEverything()
    }
    finishIfDrained()
  }

  /// Kills whatever is left in the group and closes the pipes without waiting for EOF.
  /// After the leader is reaped the group is only signalled while something still holds a
  /// pipe, because only then is the group ID certain not to have been reused.
  private func closeEverything() {
    if status == nil || openReaders > 0 {
      kill(-pid, SIGKILL)
    }
    for reader in readers where !reader.isCancelled {
      reader.cancel()
    }
    openReaders = 0
    finishIfDrained()
  }

  private func finishIfDrained() {
    guard let status, openReaders == 0 else { return }
    finish(status: status)
  }

  private func finish(status: Int32) {
    guard !finished else { return }
    finished = true
    continuation.yield(.exit(status: status, cancelled: cancelled))
    continuation.finish()
    let waiters = finishWaiters
    finishWaiters = []
    for waiter in waiters {
      waiter.resume()
    }
  }

  // MARK: Spawning

  private static func pipe() throws -> (read: Int32, write: Int32) {
    var fds: [Int32] = [0, 0]
    guard Darwin.pipe(&fds) == 0 else { throw TranslatorError.launchFailed(errno) }
    return (fds[0], fds[1])
  }

  private enum Spawned {
    case success(pid_t)
    case failure(Int32)
  }

  private static func spawn(_ command: CLICommand, stdout: Int32, stderr: Int32) -> Spawned {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, stdout, 1)
    posix_spawn_file_actions_adddup2(&actions, stderr, 2)
    posix_spawn_file_actions_addchdir_np(&actions, command.currentDirectory)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Own process group, only 0–2 inherited, default signal handling and an empty mask.
    posix_spawnattr_setflags(
      &attributes,
      Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
    )
    posix_spawnattr_setpgroup(&attributes, 0)
    var defaults = sigset_t()
    sigfillset(&defaults)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attributes, &mask)

    let argv = ([command.executable] + command.arguments).map { strdup($0) } + [nil]
    let envp = command.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      argv.forEach { free($0) }
      envp.forEach { free($0) }
    }

    var pid: pid_t = 0
    let result = posix_spawn(&pid, command.executable, &actions, &attributes, argv, envp)
    return result == 0 ? .success(pid) : .failure(result)
  }
}

/// A raw-mode PTY pair as plain descriptors: `read` is the master side, `write` the slave.
nonisolated private enum PseudoTerminal {
  static func open() throws -> (read: Int32, write: Int32) {
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    guard master >= 0 else { throw TranslatorError.launchFailed(errno) }
    guard grantpt(master) == 0, unlockpt(master) == 0 else {
      let code = errno
      close(master)
      throw TranslatorError.launchFailed(code)
    }
    var name = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard ptsname_r(master, &name, name.count) == 0 else {
      let code = errno
      close(master)
      throw TranslatorError.launchFailed(code)
    }
    let slave = Darwin.open(name, O_RDWR | O_NOCTTY)
    guard slave >= 0 else {
      let code = errno
      close(master)
      throw TranslatorError.launchFailed(code)
    }
    var window = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(master, UInt(TIOCSWINSZ), &window)
    var term = termios()
    if tcgetattr(slave, &term) == 0 {
      cfmakeraw(&term)
      _ = tcsetattr(slave, TCSANOW, &term)
    }
    _ = fcntl(master, F_SETFD, FD_CLOEXEC)
    _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
    return (master, slave)
  }
}

/// Decodes UTF-8 that arrives in arbitrary chunks, holding back a character split across them.
nonisolated struct UTF8StreamDecoder: Sendable {
  private var pending: [UInt8] = []

  mutating func decode(_ data: Data) -> String {
    pending.append(contentsOf: data)
    let cut = Self.completePrefixLength(pending)
    let text = String(decoding: pending[..<cut], as: UTF8.self)
    pending.removeFirst(cut)
    return text
  }

  /// Whatever is left at EOF, with invalid bytes replaced.
  mutating func finish() -> String {
    defer { pending = [] }
    return String(decoding: pending, as: UTF8.self)
  }

  /// Length of the prefix that doesn't end inside a multi-byte sequence.
  private static func completePrefixLength(_ bytes: [UInt8]) -> Int {
    var index = bytes.count - 1
    let floor = max(0, bytes.count - 4)
    while index >= floor {
      let byte = bytes[index]
      if byte & 0b1100_0000 != 0b1000_0000 {
        let expected = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
        return bytes.count - index < expected ? index : bytes.count
      }
      index -= 1
    }
    return bytes.count
  }
}
