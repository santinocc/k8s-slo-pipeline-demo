"""Runtime configuration read from environment variables (see .env.example)."""

import os
from dataclasses import dataclass

from psycopg.conninfo import make_conninfo


@dataclass(frozen=True)
class Settings:
    postgres_host: str
    postgres_port: int
    postgres_db: str
    postgres_user: str
    postgres_password: str
    log_level: str
    chaos_enabled: bool = False

    @property
    def conninfo(self) -> str:
        # make_conninfo quotes values, so passwords with spaces or quotes are safe.
        return make_conninfo(
            host=self.postgres_host,
            port=self.postgres_port,
            dbname=self.postgres_db,
            user=self.postgres_user,
            password=self.postgres_password,
            connect_timeout=3,
        )


def load_settings() -> Settings:
    """Build settings from the environment, with local-development defaults."""
    return Settings(
        postgres_host=os.getenv("POSTGRES_HOST", "localhost"),
        postgres_port=int(os.getenv("POSTGRES_PORT", "5432")),
        postgres_db=os.getenv("POSTGRES_DB", "slo_demo"),
        postgres_user=os.getenv("POSTGRES_USER", "slo_demo"),
        postgres_password=os.getenv("POSTGRES_PASSWORD", ""),
        log_level=os.getenv("APP_LOG_LEVEL", "info"),
        chaos_enabled=os.getenv("CHAOS_ENABLED", "false").lower() == "true",
    )
