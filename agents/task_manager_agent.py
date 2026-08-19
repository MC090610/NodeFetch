"""TaskManagerAgent — 并发队列控制器（Agent.md §3.2 内部子 Agent）。

职责：
    1. 维持并发下载槽位（默认 CONCURRENT_LIMIT=2）
    2. 每次 tick_once()：
       a. 从 DB 取当前正在 downloading 的任务，通过 DownloadWorkerAgent.get_status(gid) 同步进度到 DB
       b. 如果任务 completed / failed，更新 DB 状态、释放槽位、记录 completed_at / error
       c. 从 DB 取最老的 queued 任务，若有空槽位则调用 DownloadWorkerAgent.start_download，写入 aria2_gid 并改为 downloading（记录 started_at）

对外只暴露 tick_once()，由外部定时器（APScheduler 或 main.py lifespan）调用。
测试里手动 tick_once() 控制时序。
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Iterable

from sqlalchemy import select

from config import Settings, get_settings
from models.database import AsyncSessionLocal, scoped_session
from models.task import Task

from agents.download_worker_agent import DownloadWorkerAgent
from agents.security_agent import SecurityAgent
from agents.storage_agent import StorageAgent

log = logging.getLogger(__name__)


class TaskManagerAgent:
    def __init__(
        self,
        worker: DownloadWorkerAgent | None = None,
        settings: Settings | None = None,
        *,
        # keyword-only aliases (routes pass these names)
        download_worker: DownloadWorkerAgent | None = None,
        security: SecurityAgent | None = None,
        storage: StorageAgent | None = None,
    ) -> None:
        self._worker: DownloadWorkerAgent = worker or download_worker or DownloadWorkerAgent(settings=settings)
        self._settings = settings or get_settings()
        self._security = security or SecurityAgent(settings=self._settings)
        self._storage = storage or StorageAgent(settings=self._settings, download_worker=self._worker)

    # 与 route 里访问 tm._download_worker / tm._storage 的用法兼容。
    @property
    def _download_worker(self) -> DownloadWorkerAgent:
        return self._worker

    @property
    def storage(self) -> StorageAgent:
        return self._storage

    # ------------------------------------------------------------------
    # 对外：创建任务
    # ------------------------------------------------------------------
    async def enqueue(self, source_url: str, filename: str | None = None) -> Task:
        """创建 queued 任务。
        1) SecurityAgent.validate_url：可能抛 InvalidProtocol/PrivateIP/DNSRebinding/FileTooLarge
        2) 建 task_dir = <download_dir>/<task_id>/，mkdir -p
        3) 插入 DB：status=queued，storage_path 先填 ""（等下载启动后由 DownloadWorker 决定具体 filename）
        Returns:
            已 commit 并带 id 的 Task 对象。"""
        # 1) 校验（含 HEAD 探测文件大小）
        await self._security.validate_url(source_url, _settings=self._settings)

        # 2) sanitize filename（只允许 basename，去掉目录分隔符）
        clean_name = self._safe_filename(filename) if filename else None

        async with scoped_session() as s:
            t = Task(source_url=source_url, filename=clean_name, status="queued")
            s.add(t)
            await s.flush()  # 拿到 t.id
            # 预留 task 目录
            task_dir = self._task_dir(t.id)
            try:
                task_dir.mkdir(parents=True, exist_ok=True)
            except OSError:
                pass
            await s.commit()
            await s.refresh(t)
            return t

    # ------------------------------------------------------------------
    # 主入口：一个 tick
    # ------------------------------------------------------------------
    async def tick_once(self) -> None:
        # 1) 先同步 downloading 任务状态 -> 可能释放槽位
        await self._sync_downloading_tasks()
        # 2) 填满槽位直到并发上限
        await self._fill_queued_tasks()

    # ------------------------------------------------------------------
    # Step 1：同步所有正在下载的任务
    # ------------------------------------------------------------------
    async def _sync_downloading_tasks(self) -> None:
        async with scoped_session() as s:
            stmt = select(Task).where(Task.status.in_(["downloading", "queued"]))
            stmt = stmt.where(Task.aria2_gid.is_not(None))  # type: ignore[attr-defined]
            tasks: Iterable[Task] = list((await s.execute(stmt)).scalars())
            changed_any = False
            for t in tasks:
                try:
                    st = await self._worker.get_status(t.aria2_gid)
                except Exception as e:  # noqa: BLE001
                    # gid 不存在（aria2 重启或之前已经删了）：如果状态是 downloading 且 aria2_gid 有值，
                    # 多半是 aria2 崩了重启后丢了记录，标 failed
                    log.warning("aria2 tellStatus failed for task %s (gid=%s): %s", t.id, t.aria2_gid, e)
                    if t.status == "downloading":
                        t.mark_failed(f"aria2 lost track: {e}")
                        changed_any = True
                    continue

                # --- 进度写回 ---
                t.downloaded_size = st["downloaded_size"]
                t.speed = st["speed"]
                if st["total_size"]:
                    t.total_size = st["total_size"]
                if st["filename"] and not t.filename:
                    t.filename = st["filename"]

                new_status = st["status"]
                # 非终态 -> queued / downloading 同步
                if new_status == "queued" and t.status == "queued":
                    continue
                if new_status == "downloading":
                    if t.status != "downloading":
                        t.mark_started()
                        changed_any = True
                    continue
                # 终态
                if new_status == "completed":
                    t.downloaded_size = t.total_size or t.downloaded_size
                    t.speed = 0
                    t.mark_completed()
                    # 下载完成：记录 storage_path（单任务目录约定）。filename 如果是
                    # aria2 tellStatus 刚回填的，也能拿到。
                    final_name = t.filename or st["filename"] or "download.bin"
                    t.storage_path = f"{t.id}/{final_name}"
                    changed_any = True
                elif new_status == "failed":
                    t.mark_failed(st["error_message"] or "Unknown aria2 error")
                    changed_any = True
            if changed_any:
                await s.commit()

    # ------------------------------------------------------------------
    # Step 2：用 queued 任务填满当前可用槽位（严格并发上限）
    # ------------------------------------------------------------------
    async def _fill_queued_tasks(self) -> None:
        async with scoped_session() as s:
            # 当前正在下载的数量
            downloading_count_sq = (
                select(Task.id).where(Task.status == "downloading")
            )
            downloading_count = len(list((await s.execute(downloading_count_sq)).scalars()))
            slots = max(0, self._settings.concurrent_limit - downloading_count)
            if slots == 0:
                return

            # 最早的 queued 任务（按 created_at）
            queued_q = (
                select(Task)
                .where(Task.status == "queued")
                .order_by(Task.created_at.asc())
                .limit(slots)
            )
            picked = list((await s.execute(queued_q)).scalars())

            changed = False
            for t in picked:
                task_dir = self._task_dir(t.id)
                task_dir.mkdir(parents=True, exist_ok=True)
                try:
                    gid = await self._worker.start_download(
                        t.source_url,
                        download_dir=str(task_dir),
                        out_filename=t.filename,
                    )
                except Exception as e:  # noqa: BLE001
                    log.exception("start_download failed for task %s", t.id)
                    t.mark_failed(str(e))
                    changed = True
                    continue
                t.aria2_gid = gid
                t.mark_started()
                changed = True
            if changed:
                await s.commit()

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    def _task_dir(self, task_id: str) -> Path:
        return Path(self._settings.download_dir).expanduser().resolve() / task_id

    @staticmethod
    def _safe_filename(name: str) -> str:
        """保留 basename，去掉路径分隔符与 .gitignore 级的危险字符。"""
        import re
        # 去掉所有路径分隔符
        name = name.replace("\\", "/")
        name = name.rstrip("/").rsplit("/", 1)[-1]
        # 禁止以点开头（隐藏文件），禁止 NUL/控制字符
        name = name.lstrip(".") or "unnamed"
        name = re.sub(r"[\x00-\x1f]", "_", name)
        # 太长截断（Task.filename 字段 512）
        return name[:480] or "unnamed"
