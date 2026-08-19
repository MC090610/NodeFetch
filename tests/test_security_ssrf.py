"""SecurityAgent 单元测试（TDD：先写）。

覆盖点：
1. 协议只允许 http / https
2. 所有私有/回环/链路本地/特殊用途 IPv4 都拒绝
3. IPv6：::1、fc00::/7（ULA）、fe80::/10（链路本地）、::ffff:127.x.x.x（v4-mapped）
4. DNS rebinding：一个 host 同时解析到公网和私有 IP，只要有一个私有就拒绝
5. 文件大小：Content-Length 超 MAX_FILE_SIZE_GB 拒绝
6. 合法公网 URL 放行，并返回 resolved_ips
7. localhost / 0.0.0.0 / 任何变体域名（如 localhost.）也拒绝
"""
from __future__ import annotations

import pytest

pytestmark = pytest.mark.asyncio


class TestProtocolRestriction:
    async def test_http_allowed(self):
        from agents.security_agent import validate_url
        # 用 http://example.com 这种真的公网域名，但是我们只需要验证协议被允许，
        # 不做真实 DNS（mock 见下面 test_resolver_injection）——但为了测试真正跑通，
        # validate_url 设计为接受可选 _resolver 参数注入。
        ips = ["93.184.216.34"]
        norm, resolved = await validate_url(
            "http://example.com/file.zip",
            _resolver=lambda _h, _p, _f: [(2, 1, 6, b"", ("93.184.216.34", 0))],
        )
        assert norm.startswith("http://example.com/")
        assert resolved == ips

    async def test_https_allowed(self):
        from agents.security_agent import validate_url
        norm, resolved = await validate_url(
            "https://example.com/file.zip",
            _resolver=lambda _h, _p, _f: [(2, 1, 6, b"", ("93.184.216.34", 0))],
        )
        assert norm.startswith("https://")

    @pytest.mark.parametrize(
        "bad_url",
        [
            "file:///etc/passwd",
            "ftp://example.com/x.zip",
            "ftps://example.com/x.zip",
            "sftp://example.com/x.zip",
            "gopher://example.com/x",
            "data:text/plain,hello",
            "://bad-scheme",
        ],
    )
    async def test_disallowed_schemes_raise_invalid_protocol(self, bad_url: str):
        from agents.security_agent import InvalidProtocol, validate_url
        with pytest.raises(InvalidProtocol):
            await validate_url(bad_url)


# ---------------------------------------------------------------------------
# IPv4 私有范围拒绝
# ---------------------------------------------------------------------------
class TestPrivateIPv4Blocked:
    @pytest.mark.parametrize(
        "host",
        [
            "127.0.0.1",
            "127.1.2.3",
            "localhost",
            "localhost.",
            "0.0.0.0",
            "10.0.0.1",
            "10.255.255.254",
            "172.16.0.1",
            "172.31.255.254",
            "192.168.0.1",
            "192.168.255.254",
            "169.254.1.1",   # DHCP 链路本地
            "169.254.169.254",  # 云元数据常见地址
        ],
    )
    async def test_private_ipv4_or_localhost_is_blocked(self, host: str):
        from agents.security_agent import SSRFBlocked, validate_url
        from ipaddress import ip_address, IPv4Address
        # 构造假 resolver：直接把 host 当 IP 返回（若 host 是 localhost 则变成 127.0.0.1）
        def _fake_resolver(h, port, family):
            ip = h if h not in ("localhost", "localhost.") else "127.0.0.1"
            return [(2, 1, 6, b"", (ip, port or 0))]
        with pytest.raises(SSRFBlocked):
            await validate_url(f"https://{host}/x.zip", _resolver=_fake_resolver)


# ---------------------------------------------------------------------------
# IPv6 私有范围拒绝
# ---------------------------------------------------------------------------
class TestPrivateIPv6Blocked:
    @pytest.mark.parametrize(
        "ip",
        [
            "::1",
            "0:0:0:0:0:0:0:1",
            "fe80::1",                  # 链路本地
            "fe80:0:0:0:abcd:1234:abcd:1234",
            "fc00::1",                  # ULA
            "fd12:3456:789a::1",        # ULA 常用前缀
            "::ffff:127.0.0.1",         # v4-mapped 回环
            "::ffff:192.168.1.1",       # v4-mapped 私有
        ],
    )
    async def test_private_ipv6_blocked(self, ip: str):
        from agents.security_agent import SSRFBlocked, validate_url
        def _resolver(h, p, f):
            return [(10, 1, 6, b"", (ip, p or 0, 0, 0))]
        with pytest.raises(SSRFBlocked):
            # 用 [] 包 IPv6
            await validate_url(f"http://[{ip}]/x.zip", _resolver=_resolver)

    async def test_ipv4_mapped_public_is_allowed(self):
        from agents.security_agent import validate_url
        async def _hc(_u): return _MockHeadResponse(content_length=None)
        def _resolver(h, p, f):
            return [(10, 1, 6, b"", ("::ffff:93.184.216.34", p or 0, 0, 0))]
        _, resolved = await validate_url(
            "http://example.com/x.zip", _resolver=_resolver, _head_client=_hc,
        )
        assert resolved == ["::ffff:93.184.216.34"]

    async def test_nat64_public_is_allowed(self):
        """DNS64 常见合成地址 64:ff9b::x.x.x.x，内嵌公网 IPv4 时应放行。"""
        from agents.security_agent import validate_url
        async def _hc(_u): return _MockHeadResponse(content_length=None)
        # 93.184.216.34 = 0x5db8d822
        nat64 = "64:ff9b::5db8:d822"
        def _resolver(h, p, f):
            return [(10, 1, 6, b"", (nat64, p or 0, 0, 0))]
        _, resolved = await validate_url(
            "http://example.com/x.zip", _resolver=_resolver, _head_client=_hc,
        )
        assert resolved == [nat64]

    async def test_nat64_private_is_blocked(self):
        from agents.security_agent import SSRFBlocked, validate_url
        # 192.168.1.1 = 0xc0a80101
        nat64 = "64:ff9b::c0a8:101"
        def _resolver(h, p, f):
            return [(10, 1, 6, b"", (nat64, p or 0, 0, 0))]
        with pytest.raises(SSRFBlocked):
            await validate_url("http://internal.example/x.zip", _resolver=_resolver)


# ---------------------------------------------------------------------------
# DNS Rebinding：一个 host 解析到公网 + 私有，只要有私有必须拒绝
# ---------------------------------------------------------------------------
class TestDNSRebindingBlocked:
    async def test_mixed_public_and_private_ips_is_blocked(self):
        from agents.security_agent import SSRFBlocked, validate_url
        public_ip = "93.184.216.34"
        private_ip = "169.254.169.254"

        def _rebinding_resolver(h, p, f):
            return [
                (2, 1, 6, b"", (public_ip, p or 0)),
                (2, 1, 6, b"", (private_ip, p or 0)),
            ]
        with pytest.raises(SSRFBlocked):
            await validate_url("http://evil.example.com/x.zip", _resolver=_rebinding_resolver)


# ---------------------------------------------------------------------------
# 文件大小限制（通过 mock HEAD 响应）
# ---------------------------------------------------------------------------
class TestMaxFileSize:
    @staticmethod
    def _small_settings():
        from config import Settings
        return Settings(
            _env_file=None,
            NODE_ID="x",
            NODE_NAME="x",
            REGION="X",
            VERSION="1.0.0",
            DB_URL="sqlite+aiosqlite:///:memory:",
            ARIA2_RPC_URL="http://127.0.0.1:6800/rpc",
            ARIA2_RPC_SECRET="x",
            DOWNLOAD_DIR="./data/downloads",
            STORAGE_LIMIT_GB=1,
            MAX_FILE_SIZE_GB=1,
            CONCURRENT_LIMIT=2,
            TTL_MINUTES=2,
        )

    async def test_small_file_allowed(self):
        from agents.security_agent import validate_url
        small = 1024 * 1024  # 1MB（MAX_FILE_SIZE_GB=1）
        async def _hc(_u): return _MockHeadResponse(content_length=small)
        norm, resolved = await validate_url(
            "https://example.com/file.zip",
            _resolver=lambda _h, _p, _f: [(2, 1, 6, b"", ("93.184.216.34", 0))],
            _head_client=_hc,
            _settings=self._small_settings(),
        )
        assert resolved == ["93.184.216.34"]

    async def test_too_large_file_raises(self):
        from agents.security_agent import FileTooLarge, validate_url
        # 超过 1GB 限制 1 byte
        too_big = 1 * 1024**3 + 1
        async def _hc(_u): return _MockHeadResponse(content_length=too_big)
        with pytest.raises(FileTooLarge):
            await validate_url(
                "https://example.com/big.bin",
                _resolver=lambda _h, _p, _f: [(2, 1, 6, b"", ("93.184.216.34", 0))],
                _head_client=_hc,
                _settings=self._small_settings(),
            )

    async def test_head_no_content_length_is_allowed_but_warns(self):
        """服务器不返回 Content-Length 时允许（否则无法下载动态文件），后续由 Aria2 在传输中限制。"""
        from agents.security_agent import validate_url
        async def _hc(_u): return _MockHeadResponse(content_length=None)
        norm, resolved = await validate_url(
            "https://example.com/dynamic",
            _resolver=lambda _h, _p, _f: [(2, 1, 6, b"", ("93.184.216.34", 0))],
            _head_client=_hc,
            _settings=self._small_settings(),
        )
        assert resolved

    async def test_head_network_error_is_allowed(self):
        """HEAD 超时/连不上不应 500，按「没有 Content-Length」放行。"""
        import httpx
        from agents.security_agent import validate_url

        async def _hc(_u):
            raise httpx.ConnectTimeout("simulated")

        norm, resolved = await validate_url(
            "https://example.com/file.zip",
            _resolver=lambda _h, _p, _f: [(2, 1, 6, b"", ("93.184.216.34", 0))],
            _head_client=_hc,
            _settings=self._small_settings(),
        )
        assert resolved == ["93.184.216.34"]
        assert norm.startswith("https://example.com/")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
class _MockHeadResponse:
    def __init__(self, content_length: int | None):
        self._cl = content_length

    @property
    def headers(self):
        if self._cl is None:
            return {}
        return {"content-length": str(self._cl)}

    async def aclose(self):
        return None
