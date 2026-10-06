import Testing

@testable import OpenBunnyComponents

struct ShellTokensTests {
  @Test
  func classifiesCommandFlagStringAndText() {
    let kinds = shellTokens(#"tool --find "a b" file"#)
      .filter { !$0.text.allSatisfy(\.isWhitespace) }
      .map(\.kind)
    #expect(kinds == [.command, .flag, .string, .text])
  }

  @Test
  func commandFollowsAPipe() {
    let commands = shellTokens("cat file | grep x")
      .filter { $0.kind == .command }
      .map(\.text)
    #expect(commands == ["cat", "grep"])
  }

  @Test
  func unbalancedQuoteFallsBackToOneTextToken() {
    #expect(shellTokens(#"echo "open"#) == [ShellToken(kind: .text, text: #"echo "open"#)])
  }

  @Test
  func splitRejectsAnUnbalancedQuote() {
    #expect(throws: ShellSplitError.unbalancedQuote) {
      try splitPieces("'unterminated")
    }
  }

  @Test
  func negativeNumberIsNotAFlag() {
    #expect(classify("-1", atCommand: false) == .text)
  }
}
