import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel
  @State private var accessibilityGranted = TextCapture.isTrusted

  var body: some View {
    TabView {
      languagesTab
        .tabItem { Label("Languages", systemImage: "globe") }
      engineTab
        .tabItem { Label("Engine", systemImage: "cpu") }
    }
    .frame(width: 560, height: 420)
    .onAppear {
      model.settings.launchAtLogin = SMAppService.mainApp.status == .enabled
      accessibilityGranted = TextCapture.isTrusted
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      accessibilityGranted = TextCapture.isTrusted
    }
  }

  private var languagesTab: some View {
    Form {
      Section {
        ForEach($model.settings.targets) { $target in
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
              TextField("Name", text: $target.label)
              Button("Remove", role: .destructive) {
                model.removeTarget(target)
              }
              .disabled(model.settings.targets.count < 2)
            }
            TextField("Translate to", text: $target.language)
            KeyboardShortcuts.Recorder("Shortcut", name: target.shortcutName)
          }
          .padding(.vertical, 4)
        }
        Button("Add language") {
          model.addTarget()
        }
      } footer: {
        Text("The phrase in “Translate to” is sent to the model, e.g. “english” or “Brazilian Portuguese”.")
      }

      Section("Permissions") {
        LabeledContent("Accessibility") {
          HStack {
            Text(accessibilityGranted ? "Granted" : "Required")
              .foregroundStyle(accessibilityGranted ? Color.secondary : Color.orange)
            Button("Open Settings") {
              TextCapture.openAccessibilitySettings()
              TextCapture.promptForTrust()
              accessibilityGranted = TextCapture.isTrusted
            }
          }
        }
      }

      Section {
        Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
          .onChange(of: model.settings.launchAtLogin) { _, _ in
            model.applyLaunchAtLogin()
          }
      }
    }
    .formStyle(.grouped)
    .padding(8)
  }

  private var engineTab: some View {
    Form {
      Section {
        Toggle("Use Apple Translate", isOn: $model.settings.useAppleOnDeviceModel)
      } footer: {
        Text(AppleTranslation.availabilitySummary)
      }

      Section {
        Picker("Engine", selection: $model.settings.backend) {
          ForEach(LLMBackend.allCases) { backend in
            Text(backend.title).tag(backend)
          }
        }
        .pickerStyle(.segmented)
        .disabled(model.settings.useAppleOnDeviceModel)
      } header: {
        Text("Backend")
      } footer: {
        Text("Local streams tokens from 127.0.0.1:8765. If it isn’t running: local-translate-server start")
      }

      Section("Claude") {
        TextField("Model (optional)", text: $model.settings.claudeModel, prompt: Text("sonnet, opus, fable…"))
        TextField("Path (optional)", text: $model.settings.claudePath, prompt: Text("~/.local/bin/claude"))
      }
      .disabled(model.settings.useAppleOnDeviceModel || model.settings.backend == .local)

      Section("Codex") {
        TextField("Model (optional)", text: $model.settings.codexModel, prompt: Text("Leave blank for default"))
        TextField("Path (optional)", text: $model.settings.codexPath, prompt: Text("~/.volta/bin/codex"))
      }
      .disabled(model.settings.useAppleOnDeviceModel || model.settings.backend == .local)
    }
    .formStyle(.grouped)
    .padding(8)
  }
}
