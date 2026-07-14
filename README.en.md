# LiteWaf Gateway

> Language / 语言: [中文](README.md) | [English](README.en.md)

LiteWaf Gateway is the open-source OpenResty data-plane component for LiteWaf. It loads published gateway configuration, proxies protected traffic to upstream services, applies WAF decisions on the hot path, and emits access, WAF event, and metrics data.

Related repositories:

- API and project docs: [litewaf-api](https://github.com/newz-max/litewaf-api)
- Dashboard: [litewaf-dashboard](https://github.com/newz-max/litewaf-dashboard)
- OpenResty data-plane gateway: [litewaf-gateway](https://github.com/newz-max/litewaf-gateway)

Public API, deployment, rule, and operator documentation is maintained in the API repository. Start from `doc/文档索引.md`; day-to-day site creation, publishing, gateway verification, logs, and rollback are covered in `doc/使用说明.md`.

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
| `LITEWAF_CONFIG_PATH` | `/etc/litewaf/current/active.json` | Active versioned gateway configuration path |
| `LITEWAF_INGESTION_URL` | empty | LiteWaf API ingestion endpoint |
| `LITEWAF_INGESTION_TOKEN` | empty | Bearer token for log ingestion |
| `LITEWAF_METRICS_ENABLED` | `false` | Enables `/metrics` output when true |
| `LITEWAF_CHALLENGE_SECRET` | empty | Bot verification signing secret |
| `LITEWAF_DYNAMIC_SECRET` | empty | Dynamic protection signing secret |
| `LITEWAF_DYNAMIC_BAN_CLEAR_INTERVAL` | `5` | Seconds between manual dynamic-ban clear feed polls; set `0` to disable polling |
| `LITEWAF_SENSITIVE_HEADERS` | `authorization,cookie,set-cookie` | Headers excluded from log values |
| `LITEWAF_LOG_VALUE_MAX_LEN` | `160` | Maximum logged header/value length |
| `LITEWAF_REAL_IP_TRUSTED_CIDRS` | empty | Comma or space separated trusted proxy CIDRs for real client IP recovery |
| `LITEWAF_REAL_IP_HEADER` | `X-Forwarded-For` | Forwarded client IP header accepted from trusted proxies |
| `LITEWAF_REAL_IP_RECURSIVE` | `on` | Enables recursive forwarded-header parsing for trusted proxy chains |

The repository includes `conf/active.json` as a bootstrap empty configuration and smoke-test configurations under `conf/*-smoke-active.json`.

Leave `LITEWAF_REAL_IP_TRUSTED_CIDRS` empty for direct-client deployments. When LiteWaf is behind a trusted load balancer, CDN, host reverse proxy, or Docker bridge proxy path, set it to the immediate trusted proxy CIDR list, for example `172.16.0.0/12` for a Docker bridge validation environment. The gateway does not trust arbitrary `X-Forwarded-For` or `X-Real-IP` headers unless the peer address matches the configured trusted CIDRs.

Manual dynamic-ban release is synchronized outside the request hot path. When `LITEWAF_INGESTION_URL`, `LITEWAF_INGESTION_TOKEN`, and `LITEWAF_DYNAMIC_BAN_CLEAR_INTERVAL` are configured, worker 0 polls `/api/v1/dynamic-bans/clears` with the gateway ingestion token, consumes increasing revisions, and deletes the matching local `application_id/client_ip` dynamic-ban key. The clear feed may include listener context (`listener_port` and `scheme`) for observability, while enforcement remains application-scoped. Requests continue to use local shared dictionaries only; a manual release can take up to one poll interval to affect enforcement. Each applied release emits a bounded `dynamic_ban_clear` JSON log record.

The gateway only enforces the active published configuration file. Creating or editing protected applications, rules, policies, IP lists, or protection modules in the control plane does not affect this repository's runtime until the API publishes a new release and writes the updated active config.

## Smoke Validation

Build the image first, then run the relevant PowerShell smoke script from a Windows host with Docker available:

```powershell
docker build -t litewaf-gateway .
pwsh ./scripts/smoke.ps1 -Image litewaf-gateway
```

Additional smoke scripts cover access control, attack protection, bot protection, CC advanced counters, dynamic protection, migration compatibility, upload protection, and real client IP recovery:

```powershell
pwsh ./scripts/real-ip-smoke.ps1
pwsh ./scripts/manual-unban-smoke.ps1
```

## Repository Status

This repository contains the LiteWaf OpenResty gateway source and validation assets. API, dashboard, deployment documentation, and OpenSpec artifacts are maintained in their companion repositories/workspace.

## License

This repository is licensed under the [Apache License 2.0](LICENSE). You may use, copy, modify, distribute, and use the project commercially under that license.
