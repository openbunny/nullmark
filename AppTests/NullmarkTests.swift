import Foundation
import XCTest

@MainActor
final class NullmarkTests: XCTestCase {
  func testPDFEngineRejectsNULInputPath() {
    let nul = String(UnicodeScalar(0))
    XCTAssertThrowsError(
      try PDFEngine.replace(
        find: "a",
        replace: "b",
        inputPath: "/tmp/nullmark-nul-in\(nul).pdf",
        outputPath: "/tmp/nullmark-nul-out.pdf")
    ) { error in
      guard case PDFEngineError.embeddedNUL(let field) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(field, "input path")
    }
  }

  func testPDFEngineRejectsNULOutputPath() {
    let nul = String(UnicodeScalar(0))
    XCTAssertThrowsError(
      try PDFEngine.replace(
        find: "a",
        replace: "b",
        inputPath: "/tmp/nullmark-nul-in.pdf",
        outputPath: "/tmp/nullmark-nul-out\(nul).pdf")
    ) { error in
      guard case PDFEngineError.embeddedNUL(let field) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(field, "output path")
    }
  }

  func testFileMetadataRejectsRawNULPath() {
    let url = URL(fileURLWithPath: "/tmp/nullmark-nul\(String(UnicodeScalar(0))).pdf")
    XCTAssertThrowsError(try FileMetadata(url: url)) { error in
      guard case FileMetadata.ReadError.embeddedNULPath = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testFileMetadataRejectsPercentEncodedNULPath() {
    let url = URL(fileURLWithPath: "/tmp/nullmark-nul%00.pdf")
    XCTAssertThrowsError(try FileMetadata(url: url)) { error in
      guard case FileMetadata.ReadError.embeddedNULPath = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testApplyDropsStaleGeneration() async throws {
    unsafe _ = setenv("T4_FAKE_DELAY_ON", "first", 1)
    unsafe _ = setenv("T4_FAKE_DELAY_MS", "300", 1)
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
    for _ in 0..<200 {
      if model.document != nil || model.status != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard model.document != nil else {
      XCTFail("fixture did not load: \(String(describing: model.status))")
      return
    }

    model.findText = "first"
    model.apply()
    try await Task.sleep(nanoseconds: 50_000_000)
    model.findText = "second"
    model.apply()
    try await Task.sleep(nanoseconds: 1_500_000_000)

    switch model.status {
    case .failure(let text):
      XCTAssertTrue(text.contains("\"second\" does not occur"), text)
      XCTAssertFalse(text.contains("\"first\" does not occur"), text)

    default:
      XCTFail("unexpected status: \(String(describing: model.status))")
    }
    XCTAssertFalse(model.isApplying)
  }
}
