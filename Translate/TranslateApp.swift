import SwiftUI

@main
struct TranslateApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    // Settings UI is an AppKit window owned by AppDelegate so double-click
    // and the menu bar item always have something visible to open.
    Settings {
      EmptyView()
    }
  }
}
