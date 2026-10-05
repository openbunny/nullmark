import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

struct StatusBanner<Actions: View>: View {
  let title: String
  let message: String
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    VStack(spacing: Spacing.base) {
      NullmarkMark()
        .accessibilityHidden(true)
        .frame(width: 64, height: 64)
      Text(title)
        .font(.themeHeading)
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
