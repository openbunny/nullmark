import OpenBunnyTheme
import OpenBunnyUI
import PDFKit
import SwiftUI

private let sidebarWidth: CGFloat = 380
private let dropZonePadding: CGFloat = 28
private let chooseButtonWidth: CGFloat = 220
private let headerMarkSide: CGFloat = 44
private let stackedTextSpacing: CGFloat = 2
private let octalRadix = 8

struct ContentView: View {
  @State private var model = EditorModel()
  @State private var dropTargeted = false
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.page) {
          Header()
          PageSection(number: "01", title: "document", ruled: false) { documentSection }
          if model.document != nil {
            PageSection(number: "02", title: "replace") { replaceSection }
            if let metadata = model.metadata {
              PageSection(number: "03", title: "captured metadata") {
                metadataSection(metadata)
              }
            }
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
        model.rejectDrop(urls)
        return false
      }
      model.load(url)
      return true
    } isTargeted: { targeted in
      dropTargeted = targeted
    }
  }

  @ViewBuilder private var documentSection: some View {
    if let url = model.fileURL, let document = model.document {
      fileSummary(url: url, document: document)
    } else {
      fileDropButton
    }
    if let status = model.status, model.document == nil {
      statusLine(status)
    }
  }

  private var fileDropButton: some View {
    Button(action: model.choose) {
      Text("drop a pdf or click to choose")
        .font(.themeBody)
        .frame(maxWidth: .infinity)
        .padding(.vertical, dropZonePadding)
        .foregroundStyle(Color.muted)
        .background(dropTargeted ? Color.paperDeep : Color.paper)
        .overlay(Rectangle().stroke(Color.border, lineWidth: Metric.borderWidth))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder private var replaceSection: some View {
    LabeledField(label: "find", placeholder: "text in the pdf", text: $model.findText)
    LabeledField(label: "replace with", placeholder: "new text", text: $model.replaceText)
    HStack(spacing: Spacing.base) {
      Button("apply replacement", action: model.apply)
        .buttonStyle(.outline)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(model.findText.isEmpty || model.isApplying)
      Button("export pdf…", action: model.export)
        .buttonStyle(.outline)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!model.edited || model.isApplying)
    }
    if let status = model.status {
      statusLine(status)
    }
    StatusMessage(
      "text drawn as an image, such as a scan, is neither found nor changed.", tone: .neutral)
  }

  @ViewBuilder private var preview: some View {
    if let document = model.document {
      PDFKitView(document: document)
        .overlay(Rectangle().stroke(Color.border, lineWidth: Metric.borderWidth))
        .overlay(alignment: .topTrailing) {
          Chip(model.edited ? "edited" : "original")
            .padding(Spacing.base)
        }
        .padding(Spacing.loose)
    } else {
      StatusBanner(
        title: "drop a pdf to begin",
        message: "its metadata is captured before any change and written back after."
      ) {
        NullmarkMark()
      } actions: {
        Button("choose pdf…", action: model.choose)
          .buttonStyle(.outline)
          .frame(width: chooseButtonWidth)
      }
      .background(dropTargeted ? Color.paperDeep : Color.clear)
      .animation(reduceMotion ? nil : .default, value: dropTargeted)
    }
  }

  @ViewBuilder
  private func metadataSection(_ metadata: PDFMetadata) -> some View {
    infoGroup(metadata)
    documentGroup(metadata)
    if let file = model.fileMetadata {
      fileSystemGroup(file)
    }
  }

  private func fileSummary(url: URL, document: PDFDocument) -> some View {
    let pages = "\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")"
    let size = model.byteCount.map { bytes in
      ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    return VStack(alignment: .leading, spacing: Spacing.base) {
      VStack(alignment: .leading, spacing: stackedTextSpacing) {
        Text(verbatim: url.lastPathComponent)
          .font(.themeMono)
          .foregroundStyle(Color.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(verbatim: [pages, size].compactMap(\.self).joined(separator: " · "))
          .font(.themeCaption)
          .foregroundStyle(Color.muted)
      }
      HStack(spacing: Spacing.loose) {
        Button("open another…", action: model.choose)
        Button("revert", action: model.revert).disabled(!model.edited)
      }
      .buttonStyle(.inkLink)
    }
  }

  private func infoGroup(_ metadata: PDFMetadata) -> some View {
    KeyValueGroup(title: "info dictionary") {
      if metadata.info.isEmpty {
        KeyValueRow(key: "entries", value: "none")
      }
      ForEach(metadata.info) { KeyValueRow(key: $0.key, value: $0.display) }
    }
  }

  private func documentGroup(_ metadata: PDFMetadata) -> some View {
    let xmp =
      metadata.xmp.map { packet in
        ByteCountFormatter.string(fromByteCount: Int64(packet.count), countStyle: .file)
      } ?? "none"
    return KeyValueGroup(title: "document") {
      KeyValueRow(key: "pdf version", value: metadata.version)
      KeyValueRow(key: "document id", value: metadata.fileID ?? "none")
      KeyValueRow(key: "xmp packet", value: xmp)
    }
  }

  private func fileSystemGroup(_ file: FileMetadata) -> some View {
    KeyValueGroup(title: "file system") {
      KeyValueRow(
        key: "created",
        value: file.created?.formatted(date: .abbreviated, time: .standard) ?? "unknown")
      KeyValueRow(
        key: "modified",
        value: file.modified?.formatted(date: .abbreviated, time: .standard) ?? "unknown")
      KeyValueRow(
        key: "accessed",
        value: file.accessed?.formatted(date: .abbreviated, time: .standard) ?? "unknown")
      KeyValueRow(
        key: "permissions",
        value: file.permissions.map { String($0, radix: octalRadix) } ?? "unknown")
      ForEach(file.extendedAttributes.sorted { $0.key < $1.key }, id: \.key) { attribute in
        KeyValueRow(
          key: attribute.key,
          value: ByteCountFormatter.string(
            fromByteCount: Int64(attribute.value.count), countStyle: .file))
      }
    }
  }

  private func statusLine(_ status: EditorModel.Status) -> StatusMessage {
    switch status {
    case .info(let text):
      StatusMessage(text, tone: .neutral)

    case .success(let text):
      StatusMessage(text, tone: .valid)

    case .failure(let text):
      StatusMessage(text, tone: .failed)
    }
  }
}

private struct Header: View {
  var body: some View {
    HStack(spacing: Spacing.base) {
      NullmarkMark()
        .accessibilityHidden(true)
        .frame(width: headerMarkSide, height: headerMarkSide)
      VStack(alignment: .leading, spacing: stackedTextSpacing) {
        Text("nullmark")
          .font(.themeTitle)
          .foregroundStyle(Color.foreground)
        Text("replace text in a pdf and verify none of it survives")
          .font(.themeCaption)
          .foregroundStyle(Color.muted)
      }
    }
  }
}

struct NullmarkMark: View {
  var body: some View {
    Image(.nullmarkMark)
      .resizable()
      .scaledToFit()
      .foregroundStyle(Color.foreground)
      .accessibilityHidden(true)
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
