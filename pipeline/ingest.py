"""Ingestion job for the k8s-slo-pipeline-demo learning project.

Generates a small synthetic dataset of sensor readings and upserts it into the
PostgreSQL `items` table. Values are derived from the item id and the current
time window, so:
- re-running inside the same window changes nothing (idempotent), and
- each new window updates the values, so changes are visible in the API.

The script exits non-zero on any database error, so Kubernetes marks the Job
pod as failed and retries according to the Job's backoffLimit.
"""

import logging
import os
import random
import sys
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path

import psycopg
from psycopg.conninfo import make_conninfo

logger = logging.getLogger("ingest")

# (category, typical value, +/- spread)
CATEGORIES: list[tuple[str, float, float]] = [
    ("temperature", 21.0, 4.0),
    ("humidity", 45.0, 10.0),
    ("pressure", 1013.0, 8.0),
    ("air-quality", 40.0, 25.0),
    ("light", 300.0, 150.0),
]

UPSERT_SQL = """
INSERT INTO items AS t (id, name, category, value)
SELECT * FROM unnest(%s::integer[], %s::text[], %s::text[], %s::numeric[])
ON CONFLICT (id) DO UPDATE
    SET name = EXCLUDED.name,
        category = EXCLUDED.category,
        value = EXCLUDED.value,
        updated_at = now()
    -- Skip rows whose data did not change, so re-runs leave them untouched.
    WHERE (t.name, t.category, t.value)
        IS DISTINCT FROM (EXCLUDED.name, EXCLUDED.category, EXCLUDED.value)
RETURNING (xmax = 0) AS inserted
"""


@dataclass(frozen=True)
class Reading:
    id: int
    name: str
    category: str
    value: Decimal


@dataclass(frozen=True)
class UpsertResult:
    inserted: int
    updated: int
    unchanged: int


def window_start(now: datetime, window_minutes: int) -> datetime:
    """Floor a timestamp to the start of its ingestion window."""
    minute = now.minute - now.minute % window_minutes
    return now.replace(minute=minute, second=0, microsecond=0)


def generate_readings(count: int, window: datetime) -> list[Reading]:
    """Build `count` readings. Same count and window always give the same data."""
    readings = []
    for item_id in range(1, count + 1):
        category, base, spread = CATEGORIES[(item_id - 1) % len(CATEGORIES)]
        # Seeded per item and window for reproducible synthetic data; not for security.
        rng = random.Random(f"{item_id}:{window.isoformat()}")  # noqa: S311
        value = Decimal(str(round(base + rng.uniform(-spread, spread), 2)))
        readings.append(Reading(item_id, f"sensor-{item_id:03d}", category, value))
    return readings


def upsert_readings(
    conn: psycopg.Connection, readings: list[Reading], schema_sql: str | None = None
) -> UpsertResult:
    """Create the table if needed and upsert all readings in one transaction."""
    with conn.transaction(), conn.cursor() as cur:
        if schema_sql:
            cur.execute(schema_sql)
        cur.execute(
            UPSERT_SQL,
            (
                [r.id for r in readings],
                [r.name for r in readings],
                [r.category for r in readings],
                [r.value for r in readings],
            ),
        )
        flags = [row[0] for row in cur.fetchall()]
    inserted = sum(flags)
    updated = len(flags) - inserted
    return UpsertResult(inserted, updated, len(readings) - len(flags))


def conninfo_from_env() -> str:
    return make_conninfo(
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=os.getenv("POSTGRES_PORT", "5432"),
        dbname=os.getenv("POSTGRES_DB", "slo_demo"),
        user=os.getenv("POSTGRES_USER", "slo_demo"),
        password=os.getenv("POSTGRES_PASSWORD", ""),
        connect_timeout=5,
        application_name="slo-demo-ingest",
    )


def main() -> int:
    logging.basicConfig(
        level=os.getenv("APP_LOG_LEVEL", "info").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    count = int(os.getenv("INGEST_ITEM_COUNT", "50"))
    window = window_start(datetime.now(UTC), int(os.getenv("INGEST_WINDOW_MINUTES", "5")))
    schema_file = os.getenv("SCHEMA_FILE")
    schema_sql = Path(schema_file).read_text() if schema_file else None

    readings = generate_readings(count, window)
    started = time.perf_counter()
    try:
        with psycopg.connect(conninfo_from_env()) as conn:
            result = upsert_readings(conn, readings, schema_sql)
    except psycopg.Error as exc:
        logger.error("ingestion failed: %s", str(exc).strip())
        return 1
    logger.info(
        "ingestion complete window=%s rows=%d inserted=%d updated=%d unchanged=%d duration_ms=%d",
        window.isoformat(),
        count,
        result.inserted,
        result.updated,
        result.unchanged,
        (time.perf_counter() - started) * 1000,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
