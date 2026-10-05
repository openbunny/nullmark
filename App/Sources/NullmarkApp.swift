import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI
import os

private let minimumWindowWidth: CGFloat = 960
private let minimumWindowHeight: CGFloat = 640
private let defaultWindowWidth: CGFloat = 1_240
private let defaultWindowHeight: CGFloat = 800

@main
struct NullmarkApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
        .frame(minWidth: minimumWindowWidth, minHeight: minimumWindowHeight)
        .openbunnyTheme()
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: defaultWindowWidth, height: defaultWindowHeight)
  }

  init() {
    do {
      try Fonts.register()
    } catch {
      Logger(subsystem: "dev.openbunny.nullmark", category: "fonts").error(
        "Font registration failed, using system fonts: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
