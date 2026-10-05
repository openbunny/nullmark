import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

private let minimumHeight: CGFloat = 24
private let disabledOpacity = 0.5

struct OutlineButtonStyle: ButtonStyle {
  @Environment(\.isEnabled)
  private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.themeCaption.weight(.semibold))
      .foregroundStyle(Color.foreground)
      .padding(.horizontal, Spacing.base)
      .padding(.vertical, Spacing.tight)
      .frame(minHeight: minimumHeight)
      .background(configuration.isPressed ? Color.paperInset : Color.paper)
      .overlay(Rectangle().stroke(Color.border, lineWidth: Metric.borderWidth))
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : disabledOpacity)
  }
}

extension ButtonStyle where Self == OutlineButtonStyle {
  static var outline: OutlineButtonStyle { OutlineButtonStyle() }
}
