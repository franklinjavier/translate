import Testing
@testable import Translate

/// The app hosts these tests. Its startup must not install anything global or read the
/// user's saved settings.
struct HostStartupTests {
  @Test func testHostStartsWithoutLiveIntegrations() throws {
    let delegate = try #require(AppDelegate.current)
    #expect(AppDelegate.isHostingTests)
    #expect(!delegate.model.isLive)
    #expect(delegate.model.settings == .default)
    #expect(delegate.statusItem == nil)
    #expect(!TextCapture.isTrackingSelections)
  }
}
