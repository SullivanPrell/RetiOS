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
make generate && open RetiOS.xcodeproj
```

`RetiOS.xcodeproj` is generated and gitignored — never commit it. Edit
`project.yml` (sources, Info.plist keys, settings) and run `make generate` (a
bare `xcodegen generate` also works, but `make generate` additionally installs
the pinned dependency lockfile — see below).

## Reproducible builds & the package lockfile

Dependency versions are **pinned** in a committed lockfile, `Package.resolved`
(at the repo root, since the generated `RetiOS.xcodeproj` is gitignored). CI and
every dev machine build the *exact* same ReticulumSwift-stack versions — no
silent drift to "latest". `make generate` installs the lockfile into the
generated project, and CI and `make ci` run the same `scripts/ci.sh`, which
enforces it (`-onlyUsePackageVersionsFromResolvedFile`), so a green `make ci`
means a green CI:

```sh
make ci        # reproducible build against the pinned lockfile (iOS Simulator) — run before pushing
```

To move to newer package versions, do it **deliberately**:

```sh
make update    # resolve the stack to the latest in-range versions, verify the build, rewrite Package.resolved
```

`make update` prints exactly which versions changed; review the diff and commit
`Package.resolved`. This is the only thing that changes what RetiOS builds
against, so a dependency bump is always a reviewable commit rather than a
surprise. (Resolution is isolated to a gitignored `.spm/` cache; binary
xcframeworks are reused between runs, so updates are fast unless a package
actually changed.)

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
