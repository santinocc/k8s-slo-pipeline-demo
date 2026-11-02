-- Schema for the items table. Runs once, when the Postgres volume is first created.
-- The pipeline CronJob (M3) upserts rows into this table; the API reads them.
CREATE TABLE IF NOT EXISTS items (
    id         integer PRIMARY KEY,
    name       text        NOT NULL,
    category   text        NOT NULL,
    value      numeric     NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
