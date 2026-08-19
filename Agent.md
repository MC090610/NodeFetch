# Agent.md — NodeFetch / AsyncRelay 智能体架构总览

> 项目名候选：`NodeFetch`（当前仓库名）或 `AsyncRelay`（原规划文档名）。本文件统称 **NodeFetch**。
>
> 本文档从「**多智能体协作系统**」视角重新阐释原规划文档，定义各 Agent 的角色、职责边界、通信协议和执行闭环，作为后续实施计划与代码落地的**唯一权威依据**。

---

## 1. 项目本意（先理解 Why）

### 1.1 它是什么
NodeFetch 是一个 **AI 驱动的多节点异步下载中继系统**。

```
用户在客户端粘贴一个国外 URL
        ↓
系统自动（或用户手动）选择一个海外 VPS 节点 Agent
        ↓
节点 Agent 在当地用 Aria2 高速下载
        ↓
文件临时保存到节点本地（TTL 默认 60 分钟）
        ↓
用户从该节点用浏览器 / IDM / aria2 / wget 把文件取走
```

### 1.2 它明确不是什么

| 类型 | 是否做 | 原因 |
|---|---|---|
| HTTP / SOCKS 代理 | ❌ | 不提供逐包代理；文件是被「整个下载 + 重传」，不是「流式转发」 |
| 网盘 / 永久存储 | ❌ | 节点只做临时缓存，60 分钟自动清理，不保用户数据 |
| P2P / BT 工具 | ❌ | 节点是中心化部署的 VPS，不是用户端对端 |
| CDN 加速 | ❌ | 不做多节点回源 + 边缘分发，只有单节点下载后单链接分发 |
| 用户系统 / 积分 / VIP | ❌ | MVP 阶段完全没有账号体系 |

### 1.3 要解决的核心问题

国内用户访问 GitHub Release、海外 ROM、开源数据集、学术数据集、大文件分发站时，**跨太平洋链路丢包+带宽不足**导致下载速度只有几十 KB/s 甚至超时。

**解法思路**：利用海外 VPS 本地带宽在当地把文件拉下来（通常能跑满 VPS 带宽，数百 MB/s），再让用户从 VPS 取走（VPS→国内的速度通常好于源站→国内）。

### 1.4 设计的核心哲学（MVP 阶段不变）

1. **节点与客户端解耦**：客户端不绑定任何一个节点，只通过注册中心发现可用节点
2. **控制面与数据面彻底分离**：中心服务器**永远不碰大文件**，只做节点元数据管理
3. **GUI / TUI / CLI / Web 共用 Core**：业务逻辑写一次，界面只是壳
4. **MVP 极致精简**：先把「发现节点→选节点→提交 URL→异步下载→取文件」闭环跑通，再加任何其他功能
5. **一切皆 Agent**：系统中的角色（节点、中心、客户端核心、任务调度器）都是**自治 Agent**，通过**消息 / HTTP API**交互，而非共享内存或直接函数调用

---

## 2. 系统级智能体架构

```
                                 ┌──────────────────────┐
                                 │  GitHub Registry     │
                                 │  (公开 JSON 备份)     │
                                 └──────────┬───────────┘
                                            │ Registry Sync Msg
                                            ▼
                        ┌────────────────────────────────────────┐
                        │         Center Agent（中心智能体）        │
                        │  职责：节点注册 / 健康探活 / 节点列表     │
                        │        版本记录 / 同步到 GitHub          │
                        └──────────────┬─────────────────────────┘
                                       │
                          Node List (HTTP Response)
                                       │
             ┌─────────────────────────┴──────────────────────────┐
             ▼                                                    ▼
  ┌─────────────────────┐                            ┌──────────────────────┐
  │  GUI Client Agent   │                            │   TUI Client Agent   │
  │  (壳：只做渲染)     │                            │   (壳：只做渲染)     │
  └──────────┬──────────┘                            └──────────┬───────────┘
             │ 共用                                             │
             │                                                  │
             ▼                                                  ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │                    Core Agent（客户端核心智能体）                           │
  │                                                                          │
  │  内部子智能体：                                                           │
  │  ├─ Discovery Agent  （节点发现：中心→GitHub fallback）                   │
  │  ├─ Selector Agent   （节点选择：手动 v1 / 自动 v2+）                     │
  │  ├─ Task Agent       （任务生命周期：创建/轮询/取消/取下载地址）            │
  │  ├─ Config Agent     （配置持久化：上次节点/下载目录/中心地址）             │
  │  └─ Retry Agent      （失败重试：超时/断点续传/换节点）                    │
  └──────────┬───────────────────────────────────────────────────────────────┘
             │ Task Create / Poll / Cancel / Download (HTTP)
             │
    ┌────────┼─────────────────┐
    ▼        ▼                 ▼
 ┌──────┐ ┌──────┐        ┌──────┐
 │Node A│ │Node B│ ...... │Node N│   （全世界任意 VPS，人人可部署）
 │Agent │ │Agent │        │Agent │
 └──┬───┘ └──┬───┘        └──┬───┘
    │        │               │
    │ 内部子智能体：          │
    │ ├─ TaskManager Agent  （入队/并发控制）│
    │ ├─ DownloadWorker Agent（Aria2 RPC 调用）│
    │ ├─ Storage Agent      （按 task_id 分目录 / 磁盘配额 / TTL 清理）│
    │ └─ Security Agent     （SSRF 防护 / URL 白名单协议 / 文件大小限制）│
    │
    ▼
 Aria2（独立进程，下载引擎）
    │
    ▼
 /data/downloads/{task_id}/（Nginx 提供 HTTP Range 静态文件服务）
```

---

## 3. Agent 清单与职责边界

下面逐个定义系统里的每个 Agent。

### 3.1 Center Agent（中心控制智能体）

**一句话**：只做控制面，永远不处理用户文件数据。

| 维度 | 内容 |
|---|---|
| **上游输入** | ① Node Agent 的自注册请求 ② 用户提交的节点申请 ③ 定时触发的健康检查 tick |
| **下游输出** | ① 对 Client Core：/api/nodes 节点列表 ② 对 GitHub：registry/servers.json push ③ 对 Node Agent：探活 HTTP 请求 |
| **内部子 Agent** | HealthCheckAgent、RegistrySyncAgent、NodeReviewAgent |
| **拥有的状态** | nodes 表（SQLite / Postgres）：id、name、api_url、region、version、features、status(online/offline/maintenance)、last_seen、enabled |
| **API 契约** | 见 §4.1 |
| **失败影响** | Client Core 无法拿到节点列表；但已设计 **GitHub Registry Fallback**，系统仍能降级运行 |

### 3.2 Node Agent（节点下载智能体，MVP 核心）

**一句话**：真正跑在 VPS 上的下载执行者，是系统的「数据面」。

| 维度 | 内容 |
|---|---|
| **上游输入** | ① Client Core：`POST /api/tasks`（提交 URL）② 定时 tick：同步 Aria2 状态到 DB ③ 定时 tick：TTL 清理 |
| **下游输出** | ① Aria2 RPC：addUri / tellStatus / remove ② 磁盘写入 `/data/downloads/{task_id}/` ③ Nginx：静态文件供用户下载 |
| **内部子 Agent** | 见下表 |
| **硬限制（可配置）** | 协议只允许 http/https、单文件 ≤ 10GB、并发下载 ≤ 2、磁盘使用 ≤ 40GB、完成后 TTL = 60min |
| **API 契约** | 见 §4.2 |
| **失败影响** | 单点失败（该节点的任务失败），不影响其他节点。用户可以换一个节点重试。 |

Node Agent 内部四个子 Agent：

| 子 Agent | 职责 |
|---|---|
| **SecurityAgent** | 所有 `POST /api/tasks` 入站第一道关卡：解析 host → getaddrinfo → 拒绝所有内网/回环/链路本地 IP（防 SSRF），拒绝 file:// / ftp:// 等协议，拒绝 Content-Length > 10GB |
| **TaskManagerAgent** | 维护并发队列（默认并发数 2）。新任务如果位置满了就标记 `queued`，有位置了给 DownloadWorkerAgent |
| **DownloadWorkerAgent** | 封装 Aria2 RPC。负责 addUri → 轮询 tellStatus → 把 speed/downloaded_size/total_size/status 写回 tasks 表 |
| **StorageAgent** | ① 按 task_id 建目录 ② 周期（5min）做磁盘 `du`，超过 40GB 阈值拒绝新任务 ③ 周期扫 completed 任务，`completed_at + 60min` 已到的删文件 + 删 DB 记录 |

### 3.3 Core Agent（客户端核心智能体）

**一句话**：GUI 和 TUI 都只是壳；**所有业务逻辑都在这里**。

| 子 Agent | 职责 |
|---|---|
| **DiscoveryAgent** | 主路径：`GET {center_url}/api/nodes` → 获取节点清单；主路径失败时 fallback：`GET https://raw.githubusercontent.com/{org}/registry/main/servers.json` → 用 schema.json 校验 |
| **SelectorAgent** | MVP v1：返回用户手动选的节点（记录上次选择到 ConfigAgent）。v2+：按 延迟/地区/可用性/负载/试下载速度 自动排序给出推荐 |
| **TaskAgent** | `create_task(node_api, url)` → task_id；`poll_task(node_api, task_id)` → Stream<Progress>；`get_download_url(node_api, task_id)` → URL；`cancel_task(node_api, task_id)` |
| **RetryAgent** | 收到 failed / 超时：① 同一节点重试 1 次 ② 还不行按 SelectorAgent 的下一个节点自动换节点 ③ 客户端给出手动选项 |
| **ConfigAgent** | 用 confy/dirs 持久化：center_url、default_node_id、download_dir、log_level |

### 3.4 Client Agents（界面壳）

**GUI Client Agent** + **TUI Client Agent** 只做三件事：
1. 把用户输入（URL、选节点、取消、下载）转发给 Core Agent
2. 监听 Core Agent 的 Stream，实时渲染进度条/速度/状态
3. 弹出错误 / 提示

它们不做任何业务判断。界面换皮不需要改 Core。

### 3.5 Registry（GitHub 公开注册中心）

不是代码 Agent，是 GitHub 上的一个公开仓库：

```
async-relay-registry/
├── servers.json   # 节点列表（CenterAgent 每 15 分钟 push 一次）
└── schema.json    # JSON Schema，客户端用于校验 servers.json 合法性
```

作用：**当 Center Server 挂了，客户端 Core 直接读这里拿到最后一份可用节点清单，系统不会整体瘫痪。**

---

## 4. Agent 间通信协议（API 契约）

Agent 之间**只用 HTTP(S) JSON 通信**，不共享数据库、不共享内存、不使用消息队列（MVP 阶段保持简单）。

### 4.1 Center Agent ↔ Client Core

```http
### Center → Client：节点列表
GET  /api/nodes
Response:
[
  {
    "id": "jp-01",
    "name": "Japan 01",
    "api": "https://jp01.example.com",
    "region": "JP",
    "version": "1.0.0",
    "features": ["download", "range"],
    "status": "online",
    "enabled": true
  }
]

### 用户提交新节点（先进入审核队列）
POST /api/nodes/submit
Request: { "name": "...", "api": "https://...", "region": "HK", "description": "..." }
Response: { "submission_id": "...", "status": "pending_review" }
```

### 4.2 Node Agent ↔ Client Core

```http
### 客户端确认「这确实是一个 Node Agent」
GET  /api/node/info
Response:
{
  "id": "jp-01",
  "name": "Japan 01",
  "version": "1.0.0",
  "region": "JP",
  "features": ["download", "range"],
  "concurrent_limit": 2,
  "max_file_size_gb": 10,
  "storage_used_gb": 17.2,
  "storage_limit_gb": 40
}

### 提交下载任务
POST /api/tasks
Request:  { "url": "https://github.com/.../file.zip" }
Response: { "task_id": "a8f31c", "status": "queued", "created_at": "..." }

### 查询任务进度
GET  /api/tasks/{task_id}
Response:
{
  "task_id": "a8f31c",
  "source_url": "...",
  "filename": "file.zip",
  "status": "downloading",   # queued | downloading | completed | failed
  "total_size": 123456789,   # bytes，未拿到时为 null
  "downloaded_size": 87654321,
  "speed": 50331648,         # bytes/s
  "created_at": "...",
  "completed_at": null,
  "expires_at": "...",       # 等于 completed_at + 60min
  "error": null              # failed 时填
}

### 取消 + 删除任务
DELETE /api/tasks/{task_id}
Response: { "ok": true }

### 取下载地址（302 跳转到 Nginx 静态文件 URL）
GET  /api/tasks/{task_id}/download
302 Location: https://jp01.example.com/downloads/a8f31c/file.zip?token=<一次性 token>
```

> **下载 token 说明**：Node Agent 在任务完成时生成一个一次性 token，和 task_id + expire_at 一起存 DB；Nginx 侧用 `auth_request` 反代回 Node Agent 的 `/api/tasks/{id}/auth` 校验后再放行文件。避免任何人只要知道 task_id 就能下载。

### 4.3 Center Agent → Node Agent（健康检查）

```http
GET {node.api}/api/node/info
200 → status = online
非200 连续 2 次 → status = offline
```

### 4.4 Center Agent → GitHub Registry（同步）

```
频率：每 15 分钟一次，或节点列表有变化时批处理
动作：把 nodes 表中 enabled=true 的节点序列化为 servers.json → git commit → push 到 registry 仓库
鉴权：GitHub Personal Access Token（.env 存储，不入 Git）
```

---

## 5. 任务状态机

```
           POST /api/tasks
               │
               ▼
          ┌─────────┐
          │ queued  │  并发槽满，等待
          └────┬────┘
               │  有槽位，交给 DownloadWorkerAgent
               ▼
          ┌─────────────┐
     ┌───│ downloading │────────┐
     │   └──────┬──────┘        │
     │          │                │  进度→DB
     │  Aria2 下载出错           │
     │          │                │
     │          ▼                ▼
     │    ┌────────┐       ┌───────────┐
     └───▶│ failed │       │ completed │
          └────────┘       └─────┬─────┘
                                 │
                                 ▼
                     expires_at 到点后 StorageAgent
                           删文件 + 清 DB
```

---

## 6. MVP 边界（明确不做）

下面这些功能，**在 MVP 闭环跑通前一律不写代码**：

- ❌ 用户账号 / 登录 / 提交记录与用户绑定
- ❌ 积分 / VIP / 付费
- ❌ 自动节点选择 + 负载均衡（v1 手动选，v2 再加）
- ❌ 国内对象存储二次中转、CDN 回源
- ❌ Telegram / QQ / Discord Bot（虽然你的仓库里有 qq-bot 目录，但这是 NodeFetch 之外的东西）
- ❌ 客户端自动更新
- ❌ 多用户 / 多租户 / RBAC 权限
- ❌ 磁力链接 / BT / ed2k（只做 http/https）
- ❌ 任务拆分到多个节点并发分段下载再合并

---

## 7. 推荐技术栈

按 Agent 归属：

| Agent | 语言/框架 | 原因 |
|---|---|---|
| **Node Agent** | Python + FastAPI + SQLAlchemy + AioSQLite + Aria2(c) RPC + Nginx | 生态成熟、Aria2 RPC 封装简单、部署方便，原规划推荐 |
| **Center Agent** | Python + FastAPI + SQLAlchemy + SQLite/Postgres + PyGithub | 和 Node Agent 共享技术栈，团队只需懂一套语言 |
| **Core Agent（含子 Agent）** | Rust (reqwest + tokio + serde + confy + thiserror) | 编译成单文件、跨平台（Win/Linux/macOS）、Core 稳定后 GUI/TUI/Web/Android 都能复用 |
| **TUI Client Agent** | Rust + ratatui + crossterm | 原规划推荐，和 Core 同语言无 FFI |
| **GUI Client Agent** | **Rust + Tauri（前端用原生 HTML/CSS/TS）** | 打包小、界面现代化、未来 Web 版前端代码可复用；如果团队完全不会前端，备选 egui（纯 Rust） |
| **GitHub Registry** | 纯 JSON + JSON Schema | 无运行时 |

> 原规划中「客户端技术栈可以最后再定，不影响后端架构」——**正确。先把 Node Agent + Center Agent 做出来用 curl 测通，客户端的技术选择不影响后端。**

---

## 8. 最终项目结构（代码仓库布局）

```
NodeFetch/
│
├── Agent.md                              # ✅ 本文件：智能体架构总览（权威）
├── AsyncRelay_项目规划.md                 # 历史参考：原规划文档
│
├── center-agent/                         # 对应 §3.1 Center Agent
│   ├── main.py
│   ├── requirements.txt
│   ├── .env.example
│   ├── api/
│   │   ├── nodes.py                      # /api/nodes, /api/nodes/submit
│   │   └── registry.py                   # 手动触发 GitHub 同步的 admin API
│   ├── models/
│   │   ├── database.py
│   │   └── node.py                       # Node ORM
│   └── services/
│       ├── health_check_agent.py         # 定时探活
│       ├── github_sync_agent.py          # 定时 push registry
│       └── node_review_agent.py          # 提交节点审核
│
├── main.py                               # 对应 §3.2 Node Agent
│   ├── requirements.txt
│   ├── .env.example
│   ├── deploy/
│   │   ├── aria2.conf                    # aria2c 配置（必须开 rpc-secret）
│   │   ├── nginx.conf                    # /api 反代 + /downloads 静态 + auth_request
│   │   └── systemd/                      # node-agent.service + aria2.service
│   ├── api/
│   │   ├── node.py                       # GET /api/node/info
│   │   └── tasks.py                      # POST/GET/DELETE /api/tasks + download redirect
│   ├── models/
│   │   ├── database.py
│   │   └── task.py                       # Task ORM（对应 §2.8 的字段）
│   ├── agents/                           # 内部四个子 Agent
│   │   ├── security_agent.py             # SSRF 防护（第一道门）
│   │   ├── task_manager_agent.py         # 并发队列
│   │   ├── download_worker_agent.py      # Aria2 RPC 封装
│   │   └── storage_agent.py              # 配额 + TTL 清理
│   └── tests/
│       ├── test_security_ssrf.py         # SSRF 用例集（必须全过）
│       ├── test_task_lifecycle.py        # queued→downloading→completed 链路
│       └── test_storage_ttl.py           # 过期清理
│
├── registry/                             # 本地副本，center-agent 写这里再 push
│   ├── servers.json
│   └── schema.json
│
├── client-core/                          # 对应 §3.3 Core Agent（Rust）
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── agents/
│       │   ├── discovery_agent.rs        # 中心主路径 + GitHub fallback + schema 校验
│       │   ├── selector_agent.rs         # v1 手动选择，v2+ 自动排序
│       │   ├── task_agent.rs             # create/poll/cancel/download_url
│       │   ├── retry_agent.rs            # 失败重试 + 换节点
│       │   └── config_agent.rs           # 配置持久化
│       └── types.rs                      # Task / Node / Progress 等共享 DTO
│
├── client-tui/                           # 对应 §3.4 TUI
│   ├── Cargo.toml
│   └── src/main.rs
│
├── client-gui/                           # 对应 §3.4 GUI（Tauri 项目）
│   ├── src-tauri/
│   └── src/   (前端 HTML/CSS/TS)
│
└── README.md                             # 最终写：项目简介 + 快速上手指南（MVP 完成后再写）
```

---

## 9. 开发阶段顺序（严格依赖顺序）

```
  阶段 ①              阶段 ②              阶段 ③              阶段 ④              阶段 ⑤
 Node Agent        Center Agent      Client Core         Client TUI         Client GUI
     │                 │                  │                  │                  │
  用 curl 测      节点注册/列表/      写单元测试           ratatui 壳        Tauri / egui 壳
  通下载闭环       探活/GitHub 同步    用 mock 测 Core     调用 Core 全链路    复用 Core 跑 GUI
     │                 │                  │                  │                  │
  ┌───────┐       ┌──────────┐       ┌──────────┐       ┌──────────┐       ┌──────────┐
  │✅ 完成 │──────▶│✅ 完成  │──────▶│✅ 完成  │──────▶│✅ 完成  │──────▶│✅ 完成  │
  └───────┘       └──────────┘       └──────────┘       └──────────┘       └──────────┘
   依赖无         依赖阶段①       依赖阶段①②           依赖阶段③           依赖阶段③
   （自闭环）     （只是调用其 API） （只是调用其 API）
```

**为什么阶段①要先单独搞定？** 因为整个系统存在的意义就是「节点能高速下载」。如果 Aria2 + VPS + SSRF 防护 + Nginx Range 这一套在单机上都跑不通，后面 Center/Core/GUI 全是空中楼阁。**阶段①先在真实 VPS 上验证速度和稳定性达标后再推进后面。**

---

## 10. 风险与缓解（Agent 视角）

| 风险 | 归属 Agent | 缓解措施 |
|---|---|---|
| 节点被 SSRF 攻击（`file:///etc/passwd`、`http://169.254.169.254` 拉元数据） | **SecurityAgent**（第一道防线） | host 解析出所有 IP → 逐条检查是否为私有/回环/链路本地 → 拒绝；URL 协议只允许 http/https；必须在测试里覆盖所有边界用例（127.0.0.1、[::1]、0.0.0.0、10.x、192.168.x、172.16-31.x、169.254.x、fc00::/7） |
| Aria2 RPC 无认证被劫持 | **DownloadWorkerAgent** | 强制 `--rpc-secret`，secret 放 `.env`，**绝不入 Git**；Aria2 只 bind 127.0.0.1，绝不对外 |
| 磁盘写爆 VPS | **StorageAgent** | 每 5 分钟 `du /data/downloads`，超过 40GB（可配）时给 `/api/node/info` 返回 storage_full 标志 + 拒绝新 `POST /api/tasks` |
| 节点被用来下非法/侵权内容 | **SecurityAgent（可加 v2 子 Agent）** | v1 做好操作日志（URL + 时间 + 结果，不存用户身份）；v2 可加 Content-Disposition 文件名黑名单 + 自动 DMCA 处理钩子 |
| Center Server 挂了导致所有客户端失明 | **DiscoveryAgent** | 客户端 Core 内置 GitHub registry fallback；失败后自动尝试 raw.githubusercontent.com 拿 servers.json |
| Rust 学习曲线陡拖慢客户端进度 | — | 用 Python + Typer 先写一个临时的 CLI MVP 客户端测通后端，不影响 Core 的长期计划 |
| 项目名混乱影响沟通 | — | 全仓库统一使用 `NodeFetch`（当前目录名）。原文档里 AsyncRelay 作为别名保留在 README |

---

## 11. MVP 验收标准（闭环跑通）

在阶段⑤完成后，必须能无人工干预地完成以下整个链路：

```
1. 启动一个 Node Agent（VPS 上，跑 Aria2）
2. 启动一个 Center Agent，Node Agent 在 Center 注册后状态 online
3. Center Agent 把节点列表同步到 GitHub registry
4. GUI 客户端启动 → DiscoveryAgent 从 Center 拿到节点列表（如果 Center 挂，则从 GitHub 拿）
5. 用户在 GUI 选 JP-01 → 粘贴 `https://example.com/100mb.bin` → 点「开始下载」
6. GUI 上看到进度条从 0 到 100%，实时刷新速度
7. 完成后 GUI 显示下载链接 → 用户点击后浏览器开始下载，支持断点续传（暂停后恢复不从头开始）
8. 60 分钟后节点上的 100mb.bin 自动被 StorageAgent 清除
```

全部 8 步一次过，才算 MVP 完成。中间失败可以看每个 Agent 的日志。

---

*本文档是 NodeFetch 项目的权威架构依据。后续实施计划、代码评审、验收都以它为准。*
*文档结束*
