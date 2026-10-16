import AppKit
import KeyboardShortcuts
import os
import ServiceManagement
import SwiftUI

private let log = Logger(subsystem: "com.frank.translate", category: "app")

@Observable
final class AppModel {
  var settings: AppSettings {
    didSet {
      guard isLive, settings != oldValue else { return }
      settings.save()
    }
  }

  let overlay: OverlayState

  /// False keeps settings in memory and leaves global shortcuts, the selection tracker,
  /// the pasteboard and login items alone, for tests and offscreen snapshots.
  let isLive: Bool
  private let panel: OverlayPanel
  @ObservationIgnored private let session: TranslationCoordinator
  private var registeredIDs: Set<UUID> = []

  convenience init() {
    self.init(settings: .load(), isLive: true)
  }

  /// `coordinator` replaces the one wired to the panel and live boundaries, for tests.
  init(settings: AppSettings, isLive: Bool, coordinator: TranslationCoordinator? = nil) {
    let panel = OverlayPanel()
    let session = coordinator ?? TranslationCoordinator(
      overlay: OverlayState(),
      presenter: panel,
      boundaries: isLive ? Self.liveBoundaries() : Self.inertBoundaries
    )
    panel.state = session.overlay
    self.settings = settings
    self.isLive = isLive
    self.overlay = session.overlay
    self.panel = panel
    self.session = session
    panel.onCopy = { [weak self] in self?.copyTranslation() }
    panel.onReplace = { [weak self] in self?.session.replace() }
    panel.onClose = { [weak self] in self?.session.dismiss() }
    panel.onOpenAccessibility = { TextCapture.openAccessibilitySettings() }
    panel.onRetry = { [weak self] in self?.retryLastTranslation() }
    guard isLive else { return }
    TextCapture.startTrackingSelections { [weak self] event in
      self?.isTranslateShortcut(event) ?? false
    }
    installDefaultShortcuts()
    registerHotkeys()
  }

  func translate(toID id: UUID) {
    guard let target = settings.targets.first(where: { $0.id == id }) else { return }
    translate(to: target)
  }

  /// Snapshots the engine settings now; changing them mid-translation affects the next one.
  func translate(to target: TranslationTarget) {
    session.translate(to: target, configuration: settings.engineConfiguration)
  }

  func retryLastTranslation() {
    session.retry(configuration: settings.engineConfiguration)
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

  @discardableResult
  func addTarget(_ language: TranslationLanguage) -> UUID {
    let target = settings.addTarget(language)
    registerHotkeys()
    return target.id
  }

  /// Binds a settings row by ID, never by array index; see `AppSettings[targetID:fallback:]`.
  func targetBinding(for target: TranslationTarget) -> Binding<TranslationTarget> {
    Bindable(self).settings[targetID: target.id, fallback: target]
  }

  /// Unknown IDs and the last language are left alone.
  func removeTarget(id: UUID) {
    guard let removed = settings.removeTarget(id: id) else { return }
    guard isLive else { return }
    KeyboardShortcuts.removeHandler(for: removed.shortcutName)
    KeyboardShortcuts.setShortcut(nil, for: removed.shortcutName)
    registerHotkeys()
  }

  func registerHotkeys() {
    guard isLive else { return }
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

  /// The toggle mirrors the system's login item, which the user can change in System Settings.
  func syncLaunchAtLogin() {
    guard isLive else { return }
    settings.launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  func applyLaunchAtLogin() {
    guard isLive else { return }
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

  private static func liveBoundaries() -> SessionBoundaries {
    let clipboard = ClipboardTransactions.live()
    let replacer = SelectionReplacer(
      frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
      clipboard: clipboard
    )
    return SessionBoundaries(
      anchor: invocationAnchor,
      isTrusted: { TextCapture.isTrusted },
      capture: {
        if !TextCapture.isTrusted {
          TextCapture.promptForTrust()
        }
        return try await TextCapture.capture(using: clipboard)
      },
      translate: { request, onPartial in
        try await Translator(configuration: request.configuration).translate(
          text: request.selection.text,
          targetLanguage: request.target.language,
          onOutput: { _ in },
          onPartial: { partial in await onPartial(partial) }
        )
      },
      replace: { selection, translation in
        try await replacer.replace(selection, with: translation)
      }
    )
  }

  /// Offline: nothing is read from or written to other apps.
  private static let inertBoundaries = SessionBoundaries(
    anchor: { .point(.zero) },
    isTrusted: { true },
    capture: { .empty },
    translate: { _, _ in throw CancellationError() },
    replace: { _, _ in .failed(.selectionChanged) }
  )

  /// Accessibility bounds first, the tracked mouse selection when the app hides them,
  /// and the pointer only when neither knows where the text is.
  private static func invocationAnchor() -> OverlayAnchor {
    let screens = OverlayPanel.currentScreens()
    var accessibilityRect: CGRect?
    if TextCapture.isTrusted,
       let primary = NSScreen.screens.first,
       let bounds = TextCapture.selectionBounds() {
      let rect = OverlayPlacement.appKitRect(
        fromAccessibility: bounds,
        primaryScreenHeight: primary.frame.maxY
      )
      if OverlayPlacement.isUsable(rect, on: screens) {
        accessibilityRect = rect
      }
    }
    let dragRect = TextCapture.trackedSelectionRect().flatMap {
      OverlayPlacement.isUsable($0, on: screens) ? $0 : nil
    }
    if let rect = SelectionGeometry.anchorRect(accessibility: accessibilityRect, drag: dragRect) {
      return .selection(rect)
    }
    return .point(NSEvent.mouseLocation)
  }

  private func isTranslateShortcut(_ event: NSEvent) -> Bool {
    guard let pressed = KeyboardShortcuts.Shortcut(event: event) else { return false }
    return settings.targets.contains { KeyboardShortcuts.getShortcut(for: $0.shortcutName) == pressed }
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

  /// Only a finished translation can replace the selection; a partial one would cut it short.
  var canReplace: Bool {
    if case .result = phase { return true }
    return false
  }

  func showPartial(target: TranslationTarget, source: String, translation: String) {
    guard !translation.isEmpty else { return }
    phase = .streaming(target: target, source: source, translation: translation)
  }
}
