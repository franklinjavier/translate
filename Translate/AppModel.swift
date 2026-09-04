import AppKit
import KeyboardShortcuts
import os
import ServiceManagement
import SwiftUI

private let log = Logger(subsystem: "com.frank.translate", category: "app")

@Observable
final class AppModel {
  var settings: AppSettings {
    didSet { settings.save() }
  }

  var overlay = OverlayState()

  private let panel = OverlayPanel()
  private var translationTask: Task<Void, Never>?
  private var translationGeneration = 0
  private var registeredIDs: Set<UUID> = []

  init() {
    settings = .load()
    panel.state = overlay
    panel.onCopy = { [weak self] in self?.copyTranslation() }
    panel.onReplace = { [weak self] in self?.replaceSelection() }
    panel.onClose = { [weak self] in self?.dismissOverlay() }
    panel.onOpenAccessibility = { TextCapture.openAccessibilitySettings() }
    panel.onRetry = { [weak self] in self?.retryLastTranslation() }
    installDefaultShortcuts()
    registerHotkeys()
  }

  func translate(toID id: UUID) {
    guard let target = settings.targets.first(where: { $0.id == id }) else { return }
    translate(to: target)
  }

  private var lastTarget: TranslationTarget?

  func retryLastTranslation() {
    guard let lastTarget else { return }
    translate(to: lastTarget)
  }

  func translate(to target: TranslationTarget) {
    lastTarget = target
    translationGeneration += 1
    let generation = translationGeneration
    translationTask?.cancel()
    overlay.copiedRecently = false
    overlay.replacedRecently = false
    overlay.phase = .loading(target: target, source: "")
    panel.presentUnfocused()

    translationTask = Task { [weak self] in
      guard let self else { return }

      if !TextCapture.isTrusted {
        TextCapture.promptForTrust()
      }

      let source = await TextCapture.selectedText()

      if let source {
        self.overlay.phase = .loading(target: target, source: source)
        self.panel.relayout()

        do {
          let translator = Translator(
            backend: self.settings.backend,
            executableOverride: self.settings.activeExecutableOverride,
            model: self.settings.activeModel,
            useAppleOnDeviceModel: self.settings.useAppleOnDeviceModel
          )
          let translation = try await translator.translate(
            text: source,
            targetLanguage: target.language,
            onOutput: { _ in },
            onPartial: { [weak self, generation] partial in
              await MainActor.run {
                guard let self, generation == self.translationGeneration else { return }
                self.overlay.showPartial(target: target, source: source, translation: partial)
                self.panel.relayout(animated: true)
              }
            }
          )
          self.finish(
            generation: generation,
            phase: .result(target: target, source: source, translation: translation)
          )
        } catch is CancellationError {
          return
        } catch {
          log.error("Translation failed: \(error.localizedDescription, privacy: .public)")
          self.finish(
            generation: generation,
            phase: .error(message: error.localizedDescription, recovery: .openSettings)
          )
        }
        return
      }

      if !TextCapture.isTrusted {
        self.finish(
          generation: generation,
          phase: .error(
            message: "macOS has not granted Accessibility to this copy of Translate yet. Turn Translate off and on in Accessibility, then click Try again.",
            recovery: .openAccessibility
          )
        )
        self.watchAccessibilityGrant(generation: generation)
        return
      }

      self.finish(
        generation: generation,
        phase: .error(
          message: "No text selected. Highlight something, then press the shortcut again.",
          recovery: nil
        )
      )
    }
  }

  func dismissOverlay() {
    translationGeneration += 1
    translationTask?.cancel()
    overlay.copiedRecently = false
    overlay.replacedRecently = false
    overlay.phase = .hidden
    panel.orderOut(nil)
  }

  func copyTranslation() {
    guard let translation = overlay.currentTranslation() else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(translation, forType: .string)
    overlay.copiedRecently = true
    overlay.replacedRecently = false
    Task {
      try? await Task.sleep(for: .seconds(1.4))
      overlay.copiedRecently = false
    }
  }

  func replaceSelection() {
    guard let translation = overlay.currentTranslation() else { return }
    overlay.replacedRecently = true
    overlay.copiedRecently = false
    let original = overlay.capturedSource()
    Task {
      _ = await TextCapture.replaceSelectedText(with: translation, matching: original)
      await MainActor.run {
        self.dismissOverlay()
      }
    }
  }

  func addTarget() {
    settings.targets.append(
      TranslationTarget(id: UUID(), label: "New language", language: "French")
    )
    registerHotkeys()
  }

  func removeTarget(_ target: TranslationTarget) {
    guard settings.targets.count > 1 else { return }
    KeyboardShortcuts.removeHandler(for: target.shortcutName)
    KeyboardShortcuts.setShortcut(nil, for: target.shortcutName)
    settings.targets.removeAll { $0.id == target.id }
    registerHotkeys()
  }

  func registerHotkeys() {
    let currentIDs = Set(settings.targets.map(\.id))
    for id in registeredIDs where !currentIDs.contains(id) {
      let name = KeyboardShortcuts.Name("translate.\(id.uuidString)")
      KeyboardShortcuts.removeHandler(for: name)
    }

    for target in settings.targets {
      let name = target.shortcutName
      KeyboardShortcuts.removeHandler(for: name)
      let id = target.id
      KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
        Task { @MainActor in
          self?.translate(toID: id)
        }
      }
    }
    registeredIDs = currentIDs
  }

  func applyLaunchAtLogin() {
    let service = SMAppService.mainApp
    do {
      if settings.launchAtLogin {
        try service.register()
      } else if service.status == .enabled {
        try service.unregister()
      }
    } catch {
      log.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func finish(generation: Int, phase: OverlayState.Phase) {
    guard generation == translationGeneration else { return }
    overlay.copiedRecently = false
    overlay.replacedRecently = false
    overlay.phase = phase
    panel.relayout()
  }

  private func watchAccessibilityGrant(generation: Int) {
    Task { [weak self] in
      for _ in 0..<60 {
        try? await Task.sleep(for: .milliseconds(500))
        guard let self, generation == self.translationGeneration else { return }
        if TextCapture.isTrusted {
          self.finish(
            generation: generation,
            phase: .error(
              message: "Accessibility is on. Select some text and press the shortcut again.",
              recovery: nil
            )
          )
          return
        }
      }
    }
  }

  private func installDefaultShortcuts() {
    _ = KeyboardShortcuts.Name(
      "translate.\(TranslationTarget.englishID.uuidString)",
      initial: .init(.i, modifiers: [.command, .option])
    )
    _ = KeyboardShortcuts.Name(
      "translate.\(TranslationTarget.portugueseID.uuidString)",
      initial: .init(.u, modifiers: [.command, .option])
    )
  }
}

@Observable
final class OverlayState {
  enum Recovery: Equatable {
    case openAccessibility
    case openSettings
  }

  enum Phase: Equatable {
    case hidden
    case loading(target: TranslationTarget, source: String)
    case streaming(target: TranslationTarget, source: String, translation: String)
    case result(target: TranslationTarget, source: String, translation: String)
    case error(message: String, recovery: Recovery?)
  }

  var phase: Phase = .hidden
  var copiedRecently = false
  var replacedRecently = false

  func currentTranslation() -> String? {
    switch phase {
    case .streaming(_, _, let translation), .result(_, _, let translation):
      return translation
    case .hidden, .loading, .error:
      return nil
    }
  }

  func capturedSource() -> String? {
    switch phase {
    case .loading(_, let source), .streaming(_, let source, _), .result(_, let source, _):
      return source.isEmpty ? nil : source
    case .hidden, .error:
      return nil
    }
  }

  func showPartial(target: TranslationTarget, source: String, translation: String) {
    guard !translation.isEmpty else { return }
    phase = .streaming(target: target, source: source, translation: translation)
  }
}
