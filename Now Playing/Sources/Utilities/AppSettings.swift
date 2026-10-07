import SwiftUI

class AppSettings {
  static let `default` = AppSettings()
  
  private init() {}
  
  private func playerString() -> String {
    UserDefaults.standard.string(forKey: "player") ?? ""
  }
  
  func player() -> MusicInfo.PlayerApp {
    MusicInfo.PlayerApp.from(playerString())
  }
  
  /// The menu check. Automatic follow cannot replace it.
  private var chosenPlayer: MusicInfo.PlayerApp?
  private var manualLock = false

  func setPlayer(_ player: MusicInfo.PlayerApp, manual: Bool = false) {
    if manual {
      manualLock = true
      chosenPlayer = player
      if player != self.player() {
        UserDefaults.standard.set(player.rawValue, forKey: "player")
      }
      return
    }
    if manualLock { return }
    chosenPlayer = nil
    UserDefaults.standard.set(player.rawValue, forKey: "player")
  }

  func menuPlayer() -> MusicInfo.PlayerApp {
    chosenPlayer ?? player()
  }

  func checkedPlayer() -> MusicInfo.PlayerApp? {
    manualLock ? chosenPlayer : nil
  }

  /// A menu choice stays until the user picks another player or starts that player.
  func hasManualPlayerChoice() -> Bool {
    manualLock
  }

  func pausesOtherPlayers() -> Bool {
    UserDefaults.standard.bool(forKey: "pauseOtherPlayers")
  }

  func setPausesOtherPlayers(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: "pauseOtherPlayers")
  }
  
  func resetSettings() {
    let domain = Bundle.main.bundleIdentifier
    guard let id = domain else { return }
    UserDefaults.standard.removePersistentDomain(forName: id)
    UserDefaults.standard.synchronize()
  }
  
  private func readPropertyList() -> [String: Any]? {
    if let plistPath = Bundle.main.path(forResource: "DefaultValues", ofType: "plist") {
      if let plistData = FileManager.default.contents(atPath: plistPath) {
        do {
          let data = try PropertyListSerialization.propertyList(from: plistData, format: nil)
          let asDict = data as? [String: Any]
          return asDict
        } catch {
          print(error)
        }
      }
    }
    return nil
  }
  
  func setDefaults() {
    let userDefaults = UserDefaults.standard
    if let defaultValues = readPropertyList() {
      userDefaults.register(defaults: defaultValues)
    }
  }
}
