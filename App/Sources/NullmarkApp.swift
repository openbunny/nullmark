import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

@main
struct NullmarkApp: App {
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
