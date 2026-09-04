import Foundation

nonisolated enum ShellEnvironment {
  static func processEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extras = [
      "\(NSHomeDirectory())/.local/bin",
      "\(NSHomeDirectory())/.volta/bin",
      "\(NSHomeDirectory())/.cargo/bin",
      "\(NSHomeDirectory())/.asdf/shims",
      "/opt/homebrew/bin",
      "/usr/local/bin",
    ]
    let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    env["PATH"] = (extras + [existing]).joined(separator: ":")
    env["HOME"] = NSHomeDirectory()
    env["USER"] = NSUserName()
    env["LOGNAME"] = NSUserName()
    env["TERM"] = "dumb"
    env["NO_COLOR"] = "1"
    return env
  }

  static func resolveExecutable(named name: String, override: String) -> String? {
    let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      let path = (trimmed as NSString).expandingTildeInPath
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }

    let env = processEnvironment()
    let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
    for dir in dirs {
      let path = (dir as NSString).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }
    return nil
  }
}
