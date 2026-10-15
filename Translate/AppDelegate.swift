import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let model = AppModel()

  private var statusItem: NSStatusItem?
  private var settingsWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupStatusItem()
    observeSettingsClose()
    // Test runs host the app; popping the window there would steal focus.
    if !isLaunchedAtLogin() && !isRunningTests() {
      openSettings()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    openSettings()
    return true
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    let localItem = NSMenuItem(
      title: "Use Local MLX",
      action: #selector(useLocalEngine),
      keyEquivalent: ""
    )
    localItem.target = self
    localItem.state = (!model.settings.useAppleOnDeviceModel && model.settings.backend == .local) ? .on : .off
    localItem.toolTip = "Qwen3-4B on 127.0.0.1:8765, streamed"
    menu.addItem(localItem)

    let appleItem = NSMenuItem(
      title: "Use Apple Translate",
      action: #selector(toggleAppleOnDeviceModel),
      keyEquivalent: ""
    )
    appleItem.target = self
    appleItem.state = model.settings.useAppleOnDeviceModel ? .on : .off
    appleItem.toolTip = AppleTranslation.availabilitySummary
    menu.addItem(appleItem)

    menu.addItem(.separator())

    let settingsItem = NSMenuItem(
      title: "Settings…",
      action: #selector(openSettingsClicked),
      keyEquivalent: ","
    )
    settingsItem.keyEquivalentModifierMask = .command
    settingsItem.target = self
    menu.addItem(settingsItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "Quit Translate",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(quitItem)
  }

  @objc func useLocalEngine() {
    model.settings.useAppleOnDeviceModel = false
    model.settings.backend = .local
  }

  @objc func toggleAppleOnDeviceModel() {
    model.settings.useAppleOnDeviceModel.toggle()
  }

  @objc func openSettingsClicked() {
    openSettings()
  }

  @objc func quit() {
    NSApp.terminate(nil)
  }

  func openSettings() {
    let window = makeSettingsWindow()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
  }

  private func makeSettingsWindow() -> NSWindow {
    if let settingsWindow {
      return settingsWindow
    }

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: SettingsView.size),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Translate"
    // Follows the system appearance; the title bar blends into the white or black content.
    window.titlebarAppearsTransparent = true
    window.backgroundColor = .settingsBackground
    window.isMovableByWindowBackground = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.contentView = NSHostingView(rootView: SettingsView(model: model))
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.moveToActiveSpace]
    settingsWindow = window
    return window
  }

  private func observeSettingsClose() {
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: nil,
      queue: .main
    ) { notification in
      guard let window = notification.object as? NSWindow, !(window is OverlayPanel) else { return }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(80))
        let stillVisible = NSApp.windows.contains { $0.isVisible && !($0 is OverlayPanel) }
        if !stillVisible {
          NSApp.setActivationPolicy(.accessory)
        }
      }
    }
  }

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let image = NSImage(named: "MenuBarIcon") {
      image.isTemplate = true
      image.size = NSSize(width: 22, height: 13)
      item.button?.image = image
      item.button?.imagePosition = .imageOnly
    } else {
      item.button?.title = "文A"
      item.button?.font = .systemFont(ofSize: 13, weight: .semibold)
    }
    item.button?.toolTip = "Translate"

    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    statusItem = item
  }

  private func isRunningTests() -> Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  private func isLaunchedAtLogin() -> Bool {
    let loginItemKeyword: AEKeyword = 0x6C696E74 // 'lint'
    return NSAppleEventManager.shared()
      .currentAppleEvent?
      .paramDescriptor(forKeyword: loginItemKeyword)?
      .booleanValue == true
  }
}
