import SwiftUI

class DockViewController: NSViewController {
  var dockData: DockData?
 
  override func loadView() {
    view = NSView()
    if let data = dockData {
      let content = DockImage().environmentObject(data)
      let hosting = NSHostingView(rootView: content)
      hosting.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
      self.view.addSubview(hosting)
    }
  }

  func update(_ dockData: DockData?) {
    guard self.dockData == nil else { return }
    self.dockData = dockData
  }
}
