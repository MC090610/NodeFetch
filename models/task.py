"""Task 数据库模型。

严格对齐 Agent.md §4.2 的 Response 字段，外加一次性下载 token（用于 Nginx auth_request）。
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from secrets import token_urlsafe

from sqlalchemy import BigInteger, DateTime, String, func
from sqlalchemy.orm import Mapped, mapped_column

from config import get_settings
from models.database import Base


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _shortid() -> str:
    """6 字节 → 8 个 base64url 字符；够用且可复制。

    碰撞概率：2^48 空间，1M 任务 ≈ 10^-6。够用。"""
    return uuid.uuid4().hex[:8]


class Task(Base):
    __tablename__ = "tasks"

    # --- 主键 ---
    id: Mapped[str] = mapped_column(String(16), primary_key=True, default=_shortid)

    # --- 请求来源 ---
    source_url: Mapped[str] = mapped_column(String(2048), index=False)
    filename: Mapped[str | None] = mapped_column(String(512), default=None)

    # --- 状态机 ---
    # queued: 等待调度
    # downloading: aria2 正在下载
    # completed: 正常完成，文件存在可下载
    # failed: aria2 返回 error
    # expired: 完成过但被 StorageAgent 清理了（文件已删，只留记录做审计）
    # cancelled_by_storage: 因配额/存储问题下载中被强行取消
    status: Mapped[str] = mapped_column(String(32), default="queued", index=True)
    error: Mapped[str | None] = mapped_column(String(1024), default=None)

    # --- 磁盘位置（相对 Settings.download_dir 的路径，例：<task_id>/<filename>）---
    storage_path: Mapped[str | None] = mapped_column(String(2048), default=None)

    # --- 进度 ---
    total_size: Mapped[int | None] = mapped_column(BigInteger, default=None)       # bytes
    downloaded_size: Mapped[int] = mapped_column(BigInteger, default=0)            # bytes
    speed: Mapped[int] = mapped_column(BigInteger, default=0)                      # bytes/s

    # --- Aria2 绑定 ---
    aria2_gid: Mapped[str | None] = mapped_column(String(64), default=None, index=True)

    # --- 一次性下载凭证（用于 /downloads/{task_id}/{filename}?token=xxx）---
    download_token: Mapped[str] = mapped_column(String(64), default=lambda: token_urlsafe(32))
    download_token_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)

    # --- 时间 ---
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now_utc, server_default=func.now()
    )
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)

    @property
    def expires_at(self) -> datetime | None:
        """对外返回 completed_at + TTL 组成的过期时间（未完成则 None）。"""
        if self.completed_at is None:
            return None
        return self.completed_at + timedelta(minutes=get_settings().ttl_minutes)

    def mark_completed(self, now: datetime | None = None) -> None:
        now = now or _now_utc()
        self.completed_at = now
        self.status = "completed"
        # 一次性 token 过期时间 = 完成时间 + TTL
        self.download_token_expires_at = self.expires_at

    def mark_failed(self, error: str, now: datetime | None = None) -> None:
        self.status = "failed"
        self.error = (error[:1000] + "…") if len(error) > 1024 else error
        if self.completed_at is None:
            self.completed_at = now or _now_utc()

    def mark_started(self, now: datetime | None = None) -> None:
        self.status = "downloading"
        if self.started_at is None:
            self.started_at = now or _now_utc()
