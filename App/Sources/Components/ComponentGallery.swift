import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

private struct ComponentGallery: View {
  private let fontFailure: FontError? = {
    do throws(FontError) {
      try Fonts.register()
      return nil
    } catch {
      return error
    }
  }()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.loose) {
        if let fontFailure {
          Text(fontFailure.localizedDescription).foregroundStyle(Color.foreground)
        }
        SectionHeading(number: "01", title: "Section heading")
        SectionHeading(number: "02", title: "Command line and copy button")
        CommandLine(command: #"nullmark-cli --find "Old Name" --replace "New Name" in.pdf out.pdf"#)
        CopyButton(text: "copied text", label: "Copy sample text")
        SectionHeading(number: "03", title: "Outline buttons")
        HStack(spacing: Spacing.base) {
          Button("Enabled") {}.buttonStyle(.outline)
          Button("Disabled") {}.buttonStyle(.outline).disabled(true)
        }
        SectionHeading(number: "04", title: "Status banner")
        StatusBanner(title: "Drop a PDF to begin", message: "Status banner with one action.") {
          Button("Choose PDF…") {}.buttonStyle(.outline)
        }
        .frame(height: 260)
      }
      .padding(Spacing.loose)
    }
    .frame(width: 640, height: 820)
    .background(Color.paper)
    .openbunnyTheme()
  }
}

#Preview("Components") {
  ComponentGallery()
}
