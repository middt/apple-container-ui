# CLAUDE.md — Project Guide for Claude Code

Please read **[AGENTS.md](AGENTS.md)** and **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** first before making any edits.

## Quick Commands
- **Run Unit Tests:** `./scripts/test.sh`
- **Build & Package (`dist/Vessel.app`):** `./scripts/bundle-app.sh`
- **Launch App:** `open dist/Vessel.app`

## Key Invariants
1. Use `ObservableObject`, `@Published`, `@StateObject`, and `@ObservedObject` — **never** use `@State` or `@Observable` macros (required for CommandLineTools compatibility without full Xcode.app).
2. Always format port numbers using `String(port)` inside SwiftUI `Text`/`Label` to avoid localized commas (`8080`, not `8,080`).
3. When adding new `.swift` files, register them in `scripts/bundle-app.sh`.
4. Run every command through `ContainerRuntime` (`store.perform` + `store.settle`); change state only after the command succeeded, and never show invented data — there is no demo mode (see AGENTS.md Rule 5).

