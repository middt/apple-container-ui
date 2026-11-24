# AGENTS.md — AI Agent & Developer Instructions for `Vessel` (`apple-container-ui`)

This file provides essential context, architectural invariants, and build instructions for AI coding agents (Google Antigravity, Claude Code, OpenAI Codex, Cursor, etc.) working on **Vessel — Native macOS Container Studio**.

---

## 1. Project Overview
- **App Name:** **Vessel** (`dist/Vessel.app`)
- **Purpose:** A 100% native macOS desktop studio (`Swift` + `SwiftUI` + `Swift Charts`) for Apple's Linux microVM container runtime (`github.com/apple/container`) with built-in zero-conversion `docker-compose.yml` orchestration and Docker CLI support.
- **Target Platform:** macOS 15.0+ (`arm64-apple-macos15.0`).

---

## 2. Build & Verification Commands

Always build with `./scripts/bundle-app.sh` and run the unit tests with `./scripts/test.sh`:

```bash
# Run the unit tests (Swift Testing; works with CommandLineTools only):
./scripts/test.sh

# Compile the release binary, create dist/Vessel.app and sign it (ad-hoc by default):
./scripts/bundle-app.sh

# Launch the app:
open dist/Vessel.app
```

- **No demo mode:** Vessel always talks to the real `container` CLI (and `docker` when installed). If the binary is missing, an error banner says so and the lists stay empty. There is no sample data, simulated runtime or built-in HTTP responder.
- **Tests:** `Tests/AppleContainerUITests/`. `VESSEL_E2E=1 ./scripts/test.sh` additionally runs `EndToEndTests`, which deploys a tiny Compose stack on the real engine, drives it as a group and removes it again. `StoreTests.swift` drives `ContainerStore` through a `FakeEngine` (a live `ContainerRuntime` test double), so the real-CLI code path is covered without a container engine. `RealCLITests` additionally runs read-only commands against an installed `container` binary.
- **Headless deploy:** `./scripts/stack-up.sh <compose-file>` imports a Compose file into Vessel's settings and deploys it on the real engine through `ContainerStore.deployStack` (the opt-in `StackUpTool` test). `examples/vnext-runtime/` is the reference multi-service deployment.
- **Compose networking:** services only reach each other by name when a local DNS domain exists (`sudo container system dns create <domain>`); see docs/ARCHITECTURE.md § 4 before touching the plan builder.
- **Signing:** `VESSEL_SIGN_IDENTITY="Developer ID Application: …" ./scripts/bundle-app.sh` signs with the hardened runtime (`scripts/Vessel.entitlements`); notarization is a separate `xcrun notarytool` step.

> **IMPORTANT:** Whenever you add a new `.swift` file under `Sources/AppleContainerUI/`, you **MUST** also add its path to the `swiftc` file list inside `scripts/bundle-app.sh`.

---

## 3. Critical Coding Rules & Compiler Constraints (MUST READ)

### Rule 1: Do NOT use `@State`, `@Observable`, or `@Bindable` Macros
On macOS environments where only `/Library/Developer/CommandLineTools` is installed (without a full `/Applications/Xcode.app`), the `MacOSX27.2.sdk` defines `@State` and `@Observable` as external macros (`#externalMacro(module: "SwiftUIMacros", ...)`), and the macro plugin binary is not bundled in CommandLineTools.
- **ALWAYS use:** `final class ...: ObservableObject` with `@Published` properties, injected into views via `@StateObject` (at root) and `@ObservedObject` (in child views).
- **NEVER use:** `@State`, `@Observable`, or `@Bindable`. Store transient UI state (form inputs, search text, toggles) as `@Published` properties on `ContainerStore`. State that changes very often — the list hover state — lives in its own small `ObservableObject` (`HoverState`, held as `store.listHover`) so that it does not re-render every view of the app.

### Rule 2: Port Number Formatting (`String(port)` instead of `"\(port)"` in SwiftUI `Text`/`Label`)
SwiftUI's `LocalizedStringKey` interpolation formats `Int` values with thousands separators (`8080` becomes `8,080`).
- **ALWAYS use:** `String(port.hostPort)` and `String(port.containerPort)` when interpolating port numbers into `Text(...)` or `Label(...)`.

### Rule 3: Protocol-Aware Port Actions (`HTTP/HTTPS` vs `TCP/UDP`)
- Only ports where `port.isHTTPService == true` (`http` or `https`) should display **"Open in Browser"** (`safari` icon) or **"Test HTTP Output"**.
- Raw `tcp` / `udp` ports (e.g., PostgreSQL `5432/tcp`, Redis/Valkey `6379/tcp`, OTLP `4317/tcp`) must **NEVER** show "Open in Browser"; instead display the **Raw TCP Socket** badge and **Copy TCP Endpoint (`127.0.0.1:<port>`)**.

### Rule 4: Multi-Language Localization (`English` & `Turkish`)
- All documentation in the repository (`README.md`, `docs/*.md`, `AGENTS.md`, `CLAUDE.md`) must be written in **English**.
- The macOS application supports **English (`en`)** and **Turkish (`tr`)** via `AppLanguage` (`Sources/AppleContainerUI/Models/AppLocalization.swift`).
- On startup, `AppLanguage.detectSystemDefault()` inspects `Locale.preferredLanguages.first`: if it starts with `"tr"`, it selects `.tr`; otherwise (or if the system language is unsupported), it defaults to `.en` (English).
- All user-facing UI text must use `store.t("English string", "Türkçe metin")` (or localized model methods `title(in: store.language)`).

### Rule 5: Every command goes through `ContainerRuntime`; live mode never shows invented data
- `ContainerStore` must not spawn processes directly. Use `perform(backend, arguments)` (records the command, surfaces failures in `errorBanner`) followed by `settle()`.
- **State changes only after the command succeeded.** `settle()` re-reads the real state from the CLI; never mutate containers, images, volumes or networks locally to reflect what a command "should" have done. Transient `starting` / `stopping` states are the only exception.
- Commands are **argument vectors**, never shell strings. Use `ShellWords.split` for user-typed commands and `ShellWords.join` only for display / Terminal.app.
- Do not add sample / seed data, synthetic telemetry or a simulated runtime. Tests use the `FakeEngine` test double instead.
- Parsers in `CLIOutputParsers.swift` leave unknown fields empty / zero; views render them as "—". Never fill a gap with a plausible-looking value.
- `apple/container` has **no** `restart` command: restart is `stop` + `start`.
- Destructive actions go through a `request…` method that sets `store.pendingConfirmation` (deleting a running container, a group or a volume; stopping the system while containers run). `MainWindowView` shows the single confirmation dialog.

---

## 4. Codebase Map

| File | Responsibility |
| :--- | :--- |
| `Sources/AppleContainerUI/AppleContainerUIApp.swift` | `@main` entry point, main window (`Vessel — Apple Container Studio`), keyboard shortcuts (`Cmd+N`, `Cmd+R`, `Cmd+1..7` in sidebar order), and `MenuBarExtra` tray. |
| `Sources/AppleContainerUI/Models/AppLocalization.swift` | `AppLanguage` enum (`en`, `tr`), system locale auto-detection with English fallback, and localized enum helpers. |
| `Sources/AppleContainerUI/Models/ContainerModels.swift` | All domain structs (`ContainerItem`, `MetricSample`, `PortMapping`, `ComposeStackItem`, `ComposeServiceDefinition`, `ComposeBuild`, `ComposeHealthcheck`, `ImageItem`, `VolumeItem`, `NetworkItem`, `BuilderVMStatus`). |
| `Sources/AppleContainerUI/Services/ContainerRuntime.swift` | `protocol ContainerRuntime` with `LiveCLIRuntime` (real `container` / `docker` binary) and `UnavailableRuntime` (CLI not installed: every command fails with a clear message). |
| `Sources/AppleContainerUI/Services/ContainerCLIService.swift` | `ProcessRunner` (non-blocking process execution that drains pipes concurrently, with a timeout), binary detection, and the injection-safe Terminal.app launcher. |
| `Sources/AppleContainerUI/Services/ShellWords.swift` | POSIX word splitting / quoting and AppleScript string literals. |
| `Sources/AppleContainerUI/Services/CLIOutputParsers.swift` | Pure parsers for real CLI output: `AppleContainerParser` (list, stats, images, volumes, networks, system status, Local Network denial in the system log) and `DockerParser` (`docker inspect`, `docker stats`). |
| `Sources/AppleContainerUI/Services/ContainerStore.swift` | `@MainActor final class ContainerStore: ObservableObject` — all state, the `perform` / `settle` command pipeline, and the telemetry timer (stats every 2 s, every 10 s in the background). |
| `Sources/AppleContainerUI/Services/ContainerStore+Actions.swift` | Container, image, volume, network and engine actions; confirmation requests; quick exec; Terminal shell; real HTTP probe. |
| `Sources/AppleContainerUI/Services/ContainerStore+Compose.swift` | Compose stack import, deployment and teardown on either engine. |
| `Sources/AppleContainerUI/Services/ContainerStore+Live.swift` | Reads real state back from the CLIs: container list merge, stats polling, logs, inspect JSON, root file listing. |
| `Sources/AppleContainerUI/Services/ContainerStore+Groups.swift` | Compose project groups (`ContainerGroup`): grouping, selection, and bulk start / stop / restart / delete. |
| `Sources/AppleContainerUI/Services/MiniYAML.swift` | Dependency-free parser for the YAML subset used by Compose files. |
| `Sources/AppleContainerUI/Services/ComposeOrchestrator.swift` | Compose parser (interpolation, `env_file`, ports, volumes, build, healthcheck, resources), `depends_on` ordering, and the `apple/container` execution / teardown plans as argument vectors. |
| `Sources/AppleContainerUI/Services/DockerCommandTranslator.swift` | Token-based `docker …` -> `container …` command translator. |
| `Sources/AppleContainerUI/Services/AppSettings.swift` | `UserDefaults` persistence: language, custom binary path, imported stacks. |
| `Sources/AppleContainerUI/Views/MainWindowView.swift` | `NavigationSplitView` shell, sidebar with live CPU/MEM sparklines, bottom CLI status bar, and `MenuBarTrayView`. |
| `Sources/AppleContainerUI/Views/DashboardView.swift` | Cluster overview cards, 2x2 real-time charts, per-container bar chart, and 1-click microVM templates. |
| `Sources/AppleContainerUI/Views/ContainersSplitView.swift` | Master-detail container browser: list grouped by Compose project, and the 6 inspector tabs (`Metrics`, `Logs`, `Exec / Shell`, `Inspect & Mounts`, `Files`, `Raw JSON`). |
| `Sources/AppleContainerUI/Views/ContainerGroupViews.swift` | Group header row with bulk actions, and the group dashboard (aggregate KPIs, charts, per-container CPU / memory shares). |
| `Sources/AppleContainerUI/Views/ComposeStacksView.swift` | Visual `docker-compose.yml` stack manager with `Apple Container` vs `Docker CLI` engine selector, YAML editor, execution plan, and unified stack logs. |
| `Sources/AppleContainerUI/Views/ResourcesViews.swift` | Views for `Images`, `Volumes`, `Networks`, and `CLI & Docker` settings/translator. |
| `Sources/AppleContainerUI/Views/NewContainerSheet.swift` | Modal form to create & boot a new container microVM with live CLI command preview. |
| `Sources/AppleContainerUI/Views/Components/TelemetryCharts.swift` | Reusable `Swift Charts` components (`MetricChartCard`, `DualMetricChartCard`, `MiniSparklineView`, `ContainerBreakdownBarChart`). |

