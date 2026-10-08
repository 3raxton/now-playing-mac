import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation

/// Reads AmpSonic's on-disk queue and sends play, pause, and skip to its media remote client.
final class AmpSonicPlayer {
  static let bundleID = "com.jlandersen.ampsonic"

  struct Track: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var playing = false
    /// AmpSonic's own wasPlaying flag. `playing` is forced off while the spinner is up.
    var audible = false
    var artworkID = ""
    var artwork: NSImage?
    /// The cloud cover has been missing long enough that the previous album should come down.
    var dropStaleCover = false
    /// Playback position in seconds. Left out of equality so a moving playhead does not redraw the Dock.
    var elapsed: Double = 0
    var trackKey = ""
    /// The file is current, but playback time has not moved since this song was started.
    var buffering = false

    static func == (lhs: Track, rhs: Track) -> Bool {
      lhs.title == rhs.title
        && lhs.artist == rhs.artist
        && lhs.album == rhs.album
        && lhs.playing == rhs.playing
        && lhs.audible == rhs.audible
        && lhs.artworkID == rhs.artworkID
        && lhs.artwork === rhs.artwork
        && lhs.dropStaleCover == rhs.dropStaleCover
        && lhs.buffering == rhs.buffering
    }
  }

  private struct PositionFile: Decodable {
    let accountID: String
    let currentIndex: Int
    let wasPlaying: Bool
    let elapsedTime: Double?
  }

  private struct QueueItem: Decodable {
    let title: String?
    let artistName: String?
    let albumTitle: String?
    let artworkID: String?
  }

  private struct QueueFile: Decodable {
    let queue: [QueueItem]
  }

  private struct BufferArm {
    var waitForNewTrack: Bool
    var key: String
    var elapsed: Double
    var since: Date
  }

  private let onChange: () -> Void
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "nowplaying.ampsonic")
  private var track = Track()
  private var accountID = ""
  private var artworkCache: [String: NSImage] = [:]
  private var pendingPlaying: Bool?
  private var pendingUntil = Date.distantPast
  private var retryingArtworkID: String?
  private var artworkReadInFlight = false
  private var missingSince: (id: String, at: Date)?
  /// Set when this song was started. Cleared once elapsed time moves, or after a long wait.
  private var bufferArm: BufferArm?
  /// True after Play asks AmpSonic to start. A second Space during that wait would pause the download.
  private var awaitingAudio = false
  private var lastTrackKey = ""
  private var lastAudible = false
  private var lastElapsed = 0.0
  private var source: DispatchSourceFileSystemObject?
  private var artworkWatches: [String: DispatchSourceFileSystemObject] = [:]
  private var timer: Timer?

  init(onChange: @escaping () -> Void) {
    self.onChange = onChange
  }

  func currentTrack() -> Track {
    lock.lock()
    defer { lock.unlock() }
    return track
  }

  func shouldDropStaleCover() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return track.dropStaleCover && track.artwork == nil
  }

  func isAudible() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return track.audible
  }

  /// Play was already sent and the file has not reported audio yet.
  func isAwaitingAudio() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return awaitingAudio && track.buffering && !track.audible
  }

  func start() {
    refresh()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
        self?.refresh()
      }
      self.timer = timer
    }
  }

  func stop() {
    source?.cancel()
    source = nil
    let artworkWatches = self.artworkWatches
    self.artworkWatches = [:]
    artworkWatches.values.forEach { $0.cancel() }
    let timer = self.timer
    self.timer = nil
    if Thread.isMainThread {
      timer?.invalidate()
    } else {
      DispatchQueue.main.async { timer?.invalidate() }
    }
  }

  func playPause() -> Bool {
    guard postKey(49, flags: []) else { return false }
    lock.lock()
    let starting = !track.playing && !track.buffering
    if starting {
      awaitingAudio = true
      armBufferLocked(waitForNewTrack: false)
    } else {
      awaitingAudio = false
      bufferArm = nil
      track.buffering = false
      track.playing = false
      pendingPlaying = false
      pendingUntil = Date().addingTimeInterval(2)
      Self.reportedPlaying = false
    }
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.onChange()
    }
    scheduleRefresh()
    return starting
  }

  func nextTrack() -> Bool {
    guard postKey(124, flags: .maskCommand) else { return false }
    armSkip()
    return true
  }

  func previousTrack() -> Bool {
    guard postKey(123, flags: .maskCommand) else { return false }
    armSkip()
    return true
  }

  /// Starts the current song. Space is a toggle, so this is only for a song that is already paused.
  func play() -> Bool {
    guard postKey(49, flags: []) else { return false }
    lock.lock()
    awaitingAudio = true
    armBufferLocked(waitForNewTrack: false)
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.onChange()
    }
    scheduleRefresh()
    return true
  }

  /// Pauses AmpSonic only when it is already playing, so Space does not start it.
  static func pauseIfPlaying() {
    guard isPlaying() else { return }
    guard postKey(49, flags: []) else { return }
    reportedPlaying = false
  }

  /// The Dock pause button. Space is sent only when audio is already going.
  func pauseFromUser() {
    Self.pauseIfPlaying()
    lock.lock()
    awaitingAudio = false
    bufferArm = nil
    track.buffering = false
    track.playing = false
    pendingPlaying = false
    pendingUntil = Date().addingTimeInterval(2)
    Self.reportedPlaying = false
    lastAudible = false
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.onChange()
    }
  }

  /// Space toggles playback. Command-Left and Command-Right are AmpSonic's previous and next shortcuts.
  @discardableResult
  private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
    Self.postKey(keyCode, flags: flags)
  }

  @discardableResult
  private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
    let trusted = AXIsProcessTrusted()
    guard trusted else { return false }
    guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
    let pid = application.processIdentifier
    let source = CGEventSource(stateID: .hidSystemState)
    let modifiers = modifierKeys(in: flags)
    var held = CGEventFlags()
    for modifier in modifiers {
      held.insert(modifier.flag)
      guard let down = CGEvent(keyboardEventSource: source, virtualKey: modifier.code, keyDown: true) else { return false }
      down.flags = held
      down.postToPid(pid)
    }
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
    down.flags = flags
    up.flags = flags
    down.postToPid(pid)
    up.postToPid(pid)
    for modifier in modifiers.reversed() {
      held.remove(modifier.flag)
      guard let up = CGEvent(keyboardEventSource: source, virtualKey: modifier.code, keyDown: false) else { return false }
      up.flags = held
      up.postToPid(pid)
    }
    return true
  }

  /// Command has to go down as its own key. A flag on the arrow alone is delivered as a plain arrow, which pauses AmpSonic.
  private static func modifierKeys(in flags: CGEventFlags) -> [(code: CGKeyCode, flag: CGEventFlags)] {
    var keys: [(code: CGKeyCode, flag: CGEventFlags)] = []
    if flags.contains(.maskCommand) { keys.append((55, .maskCommand)) }
    if flags.contains(.maskShift) { keys.append((56, .maskShift)) }
    if flags.contains(.maskAlternate) { keys.append((58, .maskAlternate)) }
    if flags.contains(.maskControl) { keys.append((59, .maskControl)) }
    return keys
  }

  private func armSkip() {
    lock.lock()
    awaitingAudio = false
    armBufferLocked(waitForNewTrack: true)
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.onChange()
    }
    scheduleRefresh()
  }

  private func armBufferLocked(waitForNewTrack: Bool) {
    bufferArm = BufferArm(
      waitForNewTrack: waitForNewTrack,
      key: track.trackKey,
      elapsed: track.elapsed,
      since: Date()
    )
    track.buffering = true
    track.playing = false
    pendingPlaying = nil
    Self.reportedPlaying = false
  }

  private func scheduleRefresh() {
    for delay in [0.25, 0.7, 1.2] {
      queue.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.refresh()
      }
    }
  }

  private func watchPlaybackDirectory() {
    let path = Self.playbackDirectory().path
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .rename, .delete, .extend],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.refresh()
    }
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    self.source = source
  }

  private func refresh() {
    queue.async { [weak self] in
      guard let self else { return }
      if self.source == nil {
        self.watchPlaybackDirectory()
      }
      self.applySnapshot()
    }
  }

  private func applySnapshot() {
    let next = load()
    var resolved = next
    rememberMissingCover(&resolved)
    lock.lock()
    resolveBuffer(&resolved)
    if resolved.buffering {
      pendingPlaying = nil
    } else if let pendingPlaying {
      if resolved.playing == pendingPlaying || Date() >= pendingUntil {
        self.pendingPlaying = nil
      } else {
        resolved.playing = pendingPlaying
      }
    }
    Self.reportedPlaying = resolved.playing
    let changed = resolved != track
    if changed {
      track = resolved
    }
    let missingArtwork = resolved.artwork == nil && !resolved.artworkID.isEmpty && !resolved.title.isEmpty
    let artworkID = resolved.artworkID
    lock.unlock()
    if changed {
      DispatchQueue.main.async { [weak self] in
        self?.onChange()
      }
    }
    if missingArtwork {
      readArtworkWhenIdle(artworkID)
    } else if retryingArtworkID == artworkID {
      retryingArtworkID = nil
    }
  }

  /// Remember when this cover first went missing. After a few seconds the old album comes down.
  private func rememberMissingCover(_ resolved: inout Track) {
    let waiting = resolved.artwork == nil && !resolved.artworkID.isEmpty && !resolved.title.isEmpty
    guard waiting else {
      if missingSince?.id == resolved.artworkID {
        missingSince = nil
      }
      resolved.dropStaleCover = false
      return
    }
    if missingSince?.id != resolved.artworkID {
      missingSince = (resolved.artworkID, Date())
    }
    let started = missingSince?.at ?? Date()
    resolved.dropStaleCover = Date().timeIntervalSince(started) >= 4
  }

  /// A cloud song stays on wasPlaying false until audio starts. Hold a spinner until the playhead moves.
  private func resolveBuffer(_ resolved: inout Track) {
    if resolved.title.isEmpty {
      bufferArm = nil
      awaitingAudio = false
      resolved.buffering = false
      lastTrackKey = ""
      lastAudible = false
      lastElapsed = 0
      return
    }
    let key = resolved.trackKey
    let elapsed = resolved.elapsed
    let audible = resolved.playing
    if var arm = bufferArm {
      let playheadMoved = !arm.waitForNewTrack && key == arm.key && elapsed > arm.elapsed + 0.05
      if Date().timeIntervalSince(arm.since) >= 20 {
        bufferArm = nil
        awaitingAudio = false
        resolved.buffering = false
      } else if audible || playheadMoved {
        bufferArm = nil
        awaitingAudio = false
        resolved.buffering = false
        resolved.playing = true
      } else if arm.waitForNewTrack {
        if key != arm.key || elapsed + 1 < arm.elapsed {
          arm = BufferArm(waitForNewTrack: false, key: key, elapsed: elapsed, since: arm.since)
          bufferArm = arm
        }
        resolved.buffering = true
        resolved.playing = false
      } else if key != arm.key || elapsed + 0.5 < arm.elapsed {
        bufferArm = BufferArm(waitForNewTrack: false, key: key, elapsed: elapsed, since: key == arm.key ? arm.since : Date())
        resolved.buffering = true
        resolved.playing = false
      } else {
        resolved.buffering = true
        resolved.playing = false
      }
    } else if pendingPlaying == false {
      resolved.buffering = false
    } else if !lastTrackKey.isEmpty, key != lastTrackKey, lastAudible || pendingPlaying == true {
      if audible {
        awaitingAudio = false
        resolved.buffering = false
        resolved.playing = true
      } else {
        bufferArm = BufferArm(waitForNewTrack: false, key: key, elapsed: elapsed, since: Date())
        resolved.buffering = true
        resolved.playing = false
      }
    } else {
      resolved.buffering = false
      if !resolved.playing, key == lastTrackKey, elapsed > lastElapsed + 0.2 {
        resolved.playing = true
      }
    }
    lastTrackKey = key
    lastAudible = audible
    lastElapsed = elapsed
  }

  /// Keep looking for the whole song. A cloud download can land long after the track starts.
  private func readArtworkWhenIdle(_ artworkID: String) {
    guard !artworkReadInFlight else { return }
    artworkReadInFlight = true
    retryingArtworkID = artworkID
    queue.async { [weak self] in
      self?.readArtwork(artworkID)
      self?.artworkReadInFlight = false
    }
  }

  private func readArtwork(_ artworkID: String) {
    lock.lock()
    let accountID = self.accountID
    let currentID = track.artworkID
    lock.unlock()
    guard currentID == artworkID else { return }
    guard let image = artworkImage(accountID: accountID, artworkID: artworkID) else { return }
    lock.lock()
    let changed = track.artworkID == artworkID && (track.artwork !== image || track.dropStaleCover)
    if changed {
      track.artwork = image
      track.dropStaleCover = false
    }
    lock.unlock()
    if missingSince?.id == artworkID {
      missingSince = nil
    }
    guard changed else { return }
    DispatchQueue.main.async { [weak self] in
      self?.onChange()
    }
  }

  private func load() -> Track {
    guard Self.isRunning() else { return Track() }
    let directory = Self.playbackDirectory()
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey]
    ) else {
      return Track()
    }

    let positions = urls
      .filter { $0.lastPathComponent.hasSuffix("-position.json") }
      .sorted { lhs, rhs in
        let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return left > right
      }

    var fallback: Track?
    for url in positions {
      guard let position = decode(PositionFile.self, from: url) else { continue }
      let queueURL = url.deletingLastPathComponent().appendingPathComponent(
        url.lastPathComponent.replacingOccurrences(of: "-position.json", with: "-queue.json")
      )
      guard let queueFile = decode(QueueFile.self, from: queueURL),
            queueFile.queue.indices.contains(position.currentIndex)
      else { continue }
      let item = queueFile.queue[position.currentIndex]
      let artworkID = item.artworkID ?? ""
      watchArtwork(accountID: position.accountID)
      accountID = position.accountID
      let next = Track(
        title: item.title ?? "",
        artist: item.artistName ?? "",
        album: item.albumTitle ?? "",
        playing: position.wasPlaying,
        audible: position.wasPlaying,
        artworkID: artworkID,
        artwork: cachedArtwork(accountID: position.accountID, artworkID: artworkID),
        elapsed: position.elapsedTime ?? 0,
        trackKey: "\(position.currentIndex)\u{1f}\(item.title ?? "")"
      )
      if next.playing { return next }
      if fallback == nil { fallback = next }
    }
    return fallback ?? Track()
  }

  private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private static var reportedPlaying = false

  static func isPlaying() -> Bool {
    guard isRunning() else { return false }
    if reportedPlaying { return true }
    let directory = playbackDirectory()
    guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
      return false
    }
    for url in urls where url.lastPathComponent.hasSuffix("-position.json") {
      guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["wasPlaying"] as? Bool == true
      else { continue }
      return true
    }
    return false
  }

  /// The song AmpSonic is playing, so a later choice in that app can be told from this one.
  static func currentTrackID() -> String? {
    guard isRunning() else { return nil }
    let directory = playbackDirectory()
    guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
      return nil
    }
    for url in urls where url.lastPathComponent.hasSuffix("-position.json") {
      guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["wasPlaying"] as? Bool == true,
            let index = (json["currentIndex"] as? NSNumber)?.intValue
      else { continue }
      let queueURL = url.deletingLastPathComponent().appendingPathComponent(
        url.lastPathComponent.replacingOccurrences(of: "-position.json", with: "-queue.json")
      )
      guard let queueData = try? Data(contentsOf: queueURL),
            let queueJSON = try? JSONSerialization.jsonObject(with: queueData) as? [String: Any],
            let queue = queueJSON["queue"] as? [[String: Any]],
            queue.indices.contains(index)
      else { return "\(index)" }
      let item = queue[index]
      let title = item["title"] as? String ?? ""
      let artist = item["artistName"] as? String ?? ""
      return "\(title)\u{1}\(artist)"
    }
    return nil
  }

  private static func isRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
  }

  private func cachedArtwork(accountID: String, artworkID: String) -> NSImage? {
    guard !accountID.isEmpty, !artworkID.isEmpty else { return nil }
    return artworkCache["\(accountID)|\(artworkID)"]
  }

  /// AmpSonic names each cached cover `SHA256("\(accountID)|\(artworkID)")`.
  private func artworkImage(accountID: String, artworkID: String) -> NSImage? {
    guard !accountID.isEmpty, !artworkID.isEmpty else { return nil }
    let key = "\(accountID)|\(artworkID)"
    if let cached = artworkCache[key] { return cached }
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    let url = Self.supportDirectory()
      .appendingPathComponent("Artwork", isDirectory: true)
      .appendingPathComponent(accountID, isDirectory: true)
      .appendingPathComponent(digest)
    guard let image = NSImage(contentsOf: url),
          image.size.width > 1,
          image.size.height > 1
    else { return nil }
    if artworkCache.count > 32, let oldest = artworkCache.keys.first {
      artworkCache.removeValue(forKey: oldest)
    }
    artworkCache[key] = image
    return image
  }

  private func watchArtwork(accountID: String) {
    guard !accountID.isEmpty, artworkWatches[accountID] == nil else { return }
    let directory = Self.supportDirectory()
      .appendingPathComponent("Artwork", isDirectory: true)
      .appendingPathComponent(accountID, isDirectory: true)
    let fd = open(directory.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .rename, .delete],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.refresh()
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    artworkWatches[accountID] = source
  }

  static func playbackDirectory() -> URL {
    supportDirectory().appendingPathComponent("Playback", isDirectory: true)
  }

  private static func supportDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Containers", isDirectory: true)
      .appendingPathComponent(bundleID, isDirectory: true)
      .appendingPathComponent("Data/Library/Application Support/AmpSonic", isDirectory: true)
  }

}
