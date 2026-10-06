import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

public struct SectionHeading: View {
  private let number: String
  private let title: String

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
      Text(verbatim: number)
        .font(.themeMono)
        .foregroundStyle(Color.muted)
        .accessibilityHidden(true)
      Text(verbatim: title)
        .font(.themeHeading)
        .foregroundStyle(Color.foreground)
    }
    .accessibilityAddTraits(.isHeader)
  }

  public init(number: String, title: String) {
    self.number = number
    self.title = title
  }
}
