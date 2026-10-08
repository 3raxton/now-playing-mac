import AppKit
import ApplicationServices

enum UpdateCheck {
  private static let latest = URL(string: "https://api.github.com/repos/3raxton/now-playing-mac/releases/latest")!
  private static var checking = false
  private static var postponed = false
  private static var timer: Timer?

  /// Quiet check after launch, then once a day while the app stays open.
  static func schedule() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
      start(interactive: false)
    }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 60 * 60 * 24, repeats: true) { _ in
      start(interactive: false)
    }
  }

  static func start(interactive: Bool = true) {
    if checking { return }
    if !interactive {
      if postponed || !AXIsProcessTrusted() { return }
    }
    checking = true
    Task {
      let outcome = await lookup()
      await MainActor.run {
        checking = false
        present(outcome, interactive: interactive)
      }
    }
  }

  enum Outcome {
    case upToDate(String)
    case available(version: String, current: String, notes: String, file: URL)
    case noDownload
    case failed
  }

  static func lookup() async -> Outcome {
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    var request = URLRequest(url: latest)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("NowPlaying", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 15
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String else {
        return .failed
      }
      let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
      guard isNewer(version, than: current) else { return .upToDate(current) }
      guard let file = downloadURL(in: json["assets"] as? [[String: Any]] ?? []) else {
        return .noDownload
      }
      let notes = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return .available(version: version, current: current, notes: notes, file: file)
    } catch {
      return .failed
    }
  }

  static func present(_ outcome: Outcome, interactive: Bool) {
    switch outcome {
    case .available(let version, let current, let notes, let file):
      UpdateWindow.show(version: version, current: current, notes: notes, file: file)
    case .upToDate(let current):
      guard interactive else { return }
      alert("You're up to date"~, String(format: "Now Playing %@ is the latest version."~, current))
    case .noDownload:
      guard interactive else { return }
      alert("Couldn't check for updates"~, "This release has no app to download."~)
    case .failed:
      guard interactive else { return }
      alert("Couldn't check for updates"~, "Check your connection and try again."~)
    }
  }

  static func postpone() {
    postponed = true
  }

  private static func alert(_ title: String, _ body: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = body
    alert.runModal()
  }

  /// A zip or disk image attached to the release. GitHub's source archive is not an asset.
  private static func downloadURL(in assets: [[String: Any]]) -> URL? {
    let files: [(name: String, url: URL)] = assets.compactMap { item in
      guard let name = item["name"] as? String,
            let link = item["browser_download_url"] as? String,
            let url = URL(string: link) else { return nil }
      let kind = name.lowercased()
      guard kind.hasSuffix(".zip") || kind.hasSuffix(".dmg") else { return nil }
      return (name, url)
    }
    return files.max { rank($0.name) < rank($1.name) }?.url
  }

  private static func rank(_ name: String) -> Int {
    let lower = name.lowercased()
    var score = lower.hasSuffix(".zip") ? 2 : 1
    if lower.contains("now playing") || lower.contains("now-playing") || lower.contains("nowplaying") {
      score += 2
    }
    return score
  }

  private static func isNewer(_ remote: String, than local: String) -> Bool {
    let left = parts(remote)
    let right = parts(local)
    let count = max(left.count, right.count)
    for index in 0..<count {
      let next = index < left.count ? left[index] : 0
      let current = index < right.count ? right[index] : 0
      if next != current { return next > current }
    }
    return false
  }

  private static func parts(_ version: String) -> [Int] {
    version.split(separator: ".").map { Int($0) ?? 0 }
  }
}

/// Downloads a release and replaces this app, then relaunches.
final class UpdateWindow: NSObject, URLSessionDownloadDelegate {
  private static var current: UpdateWindow?

  private let file: URL
  private let window: NSWindow
  private let progress = NSProgressIndicator()
  private let status = NSTextField(labelWithString: "")
  private let installButton: NSButton
  private let laterButton: NSButton
  private var session: URLSession?
  private var downloaded: URL?
  private let workDirectory: URL

  static func show(version: String, current installed: String, notes: String, file: URL) {
    if Self.current != nil { return }
    let window = UpdateWindow(version: version, current: installed, notes: notes, file: file)
    self.current = window
    window.present()
  }

  private init(version: String, current: String, notes: String, file: URL) {
    self.file = file
    workDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("now-playing-update-\(UUID().uuidString)", isDirectory: true)
    let icon = NSImageView()
    icon.image = NSApp.applicationIconImage
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

    let title = NSTextField(labelWithString: "Update available"~)
    title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let detail = NSTextField(wrappingLabelWithString: String(format: "Now Playing %@ is available. You have %@."~, version, current))
    detail.font = NSFont.systemFont(ofSize: 13)
    detail.preferredMaxLayoutWidth = 340
    let heading = NSTextField(labelWithString: "What's New"~)
    heading.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    heading.textColor = .secondaryLabelColor
    let notesView = Self.changelog(notes)

    progress.isIndeterminate = false
    progress.minValue = 0
    progress.maxValue = 1
    progress.doubleValue = 0
    progress.isHidden = true
    progress.translatesAutoresizingMaskIntoConstraints = false
    progress.widthAnchor.constraint(equalToConstant: 280).isActive = true

    status.font = NSFont.systemFont(ofSize: 12)
    status.textColor = .secondaryLabelColor
    status.isHidden = true

    let later = NSButton(title: "Not Now"~, target: nil, action: #selector(later(_:)))
    later.bezelStyle = .rounded
    let install = NSButton(title: "Install Update"~, target: nil, action: #selector(install(_:)))
    install.bezelStyle = .rounded
    install.keyEquivalent = "\r"
    laterButton = later
    installButton = install

    let buttons = NSStackView(views: [later, install])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    buttons.alignment = .centerY

    let textColumn = NSStackView(views: [title, detail, heading, notesView, status, progress])
    textColumn.orientation = .vertical
    textColumn.alignment = .leading
    textColumn.spacing = 6

    let body = NSStackView(views: [icon, textColumn])
    body.orientation = .horizontal
    body.alignment = .top
    body.spacing = 16

    let root = NSStackView(views: [body, buttons])
    root.orientation = .vertical
    root.alignment = .trailing
    root.spacing = 18
    root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
    root.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView()
    content.addSubview(root)
    NSLayoutConstraint.activate([
      root.topAnchor.constraint(equalTo: content.topAnchor),
      root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      content.widthAnchor.constraint(equalToConstant: 480)
    ])

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Update available"~
    window.contentView = content
    window.isReleasedWhenClosed = false
    super.init()
    later.target = self
    install.target = self
    window.delegate = self
  }

  private static func changelog(_ notes: String) -> NSScrollView {
    let text = NSTextView()
    text.isEditable = false
    text.isSelectable = true
    text.drawsBackground = false
    text.isRichText = true
    text.textContainerInset = NSSize(width: 6, height: 8)
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.minSize = NSSize(width: 0, height: 0)
    text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    text.textContainer?.widthTracksTextView = true
    text.textContainer?.containerSize = NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude)
    let source = notes.isEmpty ? "No release notes for this update."~ : notes
    if #available(macOS 12, *),
       let markdown = try? NSAttributedString(
         markdown: Data(source.utf8),
         options: .init(interpretedSyntax: .full)
       ) {
      text.textStorage?.setAttributedString(markdown)
    } else {
      text.font = NSFont.systemFont(ofSize: 13)
      text.string = source
    }
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = true
    scroll.backgroundColor = .textBackgroundColor
    scroll.borderType = .bezelBorder
    scroll.documentView = text
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
    scroll.widthAnchor.constraint(equalToConstant: 360).isActive = true
    return scroll
  }

  private func present() {
    NSApp.activate(ignoringOtherApps: true)
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  @objc private func later(_ sender: Any?) {
    session?.invalidateAndCancel()
    UpdateCheck.postpone()
    close()
  }

  @objc private func install(_ sender: Any?) {
    installButton.isEnabled = false
    laterButton.isEnabled = true
    progress.isHidden = false
    progress.doubleValue = 0
    progress.isIndeterminate = true
    progress.startAnimation(nil)
    status.stringValue = "Downloading update…"~
    status.isHidden = false
    do {
      try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    } catch {
      fail()
      return
    }
    var request = URLRequest(url: file)
    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    request.setValue("NowPlaying", forHTTPHeaderField: "User-Agent")
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    self.session = session
    session.downloadTask(with: request).resume()
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard totalBytesExpectedToWrite > 0 else { return }
    progress.isIndeterminate = false
    progress.doubleValue = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    let destination = workDirectory.appendingPathComponent(file.lastPathComponent)
    try? FileManager.default.removeItem(at: destination)
    do {
      try FileManager.default.moveItem(at: location, to: destination)
      downloaded = destination
    } catch {
      downloaded = nil
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
    guard error == nil, let downloaded else {
      fail()
      return
    }
    status.stringValue = "Installing update…"~
    progress.isIndeterminate = true
    progress.startAnimation(nil)
    laterButton.isEnabled = false
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let prepared = Self.prepare(downloaded)
      DispatchQueue.main.async {
        guard let self else { return }
        guard let prepared else {
          self.fail()
          return
        }
        self.relaunch(prepared)
      }
    }
  }

  private func fail() {
    progress.stopAnimation(nil)
    progress.isHidden = true
    status.stringValue = "The update could not be installed."~
    status.textColor = .systemRed
    status.isHidden = false
    installButton.isEnabled = true
    laterButton.isEnabled = true
    session?.invalidateAndCancel()
    session = nil
  }

  private struct PreparedUpdate {
    let app: URL
    let mount: String
    let cleanup: String
  }

  private static func prepare(_ file: URL) -> PreparedUpdate? {
    let folder = file.deletingLastPathComponent().appendingPathComponent("contents", isDirectory: true)
    try? FileManager.default.removeItem(at: folder)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let kind = file.pathExtension.lowercased()
    if kind == "zip" {
      guard unpackZip(file, into: folder), let app = appBundle(in: folder) else { return nil }
      return PreparedUpdate(app: app, mount: "", cleanup: folder.path)
    }
    if kind == "dmg" {
      guard let mount = attach(file), let app = appBundle(in: URL(fileURLWithPath: mount)) else { return nil }
      return PreparedUpdate(app: app, mount: mount, cleanup: "")
    }
    return nil
  }

  private static func unpackZip(_ file: URL, into folder: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-xk", file.path, folder.path]
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  private static func attach(_ file: URL) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = ["attach", "-nobrowse", "-readonly", "-plist", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }
    guard process.terminationStatus == 0,
          let data = try? pipe.fileHandleForReading.readToEnd(),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
    return entities.compactMap { $0["mount-point"] as? String }.first { !$0.isEmpty }
  }

  private static func appBundle(in folder: URL) -> URL? {
    guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
    var fallback: URL?
    for case let url as URL in items {
      guard url.pathExtension == "app" else { continue }
      let path = url.path
      if path.contains(".app/") { continue }
      if url.lastPathComponent == "Now Playing.app" { return url }
      fallback = fallback ?? url
    }
    return fallback
  }

  private func relaunch(_ update: PreparedUpdate) {
    guard let destination = Self.destination() else {
      if !update.mount.isEmpty {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", update.mount, "-quiet"]
        try? detach.run()
      }
      fail()
      return
    }
    let command = Self.swapScript(
      pid: ProcessInfo.processInfo.processIdentifier,
      source: update.app.path,
      destination: destination.path,
      mount: update.mount,
      cleanup: update.cleanup
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      fail()
      return
    }
    NSApp.terminate(nil)
  }

  /// A disk image cannot be replaced in place. Install into Applications instead.
  private static func destination() -> URL? {
    let running = Bundle.main.bundleURL
    let readOnly = (try? running.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    let destination = readOnly
      ? URL(fileURLWithPath: "/Applications").appendingPathComponent(running.lastPathComponent)
      : running
    guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { return nil }
    return destination
  }

  private static func swapScript(pid: Int32, source: String, destination: String, mount: String, cleanup: String) -> String {
    let src = quote(source)
    let dest = quote(destination)
    let previous = quote(destination + ".previous")
    let detach = mount.isEmpty ? "" : "hdiutil detach \(quote(mount)) -quiet || true"
    let removeDownload = cleanup.isEmpty ? "" : "rm -rf \(quote(cleanup))"
    return """
    ( while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
      rm -rf \(previous)
      if [ -d \(dest) ]; then mv \(dest) \(previous); fi
      if ditto \(src) \(dest); then
        rm -rf \(previous)
        xattr -dr com.apple.quarantine \(dest) || true
        \(detach)
        \(removeDownload)
        open \(dest)
      else
        rm -rf \(dest)
        if [ -d \(previous) ]; then mv \(previous) \(dest); fi
        \(detach)
        open \(dest)
      fi
    ) >/dev/null 2>&1 &
    disown
    """
  }

  private static func quote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func close() {
    window.close()
    UpdateWindow.current = nil
  }
}

extension UpdateWindow: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    session?.invalidateAndCancel()
    UpdateCheck.postpone()
    UpdateWindow.current = nil
  }
}
