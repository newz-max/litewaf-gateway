# LiteWaf Gateway

LiteWaf Gateway is the OpenResty data-plane component for LiteWaf. It loads published gateway configuration, proxies protected traffic to upstream services, applies WAF decisions on the hot path, and emits access, WAF event, and metrics data.

Related repositories:

- API and project docs: [litewaf-api](https://github.com/newz-max/litewaf-api)
- Dashboard: [litewaf-dashboard](https://github.com/newz-max/litewaf-dashboard)
- OpenResty data-plane gateway: [litewaf-gateway](https://github.com/newz-max/litewaf-gateway)

## Runtime Scope

- OpenResty + LuaJIT reverse proxy.
- Local JSON configuration loading from `/etc/litewaf/active.json` by default.
- IP/access control, CC protection, managed attack protection, upload protection, bot verification, dynamic protection, dynamic source ban, and scoring-based enforcement.
- Structured JSON logs, best-effort ingestion to LiteWaf API, and basic Prometheus metrics.
- No remote database calls on the request hot path.

## Build

```bash
docker build -t litewaf-gateway .
```

The default runtime image is `openresty/openresty:1.27.1.2-0-bookworm-fat`. You can override it at build time:

```bash
docker build \
  --build-arg OPENRESTY_RUNTIME_IMAGE=openresty/openresty:1.27.1.2-0-bookworm-fat \
  -t litewaf-gateway .
```

## Run

```bash
docker run --rm -p 18081:8080 litewaf-gateway
```

Health check:

```bash
curl http://localhost:18081/healthz
```

## Configuration

Important environment variables:

| Name | Default | Description |
| --- | --- | --- |
| `LITEWAF_CONFIG_PATH` | `/etc/litewaf/active.json` | Active gateway configuration path |
| `LITEWAF_INGESTION_URL` | empty | LiteWaf API ingestion endpoint |
| `LITEWAF_INGESTION_TOKEN` | empty | Bearer token for log ingestion |
| `LITEWAF_METRICS_ENABLED` | `false` | Enables `/metrics` output when true |
| `LITEWAF_CHALLENGE_SECRET` | empty | Bot verification signing secret |
| `LITEWAF_DYNAMIC_SECRET` | empty | Dynamic protection signing secret |
| `LITEWAF_SENSITIVE_HEADERS` | `authorization,cookie,set-cookie` | Headers excluded from log values |
| `LITEWAF_LOG_VALUE_MAX_LEN` | `160` | Maximum logged header/value length |

The repository includes `conf/active.json` as a bootstrap empty configuration and smoke-test configurations under `conf/*-smoke-active.json`.

## Smoke Validation

Build the image first, then run the relevant PowerShell smoke script from a Windows host with Docker available:

```powershell
docker build -t litewaf-gateway .
pwsh ./scripts/smoke.ps1 -Image litewaf-gateway
```

Additional smoke scripts cover access control, attack protection, bot protection, CC advanced counters, dynamic protection, migration compatibility, and upload protection.

## Repository Status

This repository contains the LiteWaf OpenResty gateway source and validation assets. API, dashboard, deployment documentation, and OpenSpec artifacts are maintained in their companion repositories/workspace.
