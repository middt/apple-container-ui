# Vessel — Native macOS Container Studio for `apple/container` & Docker Compose

**Vessel** is a lightweight (~4 MB binary), 100% native macOS desktop studio built with **Swift + SwiftUI + Swift Charts** for Apple's Linux microVM container runtime ([github.com/apple/container](https://github.com/apple/container)) and the **Docker / Docker Compose** ecosystem.

---

## Key Features

- **100% Native macOS (`SwiftUI` + `Swift Charts`):** No Electron or WebView; a single ~4 MB binary with no third-party dependencies.
- **Multi-Language Support (English & Turkish):** Automatically detects the system language on startup (`tr` -> Turkish, any other or unsupported language -> defaults to English) with an instant in-app language switcher in the toolbar.
- **Real-Time Telemetry Charts (sampled every 2 s, every 10 s while in the background):**
  - Live **CPU Utilization (%)**, **Memory Usage (MB / Limit)**, **`vmnet` Network Throughput (RX / TX KB/s)**, and **`VirtioBlk` Disk I/O (Read / Write KB/s)** charts per container and across the entire cluster.
  - Live sidebar CPU & Memory sparklines and a per-container resource breakdown bar chart on the Dashboard.
- **Real CLI, real state:**
  - Every button runs the real `container` (or `docker`) command, and the UI only shows what the CLI reports. A failed command is shown in a banner and never changes the UI state.
- **Safety nets:**
  - Deleting a running container, a Compose group or a volume, and stopping the container system while containers run, ask for confirmation first.
  - If macOS denies the Local Network permission to `container-runtime-linux`, published ports silently reset connections. Vessel probes each started container's port, detects this in the system log and shows a warning with a shortcut to the right Settings page.
- **Compose groups:**
  - Containers started by `docker compose` or a Vessel stack are grouped by project in the container list. A group has its own dashboard (aggregate CPU, memory, network and disk charts, per-container shares) and can be started, stopped, restarted or deleted as a unit.
- **Real multi-service stacks:** service discovery through a local DNS domain (aliases per network + search domain), health-gated startup (`depends_on: condition: service_healthy` / `service_completed_successfully`), external networks shared between stacks, Compose volume naming and profiles. [examples/vnext-runtime/](examples/vnext-runtime/README.md) runs a 20-container Dapr-based runtime this way.
- **Zero-Conversion `docker-compose.yml` -> `apple/container` (`Compose Stacks`):**
  - Run `docker-compose.yml` / `compose.yaml` files on **Apple Container** (Vessel executes the generated `container network create` / `volume create` / `build` / `run` commands in dependency order) or via **`docker compose`**, without manual file conversion.
- **Protocol-Aware Port Actions (`HTTP/HTTPS` vs Raw `TCP/UDP`):**
  - Only actual web services (`httpbin :8090`, `nginx :8080`, `http-echo :8088`, `:3000`) display **Open in Browser (`safari`)** and **Test HTTP Output** buttons.
  - Raw TCP sockets such as PostgreSQL (`5432/tcp`) and Valkey/Redis (`6379/tcp`) display a **Raw TCP Socket** badge and **Copy TCP Endpoint (`127.0.0.1:5432`)** instead of browser buttons.

---

## Quick Start

### 1. Build and Launch (`dist/Vessel.app`)
```bash
chmod +x scripts/bundle-app.sh
./scripts/bundle-app.sh
open dist/Vessel.app
```

The bundle is ad-hoc signed. For distribution, sign with a Developer ID and the hardened runtime:
```bash
VESSEL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/bundle-app.sh
```

### 2. Run the Tests
```bash
./scripts/test.sh                 # unit tests (no containers are created)
VESSEL_E2E=1 ./scripts/test.sh    # additionally deploys and removes a tiny Compose stack on the real engine
```

---

## Documentation Map

| Document | Description |
| :--- | :--- |
| **[User Guide (`docs/USER_GUIDE.md`)](docs/USER_GUIDE.md)** | Step-by-step guide to all screens, keyboard shortcuts, localization, and container/network management. |
| **[Docker & Compose Guide (`docs/COMPOSE_AND_DOCKER_GUIDE.md`)](docs/COMPOSE_AND_DOCKER_GUIDE.md)** | Running `docker-compose.yml` stacks directly on Apple Container or Docker CLI, plus the command translator. |
| **[Architecture (`docs/ARCHITECTURE.md`)](docs/ARCHITECTURE.md)** | Internal architecture, data flow, CLI integration, localization system, and build pipeline. |
| **[AI Agent Guide (`AGENTS.md`)](AGENTS.md)** | Coding rules, compiler constraints, and file map for AI coding agents (Antigravity, Claude Code, Codex, Cursor). |
| **[AI Development Roadmap (`docs/AI_DEVELOPMENT_ROADMAP.md`)](docs/AI_DEVELOPMENT_ROADMAP.md)** | Planned phases and ready-to-use AI prompts for continuing development. |
