import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

@main
struct NullmarkApp: App {
  init() {
    do {
      try Fonts.register()
    } catch {
      print("NullmarkApp: font registration failed: \(error.localizedDescription)")
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .frame(minWidth: 960, minHeight: 640)
        .openbunnyTheme()
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1_240, height: 800)
  }
}
