"""PostgreSQL access for the API.

The `items` table is created and filled by the pipeline CronJob (M3).
The API only reads from it.
"""

from datetime import datetime
from typing import Protocol

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel


class Item(BaseModel):
    id: int
    name: str
    category: str
    value: float
    updated_at: datetime


class ItemRepository(Protocol):
    def list_items(self, limit: int) -> list[Item]: ...

    def ping(self) -> None: ...


class PostgresItemRepository:
    """Reads items through a shared connection pool."""

    def __init__(self, pool: ConnectionPool) -> None:
        self._pool = pool

    def list_items(self, limit: int) -> list[Item]:
        with self._pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                "SELECT id, name, category, value, updated_at FROM items ORDER BY id LIMIT %s",
                (limit,),
            )
            return [Item(**row) for row in cur.fetchall()]

    def ping(self) -> None:
        with self._pool.connection() as conn:
            conn.execute("SELECT 1")


def create_pool(conninfo: str) -> ConnectionPool:
    """Create a small pool. It opens lazily so the API can start while the DB is down."""
    return ConnectionPool(conninfo, min_size=1, max_size=5, timeout=2, open=False)
