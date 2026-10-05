import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI
import os

@main
struct NullmarkApp: App {
  init() {
    do {
      try Fonts.register()
    } catch {
      Logger(subsystem: "dev.openbunny.nullmark", category: "fonts").error(
        "Font registration failed, using system fonts: \(error.localizedDescription, privacy: .public)"
      )
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
