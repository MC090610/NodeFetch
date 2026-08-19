"""阶段①-5：StorageAgent TDD。

MVP 约定：每个任务的下载文件都在 `<download_dir>/<task_id>/` 单任务目录下。
storage_path 存的是相对 download_dir 的路径（例：<task_id>/foo.bin）。
StorageAgent 清理时，直接删 `<download_dir>/<task_id>/` 整个目录即可。
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from sqlalchemy import select


async def _make_task_with_files(
    session_factory,
    tmp_download_dir: Path,
    *,
    status: str,
    total_size: int,
    file_bytes: bytes | None = None,
    completed_minutes_ago: int | None = None,
) -> str:
    """创建一个任务：
    - 建目录 <download_dir>/<task_id>/
    - 放一个 foo.bin（大小 = total_size，用 file_bytes 或 \\0 填充）
    - DB 写 storage_path=<task_id>/foo.bin
    返回 task_id。"""
    from models.task import Task

    async with session_factory() as session:
        now = datetime.now(timezone.utc)
        t = Task(
            source_url="https://example.com/foo.zip",
            status=status,
            total_size=total_size,
            downloaded_size=total_size if status in ("completed", "failed", "expired") else 0,
        )
        if completed_minutes_ago is not None:
            t.status = "completed"
            t.completed_at = now - timedelta(minutes=completed_minutes_ago)
            t.started_at = t.completed_at - timedelta(seconds=5)
        session.add(t)
        await session.flush()  # 拿到 t.id
        # 建任务目录 + 文件
        task_dir = tmp_download_dir / t.id
        task_dir.mkdir(parents=True, exist_ok=True)
        binfile = task_dir / "foo.bin"
        if file_bytes is not None:
            binfile.write_bytes(file_bytes)
        else:
            # 用 seek + write 做 sparse 文件（省时间）
            with binfile.open("wb") as fh:
                if total_size > 0:
                    fh.seek(total_size - 1)
                    fh.write(b"\0")
        t.storage_path = f"{t.id}/foo.bin"
        await session.commit()
        await session.refresh(t)
        return str(t.id)


@pytest.mark.asyncio
class TestStorageAgentTTL:
    async def test_cleanup_expired_marks_expired_and_removes_files(
        self, in_memory_db, tmp_download_dir: Path
    ):
        """过期完成任务：status→expired，目录被真的递归删除；没过期/未完成不碰。"""
        from agents.storage_agent import StorageAgent
        from config import get_settings
        from models.database import scoped_session
        from models.task import Task

        s = get_settings()
        exp_id = await _make_task_with_files(
            scoped_session, tmp_download_dir,
            status="completed", total_size=1024,
            completed_minutes_ago=s.ttl_minutes + 5,
        )
        fresh_id = await _make_task_with_files(
            scoped_session, tmp_download_dir,
            status="completed", total_size=1024,
            completed_minutes_ago=0,
        )
        queued_id = await _make_task_with_files(
            scoped_session, tmp_download_dir,
            status="queued", total_size=0,
        )

        agent = StorageAgent()
        removed_count = await agent.cleanup_expired()
        assert removed_count >= 1

        # DB 校验
        async with scoped_session() as session:
            rows = (await session.execute(
                select(Task).where(Task.id.in_([exp_id, fresh_id, queued_id]))
            )).scalars().all()
            by_id = {t.id: t for t in rows}
            assert by_id[exp_id].status == "expired"
            assert by_id[exp_id].storage_path in (None, "")
            assert by_id[fresh_id].status == "completed"
            assert by_id[queued_id].status == "queued"

        # 文件校验
        assert not (tmp_download_dir / exp_id).exists(), "过期任务目录被删"
        assert (tmp_download_dir / fresh_id / "foo.bin").is_file(), "未过期的保留"
        assert (tmp_download_dir / queued_id / "foo.bin").is_file(), "queued 不碰"

    async def test_enforce_quota_deletes_oldest_completed_first(
        self, in_memory_db, tmp_download_dir: Path
    ):
        """STORAGE_LIMIT_GB=1，放 3 个 400MB 完成任务 → 超配额，先删最老的 completed_at 最前的。"""
        from agents.storage_agent import StorageAgent
        from models.database import scoped_session
        from models.task import Task

        MB = 1024 * 1024
        size_each = 400 * MB
        order = []
        for i in range(3):
            # 30min / 20min / 10min 前完成 → [0] 最老
            tid = await _make_task_with_files(
                scoped_session, tmp_download_dir,
                status="completed",
                total_size=size_each,
                completed_minutes_ago=(30 - i * 10),
            )
            order.append(tid)

        agent = StorageAgent()
        freed = await agent.enforce_quota()
        assert freed >= 1, f"超配额应该至少删 1 个，实际 {freed}"

        async with scoped_session() as session:
            rows = (await session.execute(
                select(Task).where(Task.id.in_(order))
            )).scalars().all()
            by_id = {t.id: t for t in rows}
            oldest = order[0]
            assert by_id[oldest].status == "expired", "最老的应先被清理"
            assert not (tmp_download_dir / oldest).exists(), "最老的目录被删"
            still_completed = [tid for tid in order if by_id[tid].status == "completed"]
            assert len(still_completed) >= 1, "没超配额的应保持 completed"
