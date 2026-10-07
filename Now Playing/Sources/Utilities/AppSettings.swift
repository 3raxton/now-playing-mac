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
  
  private var manualPlayerChoiceAt: TimeInterval = 0

  func setPlayer(_ player: MusicInfo.PlayerApp, manual: Bool = false) {
    if manual {
      manualPlayerChoiceAt = ProcessInfo.processInfo.systemUptime
    }
    UserDefaults.standard.set(player.rawValue, forKey: "player")
  }

  /// Keeps a menu choice in place long enough to press play before the sole playing app takes over.
  func shouldHoldManualPlayerChoice() -> Bool {
    manualPlayerChoiceAt > 0 && ProcessInfo.processInfo.systemUptime - manualPlayerChoiceAt < 8
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
