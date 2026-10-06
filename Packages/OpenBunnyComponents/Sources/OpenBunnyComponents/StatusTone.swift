import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

public enum StatusTone: Sendable, CaseIterable {
  case failed
  case neutral
  case valid

  var color: Color {
    switch self {
    case .neutral:
      Color.muted

    case .valid:
      Status.enabled.color

    case .failed:
      Status.disabled.color
    }
  }
}
