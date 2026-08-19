"""Pydantic DTOs（严格对齐 Agent.md §4.2）。"""
from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


TaskStatus = Literal[
    "queued",
    "downloading",
    "completed",
    "failed",
    "expired",
    "cancelled_by_storage",
]


# ---------- Requests ----------

class CreateTaskRequest(BaseModel):
    """POST /api/tasks request body（§4.2.1）。

    NOTE: 此处 source_url 不用 pydantic HttpUrl 类型，因为 Pydantic 会用自己的错误码
    （422 + url_scheme/...）把非法协议/URL 拦掉，无法返回 Agent.md 约定的
    {code: INVALID_PROTOCOL, message: "..."} 统一安全错误契约。SecurityAgent 会自己
    做协议/URL 格式验证并返回 400+code。"""
    source_url: str = Field(..., description="Only http/https allowed. Private IP blocked by SecurityAgent.")
    filename: str | None = Field(
        default=None,
        description="Override final filename (only basename, no directory).",
        max_length=512,
    )
    node_id: str | None = Field(
        default=None,
        description="Optional preferred node (ignored in MVP; Center routes before reaching Node).",
    )


# ---------- Responses ----------

class TaskResponse(BaseModel):
    """Task 资源表述（§4.2.2 / §4.2.3 / §4.2.4 共用）。"""
    model_config = ConfigDict(from_attributes=True)

    id: str
    source_url: str
    filename: str | None = None
    status: TaskStatus
    error: str | None = None
    total_size: int | None = None
    downloaded_size: int = 0
    speed: int = 0

    expires_at: datetime | None = None
    created_at: datetime
    started_at: datetime | None = None
    completed_at: datetime | None = None

    download_url: str | None = Field(
        default=None,
        description="一次性带 token 的直链（仅 status=completed 时有值），由 Center/Nginx 验证 token。",
    )


class ListTasksResponse(BaseModel):
    """GET /api/tasks response（§4.2.3）。"""
    items: list[TaskResponse]


class NodeHealthResponse(BaseModel):
    """GET /api/node/health response（§4.2.5）。"""
    status: Literal["ok", "degraded", "down"]
    aria2_online: bool
    queue: dict  # {queued, downloading, completed, failed, total}
    storage: dict  # {used_bytes, limit_bytes, used_ratio}
    node_id: str
    version: str = "0.1.0-mvp"
