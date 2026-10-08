import AppKit

//  MIT License
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//
// Adapted from DSFDockTile library by Darren Ford
// Original files: DSFDockTile+Core.swift + DSFDockTile+ViewController.swift
// Original sources at:
// https://github.com/dagronf/DSFDockTile/blob/main/Sources/DSFDockTile/DSFDockTile%2BViewController.swift
// https://github.com/dagronf/DSFDockTile/blob/main/Sources/DSFDockTile/DSFDockTile%2BCore.swift

public class DockBaseType {
  internal weak var dockTile: NSDockTile?

  public var badgeLabel: String? {
    didSet {
      self.dockTile?.badgeLabel = self.badgeLabel
    }
  }

  internal init(dockTile: NSDockTile = NSApp.dockTile) {
    self.dockTile = dockTile
  }
}

public class DockTileView: DockBaseType {
  internal weak var viewController: NSViewController?
  /// Last tile that actually drew. A blank SwiftUI frame would otherwise show the app icon.
  private let backing = NSImageView()

  public init(_ viewController: NSViewController, dockTile: NSDockTile = NSApp.dockTile) {
    self.viewController = viewController
    super.init(dockTile: dockTile)
    backing.imageScaling = .scaleAxesIndependently
  }

  public func display() {
    precondition(Thread.isMainThread)

    guard let tile = dockTile,
          let vc = viewController
    else {
      return
    }

    if tile.contentView !== vc.view {
      tile.contentView = vc.view
    }
    let bounds = NSRect(origin: .zero, size: tile.size)
    vc.view.frame = bounds
    if backing.superview !== vc.view {
      vc.view.addSubview(backing, positioned: .below, relativeTo: nil)
    }
    backing.frame = bounds
    for subview in vc.view.subviews where subview !== backing {
      subview.frame = bounds
      subview.layoutSubtreeIfNeeded()
      subview.frame = bounds
      if let drawn = capture(subview) {
        backing.image = drawn
      }
    }

    tile.display()
  }

  /// Draws one view. A clear frame is ignored so the previous cover stays up.
  private func capture(_ view: NSView) -> NSImage? {
    let bounds = view.bounds
    guard bounds.width > 1, bounds.height > 1 else { return nil }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
    view.cacheDisplay(in: bounds, to: rep)
    guard repHasPixels(rep) else { return nil }
    let image = NSImage(size: bounds.size)
    image.addRepresentation(rep)
    return image
  }

  private func repHasPixels(_ rep: NSBitmapImageRep) -> Bool {
    guard let data = rep.bitmapData else { return false }
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    guard width > 0, height > 0 else { return false }
    let bytesPerPixel = max(rep.bitsPerPixel / 8, 1)
    let step = max(1, min(width, height) / 16)
    var opaque = 0
    var samples = 0
    for y in stride(from: 0, to: height, by: step) {
      for x in stride(from: 0, to: width, by: step) {
        let offset = y * rep.bytesPerRow + x * bytesPerPixel
        let alpha: UInt8
        if !rep.hasAlpha {
          alpha = 255
        } else if rep.bitmapFormat.contains(.alphaFirst) {
          alpha = data[offset]
        } else {
          alpha = data[offset + bytesPerPixel - 1]
        }
        if alpha > 20 { opaque += 1 }
        samples += 1
      }
    }
    return samples > 0 && opaque * 5 > samples
  }
}
