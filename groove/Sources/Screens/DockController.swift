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
    self.updateTile()
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
      self.info?.perform(.skip)
      return
    }
    self.lastClickType = .normal
    self.info?.perform(.playPause)
  }

  func playPause() {
    self.info?.perform(.playPause)
  }

  func nextTrack() {
    self.info?.perform(.skip)
  }

  func previousTrack() {
    self.info?.perform(.previous)
  }

  private func openSelectedPlayer() {
    guard let player = self.info?.getPlayer() else { return }
    let id = player.getAppId()
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
    DispatchQueue.main.async {
      NSWorkspace.shared.open(url)
    }
  }
  
  func getData() -> DockData? {
    return self.info?.getData()
  }
}
