CREATE TABLE IF NOT EXISTS raw.qb_customers (
  id TEXT PRIMARY KEY,
  payload JSONB NOT NULL,

  -- ingestion metadata
  ingested_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  extract_window_start_utc TIMESTAMPTZ NOT NULL,
  extract_window_end_utc   TIMESTAMPTZ NOT NULL,
  page_number INT NOT NULL,
  page_size INT NOT NULL,
  request_payload JSONB
);

CREATE INDEX IF NOT EXISTS idx_qb_customers_ingested_at
  ON raw.qb_customers (ingested_at_utc);

CREATE INDEX IF NOT EXISTS idx_qb_customers_window
  ON raw.qb_customers (extract_window_start_utc, extract_window_end_utc);
