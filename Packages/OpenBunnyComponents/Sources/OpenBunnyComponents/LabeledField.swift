import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

public struct LabeledField: View {
  private let label: String
  private let placeholder: String
  @Binding private var text: String

  public var body: some View {
    VStack(alignment: .leading, spacing: Spacing.tight) {
      Text(verbatim: label).font(.themeBody).foregroundStyle(Color.muted)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(.themeMono)
        .padding(Spacing.base)
        .background(Color.paper)
        .overlay(Rectangle().stroke(Color.border, lineWidth: Metric.borderWidth))
    }
  }

  public init(label: String, placeholder: String, text: Binding<String>) {
    self.label = label
    self.placeholder = placeholder
    _text = text
  }
}
