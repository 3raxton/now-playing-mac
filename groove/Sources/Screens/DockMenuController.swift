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
        playingLabel.target = self
        playingLabel.action = #selector(showPlayer)
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
      let isCurrent = AppSettings.default.player() == current
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
    menu.items = topMenu + label + players + transport
    return menu
  }
  
  @objc func changePlayer(sender: Any) {
    if let item = sender as? PlayerMenuItem {
      if let player = item.player {
        AppSettings.default.setPlayer(player)
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
}
