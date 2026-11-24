# Tamio (iOS / iPadOS & macOS)

A native Swift 6 / SwiftUI SSH client and AI-powered fleet operations hub for **iOS, iPadOS, and macOS** — featuring a GPU-accelerated Ghostty terminal, agentless live server monitoring with animated charts, dual-pane SFTP, end-to-end encrypted iCloud sync, and an in-app AI Server Assistant built on Tamio's MCP engine.

> **Upstream Notice / 二次开发说明**
>
> This repository (**`zxfccmm4/tamio`**) is an active secondary development (fork) based on **[missuo/tamio](https://github.com/missuo/tamio)** (MIT). All original macOS architecture, shared `Foundation/` packages, and upstream commit history are preserved, while bringing **`TamioMobile` (iOS 17+ / iPadOS)** to full parity with macOS and adding native mobile UX, AI Fleet Ops, animated telemetry charts, Shortcuts, and Live Activities.

![Platform](https://img.shields.io/badge/platform-iOS%2017%2B%20%7C%20iPadOS%2017%2B%20%7C%20macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

---

## What's New in This Fork (`TamioMobile` & Shared Core)

### 1. Native Apple HIG & iOS 26 / 27 Liquid Glass UI
- Adaptive `TabView` (floating Liquid Glass tab bar on iPhone with detached far-right AI Assistant button; collapsible sidebar on iPad) with iOS 17 clean fallbacks.
- Native **iOS 18+ Zoom Navigation Transitions** across Home cards, More hub tiles, Snippets, Identities, AI Providers, and About capabilities.
- Full 5-language localization: English (`en`), Simplified Chinese (`zh-Hans`), Traditional Chinese (`zh-Hant`), Japanese (`ja`), and Korean (`ko`).

### 2. Ghostty Terminal (Non-Jailbreak `iGhostVT` Mobile Ergonomics)
- **Zero-flicker persistent `ZStack` tabs**: Background terminal surfaces pause rendering without teardown when switching tabs.
- **iPad Top Tab Strip & Multi-Window**: Compact Safari-style swipeable bottom capsule on iPhone (auto-hides while typing); top tab strip & `New Window` support on iPad.
- **Session Status Overlay**: Liquid Glass status pill (`Connecting…` / `Starting shell…`) and centered Reconnect card when disconnected.
- **Productivity & Reliability**: Scrollback Find (`⌘F` / `⌘G` / `⇧⌘G`), customizable touch keyboard bar, interaction & software-keyboard locks, Snippet drawer (`⌥⌘S`), Copy Text / Copy as Image / Export Transcript, `Keep Awake`, `NWPathMonitor` network-handover auto-reconnect, and **Dynamic Island / Lock Screen Live Activities** (`TamioMobileWidgets`).
- **Apple Shortcuts & URL Schemes**: Native `AppIntents` (`Open Server Terminal`, `Run SSH Command`, `Read Terminal Output`, `Send Input to Terminal`) plus `tamio://session/<uuid>` and `tamio://server/<uuid>`.
- **Ghost Remote**: Non-jailbreak LAN (`_ighostvt._tcp`) discovery, 6-digit TLS-PSK pairing, and `.vtrpsc` relay import.

### 3. Agentless Live Monitor & Animated Charts
- **Home Telemetry Cards**: Symmetrical CPU, Memory/Swap, and Disk rings with live upload/download throughput and system load averages.
- **Server Detail Inspector**:
  - **Overview**: CPU core breakdown, 2-row dot-matrix history, load rings, memory/cache breakdown, network interfaces & TCP stats, per-mount Disk I/O.
  - **Charts**: 6 animated Swift Charts (`CPU`, `Memory / Swap`, `Disk`, `Processes`, `Upload / Download`, `TCP / UDP`) with staggered spring entrance, left-to-right sweep reveal, pulsing live beacons, horizontal scrub inspection, and pause/resume.
  - **Processes & Containers**: Sortable process table (`kill` / `kill -9`) and Docker container stats & lifecycle actions.

### 4. In-App AI Fleet Assistant (MCP + Multi-Session History)
- **23 Shared MCP Tools**: Reuses Tamio's `AgentServer` tools directly on iOS/iPadOS with concurrent execution and per-server `AgentActivity` history.
- **10+ Remote AI Providers + Apple Intelligence**: OpenAI, Anthropic Claude, Google Gemini, DeepSeek, OpenRouter, Groq, xAI, Mistral, SiliconFlow, Ollama / OpenAI-compatible, plus on-device Apple Intelligence (`FoundationModels` on iOS 26+), with API keys stored in Keychain.
- **14 Built-in Server Ops Skills**: Health checks, Docker/Nginx/systemd diagnostics, disk/security/network audits, plus custom `SKILL.md` import.
- **FlowDown-Style Conversation Store**: Multi-session history, auto-titling, context compression, fork/edit/regenerate, collapsible reasoning & MCP tool cards, and strict inline approval before any write or command executes.

### 5. SFTP, Sync & Security
- Concurrent `FileBrowser` + `TransferQueue` SFTP (dual-pane on iPad, overwrite conflict prompts, syntax-highlighted remote file editor).
- Unified server & SSH key editors (Ed25519 generation, sealed private keys, per-server private passwords, Tailscale `None` auth).
- End-to-end encrypted iCloud KVS & Keychain sync across Mac, iPhone, and iPad.
- Face ID / Passcode App Lock with app-switcher privacy curtain.

---

## Install (iOS IPA / macOS)

### iOS / iPadOS (Sideload `.ipa`)
Download the latest unsigned/ad-hoc `.ipa` from **[Releases](https://github.com/zxfccmm4/tamio/releases/latest)** and install it using **AltStore**, **SideStore**, **Sideloadly**, **Feather**, or **TrollStore** (or build directly in Xcode with your Apple Developer account).

### macOS
Build from source using `App.xcworkspace`, or see the upstream **[missuo/tamio](https://github.com/missuo/tamio)** releases.

---

## Build from Source

Requires **Xcode 26+** (Swift 6).

### iOS / iPadOS (`TamioMobile`)

```sh
git clone https://github.com/zxfccmm4/tamio.git
cd tamio

# Build for iOS Simulator
xcodebuild -workspace TamioMobile.xcworkspace -scheme TamioMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO build

# Or package an unsigned IPA locally
xcodebuild -workspace TamioMobile.xcworkspace -scheme TamioMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/dd-ios-release CODE_SIGNING_ALLOWED=NO build
mkdir -p Payload
cp -R /tmp/dd-ios-release/Build/Products/Release-iphoneos/Tamio.app Payload/
zip -r -q TamioMobile-ios.ipa Payload
```

After editing `Application/TamioMobile/project.yml`, regenerate the Xcode project with `cd Application/TamioMobile && xcodegen generate`.

### macOS (`Tamio`)

```sh
bash Workflow/Scripts/build-macos.sh
```

### Tests

```sh
swift test --package-path Foundation/TamioModule
swift test --package-path Foundation/TamioTerminal
swift test --package-path Foundation/MachineStatus
```

---

## Automated IPA Releases (GitHub Actions)

`.github/workflows/ios.yml` automatically builds `TamioMobile` in Release configuration, packages `TamioMobile-<tag>.ipa`, and publishes it to **GitHub Releases** whenever a `v*` tag is pushed (or when triggered manually via `workflow_dispatch`).

---

## Credits & Upstream Lineage

- **[missuo/tamio](https://github.com/missuo/tamio)** — Upstream Tamio project (macOS app, `TamioModule`, `TamioTerminal`, `MachineStatus`, `CloudSync`, and MCP server)
- **[owngoal-dev/iGhostVT](https://github.com/owngoal-dev/iGhostVT)** — Mobile Ghostty UX & Ghost Remote protocol inspiration (MIT)
- **[mizorewww/catussh](https://github.com/mizorewww/catussh)** & **[Lakr233/Rayon](https://github.com/Lakr233/Rayon)** — Original SSH foundation
- **[Lakr233/FlowDown](https://github.com/Lakr233/FlowDown)** — Multi-session AI conversation architecture inspiration
- **[Ghostty](https://ghostty.org)** & **[libssh2](https://libssh2.org)**

## License

[MIT](./LICENSE). Third-party licenses are listed in [Resources/LICENSE](./Resources/LICENSE).
