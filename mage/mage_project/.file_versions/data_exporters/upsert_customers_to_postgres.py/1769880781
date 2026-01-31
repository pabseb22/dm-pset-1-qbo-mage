import json
import psycopg2
from psycopg2.extras import execute_values

from mage_ai.data_preparation.shared.secrets import get_secret_value
from pandas import DataFrame

if "data_exporter" not in globals():
    from mage_ai.data_preparation.decorators import data_exporter


def _require_secret(key: str) -> str:
    val = get_secret_value(key)
    if not val:
        raise ValueError(f"Missing required Mage Secret: {key}")
    return val


def _to_json_str(x):
    if x is None:
        return None
    if isinstance(x, (dict, list)):
        return json.dumps(x)
    return str(x)


@data_exporter
def export_data_to_postgres(df: DataFrame, **kwargs) -> None:
    schema_name = "raw"
    table_name = "qb_customers"

    host = _require_secret("POSTGRES_HOST")
    port = int(_require_secret("POSTGRES_PORT"))
    db = _require_secret("POSTGRES_DB")
    user = _require_secret("POSTGRES_USER")
    password = _require_secret("POSTGRES_PASSWORD")

    if df is None or df.empty:
        print("✅ No rows to export for this run.")
        return

    # --- KEY FIX: Deduplicate by id inside this batch ---
    # keep="last" means if the same customer appears multiple times in the run,
    # we keep the latest row in the dataframe order.
    df2 = df.copy()

    # Ensure stable ordering: keep the "latest" window / page if present
    # (Not strictly required, but helps pick a sensible "last")
    sort_cols = [c for c in ["extract_window_end_utc", "page_number"] if c in df2.columns]
    if sort_cols:
        df2 = df2.sort_values(sort_cols)

    before = len(df2)
    df2 = df2.drop_duplicates(subset=["id"], keep="last")
    after = len(df2)
    if after < before:
        print(f"⚠️ Deduped batch rows by id: {before} -> {after} (avoids CardinalityViolation)")

    values = []
    for row in df2.to_dict(orient="records"):
        values.append((
            str(row["id"]),
            _to_json_str(row["payload"]),
            row["extract_window_start_utc"],
            row["extract_window_end_utc"],
            int(row["page_number"]),
            int(row["page_size"]),
            _to_json_str(row.get("request_payload")),
        ))

    upsert_sql = f"""
    INSERT INTO {schema_name}.{table_name}
      (id, payload, extract_window_start_utc, extract_window_end_utc, page_number, page_size, request_payload)
    VALUES %s
    ON CONFLICT (id) DO UPDATE SET
      payload = EXCLUDED.payload::jsonb,
      ingested_at_utc = now(),
      extract_window_start_utc = EXCLUDED.extract_window_start_utc,
      extract_window_end_utc = EXCLUDED.extract_window_end_utc,
      page_number = EXCLUDED.page_number,
      page_size = EXCLUDED.page_size,
      request_payload = EXCLUDED.request_payload::jsonb;
    """

    conn = psycopg2.connect(
        host=host,
        port=port,
        dbname=db,
        user=user,
        password=password,
    )
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            execute_values(cur, upsert_sql, values, page_size=500)
        conn.commit()
        print(f"✅ Upserted {len(values)} rows into {schema_name}.{table_name}")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
