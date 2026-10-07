import ApplicationServices
import SwiftUI

enum ClickType {
  case normal, double, none
}

class DockController {
  var dockViewController = DockViewController()
  var info: MusicInfo?
  var lastClicked = ProcessInfo.processInfo.systemUptime
  var lastClickType: ClickType = .none

  /// Dock clicks sometimes arrive twice. A second event this soon is the same click.
  static let IGNORE_CLICK = 0.09
  /// A second click inside this window skips. A slower one pauses or plays.
  static let DOUBLE_CLICK = 0.3
  
  lazy var updateDockTile: DockTileView = {
    dockViewController.loadView()
    return DockTileView(dockViewController)
  }()

  init() {
    self.info = MusicInfo(self.updateTile)
  }
  
  func destroy() {
    self.info?.destroy()
  }

  func updateTile() {
    let data = self.info?.getData()
    Task { [weak self] in
      await self?.dockViewController.update(data)
      DispatchQueue.main.async { [weak self] in
        self?.updateDockTile.display()
      }
    }
  }

  func click() {
    if self.info?.isEmpty() ?? false {
      openSelectedPlayer()
      return
    }

    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = now - self.lastClicked
    if elapsed <= DockController.IGNORE_CLICK {
      return
    }
    self.lastClicked = now

    if elapsed <= DockController.DOUBLE_CLICK {
      self.lastClickType = .double
      self.info?.activateCheckedPlayer()
      self.info?.perform(.skip)
      return
    }
    self.lastClickType = .normal
    self.info?.activateCheckedPlayer()
    self.info?.perform(.playPause)
  }

  func playPause() {
    self.info?.activateCheckedPlayer()
    self.info?.perform(.playPause)
  }

  func nextTrack() {
    self.info?.activateCheckedPlayer()
    self.info?.perform(.skip)
  }

  func previousTrack() {
    self.info?.activateCheckedPlayer()
    self.info?.perform(.previous)
  }

  func showPlayer() {
    openSelectedPlayer()
  }

  private func openSelectedPlayer() {
    guard let player = self.info?.getPlayer() else { return }
    let id = player.getAppId()
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
    // The Dock menu is still closing on the next turn, and that cancels a Space change.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
        self.focus(running, url: url)
        return
      }
      NSWorkspace.shared.open(url)
    }
  }

  private func focus(_ application: NSRunningApplication, url: URL) {
    if raiseWindow(of: application) {
      activate(application, url: url)
      return
    }
    // AmpSonic keeps a real window, but it exposes no Accessibility windows, so AXRaise cannot find it.
    if pressDockIcon(of: application) {
      return
    }
    activate(application, url: url)
  }

  private func activate(_ application: NSRunningApplication, url: URL) {
    if #available(macOS 14.0, *) {
      NSApp.yieldActivation(to: application)
      _ = application.activate(from: .current, options: [.activateAllWindows])
    } else {
      application.activate(options: [.activateAllWindows])
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
  }

  /// AXRaise is what moves to the Space that holds the window. `activate` only changes the front app.
  @discardableResult
  private func raiseWindow(of application: NSRunningApplication) -> Bool {
    guard accessibilityTrusted() else { return false }
    let element = AXUIElementCreateApplication(application.processIdentifier)
    guard let window = mainWindow(of: element) ?? largestWindow(of: element) else { return false }
    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
  }

  /// Pressing the Dock icon switches Spaces even when the app publishes no windows.
  private func pressDockIcon(of application: NSRunningApplication) -> Bool {
    guard accessibilityTrusted(), let name = application.localizedName,
          let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { return false }
    let root = AXUIElementCreateApplication(dock.processIdentifier)
    guard let item = dockItem(named: name, in: root, depth: 0) else { return false }
    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
  }

  private func dockItem(named name: String, in element: AXUIElement, depth: Int) -> AXUIElement? {
    if depth > 6 { return nil }
    let role = stringAttribute(kAXRoleAttribute, of: element)
    let title = stringAttribute(kAXTitleAttribute, of: element)
    if role == "AXDockItem", title == name { return element }
    for child in children(of: element) {
      if let found = dockItem(named: name, in: child, depth: depth + 1) { return found }
    }
    return nil
  }

  private func children(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let value
    else { return [] }
    return (value as? NSArray)?.map { $0 as! AXUIElement } ?? []
  }

  private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  private func mainWindow(of application: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXMainWindowAttribute as CFString, &value) == .success,
          let value
    else { return nil }
    return (value as! AXUIElement)
  }

  private func largestWindow(of application: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let value
    else { return nil }
    let windows = value as! NSArray
    return windows.compactMap { $0 as! AXUIElement }.max { windowArea($0) < windowArea($1) }
  }

  private func windowArea(_ window: AXUIElement) -> CGFloat {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID()
    else { return 0 }
    var size = CGSize.zero
    AXValueGetValue(value as! AXValue, .cgSize, &size)
    return size.width * size.height
  }

  func requestAccessibility() {
    AccessibilityPrompt.shared.show()
  }

  private func accessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
  }
  
  func getData() -> DockData? {
    return self.info?.getData()
  }
}
