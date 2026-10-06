import AppKit
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
    var artworkID = ""
    var artwork: NSImage?

    static func == (lhs: Track, rhs: Track) -> Bool {
      lhs.title == rhs.title
        && lhs.artist == rhs.artist
        && lhs.album == rhs.album
        && lhs.playing == rhs.playing
        && lhs.artworkID == rhs.artworkID
        && lhs.artwork === rhs.artwork
    }
  }

  private struct PositionFile: Decodable {
    let accountID: String
    let currentIndex: Int
    let wasPlaying: Bool
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

  private let onChange: () -> Void
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "nowplaying.ampsonic")
  private var track = Track()
  private var artworkCache: [String: NSImage] = [:]
  private var pendingPlaying: Bool?
  private var pendingUntil = Date.distantPast
  private var retryingArtworkID: String?
  private var source: DispatchSourceFileSystemObject?
  private var timer: Timer?

  init(onChange: @escaping () -> Void) {
    self.onChange = onChange
  }

  func currentTrack() -> Track {
    lock.lock()
    defer { lock.unlock() }
    return track
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
    let timer = self.timer
    self.timer = nil
    if Thread.isMainThread {
      timer?.invalidate()
    } else {
      DispatchQueue.main.async { timer?.invalidate() }
    }
  }

  func playPause() {
    postKey(49, flags: [])
    lock.lock()
    track.playing.toggle()
    pendingPlaying = track.playing
    pendingUntil = Date().addingTimeInterval(2)
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.onChange()
    }
    scheduleRefresh()
  }

  func nextTrack() {
    postKey(124, flags: .maskCommand)
    markPlaying()
    scheduleRefresh()
  }

  func previousTrack() {
    postKey(123, flags: .maskCommand)
    markPlaying()
    scheduleRefresh()
  }

  /// Space toggles playback. Command-Left and Command-Right are AmpSonic's previous and next shortcuts.
  private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
    down.flags = flags
    up.flags = flags
    down.postToPid(application.processIdentifier)
    up.postToPid(application.processIdentifier)
  }

  private func markPlaying() {
    lock.lock()
    track.playing = true
    pendingPlaying = true
    pendingUntil = Date().addingTimeInterval(2)
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.onChange()
    }
  }

  private func scheduleRefresh() {
    for delay in [0.25, 0.7, 1.2] {
      queue.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.refresh()
      }
    }
  }

  private func watchPlaybackDirectory() {
    guard let path = Self.playbackDirectory()?.path else { return }
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
    lock.lock()
    let artworkPending = next.artwork == nil
      && !next.artworkID.isEmpty
      && !next.title.isEmpty
      && !track.title.isEmpty
      && next.artworkID != track.artworkID
    if artworkPending {
      let artworkID = next.artworkID
      lock.unlock()
      retryArtwork(artworkID)
      return
    }
    if retryingArtworkID == next.artworkID {
      retryingArtworkID = nil
    }
    var resolved = next
    if let pendingPlaying {
      if resolved.playing == pendingPlaying || Date() >= pendingUntil {
        self.pendingPlaying = nil
      } else {
        resolved.playing = pendingPlaying
      }
    }
    let changed = resolved != track
    if changed {
      track = resolved
    }
    lock.unlock()
    if changed {
      DispatchQueue.main.async { [weak self] in
        self?.onChange()
      }
    }
  }

  /// Check once more for a cover that is still being written. The regular timer keeps looking after that.
  private func retryArtwork(_ artworkID: String) {
    guard !artworkID.isEmpty, retryingArtworkID != artworkID else { return }
    retryingArtworkID = artworkID
    queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.refresh()
    }
  }

  private func load() -> Track {
    guard Self.isRunning() else { return Track() }
    guard let directory = Self.playbackDirectory() else { return Track() }
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
      let next = Track(
        title: item.title ?? "",
        artist: item.artistName ?? "",
        album: item.albumTitle ?? "",
        playing: position.wasPlaying,
        artworkID: artworkID,
        artwork: artworkImage(accountID: position.accountID, artworkID: artworkID)
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

  static func isPlaying() -> Bool {
    guard isRunning() else { return false }
    guard let directory = playbackDirectory() else { return false }
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

  private static func isRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
  }

  /// AmpSonic names each cached cover `SHA256("\(accountID)|\(artworkID)")`.
  private func artworkImage(accountID: String, artworkID: String) -> NSImage? {
    guard !accountID.isEmpty, !artworkID.isEmpty else { return nil }
    let key = "\(accountID)|\(artworkID)"
    if let cached = artworkCache[key] { return cached }
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    guard let support = Self.supportDirectory() else { return nil }
    let url = support
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

  private static let bookmarkKey = "ampSonicSupportBookmark"
  private static let accessLock = NSLock()
  private static var scopedSupportURL: URL?
  private static var askedThisLaunch = false

  private static func playbackDirectory() -> URL? {
    supportDirectory()?.appendingPathComponent("Playback", isDirectory: true)
  }

  /// Uses a saved folder approval so macOS does not ask to read AmpSonic on every launch.
  private static func supportDirectory() -> URL? {
    accessLock.lock()
    if let scopedSupportURL {
      accessLock.unlock()
      return scopedSupportURL
    }
    let stored = UserDefaults.standard.data(forKey: bookmarkKey)
    accessLock.unlock()

    if let stored {
      var stale = false
      if let url = try? URL(
        resolvingBookmarkData: stored,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      ), url.startAccessingSecurityScopedResource() {
        accessLock.lock()
        scopedSupportURL = url
        accessLock.unlock()
        if stale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
          UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
        }
        return url
      }
    }

    requestAccessIfNeeded()
    return nil
  }

  private static func requestAccessIfNeeded() {
    DispatchQueue.main.async {
      accessLock.lock()
      let alreadyAsked = askedThisLaunch || scopedSupportURL != nil
      if !alreadyAsked { askedThisLaunch = true }
      accessLock.unlock()
      guard !alreadyAsked else { return }

      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = false
      panel.allowsMultipleSelection = false
      panel.showsHiddenFiles = true
      panel.prompt = "Allow"
      panel.message = "Allow Now Playing to read AmpSonic so the Dock can show the current track. This is only needed once."
      panel.directoryURL = containerSupportURL()
      NSApp.activate(ignoringOtherApps: true)
      panel.begin { response in
        guard response == .OK, let url = panel.url else { return }
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        _ = url.startAccessingSecurityScopedResource()
        accessLock.lock()
        scopedSupportURL = url
        accessLock.unlock()
      }
    }
  }

  private static func containerSupportURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Containers", isDirectory: true)
      .appendingPathComponent(bundleID, isDirectory: true)
      .appendingPathComponent("Data/Library/Application Support/AmpSonic", isDirectory: true)
  }

}
