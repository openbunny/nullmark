import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

struct OutlineButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.themeCaption.weight(.semibold))
      .foregroundStyle(Color.foreground)
      .padding(.horizontal, Spacing.base)
      .padding(.vertical, Spacing.tight)
      .frame(minHeight: 24)
      .background(configuration.isPressed ? Color.paperInset : Color.paper)
      .overlay(Rectangle().stroke(Color.border, lineWidth: Metric.borderWidth))
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.5)
  }
}

extension ButtonStyle where Self == OutlineButtonStyle {
  static var outline: OutlineButtonStyle { OutlineButtonStyle() }
}
