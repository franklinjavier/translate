import KeyboardShortcuts
import SwiftUI

extension NSColor {
  /// Pure white in light mode, pure black in dark mode. Shared by the settings window and its content
  /// so the transparent title bar blends into the screen in either appearance.
  static let settingsBackground = NSColor(
    name: "SettingsBackground",
    dynamicProvider: resolveSettingsBackground(for:)
  )

  /// Nonisolated because AppKit may resolve dynamic colors off the main thread.
  private nonisolated static func resolveSettingsBackground(for appearance: NSAppearance) -> NSColor {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
  }
}

/// One compact screen styled like the popover: languages, then engine, then permissions.
/// Follows the system appearance; the popover stays black on its own.
struct SettingsView: View {
  @Bindable var model: AppModel
  @State private var accessibilityGranted = TextCapture.isTrusted

  static let size = CGSize(width: 460, height: 600)

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
        languagesSection
        engineSection
        generalSection
      }
      .padding(.horizontal, SettingsMetrics.outerPadding)
      .padding(.top, 6)
      .padding(.bottom, SettingsMetrics.outerPadding)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .background(Color(nsColor: .settingsBackground))
    .onAppear {
      model.syncLaunchAtLogin()
      accessibilityGranted = TextCapture.isTrusted
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      accessibilityGranted = TextCapture.isTrusted
    }
  }

  // MARK: Sections

  private var languagesSection: some View {
    SettingsSection(
      "Translate to",
      footer: "Pick a language and record a shortcut. The shortcut translates the selection into that language."
    ) {
      // Rows are keyed and bound by ID. A row still on screen after its language is removed
      // reads its last snapshot instead of indexing past the end of `targets`.
      ForEach(model.settings.targets) { target in
        LanguageRow(
          target: model.targetBinding(for: target),
          canRemove: model.settings.canRemoveTarget,
          onRemove: { model.removeTarget(id: target.id) }
        )
        SettingsDivider()
      }
      Menu {
        ForEach(TranslationLanguage.catalog) { language in
          Button(language.name) {
            model.addTarget(language)
          }
        }
      } label: {
        Label("Add language", systemImage: "plus")
          .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
          .foregroundStyle(Color.primary.opacity(0.8))
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .padding(.horizontal, SettingsMetrics.rowPadding)
      .padding(.vertical, 10)
    }
  }

  private var engineSection: some View {
    SettingsSection("Engine") {
      SettingsRow {
        Text("Translate with")
          .font(.system(size: SettingsMetrics.bodySize))
        Spacer(minLength: 12)
        Picker("Engine", selection: $model.settings.engine) {
          ForEach(TranslationEngine.allCases) { engine in
            Text(engine.title).tag(engine)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      SettingsDivider()
      engineDetails
    }
    // Restarts when the engine or path changes, cancelling a query for the old one. The pause
    // keeps a path being typed from launching a CLI per keystroke.
    .task(id: modelQuery) {
      guard let engine = modelQuery?.engine else { return }
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      await model.loadModels(for: engine)
    }
  }

  private struct ModelQuery: Equatable {
    var engine: TranslationEngine
    var path: String
  }

  private var modelQuery: ModelQuery? {
    switch model.settings.engine {
    case .claude: ModelQuery(engine: .claude, path: model.settings.claudePath)
    case .codex: ModelQuery(engine: .codex, path: model.settings.codexPath)
    case .local, .apple: nil
    }
  }

  /// Only what the selected engine uses: Claude and Codex get their model and path,
  /// Local and Apple only an explanation.
  @ViewBuilder
  private var engineDetails: some View {
    switch model.settings.engine {
    case .local:
      captionRow("Runs on this Mac and streams from 127.0.0.1:8765. If it isn’t running: local-translate-server start")
    case .apple:
      captionRow("\(AppleTranslation.availabilitySummary) Translates between languages only; it can’t proofread text already in the target language.")
    case .claude:
      captionRow("Runs the Claude CLI on this Mac.")
      SettingsDivider()
      modelRows(.claude, selection: $model.settings.claudeModel, path: model.settings.claudePath)
      SettingsDivider()
      fastRow(.claude, isOn: $model.settings.claudeFast)
      SettingsDivider()
      fieldRow("Path", text: $model.settings.claudePath, prompt: "~/.local/bin/claude")
    case .codex:
      captionRow("Runs the Codex CLI on this Mac.")
      SettingsDivider()
      modelRows(.codex, selection: $model.settings.codexModel, path: model.settings.codexPath)
      SettingsDivider()
      fastRow(.codex, isOn: $model.settings.codexFast)
      SettingsDivider()
      fieldRow("Path", text: $model.settings.codexPath, prompt: "~/.volta/bin/codex")
    }
  }

  /// The CLI's own list once it has answered. Until then, or if it can't, the CLI default and
  /// the saved model stay selectable; a saved model the list doesn't have stays as written.
  @ViewBuilder
  private func modelRows(_ engine: TranslationEngine, selection: Binding<String>, path: String) -> some View {
    let state = model.models.state(for: engine, override: path)
    let picker = CLIModelCatalog.picker(state.catalog, selected: selection.wrappedValue)
    SettingsRow {
      Text("Model")
        .font(.system(size: SettingsMetrics.bodySize))
        .frame(width: 56, alignment: .leading)
      Picker("Model", selection: pickOnly(selection)) {
        if let saved = picker.saved {
          Text(saved.name).tag(saved.id)
          Divider()
        }
        ForEach(picker.options) { option in
          Text(option.name).tag(option.id)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .font(.system(size: 14))
      .controlSize(.regular)
      .frame(maxWidth: .infinity, alignment: .leading)
      if state.isLoading {
        ProgressView()
          .controlSize(.small)
          .frame(width: 16, height: 16)
      } else {
        Button {
          Task { await model.loadModels(for: engine, force: true) }
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.6))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Refresh models")
        .accessibilityLabel("Refresh models")
      }
    }
    if let failure = state.failure {
      captionRow(state.catalog == nil ? failure : "\(failure) Showing the last list.")
    }
  }

  /// Writes only a real change, so a menu showing the same entry never rewrites the setting.
  private func pickOnly(_ selection: Binding<String>) -> Binding<String> {
    Binding(
      get: { selection.wrappedValue },
      set: { if $0 != selection.wrappedValue { selection.wrappedValue = $0 } }
    )
  }

  /// The saved preference, shown on only while the selected model can use it. Picking a
  /// model without Fast never changes the preference or the model.
  private func fastRow(_ engine: TranslationEngine, isOn preference: Binding<Bool>) -> some View {
    let available = model.isFastAvailable(for: engine)
    return SettingsRow {
      VStack(alignment: .leading, spacing: 2) {
        Text("Fast")
          .font(.system(size: SettingsMetrics.bodySize))
        Text(fastHint(engine, available: available))
          .font(.system(size: SettingsMetrics.captionSize))
          .foregroundStyle(Color.primary.opacity(SettingsMetrics.captionOpacity))
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      Toggle("Fast", isOn: Binding(
        get: { available && preference.wrappedValue },
        set: { preference.wrappedValue = $0 }
      ))
      .toggleStyle(.switch)
      .labelsHidden()
      .controlSize(.small)
      .disabled(!available)
    }
  }

  private func fastHint(_ engine: TranslationEngine, available: Bool) -> String {
    let path = engine == .claude ? model.settings.claudePath : model.settings.codexPath
    guard available else {
      return model.models.catalog(for: engine, override: path) == nil
        ? "Available once the CLI lists its models."
        : "Not available for this model."
    }
    return engine == .claude
      ? "Billed as extra usage, outside your plan’s limits."
      : "Uses more of your plan’s usage."
  }

  private func captionRow(_ text: String) -> some View {
    SettingsRow {
      Text(text)
        .font(.system(size: SettingsMetrics.captionSize))
        .foregroundStyle(Color.primary.opacity(SettingsMetrics.captionOpacity))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  private var generalSection: some View {
    SettingsSection("General") {
      SettingsRow {
        Text("Accessibility")
          .font(.system(size: SettingsMetrics.bodySize))
        Spacer(minLength: 12)
        Text(accessibilityGranted ? "Granted" : "Required")
          .font(.system(size: SettingsMetrics.captionSize, weight: .medium))
          .foregroundStyle(accessibilityGranted ? Color.primary.opacity(SettingsMetrics.captionOpacity) : Color.orange)
        Button("Open Settings") {
          TextCapture.openAccessibilitySettings()
          TextCapture.promptForTrust()
          accessibilityGranted = TextCapture.isTrusted
        }
        .controlSize(.small)
      }
      SettingsDivider()
      SettingsRow {
        Text("Launch at login")
          .font(.system(size: SettingsMetrics.bodySize))
        Spacer(minLength: 12)
        Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
          .toggleStyle(.switch)
          .labelsHidden()
          .controlSize(.small)
          .onChange(of: model.settings.launchAtLogin) { _, _ in
            model.applyLaunchAtLogin()
          }
      }
    }
  }

  private func fieldRow(_ label: String, text: Binding<String>, prompt: String) -> some View {
    SettingsRow {
      Text(label)
        .font(.system(size: SettingsMetrics.bodySize))
        .frame(width: 56, alignment: .leading)
      SettingsField(label: label, prompt: prompt, text: text)
    }
  }
}

/// Destination, shortcut, remove. Bound by ID through `AppModel.targetBinding(for:)`.
private struct LanguageRow: View {
  @Binding var target: TranslationTarget
  var canRemove: Bool
  var onRemove: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Picker("Translate to", selection: destination) {
        if target.isLegacyLanguage {
          // A destination saved before the picker existed stays selected, as written.
          Text(target.language).tag(target.language)
          Divider()
        }
        ForEach(TranslationLanguage.catalog) { language in
          Text(language.name).tag(language.target)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .font(.system(size: 14))
      .controlSize(.regular)
      .frame(maxWidth: .infinity, alignment: .leading)
      KeyboardShortcuts.Recorder(for: target.shortcutName)
        .fixedSize()
      Button(action: onRemove) {
        Image(systemName: "minus.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(Color.primary.opacity(canRemove ? 0.55 : 0.2))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!canRemove)
      .help(canRemove ? "Remove \(target.label)" : "Keep at least one language")
      .accessibilityLabel("Remove \(target.label)")
    }
    .padding(.horizontal, SettingsMetrics.rowPadding)
    .padding(.vertical, 8)
  }

  /// Only catalog picks write; reselecting the legacy entry leaves the row as it was.
  private var destination: Binding<String> {
    Binding(
      get: { target.language },
      set: { newValue in
        guard newValue != target.language, let language = TranslationLanguage.entry(for: newValue) else { return }
        target.setDestination(language)
      }
    )
  }
}

private struct SettingsSection<Content: View>: View {
  var title: String
  var footer: String?
  @ViewBuilder var content: Content

  init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(.system(size: SettingsMetrics.captionSize, weight: .semibold))
        .foregroundStyle(Color.primary.opacity(SettingsMetrics.captionOpacity))
        .padding(.leading, 4)
      VStack(spacing: 0) {
        content
      }
      .background(
        RoundedRectangle(cornerRadius: PopoverMetrics.cornerRadius, style: .continuous)
          .fill(Color.primary.opacity(0.05))
      )
      .overlay(
        RoundedRectangle(cornerRadius: PopoverMetrics.cornerRadius, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
      )
      if let footer {
        Text(footer)
          .font(.system(size: SettingsMetrics.captionSize))
          .foregroundStyle(Color.primary.opacity(SettingsMetrics.captionOpacity))
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
    }
  }
}

private struct SettingsRow<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    HStack(spacing: 8) {
      content
    }
    .padding(.horizontal, SettingsMetrics.rowPadding)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SettingsField: View {
  var label: String
  var prompt: String
  @Binding var text: String

  var body: some View {
    TextField(label, text: $text, prompt: Text(prompt))
      .textFieldStyle(.plain)
      .font(.system(size: SettingsMetrics.bodySize))
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.primary.opacity(0.08))
      )
  }
}

private struct SettingsDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.08))
      .frame(height: 1)
      .padding(.leading, SettingsMetrics.rowPadding)
  }
}

private enum SettingsMetrics {
  static let outerPadding: CGFloat = 16
  static let sectionSpacing: CGFloat = 20
  static let rowPadding: CGFloat = 12
  static let bodySize: CGFloat = 13
  static let captionSize: CGFloat = 11
  static let captionOpacity: Double = 0.55
}
