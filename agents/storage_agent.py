"""StorageAgent：TTL 清理 + 磁盘配额治理。

跟 Agent.md §3.3 对齐：
1. cleanup_expired()：删除 `completed_at + TTL < now` 的任务 → 递归删除 storage_path
   所属目录（一般是 `<download_dir>/<task_id>/`）→ DB status 设为 expired，storage_path 清空。
2. enforce_quota()：枚举所有 completed（且 storage_path 非空）任务，按 completed_at 升序
   （即先完成先删）累加占用，直到总量 ≤ storage_limit_gb；超出部分依次清理。
3. 清理文件前，如果任务还在 downloading → 通知 DownloadWorkerAgent 取消该任务再删目录。
"""
from __future__ import annotations

import logging
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING

from sqlalchemy import select

from config import get_settings
from models.database import scoped_session
from models.task import Task

if TYPE_CHECKING:  # 避免循环 import
    from agents.download_worker_agent import DownloadWorkerAgent

log = logging.getLogger(__name__)


class StorageAgent:
    """磁盘 + TTL 管理 Agent。无共享状态（每次从 DB/FS 读取）。"""

    def __init__(
        self,
        settings=None,
        download_worker: "DownloadWorkerAgent | None" = None,
    ) -> None:
        self._settings = settings or get_settings()
        self._download_worker = download_worker
        self._download_dir: Path = Path(self._settings.download_dir).expanduser().resolve()

    # ---------- public API ----------

    async def cleanup_expired(self) -> int:
        """扫描 DB，删除所有 status=completed 且 (completed_at + TTL) < now 的任务。

        Returns:
            实际清理的任务数。
        """
        now = datetime.now(timezone.utc)
        cutoff = now - __import__("datetime").timedelta(minutes=self._settings.ttl_minutes)
        async with scoped_session() as session:
            stmt = select(Task).where(
                Task.status == "completed",
                Task.completed_at.is_not(None),
                Task.completed_at < cutoff,
            )
            rows = (await session.execute(stmt)).scalars().all()
            count = 0
            for t in rows:
                ok = await self._purge_task_files(t)
                t.status = "expired"
                t.storage_path = None
                count += 1 if ok else 0
            await session.commit()
            return count

    async def enforce_quota(self) -> int:
        """按 STORAGE_LIMIT_GB 强制回收磁盘：先删最早完成的任务文件。

        Returns:
            被清理掉的任务数量（标记为 expired）。
        """
        limit_bytes = self._settings.storage_limit_gb * (1024**3)
        # 计算当前 completed 且已有 storage_path 的任务总大小
        async with scoped_session() as session:
            stmt = (
                select(Task)
                .where(
                    Task.status == "completed",
                    Task.storage_path.is_not(None),
                    Task.storage_path != "",
                )
                .order_by(Task.completed_at.asc().nullslast())
            )
            rows = (await session.execute(stmt)).scalars().all()

        # 预计算总大小（优先用 DB.total_size，不精确但足够；文件系统 stat 代价高）
        def _sz(t: Task) -> int:
            if t.total_size and t.total_size > 0:
                return int(t.total_size)
            # DB 没写总大小，用 storage_path 实际文件大小
            p = self._abs_storage_path(t)
            try:
                if p.is_file():
                    return p.stat().st_size
                if p.is_dir():
                    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
            except OSError:
                return 0
            return 0

        sizes = [(t, _sz(t)) for t in rows]
        total = sum(sz for _, sz in sizes)
        if total <= limit_bytes:
            return 0

        # 需要回收多少
        need_free = total - limit_bytes
        freed_count = 0
        freed_bytes = 0
        async with scoped_session() as session:
            for t, sz in sizes:
                if freed_bytes >= need_free:
                    break
                # 重新 attach 到 session（上面的 session 已关闭）
                same = await session.get(Task, t.id)
                if same is None or same.status != "completed":
                    continue
                ok = await self._purge_task_files(same)
                same.status = "expired"
                same.storage_path = None
                if ok:
                    freed_count += 1
                    freed_bytes += sz
            await session.commit()
        return freed_count

    # ---------- internal helpers ----------

    def _abs_storage_path(self, t: Task) -> Path:
        """storage_path 为空时 fallback 到 `<download_dir>/<task.id>/` 老目录。"""
        if t.storage_path:
            p = Path(t.storage_path)
            if not p.is_absolute():
                p = self._download_dir / p
            return p
        return self._download_dir / str(t.id)

    async def _purge_task_files(self, t: Task) -> bool:
        """删除任务的存储目录（单任务目录结构，默认 `<download_dir>/<task_id>/`）。

        若任务还在 downloading，会先调 DownloadWorkerAgent 取消 aria2 任务。
        返回 True 表示实际执行了删除动作（或路径本来就不存在）。"""
        # 1. 先取消 aria2（还在跑则停掉）
        if t.status == "downloading" and self._download_worker and t.aria2_gid:
            try:
                await self._download_worker.remove(t.aria2_gid)
            except Exception as e:  # noqa: BLE001 - aria2 cancel 失败也继续删文件
                log.warning("cancel aria2 gid=%s for task %s failed: %s", t.aria2_gid, t.id, e)

        # 2. 删整个 task 目录：默认 download_dir/<task_id>/
        task_dir = self._download_dir / str(t.id)
        deleted = False
        try:
            if task_dir.exists():
                shutil.rmtree(task_dir, ignore_errors=True)
                deleted = True
        except OSError as e:
            log.warning("remove task dir %s failed: %s", task_dir, e)

        # 3. 兼容：storage_path 指向的具体文件（如果不在 task_dir 里）也删掉
        abs_sp = self._abs_storage_path(t)
        if abs_sp.exists() and abs_sp.parent != task_dir:
            try:
                if abs_sp.is_dir():
                    shutil.rmtree(abs_sp, ignore_errors=True)
                else:
                    abs_sp.unlink(missing_ok=True)
                deleted = True
            except OSError as e:
                log.warning("remove storage_path %s failed: %s", abs_sp, e)
        return deleted
