import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

public struct StatusMessage: View {
  private let text: String
  private let tone: StatusTone

  public var body: some View {
    Text(verbatim: text)
      .font(.themeBody)
      .foregroundStyle(tone.color)
      .fixedSize(horizontal: false, vertical: true)
  }

  public init(_ text: String, tone: StatusTone) {
    self.text = text
    self.tone = tone
  }
}
