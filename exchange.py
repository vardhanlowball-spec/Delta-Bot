"""
exchange.py — Delta Exchange India (auth fixed per official docs)
Signature: method + timestamp + path + query_string + body
User-Agent header required to avoid 4xx errors.
"""

import hashlib
import hmac
import json
import time
import os
import requests

API_KEY    = os.getenv("DELTA_API_KEY",    "").strip()
API_SECRET = os.getenv("DELTA_API_SECRET", "").strip()
BASE_URL   = "https://api.india.delta.exchange"


def _sign(method: str, path: str, query_string: str = "", body: str = "") -> dict:
    timestamp = str(int(time.time()))
    # Official format: method + timestamp + path + query_string + body
    # query_string must include the '?' e.g. "?product_id=1&state=open"
    message   = method + timestamp + path + query_string + body
    signature = hmac.new(
        API_SECRET.encode("utf-8"),
        message.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return {
        "api-key":      API_KEY,
        "timestamp":    timestamp,
        "signature":    signature,
        "Content-Type": "application/json",
        "User-Agent":   "python-rest-client",   # required by Delta
    }


def get(path: str, params: dict = None) -> dict:
    query_string = ""
    if params:
        query_string = "?" + "&".join(f"{k}={v}" for k, v in params.items())
    headers = _sign("GET", path, query_string)
    resp = requests.get(BASE_URL + path, headers=headers, params=params, timeout=10)
    resp.raise_for_status()
    return resp.json()


def post(path: str, body: dict) -> dict:
    body_str = json.dumps(body, separators=(",", ":"))
    headers  = _sign("POST", path, "", body_str)
    resp = requests.post(BASE_URL + path, headers=headers, data=body_str, timeout=10)
    resp.raise_for_status()
    return resp.json()


def delete(path: str, body: dict) -> dict:
    body_str = json.dumps(body, separators=(",", ":"))
    headers  = _sign("DELETE", path, "", body_str)
    resp = requests.delete(BASE_URL + path, headers=headers, data=body_str, timeout=10)
    resp.raise_for_status()
    return resp.json()


# ── Public helpers ───────────────────────────────────────────────────────────

def get_products() -> list:
    r = requests.get(BASE_URL + "/v2/products",
                     headers={"User-Agent": "python-rest-client"}, timeout=10)
    r.raise_for_status()
    return [p for p in r.json().get("result", [])
            if p.get("contract_type") == "perpetual_futures"]


def get_ticker(symbol: str) -> dict:
    r = requests.get(BASE_URL + f"/v2/tickers/{symbol}",
                     headers={"User-Agent": "python-rest-client"}, timeout=10)
    r.raise_for_status()
    return r.json().get("result", {})


def get_candles(symbol: str, resolution: str = "5", count: int = 60) -> list:
    end   = int(time.time())
    start = end - int(resolution) * 60 * count
    r = requests.get(
        BASE_URL + "/v2/history/candles",
        headers={"User-Agent": "python-rest-client"},
        params={"resolution": resolution, "symbol": symbol, "start": start, "end": end},
        timeout=10,
    )
    r.raise_for_status()
    return r.json().get("result", [])


def get_wallet_balance() -> float:
    data = get("/v2/wallet/balances")
    for b in data.get("result", []):
        if b.get("asset_symbol") == "INR":
            return float(b.get("available_balance", 0))
    return 0.0


def get_positions() -> list:
    return get("/v2/positions/margined").get("result", [])


def place_order(symbol: str, side: str, size: int,
                order_type: str = "market_order",
                limit_price: float = None,
                reduce_only: bool = False) -> dict:
    body = {
        "product_symbol": symbol,
        "size":           size,
        "side":           side,
        "order_type":     order_type,
        "reduce_only":    reduce_only,
    }
    if limit_price:
        body["limit_price"] = str(limit_price)
    return post("/v2/orders", body)


def get_open_orders() -> list:
    return get("/v2/orders", {"state": "open"}).get("result", [])
