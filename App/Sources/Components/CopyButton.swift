import AppKit
import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

struct CopyButton: View {
  let text: String
  let label: String
  var caption = "Copy"
  var copiedCaption = "Copied"
  var failureHint = "Select the text and copy it by hand."

  private enum CopyState {
    case idle
    case copied
    case failed
  }

  @State private var state: CopyState = .idle
  @State private var dimmed = false
  @State private var cycle = 0

  var body: some View {
    VStack(alignment: .trailing, spacing: Spacing.tight) {
      Button(action: copy) {
        Text(dimmed ? copiedCaption : caption).textCase(.uppercase)
      }
      .buttonStyle(.outline)
      .accessibilityLabel(label)
      if state == .failed {
        Text("\(label) failed. \(failureHint)")
          .font(.themeCaption)
          .foregroundStyle(Color.foreground.opacity(0.7))
          .multilineTextAlignment(.trailing)
      }
    }
    .task(id: cycle) {
      guard state == .copied else { return }
      try? await Task.sleep(for: .milliseconds(450))
      if !Task.isCancelled { dimmed = false }
      try? await Task.sleep(for: .milliseconds(1150))
      if !Task.isCancelled { state = .idle }
    }
  }

  private func copy() {
    if NSPasteboard.general.setString(text, forType: .string) {
      dimmed = true
      state = .copied
      cycle += 1
    } else {
      state = .failed
    }
  }
}
