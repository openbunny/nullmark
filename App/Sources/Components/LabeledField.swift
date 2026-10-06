import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

struct LabeledField: View {
  let label: String
  let placeholder: String
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.tight) {
      Text(label).font(.themeBody).foregroundStyle(Color.muted)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(.themeMono)
        .padding(Spacing.base)
        .background(Color.paper)
        .overlay(Rectangle().stroke(Color.border, lineWidth: Metric.borderWidth))
    }
  }
}
