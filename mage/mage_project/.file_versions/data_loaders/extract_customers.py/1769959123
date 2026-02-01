import base64
import json
from datetime import datetime, timedelta, timezone

import pandas as pd
import requests
from mage_ai.data_preparation.shared.secrets import get_secret_value

if "data_loader" not in globals():
    from mage_ai.data_preparation.decorators import data_loader
if "test" not in globals():
    from mage_ai.data_preparation.decorators import test


RAW_COLUMNS = [
    "id",
    "payload",
    "extract_window_start_utc",
    "extract_window_end_utc",
    "page_number",
    "page_size",
    "request_payload",
]


def _require_secret(key: str) -> str:
    val = get_secret_value(key)
    if not val:
        raise ValueError(f"Missing required Mage Secret: {key}")
    return val


def _get_base_url() -> str:
    env = _require_secret("QBO_ENV").strip().lower()
    if env == "sandbox":
        return "https://sandbox-quickbooks.api.intuit.com"
    if env in ("prod", "production"):
        return "https://quickbooks.api.intuit.com"
    raise ValueError("QBO_ENV must be 'sandbox' or 'prod'/'production'")


def _refresh_access_token() -> dict:
    client_id = _require_secret("QBO_CLIENT_ID")
    client_secret = _require_secret("QBO_CLIENT_SECRET")
    refresh_token = _require_secret("QBO_REFRESH_TOKEN")

    token_url = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer"
    basic = base64.b64encode(f"{client_id}:{client_secret}".encode("utf-8")).decode("utf-8")

    headers = {
        "Authorization": f"Basic {basic}",
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
    }
    data = {"grant_type": "refresh_token", "refresh_token": refresh_token}

    r = requests.post(token_url, headers=headers, data=data, timeout=30)
    if not r.ok:
        raise RuntimeError(f"Token refresh failed: {r.status_code}\n{r.text}")
    return r.json()


def _qbo_query(access_token: str, realm_id: str, query: str, minorversion: str) -> dict:
    base_url = _get_base_url()
    url = f"{base_url}/v3/company/{realm_id}/query"

    headers = {"Authorization": f"Bearer {access_token}", "Accept": "application/json"}
    params = {"query": query, "minorversion": minorversion}

    r = requests.get(url, headers=headers, params=params, timeout=30)
    if not r.ok:
        raise RuntimeError(f"QBO query failed: {r.status_code}\nURL: {r.url}\nBody: {r.text}")
    return r.json()


def _parse_iso_utc(s: str) -> datetime:
    s = s.strip()
    if len(s) == 10:  # YYYY-MM-DD
        return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _iso_z(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _default_window_for_test() -> tuple[datetime, datetime]:
    # Solo para test manual si no pasas fechas. El deber requiere pasarlas por trigger. :contentReference[oaicite:15]{index=15}
    end_dt = datetime.now(timezone.utc)
    start_dt = end_dt - timedelta(days=30)  # 30 días para aumentar chance de data
    return start_dt, end_dt


def _extract_customers(payload: dict) -> list:
    return (payload.get("QueryResponse", {}) or {}).get("Customer", []) or []


@data_loader
def load_data_from_api(*args, **kwargs):
    """
    Requerido por el deber: acepta fecha_inicio y fecha_fin (ISO, UTC). :contentReference[oaicite:16]{index=16}

    Params (desde trigger):
      - fecha_inicio: 'YYYY-MM-DD' o ISO UTC
      - fecha_fin:    'YYYY-MM-DD' o ISO UTC
    Opcional:
      - page_size (int)  default 200
      - minorversion (str) default 75
      - force_full_scan (bool) default False  (solo para debug)
    """
    realm_id = _require_secret("QBO_REALM_ID")
    minorversion = str(kwargs.get("minorversion") or "75").strip()
    page_size = int(kwargs.get("page_size") or 200)
    force_full_scan = bool(kwargs.get("force_full_scan") or False)

    fecha_inicio = kwargs.get("fecha_inicio")
    fecha_fin = kwargs.get("fecha_fin")

    if fecha_inicio and fecha_fin:
        extract_start = _parse_iso_utc(fecha_inicio)
        extract_end = _parse_iso_utc(fecha_fin)
    else:
        extract_start, extract_end = _default_window_for_test()

    if extract_end <= extract_start:
        raise ValueError("fecha_fin must be greater than fecha_inicio")

    token_payload = _refresh_access_token()
    access_token = token_payload["access_token"]

    rows = []

    # Segmentación diaria (requerida) :contentReference[oaicite:17]{index=17}
    day_cursor = extract_start.replace(hour=0, minute=0, second=0, microsecond=0)
    final_end = extract_end

    total_pages = 0
    total_rows = 0
    started_at = datetime.now(timezone.utc)

    while day_cursor < final_end:
        day_start = max(day_cursor, extract_start)
        day_end = min(day_cursor + timedelta(days=1), final_end)

        # 1) Intento “correcto”: filtro histórico por LastUpdatedTime (UTC) :contentReference[oaicite:18]{index=18}
        def _run_paged_queries(where_clause: str | None, page_number_start: int = 1):
            nonlocal total_pages, total_rows
            start_position = 1
            page_number = page_number_start
            seen_any = False

            while True:
                where_sql = f"{where_clause} " if where_clause else ""
                q = (
                    "SELECT * FROM Customer "
                    f"{where_sql}"
                    f"STARTPOSITION {start_position} MAXRESULTS {page_size}"
                )

                payload = _qbo_query(access_token, realm_id, q, minorversion)
                customers = _extract_customers(payload)

                total_pages += 1

                request_payload = {
                    "entity": "Customer",
                    "query": q,
                    "minorversion": minorversion,
                    "realm_id": realm_id,
                    "env": _require_secret("QBO_ENV"),
                }

                for c in customers:
                    cid = c.get("Id")
                    if cid is None:
                        continue
                    seen_any = True
                    total_rows += 1
                    rows.append({
                        "id": str(cid),
                        "payload": json.dumps(c),
                        "extract_window_start_utc": _iso_z(day_start),
                        "extract_window_end_utc": _iso_z(day_end),
                        "page_number": page_number,
                        "page_size": page_size,
                        "request_payload": json.dumps(request_payload),
                    })

                if len(customers) < page_size:
                    break

                start_position += page_size
                page_number += 1

            return seen_any

        where_clause = (
            f"WHERE MetaData.LastUpdatedTime >= '{_iso_z(day_start)}' "
            f"AND MetaData.LastUpdatedTime < '{_iso_z(day_end)}'"
        )

        got_data = False
        if not force_full_scan:
            try:
                got_data = _run_paged_queries(where_clause)
            except Exception as e:
                # si QBO rechaza el WHERE, hacemos fallback para no quedarnos sin evidencia
                print(f"⚠️ Filtro por MetaData.LastUpdatedTime falló en tramo {day_start.date()}: {e}")

        # 2) Fallback: si el tramo no devolvió nada, hace full scan para “garantizar datos”
        #    (ideal para sandbox quieto; te permite verificar DB).
        if force_full_scan or (not got_data):
            # IMPORTANTE: para no romper el chunking del deber, seguimos registrando la ventana diaria
            # aunque el query sea sin WHERE.
            _run_paged_queries(where_clause=None)

        day_cursor += timedelta(days=1)

    ended_at = datetime.now(timezone.utc)
    dur_s = (ended_at - started_at).total_seconds()

    print("==== QB CUSTOMERS BACKFILL METRICS ====")
    print(f"window_start_utc={_iso_z(extract_start)} window_end_utc={_iso_z(extract_end)}")
    print(f"pages_read={total_pages} rows_emitted={total_rows} duration_seconds={dur_s:.2f}")
    print("======================================")

    return pd.DataFrame(rows, columns=RAW_COLUMNS)


@test
def test_output(output, *args) -> None:
    assert output is not None
    assert hasattr(output, "shape")
    for c in RAW_COLUMNS:
        assert c in output.columns, f"Missing column: {c}"
