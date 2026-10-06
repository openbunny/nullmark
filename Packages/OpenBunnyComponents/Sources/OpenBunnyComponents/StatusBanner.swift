import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

private let markSide: CGFloat = 64

public struct StatusBanner<Mark: View, Actions: View>: View {
  private let title: String
  private let message: String
  private let mark: Mark
  private let actions: Actions

  public var body: some View {
    VStack(spacing: Spacing.base) {
      mark
        .accessibilityHidden(true)
        .frame(width: markSide, height: markSide)
      Text(verbatim: title)
        .font(.themeTitle)
        .foregroundStyle(Color.foreground)
      Text(verbatim: message)
        .font(.themeBody)
        .foregroundStyle(Color.foreground)
        .multilineTextAlignment(.center)
      actions
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  public init(
    title: String,
    message: String,
    @ViewBuilder mark: () -> Mark,
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = title
    self.message = message
    self.mark = mark()
    self.actions = actions()
  }
}
