"""DownloadWorkerAgent — 封装 Aria2 RPC。

Agent.md §3.2 内部子 Agent：
    - start_download(url, download_dir) -> gid
    - get_status(gid) -> {status, total_size, downloaded_size, speed, error_message}
        注意：Aria2 status 是 waiting/active/complete/error，本层统一翻译成任务域：
        waiting → queued / active → downloading / complete → completed / error → failed
    - remove(gid)  -> 取消（如果正在跑）并清理 Aria2 内部记录

依赖注入（仅测试用）：
    构造函数 _aria2 参数接受一个实现了 addUri / tellStatus / removeDownloadResult 的对象，
    测试用 FakeAria2；生产时不传，本模块自动用 HTTP POST 封装 Aria2 JSON-RPC。
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

import httpx

from config import get_settings, Settings


# ---------------------------------------------------------------------------
# Protocol：Aria2 RPC 三个接口最小集合
# ---------------------------------------------------------------------------
class Aria2Rpc(Protocol):
    async def addUri(self, urls: list[str], options: dict | None = None) -> str: ...
    async def tellStatus(self, gid: str) -> dict: ...
    async def removeDownloadResult(self, gid: str) -> Any: ...


# ---------------------------------------------------------------------------
# 生产环境实现：HTTP JSON-RPC 直连 Aria2（端口 6800）
# ---------------------------------------------------------------------------
class HttpAria2Rpc:
    def __init__(self, rpc_url: str, secret: str, timeout: float = 5.0):
        self._rpc_url = rpc_url
        self._secret = secret
        self._timeout = timeout
        self._id_counter = 0
        self._client = httpx.AsyncClient(timeout=self._timeout)

    # ----- 内部：统一 JSON-RPC 调用 -----
    async def _call(self, method: str, params: list | None = None):
        self._id_counter += 1
        token_param = f"token:{self._secret}"
        all_params = [token_param] + (params or [])
        payload = {
            "jsonrpc": "2.0",
            "method": method,
            "id": str(self._id_counter),
            "params": all_params,
        }
        resp = await self._client.post(self._rpc_url, json=payload)
        resp.raise_for_status()
        body = resp.json()
        if "error" in body:
            raise RuntimeError(f"Aria2 RPC error: {body['error']}")
        return body["result"]

    async def addUri(self, urls, options=None):
        params = [list(urls)]
        if options:
            params.append(options)
        return await self._call("aria2.addUri", params)

    async def tellStatus(self, gid):
        return await self._call("aria2.tellStatus", [gid])

    async def removeDownloadResult(self, gid):
        # 语义：如果还在下载，先 forcePause 再 removeDownloadResult
        try:
            await self._call("aria2.forceRemove", [gid])
        except Exception:
            # 已经完成的任务 forceRemove 会报错，忽略
            pass
        return await self._call("aria2.removeDownloadResult", [gid])

    async def aclose(self):
        await self._client.aclose()


# ---------------------------------------------------------------------------
# 统一的 get_status 返回字段
# ---------------------------------------------------------------------------
_STATUS_MAP = {
    "waiting": "queued",
    "active": "downloading",
    "paused": "downloading",   # 仍然在下载阶段，UI 展示 downloading
    "complete": "completed",
    "error": "failed",
    "removed": "failed",
}


def _parse_status(raw: dict) -> dict:
    aria_status = raw.get("status", "waiting")
    status = _STATUS_MAP.get(aria_status, aria_status)
    total = int(raw.get("totalLength") or 0) or None
    completed = int(raw.get("completedLength") or 0)
    speed = int(raw.get("downloadSpeed") or 0)
    error = raw.get("errorMessage") or None
    # 尝试拿 filename（Aria2 的 files[0].path 可能是绝对路径，取 basename）
    import os
    filename = None
    files = raw.get("files") or []
    if files:
        path = files[0].get("path")
        if path:
            filename = os.path.basename(path)
    return {
        "status": status,
        "total_size": total,
        "downloaded_size": completed,
        "speed": speed,
        "error_message": error,
        "filename": filename,
    }


# ---------------------------------------------------------------------------
# DownloadWorkerAgent 对外类
# ---------------------------------------------------------------------------
class DownloadWorkerAgent:
    def __init__(self, *, _aria2: Aria2Rpc | None = None, _settings: Settings | None = None):
        self._settings = _settings or get_settings()
        if _aria2 is not None:
            self._aria2 = _aria2
            self._owns_rpc = False
        else:
            self._aria2 = HttpAria2Rpc(
                rpc_url=self._settings.aria2_rpc_url,
                secret=self._settings.aria2_rpc_secret,
            )
            self._owns_rpc = True

    async def start_download(
        self,
        url: str,
        *,
        download_dir: str,
        out_filename: str | None = None,
    ) -> str:
        """提交给 Aria2 开始下载，返回 Aria2 gid。

        Args:
            url: 下载源
            download_dir: 强制单任务目录（对应 storage_path 的父 dir）
            out_filename: 若提供则作为 aria2 的 `out` 选项（覆盖 URL 默认文件名）
        """
        opts: dict = {"dir": download_dir}
        if out_filename:
            opts["out"] = out_filename
        gid = await self._aria2.addUri([url], opts)
        return gid

    async def get_status(self, gid: str) -> dict:
        """统一翻译后的状态字典。"""
        raw = await self._aria2.tellStatus(gid)
        return _parse_status(raw)

    async def get_global_stat(self, timeout: float | None = None) -> dict | None:
        """getGlobalStat（轻量健康检查）。失败返回 None。"""
        try:
            if isinstance(self._aria2, HttpAria2Rpc):
                # timeout 由 aiohttp 客户端 session 默认 timeout 控制；这里再包一层 asyncio
                import asyncio as _aio
                call = self._aria2._call("aria2.getGlobalStat")  # noqa: SLF001
                if timeout is None:
                    return await call
                return await _aio.wait_for(call, timeout=timeout)
            # FakeAria2：直接返回最小可用 dict（仅用于 node health 探测）
            return {"numActive": "0", "numWaiting": "0", "numStopped": "0"}
        except Exception:  # noqa: BLE001
            return None

    async def remove(self, gid: str) -> None:
        """取消下载 + 清理 Aria2 内记录。"""
        await self._aria2.removeDownloadResult(gid)

    async def ping(self) -> bool:
        """启动时用于确认 Aria2 进程健康。生产环境 HTTP 实现，FakeAria2 默认返回 True。"""
        try:
            if isinstance(self._aria2, HttpAria2Rpc):
                await self._aria2._call("aria2.getVersion")  # noqa: SLF001
                return True
            # FakeAria2 没实现 getVersion，直接用 tellStatus 会抛错；这里 try tellStatus with 不存在 gid 也 OK
            return True
        except Exception:
            return False

    async def aclose(self):
        if self._owns_rpc and isinstance(self._aria2, HttpAria2Rpc):
            await self._aria2.aclose()
