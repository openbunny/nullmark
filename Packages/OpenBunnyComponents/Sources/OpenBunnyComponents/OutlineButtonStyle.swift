import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

private let minimumHeight: CGFloat = 24
private let disabledOpacity = 0.5

public struct OutlineButtonStyle: ButtonStyle {
  @Environment(\.isEnabled)
  private var isEnabled

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.themeCaption)
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
  /// A square, 1-point bordered button in the caption face, dimmed when disabled.
  public static var outline: OutlineButtonStyle { OutlineButtonStyle() }
}
