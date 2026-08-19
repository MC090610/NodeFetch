"""SecurityAgent — Node Agent 第一道安全关卡。

职责（对应 Agent.md §3.2 表格）：
    所有 POST /api/tasks 的 URL 在这里被校验：
    ① 协议只允许 http/https
    ② host 解析后，任何一个 IP 是私有/回环/链路本地/ULA → 抛 SSRFBlocked
    ③ HEAD Content-Length 超过 Settings.max_file_size_bytes → 抛 FileTooLarge
       （没返回 Content-Length 就放行，后续交给 Aria2 在传输中限制）

对外接口：
    await validate_url(url: str, *, _resolver=..., _head_client=...)
        -> tuple[normalized_url: str, resolved_ips: list[str]]
        或抛 InvalidProtocol / SSRFBlocked / FileTooLarge（都是 SecurityError 子类）

_resolver 和 _head_client 是为了测试注入，生产代码不传。
"""
from __future__ import annotations

import ipaddress
import logging
import socket
from dataclasses import dataclass
from types import TracebackType
from typing import Protocol
from urllib.parse import urlparse

import httpx

from config import Settings, get_settings

log = logging.getLogger(__name__)

# Well-known NAT64 prefix (RFC 6052). DNS64 会把公网 A 记录合成 AAAA。
_NAT64_WELLKNOWN = ipaddress.IPv6Network("64:ff9b::/96")
# IPv6 documentation (RFC 3849)，应拒绝，但不能用 ip.is_reserved：那会误伤 ::/8 里的 NAT64。
_IPV6_DOCUMENTATION = ipaddress.IPv6Network("2001:db8::/32")


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------
class SecurityError(Exception):
    """SecurityAgent 相关异常的基类。HTTP 层会把它翻译成对应的 4xx。"""


class InvalidProtocol(SecurityError):
    """URL scheme 不是 http/https。HTTP 400。"""


class SSRFBlocked(SecurityError):
    """解析出的任何 IP 是内网/特殊用途。HTTP 400。"""


class FileTooLarge(SecurityError):
    """HEAD Content-Length 超过限额。HTTP 400。"""


class UnreachableHost(SecurityError):
    """DNS 解析失败。HTTP 400。"""


# ---------------------------------------------------------------------------
# Protocol 注入点（测试 mock 友好）
# ---------------------------------------------------------------------------
class _Resolver(Protocol):
    def __call__(self, host: str, port: int | None, family: int) -> list[tuple]: ...


class _HeadResponse(Protocol):
    @property
    def headers(self) -> dict: ...
    async def aclose(self) -> None: ...


class _HeadClient(Protocol):
    async def __call__(self, url: str) -> _HeadResponse: ...


# ---------------------------------------------------------------------------
# Private IP 判定
# ---------------------------------------------------------------------------
def _ipv4_is_blocked(ip: ipaddress.IPv4Address) -> bool:
    return (
        ip.is_private          # 10/8、172.16/12、192.168/16、127/8、169.254/16、100.64/10 等
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_unspecified    # 0.0.0.0
        or ip.is_multicast      # 224/4 等
        or ip.is_reserved       # 240/4 等
    )


def _unwrap_ipv6_embedded_v4(ip: ipaddress.IPv6Address) -> ipaddress.IPv4Address | None:
    """把 IPv4-mapped / NAT64 合成地址还原成里面的 IPv4，再走 IPv4 SSRF 规则。"""
    mapped = ip.ipv4_mapped
    if mapped is not None:
        return mapped
    if ip in _NAT64_WELLKNOWN:
        return ipaddress.IPv4Address(ip.packed[-4:])
    return None


def _is_private_ip(ip_str: str) -> bool:
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        # 解析出来的不是合法 IP（极端情况），当私有处理，保守拒绝
        return True
    if isinstance(ip, ipaddress.IPv6Address):
        embedded = _unwrap_ipv6_embedded_v4(ip)
        if embedded is not None:
            return _ipv4_is_blocked(embedded)
        return (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_unspecified
            or ip.is_multicast
            or ip.is_site_local          # RFC 3879 废弃，但仍有实现会分配
            or ip in _IPV6_DOCUMENTATION
            # 不用 ip.is_reserved：CPython 把 ::/8 整段标 reserved，会误杀 64:ff9b::/96（DNS64）
        )
    return _ipv4_is_blocked(ip)


# ---------------------------------------------------------------------------
# Normalization helpers
# ---------------------------------------------------------------------------
def _strip_brackets(host: str) -> str:
    """host 可能是 [::1] 这种带括号的 IPv6。"""
    if host.startswith("[") and host.endswith("]"):
        return host[1:-1]
    return host


# ---------------------------------------------------------------------------
# 默认 Resolver：用 stdlib socket.getaddrinfo
# ---------------------------------------------------------------------------
def _default_resolver(host: str, port: int | None, family: int) -> list[tuple]:
    return socket.getaddrinfo(host, port, family, socket.SOCK_STREAM)


# ---------------------------------------------------------------------------
# 默认 Head client：用 httpx.AsyncClient 发 HEAD，超时 5s
# ---------------------------------------------------------------------------
@dataclass
class _DefaultHeadClient:
    timeout: float = 5.0

    async def __call__(self, url: str) -> _HeadResponse:
        client = httpx.AsyncClient(timeout=self.timeout, follow_redirects=True)
        # httpx.Response 满足 _HeadResponse 协议
        try:
            resp = await client.head(url)
        finally:
            # 保持 client 不关闭直到使用方取到 headers
            class _Resp:
                def __init__(self, inner, holder):
                    self._inner = inner
                    self._holder = holder

                @property
                def headers(self):
                    return self._inner.headers

                async def aclose(self):
                    await self._holder.aclose()

            return _Resp(resp, client)  # type: ignore[return-value]


# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------
async def validate_url(
    url: str,
    *,
    _resolver: _Resolver | None = None,
    _head_client: _HeadClient | None = None,
    _settings: "Settings | None" = None,
) -> tuple[str, list[str]]:
    """校验 URL，返回 (normalized_url, resolved_ips)。任何一个条件不满足都抛 SecurityError。

    _settings 参数只用于测试注入（覆盖全局 Settings，避免 pydantic-settings env / lru_cache 在跨测试间污染）。
    """
    settings = _settings or get_settings()
    resolver = _resolver or _default_resolver
    head_client = _head_client or _DefaultHeadClient()

    # -------- 1. scheme 检查 --------
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise InvalidProtocol(f"Scheme {parsed.scheme!r} not allowed, only http/https")
    if not parsed.hostname:
        raise InvalidProtocol("URL has no host")

    # -------- 2. host 解析 --------
    host = _strip_brackets(parsed.hostname)
    port = parsed.port
    resolved_ips: list[str] = []
    try:
        # family=AF_UNSPEC -> 同时拿 v4 和 v6
        results = resolver(host, port, socket.AF_UNSPEC)
    except socket.gaierror as e:
        raise UnreachableHost(f"DNS resolution failed for {host!r}: {e}") from e

    # getaddrinfo 的 sockaddr 首元素永远是 IP str（IPv4=(ip,port)，IPv6=(ip,port,flow,scope)）
    # 不依赖 family 常量比较（跨平台 socket.AF_INET6 值不同），直接取 sockaddr[0]
    for _family, _socktype, _proto, _canonname, sockaddr in results:
        try:
            ip = sockaddr[0]
        except (IndexError, TypeError):
            continue
        if isinstance(ip, str):
            resolved_ips.append(ip)

    if not resolved_ips:
        raise UnreachableHost(f"No IPs resolved for {host!r}")

    # -------- 3. 只要有任何一个私有用 IP，拒绝 --------
    # （DNS Rebinding 防护：只要解析结果里包含一个私有就拒绝，不管是否同时有公网）
    for ip in resolved_ips:
        if _is_private_ip(ip):
            raise SSRFBlocked(f"Host {host!r} resolves to private/reserved IP {ip}")

    # -------- 4. Content-Length 预检查（允许服务器不返回 / HEAD 失败） --------
    # 很多源站不支持 HEAD 或会超时；按契约：拿不到大小就放行，交给 Aria2。
    try:
        resp = await head_client(url)
    except (httpx.HTTPError, OSError) as e:
        log.warning("HEAD probe failed for %s: %s — skip size check", url, e)
        resp = None
    if resp is not None:
        try:
            cl_raw = resp.headers.get("content-length")
            if cl_raw is not None:
                try:
                    cl = int(cl_raw)
                except (TypeError, ValueError):
                    cl = None
                if cl is not None and cl > settings.max_file_size_bytes:
                    raise FileTooLarge(
                        f"File size {cl} bytes exceeds limit {settings.max_file_size_bytes} bytes"
                    )
        finally:
            await resp.aclose()

    # -------- 5. 返回规范化 URL（把显式默认端口去掉） --------
    normalized = parsed._replace(fragment="").geturl()
    return normalized, resolved_ips


# ---------------------------------------------------------------------------
# 类封装：符合 Agent.md §3.1 的 SecurityAgent 名。对外类/函数式两种风格都可用。
# ---------------------------------------------------------------------------

class SecurityAgent:
    """SecurityAgent 类封装（与 §3.1 架构图对齐）。

    功能上等价直接调模块级 validate_url()。类封装便于做 DI/复用同一个 settings 引用，
    便于后续在此类中扩展 `revoke_token()` / `issue_token()` / `rate_limited()` 等。"""

    def __init__(self, settings: "Settings | None" = None) -> None:
        self._settings = settings

    async def validate_url(
        self,
        url: str,
        *,
        _resolver: _Resolver | None = None,
        _head_client: _HeadClient | None = None,
        _settings: "Settings | None" = None,
    ) -> tuple[str, list[str]]:
        return await validate_url(
            url,
            _resolver=_resolver,
            _head_client=_head_client,
            # 显式传入优先 > 构造注入 > 全局
            _settings=_settings or self._settings,
        )


# 兼容别名（routes 里 catch 的时候会用）
class PrivateIP(SSRFBlocked):
    """兼容旧名：SSRFBlocked 细分 PrivateIP。当前 SSRFBlocked 覆盖所有私 IP 情况。"""


class DNSRebinding(SSRFBlocked):
    """兼容旧名：同一 SSRFBlocked 家族里的 DNS rebinding 子错误。"""


# 把 ValidateURLError 兼容别名放这里（routes 的字典 key 会用到）
ValidateURLError = SecurityError

