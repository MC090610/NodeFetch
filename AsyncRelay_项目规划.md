# AsyncRelay 项目规划

> 多节点异步下载客户端  
> 用户提交国外资源下载地址 → 选择下载节点 → 节点 VPS 高速下载 → 用户获取文件

## 1. 项目定位

AsyncRelay 是一个多节点异步下载客户端。

```text
国外下载地址
      ↓
选择下载节点
      ↓
节点 VPS 下载
      ↓
节点本地存储
      ↓
客户端获得下载地址
      ↓
用户下载文件
```

它不是代理，也不是网盘。

核心目标：

> 利用不同地区 VPS 的海外网络优势，异步获取国外资源，再让用户从选定节点取回文件。

---

## 2. 整体架构

```text
                 GitHub
                   │
             节点列表同步
                   │
                   ▼
            中心服务器
                   │
             节点信息 API
                   │
        ┌──────────┴──────────┐
        ▼                     ▼
    GUI 客户端             TUI 客户端
        │                     │
        └──────────┬──────────┘
                   │
               用户选择节点
                   │
        ┌──────────┼──────────┐
        ▼          ▼          ▼
      节点 A      节点 B      节点 C
        │          │          │
      Aria2      Aria2      Aria2
        │          │          │
      Storage    Storage    Storage
```

---

## 3. 中心服务器

中心服务器不是下载服务器，主要负责：

- 节点 ID
- 节点名称
- API 地址
- 所在地区
- 节点状态
- 节点版本
- 支持的功能

示例：

```json
{
  "id": "jp-01",
  "name": "Japan 01",
  "api": "https://jp01.example.com",
  "region": "JP",
  "enabled": true
}
```

### GitHub 同步

```text
GitHub
  ↓
中心服务器
  ↓
节点数据库
  ↓
客户端
```

也可以：

```text
用户提交节点
      ↓
中心服务器
      ↓
审核
      ↓
节点数据库
      ↓
同步 GitHub
```

> 用户与提交记录的对应关系暂时不设计。

---

## 4. GitHub 的作用

GitHub 主要作为：

> 公开的节点目录和备用节点数据源。

例如：

```text
async-relay-registry/
├── servers.json
├── README.md
└── schema.json
```

客户端正常情况下：

```text
启动
 ↓
请求中心服务器
 ↓
获取节点列表
```

如果中心服务器暂时不可用：

```text
中心服务器失败
      ↓
读取 GitHub
      ↓
获取最近的节点列表
```

这样客户端不会完全依赖中心服务器。

---

## 5. 用户提交节点

客户端可以提供：

```text
服务器
├── 官方节点
└── 社区节点
```

用户可以提交：

```text
节点名称
节点 API
地区
节点说明
```

流程：

```text
提交
 ↓
中心服务器
 ↓
检查节点是否可用
 ↓
审核
 ↓
加入节点列表
 ↓
同步 GitHub
```

---

## 6. 节点服务器

节点服务器是真正负责下载的机器。

每个节点运行同一个后端程序：

```text
AsyncRelay Node
```

内部：

```text
Node API
   │
   ├── Task Manager
   ├── Download Worker
   └── Storage Manager
             │
             ▼
          Aria2
             │
             ▼
        /data/downloads
```

任何人都可以部署：

```text
日本 VPS → AsyncRelay Node
香港 VPS → AsyncRelay Node
美国 VPS → AsyncRelay Node
```

---

## 7. 节点 API

至少提供：

```http
GET  /api/node/info
POST /api/tasks
GET  /api/tasks/{id}
GET  /api/tasks/{id}/download
DELETE /api/tasks/{id}
```

Node Info：

```json
{
  "id": "jp-01",
  "name": "Japan 01",
  "version": "1.0.0",
  "region": "JP",
  "features": [
    "download",
    "range"
  ]
}
```

用于确认：

> 这个地址确实是 AsyncRelay Node。

---

## 8. 下载任务

```text
Task
├── id
├── source_url
├── filename
├── status
├── total_size
├── downloaded_size
├── speed
├── created_at
├── completed_at
└── expires_at
```

状态：

```text
queued
   ↓
downloading
   ↓
completed
```

异常：

```text
failed
```

---

## 9. 下载过程

客户端：

```http
POST /api/tasks
```

提交：

```json
{
  "url": "https://example.com/file.zip"
}
```

节点：

```text
创建 Task
   ↓
加入队列
   ↓
Aria2 下载
   ↓
保存到 Storage
```

客户端通过：

```http
GET /api/tasks/{id}
```

获取：

- 下载进度
- 下载速度
- 文件大小
- 状态

---

## 10. 文件存储

默认：

```text
/data/downloads/
```

按任务 ID 分目录：

```text
/data/downloads/
├── a8f31c/
│   └── file.zip
├── b71de2/
│   └── rom.zip
└── c92fa1/
    └── source.tar.gz
```

---

## 11. 用户下载

下载完成后：

```text
Node
 ↓
Task completed
 ↓
客户端获取下载地址
```

例如：

```text
https://jp01.example.com/download/a8f31c
```

用户可以使用：

- 浏览器
- IDM
- aria2
- wget

直接下载。

节点需要支持：

- HTTP Range
- 断点续传
- 大文件
- Content-Length

实际文件传输可以交给 Nginx，Node API 负责任务、权限和状态。

---

## 12. GUI 客户端

GUI 是普通用户主要使用的版本。

```text
┌────────────────────────────────────┐
│          AsyncRelay                │
├────────────────────────────────────┤
│ 下载地址                            │
│ ┌──────────────────────────────┐  │
│ │ https://github.com/...       │  │
│ └──────────────────────────────┘  │
│                                    │
│ 服务器：[ 日本 01 ▼ ]              │
│                                    │
│             [开始下载]             │
├────────────────────────────────────┤
│ 下载任务                            │
│                                    │
│ rom.zip                            │
│ ██████████████░░░░ 72%             │
│ 48 MB/s                            │
└────────────────────────────────────┘
```

---

## 13. TUI 客户端

TUI 使用同一个 Core：

```text
AsyncRelay

Server: JP-01

URL:
> https://github.com/...

Tasks:

[██████████████░░░░] 72%
rom.zip             48 MB/s

Enter  Download
S      Server
R      Refresh
Q      Quit
```

---

## 14. Core 设计

GUI 和 TUI 不分别实现业务逻辑。

```text
                 AsyncRelay Core
                       │
              ┌────────┴────────┐
              ▼                 ▼
           GUI Client       TUI Client
```

Core 负责：

- 节点发现
- 节点选择
- API 请求
- 创建任务
- 查询任务
- 获取下载地址
- 配置管理
- 错误处理

GUI/TUI 只负责界面。

以后增加 CLI、Android、Web，也可以复用 Core。

---

## 15. 节点选择

第一版：

> 用户手动选择。

```text
服务器：

● 日本 01
○ 日本 02
○ 香港 01
○ 美国 01
```

以后再增加自动选择，根据：

- 延迟
- 节点负载
- 可用性
- 地区
- 下载测试速度

自动选择。

---

## 16. 节点状态

中心服务器定期检查：

```text
Node
 ↓
/api/node/info
 ↓
200 OK
```

状态：

```text
online
offline
maintenance
```

客户端优先显示 online 节点。

---

## 17. 节点版本

节点返回：

```json
{
  "version": "1.0.0"
}
```

中心服务器可以记录各节点版本，以后用于版本提示和升级。

---

## 18. 最基础的安全要求

### URL 限制

只允许：

```text
http://
https://
```

禁止：

```text
file://
localhost
127.0.0.1
内网 IP
```

防止 SSRF。

### 文件限制

```text
单文件最大 10GB
```

### 并发限制

例如：

```text
同时下载：2
```

### 存储限制

例如：

```text
缓存最大：40GB
```

### 自动清理

例如：

```text
完成后 60 分钟自动删除
```

---

## 19. 推荐技术栈

### Node Server

```text
Python
FastAPI
SQLite
aria2
Nginx
```

### Center Server

```text
Python
FastAPI
SQLite / PostgreSQL
```

中心服务器规模不大，SQLite 初期也够。

### Client

建议考虑：

```text
Rust
```

原因：

- GUI/TUI 都适合
- 编译成单文件比较方便
- Windows/Linux 支持好
- Core 可以复用
- 后期跨平台方便

GUI 后续可选择：

```text
Tauri
egui
Iced
```

TUI 使用 Rust TUI 框架。

> 客户端技术栈可以最后再定，不影响后端架构。

---

## 20. 开发顺序

### 第一阶段：Node Server

实现：

```text
提交 URL
 ↓
Aria2 下载
 ↓
查询进度
 ↓
返回下载地址
```

先确认 VPS 下载速度和稳定性。

### 第二阶段：Center Server

实现：

```text
节点注册
节点列表
节点状态
GitHub 同步
```

### 第三阶段：Core

实现：

```text
获取节点
选择节点
创建任务
查询任务
获取下载地址
```

### 第四阶段：TUI

先做一个简单客户端。

### 第五阶段：GUI

使用同一个 Core。

---

## 21. 最终项目结构

```text
AsyncRelay/
│
├── center-server/
│   ├── api/
│   ├── models/
│   ├── services/
│   └── main.py
│
├── node-server/
│   ├── api/
│   ├── models/
│   ├── services/
│   ├── worker/
│   └── main.py
│
├── client-core/
│   ├── api/
│   ├── node/
│   ├── task/
│   └── config/
│
├── client-gui/
│
├── client-tui/
│
├── registry/
│   ├── servers.json
│   └── schema.json
│
└── README.md
```

---

## 22. MVP 最终闭环

```text
                 GitHub
                    │
                    ▼
             Center Server
                    │
               节点列表
                    │
                    ▼
              GUI / TUI
                    │
              用户选择节点
                    │
                    ▼
              Node Server
                    │
                 Aria2
                    │
                    ▼
                Storage
                    │
                    ▼
                Download
```

第一版暂时不考虑：

```text
❌ 用户提交记录关联
❌ 积分
❌ VIP
❌ 多节点自动负载均衡
❌ 国内对象存储
❌ Telegram
❌ CDN
❌ 自动更新
❌ 复杂权限系统
```

先把：

> **客户端发现节点 → 用户选择节点 → 节点下载 → 用户拿到文件**

这个核心闭环做通。

---

## 23. 项目核心原则

### 原则 1：节点与客户端解耦

```text
Client
 ↓
Node Registry
 ↓
任意可用 Node
```

### 原则 2：中心服务器只负责控制面

```text
节点信息
节点状态
节点注册
GitHub 同步
```

不负责大文件传输。

### 原则 3：节点负责数据面

```text
下载
存储
任务
文件传输
```

### 原则 4：GUI/TUI 共用 Core

```text
Core
├── GUI
└── TUI
```

避免重复开发。

### 原则 5：第一版保持简单

先实现：

```text
发现节点
 ↓
选择节点
 ↓
提交 URL
 ↓
异步下载
 ↓
获取文件
```

其他功能等核心闭环稳定后再增加。

---

*文档结束*
