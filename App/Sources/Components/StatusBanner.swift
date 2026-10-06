import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

private let markSide: CGFloat = 64

struct StatusBanner<Actions: View>: View {
  let title: String
  let message: String
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    VStack(spacing: Spacing.base) {
      NullmarkMark()
        .accessibilityHidden(true)
        .frame(width: markSide, height: markSide)
      Text(title)
        .font(.themeTitle)
        .foregroundStyle(Color.foreground)
      Text(message)
        .font(.themeBody)
        .foregroundStyle(Color.foreground)
        .multilineTextAlignment(.center)
      actions()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
