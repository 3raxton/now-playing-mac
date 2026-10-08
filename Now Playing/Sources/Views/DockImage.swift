import SwiftUI

struct DockImage: View {
  @EnvironmentObject var data: DockData

  func getFallbackIcon() -> NSImage {
    let player = AppSettings.default.player()
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.getAppId()) {
      return NSWorkspace.shared.icon(forFile: url.path)
    }
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.getAppId()).first,
       let icon = app.icon
    {
      return icon
    }
    return NSImage(named: "AppIcon")!
  }

  func hasInfo() -> Bool {
    return !data.isEmpty()
  }

  var body: some View {
    ZStack {
      If(!hasInfo()) {
        tileImage(getFallbackIcon())
      }
      If(hasInfo() && data.artwork == nil) {
        tileImage(NSApp.applicationIconImage)
        Color.black.opacity(0.3)
          .mask(tileImage(NSApp.applicationIconImage))
        playbackOverlay()
      }
      If(hasInfo() && data.artwork != nil) {
        ZStack {
          tileImage(data.artwork ?? NSApp.applicationIconImage)
            .clipShape(MacIconShape())
            .shadow(color: .black.opacity(0.36), radius: 1, x: 1, y: 2)
            .id(data.artwork.map { ObjectIdentifier($0) })
          MacIconShape()
            .fill(Color.black)
            .opacity(0.3)
          playbackOverlay(onArtwork: true)
        }
        .frame(width: MacIconShape.side, height: MacIconShape.side)
      }
    }
    .frame(width: 128, height: 128)
  }

  private func tileImage(_ image: NSImage) -> some View {
    Image(nsImage: image)
      .interpolation(.high)
      .antialiased(true)
      .resizable()
  }

  private func playbackOverlay(onArtwork: Bool = false) -> some View {
    ZStack {
      DockTitle(song: data.song, artist: data.artist, onArtwork: onArtwork)
        .opacity(data.playing && !data.buffering ? 1 : 0)
      If(data.buffering) {
        Circle()
          .trim(from: 0.12, to: 0.78)
          .stroke(
            Color.white.opacity(0.92),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
          )
          .frame(width: 26, height: 26)
          .rotationEffect(.degrees(data.bufferSpin))
          .shadow(color: .black.opacity(0.36), radius: 1, x: 1, y: 2)
      }
      If(!data.playing && !data.buffering) {
        Image(systemName: "play.fill")
          .interpolation(.high)
          .antialiased(true)
          .resizable()
          .shadow(color: .black.opacity(0.36), radius: 1, x: 1, y: 2)
          .frame(width: 32, height: 32)
          .foregroundColor(.white)
          .opacity(0.85)
      }
    }
  }
}

/// Song and artist stay at body size. The fixed icon shows as many lines as that size allows.
private struct DockTitle: View {
  let song: String
  let artist: String
  var onArtwork: Bool

  var body: some View {
    GeometryReader { geo in
      let horizontal: CGFloat = onArtwork ? 6 : 16
      let top: CGFloat = onArtwork ? 6 : 4
      let bottom: CGFloat = onArtwork ? 4 : 4
      let width = max(0, geo.size.width - horizontal * 2)
      let height = max(0, geo.size.height - top - bottom)
      let split = DockTitleLayout.split(song: song, artist: artist, width: width, height: height)
      VStack(spacing: 0) {
        if split.songLines > 0 {
          Text(song)
            .lineLimit(split.songLines)
            .truncationMode(.tail)
        }
        if split.artistLines > 0 {
          Text(artist)
            .lineLimit(split.artistLines)
            .truncationMode(.tail)
        }
      }
      .foregroundColor(.white)
      .font(Font.body.weight(.semibold))
      .multilineTextAlignment(.center)
      .frame(width: width, height: height, alignment: .center)
      .position(x: horizontal + width / 2, y: top + height / 2)
    }
    .clipped()
  }
}

/// Music and Finder draw this squircle: 206 points on a 256-point icon, continuous corner 47.
private struct MacIconShape: Shape {
  static let side: CGFloat = 128 * 206 / 256
  private static let cornerRatio: CGFloat = 47.0 / 206.0

  func path(in rect: CGRect) -> Path {
    Path(roundedRect: rect, cornerRadius: rect.width * MacIconShape.cornerRatio, style: .continuous)
  }
}

private enum DockTitleLayout {
  static let font: NSFont = {
    let body = NSFont.preferredFont(forTextStyle: .body)
    return NSFont.systemFont(ofSize: body.pointSize, weight: .semibold)
  }()

  static let lineHeight: CGFloat = measure("Ag", width: 1000)

  static func split(song: String, artist: String, width: CGFloat, height: CGFloat) -> (songLines: Int, artistLines: Int) {
    guard width > 1, height > 1 else { return (0, 0) }
    let capacity = max(1, Int(floor(height / lineHeight)))
    let songNeed = lineCount(song, width: width)
    let artistNeed = lineCount(artist, width: width)
    if songNeed == 0 {
      return (0, min(artistNeed, capacity))
    }
    if artistNeed == 0 {
      return (min(songNeed, capacity), 0)
    }
    if songNeed + artistNeed <= capacity {
      return (songNeed, artistNeed)
    }
    let songLines = min(songNeed, capacity - 1)
    return (songLines, capacity - songLines)
  }

  private static func lineCount(_ text: String, width: CGFloat) -> Int {
    guard !text.isEmpty else { return 0 }
    let height = measure(text, width: width)
    return max(1, Int(ceil(height / lineHeight - 0.01)))
  }

  private static func measure(_ text: String, width: CGFloat) -> CGFloat {
    (text as NSString).boundingRect(
      with: NSSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font]
    ).height
  }
}
