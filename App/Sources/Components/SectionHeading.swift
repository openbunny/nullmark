import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

struct SectionHeading: View {
  let number: String
  let title: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
      Text(number)
        .font(.themeMono)
        .foregroundStyle(Color.muted)
        .accessibilityHidden(true)
      Text(title)
        .font(.themeBody.weight(.semibold))
        .foregroundStyle(Color.foreground)
    }
  }
}
