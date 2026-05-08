# lumi-apple

SwiftUI multi-platform client for [Lumi](https://github.com/ViniZap4/lumi) — runs on iOS, iPadOS, macOS, and visionOS.

Like the Go TUI, this client can either open a local folder/iCloud Drive vault or bind to a self-hosted lumi-server v2 instance. Native vim motions, live markdown rendering, 12 shared themes.

## Status

**Phase A — skeleton.** Boots to an empty state with a working theme picker. Domain types and the 12-theme catalog land first; vault picker, markdown rendering, vim engine, and server sync follow in subsequent phases.

## Requirements

- macOS 15+ (Sequoia or newer)
- Xcode 16+ with Swift 6
- `xcodegen` to materialize the Xcode project (installed by `make bootstrap`)

## Layout

```
apple-client/
├── Package.swift            # SPM workspace: LumiKit + LumiUI
├── Sources/
│   ├── LumiKit/             # platform-agnostic core (no SwiftUI)
│   │   ├── Domain/          # Vault, Note, Folder, errors
│   │   ├── Filesystem/      # security-scoped bookmarks, atomic writes (Phase B+)
│   │   └── Network/         # REST + WS client (Phase E+)
│   └── LumiUI/              # shared SwiftUI surface
│       ├── Theme/           # 12 themes, environment injection
│       └── Components/      # editor, markdown render (Phase B–D)
├── Tests/
│   ├── LumiKitTests/
│   └── LumiUITests/
├── App/
│   ├── Sources/             # @main app target
│   └── Resources/           # entitlements, assets
├── project.yml              # xcodegen — generates Lumi.xcodeproj
├── Makefile                 # bootstrap / build / test / open
└── .github/workflows/ci.yml # build matrix on iOS / macOS / visionOS
```

`LumiKit` MUST NOT import SwiftUI — this is an architectural invariant so the core stays portable and headless-testable.

## Quickstart

```bash
make bootstrap   # installs xcodegen, swiftlint, swiftformat (Homebrew) and generates Lumi.xcodeproj
make open        # opens the project in Xcode
make build       # swift build (LumiKit + LumiUI only)
make test        # swift test
```

## Phasing

| Phase | Scope |
|-------|-------|
| A | Skeleton, theme system, app shell, CI |
| B | Markdown render + media |
| C | Plain editor + atomic write |
| D | Vim engine (TextKit 2 + state machine) |
| E | Server client + snapshot+diff sync |
| F | WebSocket live notifications |
| G | visionOS polish, iCloud, App Store metadata |
| H | Yjs CRDT (yswift), live presence/cursors |

## License

Same as the parent monorepo.
