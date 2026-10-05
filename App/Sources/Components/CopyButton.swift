import AppKit
import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

struct CopyButton: View {
  private enum CopyState {
    case idle
    case copied
    case failed
  }

  private static let failureOpacity = 0.7
  private static let dimDelayMilliseconds = 450
  private static let resetDelayMilliseconds = 1_150

  let text: String
  let label: String
  var caption = "Copy"
  var copiedCaption = "Copied"
  var failureHint = "Select the text and copy it by hand."

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
          .foregroundStyle(Color.foreground.opacity(Self.failureOpacity))
          .multilineTextAlignment(.trailing)
      }
    }
    .task(id: cycle) {
      guard state == .copied else {
        return
      }
      try? await Task.sleep(for: .milliseconds(Self.dimDelayMilliseconds))
      if !Task.isCancelled { dimmed = false }
      try? await Task.sleep(for: .milliseconds(Self.resetDelayMilliseconds))
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
