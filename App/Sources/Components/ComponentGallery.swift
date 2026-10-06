import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

private struct ComponentGallery: View {
  private static let bannerHeight: CGFloat = 260
  private static let canvasWidth: CGFloat = 640
  private static let canvasHeight: CGFloat = 820

  private let fontFailure: FontError? = {
    do throws(FontError) {
      try Fonts.register()
      return nil
    } catch {
      return error
    }
  }()

  @State private var taps = 0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.loose) {
        if let fontFailure {
          Text(fontFailure.localizedDescription).foregroundStyle(Color.foreground)
        }
        SectionHeading(number: "01", title: "section heading")
        SectionHeading(number: "02", title: "command line and copy button")
        CommandLine(command: #"nullmark-cli --find "Old Name" --replace "New Name" in.pdf out.pdf"#)
        CopyButton(text: "copied text", label: "copy sample text")
        SectionHeading(number: "03", title: "outline and link buttons")
        HStack(spacing: Spacing.base) {
          Button("enabled") { taps += 1 }.buttonStyle(.outline)
          Button("disabled") { taps += 1 }.buttonStyle(.outline).disabled(true)
          Button("link") { taps += 1 }.buttonStyle(.inkLink)
        }
        SectionHeading(number: "04", title: "status banner")
        StatusBanner(title: "drop a pdf to begin", message: "status banner with one action.") {
          Button("choose pdf…") { taps += 1 }.buttonStyle(.outline)
        }
        .frame(height: Self.bannerHeight)
      }
      .padding(Spacing.loose)
    }
    .frame(width: Self.canvasWidth, height: Self.canvasHeight)
    .background(Color.paper)
    .openbunnyTheme()
  }
}

#Preview("Components") {
  ComponentGallery()
}
