import OpenBunnyTheme
import SwiftUI

public struct PageSection<Content: View>: View {
  private let number: String
  private let title: String
  private let ruled: Bool
  private let content: Content

  public var body: some View {
    VStack(alignment: .leading, spacing: Spacing.base) {
      SectionHeading(number: number, title: title)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, ruled ? Spacing.page : 0)
    .overlay(alignment: .top) {
      if ruled {
        Rectangle().fill(Color.border).frame(height: Metric.borderWidth)
      }
    }
  }

  public init(
    number: String, title: String, ruled: Bool = true, @ViewBuilder content: () -> Content
  ) {
    self.number = number
    self.title = title
    self.ruled = ruled
    self.content = content()
  }
}
