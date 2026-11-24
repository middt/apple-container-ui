# Vessel — Native macOS Container Studio for `apple/container`

**Vessel** is a fast, lightweight (~2.5 MB), 100% native macOS desktop UI built with **SwiftUI + Swift Charts** for Apple's Linux microVM container runtime ([github.com/apple/container](https://github.com/apple/container)) with built-in, zero-conversion **`docker-compose.yml`** support.

![Vessel — Containers & Live Metrics](docs/images/vessel-containers.png)

---

## Step-by-Step Getting Started

### Step 1 — Install & Start Apple's `container` Engine
Vessel runs on top of Apple's official `container` runtime (requires an **Apple Silicon Mac** running **macOS 15+**).

```bash
# 1. Install apple/container via Homebrew:
brew install --cask container

# 2. Start the background system daemon:
container system start

# 3. Verify the engine is running:
container system status

# 4. (Optional) Enable local DNS so containers in a Compose stack can resolve each other by service name (*.test):
sudo container system dns create test
container system property set dns.domain test
```

---

### Step 2 — Install Vessel via Homebrew
Install **Vessel** from our Homebrew tap and launch it:

```bash
# 1. Add the Vessel tap and install the macOS app:
brew tap middt/vessel https://github.com/middt/apple-container-ui
brew install --cask vessel

# 2. Open Vessel:
open -a Vessel
```

---

### Step 3 — Run Your First Container
You can spin up a Linux microVM container either from the **Vessel UI** or directly from the **terminal** (any container started in the terminal immediately appears in Vessel with live CPU, Memory, Network, and Disk charts).

#### Option A: From the Vessel UI
1. Click **`+ Run Container`** (`Cmd + N`) in the top-right toolbar (or click **Launch** on any 1-click template such as **`httpbin`**, **`nginx`**, **`postgres`**, or **`valkey`** on the **Dashboard**).
2. Enter the container settings:
   - **Name:** `httpbin`
   - **Image:** `mccutchen/go-httpbin:v2.15.0`
   - **Resources:** `2 vCPU`, `512 MB RAM`
   - **Port:** `8090` → `8080` (`HTTP`)
3. Click **`Create & Boot MicroVM`**.
4. Once running, click **`:8090`** (or **`Open http://localhost:8090`**) to open it in your browser, or click **`Shell`** to open an interactive terminal inside the microVM.

#### Option B: Example Terminal Commands
```bash
# Start an httpbin microVM container (2 vCPU, 512 MB RAM, port 8090 -> 8080):
container run -d --name httpbin --cpus 2 --memory 512M --publish 8090:8080 mccutchen/go-httpbin:v2.15.0

# Start a PostgreSQL 17 microVM container (port 5432):
container run -d --name postgres-dev --cpus 2 --memory 1024M --publish 5432:5432 --env POSTGRES_PASSWORD=postgres postgres:17-alpine

# Check running containers and test the HTTP endpoint:
container list
curl -s http://localhost:8090/get
```

---

### Step 4 — Run a `docker-compose.yml` Stack (Zero Conversion)
Apple's `container` CLI does not natively parse `docker-compose.yml` files. **Vessel** includes a built-in Compose orchestrator that runs standard `docker-compose.yml` files directly on `apple/container` without any manual conversion.

![Vessel — Compose Stacks](docs/images/vessel-compose-stacks.png)

1. Save the following sample file as `docker-compose.yml` (or use any existing `docker-compose.yml` project on your Mac):
   ```yaml
   version: "3.9"
   services:
     httpbin:
       image: mccutchen/go-httpbin:v2.15.0
       cpus: 2
       mem_limit: 512m
       ports:
         - "8090:8080/http"
     api-gateway:
       image: nginx:1.27-alpine
       cpus: 2
       mem_limit: 512m
       ports:
         - "8080:80/http"
       depends_on:
         - httpbin
     cache:
       image: valkey/valkey:8.0-alpine
       cpus: 1
       mem_limit: 512m
       ports:
         - "6379:6379/tcp"
   ```
2. In **Vessel**, open the **`Compose Stacks`** tab (`Cmd + 3`) in the left sidebar.
3. Click **`Import YAML`** and select your `docker-compose.yml` file.
4. Set the engine dropdown in the top-right to **`Apple Container (MicroVM)`** (or **`Docker CLI Engine`** to run via `docker compose`).
5. Click **`Stack Up`**.
   - Vessel automatically generates and runs the underlying `apple/container` commands in `depends_on` order:
     ```bash
     container network create httpbin-gateway_default
     container run --detach --name httpbin-gateway-httpbin-1 --network httpbin-gateway_default --cpus 2 --memory 512M --publish 8090:8080 mccutchen/go-httpbin:v2.15.0
     container run --detach --name httpbin-gateway-api-gateway-1 --network httpbin-gateway_default --cpus 2 --memory 512M --publish 8080:80 nginx:1.27-alpine
     container run --detach --name httpbin-gateway-cache-1 --network httpbin-gateway_default --cpus 1 --memory 512M --publish 6379:6379 valkey/valkey:8.0-alpine
     ```
6. Verify the running stack endpoints:
   ```bash
   curl -s http://localhost:8090/get
   curl -I http://localhost:8080
   container list
   ```

---

## Application Screenshots

### 1. Cluster Dashboard & Real-Time Charts
Live cluster CPU, Memory, `vmnet` Network RX/TX, and Disk I/O telemetry alongside per-container resource distribution and 1-click microVM templates.

![Vessel — Dashboard](docs/images/vessel-dashboard.png)

### 2. Containers Inspector (Metrics, Logs, Exec/Shell, Mounts, Files & Raw JSON)
Grouped by Compose project with protocol-aware port actions (**Open in Browser** & **Test HTTP Output** for HTTP/HTTPS services; **Copy TCP Endpoint** for raw TCP sockets like PostgreSQL and Redis/Valkey).

![Vessel — Containers Inspector](docs/images/vessel-containers-overview.jpg)

### 3. Zero-Conversion `docker-compose.yml` Stack Manager
Edit `docker-compose.yml` live in the UI, inspect the generated `apple/container` execution plan, and view combined stack logs.

![Vessel — Compose Stacks](docs/images/vessel-compose-stacks.png)

---

## Documentation

| Document | Description |
| :--- | :--- |
| **[User Guide (`docs/USER_GUIDE.md`)](docs/USER_GUIDE.md)** | Complete walkthrough of all screens, keyboard shortcuts, and features. |
| **[Docker & Compose Guide (`docs/COMPOSE_AND_DOCKER_GUIDE.md`)](docs/COMPOSE_AND_DOCKER_GUIDE.md)** | How zero-conversion `docker-compose.yml` orchestration works on `apple/container`. |
| **[Architecture (`docs/ARCHITECTURE.md`)](docs/ARCHITECTURE.md)** | Internal architecture, CLI parsers, Compose DNS networking, and build pipeline. |
