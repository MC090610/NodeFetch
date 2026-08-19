"""数据库连接（SQLAlchemy async）。"""
from __future__ import annotations

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from config import get_settings


class Base(DeclarativeBase):
    pass


_settings = get_settings()


def _build_engine(db_url: str | None = None) -> AsyncEngine:
    url = db_url or _settings.db_url
    connect_args = {"check_same_thread": False} if url.startswith("sqlite") else {}
    return create_async_engine(url, future=True, echo=False, connect_args=connect_args)


_engine: AsyncEngine = _build_engine()
AsyncSessionLocal: async_sessionmaker[AsyncSession] = async_sessionmaker(
    bind=_engine, class_=AsyncSession, expire_on_commit=False, autoflush=False
)


def get_engine() -> AsyncEngine:
    return _engine


def set_engine_for_tests(db_url: str) -> None:
    """测试用：替换为内存数据库引擎 + 重新建表。"""
    global _engine, AsyncSessionLocal  # noqa: PLW0603
    _engine = _build_engine(db_url)
    AsyncSessionLocal = async_sessionmaker(
        bind=_engine, class_=AsyncSession, expire_on_commit=False, autoflush=False
    )


@asynccontextmanager
async def scoped_session() -> AsyncGenerator[AsyncSession, None]:
    """显式事务管理的短会话（Agent 内部直接用这个）。"""
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


async def init_db() -> None:
    """启动时建表（幂等）。"""
    # 导入所有模型，确保 metadata 被注册
    from models import task as _task_model  # noqa: F401

    async with _engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
