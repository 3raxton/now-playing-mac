import Combine
import MusicPlayer
import SwiftUI

class MusicInfo {
  private var name: PlayerApp
  private var data: DockData
  
  private var player: MusicPlayers.Scriptable?
  private var ampSonic: AmpSonicPlayer?
  private var loader: ArtworkLoader?
  
  private var updateView: () -> Void
  private let activity = PlayingPlayerMonitor()

  private var subs = Set<AnyCancellable>()

  enum Action {
    case skip, previous, playPause, none
  }

  enum PlayerApp: String {
    case appleMusic = "Music"
    case spotify = "Spotify"
    case ampSonic = "AmpSonic"

    static let allCases: [PlayerApp] = [.spotify, .appleMusic, .ampSonic]

    func getAppId() -> String {
      switch self {
      case .spotify:
        return "com.spotify.client"
      case .appleMusic:
        if #available(OSX 10.15, *) {
          return "com.apple.Music"
        } else {
          return "com.apple.itunes"
        }
      case .ampSonic:
        return AmpSonicPlayer.bundleID
      }
    }
    
    func getInternalPlayer() -> MusicPlayerName? {
      switch self {
      case .spotify:
        return .spotify
      case .appleMusic:
        return .appleMusic
      case .ampSonic:
        return nil
      }
    }

    static func from(_ value: String) -> PlayerApp {
      switch value {
      case spotify.rawValue:
        return .spotify
      case appleMusic.rawValue:
        return .appleMusic
      case ampSonic.rawValue:
        return .ampSonic
      default:
        return .spotify
      }
    }
  }

  init(_ updateView: @escaping () -> Void) {
    let player = MusicInfo.getPlayer()
    self.name = player
    self.data = DockData(artist: "", album: "", song: "", artwork: nil, playing: false)
    self.updateView = updateView
    NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsDidChange), name: UserDefaults.didChangeNotification, object: nil)
    setUpPlayer()
    activity.start(selected: { [weak self] in
      self?.name ?? .spotify
    }, onPlaying: { [weak self] player in
      self?.follow(player)
    })
  }
  
  private func setUpPlayer() {
    guard let scriptable = name.getInternalPlayer() else {
      self.player = nil
      self.loader = nil
      let ampSonic = AmpSonicPlayer { [weak self] in
        self?.update()
      }
      self.ampSonic = ampSonic
      ampSonic.start()
      return
    }

    self.player = MusicPlayers.Scriptable(name: scriptable)
    self.loader = ArtworkLoader(player: name)
    
    if let controller = self.player {
      Publishers.CombineLatest(controller.currentTrackWillChange, controller.playbackStateWillChange)
        .throttle(for: .milliseconds(200),
                  scheduler: DispatchQueue.main,
                  latest: true)
        .sink { [weak self] event in
          let next = event.0
          let state = event.1
          if (state == .stopped || (next == nil && state == .playing(time: 0))) && (self?.isSpotify() ?? false) {
            return
          }
          self?.update()
        }
        .store(in: &subs)
    }
  }
  
  private func tearDownPlayer() {
    for sub in subs { sub.cancel() }
    subs.removeAll()
    ampSonic?.stop()
    ampSonic = nil
  }
  
  private func resetPlayer() {
    tearDownPlayer()
    setUpPlayer()
  }
  
  @objc func userDefaultsDidChange(_ notification: Notification) {
    let player = AppSettings.default.player()
    guard player != name else { return }
    self.name = player
    resetPlayer()
  }

  private func follow(_ player: PlayerApp) {
    guard player != name else { return }
    AppSettings.default.setPlayer(player)
  }

  func update() {
    Task { [weak self] in
      do {
        await self?.fetch()
        self?.updateView()
      }
    }
  }

  func destroy() {
    activity.stop()
    tearDownPlayer()
    NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
  }

  static func getPlayer() -> PlayerApp {
    return AppSettings.default.player()
  }

  func getPlayer() -> PlayerApp {
    return name
  }

  func isSpotify() -> Bool {
    return getPlayer() == .spotify
  }

  func isAppleMusic() -> Bool {
    return getPlayer() == .appleMusic
  }

  func getArtist() -> String {
    if let ampSonic { return ampSonic.currentTrack().artist }
    return player?.currentTrack?.artist ?? ""
  }

  func getAlbum() -> String {
    if let ampSonic { return ampSonic.currentTrack().album }
    return player?.currentTrack?.album ?? ""
  }

  func getSong() -> String {
    if let ampSonic { return ampSonic.currentTrack().title }
    return player?.currentTrack?.title ?? ""
  }

  func getArtwork() -> NSImage? {
    if let ampSonic { return ampSonic.currentTrack().artwork }
    return loader?.getArtwork()
  }

  func getPlaybackStatus() -> Bool {
    return internalPlaybackStatus()
  }

  func getData() -> DockData {
    return data
  }
  
  func isEmpty() -> Bool {
    return getData().isEmpty()
  }

  func playPause() {
    if let ampSonic {
      ampSonic.playPause()
      return
    }
    player?.playPause()
  }

  func nextTrack() {
    if let ampSonic {
      ampSonic.nextTrack()
      return
    }
    player?.skipToNextItem()
    if !getPlaybackStatus(), isAppleMusic() {
      player?.playPause()
    }
  }

  func previousTrack() {
    if let ampSonic {
      ampSonic.previousTrack()
      return
    }
    player?.skipToPreviousItem()
  }

  func perform(_ action: Action) {
    switch action {
    case .playPause:
      playPause()
    case .skip:
      nextTrack()
    case .previous:
      previousTrack()
    case .none:
      break
    }
  }

  @discardableResult
  func fetch() async -> DockData {
    let task = Task {
      do {
        await getTrackInfo()
        let newData = DockData(artist: getArtist(), album: getAlbum(), song: getSong(), artwork: getArtwork(), playing: getPlaybackStatus())
        if !isAppleMusic() || newData.song != "Connecting…" {
          await self.data.update(other: newData)
        }
      }
    }
    _ = await task.result
    return data
  }

  private func delay(_ delay: TimeInterval) async {
    let nano = UInt64(delay * 1_000_000_000)
    try? await Task.sleep(nanoseconds: nano)
  }

  private func getTrackInfo() async {
    do {
      try await loader?.getArtworkAsync()
    } catch {
      print(error)
    }
  }

  private func internalPlaybackStatus() -> Bool {
    if let ampSonic {
      return ampSonic.currentTrack().playing
    }
    if let state = player?.playbackState {
      switch state {
      case .playing:
        return true
      default:
        return false
      }
    }
    return false
  }
}

/// Switches the dock to a player when that player starts, and once at launch if another app is already playing.
private final class PlayingPlayerMonitor {
  private var spotify: MusicPlayers.Scriptable?
  private var appleMusic: MusicPlayers.Scriptable?
  private var wasPlaying: [MusicInfo.PlayerApp: Bool] = [:]
  private var subs = Set<AnyCancellable>()
  private var timer: Timer?
  private var primed = false

  func start(selected: @escaping () -> MusicInfo.PlayerApp, onPlaying: @escaping (MusicInfo.PlayerApp) -> Void) {
    spotify = MusicPlayers.Scriptable(name: .spotify)
    appleMusic = MusicPlayers.Scriptable(name: .appleMusic)
    wasPlaying = current()
    let report = { [weak self] (player: MusicInfo.PlayerApp, playing: Bool) in
      DispatchQueue.main.async {
        self?.consider(player, playing: playing, selected: selected, onPlaying: onPlaying)
      }
    }
    spotify?.playbackStateWillChange
      .sink { report(.spotify, $0.isPlaying) }
      .store(in: &subs)
    appleMusic?.playbackStateWillChange
      .sink { report(.appleMusic, $0.isPlaying) }
      .store(in: &subs)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.adoptCurrentPlayer(selected: selected, onPlaying: onPlaying)
      let timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
        guard let self else { return }
        let states = self.current()
        for player in MusicInfo.PlayerApp.allCases {
          report(player, states[player] ?? false)
        }
      }
      self.timer = timer
    }
  }

  func stop() {
    subs.removeAll()
    let timer = self.timer
    self.timer = nil
    if Thread.isMainThread {
      timer?.invalidate()
    } else {
      DispatchQueue.main.async { timer?.invalidate() }
    }
    spotify = nil
    appleMusic = nil
  }

  private func adoptCurrentPlayer(selected: () -> MusicInfo.PlayerApp, onPlaying: (MusicInfo.PlayerApp) -> Void) {
    let states = current()
    wasPlaying = states
    primed = true
    let currentPlayer = selected()
    if states[currentPlayer] == true { return }
    if let active = MusicInfo.PlayerApp.allCases.first(where: { states[$0] == true }) {
      onPlaying(active)
    }
  }

  private func consider(_ player: MusicInfo.PlayerApp, playing: Bool, selected: () -> MusicInfo.PlayerApp, onPlaying: (MusicInfo.PlayerApp) -> Void) {
    let was = wasPlaying[player] ?? false
    wasPlaying[player] = playing
    guard primed, playing, !was, player != selected() else { return }
    onPlaying(player)
  }

  private func current() -> [MusicInfo.PlayerApp: Bool] {
    [
      .spotify: spotify?.playbackState.isPlaying ?? false,
      .appleMusic: appleMusic?.playbackState.isPlaying ?? false,
      .ampSonic: AmpSonicPlayer.isPlaying()
    ]
  }
}
