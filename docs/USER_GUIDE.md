# Vessel — User Guide

This guide covers the installation, user interface, multi-language support, and daily workflows of **Vessel — Apple Container Studio**.

---

## 1. Installation & Launch

### Requirements
- **Operating System:** macOS 15.0+ (Apple Silicon `arm64`)
- **Optional Runtime Binaries:**
  - `apple/container` CLI (`/usr/local/bin/container` or `/opt/homebrew/bin/container`)
  - `docker` & `docker compose` CLI (`/usr/local/bin/docker`)
  - Vessel shows only what the CLI reports. If the container system is stopped, the lists are empty and the power button in the sidebar runs `container system start --enable-kernel-install` (the first start downloads the default kernel).
  - If the `container` binary is not installed, a banner says so; there is no demo mode or sample data.
  - **Local DNS domain (for Compose stacks):** containers on `apple/container` only find each other by name after you create a DNS domain once: `sudo container system dns create vessel.test`. Vessel detects it and wires every stack's services to it; without one, a multi-service stack shows a warning in its execution plan.
  - **Local Network permission:** published ports (`localhost:8090`) only work if macOS allows `container-runtime-linux` under **System Settings → Privacy & Security → Local Network**. If it is denied, the browser only shows "connection reset". Vessel checks every container it sees start (it opens a short TCP connection to the published port) and shows an orange banner with an **Open Settings** button; the banner disappears by itself once access is allowed.
  - Failed commands appear in a red banner above the status bar and never change what the UI shows.

### Build & Run (or Install via Homebrew)
```bash
# Install via Homebrew (installs /Applications/Vessel.app + 'vessel' CLI):
brew tap middt/vessel https://github.com/middt/apple-container-ui
brew install --cask vessel

# Start the engine & launch Vessel:
vessel system start
open -a Vessel

# Run a container or a Compose stack from the terminal using 'vessel':
vessel run -d --name postgres-dev --cpus 2 --memory 1024M --publish 5432:5432 --env POSTGRES_PASSWORD=postgres postgres:17-alpine
vessel stack-up docker-compose.yml
vessel list
```

---

## 2. Multi-Language Support (English & Turkish)

Vessel supports **English (`en`)** and **Turkish (`tr`)**:
- **Automatic System Detection:** On startup, Vessel inspects macOS `Locale.preferredLanguages`. If the primary system language is Turkish (`tr`), Turkish is selected automatically. If the system language is English or any other language not yet supported by the app, Vessel defaults to **English (`en`)**.
- **Instant Language Switching:** Click the language selector (`EN` / `TR`) in the top window toolbar (or inside **CLI & Docker** settings) to switch the entire interface immediately without restarting.

---

## 3. Sidebar & Navigation

The left sidebar provides access to all workspaces and displays **live CPU and Memory sparkline graphs** in the footer:

1. **Dashboard (`Cmd+1`):**
   - Cluster summary cards (running Linux microVMs, aggregate CPU load, allocated VM memory, cached OCI image size).
   - 2x2 real-time cluster charts (CPU, Memory, `vmnet` Network RX/TX, Block Storage Read/Write).
   - **Per-Container MicroVM Resource Distribution:** Horizontal bar chart comparing memory and CPU usage across containers.
   - **1-Click Quick MicroVM Templates:** Launch `httpbin`, `nginx-web`, `redis-fast`, or `postgres-dev` with a single click.

2. **Containers (`Cmd+2`):**
   - **Left Master List:** State filter (`All`, `Running`, `Stopped`), instant search (`name`, `image`, `IP`), protocol badge (`:8090/http` in cyan, `:5432/tcp` in orange), and hover quick actions (**Start/Stop**, **Shell**, **Delete**).
   - **Compose groups:** containers started by `docker compose` or a Vessel stack are grouped by project under a collapsible header showing how many are running plus the group's CPU and memory. Hover the header (or right-click it) to **Start All**, **Stop All**, **Restart** or **Delete** the whole group; deleting asks for confirmation and keeps named volumes.
   - **Group dashboard:** click a group header to see aggregate CPU, memory, network and disk charts for the group, each container's share of CPU and memory, per-container start/stop, and a shortcut to the Compose file.
   - **Right Detail Inspector (6 Tabs):**
     - **Metrics:** 4 real-time `Swift Charts` cards (CPU %, Memory MB, Network RX/TX KB/s, Block Disk I/O KB/s) + 5 KPI summary pills.
     - **Logs:** Live log stream with level badges (`INFO`, `WARN`, `ERROR`), search filter, and 1-click Copy.
     - **Exec / Shell:** Quick preset command chips (`uname -a`, `ps aux`, `ip addr`, `df -h`, `env`, `cat /etc/os-release`), custom command execution, and **Open in macOS Terminal.app** (`container exec -it <id> /bin/sh`).
     - **Inspect & Mounts:** Hardware virtualization details, `vmnet` IP/MAC/DNS info, published port forwards, `VirtioFS` volume mounts, and environment variables (`Show/Hide Values`).
     - **Files:** Root directory listing (`exec <id> ls -la /`).
     - **Raw JSON:** The real `container inspect <id>` / `docker inspect <id>` output.

3. **Compose Stacks (`Cmd+3`):**
   - Run unmodified `docker-compose.yml` projects directly on **Apple Container** or **Docker CLI**.
   - See [COMPOSE_AND_DOCKER_GUIDE.md](COMPOSE_AND_DOCKER_GUIDE.md) for details.

4. **Images (`Cmd+4`):**
   - Browse cached OCI images, pull new images from registries (`Pull Image`), launch a container directly from an image (`Run`), or delete unused images.

5. **Volumes (`Cmd+5`):**
   - Create persistent volumes, see which containers use them, and delete volumes (asks for confirmation — the data is lost).

6. **Networks (`Cmd+6`):**
   - Manage macOS `vmnet` virtual network bridges (`bridge100`, `bridge101`), subnet CIDRs, gateways, and `*.container.local` DNS domains.

7. **CLI & Docker (`Cmd+7`):**
   - Configure custom binary paths for `apple/container` and `docker`, use the **`docker run` -> `apple/container` translator**, and inspect the CLI command audit log.

---

## 4. Protocol-Aware HTTP (`httpbin`) vs TCP Port Handling

Vessel distinguishes between application-layer HTTP/HTTPS services and raw TCP/UDP sockets:

- **Web / HTTP Services (`http`, `https`):**
  - Examples: **`httpbin`** (`8090 → 8080/http`), **`http-echo-demo`** (`8088 → 8080/http`), **`api-gateway-nginx`** (`8080 → 80/http`).
  - Displays **`Open http://localhost:8090`** in the header and under *Inspect & Mounts*.
  - Clicking **`Test HTTP Output`** sends a real HTTP request to the published port and displays the actual status, headers and body (or the connection error).
- **Raw TCP Sockets (`tcp`, `udp`):**
  - Examples: **`postgres-primary`** (`5432 → 5432/tcp`), **`redis-valkey-cache`** (`6379 → 6379/tcp`).
  - Does **not** display an "Open in Browser" button; instead shows a **`Raw TCP Socket`** indicator and a **`Copy 127.0.0.1:5432`** button.

---

## 5. Keyboard Shortcuts & Menu Bar Tray (`MenuBarExtra`)

| Shortcut | Action |
| :--- | :--- |
| `Cmd + N` | Open the "Run New Container MicroVM" sheet |
| `Cmd + R` | Refresh container states and telemetry |
| `Cmd + 1` .. `Cmd + 7` | Switch between the sidebar sections, in order |

Deleting a running container or a whole group, deleting a volume, and stopping the container system while containers are running all ask for confirmation.

You can also click the container box icon in the macOS top-right **Menu Bar** to view live CPU/RAM usage and start or stop containers without opening the main window.
