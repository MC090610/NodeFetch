"""pytest fixtures。

运行方式：
    cd node-agent
    python -m pytest tests/
本 conftest 会把 node-agent 目录加入 sys.path，代码里就可以直接 `import config / models / agents / api`。
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import pytest
import pytest_asyncio

# --- 把 node-agent 根目录加入 sys.path，这样直接 import 不带前缀 ---
NODE_AGENT_ROOT = Path(__file__).resolve().parents[1]
if str(NODE_AGENT_ROOT) not in sys.path:
    sys.path.insert(0, str(NODE_AGENT_ROOT))


def _choose_policy() -> asyncio.AbstractEventLoopPolicy:
    """Windows 上默认用 Proactor（支持 subprocess/pipe）；其他平台退回默认。"""
    try:
        # 某些精简 win32 没有 WindowsProactorEventLoopPolicy
        return asyncio.WindowsProactorEventLoopPolicy()  # type: ignore[attr-defined]
    except AttributeError:
        return asyncio.DefaultEventLoopPolicy()


# 在全局先做一次 policy 设置（pytest-asyncio 外手动跑的代码也能用）
asyncio.set_event_loop_policy(_choose_policy())


@pytest.fixture(scope="session")
def event_loop_policy():
    """pytest-asyncio 事件循环策略（session 范围，每个 session 初始化一次 policy）。"""
    return _choose_policy()


# ---------- 关键：pytest-asyncio 0.24+ strict 模式 ----------
# async fixture 必须使用 pytest_asyncio.fixture（或显式 loop=f...）。
# 否则 bare `@pytest.fixture async def` 的 fixture 很可能**根本不被执行**，
# 直接 yield 一个被遗忘的协程对象。在我们这里会导致 set_engine/init_db 没跑，
# 然后业务代码使用默认引擎 → "no such table: tasks"。
@pytest_asyncio.fixture(scope="function")
async def in_memory_db(tmp_path: Path):
    """每个测试一个独立的 SQLite（用临时文件，避免 aiosqlite :memory: 多连接各自独立的坑）。"""
    from models.database import (
        Base,
        get_engine,
        init_db,
        set_engine_for_tests,
    )

    db_file = tmp_path / "test.sqlite3"
    db_url = f"sqlite+aiosqlite:///{db_file.as_posix()}"
    set_engine_for_tests(db_url)
    await init_db()
    try:
        yield  # 测试代码体在这里运行
    finally:
        engine = get_engine()
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
        await engine.dispose()
        try:
            db_file.unlink(missing_ok=True)
        except OSError:
            pass


@pytest.fixture()
def tmp_download_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """临时下载目录，并让 Settings 指向它（清掉 lru_cache 重新构造）。

    NOTE: 严禁 importlib.reload(config) — 它会制造新模块对象，而其他模块里
    `from config import get_settings` 已经绑定到旧模块对象，导致 cache_clear 无效。
    只做 monkeypatch + 清 lru_cache，保证全进程用同一个 get_settings 函数。"""
    d = tmp_path / "downloads"
    d.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("DOWNLOAD_DIR", str(d))
    monkeypatch.setenv("STORAGE_LIMIT_GB", "1")
    monkeypatch.setenv("MAX_FILE_SIZE_GB", "1")
    monkeypatch.setenv("TTL_MINUTES", "2")

    import config as cfg_mod
    cfg_mod.get_settings.cache_clear()
    _ = cfg_mod.get_settings()
    return d
