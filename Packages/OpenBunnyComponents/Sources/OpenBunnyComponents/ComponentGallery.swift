import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

private struct ComponentGallery: View {
  private static let bannerHeight: CGFloat = 260
  private static let canvasWidth: CGFloat = 640
  private static let canvasHeight: CGFloat = 1_180

  private let fontFailure: FontError? = {
    do throws(FontError) {
      try Fonts.register()
      return nil
    } catch {
      return error
    }
  }()

  @State private var taps = 0
  @State private var field = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.loose) {
        if let fontFailure {
          Text(fontFailure.localizedDescription).foregroundStyle(Color.foreground)
        }
        PageSection(number: "01", title: "page section", ruled: false) {
          Text("the first section has no rule; every later one does.")
        }
        PageSection(number: "02", title: "command line and copy button") { commandSamples }
        PageSection(number: "03", title: "outline and link buttons") { buttonSamples }
        PageSection(number: "04", title: "field, chip and key/value grid") { fieldSamples }
        PageSection(number: "05", title: "status messages") { statusSamples }
        PageSection(number: "06", title: "status banner") { bannerSample }
      }
      .padding(Spacing.loose)
    }
    .frame(width: Self.canvasWidth, height: Self.canvasHeight)
    .background(Color.paper)
    .openbunnyTheme()
  }

  @ViewBuilder private var commandSamples: some View {
    ShellCommandLine(
      command: #"nullmark-cli --find "Old Name" --replace "New Name" in.pdf out.pdf"#)
    CopyButton(text: "copied text", label: "copy sample text")
  }

  private var buttonSamples: some View {
    HStack(spacing: Spacing.base) {
      Button("enabled") { taps += 1 }.buttonStyle(.outline)
      Button("disabled") { taps += 1 }.buttonStyle(.outline).disabled(true)
      Button("link") { taps += 1 }.buttonStyle(.inkLink)
    }
  }

  @ViewBuilder private var fieldSamples: some View {
    LabeledField(label: "find", placeholder: "text in the pdf", text: $field)
    Chip("edited")
    KeyValueGroup(title: "document") {
      KeyValueRow(key: "pdf version", value: "1.7")
      KeyValueRow(key: "xmp packet", value: "none")
    }
  }

  @ViewBuilder private var statusSamples: some View {
    StatusMessage("metadata captured. enter the text to replace.", tone: .neutral)
    StatusMessage("replaced 2 occurrences across 1 page.", tone: .valid)
    StatusMessage(#""old name" does not occur in the pdf's text layer."#, tone: .failed)
  }

  private var bannerSample: some View {
    StatusBanner(title: "drop a pdf to begin", message: "status banner with one action.") {
      Rectangle().stroke(Color.border, lineWidth: Metric.borderWidth)
    } actions: {
      Button("choose pdf…") { taps += 1 }.buttonStyle(.outline)
    }
    .frame(height: Self.bannerHeight)
  }
}

#Preview("Components") {
  ComponentGallery()
}
