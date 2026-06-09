# LiteWaf Gateway

> 语言 / Language: [中文](README.md) | [English](README.en.md)

LiteWaf Gateway 是 LiteWaf 的 OpenResty 数据面网关。它加载控制面发布后的网关配置，代理受保护流量到上游服务，在请求热路径执行 IP/访问控制、CC 防护、攻击防护、上传防护、Bot 验证、动态防护和评分阈值决策，并输出访问日志、WAF 事件和指标数据。

## 相关仓库

- API 和项目文档：[litewaf-api](https://github.com/newz-max/litewaf-api)
- Dashboard：[litewaf-dashboard](https://github.com/newz-max/litewaf-dashboard)
- OpenResty 数据面网关：[litewaf-gateway](https://github.com/newz-max/litewaf-gateway)

公开 API、部署、规则和日常操作文档维护在 API 仓库中。建议从 `doc/文档索引.md` 开始阅读；防护应用创建、发布、网关验证、日志和回滚流程见 `doc/使用说明.md`。

## 运行范围

- OpenResty + LuaJIT 反向代理。
- 默认从 `/etc/litewaf/active.json` 加载本地发布配置。
- 支持 IP/访问控制、CC 防护、托管攻击防护、上传防护、Bot 验证、动态防护、动态封禁和基于评分的处置。
- 输出结构化 JSON 日志，尽力写入 LiteWaf API，并提供基础 Prometheus 指标。
- 请求热路径不访问远程数据库。

## 构建

```bash
docker build -t litewaf-gateway .
```

默认运行镜像为 `openresty/openresty:1.27.1.2-0-bookworm-fat`，可以通过 build arg 覆盖。

## 运行

```bash
docker run --rm -p 18081:8080 litewaf-gateway
```

健康检查：

```bash
curl http://localhost:18081/healthz
```

## 配置边界

仓库包含 `conf/active.json` 作为空启动配置，并包含 `conf/*-smoke-active.json` smoke 测试配置。网关只执行当前已发布的活动配置文件；在控制面创建或修改防护应用、规则、策略、IP 名单或防护模块后，必须由 API 发布新版本并写入新的活动配置，本网关运行时才会生效。

直接客户端部署时保持 `LITEWAF_REAL_IP_TRUSTED_CIDRS` 为空。位于可信负载均衡、CDN、宿主机反代或 Docker bridge 代理路径后方时，只填写直接连接网关的可信代理 CIDR。

## Smoke 验证

先构建镜像，再在有 Docker 的 Windows 主机运行脚本：

```powershell
docker build -t litewaf-gateway .
pwsh ./scripts/smoke.ps1 -Image litewaf-gateway
```

其他 smoke 脚本覆盖访问控制、攻击防护、Bot 防护、CC 高级计数、动态防护、迁移兼容、上传防护和真实客户端 IP 恢复。

## 仓库状态

本仓库包含 LiteWaf OpenResty 网关源码和验证资产。API、Dashboard、部署文档和 OpenSpec 变更分别维护在配套仓库或工作区中。

## 许可证

本仓库采用 [Apache License 2.0](LICENSE)。你可以按该许可证使用、复制、修改、分发和商业使用本项目。
