import AppKit
import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

public struct CopyButton: View {
  private enum CopyState {
    case idle
    case copied
    case failed
  }

  private static let failureOpacity = 0.7
  private static let dimDelayMilliseconds = 450
  private static let resetDelayMilliseconds = 1_150

  private let text: String
  private let label: String
  private let caption: String
  private let copiedCaption: String
  private let failureHint: String

  @State private var state: CopyState = .idle
  @State private var dimmed = false
  @State private var cycle = 0

  public var body: some View {
    VStack(alignment: .trailing, spacing: Spacing.tight) {
      Button(action: copy) {
        Text(verbatim: dimmed ? copiedCaption : caption)
      }
      .buttonStyle(.outline)
      .accessibilityLabel(label)
      if state == .failed {
        Text(verbatim: "\(label) failed. \(failureHint)")
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

  public init(
    text: String,
    label: String,
    caption: String = "copy",
    copiedCaption: String = "copied",
    failureHint: String = "select the text and copy by hand."
  ) {
    self.text = text
    self.label = label
    self.caption = caption
    self.copiedCaption = copiedCaption
    self.failureHint = failureHint
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
