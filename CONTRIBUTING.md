# Contributing to RetiOS

RetiOS is the reference app for the ReticulumSwift stack. Most protocol logic
lives in the packages ([ReticulumSwift](https://github.com/SullivanPrell/ReticulumSwift),
[LXMFSwift](https://github.com/SullivanPrell/LXMFSwift),
[LXSTSwift](https://github.com/SullivanPrell/LXSTSwift),
[NomadNetSwift](https://github.com/SullivanPrell/NomadNetSwift)); RetiOS is the
SwiftUI experience on top. Protocol bugs usually belong in a package repo.

## Setup

```sh
brew install xcodegen
git clone https://github.com/SullivanPrell/RetiOS.git
cd RetiOS
xcodegen generate && open RetiOS.xcodeproj
```

`RetiOS.xcodeproj` is generated and gitignored — never commit it. Edit
`project.yml` (sources, Info.plist keys, settings) and regenerate.

## Working on a package and the app together

See [docs/BUILDING.md](docs/BUILDING.md#developing-the-whole-stack-locally) —
switch `project.yml` to local package paths, or add local packages in Xcode.

## Conventions

- SwiftUI + `@Observable` controllers; keep protocol work in the packages.
- Real `#if os(macOS)` branches exist (daemon probe, AppKit clipboard, etc.) —
  the app builds natively for Mac, not just "Designed for iPad". Don't assume iOS.
- Add Info.plist keys and build settings in `project.yml`, not the generated project.
- Run the [manual test checklist](docs/TESTING.md) for UI-affecting changes, and
  `xcodebuild test` for the unit tests.

## Submitting changes

Branch from `main`, keep commits focused, and describe user-visible behavior.
Contributions are licensed under the [Reticulum License](LICENSE).
