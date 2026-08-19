"""Node Agent 的 FastAPI 入口。

运行：
    cd node-agent
    python -m uvicorn main:app --reload  # 开发
    # 或生产：
    uvicorn main:app --host 0.0.0.0 --port 8000 --workers 1
"""
from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from agents.download_worker_agent import DownloadWorkerAgent
from agents.security_agent import SecurityAgent
from agents.storage_agent import StorageAgent
from agents.task_manager_agent import TaskManagerAgent
from api import node as node_routes
from api import tasks as task_routes
from config import get_settings
from models.database import init_db

log = logging.getLogger(__name__)


def _configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s | %(message)s",
    )


# --------------------------------- lifespan ---------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    """启动时：建表 + 注册 Center（可选）+ 启动周期 tick；关闭时停止周期协程。

    周期任务（后台 asyncio.Task）：
    - TaskManager.tick_once()   每 1.5s — 推进 queued→downloading 与下载状态写回 DB
    - StorageAgent.cleanup_expired() + enforce_quota() 每 60s — TTL + 配额治理
    """
    _configure_logging()
    settings = get_settings()
    log.info(
        "[node-agent] starting node_id=%s version=%s db=%s",
        settings.node_id, settings.version, settings.db_url,
    )

    # 1) 建表（幂等）
    try:
        await init_db()
    except Exception as e:  # pragma: no cover
        log.exception("init_db failed: %s", e)
        raise

    # 2) 保证下载目录存在
    download_dir = settings.download_dir_path
    download_dir.mkdir(parents=True, exist_ok=True)
    log.info("[node-agent] download_dir=%s (limit=%sGB, TTL=%smin)",
             download_dir, settings.storage_limit_gb, settings.ttl_minutes)

    # 3) 共享 agent 实例（main 和 routes 里各管各的也行；这里存到 app.state）
    worker = DownloadWorkerAgent(_settings=settings)
    security = SecurityAgent(settings=settings)
    storage = StorageAgent(settings=settings, download_worker=worker)
    manager = TaskManagerAgent(
        worker=worker,
        settings=settings,
        security=security,
        storage=storage,
    )
    app.state.task_manager = manager
    app.state.storage_agent = storage
    app.state.download_worker = worker

    # 4) 可选：启动时向 Center 注册（CENTER_URL 存在就试一次，失败降级继续跑）
    center_url = getattr(settings, "center_url", None) or None
    center_token = getattr(settings, "center_token", None) or None
    if center_url:
        try:
            import json as _json
            import urllib.request as _req
            data = _json.dumps({
                "node_id": settings.node_id,
                "node_name": settings.node_name,
                "region": settings.region,
                "api_base": f"http://{settings.api_host}:{settings.api_port}",
                "version": settings.version,
            }).encode()
            req = _req.Request(
                center_url.rstrip("/") + "/api/agents/node/register",
                data=data,
                method="POST",
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {center_token}" if center_token else "",
                },
            )
            with _req.urlopen(req, timeout=5) as resp:
                log.info("[node-agent] center registration: HTTP %s", resp.status)
        except Exception as e:  # noqa: BLE001 - 注册失败不影响 node 独立运行
            log.warning("[node-agent] failed to register to center (%s): %s", center_url, e)

    # 5) 启动两个周期任务（Background coroutines）
    async def _tm_tick_loop():
        while True:
            try:
                await manager.tick_once()
            except Exception as e:  # noqa: BLE001 - 单轮失败不终止循环
                log.exception("[tick] task-manager failed: %s", e)
            await asyncio.sleep(1.5)

    async def _storage_loop():
        while True:
            try:
                n_expired = await storage.cleanup_expired()
                if n_expired:
                    log.info("[storage] cleaned %d expired task(s)", n_expired)
                n_freed = await storage.enforce_quota()
                if n_freed:
                    log.info("[storage] freed %d task(s) for quota", n_freed)
            except Exception as e:  # noqa: BLE001
                log.exception("[tick] storage failed: %s", e)
            await asyncio.sleep(60)

    t_tm = asyncio.create_task(_tm_tick_loop(), name="tm-tick")
    t_st = asyncio.create_task(_storage_loop(), name="storage-tick")

    try:
        yield
    finally:
        log.info("[node-agent] shutting down background loops")
        for t in (t_tm, t_st):
            t.cancel()
        await asyncio.gather(t_tm, t_st, return_exceptions=True)
        log.info("[node-agent] shutdown complete")


# ------------------------------------ app -----------------------------------

app = FastAPI(
    title="NodeFetch Node Agent",
    description=("Distributed offloader for big-file downloads. "
                 "Agent contract: see <repo>/Agent.md §4."),
    version="0.1.0-mvp",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(node_routes.router)
app.include_router(task_routes.router)


@app.get("/", include_in_schema=False)
def root() -> dict:
    s = get_settings()
    return {
        "name": "NodeFetch-Node-Agent",
        "version": "0.1.0-mvp",
        "node_id": s.node_id,
        "docs": "/docs",
        "health": "/api/node/health",
    }
