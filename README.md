# LiteWaf Gateway

LiteWaf Gateway is the open-source OpenResty data-plane component for LiteWaf. It loads published gateway configuration, proxies protected traffic to upstream services, applies WAF decisions on the hot path, and emits access, WAF event, and metrics data.

中文摘要：LiteWaf Gateway 是 LiteWaf 的 OpenResty 数据面网关。它加载控制面发布后的网关配置，代理受保护流量到上游服务，在请求热路径执行 IP/访问控制、CC 防护、攻击防护、上传防护、Bot 验证、动态防护和评分阈值决策，并输出访问日志、WAF 事件和指标数据。

Related repositories:

- API and project docs: [litewaf-api](https://github.com/newz-max/litewaf-api)
- Dashboard: [litewaf-dashboard](https://github.com/newz-max/litewaf-dashboard)
- OpenResty data-plane gateway: [litewaf-gateway](https://github.com/newz-max/litewaf-gateway)

Public API, deployment, rule, and operator documentation is maintained in the API repository. Start from `doc/文档索引.md`; day-to-day site creation, publishing, gateway verification, logs, and rollback are covered in `doc/使用说明.md`.

相关仓库：

- API 和项目文档：[litewaf-api](https://github.com/newz-max/litewaf-api)
- Dashboard：[litewaf-dashboard](https://github.com/newz-max/litewaf-dashboard)
- OpenResty 数据面网关：[litewaf-gateway](https://github.com/newz-max/litewaf-gateway)

公开 API、部署、规则和日常操作文档维护在 API 仓库中。建议从 `doc/文档索引.md` 开始阅读；防护应用创建、发布、网关验证、日志和回滚流程见 `doc/使用说明.md`。

## Runtime Scope

- OpenResty + LuaJIT reverse proxy.
- Local JSON configuration loading from `/etc/litewaf/active.json` by default.
- IP/access control, CC protection, managed attack protection, upload protection, bot verification, dynamic protection, dynamic source ban, and scoring-based enforcement.
- Structured JSON logs, best-effort ingestion to LiteWaf API, and basic Prometheus metrics.
- No remote database calls on the request hot path.

## 运行范围

- OpenResty + LuaJIT 反向代理。
- 默认从 `/etc/litewaf/active.json` 加载本地发布配置。
- 支持 IP/访问控制、CC 防护、托管攻击防护、上传防护、Bot 验证、动态防护、动态封禁和基于评分的处置。
- 输出结构化 JSON 日志，尽力写入 LiteWaf API，并提供基础 Prometheus 指标。
- 请求热路径不访问远程数据库。

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
| `LITEWAF_RELOAD_WATCH_ENABLED` | `true` | Watches published gateway config files and reloads OpenResty automatically |
| `LITEWAF_RELOAD_WATCH_INTERVAL` | `2` | Seconds between config change checks |
| `LITEWAF_RELOAD_WATCH_DEBOUNCE` | `1` | Seconds to wait for config writes to stabilize before reload |
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

网关只执行当前已发布的活动配置文件。在控制面创建或修改防护应用、规则、策略、IP 名单或防护模块后，必须由 API 发布新版本并写入新的活动配置，本网关运行时才会生效。

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

本仓库包含 LiteWaf OpenResty 网关源码和验证资产。API、Dashboard、部署文档和 OpenSpec 变更分别维护在配套仓库或工作区中。

## License

This repository is licensed under the [Apache License 2.0](LICENSE). You may use, copy, modify, distribute, and use the project commercially under that license.
