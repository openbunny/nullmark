import AppKit
import Observation
import PDFKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class EditorModel {
  enum Status {
    case info(String)
    case success(String)
    case failure(String)
  }

  enum ScratchError: LocalizedError {
    case residue(URL)

    var errorDescription: String? {
      switch self {
      case .residue(let directory):
        """
        The unredacted working copy at \(directory.path) could not be deleted. \
        It still contains the original text; remove it manually.
        """
      }
    }
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
  private var applyGeneration = 0

  var byteCount: Int { data?.count ?? 0 }

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
    try data.write(to: url, options: .atomic)
    let refused = try metadata.apply(to: url)
    let written = try FileMetadata(url: url)
    return MetadataDiff(refused: refused, differences: metadata.differences(from: written))
  }

  nonisolated private static func withScratchDirectory<T>(
    _ body: (URL) throws -> T
  ) throws -> T {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
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
    Task {
      do {
        let loaded = try await Task.detached { try Self.read(url) }.value
        guard let pdf = PDFDocument(data: loaded.data) else {
          self.status = .failure("\(url.lastPathComponent) is not a readable PDF.")
          return
        }
        guard !pdf.isLocked else {
          self.status = .failure(
            "\(url.lastPathComponent) is password-protected. Remove the password in Preview, then open it again."
          )
          return
        }
        self.fileURL = url
        self.data = loaded.data
        self.document = pdf
        self.fileMetadata = loaded.metadata
        self.metadata = PDFMetadata(document: pdf, data: loaded.data)
        self.edited = false
        self.status = .info("Metadata captured. Enter the text to replace.")
      } catch {
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
    applyGeneration += 1
    let generation = applyGeneration
    isApplying = true
    Task {
      do {
        let outcome = try await Task.detached {
          try Self.replace(data: data, find: find, replace: replacement)
        }.value
        guard generation == self.applyGeneration else {
          return
        }
        isApplying = false
        self.acceptApplyOutcome(outcome, find: find)
      } catch {
        guard generation == self.applyGeneration else {
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
        "\"\(find)\" does not occur in the PDF's text layer. Matching is case-sensitive.")
      return
    }
    guard let outputDocument = PDFDocument(data: outcome.data) else {
      self.status = .failure("The edited PDF could not be reopened. The original is unchanged.")
      return
    }
    self.data = outcome.data
    self.document = outputDocument
    self.edited = true
    let pages = "\(outcome.pagesChanged) page\(outcome.pagesChanged == 1 ? "" : "s")"
    self.status = .success(
      """
      Replaced \(outcome.matches) occurrence\(outcome.matches == 1 ? "" : "s") across \
      \(pages). Document metadata preserved.
      """
    )
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
          self.status = .success(
            """
            Saved \(url.lastPathComponent). File dates, permissions and \
            \(fileMetadata.extendedAttributes.count) extended attributes verified identical.
            """
          )
        } else {
          self.status = .failure(
            "Saved \(url.lastPathComponent), but these items differ from the original: "
              + (diff.refused + diff.differences).joined(separator: ", "))
        }
      } catch {
        self.status = .failure(
          "\(url.lastPathComponent) could not be saved: \(error.localizedDescription)")
      }
    }
  }
}
