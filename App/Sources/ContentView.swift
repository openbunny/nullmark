import OpenBunnyTheme
import OpenBunnyUI
import PDFKit
import SwiftUI

private let sidebarWidth: CGFloat = 380
private let dropZonePadding: CGFloat = 28
private let dropZoneDashLength: CGFloat = 6
private let chooseButtonWidth: CGFloat = 220
private let headerMarkSide: CGFloat = 44
private let stackedTextSpacing: CGFloat = 2
private let markGlyphUnits = 5.0
private let markSideUnits = 6.0
private let markGlyphToSide = markGlyphUnits / markSideUnits
private let octalRadix = 8

struct ContentView: View {
  @State private var model = EditorModel()
  @State private var dropTargeted = false
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.loose) {
          Header()
          fileCard
          if model.document != nil {
            replaceCard
            metadataCard
          }
        }
        .padding(Spacing.loose)
        .padding(.top, Spacing.loose)
      }
      .frame(width: sidebarWidth)
      .background(Color.background)
      .overlay(alignment: .trailing) {
        Rectangle()
          .fill(Color.border)
          .frame(width: Metric.borderWidth)
      }

      preview
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
    }
    .ignoresSafeArea()
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else {
        return false
      }
      model.load(url)
      return true
    } isTargeted: { targeted in
      dropTargeted = targeted
    }
  }

  @ViewBuilder private var fileCard: some View {
    Card(title: "Document", symbol: "doc") {
      if let url = model.fileURL, let document = model.document {
        fileSummary(url: url, document: document)
      } else {
        fileDropButton
      }
      if let status = model.status, model.document == nil {
        statusLabel(status)
      }
    }
  }

  private var fileDropButton: some View {
    Button(action: model.choose) {
      VStack(spacing: Spacing.tight) {
        Image(systemName: "arrow.down.doc").accessibilityHidden(true).font(.themeTitle)
        Text("Drop a PDF or click to choose").font(.themeBody)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, dropZonePadding)
      .foregroundStyle(Color.muted)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .strokeBorder(
            Color.border,
            style: StrokeStyle(lineWidth: Metric.borderWidth, dash: [dropZoneDashLength]))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var replaceCard: some View {
    Card(title: "Replace", symbol: "arrow.left.arrow.right") {
      LabeledField(
        label: "Find", placeholder: "Text currently in the PDF", text: $model.findText)
      LabeledField(label: "Replace with", placeholder: "New text", text: $model.replaceText)
      Button(action: model.apply) {
        Label("Apply Replacement", systemImage: "wand.and.stars")
      }
      .buttonStyle(.outline)
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(model.findText.isEmpty || model.isApplying)
      Button(action: model.export) {
        Label("Export PDF…", systemImage: "square.and.arrow.up")
      }
      .buttonStyle(.outline)
      .keyboardShortcut("s", modifiers: .command)
      .disabled(!model.edited || model.isApplying)
      if let status = model.status {
        statusLabel(status)
      }
    }
  }

  @ViewBuilder private var metadataCard: some View {
    if let metadata = model.metadata {
      Card(title: "Captured Metadata", symbol: "tag") {
        infoSection(metadata)
        documentSection(metadata)
        if let file = model.fileMetadata {
          fileSystemSection(file)
        }
      }
    }
  }

  @ViewBuilder private var preview: some View {
    if let document = model.document {
      PDFKitView(document: document)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(Color.border, lineWidth: Metric.borderWidth)
        )
        .overlay(alignment: .topTrailing) {
          Group {
            if model.edited {
              Tag(text: "edited")
            } else {
              Tag(text: "original", tint: Color.muted)
            }
          }
          .padding(Spacing.base)
        }
        .padding(Spacing.loose)
    } else {
      StatusBanner(
        title: "Drop a PDF to begin",
        message:
          "Its metadata is captured before any change and written back after."
      ) {
        Button(action: model.choose) {
          Label("Choose PDF…", systemImage: "arrow.down.doc")
        }
        .buttonStyle(.outline)
        .frame(width: chooseButtonWidth)
      }
      .background(dropTargeted ? Color.paperDeep : Color.clear)
      .animation(reduceMotion ? nil : .default, value: dropTargeted)
    }
  }

  private func fileSummary(url: URL, document: PDFDocument) -> some View {
    let pages = "\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")"
    let size = ByteCountFormatter.string(fromByteCount: Int64(model.byteCount), countStyle: .file)
    return VStack(alignment: .leading, spacing: Spacing.base) {
      HStack(spacing: Spacing.base) {
        Image(systemName: "doc.richtext.fill")
          .accessibilityHidden(true)
          .font(.themeTitle)
          .foregroundStyle(Color.sprout)
        VStack(alignment: .leading, spacing: stackedTextSpacing) {
          Text(url.lastPathComponent)
            .font(.themeBody.weight(.semibold))
            .foregroundStyle(Color.foreground)
            .lineLimit(1)
            .truncationMode(.middle)
          Text("\(pages) · \(size)")
            .font(.themeCaption)
            .foregroundStyle(Color.muted)
        }
        Spacer()
      }
      HStack(spacing: Spacing.loose) {
        Button("Open Another…", action: model.choose)
        Button("Revert", action: model.revert).disabled(!model.edited)
      }
      .buttonStyle(.plain)
      .font(.themeBody)
      .foregroundStyle(Color.sprout)
    }
  }

  private func infoSection(_ metadata: PDFMetadata) -> some View {
    metadataSection("Info dictionary") {
      if metadata.info.isEmpty {
        KeyValueRow(key: "—", value: "No Info dictionary")
      }
      ForEach(metadata.info) { KeyValueRow(key: $0.key, value: $0.display) }
    }
  }

  private func documentSection(_ metadata: PDFMetadata) -> some View {
    let xmp =
      metadata.xmp.map { packet in
        ByteCountFormatter.string(fromByteCount: Int64(packet.count), countStyle: .file)
      } ?? "None"
    return metadataSection("Document") {
      KeyValueRow(key: "PDF version", value: metadata.version)
      KeyValueRow(key: "Document ID", value: metadata.fileID ?? "None")
      KeyValueRow(key: "XMP packet", value: xmp)
    }
  }

  private func fileSystemSection(_ file: FileMetadata) -> some View {
    metadataSection("File system") {
      KeyValueRow(
        key: "Created",
        value: file.created?.formatted(date: .abbreviated, time: .standard) ?? "Unknown")
      KeyValueRow(
        key: "Modified",
        value: file.modified?.formatted(date: .abbreviated, time: .standard) ?? "Unknown")
      KeyValueRow(
        key: "Accessed",
        value: file.accessed?.formatted(date: .abbreviated, time: .standard) ?? "Unknown")
      KeyValueRow(
        key: "Permissions",
        value: file.permissions.map { String($0, radix: octalRadix) } ?? "Unknown")
      ForEach(file.extendedAttributes.sorted { $0.key < $1.key }, id: \.key) { attribute in
        KeyValueRow(
          key: attribute.key,
          value: ByteCountFormatter.string(
            fromByteCount: Int64(attribute.value.count), countStyle: .file))
      }
    }
  }

  private func statusLabel(_ status: EditorModel.Status) -> StatusText {
    switch status {
    case .info(let text):
      StatusText(LocalizedStringKey(text), status: .enabled)

    case .success(let text):
      StatusText(LocalizedStringKey(text), status: .enabled)

    case .failure(let text):
      StatusText(LocalizedStringKey(text), status: .disabled)
    }
  }

  private func metadataSection(
    _ title: String, @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.tight) {
      Text(title).font(.themeBody.weight(.semibold)).foregroundStyle(Color.foreground)
      content()
    }
    .padding(.top, Spacing.tight)
  }
}

private struct Header: View {
  var body: some View {
    HStack(spacing: Spacing.base) {
      NullmarkMark()
        .accessibilityHidden(true)
        .frame(width: headerMarkSide, height: headerMarkSide)
        .background(
          Color.paper, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Color.border, lineWidth: Metric.borderWidth))
      VStack(alignment: .leading, spacing: stackedTextSpacing) {
        Text("nullmark")
          .font(.themeBody.weight(.bold))
          .foregroundStyle(Color.foreground)
        Text("replace text in pdfs, verify nothing survives")
          .font(.themeCaption)
          .foregroundStyle(Color.muted)
      }
    }
  }
}

struct NullmarkMark: View {
  var body: some View {
    GeometryReader { proxy in
      let bounds = CGRect(origin: .zero, size: proxy.size)
      let side = min(bounds.width, bounds.height)
      Text("0")
        .font(.custom(FontFamily.mono, fixedSize: side * markGlyphToSide).weight(.bold))
        .foregroundStyle(Color.foreground)
        .frame(width: side, height: side)
        .position(x: bounds.midX, y: bounds.midY)
    }
  }
}

private struct Card<Content: View>: View {
  let title: String
  let symbol: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.base) {
      Label(title, systemImage: symbol)
        .font(.themeBody.weight(.semibold))
        .foregroundStyle(Color.foreground)
      content()
    }
    .padding(Spacing.loose)
    .background(Color.paperInset)
    .overlay(Rectangle().stroke(Color.border, lineWidth: Metric.borderWidth))
  }
}

private struct LabeledField: View {
  let label: String
  let placeholder: String
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.tight) {
      Text(label).font(.themeBody).foregroundStyle(Color.foreground)
      TextField(placeholder, text: $text)
        .font(.themeBody)
        .padding(Spacing.base)
        .background(Color.paper)
        .overlay(Rectangle().stroke(Color.border, lineWidth: Metric.borderWidth))
    }
  }
}

private struct KeyValueRow: View {
  let key: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
      Text(key).font(.themeBody).foregroundStyle(Color.muted)
      Spacer()
      Text(value)
        .font(.themeMono)
        .foregroundStyle(Color.foreground)
        .multilineTextAlignment(.trailing)
    }
  }
}

private struct Tag: View {
  let text: String
  var tint = Color.sprout

  var body: some View {
    Text(text)
      .font(.themeCaption)
      .foregroundStyle(Color.foreground)
      .padding(.horizontal, Spacing.base)
      .padding(.vertical, Spacing.tight)
      .background(tint)
  }
}

private struct PDFKitView: NSViewRepresentable {
  let document: PDFDocument

  func makeNSView(context _: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.backgroundColor = NSColor(Color.background)
    return view
  }

  func updateNSView(_ view: PDFView, context _: Context) {
    if view.document !== document { view.document = document }
  }
}
