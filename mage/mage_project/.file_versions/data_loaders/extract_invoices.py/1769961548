import base64
import json
import time
import random
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
    value = get_secret_value(key)
    if not value:
        raise ValueError(f"Missing required Mage Secret: {key}")
    return value


def _get_base_url() -> str:
    env = _require_secret("QBO_ENV").strip().lower()
    if env == "sandbox":
        return "https://sandbox-quickbooks.api.intuit.com"
    if env in ("prod", "production"):
        return "https://quickbooks.api.intuit.com"
    raise ValueError("QBO_ENV must be 'sandbox' or 'prod'")


def _parse_iso_utc(value: str) -> datetime:
    value = value.strip()
    if len(value) == 10:
        return datetime.fromisoformat(value).replace(tzinfo=timezone.utc)
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _iso_z(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _refresh_access_token() -> str:
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

    response = requests.post(token_url, headers=headers, data=data, timeout=30)

    if not response.ok:
        try:
            err = response.json()
            code = err.get("error")
            desc = err.get("error_description", "")
        except Exception:
            code = None
            desc = response.text

        if code == "invalid_grant":
            raise RuntimeError(
                "Token refresh failed: invalid_grant. "
                "El refresh token es inválido/expiró o no corresponde al entorno/app. "
                "Actualiza el secret QBO_REFRESH_TOKEN."
            )

        raise RuntimeError(f"Token refresh failed ({response.status_code}): {desc}")

    payload = response.json()
    new_refresh = payload.get("refresh_token")
    if new_refresh and new_refresh != refresh_token:
        print("Se recibió un refresh token nuevo (rotación). Actualiza el secret QBO_REFRESH_TOKEN.")

    return payload["access_token"]


def _qbo_request_with_retries(
    access_token: str,
    realm_id: str,
    query: str,
    minorversion: str,
    max_retries: int = 5,
) -> dict:
    base_url = _get_base_url()
    url = f"{base_url}/v3/company/{realm_id}/query"

    headers = {"Authorization": f"Bearer {access_token}", "Accept": "application/json"}
    params = {"query": query, "minorversion": minorversion}

    attempt = 0
    consecutive_failures = 0

    while True:
        attempt += 1
        response = requests.get(url, headers=headers, params=params, timeout=30)

        if response.ok:
            return response.json()

        status = response.status_code

        if status == 401 and attempt <= max_retries:
            print("Auth expired. Refreshing access token and retrying.")
            access_token = _refresh_access_token()
            headers["Authorization"] = f"Bearer {access_token}"
            continue

        if status in (429, 500, 502, 503, 504) and attempt <= max_retries:
            consecutive_failures += 1
            backoff = min(2 ** attempt, 30) + random.uniform(0, 1)
            print(f"Request failed ({status}). Retry {attempt}/{max_retries} in {backoff:.1f}s.")
            time.sleep(backoff)

            if consecutive_failures >= max_retries:
                raise RuntimeError(f"Circuit breaker opened after {consecutive_failures} failures.")
            continue

        raise RuntimeError(f"QBO request failed ({status}): {response.text}")


def _extract_invoices(payload: dict) -> list:
    return (payload.get("QueryResponse", {}) or {}).get("Invoice", []) or []


@data_loader
def load_data_from_api(*args, **kwargs):
    """
    Backfill histórico de Invoices desde QuickBooks Online.

    Parámetros obligatorios (desde trigger):
      - fecha_inicio (ISO, UTC)
      - fecha_fin (ISO, UTC)

    Parámetros opcionales:
      - page_size (int, default 200)
      - minorversion (str, default 75)
    """
    realm_id = _require_secret("QBO_REALM_ID")
    page_size = int(kwargs.get("page_size") or 200)
    minorversion = str(kwargs.get("minorversion") or "75")

    if not kwargs.get("fecha_inicio") or not kwargs.get("fecha_fin"):
        raise ValueError("fecha_inicio y fecha_fin deben ser provistas por el trigger")

    extract_start = _parse_iso_utc(kwargs["fecha_inicio"])
    extract_end = _parse_iso_utc(kwargs["fecha_fin"])
    if extract_end <= extract_start:
        raise ValueError("fecha_fin debe ser mayor que fecha_inicio")

    access_token = _refresh_access_token()
    rows = []

    overall_start = datetime.now(timezone.utc)
    day_cursor = extract_start.replace(hour=0, minute=0, second=0, microsecond=0)

    while day_cursor < extract_end:
        day_start = max(day_cursor, extract_start)
        day_end = min(day_cursor + timedelta(days=1), extract_end)

        tramo_start = datetime.now(timezone.utc)
        tramo_pages = 0
        tramo_rows = 0

        print(f"Processing Invoices window {_iso_z(day_start)} → {_iso_z(day_end)}")

        start_position = 1
        page_number = 1

        while True:
            query = (
                "SELECT * FROM Invoice "
                f"WHERE MetaData.LastUpdatedTime >= '{_iso_z(day_start)}' "
                f"AND MetaData.LastUpdatedTime < '{_iso_z(day_end)}' "
                f"STARTPOSITION {start_position} MAXRESULTS {page_size}"
            )

            payload = _qbo_request_with_retries(access_token, realm_id, query, minorversion)
            invoices = _extract_invoices(payload)

            tramo_pages += 1

            request_payload = {
                "entity": "Invoice",
                "query": query,
                "minorversion": minorversion,
                "realm_id": realm_id,
                "env": _require_secret("QBO_ENV"),
            }

            for inv in invoices:
                iid = inv.get("Id")
                if not iid:
                    continue
                rows.append({
                    "id": str(iid),
                    "payload": json.dumps(inv),
                    "extract_window_start_utc": _iso_z(day_start),
                    "extract_window_end_utc": _iso_z(day_end),
                    "page_number": page_number,
                    "page_size": page_size,
                    "request_payload": json.dumps(request_payload),
                })
                tramo_rows += 1

            if len(invoices) < page_size:
                break

            start_position += page_size
            page_number += 1

        tramo_end = datetime.now(timezone.utc)
        tramo_duration = (tramo_end - tramo_start).total_seconds()
        print(f"Window completed | pages={tramo_pages} rows={tramo_rows} duration_s={tramo_duration:.2f}")

        day_cursor += timedelta(days=1)

    overall_end = datetime.now(timezone.utc)
    overall_duration = (overall_end - overall_start).total_seconds()

    print("==== QB INVOICES BACKFILL SUMMARY ====")
    print(f"window_start_utc={_iso_z(extract_start)}")
    print(f"window_end_utc={_iso_z(extract_end)}")
    print(f"total_rows={len(rows)}")
    print(f"duration_seconds={overall_duration:.2f}")
    print("=====================================")

    return pd.DataFrame(rows, columns=RAW_COLUMNS)


@test
def test_output(output, *args):
    assert output is not None
    for col in RAW_COLUMNS:
        assert col in output.columns
