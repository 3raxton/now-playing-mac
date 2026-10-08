import Combine
import Darwin
import LXMusicPlayer
import SwiftUI

class MusicInfo {
  private var name: PlayerApp
  private var data: DockData
  
  private var player: LXScriptingMusicPlayer?
  private var ampSonic: AmpSonicPlayer?
  private var loader: ArtworkLoader?
  
  private var updateView: () -> Void
  private let activity = PlayingPlayerMonitor()
  private var artworkTicket = 0
  private var updateSerial = 0
  private var shownPlaying: (playing: Bool, until: TimeInterval)?
  private var bufferTimer: Timer?
  private var previewNeedsReplace = false
  /// Song whose cover is still loading after a player switch. Keeps the current image up.
  private var coverHoldSong: String?

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
    
    func scriptingName() -> LXScriptingMusicPlayer.Name? {
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
    NotificationCenter.default.addObserver(self, selector: #selector(manualPlayerChoice(_:)), name: AppSettings.manualPlayerChoice, object: nil)
    setUpPlayer()
    activity.start(selected: { [weak self] in
      self?.name ?? .spotify
    }, onPlaying: { [weak self] player in
      self?.follow(player)
    })
  }
  
  private func setUpPlayer() {
    guard let scriptingName = name.scriptingName() else {
      self.player = nil
      self.loader = nil
      let ampSonic = AmpSonicPlayer { [weak self] in
        self?.update()
      }
      self.ampSonic = ampSonic
      ampSonic.start()
      return
    }

    guard let player = LXScriptingMusicPlayer(name: scriptingName) else { return }
    self.player = player
    self.loader = ArtworkLoader(player: name)

    // Watch the scripting player directly. Bridging its track into MusicTrack
    // copies a Scripting Bridge object and traps on this OS.
    Publishers.CombineLatest(
      player.publisher(for: \.currentTrack),
      player.publisher(for: \.playerState)
    )
    .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
    .sink { [weak self] track, state in
      guard let self else { return }
      if self.isSpotify() {
        let starting = track == nil && state.isPlaying() && state.playbackTime() == 0
        if state.state() == .stopped || starting {
          return
        }
      }
      self.update()
    }
    .store(in: &subs)
  }
  
  private func tearDownPlayer() {
    bufferTimer?.invalidate()
    bufferTimer = nil
    for sub in subs { sub.cancel() }
    subs.removeAll()
    ampSonic?.stop()
    ampSonic = nil
  }
  
  private func resetPlayer() {
    tearDownPlayer()
    setUpPlayer()
  }
  
  @objc private func manualPlayerChoice(_ notification: Notification) {
    guard let raw = notification.userInfo?["player"] as? String else { return }
    activity.arm(PlayerApp.from(raw))
  }

  @objc func userDefaultsDidChange(_ notification: Notification) {
    let player = AppSettings.default.player()
    guard player != name else { return }
    self.name = player
    previewNeedsReplace = true
    resetPlayer()
    update()
  }

  private func follow(_ player: PlayerApp) {
    guard !AppSettings.default.hasManualPlayerChoice() else { return }
    guard player != name else { return }
    AppSettings.default.setPlayer(player)
  }

  func update() {
    let song = getSong()
    let artist = getArtist()
    let album = getAlbum()
    let buffering = ampSonic?.currentTrack().buffering == true
    let audible = ampSonic?.isAudible() == true
    let reported = getPlaybackStatus()
    let image = getArtwork()
    let dropStaleCover = ampSonic?.shouldDropStaleCover() == true && image == nil
    let songChanged = !song.isEmpty && (song != data.song || artist != data.artist || album != data.album)
    let switching = previewNeedsReplace
    if switching, image == nil, data.artwork != nil, !song.isEmpty, !dropStaleCover {
      coverHoldSong = song
    } else if image != nil || song != coverHoldSong {
      coverHoldSong = nil
    }
    let holdingCover = coverHoldSong == song && image == nil
    // The new player's cover is not in the loader yet. Keep the current one so the app icon does not flash.
    let clearArtwork = dropStaleCover || (image == nil && songChanged && !holdingCover)
    let artwork = image ?? (clearArtwork ? nil : data.artwork)
    let stillBuffering = buffering && !audible && !reported
    if previewNeedsReplace, !reported, !stillBuffering, song == "" { return }
    let force = previewNeedsReplace
    previewNeedsReplace = false
    updateSerial += 1
    let serial = updateSerial
    Task { @MainActor [weak self] in
      guard let self, self.updateSerial == serial else { return }
      let next = DockData(
        artist: artist,
        album: album,
        song: song,
        artwork: artwork,
        playing: stillBuffering ? false : self.displayedPlaying(reported || audible),
        buffering: stillBuffering
      )
      if stillBuffering { self.shownPlaying = nil }
      let previousArtwork = self.data.artwork
      if let artwork, artwork !== previousArtwork {
        _ = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil)
      }
      if !self.isAppleMusic() || next.song != "Connecting…" {
        self.data.update(other: next, force: force, clearArtwork: clearArtwork)
      }
      self.syncBufferTimer()
      self.updateView()
      if let artwork, artwork !== previousArtwork {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
          self?.updateView()
        }
      }
    }
    refreshArtwork(for: song, dropIfMissing: holdingCover)
  }

  /// The dock title updates before the cover. A skip should not wait on the image.
  private func refreshArtwork(for song: String, dropIfMissing: Bool = false) {
    guard loader != nil, !song.isEmpty else { return }
    artworkTicket += 1
    let ticket = artworkTicket
    Task.detached { [weak self] in
      guard let self else { return }
      try? await self.loader?.getArtworkAsync()
      let image = self.getArtwork()
      await MainActor.run {
        guard self.artworkTicket == ticket, self.getSong() == song else { return }
        if let image {
          self.coverHoldSong = nil
          self.data.artwork = image
          self.updateView()
        } else if dropIfMissing {
          self.coverHoldSong = nil
          self.data.artwork = nil
          self.updateView()
        }
      }
    }
  }

  func destroy() {
    bufferTimer?.invalidate()
    bufferTimer = nil
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

  /// Menu playback acts on the checked player. Checking the menu does not switch or pause.
  func activateCheckedPlayer() {
    guard let chosen = AppSettings.default.checkedPlayer(), chosen != name else { return }
    AppSettings.default.setPlayer(chosen)
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

  /// Set when a Dock click pauses AmpSonic. The second click of a double-click skips, and that pause has to be undone or the next song stays stopped.
  private var undoAmpSonicPause = false

  func playPause() {
    if let ampSonic {
      if ampSonic.currentTrack().buffering {
        if ampSonic.isAudible() || ampSonic.isAwaitingAudio() { return }
        undoAmpSonicPause = false
        if ampSonic.play() {
          showBuffering()
        }
        return
      }
      let start = !getData().playing || !getPlaybackStatus()
      if start {
        undoAmpSonicPause = false
        if AppSettings.default.pausesOtherPlayers() {
          let name = self.name
          activity.keep(name)
          DispatchQueue.global(qos: .userInitiated).async { [activity] in
            activity.pauseOthers(except: name)
          }
        }
        if ampSonic.playPause() {
          showBuffering()
        }
        return
      }
      undoAmpSonicPause = true
      showPlaying(false)
      pausePlayback()
      return
    }
    undoAmpSonicPause = false
    let start = !getData().playing || !getPlaybackStatus()
    showPlaying(start)
    if start {
      if AppSettings.default.pausesOtherPlayers() {
        let name = self.name
        activity.keep(name)
        DispatchQueue.global(qos: .userInitiated).async { [activity] in
          activity.pauseOthers(except: name)
        }
      }
      startPlayback()
      return
    }
    pausePlayback()
  }

  /// Starts the checked player. A toggle would pause whichever app was already playing.
  private func startPlayback() {
    if let ampSonic = self.ampSonic {
      if !ampSonic.currentTrack().playing {
        _ = ampSonic.playPause()
      }
      return
    }
    activity.play(name)
  }

  private func pausePlayback() {
    if let ampSonic {
      ampSonic.pauseFromUser()
      return
    }
    self.player?.pause()
  }

  /// Double-click skips. The first click already paused AmpSonic, so play again after the skip.
  func skipResumingPlayback() {
    let resume = undoAmpSonicPause
    undoAmpSonicPause = false
    if let ampSonic {
      if ampSonic.nextTrack() {
        showBuffering()
      }
      if resume {
        _ = ampSonic.play()
        showBuffering()
      }
      pauseOthersAlongside()
      return
    }
    nextTrack()
  }

  /// Triple-click goes back, including from the middle of a song.
  /// One Previous there only returns to the start. Rewind first, then leave the song.
  func previousResumingPlayback() {
    let resume = undoAmpSonicPause
    undoAmpSonicPause = false
    if let ampSonic {
      let inMiddle = ampSonic.currentTrack().elapsed > 2
      if ampSonic.previousTrack() {
        showBuffering()
      }
      if inMiddle {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
          guard let self else { return }
          if self.ampSonic?.previousTrack() == true {
            self.showBuffering()
          }
          if resume {
            _ = self.ampSonic?.play()
            self.showBuffering()
          }
        }
      } else if resume {
        _ = ampSonic.play()
        showBuffering()
      }
      pauseOthersAlongside()
      return
    }
    if (player?.playbackTime ?? 0) > 1.5 {
      player?.playbackTime = 0
    }
    previousTrack()
    if !self.getPlaybackStatus(), self.isAppleMusic() {
      self.player?.playPause()
    }
  }

  func nextTrack() {
    undoAmpSonicPause = false
    if let ampSonic {
      if ampSonic.nextTrack() {
        showBuffering()
      }
      pauseOthersAlongside()
      return
    }
    showPlaying(true)
    pauseOthersAlongside()
    self.player?.skipToNextItem()
    if !self.getPlaybackStatus(), self.isAppleMusic() {
      self.player?.playPause()
    }
  }

  func previousTrack() {
    undoAmpSonicPause = false
    if let ampSonic {
      if ampSonic.previousTrack() {
        showBuffering()
      }
      pauseOthersAlongside()
      return
    }
    showPlaying(true)
    pauseOthersAlongside()
    self.player?.skipToPreviousItem()
  }

  /// The icon changes with the click. A late player report must not put the old icon back.
  private func showPlaying(_ playing: Bool) {
    shownPlaying = (playing, ProcessInfo.processInfo.systemUptime + 1)
    let apply = { [weak self] in
      guard let self else { return }
      self.data.playing = playing
      self.data.buffering = false
      self.syncBufferTimer()
      self.updateView()
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  /// Dock tiles do not animate on their own. Step the spinner until the song's time moves.
  private func showBuffering() {
    shownPlaying = nil
    let apply = { [weak self] in
      guard let self else { return }
      self.data.playing = false
      self.data.buffering = true
      self.syncBufferTimer()
      self.updateView()
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  private func syncBufferTimer() {
    if data.buffering {
      guard bufferTimer == nil else { return }
      let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
        guard let self else { return }
        guard self.data.buffering else {
          self.bufferTimer?.invalidate()
          self.bufferTimer = nil
          return
        }
        self.data.bufferSpin = (self.data.bufferSpin + 24).truncatingRemainder(dividingBy: 360)
        self.updateView()
      }
      bufferTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    } else {
      bufferTimer?.invalidate()
      bufferTimer = nil
    }
  }

  private func displayedPlaying(_ reported: Bool) -> Bool {
    guard let shownPlaying else { return reported }
    if reported == shownPlaying.playing || ProcessInfo.processInfo.systemUptime >= shownPlaying.until {
      self.shownPlaying = nil
      return reported
    }
    return shownPlaying.playing
  }

  /// Skip should not wait on the other players. Pause them while the track changes.
  private func pauseOthersAlongside() {
    guard AppSettings.default.pausesOtherPlayers() else { return }
    let name = self.name
    activity.keep(name)
    DispatchQueue.global(qos: .userInitiated).async { [activity] in
      activity.pauseOthers(except: name)
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

  private func internalPlaybackStatus() -> Bool {
    if let ampSonic {
      return ampSonic.currentTrack().playing
    }
    return player?.playerState.isPlaying() == true
  }
}

/// Switches the dock to a player when that player is the only one playing.
private final class PlayingPlayerMonitor {
  private var wasPlaying: [MusicInfo.PlayerApp: Bool] = [:]
  private var timer: Timer?
  private var primed = false
  private var pollInFlight = false
  private var keeper: MusicInfo.PlayerApp?
  private var trackID: [MusicInfo.PlayerApp: String] = [:]
  private var baselineTicket: [MusicInfo.PlayerApp: Int] = [:]
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
      self.playbackNotice.onChange = { [weak self] player, playing, track in
        self?.note(player, playing: playing, track: track)
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

  private func noteAmpSonic() {
    let track = AppSettings.default.hasManualPlayerChoice() ? AmpSonicPlayer.currentTrackID() : nil
    note(.ampSonic, playing: AmpSonicPlayer.isPlaying(), track: track)
  }

  /// Remember the song already playing so the next one in the checked app pauses the others.
  func arm(_ player: MusicInfo.PlayerApp) {
    let ticket = (baselineTicket[player] ?? 0) + 1
    baselineTicket[player] = ticket
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let baseline = Self.currentTrackID(player)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.baselineTicket[player] == ticket else { return }
        let seen = self.trackID[player]
        if self.trackID[player] == nil, let baseline, !baseline.isEmpty {
          self.trackID[player] = baseline
        }
        self.baselineTicket[player] = nil
        guard let seen, let baseline, !baseline.isEmpty, seen != baseline else { return }
        guard AppSettings.default.checkedPlayer() == player else { return }
        AppSettings.default.releaseManualPlayerChoice()
        guard AppSettings.default.pausesOtherPlayers() else { return }
        self.keeper = player
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
          self?.pauseOthers(except: player)
        }
      }
    }
  }

  private func note(_ player: MusicInfo.PlayerApp, playing: Bool, track: String? = nil) {
    consider(player, playing: playing, track: track, selected: { [weak self] in
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
          self?.noteAmpSonic()
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
        self?.noteAmpSonic()
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

  /// `resume` leaves Apple Music stopped. `play` starts Spotify and Apple Music from stopped or paused.
  func play(_ player: MusicInfo.PlayerApp) {
    guard player != .ampSonic else { return }
    let id = player.getAppId()
    let source = """
    if application id "\(id)" is running then
      tell application id "\(id)" to play
    end if
    """
    DispatchQueue.global(qos: .userInitiated).async {
      _ = Self.runAppleScript(source)
    }
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
  private func consider(_ player: MusicInfo.PlayerApp, playing: Bool, track: String? = nil, selected: () -> MusicInfo.PlayerApp, onPlaying: @escaping (MusicInfo.PlayerApp) -> Void) -> Bool {
    let previousTrack = trackID[player]
    if let track, !track.isEmpty {
      trackID[player] = track
    }
    let was = wasPlaying[player] ?? false
    wasPlaying[player] = playing
    guard primed else { return false }
    let chosen = AppSettings.default.checkedPlayer()
    let choseThis = chosen == player
    // A new song in the checked player counts even when that app was already playing.
    let trackChanged = playing && choseThis && previousTrack != nil && track != nil && track != previousTrack
    if playing, !was || trackChanged {
      let current = selected()
      if player != current, chosen == nil {
        onPlaying(player)
      }
      if choseThis {
        AppSettings.default.releaseManualPlayerChoice()
      }
      if AppSettings.default.pausesOtherPlayers(), chosen == nil || choseThis {
        keeper = player
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
          self?.pauseOthers(except: player)
        }
        return true
      }
    }
    followSolePlayer(selected: selected, onPlaying: onPlaying)
    return false
  }

  /// A missed or ignored pause used to leave Apple Music playing for good. Try again while it is still going.
  private func pauseKeeperIfOthersStillPlaying() {
    guard let keeper, AppSettings.default.pausesOtherPlayers() else { return }
    if AppSettings.default.hasManualPlayerChoice(), keeper != selectedPlayer?() { return }
    let others = MusicInfo.PlayerApp.allCases.filter { $0 != keeper && wasPlaying[$0] == true }
    guard !others.isEmpty else { return }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.pauseOthers(except: keeper)
    }
  }

  private func followSolePlayer(selected: () -> MusicInfo.PlayerApp, onPlaying: (MusicInfo.PlayerApp) -> Void) {
    guard !AppSettings.default.hasManualPlayerChoice() else { return }
    let playing = MusicInfo.PlayerApp.allCases.filter { wasPlaying[$0] == true }
    guard playing.count == 1, let only = playing.first, only != selected() else { return }
    onPlaying(only)
  }

  private static func currentTrackID(_ player: MusicInfo.PlayerApp) -> String? {
    if player == .ampSonic {
      return AmpSonicPlayer.currentTrackID()
    }
    let id = player.getAppId()
    let source = """
    if application id "\(id)" is running then
      tell application id "\(id)"
        if player state is playing then
          return (name of current track) & character id 1 & (artist of current track)
        end if
      end tell
    end if
    """
    let value = runAppleScript(source)
    return value?.isEmpty == false ? value : nil
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
  var onChange: ((MusicInfo.PlayerApp, Bool, String?) -> Void)?

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
    onChange?(.spotify, playing, Self.track(note))
  }

  @objc private func music(_ note: Notification) {
    guard let playing = Self.playing(note) else { return }
    onChange?(.appleMusic, playing, Self.track(note))
  }

  private static func playing(_ note: Notification) -> Bool? {
    let state = (note.userInfo?["Player State"] as? String) ?? (note.userInfo?["Playback State"] as? String)
    guard let state else { return nil }
    return state.caseInsensitiveCompare("Playing") == .orderedSame
  }

  private static func track(_ note: Notification) -> String? {
    let info = note.userInfo
    let name = info?["Name"] as? String ?? ""
    let artist = info?["Artist"] as? String ?? ""
    guard !name.isEmpty || !artist.isEmpty else { return nil }
    return "\(name)\u{1}\(artist)"
  }
}
