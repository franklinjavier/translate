import Foundation
import NaturalLanguage
import os

#if canImport(Translation)
@preconcurrency import Translation
#endif

nonisolated private let appleLog = Logger(subsystem: "com.frank.translate", category: "apple-translate")

nonisolated enum AppleTranslation {
  static var availabilitySummary: String {
    if #available(macOS 26.0, *) {
      return "Apple Translate (on-device). Same engine as the Translate app."
    }
    return "Requires macOS 26."
  }

  static func translate(
    text: String,
    targetLanguage: String,
    onOutput: @escaping @Sendable (String) async -> Void,
    onPartial: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    if #available(macOS 26.0, *) {
      return try await translateWithSession(
        text: text,
        targetLanguage: targetLanguage,
        onOutput: onOutput,
        onPartial: onPartial
      )
    }
    throw TranslatorError.appleUnavailable("Requires macOS 26.")
  }

  @available(macOS 26.0, *)
  private static func translateWithSession(
    text: String,
    targetLanguage: String,
    onOutput: @escaping @Sendable (String) async -> Void,
    onPartial: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let clock = DebugClock()
    func trace(_ message: String) async {
      appleLog.info("\(message, privacy: .public)")
      await onOutput(clock.line(message))
    }

    await trace("Apple Translate (TranslationSession)")

    guard let target = AppleLanguageMapper.language(from: targetLanguage) else {
      await trace("unmapped target “\(targetLanguage)”")
      throw TranslatorError.appleUnavailable(
        "Don’t know how to map “\(targetLanguage)” to an Apple language."
      )
    }

    guard let source = AppleLanguageMapper.detectedLanguage(in: text) else {
      await trace("could not detect source language")
      throw TranslatorError.appleUnavailable("Couldn’t detect the source language.")
    }

    await trace("source=\(AppleLanguageMapper.code(source)) target=\(AppleLanguageMapper.code(target))")

    if AppleLanguageMapper.sameLanguage(source, target) {
      await trace("source equals target, skipping")
      await onPartial(text)
      return text
    }

    let availability = LanguageAvailability()
    let status = await availability.status(from: source, to: target)
    switch status {
    case .installed:
      await trace("status=installed")
    case .supported:
      await trace("status=supported (not downloaded)")
      throw TranslatorError.appleUnavailable(
        "Download \(AppleLanguageMapper.code(source)) → \(AppleLanguageMapper.code(target)) in the Translate app, then try again."
      )
    case .unsupported:
      await trace("status=unsupported")
      throw TranslatorError.appleUnavailable(
        "Apple Translate doesn’t support \(AppleLanguageMapper.code(source)) → \(AppleLanguageMapper.code(target))."
      )
    @unknown default:
      await trace("status=unknown")
      throw TranslatorError.appleUnavailable("Apple Translate isn’t available for this language pair.")
    }

    let session = makeSession(source: source, target: target)
    if #available(macOS 26.4, *) {
      await trace("strategy=\(session.preferredStrategy == .highFidelity ? "highFidelity" : "lowLatency")")
    }

    do {
      await trace("prepareTranslation")
      try await session.prepareTranslation()
      let units = TranslationUnits.split(text)
      await trace("translate \(units.count) unit\(units.count == 1 ? "" : "s")")
      let translated = try await translateUnits(units, session: session, onPartial: onPartial)
      await trace("done \(translated.count) chars, \(clock.rate(characters: translated.count))")
      return translated
    } catch TranslationError.notInstalled {
      await trace("error=notInstalled")
      throw TranslatorError.appleUnavailable(
        "Download this language pair in the Translate app, then try again."
      )
    } catch {
      await trace("error: \(error.localizedDescription)")
      throw error
    }
  }

  @available(macOS 26.0, *)
  private static func makeSession(
    source: Locale.Language,
    target: Locale.Language
  ) -> TranslationSession {
    if #available(macOS 26.4, *) {
      TranslationSession(
        installedSource: source,
        target: target,
        preferredStrategy: .highFidelity
      )
    } else {
      TranslationSession(installedSource: source, target: target)
    }
  }

  @available(macOS 26.0, *)
  private static func translateUnits(
    _ units: [String],
    session: TranslationSession,
    onPartial: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    guard units.count > 1 else {
      let response = try await session.translate(units[0])
      await onPartial(response.targetText)
      return response.targetText
    }

    let requests = units.enumerated().map { index, unit in
      TranslationSession.Request(sourceText: unit, clientIdentifier: String(index))
    }
    var parts = [String?](repeating: nil, count: units.count)
    var visibleUntil = 0
    var displayed = ""

    for try await response in session.translate(batch: requests) {
      guard
        let identifier = response.clientIdentifier,
        let index = Int(identifier),
        parts.indices.contains(index)
      else { continue }
      parts[index] = response.targetText
      while visibleUntil < parts.count, let piece = parts[visibleUntil] {
        displayed += piece
        visibleUntil += 1
        await onPartial(displayed)
      }
    }

    if visibleUntil < parts.count {
      let response = try await session.translate(units.joined())
      await onPartial(response.targetText)
      return response.targetText
    }
    return displayed
  }
}

nonisolated enum TranslationUnits {
  static func split(_ text: String) -> [String] {
    guard text.count >= 80 else { return [text] }
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    var units: [String] = []
    var cursor = text.startIndex
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      units.append(String(text[cursor..<range.upperBound]))
      cursor = range.upperBound
      return true
    }
    if cursor < text.endIndex {
      units.append(String(text[cursor...]))
    }
    let trimmed = units.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return trimmed.isEmpty ? [text] : trimmed
  }
}

nonisolated enum AppleLanguageMapper {
  static func language(from phrase: String) -> Locale.Language? {
    let key = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !key.isEmpty else { return nil }
    if let identifier = aliases[key] {
      return Locale.Language(identifier: identifier)
    }
    return Locale.Language(identifier: phrase.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func detectedLanguage(in text: String) -> Locale.Language? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
    return Locale.Language(identifier: code)
  }

  static func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
    a.languageCode?.identifier == b.languageCode?.identifier
  }

  static func code(_ language: Locale.Language) -> String {
    language.maximalIdentifier
  }

  private static let aliases: [String: String] = [
    "english": "en",
    "en": "en",
    "portuguese": "pt-BR",
    "brazilian portuguese": "pt-BR",
    "português": "pt-BR",
    "português brasileiro": "pt-BR",
    "portugues": "pt-BR",
    "pt": "pt-BR",
    "pt-br": "pt-BR",
    "french": "fr",
    "français": "fr",
    "spanish": "es",
    "español": "es",
    "german": "de",
    "deutsch": "de",
    "italian": "it",
    "japanese": "ja",
    "korean": "ko",
    "chinese": "zh-Hans",
    "simplified chinese": "zh-Hans",
    "traditional chinese": "zh-Hant",
  ]
}

nonisolated struct DebugClock: Sendable {
  let started = ContinuousClock.now

  var elapsedMilliseconds: Int {
    Int((ContinuousClock.now - started) / .milliseconds(1))
  }

  func line(_ message: String) -> String {
    String(format: "[%4dms] %@\n", elapsedMilliseconds, message)
  }

  func rate(characters: Int) -> String {
    let seconds = max(Double(elapsedMilliseconds) / 1000, 0.001)
    return String(format: "%.1f chars/s", Double(characters) / seconds)
  }
}
