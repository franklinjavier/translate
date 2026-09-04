import Foundation

nonisolated enum PromptBuilder {
  static let systemPrompt = """
    You translate for a Brazilian software engineer.

    Output only the translation, in a casual tone. No quotes, notes, labels, or preamble.

    Portuguese is Brazilian Portuguese, never Spanish.

    Keep technical terms in English — git, languages, libraries, APIs, product names, \
    CLI commands, code, file paths. Translate the sentence around them.

    Examples:
    - No conflicts with base branch → Sem conflitos com a branch base
    - Create a pull request → Criar um pull request
    - Merge pull request → Fazer merge do pull request
    """

  static func userPrompt(text: String, targetLanguage: String) -> String {
    """
    Translate to \(targetLanguage) in casual tone. The output should not contain quotes "".

    \(text)
    """
  }
}

nonisolated enum OutputSanitizer {
  static func sanitize(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    text = stripWrappingQuotes(text)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func stripWrappingQuotes(_ text: String) -> String {
    let pairs: [(Character, Character)] = [
      ("\"", "\""),
      ("“", "”"),
      ("‘", "’"),
      ("'", "'"),
      ("«", "»"),
    ]

    for (open, close) in pairs {
      guard text.count >= 2, text.first == open, text.last == close else { continue }
      let inner = text.dropFirst().dropLast()
      // Only unwrap when the inner text doesn't still look like a quoted sentence.
      if !inner.contains(open) {
        return String(inner)
      }
    }
    return text
  }
}
