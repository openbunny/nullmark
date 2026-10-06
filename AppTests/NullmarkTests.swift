import Foundation
import Testing

private let nul = String(UnicodeScalar(0))
private let loadPolls = 200
private let loadPollMilliseconds = 10
private let staleDelayMilliseconds = 300
private let secondApplyOffsetMilliseconds = 50
private let applySettleMilliseconds = 1_500

@MainActor
struct NullmarkTests {
  @Test(arguments: [
    NULArgument(field: "find", find: "a\(nul)"),
    NULArgument(field: "replacement", replace: "b\(nul)"),
    NULArgument(field: "input path", inputPath: "/tmp/nullmark-nul-in\(nul).pdf"),
    NULArgument(field: "output path", outputPath: "/tmp/nullmark-nul-out\(nul).pdf"),
  ])
  func pdfEngineRejectsNUL(_ argument: NULArgument) {
    let error = #expect(throws: PDFEngineError.self) {
      try PDFEngine.replace(
        find: argument.find,
        replace: argument.replace,
        inputPath: argument.inputPath,
        outputPath: argument.outputPath)
    }
    guard case .embeddedNUL(let field)? = error else {
      Issue.record("unexpected error: \(String(describing: error))")
      return
    }
    #expect(field == argument.field)
  }

  @Test(arguments: ["/tmp/nullmark-nul\(nul).pdf", "/tmp/nullmark-nul%00.pdf"])
  func fileMetadataRejectsNULPath(_ path: String) {
    let error = #expect(throws: FileMetadata.ReadError.self) {
      try FileMetadata(url: URL(fileURLWithPath: path))
    }
    guard case .embeddedNULPath? = error else {
      Issue.record("unexpected error: \(String(describing: error))")
      return
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func applyDropsStaleGeneration() async throws {
    let model = try await withDelayedFirstApply { model, _ in
      model.findText = "second"
      model.apply()
    }
    guard case .failure(let text) = model.status else {
      Issue.record("unexpected status: \(String(describing: model.status))")
      return
    }
    #expect(text.contains("\"second\" does not occur"))
    #expect(!text.contains("\"first\" does not occur"))
    #expect(!model.isApplying)
  }

  @Test(.timeLimit(.minutes(1)))
  func loadDropsInFlightApply() async throws {
    let model = try await withDelayedFirstApply { model, fixture in
      model.load(fixture)
    }
    guard case .info(let text) = model.status else {
      Issue.record("unexpected status: \(String(describing: model.status))")
      return
    }
    #expect(text.hasPrefix("metadata captured"))
    #expect(!model.edited)
    #expect(!model.isApplying)
  }

  private func withDelayedFirstApply(
    _ interrupt: (EditorModel, URL) -> Void
  ) async throws -> EditorModel {
    unsafe _ = setenv("T4_FAKE_DELAY_ON", "first", 1)
    unsafe _ = setenv("T4_FAKE_DELAY_MS", String(staleDelayMilliseconds), 1)
    defer {
      unsafe _ = unsetenv("T4_FAKE_DELAY_ON")
      unsafe _ = unsetenv("T4_FAKE_DELAY_MS")
    }
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("CTask4PDF/fuzz/corpus/simple.pdf")
    let model = EditorModel()
    model.load(fixture)
    for _ in 0..<loadPolls where model.document == nil && model.status == nil {
      try await Task.sleep(for: .milliseconds(loadPollMilliseconds))
    }
    try #require(model.document != nil, "fixture did not load: \(String(describing: model.status))")

    model.findText = "first"
    model.apply()
    try await Task.sleep(for: .milliseconds(secondApplyOffsetMilliseconds))
    interrupt(model, fixture)
    try await Task.sleep(for: .milliseconds(applySettleMilliseconds))
    return model
  }
}

struct NULArgument: Sendable, CustomTestStringConvertible {
  let field: String
  var find = "a"
  var replace = "b"
  var inputPath = "/tmp/nullmark-nul-in.pdf"
  var outputPath = "/tmp/nullmark-nul-out.pdf"

  var testDescription: String { field }
}
