import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

struct Chip: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.themeCaption)
      .foregroundStyle(Color.foreground)
      .padding(.horizontal, Spacing.base)
      .padding(.vertical, Spacing.tight)
      .background(Color.paperDeep)
  }
}
