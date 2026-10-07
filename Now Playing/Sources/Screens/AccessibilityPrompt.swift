import AppKit
import ApplicationServices
import CoreVideo

/// A bar under the System Settings window. Its switch keeps flipping until Accessibility is turned on.
final class AccessibilityPrompt: NSObject {
  static let shared = AccessibilityPrompt()

  private var panel: NSPanel?
  private var preview: ListPreviewView?
  private var dimView: NSView?
  private var didPlace = false
  private var wasMoving = false
  private var displayLink: CVDisplayLink?
  private var trackingQueued = false
  private let trackingLock = NSLock()
  private var dismissing = false
  private var granted = false
  private var watchingTrust = false
  private var trustGeneration = 0
  private var trustObserver: NSObjectProtocol?
  private var settingsWindowID: CGWindowID?
  private var nextFullScan = 0.0
  private var ticks = 0
  private var missedSettingsFrames = 0

  func show() {
    guard !Self.processIsTrusted() else { return }
    granted = false
    openAccessibilitySettings()
    DispatchQueue.main.async { [weak self] in
      self?.present()
    }
  }

  private func openAccessibilitySettings() {
    let urls = [
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ]
    let uid = String(getuid())
    for raw in urls {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      task.arguments = ["asuser", uid, "/usr/bin/open", raw]
      if (try? task.run()) != nil { return }
    }
  }

  private func present() {
    if panel == nil {
      panel = makePanel()
    }
    startWatchingTrust()
    startTracking()
    tick()
  }

  private func startTracking() {
    if let displayLink {
      CVDisplayLinkStop(displayLink)
      self.displayLink = nil
    }
    var link: CVDisplayLink?
    guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, user in
      guard let user else { return kCVReturnSuccess }
      let prompt = Unmanaged<AccessibilityPrompt>.fromOpaque(user).takeUnretainedValue()
      prompt.trackingLock.lock()
      let alreadyQueued = prompt.trackingQueued
      if !alreadyQueued { prompt.trackingQueued = true }
      prompt.trackingLock.unlock()
      guard !alreadyQueued else { return kCVReturnSuccess }
      DispatchQueue.main.async {
        prompt.tick()
        prompt.trackingLock.lock()
        prompt.trackingQueued = false
        prompt.trackingLock.unlock()
      }
      return kCVReturnSuccess
    }, context)
    CVDisplayLinkStart(link)
    displayLink = link
  }

  private func stopTracking() {
    if let displayLink {
      CVDisplayLinkStop(displayLink)
      self.displayLink = nil
    }
  }

  private func tick() {
    guard !granted, !dismissing else { return }
    ticks += 1
    if ticks % 24 == 0, Self.processIsTrusted() {
      acknowledgeAccess()
      return
    }
    placePanel()
  }

  /// Trust is checked when the system says Accessibility changed, then a few times while TCC catches up.
  /// Polling the whole time this pane is open makes macOS insert the app.
  private func startWatchingTrust() {
    guard !watchingTrust else { return }
    watchingTrust = true
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      accessibilityTrustChanged,
      "com.apple.accessibility.api" as CFString,
      nil,
      .deliverImmediately
    )
    trustObserver = DistributedNotificationCenter.default.addObserver(
      forName: Notification.Name("com.apple.accessibility.api"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.trustMayHaveChanged()
    }
  }

  private func stopWatchingTrust() {
    guard watchingTrust else { return }
    watchingTrust = false
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName("com.apple.accessibility.api" as CFString),
      nil
    )
    if let trustObserver {
      DistributedNotificationCenter.default.removeObserver(trustObserver)
      self.trustObserver = nil
    }
  }

  fileprivate func trustMayHaveChanged() {
    trustGeneration += 1
    confirmTrust(generation: trustGeneration, remaining: 12)
  }

  private func confirmTrust(generation: Int, remaining: Int) {
    guard generation == trustGeneration, !granted else { return }
    if Self.processIsTrusted() {
      acknowledgeAccess()
      return
    }
    guard remaining > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      self?.confirmTrust(generation: generation, remaining: remaining - 1)
    }
  }

  private static func processIsTrusted() -> Bool {
    if AXIsProcessTrusted() { return true }
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: false] as CFDictionary)
  }

  private func acknowledgeAccess() {
    guard !granted else { return }
    granted = true
    dismissing = true
    close()
  }

  private func close() {
    stopTracking()
    trustGeneration += 1
    dismissing = false
    stopWatchingTrust()
    settingsWindowID = nil
    didPlace = false
    preview?.stopSwitchAnimation()
    panel?.orderOut(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = SupportingPanel(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 420, height: 132)),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .normal
    panel.isFloatingPanel = false
    panel.isMovable = false
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.collectionBehavior = [.ignoresCycle, .managed]
    markActive(panel)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false

    let title = NSTextField(labelWithString: "Enable Now Playing in the Accessibility pane"~)
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.textColor = Self.activeLabel
    title.cell?.backgroundStyle = .emphasized
    title.lineBreakMode = .byWordWrapping
    title.maximumNumberOfLines = 2
    title.preferredMaxLayoutWidth = 440
    title.cell?.wraps = true
    title.cell?.isScrollable = false
    title.frame.size.width = 440
    title.sizeToFit()

    let detail = NSTextField(labelWithString: "Turn on the switch in the list above to grant Accessibility access to Now Playing"~)
    detail.font = .systemFont(ofSize: 12)
    detail.textColor = Self.activeSecondary
    detail.cell?.backgroundStyle = .emphasized
    detail.lineBreakMode = .byWordWrapping
    detail.maximumNumberOfLines = 2
    detail.preferredMaxLayoutWidth = 440
    detail.cell?.wraps = true
    detail.cell?.isScrollable = false
    detail.frame.size.width = 440
    detail.sizeToFit()

    let textWidth = max(title.frame.width, detail.frame.width)
    let textHeight = title.frame.height + 4 + detail.frame.height
    let size = NSSize(width: max(420, textWidth + 56), height: 14 + 52 + 12 + textHeight + 16)
    panel.setContentSize(size)

    let container = NSView(frame: NSRect(origin: .zero, size: size))
    container.wantsLayer = true
    container.layer?.shadowColor = NSColor.black.cgColor
    container.layer?.shadowOpacity = 0.28
    container.layer?.shadowRadius = 14
    container.layer?.shadowOffset = CGSize(width: 0, height: -3)
    container.layer?.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.contentView = container

    let background = NSView(frame: container.bounds)
    background.appearance = NSAppearance(named: .darkAqua)
    background.wantsLayer = true
    background.layer?.backgroundColor = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor
    background.layer?.cornerRadius = 16
    background.layer?.masksToBounds = true
    container.addSubview(background)

    let titleY = size.height - 16 - title.frame.height
    title.frame = NSRect(x: 16, y: titleY, width: size.width - 52, height: title.frame.height)
    background.addSubview(title)

    detail.frame = NSRect(x: 16, y: titleY - 4 - detail.frame.height, width: size.width - 32, height: detail.frame.height)
    background.addSubview(detail)

    let row = ListPreviewView(frame: NSRect(x: 12, y: 14, width: size.width - 24, height: 52))
    preview = row
    background.addSubview(row)

    let close = NSButton(frame: NSRect(x: size.width - 36, y: titleY - 2, width: 24, height: 24))
    close.bezelStyle = .inline
    close.isBordered = false
    close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close"~)
    close.contentTintColor = Self.activeSecondary
    close.target = self
    close.action = #selector(closeClicked)
    background.addSubview(close)

    let dim = ClickThroughView(frame: background.bounds)
    dim.autoresizingMask = [.width, .height]
    dim.wantsLayer = true
    dim.layer?.backgroundColor = NSColor.black.cgColor
    dim.alphaValue = 0
    background.addSubview(dim)
    dimView = dim
    return panel
  }

  @objc private func closeClicked() {
    close()
  }

  private func placePanel() {
    guard let panel, !granted else {
      panel?.orderOut(nil)
      return
    }
    guard let settings = systemSettingsFrame(), let settingsWindowID else {
      missedSettingsFrames += 1
      if missedSettingsFrames > 180 {
        preview?.stopSwitchAnimation()
        didPlace = false
        panel.orderOut(nil)
      }
      return
    }
    missedSettingsFrames = 0
    let size = panel.frame.size
    let visible = visibleFrame(containing: settings)
    var origin = CGPoint(x: settings.midX - size.width / 2, y: settings.minY - size.height - 10)
    if origin.y < visible.minY + 8 {
      let raised = visible.minY + 8
      let wouldCoverTheList = raised + size.height > settings.minY - 8
      if !wouldCoverTheList {
        origin.y = raised
      }
    }
    origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
    origin.x = origin.x.rounded()
    origin.y = origin.y.rounded()
    let moving = panel.frame.origin != origin
    if moving {
      var frame = panel.frame
      frame.origin = origin
      panel.setFrame(frame, display: false)
    }
    if !didPlace {
      panel.level = .normal
      panel.order(.above, relativeTo: Int(settingsWindowID))
      didPlace = true
      preview?.startSwitchAnimation()
    }
    if !moving || !wasMoving {
      stick(panel, above: settingsWindowID)
    }
    wasMoving = moving
    if ticks % 8 == 0 {
      moveToSpace(of: settingsWindowID, panel: panel)
    }
  }

  private var trackedScreenFrame = CGRect.null
  private var trackedVisibleFrame = CGRect.null

  private func visibleFrame(containing settings: CGRect) -> CGRect {
    if trackedScreenFrame.intersects(settings), !trackedVisibleFrame.isNull {
      return trackedVisibleFrame
    }
    let screen = NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main
    trackedScreenFrame = screen?.frame ?? settings
    trackedVisibleFrame = screen?.visibleFrame ?? settings
    return trackedVisibleFrame
  }

  /// Stay directly above System Settings, so the pane goes behind whatever covers Settings.
  private func stick(_ panel: NSWindow, above settingsWindowID: CGWindowID) {
    panel.level = .normal
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
      panel.order(.above, relativeTo: Int(settingsWindowID))
      return
    }
    let ours = CGWindowID(panel.windowNumber)
    var inFront: CGWindowID?
    for window in info {
      let layer = window[kCGWindowLayer as String] as? Int ?? 0
      guard layer == 0, let id = windowID(window) else { continue }
      if id == settingsWindowID {
        if inFront != ours {
          panel.level = .normal
          panel.order(.above, relativeTo: Int(settingsWindowID))
        }
        return
      }
      inFront = id
    }
    panel.level = .normal
    panel.order(.above, relativeTo: Int(settingsWindowID))
  }

  private func markActive(_ panel: NSPanel) {
    let selector = NSSelectorFromString("_setForceActiveControls:")
    guard panel.responds(to: selector) else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    let setter = unsafeBitCast(panel.method(for: selector), to: Setter.self)
    setter(panel, selector, true)
    dimView?.alphaValue = 0
  }

  private func moveToSpace(of settingsWindow: CGWindowID, panel: NSWindow) {
    guard panel.windowNumber > 0 else { return }
    let connection = CGSMainConnectionID()
    guard let settingsSpaces = CGSCopySpacesForWindows(connection, 7, [settingsWindow] as CFArray),
          CFArrayGetCount(settingsSpaces) > 0 else { return }
    let target = unsafeBitCast(CFArrayGetValueAtIndex(settingsSpaces, 0), to: NSNumber.self).uint64Value
    guard target != 0 else { return }
    let ourWindow = CGWindowID(panel.windowNumber)
    let windows = [ourWindow] as CFArray
    if let ourSpaces = CGSCopySpacesForWindows(connection, 7, windows),
       CFArrayGetCount(ourSpaces) > 0 {
      let current = unsafeBitCast(CFArrayGetValueAtIndex(ourSpaces, 0), to: NSNumber.self).uint64Value
      if current == target { return }
      CGSRemoveWindowsFromSpaces(connection, windows, ourSpaces)
    }
    CGSAddWindowsToSpaces(connection, windows, settingsSpaces)
    CGSMoveWindowsToManagedSpace(connection, windows, target)
  }

  private func systemSettingsFrame() -> CGRect? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else {
      settingsWindowID = nil
      return nil
    }
    let now = ProcessInfo.processInfo.systemUptime
    if let tracked = settingsWindowID, now < nextFullScan, let frame = bounds(of: tracked), frame.width > 280, frame.height > 280 {
      return frame
    }
    nextFullScan = now + 0.5
    guard let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
      return nil
    }
    let pid = Int(app.processIdentifier)
    let windows: [(id: CGWindowID, frame: CGRect)] = info.compactMap { window in
      let owner = window[kCGWindowOwnerPID as String] as? Int ?? Int(window[kCGWindowOwnerPID as String] as? Int32 ?? -1)
      guard owner == pid else { return nil }
      let layer = window[kCGWindowLayer as String] as? Int ?? 0
      guard layer == 0 else { return nil }
      guard let id = windowID(window) else { return nil }
      guard let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
      var rect = CGRect.zero
      guard CGRectMakeWithDictionaryRepresentation(bounds, &rect), rect.width > 280, rect.height > 280 else { return nil }
      return (id, cocoaFrame(fromQuartz: rect))
    }
    if let tracked = settingsWindowID, let match = windows.first(where: { $0.id == tracked }) {
      return match.frame
    }
    guard let largest = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
      settingsWindowID = nil
      return nil
    }
    settingsWindowID = largest.id
    return largest.frame
  }

  private func bounds(of id: CGWindowID) -> CGRect? {
    var rect = CGRect.zero
    guard CGSGetWindowBounds(CGSMainConnectionID(), id, &rect) == 0, rect.width > 1, rect.height > 1 else { return nil }
    return cocoaFrame(fromQuartz: rect)
  }

  private func windowID(_ window: [String: Any]) -> CGWindowID? {
    let key = kCGWindowNumber as String
    if let number = window[key] as? UInt32 { return number }
    if let number = window[key] as? Int { return CGWindowID(number) }
    if let number = window[key] as? NSNumber { return number.uint32Value }
    return nil
  }

  private static let activeLabel = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)
  private static let activeSecondary = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 0.55)

  private var cachedPrimaryHeight: CGFloat = 0

  private func cocoaFrame(fromQuartz rect: CGRect) -> CGRect {
    if cachedPrimaryHeight == 0 {
      cachedPrimaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
        ?? NSScreen.main?.frame.height
        ?? rect.height
    }
    return CGRect(x: rect.origin.x, y: cachedPrimaryHeight - rect.origin.y - rect.height, width: rect.width, height: rect.height)
  }
}

private final class ListPreviewView: NSView {
  private let toggle: AccentSwitch
  private var hinting = false

  override init(frame frameRect: NSRect) {
    let switchSize = NSSize(width: 38, height: 22)
    toggle = AccentSwitch(frame: NSRect(
      x: frameRect.width - switchSize.width - 12,
      y: (frameRect.height - switchSize.height) / 2,
      width: switchSize.width,
      height: switchSize.height
    ))
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.borderWidth = 1
    layer?.backgroundColor = NSColor(srgbRed: 0.19, green: 0.19, blue: 0.20, alpha: 1).cgColor
    layer?.borderColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12).cgColor

    let icon = NSImageView(frame: NSRect(x: 10, y: 10, width: 32, height: 32))
    icon.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
    icon.imageScaling = .scaleProportionallyUpOrDown
    addSubview(icon)

    let name = NSTextField(labelWithString: "Now Playing"~)
    name.font = .systemFont(ofSize: 13, weight: .medium)
    name.textColor = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)
    name.cell?.backgroundStyle = .emphasized
    name.frame = NSRect(x: 50, y: 16, width: 220, height: 18)
    addSubview(name)
    addSubview(toggle)
  }

  func startSwitchAnimation() {
    guard !hinting else { return }
    hinting = true
    toggle.startHint()
  }

  func stopSwitchAnimation() {
    guard hinting else { return }
    hinting = false
    toggle.stopHint()
  }

  required init?(coder: NSCoder) {
    nil
  }
}

private final class ClickThroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws at full brightness while System Settings, not this app, is the focused app.
private final class SupportingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override var isKeyWindow: Bool { true }
  override var isMainWindow: Bool { true }

  /// AppKit otherwise draws this window dim until it is clicked, because Now Playing is not the active app.
  @objc func _hasActiveAppearance() -> Bool { true }
  @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
  @objc func _hasActiveControls() -> Bool { true }
  @objc func _hasActiveAppearanceForStandardWindowButton(_ button: Any?) -> Bool { true }
}

/// The knob is a layer, so looping the switch does not redraw the rest of the pane.
private final class AccentSwitch: NSView {
  private let track = CALayer()
  private let knob = CALayer()
  private var progress: CGFloat = 0
  private var hintID = 0
  private var pendingFlip: DispatchWorkItem?
  private var laidOutBounds = CGRect.null
  private let offColor = CGColor(srgbRed: 0.28, green: 0.28, blue: 0.30, alpha: 1)
  private let onColor = NSColor.systemBlue.cgColor

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    track.backgroundColor = offColor
    knob.backgroundColor = NSColor.white.cgColor
    layer?.addSublayer(track)
    layer?.addSublayer(knob)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layout() {
    super.layout()
    guard bounds != laidOutBounds else { return }
    laidOutBounds = bounds
    let inset: CGFloat = 2
    let diameter = max(0, bounds.height - inset * 2)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    track.frame = bounds
    track.cornerRadius = bounds.height / 2
    knob.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
    knob.cornerRadius = diameter / 2
    if knob.animation(forKey: "move") == nil {
      knob.position = knobCenter(progress)
      track.backgroundColor = progress > 0.5 ? onColor : offColor
    }
    CATransaction.commit()
  }

  func startHint() {
    stopHint()
    hintID += 1
    progress = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    knob.position = knobCenter(0)
    track.backgroundColor = offColor
    CATransaction.commit()
    queueFlip(towardOn: true, hint: hintID)
  }

  func stopHint() {
    hintID += 1
    pendingFlip?.cancel()
    pendingFlip = nil
    knob.removeAllAnimations()
    track.removeAllAnimations()
  }

  private func queueFlip(towardOn: Bool, hint: Int) {
    let work = DispatchWorkItem { [weak self] in
      guard let self, hint == self.hintID else { return }
      self.animate(on: towardOn)
      self.queueFlip(towardOn: !towardOn, hint: hint)
    }
    pendingFlip = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
  }

  /// One animation, removed by Core Animation when it finishes. The knob is already at the end, so nothing snaps.
  private func animate(on: Bool) {
    let destination = knobCenter(on ? 1 : 0)
    let start = knob.position
    progress = on ? 1 : 0
    let move = CABasicAnimation(keyPath: "position")
    move.fromValue = start
    move.toValue = destination
    move.duration = 0.35
    move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    let fade = CABasicAnimation(keyPath: "backgroundColor")
    fade.fromValue = track.backgroundColor
    fade.toValue = on ? onColor : offColor
    fade.duration = 0.35
    fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    knob.add(move, forKey: "move")
    track.add(fade, forKey: "fade")
    knob.position = destination
    track.backgroundColor = on ? onColor : offColor
    CATransaction.commit()
  }

  private func knobCenter(_ amount: CGFloat) -> CGPoint {
    let inset: CGFloat = 2
    let diameter = max(0, bounds.height - inset * 2)
    let travel = max(0, bounds.width - inset * 2 - diameter)
    let clamped = min(1, max(0, amount))
    return CGPoint(x: inset + diameter / 2 + travel * clamped, y: bounds.midY)
  }

}

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetWindowBounds")
private func CGSGetWindowBounds(_ connection: Int32, _ window: CGWindowID, _ bounds: UnsafeMutablePointer<CGRect>) -> Int32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray?

@_silgen_name("CGSMoveWindowsToManagedSpace")
private func CGSMoveWindowsToManagedSpace(_ connection: Int32, _ windows: CFArray, _ space: UInt64)

@_silgen_name("CGSRemoveWindowsFromSpaces")
private func CGSRemoveWindowsFromSpaces(_ connection: Int32, _ windows: CFArray, _ spaces: CFArray) -> Int32

@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ connection: Int32, _ windows: CFArray, _ spaces: CFArray) -> Int32

private func accessibilityTrustChanged(
  _ center: CFNotificationCenter?,
  _ observer: UnsafeMutableRawPointer?,
  _ name: CFNotificationName?,
  _ object: UnsafeRawPointer?,
  _ userInfo: CFDictionary?
) {
  guard let observer else { return }
  let prompt = Unmanaged<AccessibilityPrompt>.fromOpaque(observer).takeUnretainedValue()
  DispatchQueue.main.async {
    prompt.trustMayHaveChanged()
  }
}
