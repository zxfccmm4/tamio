# Tamio (iOS / iPadOS & macOS)

A native Swift 6 / SwiftUI SSH client and AI-powered fleet operations hub for **iOS, iPadOS, and macOS** — featuring a GPU-accelerated Ghostty terminal, agentless live server monitoring with animated charts, dual-pane SFTP, end-to-end encrypted iCloud sync, cross-platform AES-256-GCM backups, and an in-app AI Fleet Assistant built on Tamio's MCP engine.

> **Upstream Notice / 二次开发说明**
>
> This repository (**`zxfccmm4/tamio`**) is an active secondary development (fork) based on **[missuo/tamio](https://github.com/missuo/tamio)** (MIT). All original macOS architecture, shared `Foundation/` packages, and upstream commit history are preserved, while bringing **`TamioMobile` (iOS 17+ / iPadOS)** and **native `Tamio` (macOS 14+)** to full feature parity with AI Fleet Ops, animated telemetry charts, compact live cards, encrypted cross-device backup, and native system Shortcuts.

![Platform](https://img.shields.io/badge/platform-iOS%2017%2B%20%7C%20iPadOS%2017%2B%20%7C%20macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

---

## What's New in This Fork (macOS & iOS / iPadOS)

### 1. Redesigned Compact Home Telemetry Cards (macOS & iOS)
- **High-Density Live Cards**: Compact header (live status dot, country flag, server title, OS + uptime, quick actions for Terminal / Files / Monitor), 3-column animated capsule progress bars (`CPU`, `Memory` tap/click to toggle `Swap`, `Disk`), and a single-line telemetry footer (live network `↑/↓` tap/click for cumulative totals, process count, and `1·5·15m` load averages).
- **Zero-Shift Animated Skeleton**: Matching-height connecting skeleton with sliding gradient bars eliminates layout shift while sessions establish.
- **Fleet Summary Pulse**: Live online/offline server count strip with group filtering (`HomeGroupSwitcher` on macOS, group tabs on iOS).

### 2. Native Apple HIG & Liquid Glass UI + Full 5-Language Localization
- **iOS / iPadOS**: Adaptive `TabView` (floating Liquid Glass tab bar on iPhone with detached AI Assistant button; collapsible sidebar on iPad), iOS 18+ Zoom Navigation Transitions, redesigned **Add / Edit Server** form with live SSH endpoint preview, and `CoreHaptics` chart reveal sweep.
- **macOS**: Native AppKit + SwiftUI frosted-glass window chrome, rebuilt compact server cards, and native `NSSavePanel` / `NSOpenPanel` workflows.
- **Full 5-Language Localization**: English (`en`), Simplified Chinese (`zh-Hans`), Traditional Chinese (`zh-Hant`), Japanese (`ja`), and Korean (`ko`) across 2,150+ strings.

### 3. Ghostty Terminal & System Automation
- **macOS & iOS**: GPU-accelerated Ghostty terminal with **Terminal Find Bar (`⌘F` / `⌘G` / `⇧⌘G` / `Esc`)** featuring live match counts and recent search history, plus native **Apple Shortcuts (`AppIntents`)** (`Open Server Terminal`, `Run SSH Command`, `Read Terminal Output`, `Send Input to Terminal`).
- **iOS / iPadOS Mobile Ergonomics (`iGhostVT`-inspired)**: Zero-flicker persistent `ZStack` tabs, Safari-style swipeable tab capsule & iPad top tab strip, customizable touch keyboard bar, interaction & software-keyboard locks, `Keep Awake`, `NWPathMonitor` auto-reconnect, **Dynamic Island / Lock Screen Live Activities** (`TamioMobileWidgets`), and **Ghost Remote** (`_ighostvt._tcp` LAN discovery, 6-digit TLS-PSK pairing, `.vtrpsc` relay import).

### 4. Agentless Live Monitor (4-Tab Inspector on Both macOS & iOS)
- **Overview**: CPU core breakdown, load averages, memory/cache breakdown, network interfaces & TCP stats, per-mount Disk I/O.
- **Charts**: 6 animated Swift Charts (`CPU`, `Memory / Swap`, `Disk`, `Processes`, `Upload / Download`, `TCP / UDP`) with smooth draw-in animations, live beacons, scrub inspection, and pause/resume.
- **Processes**: Sortable process table (`CPU` / `Memory` / `PID`) with search and `kill` / `kill -9`.
- **Containers**: Live Docker container list with one-click `Start`, `Restart`, and `Stop` controls.

### 5. In-App AI Fleet Assistant (macOS & iOS)
- **FlowDown-Inspired Multi-Session UX**: Persistent conversation history sidebar, pin/rename/duplicate/compress/export Markdown, per-message Copy / Regenerate / Edit & Resend / Fork Here / Delete, shimmering `Thinking…` disclosure with auto-collapse, unified composer with morphing Send/Stop button, and keyboard-docked bottom accessory handoff on iOS 26.1+.
- **Target Scope & Pinned Skills**: Scope any chat to `All Servers`, a server `Group`, or multi-selected `Hosts`, and pin reusable Ops Skills directly into the conversation.
- **23 Shared MCP Tools + Inline Approvals**: Reuses Tamio's `AgentServer` tools with concurrent execution, per-server `AgentActivity` history, and strict inline approval cards before any write or shell command.
- **10+ Remote Providers + Apple Intelligence**: OpenAI, Anthropic Claude, Google Gemini, DeepSeek, OpenRouter, xAI, Ollama, OpenAI/Anthropic-compatible relays (with **Test Connection** latency check & **Fetch Models**), plus Apple Intelligence On-Device and entitlement-checked Private Cloud Compute (`FoundationModels`).
- **14 Built-in Server Ops Skills + Custom `SKILL.md` Import**: Health checks, Docker/Nginx/systemd diagnostics, disk/security/network audits, plus local file or GitHub/Raw URL `SKILL.md` import.

### 6. SFTP, Sync, Encrypted Cross-Platform Backup & Security
- **Cross-Platform `.tamiobackup.json` Export & Import**: Selective 4-category export (`Servers & SSH Credentials`, `Snippets & Port Forwards`, `AI Providers & API Keys`, `Ops Skills & AI Preferences`) using **AES-256-GCM** (PBKDF2-HMAC-SHA256) or plaintext JSON — 100% compatible between iPhone, iPad, and Mac with Merge/Replace preview.
- Concurrent `FileBrowser` + `TransferQueue` SFTP, syntax-highlighted remote file editor, end-to-end encrypted iCloud sync, and Face ID / Passcode App Lock on iOS.

---

## Install (iOS `.ipa` & macOS `.dmg`)

Download the latest release from **[Releases](https://github.com/zxfccmm4/tamio/releases/latest)**:

- **iOS / iPadOS (`TamioMobile-<tag>.ipa`)**: Unsigned sideloadable `.ipa` for **AltStore**, **SideStore**, **Sideloadly**, **Feather**, or **TrollStore** (or build directly in Xcode with your Apple Developer account).
- **macOS (`Tamio-<tag>-macOS.dmg`)**: Native Apple Silicon / Universal macOS disk image (ad-hoc signed on fork releases; if Gatekeeper warns on first launch, right-click → **Open** or run `xattr -dr com.apple.quarantine /Applications/Tamio.app`).

---

## Build from Source

Requires **Xcode 26+** (Swift 6).

> **Note**: `App.xcworkspace` (macOS) and `TamioMobile.xcworkspace` (iOS) share local `Foundation/*` Swift packages. Close one workspace in Xcode before opening the other.

### iOS / iPadOS (`TamioMobile`)

```sh
git clone https://github.com/zxfccmm4/tamio.git
cd tamio

# Build for iOS Simulator
xcodebuild -workspace TamioMobile.xcworkspace -scheme TamioMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO build

# Package an unsigned IPA locally
xcodebuild -workspace TamioMobile.xcworkspace -scheme TamioMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/dd-ios-release CODE_SIGNING_ALLOWED=NO build
mkdir -p Payload
cp -R /tmp/dd-ios-release/Build/Products/Release-iphoneos/Tamio.app Payload/
zip -r -q TamioMobile-ios.ipa Payload
```

### macOS (`Tamio`)

```sh
# Debug build (ad-hoc signed)
bash Workflow/Scripts/build-macos.sh

# Package an ad-hoc signed macOS DMG locally
CODE_SIGN_IDENTITY="-" bash Workflow/Scripts/release.sh mac
```

After editing `project.yml`, regenerate with `cd Application/Tamio && xcodegen generate` or `cd Application/TamioMobile && xcodegen generate`.

### Tests

```sh
swift test --package-path Foundation/TamioModule
swift test --package-path Foundation/TamioTerminal
swift test --package-path Foundation/MachineStatus
```

---

## Automated IPA & DMG Releases (GitHub Actions)

`.github/workflows/ios.yml` automatically builds **both** `TamioMobile-<tag>.ipa` (iOS/iPadOS) and `Tamio-<tag>-macOS.dmg` (macOS) in Release configuration and publishes them together to **GitHub Releases** whenever a `v*` tag is pushed (or when triggered manually via `workflow_dispatch`).

---

## Credits & Upstream Lineage

- **[missuo/tamio](https://github.com/missuo/tamio)** — Upstream Tamio project (macOS app, `TamioModule`, `TamioTerminal`, `MachineStatus`, `CloudSync`, and MCP server)
- **[owngoal-dev/iGhostVT](https://github.com/owngoal-dev/iGhostVT)** — Ghostty terminal UX, Find Bar, Shortcuts & Ghost Remote inspiration (MIT)
- **[mizorewww/catussh](https://github.com/mizorewww/catussh)** & **[Lakr233/Rayon](https://github.com/Lakr233/Rayon)** — Original SSH foundation
- **[Lakr233/FlowDown](https://github.com/Lakr233/FlowDown)** — Multi-session AI conversation & composer UX inspiration
- **[Ghostty](https://ghostty.org)** & **[libssh2](https://libssh2.org)**

## License

[MIT](./LICENSE). Third-party licenses are listed in [Resources/LICENSE](./Resources/LICENSE).
