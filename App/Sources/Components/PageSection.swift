import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

struct PageSection<Content: View>: View {
  let number: String
  let title: String
  var ruled = true
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.base) {
      SectionHeading(number: number, title: title)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, ruled ? Spacing.page : 0)
    .overlay(alignment: .top) {
      if ruled {
        Rectangle().fill(Color.border).frame(height: Metric.borderWidth)
      }
    }
  }
}
