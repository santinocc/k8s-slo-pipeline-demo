"""FastAPI service for the k8s-slo-pipeline-demo learning project."""

import logging
import random
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import psycopg
from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from psycopg_pool import PoolTimeout

from api.config import Settings, load_settings
from api.db import Item, ItemRepository, PostgresItemRepository, create_pool
from api.metrics import metrics_middleware

logger = logging.getLogger("api")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = load_settings()
    logging.basicConfig(level=settings.log_level.upper())
    pool = create_pool(settings.conninfo)
    pool.open(wait=False)
    app.state.settings = settings
    app.state.repository = PostgresItemRepository(pool)
    try:
        yield
    finally:
        pool.close()


app = FastAPI(title="k8s-slo-pipeline-demo API", lifespan=lifespan)
app.middleware("http")(metrics_middleware)


def get_repository(request: Request) -> ItemRepository:
    return request.app.state.repository


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


@app.get("/health")
def health() -> dict[str, str]:
    """Liveness: the process is up. Does not touch the database."""
    return {"status": "ok"}


@app.get("/ready")
def ready(repo: ItemRepository = Depends(get_repository)) -> dict[str, str]:
    """Readiness: the database is reachable."""
    try:
        repo.ping()
    except (psycopg.Error, PoolTimeout) as exc:
        logger.warning("readiness check failed: %s", exc)
        raise HTTPException(status_code=503, detail="database unavailable") from exc
    return {"status": "ready"}


@app.get("/items")
def list_items(
    limit: int = Query(default=100, ge=1, le=1000),
    repo: ItemRepository = Depends(get_repository),
) -> list[Item]:
    try:
        return repo.list_items(limit)
    except (psycopg.Error, PoolTimeout) as exc:
        logger.error("failed to read items: %s", exc)
        raise HTTPException(status_code=503, detail="database unavailable") from exc


@app.get("/chaos")
def chaos(
    rate: float = Query(default=0.5, ge=0.0, le=1.0),
    settings: Settings = Depends(get_settings),
) -> dict[str, str]:
    """Error injection for the SLO demo: fails with probability `rate`.

    Disabled (404) unless CHAOS_ENABLED=true. It is stateless, so it behaves
    the same on every replica behind the Service.
    """
    if not settings.chaos_enabled:
        raise HTTPException(status_code=404, detail="Not Found")
    # Not security-sensitive; only decides whether to inject an error.
    if random.random() < rate:  # noqa: S311
        raise HTTPException(status_code=500, detail="injected failure")
    return {"status": "ok"}


@app.get("/metrics", include_in_schema=False)
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
