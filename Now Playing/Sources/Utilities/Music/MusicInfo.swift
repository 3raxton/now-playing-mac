import Combine
import Darwin
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
    performAfterPausingOthers { [weak self] in
      guard let self else { return }
      if let ampSonic = self.ampSonic {
        ampSonic.playPause()
        return
      }
      self.player?.playPause()
    }
  }

  private func performAfterPausingOthers(_ action: @escaping () -> Void) {
    guard AppSettings.default.pausesOtherPlayers() else {
      action()
      return
    }
    let name = self.name
    activity.keep(name)
    DispatchQueue.global(qos: .userInitiated).async { [activity] in
      activity.pauseOthers(except: name)
      DispatchQueue.main.async(execute: action)
    }
  }

  func nextTrack() {
    performAfterPausingOthers { [weak self] in
      guard let self else { return }
      if let ampSonic = self.ampSonic {
        ampSonic.nextTrack()
        return
      }
      self.player?.skipToNextItem()
      if !self.getPlaybackStatus(), self.isAppleMusic() {
        self.player?.playPause()
      }
    }
  }

  func previousTrack() {
    performAfterPausingOthers { [weak self] in
      guard let self else { return }
      if let ampSonic = self.ampSonic {
        ampSonic.previousTrack()
        return
      }
      self.player?.skipToPreviousItem()
    }
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

/// Switches the dock to a player when that player is the only one playing.
private final class PlayingPlayerMonitor {
  private var wasPlaying: [MusicInfo.PlayerApp: Bool] = [:]
  private var timer: Timer?
  private var primed = false
  private var pollInFlight = false
  private var keeper: MusicInfo.PlayerApp?
  private var selectedPlayer: (() -> MusicInfo.PlayerApp)?
  private var playerStarted: ((MusicInfo.PlayerApp) -> Void)?
  private let playbackNotice = PlaybackNotice()
  private var ampDirectoryWatch: DispatchSourceFileSystemObject?
  private var ampFileWatches: [String: DispatchSourceFileSystemObject] = [:]

  func start(selected: @escaping () -> MusicInfo.PlayerApp, onPlaying: @escaping (MusicInfo.PlayerApp) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.selectedPlayer = selected
      self.playerStarted = onPlaying
      self.playbackNotice.onChange = { [weak self] player, playing in
        self?.note(player, playing: playing)
      }
      self.playbackNotice.start()
      self.watchAmpSonic()
      self.poll(selected: selected, onPlaying: onPlaying, adopt: true)
      let timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
        self?.poll(selected: selected, onPlaying: onPlaying, adopt: false)
      }
      self.timer = timer
    }
  }

  private func note(_ player: MusicInfo.PlayerApp, playing: Bool) {
    consider(player, playing: playing, selected: { [weak self] in
      self?.selectedPlayer?() ?? .spotify
    }, onPlaying: { [weak self] started in
      self?.playerStarted?(started)
    })
  }

  /// AmpSonic has no playback notification. The position file updates as soon as it starts.
  private func watchAmpSonic() {
    let directory = AmpSonicPlayer.playbackDirectory()
    if ampDirectoryWatch == nil {
      let fd = open(directory.path, O_EVTONLY)
      if fd >= 0 {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
          self?.watchAmpSonic()
          self?.note(.ampSonic, playing: AmpSonicPlayer.isPlaying())
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        ampDirectoryWatch = source
      }
    }
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    let paths = Set(files.map(\.path).filter { $0.hasSuffix("-position.json") })
    for path in ampFileWatches.keys.filter({ !paths.contains($0) }) {
      ampFileWatches[path]?.cancel()
      ampFileWatches[path] = nil
    }
    for path in paths where ampFileWatches[path] == nil {
      let fd = open(path, O_EVTONLY)
      guard fd >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .extend, .rename, .delete],
        queue: .main
      )
      source.setEventHandler { [weak self] in
        self?.note(.ampSonic, playing: AmpSonicPlayer.isPlaying())
      }
      source.setCancelHandler { close(fd) }
      source.resume()
      ampFileWatches[path] = source
    }
  }

  private func poll(selected: @escaping () -> MusicInfo.PlayerApp, onPlaying: @escaping (MusicInfo.PlayerApp) -> Void, adopt: Bool) {
    guard !pollInFlight else { return }
    pollInFlight = true
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let spotify = Self.isApplicationPlaying("Spotify")
      let appleMusic = Self.isApplicationPlaying("Music")
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.pollInFlight = false
        let states: [MusicInfo.PlayerApp: Bool] = [
          .spotify: spotify,
          .appleMusic: appleMusic,
          .ampSonic: AmpSonicPlayer.isPlaying()
        ]
        if self.ampDirectoryWatch == nil || self.ampFileWatches.isEmpty {
          self.watchAmpSonic()
        }
        if adopt || !self.primed {
          self.wasPlaying = states
          self.primed = true
          let playing = MusicInfo.PlayerApp.allCases.filter { states[$0] == true }
          if playing.count == 1 {
            self.keeper = playing[0]
          }
          self.followSolePlayer(selected: selected, onPlaying: onPlaying)
          return
        }
        var paused = false
        for player in MusicInfo.PlayerApp.allCases {
          if self.consider(player, playing: states[player] ?? false, selected: selected, onPlaying: onPlaying) {
            paused = true
          }
        }
        if !paused {
          self.pauseKeeperIfOthersStillPlaying()
        }
      }
    }
  }

  func keep(_ player: MusicInfo.PlayerApp) {
    keeper = player
  }

  func pauseOthers(except selected: MusicInfo.PlayerApp) {
    var scripts: [String] = []
    if selected != .spotify {
      scripts.append(Self.pauseSource(id: MusicInfo.PlayerApp.spotify.getAppId()))
    }
    if selected != .appleMusic {
      scripts.append(Self.pauseSource(id: MusicInfo.PlayerApp.appleMusic.getAppId()))
    }
    if !scripts.isEmpty {
      _ = Self.runAppleScript(scripts.joined(separator: "\n"))
    }
    if selected != .ampSonic {
      AmpSonicPlayer.pauseIfPlaying()
    }
  }

  /// Music ignores a bare pause. Ask for player state, then pause, and target the app by bundle id.
  private static func pauseSource(id: String) -> String {
    """
    if application id "\(id)" is running then
      tell application id "\(id)"
        if player state is playing then pause
      end tell
    end if
    """
  }

  func stop() {
    let timer = self.timer
    self.timer = nil
    let directoryWatch = ampDirectoryWatch
    ampDirectoryWatch = nil
    let fileWatches = Array(ampFileWatches.values)
    ampFileWatches = [:]
    let notice = playbackNotice
    let finish = {
      timer?.invalidate()
      directoryWatch?.cancel()
      fileWatches.forEach { $0.cancel() }
      notice.stop()
    }
    if Thread.isMainThread {
      finish()
    } else {
      DispatchQueue.main.async(execute: finish)
    }
  }

  @discardableResult
  private func consider(_ player: MusicInfo.PlayerApp, playing: Bool, selected: () -> MusicInfo.PlayerApp, onPlaying: @escaping (MusicInfo.PlayerApp) -> Void) -> Bool {
    let was = wasPlaying[player] ?? false
    wasPlaying[player] = playing
    guard primed else { return false }
    if playing, !was, AppSettings.default.pausesOtherPlayers() {
      if AppSettings.default.shouldHoldManualPlayerChoice(), player != selected() {
        return false
      }
      keeper = player
      let current = selected()
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.pauseOthers(except: player)
        DispatchQueue.main.async {
          if player != current {
            onPlaying(player)
          }
        }
      }
      return true
    }
    followSolePlayer(selected: selected, onPlaying: onPlaying)
    return false
  }

  /// A missed or ignored pause used to leave Apple Music playing for good. Try again while it is still going.
  private func pauseKeeperIfOthersStillPlaying() {
    guard let keeper, AppSettings.default.pausesOtherPlayers(), !AppSettings.default.shouldHoldManualPlayerChoice() else { return }
    let others = MusicInfo.PlayerApp.allCases.filter { $0 != keeper && wasPlaying[$0] == true }
    guard !others.isEmpty else { return }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.pauseOthers(except: keeper)
    }
  }

  private func followSolePlayer(selected: () -> MusicInfo.PlayerApp, onPlaying: (MusicInfo.PlayerApp) -> Void) {
    guard !AppSettings.default.shouldHoldManualPlayerChoice() else { return }
    let playing = MusicInfo.PlayerApp.allCases.filter { wasPlaying[$0] == true }
    guard playing.count == 1, let only = playing.first, only != selected() else { return }
    onPlaying(only)
  }

  private static func isApplicationPlaying(_ name: String) -> Bool {
    let bundleID = name == "Spotify" ? MusicInfo.PlayerApp.spotify.getAppId() : MusicInfo.PlayerApp.appleMusic.getAppId()
    guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false else { return false }
    let source = "tell application \"\(name)\" to player state is playing"
    return runAppleScript(source) == "true"
  }

  /// Fallback only. Pause itself does not wait on this.
  private static func runAppleScript(_ source: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Spotify and Apple Music post these the moment playback changes.
private final class PlaybackNotice: NSObject {
  var onChange: ((MusicInfo.PlayerApp, Bool) -> Void)?

  func start() {
    let center = DistributedNotificationCenter.default()
    center.addObserver(
      self,
      selector: #selector(spotify(_:)),
      name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
    center.addObserver(
      self,
      selector: #selector(music(_:)),
      name: Notification.Name("com.apple.iTunes.playerInfo"),
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
  }

  func stop() {
    DistributedNotificationCenter.default().removeObserver(self)
  }

  @objc private func spotify(_ note: Notification) {
    guard let playing = Self.playing(note) else { return }
    onChange?(.spotify, playing)
  }

  @objc private func music(_ note: Notification) {
    guard let playing = Self.playing(note) else { return }
    onChange?(.appleMusic, playing)
  }

  private static func playing(_ note: Notification) -> Bool? {
    let state = (note.userInfo?["Player State"] as? String) ?? (note.userInfo?["Playback State"] as? String)
    guard let state else { return nil }
    return state.caseInsensitiveCompare("Playing") == .orderedSame
  }
}
