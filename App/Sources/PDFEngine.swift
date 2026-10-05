import Foundation

enum PDFEngineError: LocalizedError {
  case failed(String)
  case residual(Int)
  case embeddedNUL(field: String)

  var errorDescription: String? {
    switch self {
    case .failed(let message):
      message

    case .residual(let count):
      """
      The document still contains \(count) occurrence\(count == 1 ? "" : "s") of the text \
      after redaction. The output was discarded.
      """

    case .embeddedNUL(let field):
      "The \(field) text contains a NUL character (U+0000), which C string interop truncates. Remove it and try again."
    }
  }
}

struct PDFReplacementResult {
  let matches: Int
  let pagesChanged: Int
}

enum PDFEngine {
  static func replace(
    find: String, replace: String, inputPath: String, outputPath: String
  ) throws -> PDFReplacementResult {
    guard !find.utf8.contains(0) else {
      throw PDFEngineError.embeddedNUL(field: "find")
    }
    guard !replace.utf8.contains(0) else {
      throw PDFEngineError.embeddedNUL(field: "replacement")
    }
    guard !inputPath.utf8.contains(0) else {
      throw PDFEngineError.embeddedNUL(field: "input path")
    }
    guard !outputPath.utf8.contains(0) else {
      throw PDFEngineError.embeddedNUL(field: "output path")
    }
    var result = T4Result()
    let code = unsafe t4_replace(inputPath, outputPath, find, replace, &result)
    guard code == 0 else {
      throw PDFEngineError.failed(errorMessage(result))
    }
    guard result.residual == 0 else {
      throw PDFEngineError.residual(Int(result.residual))
    }
    return PDFReplacementResult(
      matches: Int(result.matches), pagesChanged: Int(result.pages_changed))
  }

  private static func errorMessage(_ result: T4Result) -> String {
    withUnsafeBytes(of: result.error) { raw in
      guard let base = raw.baseAddress else {
        return ""
      }
      return unsafe String(cString: base.assumingMemoryBound(to: CChar.self))
    }
  }
}
