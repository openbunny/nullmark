import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

private let disabledOpacity = 0.5

struct LinkButtonStyle: ButtonStyle {
  @Environment(\.isEnabled)
  private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.themeBody)
      .foregroundStyle(Color.ink)
      .underline(color: configuration.isPressed ? Color.ink : Color.line)
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : disabledOpacity)
  }
}

extension ButtonStyle where Self == LinkButtonStyle {
  static var inkLink: LinkButtonStyle { LinkButtonStyle() }
}
