import OpenBunnyTheme
import OpenBunnyUI
import SwiftUI

struct KeyValueGroup<Rows: View>: View {
  let title: String
  @ViewBuilder let rows: () -> Rows

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.tight) {
      Text(title).font(.themeBody).foregroundStyle(Color.foreground)
      Grid(
        alignment: .leadingFirstTextBaseline,
        horizontalSpacing: Spacing.loose,
        verticalSpacing: Spacing.tight
      ) {
        rows()
      }
    }
    .padding(.top, Spacing.tight)
  }
}

struct KeyValueRow: View {
  let key: String
  let value: String

  var body: some View {
    GridRow {
      Text(verbatim: key).foregroundStyle(Color.muted)
      Text(verbatim: value)
        .foregroundStyle(Color.foreground)
        .textSelection(.enabled)
    }
    .font(.themeMono)
  }
}
