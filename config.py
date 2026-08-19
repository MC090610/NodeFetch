"""全局配置（基于 pydantic-settings，从 .env 读取）。"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # --- Node Identity ---
    node_id: str = Field("dev-local-01", alias="NODE_ID")
    node_name: str = Field("Dev Local 01", alias="NODE_NAME")
    region: str = Field("DEV", alias="REGION")
    version: str = Field("1.0.0", alias="VERSION")

    # --- Database ---
    db_url: str = Field("sqlite+aiosqlite:///./tasks.db", alias="DB_URL")

    # --- Aria2 ---
    aria2_rpc_url: str = Field("http://127.0.0.1:6800/rpc", alias="ARIA2_RPC_URL")
    aria2_rpc_secret: str = Field("", alias="ARIA2_RPC_SECRET")

    # --- Storage ---
    download_dir: str = Field("./data/downloads", alias="DOWNLOAD_DIR")
    storage_limit_gb: int = Field(40, alias="STORAGE_LIMIT_GB")
    max_file_size_gb: int = Field(10, alias="MAX_FILE_SIZE_GB")

    # --- Concurrency ---
    concurrent_limit: int = Field(2, alias="CONCURRENT_LIMIT")

    # --- TTL ---
    ttl_minutes: int = Field(60, alias="TTL_MINUTES")

    # --- API Server ---
    api_host: str = Field("127.0.0.1", alias="API_HOST")
    api_port: int = Field(8000, alias="API_PORT")

    @property
    def max_file_size_bytes(self) -> int:
        return self.max_file_size_gb * 1024**3

    @property
    def storage_limit_bytes(self) -> int:
        return self.storage_limit_gb * 1024**3

    @property
    def download_dir_path(self) -> Path:
        """download_dir 解析为绝对 Path。懒计算避免 Field(validate_default) 开销。"""
        return Path(self.download_dir).expanduser().resolve()


@lru_cache
def get_settings() -> Settings:
    return Settings()
