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

  static let size = CGSize(width: 520, height: 560)

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
      "Languages",
      footer: "Each shortcut translates the selection into its row’s language. Names are only for you."
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
      captionRow("Runs the Claude CLI on this Mac. Leave Model blank for its default.")
      SettingsDivider()
      fieldRow("Model", text: $model.settings.claudeModel, prompt: "sonnet, opus, fable…")
      SettingsDivider()
      fieldRow("Path", text: $model.settings.claudePath, prompt: "~/.local/bin/claude")
    case .codex:
      captionRow("Runs the Codex CLI on this Mac. Leave Model blank for its default.")
      SettingsDivider()
      fieldRow("Model", text: $model.settings.codexModel, prompt: "Leave blank for default")
      SettingsDivider()
      fieldRow("Path", text: $model.settings.codexPath, prompt: "~/.volta/bin/codex")
    }
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

/// Name → destination, shortcut, remove. Bound by ID through `AppModel.targetBinding(for:)`.
private struct LanguageRow: View {
  @Binding var target: TranslationTarget
  var canRemove: Bool
  var onRemove: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      SettingsField(label: "Name", prompt: "Name", text: $target.label)
        .frame(width: 110)
      Image(systemName: "arrow.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.primary.opacity(0.35))
        .accessibilityHidden(true)
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
      .controlSize(.small)
      .frame(maxWidth: .infinity)
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
