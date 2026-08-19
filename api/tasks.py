"""Task 路由：/api/tasks/* + 一次性直链 /downloads/*（Agent.md §4.2.1~4 和 §4.3）。"""
from __future__ import annotations

import logging
import mimetypes
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import FileResponse, StreamingResponse

from agents.download_worker_agent import DownloadWorkerAgent
from agents.security_agent import (
    FileTooLarge,
    InvalidProtocol,
    SecurityAgent,
    SecurityError,
    SSRFBlocked,
    ValidateURLError,
)
from agents.storage_agent import StorageAgent
from agents.task_manager_agent import TaskManagerAgent
from api.schemas import (
    CreateTaskRequest,
    ListTasksResponse,
    TaskResponse,
    TaskStatus,
)
from config import get_settings
from models.database import scoped_session
from models.task import Task
from sqlalchemy import select

router = APIRouter(tags=["tasks"])
log = logging.getLogger(__name__)


# ---------- 依赖注入：agent 共享实例 ----------

def _task_manager() -> TaskManagerAgent:
    """单进程内用同一个 TaskManager（它内部有并发槽状态）。"""
    settings = get_settings()
    # 同一个实例：TaskManager → DownloadWorker
    worker = DownloadWorkerAgent(_settings=settings)
    key = (id(settings),)
    mgr = getattr(_task_manager, "__instance__", None)
    if mgr is None or getattr(_task_manager, "__key__", None) != key:
        mgr = TaskManagerAgent(
            worker=worker,
            settings=settings,
            security=SecurityAgent(settings=settings),
            storage=StorageAgent(settings=settings, download_worker=worker),
        )
        _task_manager.__instance__ = mgr  # type: ignore[attr-defined]
        _task_manager.__key__ = key  # type: ignore[attr-defined]
    return mgr


TaskManagerDep = Annotated[TaskManagerAgent, Depends(_task_manager)]


# ---------- internal small helpers ----------

_SECURITY_ERROR_TO_HTTP: dict[type, tuple[int, str]] = {
    InvalidProtocol: (400, "INVALID_PROTOCOL"),
    SSRFBlocked: (403, "PRIVATE_IP_BLOCKED"),
    FileTooLarge: (413, "FILE_TOO_LARGE"),
    SecurityError: (400, "URL_VALIDATION_FAILED"),  # 兜底：UnreachableHost 等
}
# 保持别名
try:  # pragma: no cover - 兼容性：PrivateIP 是 SSRFBlocked 别名
    from agents.security_agent import PrivateIP as _PrivateIP, DNSRebinding as _DNSRebinding
    _SECURITY_ERROR_TO_HTTP.setdefault(_PrivateIP, (403, "PRIVATE_IP_BLOCKED"))
    _SECURITY_ERROR_TO_HTTP.setdefault(_DNSRebinding, (403, "DNS_REBINDING_BLOCKED"))
except ImportError:
    pass


def _task_to_response(t: Task, request: Request) -> TaskResponse:
    """ORM Task → Pydantic TaskResponse，含一次性 download_url（仅 completed 有值）。"""
    download_url: str | None = None
    if t.status == "completed" and t.storage_path and t.download_token:
        # <download_dir>/<task_id>/<filename> → /downloads/<task_id>/<filename>?token=<tok>
        sp = Path(t.storage_path)
        rel = sp.as_posix()
        # storage_path 一般形如 "<task_id>/<filename>"
        parts = rel.split("/", 1)
        safe_tid = parts[0] or t.id
        safe_rest = parts[1] if len(parts) == 2 else Path(t.storage_path).name
        base = str(request.base_url).rstrip("/")
        download_url = f"{base}/downloads/{safe_tid}/{safe_rest}?token={t.download_token}"

    return TaskResponse.model_validate(
        {
            **{c.name: getattr(t, c.name) for c in Task.__table__.columns},
            "expires_at": t.expires_at,
            "download_url": download_url,
        }
    )


# ---------- Routes ----------

@router.post("/api/tasks", response_model=TaskResponse, status_code=status.HTTP_201_CREATED)
async def create_task(body: CreateTaskRequest, request: Request, tm: TaskManagerDep) -> TaskResponse:
    """提交下载任务。

    流程：SecurityAgent 校验 URL → TaskManager.enqueue(插入 DB + queued) → 返回 201。
    Security 错误码：400 INVALID_PROTOCOL / 403 PRIVATE_IP_BLOCKED /
                     403 DNS_REBINDING_BLOCKED / 413 FILE_TOO_LARGE。"""
    url_str = str(body.source_url)
    try:
        task = await tm.enqueue(
            source_url=url_str,
            filename=body.filename,
        )
    except SecurityError as e:
        code = None
        http = 400
        # 按从最具体到最通用的异常类型匹配（Python MRO 顺序）
        for exc_cls, (c, title) in _SECURITY_ERROR_TO_HTTP.items():
            if isinstance(e, exc_cls):
                http = c
                code = title
                break
        if code is None:
            code = "URL_VALIDATION_FAILED"
            http = 400
        raise HTTPException(
            status_code=http,
            detail={"code": code, "message": str(e)},
        ) from e
    return _task_to_response(task, request)


@router.get("/api/tasks", response_model=ListTasksResponse)
async def list_tasks(
    request: Request,
    status_filter: Annotated[TaskStatus | None, Query(alias="status")] = None,
    limit: Annotated[int, Query(ge=1, le=500)] = 50,
) -> ListTasksResponse:
    """列出任务，可按 status 过滤，最多 limit 条（按 created_at desc）。"""
    async with scoped_session() as session:
        stmt = select(Task).order_by(Task.created_at.desc()).limit(limit)
        if status_filter:
            stmt = stmt.where(Task.status == status_filter)
        rows = (await session.execute(stmt)).scalars().all()
        return ListTasksResponse(items=[_task_to_response(t, request) for t in rows])


@router.get("/api/tasks/{task_id}", response_model=TaskResponse)
async def get_task(task_id: str, request: Request) -> TaskResponse:
    """按 task_id 查看单个任务。"""
    async with scoped_session() as session:
        t = await session.get(Task, task_id)
        if t is None:
            raise HTTPException(status_code=404, detail={"code": "TASK_NOT_FOUND"})
        return _task_to_response(t, request)


@router.delete("/api/tasks/{task_id}", response_model=TaskResponse)
async def cancel_or_delete_task(task_id: str, request: Request, tm: TaskManagerDep) -> TaskResponse:
    """取消任务：
    - queued → 直接改 status=failed(error="cancelled")
    - downloading → 调 aria2 remove + 改 failed("cancelled")
    - completed → 调 storage 清理 + status=expired（就等于删了文件）
    - 其他 → 保持不变返回
    """
    async with scoped_session() as session:
        t = await session.get(Task, task_id)
        if t is None:
            raise HTTPException(status_code=404, detail={"code": "TASK_NOT_FOUND"})
        prev = t.status
        if prev == "queued":
            t.status = "failed"
            t.error = "cancelled by user"
            if t.completed_at is None:
                t.completed_at = datetime.now(timezone.utc)
        elif prev == "downloading":
            if t.aria2_gid:
                try:
                    await tm._download_worker.remove(t.aria2_gid)
                except Exception as e:  # noqa: BLE001
                    log.warning("cancel aria2 gid=%s failed: %s", t.aria2_gid, e)
            t.status = "failed"
            t.error = "cancelled by user"
            if t.completed_at is None:
                t.completed_at = datetime.now(timezone.utc)
        elif prev == "completed":
            # 删除下载文件，保留记录标记 expired
            await tm.storage._purge_task_files(t)
            t.status = "expired"
            t.storage_path = None
        await session.commit()
        await session.refresh(t)
        return _task_to_response(t, request)


# ---------- 一次性下载直链 ----------

@router.get("/downloads/{task_id}/{filename:path}")
async def download_with_token(task_id: str, filename: str, token: str, request: Request):
    """一次性直链（§4.3.3）：校验 token + 过期时间，通过后流式返回文件。

    MVP FastAPI 直接 StreamingResponse；生产环境建议用 Nginx X-Accel-Redirect。
    """
    async with scoped_session() as session:
        t = await session.get(Task, task_id)
        if t is None:
            raise HTTPException(404, detail={"code": "TASK_NOT_FOUND"})
        if t.status != "completed" or not t.download_token:
            raise HTTPException(404, detail={"code": "DOWNLOAD_NOT_AVAILABLE"})
        # 1. Token 精确匹配（固定时长对比避免时序攻击，用 secrets.compare_digest）
        import secrets
        if not secrets.compare_digest(t.download_token, token):
            raise HTTPException(403, detail={"code": "BAD_TOKEN"})
        # 2. 过期检查
        now = datetime.now(timezone.utc)
        if t.download_token_expires_at and t.download_token_expires_at < now:
            raise HTTPException(410, detail={"code": "TOKEN_EXPIRED"})
        # 3. 实际文件定位（单任务目录约定）
        settings = get_settings()
        candidate = settings.download_dir_path / task_id / filename
        try:
            candidate_resolved = candidate.resolve()
        except OSError as e:
            raise HTTPException(500, detail={"code": "BAD_PATH", "msg": str(e)})
        # 防路径穿越：必须在 settings.download_dir_path 下
        try:
            candidate_resolved.relative_to(settings.download_dir_path)
        except ValueError:
            raise HTTPException(400, detail={"code": "PATH_TRAVERSAL"})
        if not candidate_resolved.is_file():
            raise HTTPException(404, detail={"code": "FILE_NOT_FOUND"})

        # 返回：大文件优先用 FileResponse（sendfile 系统调用），fallback StreamingResponse
        media_type, _ = mimetypes.guess_type(str(candidate_resolved))
        media_type = media_type or "application/octet-stream"
        try:
            return FileResponse(
                path=candidate_resolved,
                media_type=media_type,
                filename=os.path.basename(filename),
            )
        except Exception:  # pragma: no cover - 极端情况兜底
            def _iter():
                with candidate_resolved.open("rb") as fh:
                    while True:
                        chunk = fh.read(1024 * 256)
                        if not chunk:
                            break
                        yield chunk
            return StreamingResponse(
                _iter(),
                media_type=media_type,
                headers={
                    "Content-Disposition": f'attachment; filename="{os.path.basename(filename)}"'
                },
            )
