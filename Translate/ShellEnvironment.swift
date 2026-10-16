import Foundation

nonisolated enum ShellEnvironment {
  /// Variables a child CLI may inherit: runtime basics, locale, temp, proxies and
  /// certificates, plus the config roots and credentials the installed CLIs sign in with.
  /// Values pass through untouched and are never read or logged. Everything else is
  /// dropped, including agent session and tool-bridge variables, memory or MCP tokens,
  /// SSH_AUTH_SOCK, and startup hooks like NODE_OPTIONS, BASH_ENV or ZDOTDIR.
  static let inheritedNames: Set<String> = [
    "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "TZ", "LANG", "__CF_USER_TEXT_ENCODING",
    "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME",
    "VOLTA_HOME", "ASDF_DIR", "ASDF_DATA_DIR",
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
    "http_proxy", "https_proxy", "all_proxy", "no_proxy",
    "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
    // Codex
    "CODEX_HOME", "CODEX_API_KEY", "OPENAI_API_KEY", "OPENAI_BASE_URL",
    // Claude, including Bedrock and Vertex sign-in
    "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
    "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION",
    "AWS_PROFILE", "AWS_REGION", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
    "AWS_BEARER_TOKEN_BEDROCK", "GOOGLE_APPLICATION_CREDENTIALS",
  ]

  static func processEnvironment() -> [String: String] {
    childEnvironment(from: ProcessInfo.processInfo.environment)
  }

  /// The environment a child CLI gets when the app's own is `inherited`.
  static func childEnvironment(from inherited: [String: String]) -> [String: String] {
    var env = inherited.filter { inheritedNames.contains($0.key) || $0.key.hasPrefix("LC_") }
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
