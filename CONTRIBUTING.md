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

## Reproducing CI locally

CI and `make ci` run the **same script** (`scripts/ci.sh`), so a green run
locally means a green run on CI:

```sh
make ci        # regenerate, resolve the stack to the LATEST in-range versions, build (iOS Simulator)
make ci-fast   # same build, reusing already-resolved packages (fast; may lag CI's versions)
```

Run `make ci` before pushing. It matters because the CI runner is cacheless and
always resolves the ReticulumSwift stack to the newest versions allowed by the
`from:` pins in `project.yml`, whereas a normal local build silently reuses
whatever SwiftPM already cached — which can pin you to an older version and pass
locally while failing on CI (e.g. when a package ships a new API). `make ci`
forces that same latest-version resolve into an isolated `.spm/` cache, printing
exactly which versions it used. Binary xcframeworks are reused between runs, so
it's fast unless a package actually bumps.

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
