import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

public struct KeyValueGroup<Rows: View>: View {
  private let title: String
  private let rows: Rows

  public var body: some View {
    VStack(alignment: .leading, spacing: Spacing.tight) {
      Text(verbatim: title).font(.themeBody).foregroundStyle(Color.muted)
      Grid(
        alignment: .leadingFirstTextBaseline,
        horizontalSpacing: Spacing.loose,
        verticalSpacing: Spacing.tight
      ) {
        rows
      }
    }
    .padding(.top, Spacing.tight)
  }

  public init(title: String, @ViewBuilder rows: () -> Rows) {
    self.title = title
    self.rows = rows()
  }
}

public struct KeyValueRow: View {
  private let key: String
  private let value: String

  public var body: some View {
    GridRow {
      Text(verbatim: key).foregroundStyle(Color.muted)
      Text(verbatim: value)
        .foregroundStyle(Color.foreground)
        .textSelection(.enabled)
    }
    .font(.themeMono)
  }

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}
