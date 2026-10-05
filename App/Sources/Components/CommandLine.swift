import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

enum ShellTokenKind {
  case command
  case flag
  case string
  case text
}

struct ShellToken {
  let kind: ShellTokenKind
  let text: String
}

func splitPieces(_ command: String) -> [String]? {
  var pieces: [String] = []
  var current = ""
  var quote: Character?
  for char in command {
    if let open = quote {
      current.append(char)
      if char == open { quote = nil }
    } else if char == "'" || char == "\"" {
      quote = char
      current.append(char)
    } else if char.isWhitespace {
      if !current.isEmpty {
        pieces.append(current)
        current = ""
      }
      pieces.append(String(char))
    } else {
      current.append(char)
    }
  }
  if quote != nil { return nil }
  if !current.isEmpty { pieces.append(current) }
  return pieces
}

func classify(_ piece: String, atCommand: Bool) -> ShellTokenKind {
  if atCommand { return .command }
  if piece.hasPrefix("'") || piece.hasPrefix("\"") { return .string }
  if piece.hasPrefix("-"), piece.drop(while: { $0 == "-" }).first?.isLetter == true {
    return .flag
  }
  return .text
}

func shellTokens(_ command: String) -> [ShellToken] {
  guard let pieces = splitPieces(command) else {
    return [ShellToken(kind: .text, text: command)]
  }
  var tokens: [ShellToken] = []
  var atCommand = true
  for piece in pieces {
    if piece.allSatisfy(\.isWhitespace) {
      tokens.append(ShellToken(kind: .text, text: piece))
      continue
    }
    tokens.append(ShellToken(kind: classify(piece, atCommand: atCommand), text: piece))
    atCommand = ["|", "||", "&&", ";"].contains(piece)
  }
  return tokens
}

struct CommandLine: View {
  let command: String
  var copyLabel: String?

  var body: some View {
    HStack(alignment: .center, spacing: Spacing.base) {
      (Text("$ ").foregroundStyle(Color.muted) + tokenText)
        .font(.themeMono)
        .frame(maxWidth: .infinity, alignment: .leading)
      CopyButton(
        text: command, label: copyLabel ?? "Copy command: \(command)")
    }
    .padding(.horizontal, Spacing.base)
    .padding(.vertical, Spacing.tight)
    .background(Color.paperInset)
    .overlay(Rectangle().stroke(Color.border, lineWidth: Metric.borderWidth))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(command)
  }

  private var tokenText: Text {
    shellTokens(command).reduce(Text("")) { result, token in
      let styled: Text
      switch token.kind {
      case .command:
        styled = Text(token.text).bold().foregroundStyle(Color.foreground)
      case .flag:
        styled = Text(token.text).foregroundStyle(Color.muted)
      case .string:
        styled = Text(token.text).foregroundStyle(Color.sprout)
      case .text:
        styled = Text(token.text).foregroundStyle(Color.foreground)
      }
      return result + styled
    }
  }
}
