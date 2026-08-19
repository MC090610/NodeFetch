"""Node 路由：/api/node/*（Agent.md §4.2.5）。"""
from __future__ import annotations

import logging

from fastapi import APIRouter

from api.schemas import NodeHealthResponse
from config import get_settings
from models.database import scoped_session
from models.task import Task
from sqlalchemy import func, select

router = APIRouter(prefix="/api/node", tags=["node"])
log = logging.getLogger(__name__)


@router.get("/health", response_model=NodeHealthResponse)
async def health() -> NodeHealthResponse:
    """Node 健康检查：aria2 可达性 + 队列统计 + 存储占用。"""
    settings = get_settings()

    # 1. 队列统计（直接读 DB）
    async with scoped_session() as session:
        # 按 status group by
        stmt = select(Task.status, func.count(Task.id)).group_by(Task.status)
        rows = (await session.execute(stmt)).all()
    counts: dict[str, int] = {s: c for s, c in rows}
    total = sum(counts.values())
    queue = {
        "queued": counts.get("queued", 0),
        "downloading": counts.get("downloading", 0),
        "completed": counts.get("completed", 0),
        "failed": counts.get("failed", 0),
        "total": total,
    }

    # 2. Aria2 连通性（轻量：尝试一次 get_global_stat，失败就 aria2_online=False，不抛错）
    aria2_online = False
    try:
        from agents.download_worker_agent import DownloadWorkerAgent
        worker = DownloadWorkerAgent(_settings=settings)
        stats = await worker.get_global_stat(timeout=1.5)
        aria2_online = bool(stats and "numActive" in stats)
    except Exception as e:  # noqa: BLE001 - health 不能抛异常
        log.warning("aria2 health probe failed: %s", e)
        aria2_online = False

    # 3. Storage 用量
    used_bytes = 0
    limit_bytes = settings.storage_limit_bytes
    download_dir = settings.download_dir_path
    try:
        if download_dir.exists():
            # completed + storage_path != None 任务的 total_size 之和（MVP 上界）
            used_bytes = sum(
                f.stat().st_size for f in download_dir.rglob("*") if f.is_file()
            )
    except OSError as e:
        log.warning("scanning download dir failed: %s", e)
    used_ratio = round(used_bytes / limit_bytes, 4) if limit_bytes > 0 else 0.0

    # status 判定
    if not aria2_online:
        overall: str = "degraded" if used_ratio < 1.0 else "down"
    elif used_ratio > 0.95:
        overall = "degraded"
    else:
        overall = "ok"

    return NodeHealthResponse(
        status=overall,  # type: ignore[arg-type]
        aria2_online=aria2_online,
        queue=queue,
        storage={
            "used_bytes": used_bytes,
            "limit_bytes": limit_bytes,
            "used_ratio": used_ratio,
        },
        node_id=settings.node_id,
    )
