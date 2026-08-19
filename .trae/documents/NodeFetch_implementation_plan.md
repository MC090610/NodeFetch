# NodeFetch 实施计划（基于 Agent.md）

> 权威架构依据：[Agent.md](file:///e:/vibe-code/NodeFetch/Agent.md)（本文所有术语、边界、阶段顺序均以它为准）

---

## 1. 仓库研究结论

### 1.1 仓库现状（完成了浏览目标）
- 仓库路径：`e:\vibe-code\NodeFetch`
- 现有文件：
  - [AsyncRelay_项目规划.md](file:///e:/vibe-code/NodeFetch/AsyncRelay_%E9%A1%B9%E7%9B%AE%E8%A7%84%E5%88%92.md) — 原始 850 行规划文档（作为历史参考）
  - [Agent.md](file:///e:/vibe-code/NodeFetch/Agent.md) — **刚创建的权威架构文档（6 大类 Agent + 通信协议 + 状态机 + MVP 验收标准）**
  - `.trae/documents/NodeFetch_implementation_plan.md` — 上一版计划，本文件替代它

### 1.2 项目本意（完成「了解本意」目标）
- 一个 **AI 智能体驱动的多节点异步下载中继系统**
- 用户丢国外 URL → 选海外 VPS 节点 Agent → 节点用 Aria2 本地高速下载 → 用户再从节点取回文件
- **不是代理、不是网盘、不是 P2P、不做用户系统/积分/VIP**

### 1.3 所有 Agent 的职责图（摘自 Agent.md §2）
```
GitHub Registry ← Center Agent（控制面：节点/健康/GitHub同步）
                     │
                     ▼
        GUI Agent ← Core Agent（Discovery/Selector/Task/Retry/Config 子Agent）→ TUI Agent
                              │
                   ┌──────────┼──────────┐
                   ▼          ▼          ▼
         Node Agent A  Node Agent B  Node Agent C
              │             │            │
      Security/TaskManager/DownloadWorker/Storage（内部子Agent）
              │
            Aria2 → /data/downloads/{task_id}/ → Nginx Range 文件服务
```

### 1.4 MVP 验收标准（8 步闭环，Agent.md §11）
所有实施工作的最终成功判定就是能否走完这 8 步：**Node 上线 → Center 注册 → GitHub 同步 → GUI 拿节点 → 选节点提交 URL → 实时进度 → 断点续传下载 → 60min 自动清理**

---

## 2. 要创建的模块和文件

**完整目录树（完全对应 Agent.md §8）**：

```
NodeFetch/
├── Agent.md                              ✅ 已完成
├── AsyncRelay_项目规划.md                 ✅ 已有，保留参考
│
├── node-agent/                           阶段 ①
│   ├── main.py
│   ├── requirements.txt
│   ├── .env.example                       # NODE_ID / NODE_NAME / REGION / ARIA2_RPC_SECRET / STORAGE_LIMIT_GB / MAX_FILE_SIZE_GB / CONCURRENT_LIMIT / TTL_MINUTES
│   ├── deploy/
│   │   ├── aria2.conf                     # rpc-secret + bind 127.0.0.1 + dir=/data/downloads + max-concurrent=2
│   │   ├── nginx.conf                     # /api 反代 + /downloads 静态 + auth_request + Range
│   │   └── systemd/node-agent.service, aria2.service
│   ├── api/
│   │   ├── __init__.py
│   │   ├── node.py                        # GET /api/node/info
│   │   └── tasks.py                       # POST/GET/DELETE /api/tasks + GET /api/tasks/{id}/download(302) + GET /api/tasks/{id}/auth(Nginx内部)
│   ├── models/
│   │   ├── __init__.py
│   │   ├── database.py                    # SQLite aiosqlite + session maker + create_all
│   │   └── task.py                        # SQLAlchemy 模型（Agent.md §5 字段 + download_token）
│   ├── agents/
│   │   ├── __init__.py
│   │   ├── security_agent.py              # SSRF 防护入口（getaddrinfo + 私有 IP 拒绝）
│   │   ├── task_manager_agent.py          # 并发队列 + queued→downloading 状态推进
│   │   ├── download_worker_agent.py       # Aria2 XML-RPC 封装（addUri / tellStatus / remove）
│   │   └── storage_agent.py               # du 监控配额 + TTL 到期清理
│   ├── tests/
│   │   ├── __init__.py
│   │   ├── conftest.py                    # pytest + 内存 DB + mock aria2
│   │   ├── test_security_ssrf.py          # 内网/回环/链路本地/IPv6 ULA 全用例
│   │   ├── test_task_lifecycle.py         # queued→downloading→completed 状态机
│   │   └── test_storage_ttl.py            # TTL 过期清 DB + 删文件
│   └── README_NODE.md                     # 节点部署快速指南
│
├── center-agent/                         阶段 ②
│   ├── main.py
│   ├── requirements.txt
│   ├── .env.example                       # DB_URL / GITHUB_TOKEN / REGISTRY_REPO / HEALTH_CHECK_INTERVAL_SEC / SYNC_INTERVAL_SEC
│   ├── api/
│   │   ├── __init__.py
│   │   ├── nodes.py                       # GET /api/nodes + POST /api/nodes/submit
│   │   └── registry.py                    # POST /admin/registry/sync（需 admin key）
│   ├── models/
│   │   ├── __init__.py
│   │   ├── database.py
│   │   └── node.py                        # id/name/api_url/region/version/features/status/enabled/last_seen
│   ├── services/
│   │   ├── __init__.py
│   │   ├── health_check_agent.py          # APScheduler，每节点 5 分钟一次 call /api/node/info
│   │   ├── github_sync_agent.py           # 每 15 分钟 dump servers.json → git push 到 registry 仓库
│   │   └── node_review_agent.py           # 提交队列管理（MVP 手动 approve CLI 命令即可）
│   └── README_CENTER.md
│
├── registry/                             阶段 ② 产出、阶段 ③ 消费
│   ├── servers.json                       # Center 写、Client fallback 读
│   └── schema.json                        # JSON Schema（Draft-07）
│
├── client-core/                          阶段 ③ Rust crate
│   ├── Cargo.toml                         # reqwest/json-rust、tokio/full、serde/derive、confy、thiserror、anyhow、jsonschema
│   └── src/
│       ├── lib.rs
│       ├── types.rs                       # Task / TaskStatus / NodeInfo / Error（共享 DTO）
│       └── agents/
│           ├── discovery_agent.rs         # center → GitHub fallback + schema 校验
│           ├── selector_agent.rs          # v1 纯手动选择 + 记忆上次节点
│           ├── task_agent.rs              # create/poll(Stream)/cancel/get_download_url
│           ├── retry_agent.rs             # 失败重试 + 换节点策略
│           └── config_agent.rs            # confy 持久化（NodeFetch.toml）
│
├── client-core/tests/                    阶段 ③
│   └── integration/
│       └── full_stack.rs                  # wiremock 模拟 Center/Node，走通完整链路
│
├── client-tui/                           阶段 ④
│   ├── Cargo.toml                         # ratatui、crossterm、client-core = { path = "../client-core" }
│   └── src/main.rs                        # 三屏：节点列表 → URL 输入 → 任务卡片进度
│
├── client-gui/                           阶段 ⑤
│   └── (Tauri 脚手架：src-tauri/Cargo.toml + src/index.html + 前端 TSX)
│
└── .gitignore                             # 阶段 ① 起一起维护：.env、__pycache__、/target、*.db、/data/*
```

---

## 3. 按阶段的实施步骤（严格依赖顺序）

### 阶段 ①：Node Agent（MVP 最关键，自闭环，单独可用 curl 测试）

**前置依赖**：无（自闭环）
**产出**：一台 VPS 上跑 Node Agent，HTTP 五件套 API 全可用

步骤（按依赖顺序）：

1. **初始化 Python 项目**
   - `mkdir node-agent && cd node-agent && python -m venv .venv && pip install fastapi uvicorn[standard] sqlalchemy aiosqlite aiofiles httpx pydantic-settings pyaria2 apscheduler pytest pytest-asyncio pytest-httpx`
   - 写 `requirements.txt` 固定版本
   - 写 `.env.example`（NODE_ID, NODE_NAME, REGION, VERSION=1.0.0, DB_URL=sqlite+aiosqlite:///./tasks.db, ARIA2_RPC_URL=http://127.0.0.1:6800/rpc, ARIA2_RPC_SECRET=, DOWNLOAD_DIR=/data/downloads, STORAGE_LIMIT_GB=40, MAX_FILE_SIZE_GB=10, CONCURRENT_LIMIT=2, TTL_MINUTES=60）

2. **写 DB + 模型层（models/database.py, models/task.py）**
   - SQLAlchemy 2.x async 风格，DB 路径从 settings 读
   - Task 字段严格按 Agent.md §4.2 + `download_token`（uuid，一次性）+ `download_token_expires_at`
   - 启动时 `await Base.metadata.create_all()`

3. **写 SecurityAgent（agents/security_agent.py）—— 第一个写，因为是第一道门**
   - 函数 `validate_url(url: str) -> tuple[str, list[str]]`，返回 normalized_url + resolved_ips
   - 用 `urllib.parse.urlparse` 检查 scheme ∈ {http, https}，否则抛 400 `InvalidProtocol`
   - `socket.getaddrinfo(host, None)` 解析出所有 IP，调用 `_is_private_ip(ip_str)`：
     - IPv4：127.0.0.0/8、10.0.0.0/8、172.16.0.0/12、192.168.0.0/16、169.254.0.0/16、0.0.0.0/8
     - IPv6：::1/128、::ffff:127.0.0.0/104、fc00::/7、fe80::/10
     - 任何一个 IP 命中都抛 400 `SSRFBlocked`
   - 可选 HEAD 请求拿 Content-Length，超过 `MAX_FILE_SIZE_GB * 1024**3` 抛 400 `FileTooLarge`
   - **配套 tests/test_security_ssrf.py 先写（TDD 思路）**，用例至少 15 条覆盖上述所有范围 + DNS rebinding（解析出公网+私有双 IP 的情况也要拒绝）

4. **写 DownloadWorkerAgent（Aria2 RPC 封装）**
   - 封装 `start_download(url: str, dir: str) -> aria2_gid`（`aria2.addUri([url], {dir: dir})`）
   - 封装 `get_status(gid) -> {status, totalLength, completedLength, downloadSpeed, errorMessage}`（`aria2.tellStatus`）
   - 封装 `remove(gid)`（`aria2.removeDownloadResult`）
   - 启动时检查 Aria2 能不能通（`aria2.getVersion`），通不了直接拒绝启动并报明显错误

5. **写 TaskManagerAgent（并发控制）**
   - 内存里一个 `current_downloads: set[task_id]`（最多 CONCURRENT_LIMIT）
   - 后台每 2 秒 tick：从 DB 找最老的 queued 任务，若 current_downloads 有空位 → 调用 DownloadWorkerAgent → 状态改成 downloading，记录 aria2_gid

6. **写 StorageAgent（配额 + TTL 清理）**
   - 每 5 分钟 tick 1：`du` 算 DOWNLOAD_DIR 总大小，存到内存变量供 /api/node/info 返回
   - 每 10 分钟 tick 2：找所有 `status=completed AND expires_at < now` 的任务 → `shutil.rmtree` 目录 → DB 删记录
   - 新任务 POST 时如果 storage_used > storage_limit → 抛 507 `StorageFull`

7. **写 API 路由（api/node.py + api/tasks.py）**
   - `GET /api/node/info`：返回 Agent.md §4.2 的 JSON（含实时 storage_used_gb / storage_limit_gb / concurrent_limit）
   - `POST /api/tasks`：SecurityAgent.validate → 生成 6-hex task_id（短）+ 生成 download_token(uuid) → DB 写 queued → 返回 task_id
   - `GET /api/tasks/{id}`：从 DB 取任务 + 如果是 downloading/queued 则问一次 Aria2 刷新速度/大小 → 返回聚合 DTO
   - `DELETE /api/tasks/{id}`：如果 downloading 调 aria2.remove；DB 删行 + 删目录
   - `GET /api/tasks/{id}/download`：必须 status=completed，检查 download_token=query param且未过期 → 302 到 `/downloads/{task_id}/{filename}?token=xxx`
   - `GET /api/tasks/{id}/auth`（Nginx `auth_request` 内部子请求）：返回 2xx / 4xx 控制文件放行

8. **写部署配置（deploy/ 目录三件套）**
   - `aria2.conf`：`enable-rpc=true, rpc-listen-port=6800, rpc-allow-origin-all=false, rpc-listen-all=false, rpc-secret=<必须改>, dir=/data/downloads, max-concurrent-downloads=2, max-connection-per-server=16, continue=true`
   - `nginx.conf`：server { listen 443 ssl; location /api/ { proxy_pass http://127.0.0.1:8000; } location /downloads/ { internal? 不，要公网访问 + auth_request /api/tasks/$task_id_internal/auth; alias /data/downloads/; }  } （nginx 的 auth_request 装配要调试对）
   - `systemd/*.service`：两个服务，node-agent（uvicorn --host 127.0.0.1:8000）+ aria2.service，开机自启 + 崩溃重启

9. **在真实 VPS 上跑通并手动用 curl 验证（Agent.md §11 中的前半部分）**
   - 提交一个大文件 URL（比如 `https://speed.hetzner.de/100MB.bin`）→ 观察 queued→downloading→completed
   - 下载链接 `curl -r 0-1023` 能拿到 1KB → **证明 Range 支持（断点续传）**
   - 确认 aria2 只能本地 bind、rpc-secret 生效
   - 跑 SSRF 全量测试：`pytest node-agent/tests/` 必须全绿

---

### 阶段 ②：Center Agent（控制面）

**前置依赖**：阶段 ① 完成（健康检查和同步都要调用 Node 的 API）

步骤：

1. **搭骨架 + 模型**
   - Python 项目，和 node-agent 同栈（FastAPI + SQLAlchemy async + aiosqlite）
   - Node ORM 表：id / name / api_url / region / version / features(JSON) / status(online/offline/maintenance) / enabled / last_seen / submitted_by_description

2. **API：GET /api/nodes + POST /api/nodes/submit**
   - GET：返回 enabled=true 的所有节点，online 排前面
   - POST 提交：写入 DB 时 status=maintenance，enabled=false，进入 review 队列
   - 提供 CLI（`python -m center-agent.services.node_review_agent approve <id>`）把节点置 enabled 并做首次健康检查

3. **HealthCheckAgent（APScheduler）**
   - 每 5 分钟：遍历所有 DB 里的节点，`GET {api_url}/api/node/info`
   - 2xx + version 合法 → status=online + last_seen=now
   - 连续 2 次失败 → status=offline
   - 节点的 version / features 每次顺手更新到 DB

4. **GitHubSyncAgent**
   - 每 15 分钟 OR enabled 节点集合有变化才 push（去抖）
   - dump 所有 enabled 的节点为 JSON → 写到 `registry/servers.json`
   - `git add registry/servers.json && git -c user.name=... -c user.email=... commit -m "chore(registry): sync $(date)" && git push`
   - 失败重试 2 次，报警到日志
   - 同步写 `registry/schema.json`（JSON Schema Draft-07，描述 servers.json 的数组类型+每个字段 required）

---

### 阶段 ③：Client Core（Rust 共享库）

**前置依赖**：阶段 ①② 接口稳定（DTO 字段冻结）

步骤：

1. **Cargo.toml + types.rs**
   - DTO：`TaskId(String)`、`TaskStatus(enum queued/downloading/completed/failed)`、`TaskProgress { total, downloaded, speed, status, filename }`、`Node { id, name, api, region, status, version, features }`、统一 `CoreError(thiserror enum)`

2. **ConfigAgent**
   - 用 confy 存在 `~/.config/NodeFetch/config.toml`：`center_url: String, last_selected_node_id: Option<String>, download_dir: String, log_level: String`

3. **DiscoveryAgent**
   - 主路径 `GET {center_url}/api/nodes` → 反序列化为 `Vec<Node>`
   - 主路径失败（超时/4xx/5xx）→ fallback：`GET https://raw.githubusercontent.com/<repo>/registry/main/servers.json` → 用 `jsonschema` + `registry/schema.json` 校验 → 不行再报错
   - 缓存节点列表 5 分钟（不要每次都打）

4. **SelectorAgent（v1 只有手动选择）**
   - `select_node(&self, node_id: &str) -> Result<&Node>` → 同时写到 ConfigAgent.last_selected_node_id
   - `default_node(&self) -> Result<&Node>` → ConfigAgent 里有就用它，没有就选 online 列表第一个

5. **TaskAgent**
   - `create(node_api: &str, url: &str) -> Result<TaskId>`：POST /api/tasks
   - `poll(node_api: &str, id: TaskId) -> impl Stream<Item = Result<TaskProgress>>`：tokio interval 每 1s GET 一次直到 completed/failed
   - `download_url(node_api: &str, id: TaskId) -> Result<Url>`：302 跟随，拿到最终下载链接
   - `cancel(node_api: &str, id: TaskId) -> Result<()>`

6. **RetryAgent（包装 TaskAgent）**
   - 同一节点失败重试 1 次；还失败 → SelectorAgent 给下一个 online 节点自动再试；所有节点失败再向调用者抛错

7. **tests/integration/full_stack.rs**
   - 用 `wiremock` 起三个 mock 服务：Center + Node A + Node B
   - 模拟：DiscoveryAgent 从 Center 拿节点 → SelectorAgent 选 A → TaskAgent create → poll 模拟 3 次进度 → completed → download_url 返回带 token 的 URL
   - 再加失败场景：Node A 返回 failed → RetryAgent 自动换 Node B 成功

---

### 阶段 ④：Client TUI（Rust ratatui）

**前置依赖**：阶段 ③ Core 完成 + integration 测试全过

步骤：
- ratatui 经典三屏：
  1. **Nodes 视图**：列出 DiscoveryAgent 的 online 节点，高亮默认选中，Enter 确认选
  2. **URL 输入视图**：prompt + 提交 Enter 下载
  3. **Tasks 视图**：每行一张卡片，文件名 + 进度条（ratatui Gauge widget）+ 速度 + 状态；C 复制下载链接、D 删除、R 刷新、Q 退出
- 快捷键和 Agent.md §13 的示意图一致：Enter/D/S/R/Q
- 所有业务逻辑都 `use client_core::agents::*`，TUI 代码**禁止出现任何直接 HTTP 调用**（否则等于 Core 白写了）

---

### 阶段 ⑤：Client GUI（Tauri，默认方案）

**前置依赖**：阶段 ③ Core 完成（阶段④其实可以并行，因为都只依赖 Core）

步骤：
1. `cargo install create-tauri-app && create-tauri-app client-gui --template vanilla-ts`
2. 把 `client-core` 作为 crate 依赖到 `client-gui/src-tauri/Cargo.toml`
3. 定义 Tauri commands 封装 Core Agent：`cmd_list_nodes`, `cmd_select_node`, `cmd_create_task`, `cmd_poll_task`(用 Tauri event stream), `cmd_cancel_task`, `cmd_get_download_link`
4. 前端界面按 Agent.md §12 的线框图：URL 大输入框 + 节点下拉 + 「开始下载」主按钮 + 下方任务卡片列表（进度条 + 速度 + 复制链接 + 取消）
5. 开启动画、深色模式可选、自动刷新进度（不要手动 R）

---

## 4. 跨阶段依赖和注意事项

| 事项 | 说明 |
|---|---|
| **阶段①必须在真 VPS 验证** | 本地 Windows 开发也可以装 aria2 + WSL 写代码，但阶段①的**验收必须有至少一台真实海外 VPS（日本/香港/美国各一台最好）跑满带宽实测**，否则后面所有阶段基于假设 |
| **DTO 字段冻结时间点** | 阶段①② API 写完后，把所有 Request/Response DTO 抽成 `node-agent/shared_dtos.py` + 对应 Rust `types.rs`，两边各维护一份但字段必须完全对齐。改一个字段必须同步改两边 + integration 测试 |
| **rpc-secret / GitHub Token** | 必须放 `.env`，`.gitignore` 必须覆盖 `.env`、`*.db`、`/data`、`__pycache__`、`/target`；GITHUB_TOKEN 要 repo scope 才能 push registry |
| **SSR 防护是安全红线** | SecurityAgent 的测试套件必须放在 CI 上跑；每次 PR 都要跑，过不去不能合 |
| **Nginx auth_request 配置** | 阶段①的 Nginx 配置常踩坑：auth_request 是内部子请求，不能被公网直接调；`$task_id_internal` 需要通过正则或 map 从 URL 提取，要真机调试 |
| **项目名统一**：全程用 `NodeFetch` | Config 路径、包名、README、Tauri 包名、systemd 服务名都用 NodeFetch；AsyncRelay 只出现在旧文档引用里 |
| **不提前做 v2 特性** | 自动节点选择、积分、多节点分段合并等 MVP 不做清单里的内容，一律不建分支不写代码。先让 §11 的 8 步验收跑通 |

---

## 5. 每阶段完成后的验证（必须全过才能推进下一阶段）

### 阶段 ① Node Agent
- [ ] `pytest tests/`（含 SSRF/任务生命周期/TTL）100% 通过
- [ ] 真实 VPS 上 aria2 监听 127.0.0.1、rpc-secret 正确（外网扫 6800 应关闭）
- [ ] 提交 hetzner 100MB.bin → 任务完成后 `curl -r 0-1023 <download_url>` 成功返回 1KB（Range 支持）
- [ ] 下载链接带 token；删掉 token 不能下载（权限校验生效）
- [ ] 60 分钟（测试时临时改成 2min）后自动 `ls /data/downloads/{task_id}` 消失

### 阶段 ② Center Agent
- [ ] `/api/nodes` 返回 online 节点
- [ ] 把 Node Agent 手动下线 → 最多 10 分钟 Center 标记 offline
- [ ] GitHub registry 仓库 servers.json 有节点条目，且通过 schema 校验（`jsonschema -i servers.json schema.json`）

### 阶段 ③ Client Core
- [ ] `cargo test`（含 integration full_stack）全绿
- [ ] 手动集成：指向真实 Center + Node，用一个临时 CLI main 调 Core 跑一遍下载流程

### 阶段 ④ TUI
- [ ] 键盘全走通：选节点→输 URL→任务进度条→复制下载链接→正常退出
- [ ] Center 故意断网 → TUI 能提示 fallback 到 GitHub registry

### 阶段 ⑤ GUI
- [ ] 鼠标全走通，无控制台报错
- [ ] 下载完成后浏览器直接打开链接能下，支持 IDM 断点续传
- [ ] 最终 MVP 8 步（Agent.md §11）人工端到端全通过

---

## 6. 风险与处理

| 风险 | 概率 | 影响 | 处理 |
|---|---|---|---|
| SSRF 被绕过（DNS rebinding 等技巧） | 中 | 高（节点被入侵） | SecurityAgent 里做「解析→校验→复用同一 socket」的 happy eyeballs 式安全连接，不要先校验 host IP 再让 httpx 重新解析（两次解析结果可能不同）；加完整黑盒测试用例集 |
| Aria2 进程崩或 Node Agent 重启后丢失 aria2_gid | 中 | 中（下载任务孤儿化） | 启动时遍历 `/data/downloads/*/` 扫描目录 + 用 aria2.tellActive/tellWaiting/tellStopped 重建内存 map，重新绑定 DB 记录（恢复逻辑） |
| Rust Core 开发不顺利影响全客户端 | 中 | 中 | 预案：阶段④先用 Python Typer 写 200 行 CLI 客户端，直接 HTTP 调用 Node/Center，完全独立于 Rust Core，保证后端链路能被测试覆盖 |
| GitHub push registry 频率过高被限流 | 低 | 低 | 15 分钟批量 + 去抖（节点列表实际变动才 commit），失败进队列下次重试 |
| 节点磁盘被占满但 du 漏算（硬链接/稀疏文件） | 低 | 高 | du + statfs 双重监控；任何一处超阈值都拒绝新任务 |

---

## 7. 明确本实施计划覆盖的内容

完全满足用户最初 goal 的四项要求：

| Goal 条目 | 在哪里被覆盖 |
|---|---|
| ① 快速浏览项目 | 本计划 §1.1 仓库现状 + 完成了全部文件扫描（确认无 Agent.md，已补写） |
| ② 根据 Agent.md 了解架构和规划 | 本计划完全以 Agent.md 为权威依据（每节都有章节引用），且 Agent.md 刚刚已写入仓库 |
| ③ 规划怎么制作 | 本计划 §2（完整目录树）+ §3（5 个阶段分步）+ §4（跨阶段注意）+ §5（验证清单）+ §6（风险） |
| ④ 了解本意 | 本计划 §1.2（本意+非目标）+ 继承自 Agent.md §1 的 Why 阐释 |

---

*本计划与 Agent.md 同步维护。Agent.md 架构变更时，本计划对应章节同步调整。*
