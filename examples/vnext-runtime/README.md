# vNext Runtime on Apple Container

Three Compose stacks that run the [vNext Runtime](https://github.com/burgan-tech/vnext-runtime) on
`apple/container` through Vessel, adapted from `vnext-runtime/vnext/docker/docker-compose.yml`:

| Stack | Folder | What it runs |
| :--- | :--- | :--- |
| `vnext-infra` | [vnext-infra/](vnext-infra/docker-compose.yml) | Postgres, Redis, Vault, Dapr placement + scheduler, OpenObserve, OTel collector |
| `vnext-core` | [vnext-core/](vnext-core/docker-compose.yml) | One domain: db-migrator, orchestrator, execution, inbox / outbox workers, init, component publisher — each with its Dapr sidecar |
| `vnext-mocklab` | [vnext-mocklab/](vnext-mocklab/docker-compose.yml) | MockLab (the API mocks of the `vnext-example` domain) and its Dapr sidecar — needed for the example's integration tests |

All stacks attach to the external network `vnext-development`, so they share one DNS zone.

## Prerequisites

1. **A local DNS domain** (once per machine; needs an administrator password). Without it
   containers on `apple/container` can only reach each other by IP address:
   ```bash
   sudo container system dns create vnext.test
   ```
2. **A `vnext-runtime` checkout** with the domain's configuration files:
   ```bash
   cd <vnext-runtime> && make create-domain DOMAIN=core PORT_OFFSET=0
   ```
3. **`.env` files** next to each Compose file: copy `.env.example` to `.env` and set
   `VNEXT_DOCKER_DIR` to `<vnext-runtime>/vnext/docker` (`VNEXT_EXAMPLE_DIR` to the `vnext-example`
   checkout for MockLab). For `vnext-core`, the ports mirror `<VNEXT_DOCKER_DIR>/domains/<domain>/.env`.
4. **A static BusyBox** for the localhost bridges (see below): `./examples/vnext-runtime/tools/fetch-busybox.sh`.

## Running

In Vessel: **Compose Stacks → Import YAML**, pick `vnext-infra/docker-compose.yml`, **Stack Up**;
then the same for `vnext-core/docker-compose.yml`. Or headless, through the same code path:

```bash
./scripts/stack-up.sh examples/vnext-runtime/vnext-infra/docker-compose.yml
./scripts/stack-up.sh examples/vnext-runtime/vnext-core/docker-compose.yml
./scripts/stack-up.sh examples/vnext-runtime/vnext-mocklab/docker-compose.yml
```

The first run pulls about fifteen images. The stacks appear as groups in the **Containers** tab.

Endpoints on the host: runtime `http://localhost:4201` (execution 4202, inbox 4203, outbox 4204),
init `3005`, MockLab `3001`, the orchestrator's Dapr HTTP API `42110`, Postgres `5432`, Redis `6379`,
Vault `8200`, OpenObserve `5080`.

## What had to change compared to the Docker file

- **Dapr sidecars.** The Docker file puts every `daprd` into its application's network namespace
  (`network_mode: service:<app>`) so both talk over `localhost`. On `apple/container` every
  container is its own VM, so that does not exist. Each sidecar is a container of its own:
  `daprd` reaches the app with `--app-channel-address <app container>` and listens on all
  interfaces (`--dapr-listen-addresses 0.0.0.0`); the app reaches `daprd` through
  `DAPR_HTTP_ENDPOINT` / `DAPR_GRPC_ENDPOINT`.
- **Sidecar-to-sidecar calls.** Dapr's default name resolver (mDNS) fails between the container
  VMs ("zeroconf register: No supported interface"). [dapr/config.yaml](dapr/config.yaml) switches
  every sidecar to the `nameformat` resolver (`{appid}-dapr:50002`), which is why the sidecar
  containers are named `<app-id>-dapr` and use `--dapr-internal-grpc-port 50002`.
- **`localhost` inside the runtime.** Components written for a runtime on the developer's machine
  call `http://localhost:3001` (MockLab) and `http://localhost:4201` (the runtime itself). Inside a
  container that is the container. [tools/with-localhost-forwards.sh](tools/with-localhost-forwards.sh)
  wraps the entrypoint of the four applications and forwards those ports with BusyBox `nc`
  (`LOCALHOST_FORWARDS`).
- **Profiles.** Infrastructure and domain are separate stacks instead of two profiles of one file.
- **Service discovery.** Vessel gives every service the aliases `<service>` and `<container_name>`
  in the zone `vnext-development.<dns domain>` and sets it as the search domain, so the unchanged
  host names (`vnext-postgres`, `vnext-redis`, `dapr-placement`, `otel-collector`, …) resolve.
- **Startup order.** `depends_on` conditions are emulated by Vessel: `service_healthy` runs the
  healthcheck with `container exec` until it passes, `service_completed_successfully` waits for
  the one-shot container (the db-migrator) to stop.
- **Postgres data directory.** A named volume on `apple/container` is an ext4 image with a
  `lost+found` directory at its root, which `initdb` rejects; `PGDATA` points one level deeper.
- **Vault** listens on `0.0.0.0` so the other containers can reach it.
