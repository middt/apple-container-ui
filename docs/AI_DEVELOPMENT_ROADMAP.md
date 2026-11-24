# Vessel — AI Development Guide & Roadmap

This document provides ready-to-use prompts and a structured technical roadmap for continuing development on **Vessel** with AI coding agents (Antigravity, Claude Code, OpenAI Codex, Cursor, etc.).

---

## 1. Initializing an AI Session

When starting a new session with an AI coding agent, provide the following context prompt:

> "Read `AGENTS.md` and `docs/ARCHITECTURE.md`. Follow all architectural constraints (specifically `@ObservedObject` state management, `store.t(en, tr)` localization for English/Turkish, and building via `./scripts/bundle-app.sh`) and implement the following feature: ..."

---

## 2. Upcoming Phases & Ready-to-Use AI Prompts

### Phase 2.1 — Visual `Dockerfile` / `Containerfile` Image Builder (`container build`)
**Goal:** Build OCI images directly from the UI using a visual `Dockerfile` editor and stream real-time BuildKit logs.

**Prompt to Use:**
```text
Following the rules in AGENTS.md (including English and Turkish localization via store.t), add a visual "Dockerfile / Containerfile Image Builder" section to the Images view (there is no Builder VM page; `container build` starts the builder on demand).
Allow the user to:
1. Specify an image tag (e.g., my-api:v1) and target architecture (linux/arm64, linux/amd64),
2. Edit a Dockerfile in-app or import one from disk,
3. Click "Build Image" to run `container build -t <tag> .` (or `docker build` if Docker CLI is selected), stream build step logs, and append the built image to `store.images`.
```

---

### Phase 2.2 — Visual Service Wizard for `docker-compose.yml`
**Goal:** Add services (PostgreSQL, Valkey/Redis, Nginx, RabbitMQ, MinIO, Mailpit) to a Compose Stack via a form without writing YAML manually.

**Prompt to Use:**
```text
Following AGENTS.md (including English/Turkish localization via store.t), add an "Add Service to Stack" button and sheet to ComposeStacksView.
When the user selects a preset from the catalog (PostgreSQL, Valkey/Redis, Nginx, httpbin, MinIO, Mailpit) or enters custom image/port/env values, automatically append the formatted YAML block to the selected ComposeStackItem's `yamlContent` and refresh the topology view.
```

---

### Phase 2.3 — Interactive Container File Browser (`container exec` + `cp`)
**Goal:** Navigate subdirectories inside a container (`cd`), preview configuration files (`cat`), and copy files between macOS and the container.

**Prompt to Use:**
```text
Following AGENTS.md (including English/Turkish localization via store.t), make the "Files" tab in ContainersSplitView interactive:
1. Double-clicking a directory navigates into that path with a breadcrumb bar (`/ -> etc -> nginx`),
2. Clicking a text or configuration file (`nginx.conf`, `os-release`, `.env`) previews its contents in a side pane,
3. Use `container exec <id> ls -la <path>` and `container exec <id> cat <file>`. Do not add sample data: there is no demo mode.
```

---

### Phase 2.4 — Container Healthchecks & Resource Alerts
**Goal:** Monitor HTTP health endpoints (`/healthz`, `/get`) and display alerts when container CPU or memory usage exceeds 85%.

**Prompt to Use:**
```text
Following AGENTS.md (including English/Turkish localization via store.t), add `healthStatus` (healthy, unhealthy, starting) and `healthcheckPath` (e.g., `/get` or `/healthz`) to ContainerItem.
Update the telemetry loop in ContainerStore to evaluate health status for running HTTP containers, render a green "Healthy" badge in the UI, and show a warning banner on the Dashboard when any container exceeds 85% memory utilization.
```

---

## 3. Troubleshooting

- **`SwiftUIMacros` error during compilation:**
  - A view used `@State` or `@Observable`. Move that property onto `ContainerStore` as `@Published` and bind via `@ObservedObject var store: ContainerStore`.
- **Thousands separator comma in port numbers (`8,080`):**
  - Use `Text(":\(String(port))")` instead of `Text(":\(port)")`.
- **Missing translation in UI:**
  - Always wrap user-facing strings with `store.t("English text", "Türkçe metin")`.
