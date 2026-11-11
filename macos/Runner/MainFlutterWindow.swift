import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private static var directorStorageChannel: FlutterMethodChannel?
  private static var menuChannel: FlutterMethodChannel?
  private static var systemFontsChannel: FlutterMethodChannel?
  private static var windowPositionChannel: FlutterMethodChannel?
  private static var windowLifecycleChannel: FlutterMethodChannel?

  /// 窗口已可见、但 NSApp 的应用级 occlusion 还没跟上时的补拍次数。
  /// 窗口 order in 之后 occlusionState 不是同步更新的，只看一次会漏。
  private var pendingLifecycleSyncRetries = 0

  private var unhandledKeyEvent: NSEvent?

  override func keyDown(with event: NSEvent) {
    let previousEvent = unhandledKeyEvent
    unhandledKeyEvent = event
    defer { unhandledKeyEvent = previousEvent }
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Flutter asynchronously returns unhandled keys to NSWindow. AppKit's
    // cancel-key fallback can create another Escape when NSApp.currentEvent
    // has changed. Flutter's identity-based redispatch guard misses that copy,
    // sending it through Dart and back here indefinitely. Let AppKit finish
    // its native cancellation instead of feeding the copy into Flutter again.
    if let unhandledKeyEvent,
      unhandledKeyEvent.keyCode == 53,
      event.keyCode == 53,
      event !== unhandledKeyEvent
    {
      return false
    }
    return super.performKeyEquivalent(with: event)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    MainFlutterWindow.prepareEngineForMultiView(flutterViewController)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.isMovableByWindowBackground = false
    self.styleMask.insert(.fullSizeContentView)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let directorStorageChannel = FlutterMethodChannel(name: "ai.reveric.director/storage", binaryMessenger: flutterViewController.engine.binaryMessenger)
    MainFlutterWindow.directorStorageChannel = directorStorageChannel
    directorStorageChannel.setMethodCallHandler { call, result in
      guard call.method == "availableBytes", let args = call.arguments as? [String: Any], let path = args["path"] as? String else { result(FlutterMethodNotImplemented); return }
      do {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
        guard let bytes = attrs[.systemFreeSize] as? NSNumber else { throw NSError(domain: "storage_probe_failed", code: 1) }
        result(bytes.int64Value)
      } catch { result(FlutterError(code: "storage_probe_failed", message: "Unable to query private volume", details: nil)) }
    }

    let channel = FlutterMethodChannel(
      name: "reveric/menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    MainFlutterWindow.menuChannel = channel

    let systemFontsChannel = FlutterMethodChannel(
      name: "reveric/system_fonts",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    MainFlutterWindow.systemFontsChannel = systemFontsChannel
    systemFontsChannel.setMethodCallHandler { call, result in
      guard call.method == "listFontFamilies" else {
        result(FlutterMethodNotImplemented)
        return
      }

      let fonts = NSFontManager.shared.availableFontFamilies
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      result(Array(Set(fonts)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    let windowPositionChannel = FlutterMethodChannel(
      name: "reveric/window_position",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    MainFlutterWindow.windowPositionChannel = windowPositionChannel
    windowPositionChannel.setMethodCallHandler { call, result in
      guard
        let args = call.arguments as? [String: Any],
        let handle = args["windowHandle"] as? NSNumber,
        let pointer = UnsafeRawPointer(bitPattern: UInt(handle.uint64Value))
      else {
        result(
          FlutterError(
            code: "bad_args",
            message: "Missing native window handle.",
            details: nil
          )
        )
        return
      }
      let window = Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue()

      switch call.method {
      case "getPosition":
        result([
          "x": Double(window.frame.origin.x),
          "y": Double(window.frame.origin.y),
        ])
      case "setPosition":
        guard
          let x = args["x"] as? NSNumber,
          let y = args["y"] as? NSNumber
        else {
          result(
            FlutterError(
              code: "bad_args",
              message: "Missing native window position.",
              details: nil
            )
          )
          return
        }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let origin = MainFlutterWindow.clampedWindowOrigin(
          NSPoint(x: x.doubleValue, y: y.doubleValue),
          windowSize: window.frame.size,
          visibleFrames: visibleFrames,
          fallbackVisibleFrame: NSScreen.main?.visibleFrame
        )
        window.setFrameOrigin(origin)
        result(nil)
      case "setAlwaysOnTop":
        guard let value = args["value"] as? Bool else {
          result(
            FlutterError(
              code: "bad_args",
              message: "Missing always-on-top value.",
              details: nil
            )
          )
          return
        }
        window.level = value ? .floating : .normal
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let windowLifecycleChannel = FlutterMethodChannel(
      name: "reveric/window_lifecycle",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    MainFlutterWindow.windowLifecycleChannel = windowLifecycleChannel
    windowLifecycleChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "window_gone",
            message: "MainFlutterWindow has been deallocated.",
            details: nil
          )
        )
        return
      }

      switch call.method {
      case "reseedEngineVisibility":
        result(self.reseedEngineVisibility())
      case "getVisibilityState":
        result(self.visibilitySnapshot())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(setupAboutMenu),
      name: NSApplication.didFinishLaunchingNotification,
      object: nil
    )

    // 窗口由隐藏转为可见，正是引擎唯一会漏掉的那次状态变化。窗口级通知覆盖
    // window_manager.show() 的两条路径（orderFront / makeKeyAndOrderFront）；
    // 应用级通知覆盖「窗口早已 order in、应用稍后才被判定为可见」的时序。
    for name in [
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didDeminiaturizeNotification,
    ] {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(syncEngineApplicationLifecycle),
        name: name,
        object: self
      )
    }
    for name in [
      NSApplication.didChangeOcclusionStateNotification,
      NSApplication.didBecomeActiveNotification,
    ] {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(syncEngineApplicationLifecycle),
        name: name,
        object: nil
      )
    }

    super.awakeFromNib()
  }

  /// 按 NSApp 实况把应用生命周期状态回灌给引擎。
  ///
  /// FlutterEngine 把 `_active` / `_visible` 初始化为 NO，`_visible` 此后**只有**
  /// `handleDidChangeOcclusionState:` 会置位（FlutterEngine.mm）。本 app 启动时窗口
  /// 先隐藏、等 window_manager 恢复几何后才 show()；若这期间 macOS 没有投递应用级
  /// occlusion **变化**通知，`_visible` 就永远停在 NO。之后每次 will-become-active /
  /// will-resign-active 都会因 `if (!_visible)` 再发一次 hidden，把 Dart 侧的
  /// framesEnabled 关掉，UI 永久冻结在最后一帧。
  ///
  /// 这里调用引擎自己的回调，让它重新读取 NSApp 的 occlusionState 与 isActive ——
  /// 引擎内部会据实分支，所以真被遮挡时不会被推成错误的 visible。
  @objc private func syncEngineApplicationLifecycle() {
    guard isVisible else {
      logLifecycle("sync skipped: window not visible")
      return
    }

    guard NSApp.occlusionState.contains(.visible) else {
      // 窗口刚 order in 时应用级 occlusion 未必已更新。旧实现在这里直接 return
      // 且没有重试，这正是原生这条路径经常不生效的原因。
      scheduleLifecycleSyncRetry()
      return
    }

    pendingLifecycleSyncRetries = 0
    _ = reseedEngineVisibility()
  }

  /// 窗口可见但应用级 occlusion 还没跟上时补拍几次。
  private func scheduleLifecycleSyncRetry() {
    guard pendingLifecycleSyncRetries < 10 else {
      logLifecycle("sync gave up: app occlusion never became visible")
      return
    }
    pendingLifecycleSyncRetries += 1
    logLifecycle("sync deferred: app occlusion not visible yet, retry #\(pendingLifecycleSyncRetries)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.syncEngineApplicationLifecycle()
    }
  }

  /// 把 NSApp 的真实 occlusion / active 状态回灌给引擎，并返回当次快照。
  ///
  /// 先 occlusion 后 active：`handleDidChangeOcclusionState:` 负责修正 `_visible`，
  /// `handleWillBecomeActive:` 负责修正 `_active`。反过来的话，`_visible` 还是 NO 时
  /// 的 will-become-active 会先多发一条无意义的 hidden。
  private func reseedEngineVisibility() -> [String: Any] {
    var snapshot = visibilitySnapshot()

    guard let controller = contentViewController as? FlutterViewController else {
      snapshot["reseeded"] = false
      snapshot["reason"] = "no_flutter_view_controller"
      logLifecycle("reseed skipped: contentViewController is not a FlutterViewController")
      return snapshot
    }

    let engine: FlutterAppLifecycleDelegate = controller.engine
    engine.handleDidChangeOcclusionState?(
      Notification(name: NSApplication.didChangeOcclusionStateNotification, object: NSApp)
    )
    if NSApp.isActive {
      engine.handleWillBecomeActive?(
        Notification(name: NSApplication.willBecomeActiveNotification, object: NSApp)
      )
    }

    snapshot["reseeded"] = true
    logLifecycle("reseed done \(snapshot)")
    return snapshot
  }

  /// 生命周期排查所需的原生实况。Dart 侧守卫用 `appOcclusionVisible` 判断
  /// 「引擎说的 hidden 是不是真的」—— `windowVisible` 不行，窗口被别的应用完全盖住时
  /// NSWindow.isVisible 仍然是 true。
  private func visibilitySnapshot() -> [String: Any] {
    return [
      "appOcclusionVisible": NSApp.occlusionState.contains(.visible),
      "appActive": NSApp.isActive,
      "windowVisible": isVisible,
      "windowMiniaturized": isMiniaturized,
      "windowKey": isKeyWindow,
      "windowOcclusionVisible": occlusionState.contains(.visible),
    ]
  }

  private func logLifecycle(_ message: String) {
    #if DEBUG
      NSLog(
        "[WindowLifecycle] %@ | windowVisible=%d appOcclusionVisible=%d appActive=%d",
        message,
        isVisible,
        NSApp.occlusionState.contains(.visible),
        NSApp.isActive
      )
    #endif
  }

  static func prepareEngineForMultiView(_ flutterViewController: FlutterViewController) {
    let engine = flutterViewController.engine
    let enableMultiView = NSSelectorFromString("enableMultiView")
    precondition(
      engine.responds(to: enableMultiView),
      "The pinned Flutter engine no longer exposes enableMultiView."
    )

    // FlutterViewController() immediately claims the implicit view. The native
    // windowing API requires multiview to be enabled before any view is added,
    // while legacy desktop plugins still resolve the implicit view. Reattach
    // the same controller around the experimental engine opt-in to satisfy both.
    engine.viewController = nil
    _ = engine.perform(enableMultiView)
    engine.viewController = flutterViewController
  }

  static func clampedWindowOrigin(
    _ requestedOrigin: NSPoint,
    windowSize: NSSize,
    visibleFrames: [NSRect],
    fallbackVisibleFrame: NSRect?
  ) -> NSPoint {
    let requestedFrame = NSRect(origin: requestedOrigin, size: windowSize)
    guard
      let visibleFrame = visibleFrames.first(where: { $0.intersects(requestedFrame) })
        ?? fallbackVisibleFrame
        ?? visibleFrames.first
    else {
      return requestedOrigin
    }

    let maximumX = max(visibleFrame.minX, visibleFrame.maxX - windowSize.width)
    let maximumY = max(visibleFrame.minY, visibleFrame.maxY - windowSize.height)
    return NSPoint(
      x: min(max(requestedOrigin.x, visibleFrame.minX), maximumX),
      y: min(max(requestedOrigin.y, visibleFrame.minY), maximumY)
    )
  }

  @objc func setupAboutMenu() {
    guard let aboutItem = NSApp.mainMenu?.item(at: 0)?.submenu?.item(at: 0) else { return }
    aboutItem.action = #selector(handleAboutMenu)
    aboutItem.target = self
  }

  @objc func handleAboutMenu() {
    MainFlutterWindow.menuChannel?.invokeMethod("about", arguments: nil)
  }
}
