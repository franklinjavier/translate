import AppKit
import KeyboardShortcuts
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let model = AppModel()

  private var statusItem: NSStatusItem?
  private var settingsWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupStatusItem()
    observeSettingsClose()
    if !isLaunchedAtLogin() {
      openSettings()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    openSettings()
    return true
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    for target in model.settings.targets {
      let item = NSMenuItem(
        title: "Translate to \(target.label)",
        action: #selector(translateFromMenu(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = target.id.uuidString
      item.setShortcut(for: target.shortcutName)
      menu.addItem(item)
    }

    menu.addItem(.separator())

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

  @objc func translateFromMenu(_ sender: NSMenuItem) {
    guard
      let raw = sender.representedObject as? String,
      let id = UUID(uuidString: raw)
    else { return }
    model.translate(toID: id)
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
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Translate"
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

  private func isLaunchedAtLogin() -> Bool {
    let loginItemKeyword: AEKeyword = 0x6C696E74 // 'lint'
    return NSAppleEventManager.shared()
      .currentAppleEvent?
      .paramDescriptor(forKeyword: loginItemKeyword)?
      .booleanValue == true
  }
}
