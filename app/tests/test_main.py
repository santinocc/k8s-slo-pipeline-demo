"""API tests. The database is replaced with in-memory fakes, so no PostgreSQL is needed."""

from collections.abc import Iterator
from datetime import UTC, datetime

import psycopg
import pytest
from fastapi.testclient import TestClient

from api.config import Settings
from api.db import Item
from api.main import app, get_repository

SAMPLE = [
    Item(id=1, name="alpha", category="a", value=1.5, updated_at=datetime(2026, 1, 1, tzinfo=UTC)),
    Item(id=2, name="beta", category="b", value=2.0, updated_at=datetime(2026, 1, 2, tzinfo=UTC)),
]


class FakeRepository:
    def __init__(self, items: list[Item]) -> None:
        self.items = items
        self.last_limit: int | None = None

    def list_items(self, limit: int) -> list[Item]:
        self.last_limit = limit
        return self.items[:limit]

    def ping(self) -> None:
        return None


class BrokenRepository:
    def list_items(self, limit: int) -> list[Item]:
        raise psycopg.OperationalError("connection refused")

    def ping(self) -> None:
        raise psycopg.OperationalError("connection refused")


@pytest.fixture
def fake_repo() -> FakeRepository:
    return FakeRepository(SAMPLE)


@pytest.fixture
def client(fake_repo: FakeRepository) -> Iterator[TestClient]:
    # No `with` block: the lifespan (real connection pool) is not started.
    app.dependency_overrides[get_repository] = lambda: fake_repo
    yield TestClient(app)
    app.dependency_overrides.clear()


@pytest.fixture
def broken_client() -> Iterator[TestClient]:
    app.dependency_overrides[get_repository] = BrokenRepository
    yield TestClient(app)
    app.dependency_overrides.clear()


def test_health_returns_ok(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_health_does_not_depend_on_database(broken_client: TestClient) -> None:
    assert broken_client.get("/health").status_code == 200


def test_ready_ok_when_database_reachable(client: TestClient) -> None:
    assert client.get("/ready").status_code == 200


def test_ready_503_when_database_down(broken_client: TestClient) -> None:
    assert broken_client.get("/ready").status_code == 503


def test_items_returns_rows_as_json(client: TestClient) -> None:
    response = client.get("/items")
    assert response.status_code == 200
    body = response.json()
    assert [row["name"] for row in body] == ["alpha", "beta"]
    assert body[0] == {
        "id": 1,
        "name": "alpha",
        "category": "a",
        "value": 1.5,
        "updated_at": "2026-01-01T00:00:00Z",
    }


def test_items_passes_limit(client: TestClient, fake_repo: FakeRepository) -> None:
    response = client.get("/items", params={"limit": 1})
    assert response.status_code == 200
    assert len(response.json()) == 1
    assert fake_repo.last_limit == 1


@pytest.mark.parametrize("limit", [0, 1001, "x"])
def test_items_rejects_invalid_limit(client: TestClient, limit: object) -> None:
    assert client.get("/items", params={"limit": limit}).status_code == 422


def test_items_503_when_database_down(broken_client: TestClient) -> None:
    response = broken_client.get("/items")
    assert response.status_code == 503
    assert response.json() == {"detail": "database unavailable"}


def test_metrics_exposes_request_counters(client: TestClient) -> None:
    client.get("/health")
    client.get("/does-not-exist")
    response = client.get("/metrics")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    text = response.text
    assert 'http_requests_total{method="GET",route="/health",status="200"}' in text
    assert 'http_requests_total{method="GET",route="unmatched",status="404"}' in text
    assert "http_request_duration_seconds_bucket" in text


def test_conninfo_quotes_special_characters() -> None:
    settings = Settings("db", 5432, "slo_demo", "user", "p@ss word'", "info")
    assert "password='p@ss word\\''" in settings.conninfo
