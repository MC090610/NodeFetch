<h1 align="center">NodeFetch</h1>

<p align="center">多节点异步下载中继系统 —— 用海外 VPS 解决跨洋下载慢的问题</p>

<p align="center">
  <img alt="Python" src="https://img.shields.io/badge/Python-3.12+-3776AB?logo=python&logoColor=white">
  <img alt="FastAPI" src="https://img.shields.io/badge/FastAPI-0.115-009688?logo=fastapi&logoColor=white">
  <img alt="aria2" src="https://img.shields.io/badge/aria2-RPC-128A0C?logo=aria2&logoColor=white">
  <img alt="Docker" src="https://img.shields.io/badge/Docker-✓-2496ED?logo=docker&logoColor=white">
  <img alt="Tests" src="https://img.shields.io/badge/tests-40%20passed-brightgreen">
</p>

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#api-文档">API 文档</a> ·
  <a href="#docker-部署">Docker 部署</a> ·
  <a href="#架构">架构</a> ·
  <a href="#路线图">路线图</a>
</p>

---

## 它解决什么问题

国内用户从 GitHub Release、海外 ROM 站、开源数据集等地址下载大文件时，跨太平洋链路丢包 + 带宽不足，速度往往只有几十 KB/s 甚至超时。

**解法**：在海外 VPS 上部署 Node Agent，用 aria2 在当地高速下载（VPS 带宽通常能跑满），用户再从 VPS 取走文件。VPS → 国内 的速度通常远好于 源站 → 国内。

```
用户粘贴海外 URL → Node Agent 在 VPS 上用 aria2 下载 → 文件临时缓存（TTL 60 分钟）→ 用户取走 → 自动清理
```

## 它不是什么

| 类型 | 说明 |
|---|---|
| HTTP/SOCKS 代理 | 不做逐包代理，文件是整体下载后重传 |
| 网盘 | 只有 TTL 临时缓存，不永久存储 |
| P2P/BT 工具 | 中心化部署的 VPS，不是端对端 |
| CDN | 不做边缘分发，只有单节点下载后单链接分发 |

---

## 功能特性

- **SSRF 防护**：协议白名单（仅 http/https）、私网 IP 拦截（IPv4/IPv6）、DNS Rebinding 检测、文件大小上限
- **任务状态机**：queued → downloading → completed / failed / expired / cancelled
- **并发控制**：可配置并发下载槽位（默认 2）
- **存储治理**：TTL 过期自动清理 + 磁盘配额（超限时最老文件优先回收）
- **一次性直链**：带 token 的下载链接，`secrets.compare_digest` 防时序攻击，路径穿越防护
- **健康检查**：aria2 在线状态 / 队列统计 / 存储使用率 / 综合状态（ok / degraded / down）

---

## 快速开始

### 前置条件

- Python 3.12+
- aria2 ≥ 1.36
- Linux / macOS / Windows（容器部署推荐 Linux）

### 方式一：Linux TUI 安装向导（推荐）

```bash
git clone https://github.com/MC090610/NodeFetch.git
cd NodeFetch
chmod +x scripts/install.sh
./scripts/install.sh          # 进入交互式菜单，6 步搞定
```

向导会自动：检测发行版 → 装系统包 → 建 venv → 装 pip 依赖 → 交互式生成 `.env` → 启动 aria2 + Node Agent → 健康检查验证。

### 方式二：手动启动

```bash
git clone https://github.com/MC090610/NodeFetch.git
cd NodeFetch

# 1. Python 依赖
python -m venv .venv
source .venv/bin/activate    # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# 2. 配置
cp .env.example .env
# 编辑 .env：至少改 ARIA2_RPC_SECRET

# 3. 启动 aria2（必须先起来）
aria2c --enable-rpc --rpc-listen-all \
       --rpc-secret='your_secret_here' \
       --rpc-listen-port=6800 \
       --dir=./data/downloads \
       --max-concurrent-downloads=2 \
       --continue=true --file-allocation=none

# 4. 启动 API
uvicorn main:app --reload
```

打开 `http://localhost:8000/docs` 查看 Swagger，或访问 `http://localhost:8000/api/node/health`。

### 方式三：Docker 部署

```bash
cp .env.example .env
# 编辑 .env：改 ARIA2_RPC_SECRET / NODE_ID

docker compose up -d --build
docker compose logs -f node-agent
```

端口映射：Node API `:8000`，Aria2 RPC `:6800`（不建议对外暴露）。

---

## API 文档

### 创建下载任务

```bash
curl -sS -X POST http://127.0.0.1:8000/api/tasks \
  -H 'Content-Type: application/json' \
  -d '{"source_url":"https://example.com/file.zip","filename":"file.zip"}'
```

返回（HTTP 201）：

```json
{"id":"a1b2c3d4","status":"queued","downloaded_size":0,"speed":0,...}
```

安全错误码：

| HTTP | code | 说明 |
|---|---|---|
| 400 | `INVALID_PROTOCOL` | 非 http/https |
| 403 | `PRIVATE_IP_BLOCKED` | 域名解析到私网/回环 IP |
| 413 | `FILE_TOO_LARGE` | 超过 `MAX_FILE_SIZE_GB` |

### 查询任务

```bash
curl http://127.0.0.1:8000/api/tasks/{task_id}
```

`status=completed` 时返回 `download_url`（一次性直链，TTL 内有效）。

### 列出任务

```bash
curl 'http://127.0.0.1:8000/api/tasks?status=downloading&limit=10'
```

### 取消任务

```bash
curl -X DELETE http://127.0.0.1:8000/api/tasks/{task_id}
```

### 健康检查

```bash
curl http://127.0.0.1:8000/api/node/health
```

```json
{
  "status":"ok",
  "aria2_online":true,
  "queue":{"queued":0,"downloading":0,"completed":1,"failed":0,"total":1},
  "storage":{"used_bytes":314572800,"limit_bytes":10737418240,"used_ratio":0.03}
}
```

### 下载文件

```
GET /downloads/{task_id}/{filename}?token=xxx
```

校验：任务 completed + token 精确匹配 + 未过期 + 路径不穿越。通过后流式返回文件。

---

## 配置

所有配置通过环境变量或 `.env` 文件加载（见 `.env.example`）：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `NODE_ID` | `dev-local-01` | 节点唯一标识 |
| `DB_URL` | `sqlite+aiosqlite:///./tasks.db` | 数据库连接（可换 PostgreSQL） |
| `ARIA2_RPC_URL` | `http://127.0.0.1:6800/rpc` | aria2 RPC 地址 |
| `ARIA2_RPC_SECRET` | — | aria2 RPC 密钥（**必须设置**） |
| `DOWNLOAD_DIR` | `./data/downloads` | 下载目录 |
| `STORAGE_LIMIT_GB` | `40` | 磁盘配额（GB） |
| `MAX_FILE_SIZE_GB` | `10` | 单文件大小上限（GB） |
| `CONCURRENT_LIMIT` | `2` | 并发下载槽位 |
| `TTL_MINUTES` | `60` | 文件存活时间（分钟） |
| `API_HOST` | `127.0.0.1` | API 监听地址 |
| `API_PORT` | `8000` | API 端口 |
| `CENTER_URL` | — | 中心调度服务地址（可选，留空则独立运行） |
| `NODE_TOKEN` | — | 向中心注册的 Bearer Token（可选） |

---

## 架构

```
┌─────────────────────────────────────────────────┐
│  Node Agent (FastAPI)                           │
│                                                 │
│  ┌──────────────┐  ┌──────────────┐             │
│  │ SecurityAgent│  │ TaskManager  │             │
│  │ URL 校验/SSRF│  │ 并发槽/状态机│             │
│  └──────────────┘  └──────┬───────┘             │
│                           │                     │
│                    ┌──────┴───────┐             │
│                    │DownloadWorker│             │
│                    │ aria2 RPC    │             │
│                    └──────────────┘             │
│                                                 │
│  ┌──────────────┐  ┌──────────────┐            │
│  │ StorageAgent │  │  FastAPI     │            │
│  │ TTL/配额清理  │  │  REST API    │            │
│  └──────────────┘  └──────────────┘            │
└─────────────────────────────────────────────────┘
```

**技术栈**：Python 3.12 · FastAPI · uvicorn · SQLAlchemy (aiosqlite) · Pydantic Settings · aria2 (RPC) · Docker

---

## 运行测试

```bash
python -m pytest tests/ -v
```

当前 40 条测试（SecurityAgent 34 + TaskLifecycle 4 + Storage 2），TDD 全部通过。测试不需要 aria2 或真实网络，可离线跑。

---

## 运维脚本

| 脚本 | 用途 |
|---|---|
| `scripts/install.sh` | Linux TUI 安装向导 + 运维菜单（start/stop/restart/status/logs/tools/uninstall） |
| `scripts/manage.sh` | 轻量命令式运维脚本（适合 CI / 自动化） |

```bash
# 运维快捷操作
./scripts/install.sh start      # 启动 aria2 + node
./scripts/install.sh status     # 查状态
./scripts/install.sh logs node -f  # 看日志
./scripts/install.sh restart    # 重启
```

---

## 路线图

- [x] Node Agent MVP（SSRF 防护 / 任务状态机 / 存储治理 / 一次性直链）
- [ ] Center Agent（节点注册发现 / 任务路由 / 状态聚合）
- [ ] GUI Client（图形界面）
- [ ] TUI Client（终端界面）
- [ ] GitHub Registry（公开节点注册表）

---

## 已知限制

- MVP 无账号系统
- SQLite 单机存储（可换 PostgreSQL，改 `DB_URL` 即可）
- 下载直链由 FastAPI `FileResponse` 处理（大文件生产建议加 Nginx `X-Accel-Redirect`）
- Center Agent 尚未实现，当前单节点独立运行
