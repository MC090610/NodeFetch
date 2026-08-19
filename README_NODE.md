# Node Agent（NodeFetch）— MVP 部署与使用手册

本目录是 NodeFetch 系统的 **Node Agent** 实现（对应仓库 `Agent.md §3 ~ §4`）。
它是一个 FastAPI + Aria2 + SQLAlchemy 异步进程，职责：

1. 接收 `POST /api/tasks` 提交的大文件下载请求
2. 用 SecurityAgent 拦截协议不合法 / 私网 IP / DNS Rebinding / 超限文件
3. 交给 Aria2 下载，控制并发槽位（默认 CONCURRENT_LIMIT=2）
4. 通过 StorageAgent 做 TTL 过期清理 + 磁盘配额治理
5. 对外提供一次性带 token 下载直链（`/downloads/{task_id}/{filename}?token=...`），可直接由 Nginx `auth_request` 代理

> 整体架构 / 完整规划 见仓库根 `Agent.md`；本 README 只关心 **Node 端怎么跑 / 怎么调 / 怎么部署**。

---

## 1. 目录结构

```
.
├── main.py                 # FastAPI 入口（lifespan + route 装配）
├── config.py               # pydantic-settings（从 .env 或环境变量读）
├── requirements.txt
├── Dockerfile.node         # Node 容器镜像
├── docker-compose.yml      # Node + Aria2 一键部署
├── .env.example            # 环境变量模板
├── agents/                 # 内部子 Agent（Security / TaskManager / DownloadWorker / Storage）
│   ├── security_agent.py
│   ├── task_manager_agent.py
│   ├── download_worker_agent.py
│   └── storage_agent.py
├── api/                    # FastAPI 路由 + Pydantic DTO
│   ├── schemas.py
│   ├── node.py             # /api/node/*
│   └── tasks.py            # /api/tasks/* + /downloads/*
├── models/                 # SQLAlchemy ORM
│   ├── database.py         # engine / session / 建表
│   └── task.py             # Task 模型 + 状态机 helper
└── tests/                  # pytest (当前 40 个，100% 通过)
    ├── conftest.py
    ├── test_security_ssrf.py
    ├── test_task_lifecycle.py
    └── test_storage_agent.py
```

---

## 2. 本机快速启动（Bare Metal）

### 2.1 依赖

- Python 3.12+
- aria2 ≥ 1.36（**必须**，负责实际下载）

Windows 可：

```powershell
scoop install aria2
# 或 winget install aria2.aria2
```

Linux/macOS：`brew/apt install aria2`。

### 2.2 Python 依赖

```bash
cd node-agent
python -m venv .venv
# Windows: .venv\Scripts\activate
# Posix:   source .venv/bin/activate
pip install -r requirements.txt
```

### 2.3 启动 aria2（必须先起来）

```bash
aria2c --enable-rpc --rpc-listen-all \
       --rpc-secret='replace_with_a_long_random_secret_change_me' \
       --rpc-listen-port=6800 \
       --dir=./data/downloads \
       --max-concurrent-downloads=2 \
       --continue=true \
       --file-allocation=none
```

（RPC_SECRET 跟下一步 .env 的 `ARIA2_RPC_SECRET` 必须一致。）

### 2.4 配置 Node Agent

```bash
cp .env.example .env
# 编辑 .env，至少改 ARIA2_RPC_SECRET、NODE_ID、可选 CENTER_URL + NODE_TOKEN
```

### 2.5 启动 API

```bash
uvicorn main:app --reload
# 不带 reload 生产：
# uvicorn main:app --host 0.0.0.0 --port 8000 --proxy-headers
```

打开：<http://localhost:8000/docs>（Swagger）或 <http://localhost:8000/api/node/health>。

---

## 3. 容器部署（推荐生产）

```bash
cd node-agent
cp .env.example .env
# 改：ARIA2_RPC_SECRET / NODE_ID / 可选 CENTER_URL & NODE_TOKEN

docker compose up -d --build
docker compose ps
docker compose logs -f node-agent
```

服务端口：

- Node API：宿主机 `:8000`
- Aria2 RPC：宿主机 `:6800`（不建议对外暴露）
- Aria2 BT/DHT：宿主机 `:6888` + UDP（想做 BT/磁力才需要）

卷：

- `downloads` 卷 → 下载文件（两边容器共享）
- `db_data` 卷 → SQLite `tasks.db`
- `aria2_conf` 卷 → Aria2 session/配置

---

## 4. 对外 HTTP API（Agent.md §4.2）

### 4.1 创建任务 `POST /api/tasks`

```bash
curl -sS -X POST http://127.0.0.1:8000/api/tasks \
  -H 'Content-Type: application/json' \
  -d '{
    "source_url": "https://nodejs.org/dist/v20.11.1/node-v20.11.1-linux-x64.tar.xz",
    "filename": "node-v20.tar.xz"
  }' | python -m json.tool
```

成功返回（HTTP 201）：

```json
{
  "id": "a1b2c3d4",
  "source_url": "https://nodejs.org/...",
  "status": "queued",
  "downloaded_size": 0,
  "speed": 0,
  "download_url": null,
  "created_at": "2026-08-19T12:34:56Z",
  "..." : "..."
}
```

Security 错误：

| HTTP | code | 说明 |
| --- | --- | --- |
| 400 | `INVALID_PROTOCOL` | 非 http/https（file/ftp/gopher/data 等一律禁） |
| 403 | `PRIVATE_IP_BLOCKED` | 域名解析到私网/回环/链路本地 IP |
| 403 | `DNS_REBINDING_BLOCKED` | 解析结果包含公网 + 私网混合 |
| 413 | `FILE_TOO_LARGE` | HEAD 返回 Content-Length > `MAX_FILE_SIZE_GB` |
| 400 | `UNREACHABLE_HOST` | DNS 完全失败或主机不可达 |

### 4.2 查单个任务 `GET /api/tasks/{task_id}`

```bash
curl http://127.0.0.1:8000/api/tasks/a1b2c3d4
```

当 `status == completed`，返回体会包含 `download_url`，这是一次性直链（带 `?token=<32char>`，在 TTL_MINUTES 内有效）：

```json
{
  "status": "completed",
  "download_url": "http://127.0.0.1:8000/downloads/a1b2c3d4/node-v20.tar.xz?token=abCDef...",
  "expires_at": "2026-08-19T13:34:56Z",
  "...": "..."
}
```

### 4.3 列任务 `GET /api/tasks?status=completed&limit=50`

```bash
curl 'http://127.0.0.1:8000/api/tasks?status=downloading&limit=5'
```

### 4.4 取消/删除 `DELETE /api/tasks/{task_id}`

```bash
curl -X DELETE http://127.0.0.1:8000/api/tasks/a1b2c3d4
```

行为：
- `queued` → `failed`（error=`cancelled by user`）
- `downloading` → 先 cancel aria2，再写 `failed`
- `completed` → **文件立即被删**（StorageAgent purge），status 改 `expired`，保留 DB 记录

### 4.5 健康检查 `GET /api/node/health`

```json
{
  "status": "ok",
  "aria2_online": true,
  "queue": {"queued":0,"downloading":0,"completed":1,"failed":0,"total":1},
  "storage": {"used_bytes": 314572800, "limit_bytes": 10737418240, "used_ratio": 0.0293},
  "node_id": "dev-local-01",
  "version": "0.1.0-mvp"
}
```

`status == "degraded"` 的典型原因：aria2 不可达 / 存储占用 > 95%。
`status == "down"` 同时 aria2 下线且磁盘超配额。

### 4.6 一次性直链 `GET /downloads/{task_id}/{filename}?token=xxx`

SecurityAgent 校验：
1. 任务存在且 status=completed
2. `token` 精确匹配 `Task.download_token`（`secrets.compare_digest`，防时序攻击）
3. `download_token_expires_at` 未过期
4. 路径不穿越 `DOWNLOAD_DIR`（防 `../../etc/shadow`）

通过后 FastAPI 用 `FileResponse` 流式返回（大文件会走系统 sendfile）。

> 生产建议：在前面加 Nginx，使用 `X-Accel-Redirect` 绕过 Python 进程传大文件（留作后续优化项）。

---

## 5. 运行测试

```bash
cd node-agent
python -m pytest tests/ -v
```

当前套件 = 40 个（SecurityAgent 34 + TaskLifecycle 4 + Storage 2），TDD 全部通过。

测试不需要 aria2 或真实网络（SecurityAgent 的 DNS/HTTP 都被 mock、TaskManager 用 `_FakeAria2`），可离线跑。

---

## 6. 可选：注册到 Center Agent

`.env` 里填上 `CENTER_URL`（Center 对外根地址）+ `NODE_TOKEN`（管理员分配给该 Node 的 Bearer Token）。Node Agent 在 lifespan `startup` 时会 POST 一次：

```http
POST <CENTER_URL>/api/agents/node/register
Authorization: Bearer <NODE_TOKEN>
Content-Type: application/json

{
  "node_id": "...",
  "node_name": "...",
  "region": "...",
  "api_base": "http://<node_host>:<node_port>",
  "version": "1.0.0"
}
```

失败只打 warning，不影响 Node 独立运行（降级模式：中心崩了 Node 还能本地直接调用）。

---

## 7. 已知边界 / Roadmap

MVP 刻意限制了范围（对应 `Agent.md §5 MVP验收标准`）：

- [x] 只允许 HTTP/HTTPS；SSRF + DNS Rebinding 防护；文件大小上限
- [x] Aria2 做下载；严格并发上限
- [x] SQLite 单机 DB；可换成 PostgreSQL（只需改 `DB_URL=postgresql+asyncpg://...`）
- [x] TTL + 磁盘配额自动清理
- [x] 一次性带 token 下载直链
- [ ] ~~多 Node 元数据共享~~（由 Center 负责，Node 不互相通信）
- [ ] ~~GUI/TUI Client~~（见仓库其他目录）
