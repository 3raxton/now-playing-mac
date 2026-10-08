import SwiftUI

class PlayerMenuItem: NSMenuItem {
  var player: MusicInfo.PlayerApp?

  override init(title string: String, action selector: Selector?, keyEquivalent charCode: String) {
    super.init(title: string, action: selector, keyEquivalent: charCode)
  }
  
  required init(coder: NSCoder) {
    super.init(coder: coder)
  }
  
  func setPlayer(_ player: MusicInfo.PlayerApp) {
    self.player = player
  }
}

class DockMenuController {
  let dockController: DockController
  let menu: NSMenu
  
  init(controller: DockController) {
    self.dockController = controller
    self.menu = NSMenu()
  }
  
  private func getTopMenu() -> [NSMenuItem] {
    if let nowPlaying = dockController.getData() {
      if !nowPlaying.isEmpty() {
        let playingLabel = NSMenuItem()
        playingLabel.title = nowPlaying.playing ? "Now Playing"~ : "Paused"~
        let songLabel = NSMenuItem()
        songLabel.title = nowPlaying.description
        songLabel.target = self
        songLabel.action = #selector(showPlayer)
        songLabel.indentationLevel = 1
        return [playingLabel, songLabel, NSMenuItem.separator()]
      }
    }
    return []
  }
  
  private func getTransportMenu() -> [NSMenuItem] {
    let label = NSMenuItem()
    label.title = "Playback"~
    let playing = dockController.getData()?.playing ?? false
    let playback = NSMenuItem(title: (playing ? "Pause" : "Play")~, action: #selector(playPause), keyEquivalent: "")
    playback.target = self
    playback.indentationLevel = 1
    let previous = NSMenuItem(title: "Previous"~, action: #selector(previousTrack), keyEquivalent: "")
    previous.target = self
    previous.indentationLevel = 1
    let next = NSMenuItem(title: "Next"~, action: #selector(nextTrack), keyEquivalent: "")
    next.target = self
    next.indentationLevel = 1
    return [NSMenuItem.separator(), label, playback, previous, next]
  }

  private func getPauseOthersMenu() -> [NSMenuItem] {
    let label = NSMenuItem()
    label.title = "Pause other players"~
    let enabled = AppSettings.default.pausesOtherPlayers()
    let on = settingItem(title: "On"~, selected: enabled, action: #selector(enablePauseOtherPlayers))
    let off = settingItem(title: "Off"~, selected: !enabled, action: #selector(disablePauseOtherPlayers))
    return [NSMenuItem.separator(), label, on, off]
  }

  private func settingItem(title: String, selected: Bool, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.state = selected ? .on : .off
    item.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
    item.indentationLevel = 1
    item.isEnabled = true
    return item
  }

  private func getLabelMenu() -> [NSMenuItem] {
    let label = NSMenuItem()
    label.title = "Music Player"~
    return [label]
  }
  
  private func getPlayersMenu() -> [NSMenuItem] {
    let target = self
    let players = MusicInfo.PlayerApp.allCases.map {
      let current = $0
      let title = current.rawValue
      let player = PlayerMenuItem()
      let isCurrent = AppSettings.default.menuPlayer() == current
      player.state = isCurrent ? .on : .off
      player.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
      if !isCurrent { player.setPlayer($0) }
      player.title = "\(title)"~
      player.action = #selector(self.changePlayer(sender:))
      player.target = target
      player.indentationLevel = 1
      return player
    }
    return players
  }
  
  private func getInternalMenu() -> NSMenu {
    return self.menu
  }
  
  func getMenu() -> NSMenu? {
    let menu = getInternalMenu()
    let topMenu = getTopMenu()
    let transport = getTransportMenu()
    let label = getLabelMenu()
    let players = getPlayersMenu()
    let pauseOthers = getPauseOthersMenu()
    let about = NSMenuItem(title: "About Now Playing"~, action: #selector(showAbout), keyEquivalent: "")
    about.target = self
    menu.items = topMenu + label + players + transport + pauseOthers + [NSMenuItem.separator(), about]
    return menu
  }
  
  @objc func changePlayer(sender: Any) {
    if let item = sender as? PlayerMenuItem {
      if let player = item.player {
        AppSettings.default.setPlayer(player, manual: true)
      }
    }
  }
  
  @objc func playPause() {
    self.dockController.playPause()
  }

  @objc func showPlayer() {
    self.dockController.showPlayer()
  }

  @objc func nextTrack() {
    self.dockController.nextTrack()
  }

  @objc func previousTrack() {
    self.dockController.previousTrack()
  }

  @objc func enablePauseOtherPlayers() {
    AppSettings.default.setPausesOtherPlayers(true)
  }

  @objc func disablePauseOtherPlayers() {
    AppSettings.default.setPausesOtherPlayers(false)
  }

  @objc func showAbout() {
    AboutWindow.show()
  }
}

final class AboutWindow: NSObject, NSWindowDelegate {
  private static var window: NSWindow?
  private static let delegate = AboutWindow()
  private var copyButton: NSButton?
  private var closeMonitor: Any?

  static func show() {
    NSApp.activate(ignoringOtherApps: true)
    let panel: NSWindow
    if let window {
      panel = window
    } else {
      panel = delegate.make()
      panel.delegate = delegate
      window = panel
      delegate.watchCloseShortcut()
    }
    panel.makeKeyAndOrderFront(nil)
    panel.center()
    alignHorizontally(panel)
    DispatchQueue.main.async {
      guard AboutWindow.window === panel else { return }
      alignHorizontally(panel)
    }
  }

  /// The window can grow wider after it appears. Slide it back without moving it vertically.
  private static func alignHorizontally(_ panel: NSWindow) {
    guard let screen = panel.screen ?? NSScreen.main else { return }
    let visible = screen.visibleFrame
    var frame = panel.frame
    frame.origin.x = (visible.midX - frame.width / 2).rounded()
    if frame.width <= visible.width {
      frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
    }
    panel.setFrame(frame, display: true)
  }

  func windowWillClose(_ notification: Notification) {
    if let closeMonitor {
      NSEvent.removeMonitor(closeMonitor)
      self.closeMonitor = nil
    }
    AboutWindow.window = nil
  }

  private func watchCloseShortcut() {
    guard closeMonitor == nil else { return }
    closeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard flags == .command,
            event.charactersIgnoringModifiers?.lowercased() == "w",
            event.window === AboutWindow.window else { return event }
      AboutWindow.window?.close()
      return nil
    }
  }

  @objc func checkForUpdates() {
    UpdateCheck.start()
  }

  @objc func copyVersionInfo() {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(Self.versionDetails, forType: .string)
    copyButton?.title = "Copied"~
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
      self?.copyButton?.title = "Copy Version Info"~
    }
  }

  private func make() -> NSWindow {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 36, left: 36, bottom: 22, right: 36)

    let icon = NSImageView()
    icon.image = NSApp.applicationIconImage
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

    let updates = NSButton(title: "Check for Updates…"~, target: self, action: #selector(checkForUpdates))
    updates.bezelStyle = .rounded
    let copy = NSButton(title: "Copy Version Info"~, target: self, action: #selector(copyVersionInfo))
    copy.bezelStyle = .rounded
    copy.keyEquivalent = "\r"
    copy.translatesAutoresizingMaskIntoConstraints = false
    let fullTitle = copy.fittingSize
    copy.title = "Copied"~
    let shortTitle = copy.fittingSize
    copy.title = "Copy Version Info"~
    copy.widthAnchor.constraint(equalToConstant: max(fullTitle.width, shortTitle.width)).isActive = true
    copy.heightAnchor.constraint(equalToConstant: max(fullTitle.height, shortTitle.height)).isActive = true
    copyButton = copy
    let actions = NSStackView(views: [updates, copy])
    actions.orientation = .horizontal
    actions.spacing = 10
    actions.alignment = .centerY

    let copyright = Self.text(Self.copyrightText, size: 11, color: .tertiaryLabelColor)
    copyright.maximumNumberOfLines = 2
    copyright.lineBreakMode = .byWordWrapping
    copyright.preferredMaxLayoutWidth = 300

    stack.addArrangedSubview(icon)
    let version = Self.text(String(format: "Version %@"~, Self.version), size: 13, color: .secondaryLabelColor)
    let built = Self.text(Self.buildDateText, size: 12, color: .secondaryLabelColor)
    stack.addArrangedSubview(Self.text("Now Playing", size: 22, weight: .bold))
    stack.addArrangedSubview(version)
    stack.addArrangedSubview(built)
    stack.addArrangedSubview(actions)
    stack.addArrangedSubview(copyright)
    stack.setCustomSpacing(16, after: icon)
    stack.setCustomSpacing(2, after: stack.arrangedSubviews[1])
    stack.setCustomSpacing(14, after: version)
    stack.setCustomSpacing(22, after: built)
    stack.setCustomSpacing(22, after: actions)

    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      container.widthAnchor.constraint(equalToConstant: 380)
    ])

    let panel = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "Now Playing"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .windowBackgroundColor
    panel.contentView = container
    panel.isReleasedWhenClosed = false
    container.layoutSubtreeIfNeeded()
    panel.setContentSize(container.fittingSize)
    return panel
  }

  private static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  }

  private static var copyrightText: String {
    Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
      ?? "© 2026 Braxton Huff. © 2022 Jaxson Van Doorn."
  }

  private static var buildDate: Date {
    if let url = Bundle.main.executableURL,
       let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
      return date
    }
    return Date()
  }

  static var buildDateText: String {
    let absolute = DateFormatter()
    absolute.locale = .current
    absolute.dateFormat = "MMM d, yyyy, h:mm a"
    let relative = RelativeDateTimeFormatter()
    relative.locale = .current
    relative.unitsStyle = .full
    let ago = relative.localizedString(for: buildDate, relativeTo: Date())
    return "\(absolute.string(from: buildDate)) (\(ago))"
  }

  static func updateIcon(pointSize: CGFloat) -> NSImage? {
    let symbol = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    return NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Check for Updates"~)?
      .withSymbolConfiguration(symbol)
  }

  private static var versionDetails: String {
    "Now Playing \(version)\n\(buildDateText)\n\(copyrightText)"
  }

  private static func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = NSFont.systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.alignment = .center
    return field
  }
}
