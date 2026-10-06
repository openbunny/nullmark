import OpenBunnyTheme
import SwiftUI

public struct Chip: View {
  private let text: String

  public var body: some View {
    Text(verbatim: text)
      .font(.themeCaption)
      .foregroundStyle(Color.foreground)
      .padding(.horizontal, Spacing.base)
      .padding(.vertical, Spacing.tight)
      .background(Color.paperDeep)
  }

  public init(_ text: String) {
    self.text = text
  }
}
