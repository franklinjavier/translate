import Foundation
import Testing
@testable import Translate

struct AppleLanguageMapperTests {
  @Test func mapsEnglishAndBrazilianPortuguese() {
    #expect(AppleLanguageMapper.language(from: "english")?.languageCode?.identifier == "en")
    #expect(AppleLanguageMapper.language(from: "Brazilian Portuguese")?.languageCode?.identifier == "pt")
    #expect(AppleLanguageMapper.language(from: "Portuguese")?.languageCode?.identifier == "pt")
  }

  @Test func detectsEnglishSource() {
    let language = AppleLanguageMapper.detectedLanguage(
      in: "The protocol here is good, and several of its rules are earned lessons."
    )
    #expect(language.map(AppleLanguageMapper.code)?.hasPrefix("en") == true)
  }

  @Test func splitsLongTextIntoSentences() {
    let text = "The first sentence explains the change. The second sentence adds more detail. The third sentence wraps it up."
    let units = TranslationUnits.split(text)
    #expect(units.count >= 2)
    #expect(units.joined() == text || units.joined().contains("First sentence"))
  }

  @Test func sameLanguageGoesToProofreading() {
    #expect(AppleTranslation.isSameLanguage(
      text: "The protocol here is good, and several of its rules are earned lessons.",
      targetLanguage: "english"
    ))
    #expect(!AppleTranslation.isSameLanguage(
      text: "O protocolo aqui é bom, e várias das regras são lições aprendidas.",
      targetLanguage: "english"
    ))
  }

  @Test func keepsShortTextWhole() {
    #expect(TranslationUnits.split("Hello.") == ["Hello."])
  }
}

struct AppleEngineTests {
  /// The Claude path doesn't exist, so a fallback would fail as executableNotFound (or spawn
  /// whatever `claude` is on PATH). Apple must stop first, with its own error.
  @Test func sameLanguageFailsWithoutFallingBackToACLI() async throws {
    let translator = Translator(configuration: EngineConfiguration(
      engine: .apple,
      executableOverride: "/nonexistent/translate-tests/claude",
      model: ""
    ))
    do {
      _ = try await translator.translate(
        text: "This sentence is already written in plain English and only needs a proofread.",
        targetLanguage: "english",
        onOutput: { _ in },
        onPartial: { _ in }
      )
      Issue.record("expected appleUnavailable")
    } catch TranslatorError.appleUnavailable(let message) {
      #expect(message == AppleTranslation.cannotProofreadMessage)
    }
  }

  @Test func everyCatalogDestinationMapsToALocaleIdentifier() throws {
    for language in TranslationLanguage.catalog {
      let mapped = try #require(AppleLanguageMapper.language(from: language.target), "\(language.target)")
      let code = try #require(mapped.languageCode?.identifier, "\(language.target)")
      #expect((2...3).contains(code.count), "\(language.target) → \(code)")
    }
    #expect(AppleLanguageMapper.language(from: "European Portuguese")?.region?.identifier == "PT")
    #expect(AppleLanguageMapper.language(from: "Brazilian Portuguese")?.region?.identifier == "BR")
    #expect(AppleLanguageMapper.language(from: "Simplified Chinese")?.script?.identifier == "Hans")
    #expect(AppleLanguageMapper.language(from: "Traditional Chinese")?.script?.identifier == "Hant")
  }
}
