import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  var dockController: DockController?
  var dockMenuController: DockMenuController?

  func applicationDidBecomeActive(_: Notification) {
    
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    self.dockController?.click()
    return false
  }

  func applicationDidFinishLaunching(_: Notification) {
    AppSettings.default.setDefaults()
    installMainMenu()
    let controller = DockController()
    self.dockController = controller
    self.dockMenuController = DockMenuController(controller: controller)
    DispatchQueue.main.async {
      controller.requestAccessibility()
    }
    UpdateCheck.schedule()
  }

  private func installMainMenu() {
    let appMenu = NSMenu()
    let about = NSMenuItem(title: "About Now Playing"~, action: #selector(showAbout), keyEquivalent: "")
    about.target = self
    let updates = NSMenuItem(title: "Check for Updates…"~, action: #selector(checkForUpdates), keyEquivalent: "")
    updates.target = self
    updates.image = AboutWindow.updateIcon(pointSize: 14)
    let quit = NSMenuItem(title: "Quit Now Playing"~, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenu.items = [about, updates, NSMenuItem.separator(), quit]

    let appMenuItem = NSMenuItem()
    appMenuItem.submenu = appMenu
    let mainMenu = NSMenu()
    mainMenu.addItem(appMenuItem)
    NSApp.mainMenu = mainMenu
  }

  @objc func showAbout() {
    AboutWindow.show()
  }

  @objc func checkForUpdates() {
    UpdateCheck.start()
  }

  func applicationWillTerminate(_: Notification) {
    self.dockController?.destroy()
  }
  
  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    return self.dockMenuController?.getMenu()
  }
}
