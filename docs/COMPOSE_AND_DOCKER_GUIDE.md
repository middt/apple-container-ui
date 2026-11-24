# Docker & Docker Compose Guide (`apple/container` & `docker`)

**Vessel** enables you to run existing `docker-compose.yml` / `compose.yaml` projects **without any manual file conversion** on either **Apple Container** or **Docker CLI**.

---

## 1. How Zero-Conversion `docker-compose.yml` on Apple Container Works

Out of the box, Apple's `container` CLI manages individual Linux microVMs (`container run`, `container network`, `container volume`) and does not include a native `docker-compose.yml` parser.

Vessel's built-in [ComposeOrchestrator.swift](../Sources/AppleContainerUI/Services/ComposeOrchestrator.swift) automates the entire workflow:

1. **Zero-Conversion YAML Parsing:**
   - Parses `image`, `build`, `command`, `entrypoint`, `container_name`, `ports` (short and long syntax, host IP, ranges, `/udp`), `environment`, `env_file`, `volumes` (bind mounts, named volumes, `tmpfs`), `depends_on` (including `condition:`), `healthcheck`, `cpus`, `mem_limit`, `deploy.resources.limits`, `labels`, `working_dir`, `user`, `cap_add` / `cap_drop`, `profiles` (activated with `COMPOSE_PROFILES` in `.env`), top-level `networks` / `volumes` (`external`, `name`), and `${VAR}` interpolation (shell environment + `.env`). Multi-line flow lists (`command: [` … `]`) and block scalars are supported.
   - `restart` has no `apple/container` equivalent, and health is not monitored after startup; both are listed as warnings in the **Apple Container Execution** tab.
   - Not supported: `extends`, `secrets`, `configs`, more than one network per stack, and `network_mode: service:<x>` (every container is its own VM, so two containers cannot share a network namespace — see the vNext example for how to run sidecars instead).
2. **Topological Dependency Ordering (`depends_on`):**
   - Resolves the service dependency graph so upstream dependencies (e.g., `httpbin` or `postgres-primary`) boot before downstream services (e.g., `api-gateway-nginx` or `adminer-web`).
3. **Network & Service Discovery:**
   - Every stack gets one network: `<stack>_default`, or the first network the file declares (`external: true` networks keep their name, are shared between stacks and are never deleted by **Stack Down**).
   - On `apple/container`, containers can only resolve each other by name when a **local DNS domain** exists. Create one once (needs an administrator password): `sudo container system dns create vessel.test`. Vessel then gives every service the aliases `<service>` and `<container name>` in the zone `<network>.<domain>` and sets that zone as the DNS search domain, so plain Compose host names (`postgres`, `redis`) resolve — scoped per network like in Docker. Without a domain the execution plan shows a warning with this command.
   - Named volumes follow Compose naming: `<stack>_<volume>` unless declared `external` or given a `name`.
4. **Startup Order (`depends_on` conditions):**
   - `condition: service_healthy` — Vessel runs the dependency's `healthcheck` with `container exec` until it succeeds (for at most `start_period + retries × (interval + timeout)`), then starts the dependent service.
   - `condition: service_completed_successfully` — Vessel waits until the one-shot container (a migrator, a seeder) has stopped. `apple/container` does not report exit codes, so only completion can be verified.
5. **Dual-Engine Execution:**
   - **Engine = `Apple Container (MicroVM)`:** Executes the plan shown in the **Apple Container Execution** tab step by step (`container network create`, `container volume create`, `container build`, `container run --detach …`). A failing step aborts the deployment and is shown in the error banner. **Stack Down** stops and deletes the stack's containers and its network; named volumes are kept.
   - **Engine = `Docker CLI Engine`:** Runs `docker compose --project-name <stack> --project-directory <dir> --file <copy> up --detach`, and `docker compose --project-name <stack> down` for **Stack Down**. Vessel's `/http` and `/https` port hints are removed from the copy handed to Docker.
   - Either way, the stack's containers appear as a **group** in the Containers tab, with a group dashboard and bulk start / stop / restart / delete. Stacks started outside Vessel with `docker compose` are grouped the same way.

---

## 2. Running a Compose Stack Step by Step

1. Select **Compose Stacks** in the left sidebar.
2. Pick one of the included example stacks:
   - [examples/httpbin-gateway/docker-compose.yml](../examples/httpbin-gateway/docker-compose.yml) (`httpbin` + `api-gateway-nginx` + `redis-valkey-cache`)
   - [examples/postgres-stack/docker-compose.yml](../examples/postgres-stack/docker-compose.yml) (`postgres-primary` + `adminer-web`)
   - Or click **Import YAML** in the top-left of the stacks pane to open any `docker-compose.yml` file from disk.
3. Choose the target runtime in the top-right engine picker: **`Apple Container (MicroVM)`** or **`Docker CLI Engine`**.
4. Click **Stack Up**.
5. Switch to the **docker-compose.yml** tab to edit the YAML live and click **Apply YAML & Run** to redeploy immediately.
6. Switch to the **Apple Container Execution** tab to inspect the exact sequence of `container network create` and `container run -d` commands generated from your YAML file.

---

## 3. A Real Multi-Service Example: vNext Runtime

[examples/vnext-runtime/](../examples/vnext-runtime/README.md) runs the vNext workflow runtime — 8 infrastructure services and a 12-container domain with Dapr sidecars — as two stacks on a shared external network. Its README lists what had to change compared to the Docker Compose file.

A stack can also be deployed without the UI, through the same code path as **Stack Up**:

```bash
./scripts/stack-up.sh examples/vnext-runtime/vnext-infra/docker-compose.yml
```

---

## 4. Supported `docker-compose.yml` Fields

```yaml
version: "3.9"
services:
  httpbin:
    image: mccutchen/go-httpbin:v2.15.0
    cpus: 2
    mem_limit: 512m
    ports:
      - "8090:8080/http"   # Supports /http, /https, /tcp, /udp (auto-detected if omitted)
    environment:
      - PORT=8080
      - HOST=0.0.0.0
    volumes:
      - shared-artifacts:/data
    depends_on:
      - redis-valkey-cache
```

---

## 5. `docker run` -> `apple/container` Command Translator

In the **CLI & Docker** sidebar tab, paste any `docker run` command into the **Docker CLI & `docker run` → `apple/container` Direct Runner** box:

- **Input (`docker`):**
  ```bash
  docker run -d -p 8090:8080 --name httpbin -e PORT=8080 mccutchen/go-httpbin:v2.15.0
  ```
- **Translated Output (`apple/container`):**
  ```bash
  container run --detach --publish 8090:8080 --name httpbin --env PORT=8080 mccutchen/go-httpbin:v2.15.0
  ```

The translator tokenises the command like a shell, so `-p8080:80`, `--memory=512m`, combined flags (`-dit`) and quoted values are handled, and everything after the image name is left untouched. Flags without an `apple/container` equivalent (`--restart`, `--privileged`, `--health-*`, …) are dropped and listed in a `#` note. Other subcommands are mapped too (`docker ps` -> `container list`, `docker rmi` -> `container image delete`, `docker restart x` -> `container stop x && container start x`).
