import Cocoa
import FlutterMacOS
import XCTest
@testable import Reveric

class RunnerTests: XCTestCase {

  func testUnhandledEscapeDoesNotReenterKeyEquivalentsAsANewEvent() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    let view = KeyEquivalentProbeView(frame: window.contentView!.bounds)
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    window.makeFirstResponder(view)

    for _ in 0..<2 {
      let escape = keyEvent(window: window, keyCode: 53, characters: "\u{1b}")
      view.unhandledEvent = escape
      view.events.removeAll()

      // Model Flutter returning an unhandled key to NSWindow asynchronously,
      // when NSApp.currentEvent no longer refers to that key.
      window.keyDown(with: escape)

      XCTAssertEqual(view.events.count, 1)
      XCTAssertTrue(view.events.first === escape)
    }
  }

  func testFirstEscapeAndOtherKeyEquivalentsStillReachContent() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    let view = KeyEquivalentProbeView(frame: window.contentView!.bounds)
    window.contentView = view
    window.makeFirstResponder(view)

    let escape = keyEvent(window: window, keyCode: 53, characters: "\u{1b}")
    XCTAssertTrue(window.performKeyEquivalent(with: escape))
    XCTAssertTrue(view.events.last === escape)

    let shortcut = keyEvent(window: window, keyCode: 0, characters: "a", modifiers: .command)
    XCTAssertTrue(window.performKeyEquivalent(with: shortcut))
    XCTAssertTrue(view.events.last === shortcut)
    XCTAssertEqual(view.events.count, 2)
  }

  private func keyEvent(
    window: NSWindow, keyCode: UInt16, characters: String,
    modifiers: NSEvent.ModifierFlags = []
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil,
      characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: keyCode
    )!
  }

  func testMainViewIsReattachedAfterEnablingMultiView() {
    let flutterViewController = FlutterViewController()

    MainFlutterWindow.prepareEngineForMultiView(flutterViewController)

    XCTAssertTrue(flutterViewController.engine.viewController === flutterViewController)

    // The windowing API calls this selector again when creating its first
    // native window. It must be an idempotent no-op instead of throwing the
    // late-enable NSInternalInconsistencyException.
    let enableMultiView = NSSelectorFromString("enableMultiView")
    XCTAssertTrue(flutterViewController.engine.responds(to: enableMultiView))
    _ = flutterViewController.engine.perform(enableMultiView)
  }

  func testRestoredWindowPositionIsKeptInsideVisibleScreen() {
    let visibleFrame = NSRect(x: 0, y: 24, width: 1440, height: 876)

    let origin = MainFlutterWindow.clampedWindowOrigin(
      NSPoint(x: 2400, y: -500),
      windowSize: NSSize(width: 640, height: 640),
      visibleFrames: [visibleFrame],
      fallbackVisibleFrame: visibleFrame
    )

    XCTAssertEqual(origin.x, 800, accuracy: 0.001)
    XCTAssertEqual(origin.y, 24, accuracy: 0.001)
  }

  func testRestoredWindowPositionPreservesNegativeDisplayCoordinates() {
    let leftDisplay = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
    let primaryDisplay = NSRect(x: 0, y: 0, width: 1440, height: 900)

    let origin = MainFlutterWindow.clampedWindowOrigin(
      NSPoint(x: -1500, y: 120),
      windowSize: NSSize(width: 640, height: 640),
      visibleFrames: [leftDisplay, primaryDisplay],
      fallbackVisibleFrame: primaryDisplay
    )

    XCTAssertEqual(origin.x, -1500, accuracy: 0.001)
    XCTAssertEqual(origin.y, 120, accuracy: 0.001)
  }

}

private final class KeyEquivalentProbeView: NSView {
  var unhandledEvent: NSEvent?
  var events: [NSEvent] = []

  override var acceptsFirstResponder: Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    events.append(event)
    return event !== unhandledEvent
  }

}
