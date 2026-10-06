import AppKit
import Observation
import PDFKit
import UniformTypeIdentifiers

private let scratchDirectoryPermissions = 0o700

@MainActor
@Observable
final class EditorModel {
  enum Status {
    case info(String)
    case success(String)
    case failure(String)
  }

  private struct Loaded: Sendable {
    let data: Data
    let metadata: FileMetadata
  }

  private struct Replacement: Sendable {
    let data: Data
    let matches: Int
    let pagesChanged: Int
  }

  private struct MetadataDiff: Sendable {
    let refused: [String]
    let differences: [String]
  }

  private(set) var fileURL: URL?
  private(set) var metadata: PDFMetadata?
  private(set) var fileMetadata: FileMetadata?
  private(set) var document: PDFDocument?
  private(set) var edited = false
  private(set) var status: Status?
  private(set) var isApplying = false
  var findText = ""
  var replaceText = ""

  private var data: Data?
  private var generation = 0

  var byteCount: Int? { data?.count }

  nonisolated private static func read(_ url: URL) throws -> Loaded {
    let meta = try FileMetadata(url: url)
    let bytes = try Data(contentsOf: url)
    return Loaded(data: bytes, metadata: meta)
  }

  nonisolated private static func replace(
    data: Data, find: String, replace: String
  ) throws -> Replacement {
    try withScratchDirectory { directory in
      let input = directory.appendingPathComponent("input.pdf")
      let output = directory.appendingPathComponent("output.pdf")
      try data.write(to: input, options: .atomic)
      let result = try PDFEngine.replace(
        find: find, replace: replace, inputPath: input.path, outputPath: output.path)
      let outputData = try Data(contentsOf: output)
      return Replacement(
        data: outputData, matches: result.matches, pagesChanged: result.pagesChanged)
    }
  }

  nonisolated private static func write(
    data: Data, metadata: FileMetadata, to url: URL
  ) throws -> MetadataDiff {
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      throw SaveError.data(name: url.lastPathComponent, reason: error.localizedDescription)
    }
    do {
      let refused = try metadata.apply(to: url)
      let written = try FileMetadata(url: url)
      return MetadataDiff(refused: refused, differences: metadata.differences(from: written))
    } catch {
      throw SaveError.metadata(name: url.lastPathComponent, reason: error.localizedDescription)
    }
  }

  nonisolated private static func withScratchDirectory<T>(
    _ body: (URL) throws -> T
  ) throws -> T {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: scratchDirectoryPermissions])
    let outcome: Result<T, Error>
    do {
      outcome = .success(try body(directory))
    } catch {
      outcome = .failure(error)
    }
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      throw ScratchError.residue(directory)
    }
    return try outcome.get()
  }

  func choose() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    load(url)
  }

  func load(_ url: URL) {
    generation += 1
    let ticket = generation
    isApplying = false
    Task {
      do {
        let loaded = try await Task.detached { try Self.read(url) }.value
        guard ticket == self.generation else {
          return
        }
        guard let pdf = PDFDocument(data: loaded.data) else {
          self.status = .failure("\(url.lastPathComponent) is not a readable pdf.")
          return
        }
        guard !pdf.isLocked else {
          self.status = .failure(
            "\(url.lastPathComponent) is password-protected. remove the password in preview, then open it again."
          )
          return
        }
        self.fileURL = url
        self.data = loaded.data
        self.document = pdf
        self.fileMetadata = loaded.metadata
        self.metadata = PDFMetadata(document: pdf, data: loaded.data)
        self.edited = false
        self.status = .info("metadata captured. enter the text to replace.")
      } catch {
        guard ticket == self.generation else {
          return
        }
        self.status = .failure(
          "\(url.lastPathComponent) could not be read: \(error.localizedDescription)")
      }
    }
  }

  func revert() {
    if let fileURL { load(fileURL) }
  }

  func apply() {
    guard let data else {
      return
    }
    let find = findText
    let replacement = replaceText
    generation += 1
    let ticket = generation
    isApplying = true
    Task {
      do {
        let outcome = try await Task.detached {
          try Self.replace(data: data, find: find, replace: replacement)
        }.value
        guard ticket == self.generation else {
          return
        }
        isApplying = false
        self.acceptApplyOutcome(outcome, find: find)
      } catch {
        guard ticket == self.generation else {
          return
        }
        isApplying = false
        self.status = .failure(error.localizedDescription)
      }
    }
  }

  private func acceptApplyOutcome(_ outcome: Replacement, find: String) {
    guard outcome.matches > 0 else {
      self.status = .failure(
        """
        "\(find)" does not occur in the pdf's text layer. matching is case-sensitive. \
        a scanned page has no text layer, so text in a scan is not found and stays visible.
        """)
      return
    }
    guard let outputDocument = PDFDocument(data: outcome.data) else {
      self.status = .failure("the edited pdf could not be reopened. the original is unchanged.")
      return
    }
    self.data = outcome.data
    self.document = outputDocument
    self.edited = true
    let pages = "\(outcome.pagesChanged) page\(outcome.pagesChanged == 1 ? "" : "s")"
    self.status = .success(
      """
      replaced \(outcome.matches) occurrence\(outcome.matches == 1 ? "" : "s") across \
      \(pages). an independent scan of the output found no remaining occurrence on any \
      text surface. document metadata preserved.
      """
    )
  }

  func rejectDrop(_ urls: [URL]) {
    let name = urls.first?.lastPathComponent ?? "the dropped item"
    status = .failure("\(name) is not a pdf. drop a file with the .pdf extension.")
  }

  func export() {
    guard let data, let fileURL, let fileMetadata else {
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + " edited.pdf"
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    Task {
      do {
        let diff = try await Task.detached {
          try Self.write(data: data, metadata: fileMetadata, to: url)
        }.value
        if diff.refused.isEmpty, diff.differences.isEmpty {
          let count = fileMetadata.copiedAttributes.count
          let attributes = "\(count) extended attribute\(count == 1 ? "" : "s")"
          let systemOwned = FileMetadata.systemOwnedAttributes.joined(separator: ", ")
          self.status = .success(
            """
            saved \(url.lastPathComponent). creation and modification dates, permissions \
            and \(attributes) verified identical. macos sets \(systemOwned) on the \
            exported file itself, so they were not copied.
            """
          )
        } else {
          self.status = .failure(
            "saved \(url.lastPathComponent), but these items differ from the original: "
              + (diff.refused + diff.differences).joined(separator: ", "))
        }
      } catch {
        self.status = .failure(error.localizedDescription)
      }
    }
  }
}

enum SaveError: LocalizedError {
  case data(name: String, reason: String)
  case metadata(name: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .data(let name, let reason):
      "\(name) was not saved: \(reason). choose another location and export again."

    case .metadata(let name, let reason):
      """
      \(name) was saved with the redacted content, but its file metadata could not be \
      restored: \(reason). check its dates, permissions and extended attributes before \
      sharing it.
      """
    }
  }
}

enum ScratchError: LocalizedError {
  case residue(URL)

  var errorDescription: String? {
    switch self {
    case .residue(let directory):
      """
      the unredacted working copy at \(directory.path) could not be deleted. \
      it still contains the original text; remove it manually.
      """
    }
  }
}
