"""Tests for the ingestion job.

Unit tests need nothing. Integration tests run only when TEST_POSTGRES_DSN is
set (see `make test-integration`, which starts a throwaway Postgres container).
"""

import os
from collections.abc import Iterator
from datetime import UTC, datetime
from pathlib import Path

import psycopg
import pytest

from ingest import generate_readings, upsert_readings, window_start

SCHEMA_SQL = (Path(__file__).parents[2] / "k8s" / "base" / "schema.sql").read_text()
WINDOW_A = datetime(2026, 11, 3, 10, 5, tzinfo=UTC)
WINDOW_B = datetime(2026, 11, 3, 10, 10, tzinfo=UTC)


def test_window_start_floors_to_window() -> None:
    now = datetime(2026, 11, 3, 10, 7, 42, 123, tzinfo=UTC)
    assert window_start(now, 5) == datetime(2026, 11, 3, 10, 5, tzinfo=UTC)
    assert window_start(now, 1) == datetime(2026, 11, 3, 10, 7, tzinfo=UTC)


def test_readings_are_deterministic_per_window() -> None:
    assert generate_readings(20, WINDOW_A) == generate_readings(20, WINDOW_A)


def test_readings_change_between_windows() -> None:
    a = generate_readings(20, WINDOW_A)
    b = generate_readings(20, WINDOW_B)
    assert [r.id for r in a] == [r.id for r in b]
    assert [r.value for r in a] != [r.value for r in b]


def test_readings_shape() -> None:
    readings = generate_readings(7, WINDOW_A)
    assert [r.id for r in readings] == list(range(1, 8))
    assert readings[0].name == "sensor-001"
    assert readings[0].category == "temperature"
    assert readings[5].category == "temperature"  # categories cycle every 5 ids
    assert all(r.value == round(r.value, 2) for r in readings)


@pytest.fixture
def conn() -> Iterator[psycopg.Connection]:
    dsn = os.getenv("TEST_POSTGRES_DSN")
    if not dsn:
        pytest.skip("TEST_POSTGRES_DSN not set")
    with psycopg.connect(dsn, autocommit=True) as connection:
        connection.execute("DROP TABLE IF EXISTS items")
        yield connection
        connection.execute("DROP TABLE IF EXISTS items")


def _count(conn: psycopg.Connection) -> int:
    row = conn.execute("SELECT count(*), count(DISTINCT id) FROM items").fetchone()
    assert row is not None
    total, distinct = row
    assert total == distinct
    return total


@pytest.mark.integration
def test_upsert_creates_table_and_inserts(conn: psycopg.Connection) -> None:
    result = upsert_readings(conn, generate_readings(10, WINDOW_A), SCHEMA_SQL)
    assert (result.inserted, result.updated, result.unchanged) == (10, 0, 0)
    assert _count(conn) == 10


@pytest.mark.integration
def test_rerun_in_same_window_is_a_no_op(conn: psycopg.Connection) -> None:
    readings = generate_readings(10, WINDOW_A)
    upsert_readings(conn, readings, SCHEMA_SQL)
    before = conn.execute("SELECT id, value, updated_at FROM items ORDER BY id").fetchall()

    result = upsert_readings(conn, readings, SCHEMA_SQL)

    assert (result.inserted, result.updated, result.unchanged) == (0, 0, 10)
    after = conn.execute("SELECT id, value, updated_at FROM items ORDER BY id").fetchall()
    assert after == before


@pytest.mark.integration
def test_new_window_updates_rows_without_duplicates(conn: psycopg.Connection) -> None:
    upsert_readings(conn, generate_readings(10, WINDOW_A), SCHEMA_SQL)
    result = upsert_readings(conn, generate_readings(12, WINDOW_B), SCHEMA_SQL)
    assert result.inserted == 2
    assert result.updated + result.unchanged == 10
    assert _count(conn) == 12
