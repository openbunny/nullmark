import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

private let disabledOpacity = 0.5

public struct LinkButtonStyle: ButtonStyle {
  @Environment(\.isEnabled)
  private var isEnabled

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.themeBody)
      .foregroundStyle(Color.ink)
      .underline(color: configuration.isPressed ? Color.ink : Color.line)
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : disabledOpacity)
  }
}

extension ButtonStyle where Self == LinkButtonStyle {
  /// Ink text with a line-coloured underline, the websites' `.link` class.
  public static var inkLink: LinkButtonStyle { LinkButtonStyle() }
}
