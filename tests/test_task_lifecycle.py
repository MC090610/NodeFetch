"""任务生命周期 TDD 测试。

测试对象：
    agents.download_worker_agent.DownloadWorkerAgent  （封装 Aria2，支持注入 FakeAria2 做测试）
    agents.task_manager_agent.TaskManagerAgent        （并发队列 + 状态推进）

状态机链路：queued → downloading → completed / failed
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest

pytestmark = pytest.mark.asyncio


async def _make_new_task(session_factory, url: str = "https://example.com/f.zip", **extra):
    """DB 里直接插一条 queued 任务，返回 task_id。"""
    from models.database import scoped_session
    from models.task import Task

    async with session_factory() as session:
        task = Task(
            id=uuid.uuid4().hex[:6].lower(),
            source_url=url,
            status="queued",
            **extra,
        )
        session.add(task)
        await session.flush()
        tid = task.id
    return tid


async def _get_task(session_factory, task_id: str):
    from models.database import scoped_session
    from models.task import Task

    async with session_factory() as session:
        return await session.get(Task, task_id)


# ---------------------------------------------------------------------------
# 1. DownloadWorkerAgent：用 FakeAria2（注入）模拟 Aria2 响应
# ---------------------------------------------------------------------------
class TestDownloadWorkerAgent:
    async def test_start_returns_gid_and_tellstatus_updates_progress(self, in_memory_db):
        from agents.download_worker_agent import DownloadWorkerAgent
        from models.database import scoped_session

        fake = _FakeAria2()
        worker = DownloadWorkerAgent(_aria2=fake)

        gid = await worker.start_download(
            "https://example.com/f.zip", download_dir=str(Path("./tmp/t1"))
        )
        assert gid is not None
        # Fake 初始状态：active, 1GB 文件, 已下载 1/3
        fake.set_progress(gid, status="active", total=1024**3, completed=1024**3 // 3, speed=10 * 1024**2)
        s = await worker.get_status(gid)
        assert s["status"] == "downloading"
        assert s["total_size"] == 1024**3
        assert s["downloaded_size"] == 1024**3 // 3
        assert s["speed"] == 10 * 1024**2

    async def test_remove_cancels_download(self, in_memory_db):
        from agents.download_worker_agent import DownloadWorkerAgent

        fake = _FakeAria2()
        worker = DownloadWorkerAgent(_aria2=fake)
        gid = await worker.start_download("https://example.com/f.zip", download_dir="./tmp")

        await worker.remove(gid)
        # Fake 的 remove 会把 gid 放到 removed 列表里
        assert gid in fake.removed_gids


# ---------------------------------------------------------------------------
# 2. TaskManagerAgent：并发控制（CONCURRENT_LIMIT=2）+ queued→downloading→completed 推进
# ---------------------------------------------------------------------------
class TestTaskManagerAgent:
    async def test_3_tasks_concurrent_2_third_stays_queued(self, in_memory_db, tmp_path, monkeypatch):
        from agents.task_manager_agent import TaskManagerAgent
        from agents.download_worker_agent import DownloadWorkerAgent
        from config import Settings

        fake = _FakeAria2(auto_set_progress_on_add="active-downloading")
        worker = DownloadWorkerAgent(_aria2=fake)
        settings = Settings(
            _env_file=None,
            NODE_ID="x", NODE_NAME="x", REGION="X", VERSION="1.0.0",
            DB_URL="sqlite+aiosqlite:///:memory:",
            ARIA2_RPC_URL="", ARIA2_RPC_SECRET="",
            DOWNLOAD_DIR=str(tmp_path), STORAGE_LIMIT_GB=10, MAX_FILE_SIZE_GB=10,
            CONCURRENT_LIMIT=2, TTL_MINUTES=60,
        )
        mgr = TaskManagerAgent(worker, settings)

        tid1 = await _make_new_task(lambda: _scoped_session_ctx())
        tid2 = await _make_new_task(lambda: _scoped_session_ctx())
        tid3 = await _make_new_task(lambda: _scoped_session_ctx())

        # 首次 tick：前两个进入 downloading，第三个保持 queued
        await mgr.tick_once()
        from models.database import scoped_session

        async with scoped_session() as s:
            t1 = await s.get(__import__("models.task", fromlist=["Task"]).Task, tid1)
            t2 = await s.get(__import__("models.task", fromlist=["Task"]).Task, tid2)
            t3 = await s.get(__import__("models.task", fromlist=["Task"]).Task, tid3)
            assert t1.status == "downloading" and t1.aria2_gid is not None
            assert t2.status == "downloading" and t2.aria2_gid is not None
            assert t3.status == "queued" and t3.aria2_gid is None

        # 让 task1 complete（Fake 的 fake.complete(gid)）→ 再 tick → task3 变成 downloading
        fake.complete(t1.aria2_gid)
        await mgr.tick_once()
        async with scoped_session() as s:
            t1 = await s.get(__import__("models.task", fromlist=["Task"]).Task, tid1)
            t3 = await s.get(__import__("models.task", fromlist=["Task"]).Task, tid3)
            assert t1.status == "completed"
            assert t1.completed_at is not None
            assert t3.status == "downloading"

    async def test_aria2_error_marks_task_failed(self, in_memory_db, tmp_path):
        from agents.task_manager_agent import TaskManagerAgent
        from agents.download_worker_agent import DownloadWorkerAgent
        from models.database import scoped_session
        from models.task import Task
        from config import Settings

        fake = _FakeAria2(auto_set_progress_on_add="active-downloading")
        worker = DownloadWorkerAgent(_aria2=fake)
        settings = Settings(
            _env_file=None, NODE_ID="x", NODE_NAME="x", REGION="X", VERSION="1.0.0",
            DB_URL="sqlite+aiosqlite:///:memory:",
            ARIA2_RPC_URL="", ARIA2_RPC_SECRET="",
            DOWNLOAD_DIR=str(tmp_path), STORAGE_LIMIT_GB=10, MAX_FILE_SIZE_GB=10,
            CONCURRENT_LIMIT=2, TTL_MINUTES=60,
        )
        mgr = TaskManagerAgent(worker, settings)

        tid = await _make_new_task(lambda: _scoped_session_ctx())
        await mgr.tick_once()
        # get aria2_gid
        async with scoped_session() as s:
            task = await s.get(Task, tid)
            gid = task.aria2_gid

        # 标记 Aria2 出错并写 error
        fake.set_progress(gid, status="error", total=1024, completed=128, speed=0, error_msg="timeout connecting")
        await mgr.tick_once()
        async with scoped_session() as s:
            task = await s.get(Task, tid)
            assert task.status == "failed"
            assert "timeout" in (task.error or "")


# ---------------------------------------------------------------------------
# Helper：Scoped session 直接给 _make_new_task 用（in_memory_db fixture 已经切换了引擎）
# ---------------------------------------------------------------------------
from contextlib import asynccontextmanager


@asynccontextmanager
async def _scoped_session_ctx():
    """因为 TestTaskManagerAgent 的参数里直接写 scoped_session lambda，这里提供一个。"""
    from models.database import scoped_session
    async with scoped_session() as s:
        yield s


# ---------------------------------------------------------------------------
# Fake Aria2：实现 addUri / tellStatus / remove 三个方法，全内存模拟。
# ---------------------------------------------------------------------------
class _FakeAria2:
    def __init__(self, auto_set_progress_on_add: str | None = None):
        self._tasks: dict[str, dict] = {}  # gid -> status dict
        self._next_gid = 0
        self.removed_gids: list[str] = []
        self._auto_mode = auto_set_progress_on_add

    async def addUri(self, urls, options=None):
        import string
        self._next_gid += 1
        gid = f"fake-gid-{self._next_gid:04d}"
        d = {
            "status": "waiting",
            "totalLength": "0",
            "completedLength": "0",
            "downloadSpeed": "0",
            "errorMessage": "",
            "files": [{"uris": [{"uri": urls[0] if urls else ""}], "path": options.get("dir", "") if options else ""}],
        }
        if self._auto_mode == "active-downloading":
            d["status"] = "active"
            d["totalLength"] = str(1024 * 1024)
            d["completedLength"] = "0"
            d["downloadSpeed"] = str(1024 * 1024)
        self._tasks[gid] = d
        return gid

    async def tellStatus(self, gid):
        if gid not in self._tasks:
            raise KeyError(f"gid {gid} not found")
        return self._tasks[gid].copy()

    async def removeDownloadResult(self, gid):
        # aria2 语义：先 forceRemove（如果活动）再 removeDownloadResult
        self.removed_gids.append(gid)
        self._tasks.pop(gid, None)
        return "OK"

    # ---- helper API（测试用，非 aria2 真实 API）----
    def set_progress(
        self,
        gid: str,
        *,
        status: str,                # "active" / "complete" / "error"
        total: int,
        completed: int,
        speed: int,
        error_msg: str = "",
    ) -> None:
        if gid not in self._tasks:
            raise KeyError(gid)
        aria2_status = {
            "downloading": "active",
            "active-downloading": "active",
            "completed": "complete",
            "error": "error",
            "failed": "error",
        }.get(status, status)
        self._tasks[gid]["status"] = aria2_status
        self._tasks[gid]["totalLength"] = str(total)
        self._tasks[gid]["completedLength"] = str(completed)
        self._tasks[gid]["downloadSpeed"] = str(speed)
        self._tasks[gid]["errorMessage"] = error_msg

    def complete(self, gid: str) -> None:
        d = self._tasks[gid]
        total = int(d.get("totalLength") or "0") or 1024 * 1024
        self.set_progress(gid, status="complete", total=total, completed=total, speed=0)
