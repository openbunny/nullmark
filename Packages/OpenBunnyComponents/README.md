<!-- SPDX-License-Identifier: MIT -->

# OpenBunnyComponents

SwiftUI components that apply the OpenBunny theme the way the OpenBunny
websites and `@openbunny/react` apply it. The package depends only on
`OpenBunnyTheme` and `OpenBunnyUI` from
[openbunny/theme](https://github.com/openbunny/theme), pinned to an exact
version, so it can move to an OpenBunny repository without changes.

## Use

```swift
.package(path: "Packages/OpenBunnyComponents")
```

Link the `OpenBunnyComponents` product, call `Fonts.register()` at launch and
apply `.openbunnyTheme()`, as the theme's README describes. `ComponentGallery`
is the `Components` preview and shows every component.

## Rules the components encode

- Copy is lowercase. The components take their text from the caller and render
  it with `Text(verbatim:)`, so caller text is never parsed as Markdown.
- Borders are 1 point in `border`, with square corners.
- `PageSection` separates sections with a rule above a numbered
  `SectionHeading`. At most two regions of a screen carry a filled ground.
- `sprout` marks state (`StatusMessage` with `.valid`) and string tokens in a
  `ShellCommandLine`, nothing else. `LinkButtonStyle` draws a link as `ink`
  text with a `line` underline.
- Weights are the theme's regular and bold.
- No component draws a decorative icon. `StatusBanner` takes its mark from the
  caller.

## Gates

`swift test --package-path Packages/OpenBunnyComponents` runs the tests. The
repository's `just check` runs it as the `components` recipe, and its
`swift format` and SwiftLint gates cover this directory.
