import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

public struct ShellCommandLine: View {
  private let command: String
  private let copyLabel: String?

  public var body: some View {
    HStack(alignment: .center, spacing: Spacing.base) {
      HStack(spacing: 0) {
        Text(verbatim: "$ ").foregroundStyle(Color.muted)
        tokenText
      }
      .font(.themeMono)
      .frame(maxWidth: .infinity, alignment: .leading)
      CopyButton(
        text: command, label: copyLabel ?? "copy command: \(command)")
    }
    .padding(.horizontal, Spacing.base)
    .padding(.vertical, Spacing.tight)
    .background(Color.paperInset)
    .overlay(Rectangle().stroke(Color.border, lineWidth: Metric.borderWidth))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(command)
  }

  private var tokenText: Text {
    shellTokens(command).reduce(Text(verbatim: "")) { partial, token in
      Text("\(partial)\(style(token))")
    }
  }

  public init(command: String, copyLabel: String? = nil) {
    self.command = command
    self.copyLabel = copyLabel
  }

  private func style(_ token: ShellToken) -> Text {
    let base = Text(verbatim: token.text)
    switch token.kind {
    case .command:
      return base.bold().foregroundStyle(Color.foreground)

    case .flag:
      return base.foregroundStyle(Color.muted)

    case .string:
      return base.foregroundStyle(Color.sprout)

    case .text:
      return base.foregroundStyle(Color.foreground)
    }
  }
}

public enum ShellTokenKind: Sendable, Equatable {
  case command
  case flag
  case string
  case text
}

public struct ShellToken: Sendable, Equatable {
  public let kind: ShellTokenKind
  public let text: String

  public init(kind: ShellTokenKind, text: String) {
    self.kind = kind
    self.text = text
  }
}

enum ShellSplitError: Error, Equatable {
  case unbalancedQuote
}

func splitPieces(_ command: String) throws(ShellSplitError) -> [String] {
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
  if quote != nil {
    throw .unbalancedQuote
  }
  if !current.isEmpty { pieces.append(current) }
  return pieces
}

func classify(_ piece: String, atCommand: Bool) -> ShellTokenKind {
  if atCommand {
    return .command
  }
  if piece.hasPrefix("'") || piece.hasPrefix("\"") {
    return .string
  }
  if piece.hasPrefix("-"), piece.drop(while: { $0 == "-" }).first?.isLetter == true {
    return .flag
  }
  return .text
}

/// Splits a shell command into command, flag, string and text tokens. An
/// unbalanced quote returns the whole command as one text token.
public func shellTokens(_ command: String) -> [ShellToken] {
  let pieces: [String]
  do {
    pieces = try splitPieces(command)
  } catch {
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
