"""
exchange.py — Delta Exchange India REST client
Fixes:
  • Correct HMAC-SHA256 signature for v2 API
  • Proper headers including timestamp + signature
  • No DeltaRestClient dependency (pure requests)
"""

import hashlib
import hmac
import time
import os
import requests

API_KEY    = os.getenv("DELTA_API_KEY", "").strip()
API_SECRET = os.getenv("DELTA_API_SECRET", "").strip()
BASE_URL   = "https://api.india.delta.exchange"


def _sign(method: str, path: str, query: str, body: str) -> dict:
    """Build signed headers for Delta Exchange v2."""
    timestamp = str(int(time.time()))
    # Signature payload: method + timestamp + path + query_string + body
    payload = method + timestamp + path + (("?" + query) if query else "") + body
    signature = hmac.new(
        API_SECRET.encode(), payload.encode(), hashlib.sha256
    ).hexdigest()
    return {
        "api-key":       API_KEY,
        "timestamp":     timestamp,
        "signature":     signature,
        "Content-Type":  "application/json",
        "Accept":        "application/json",
    }


def get(path: str, params: dict = None) -> dict:
    query = "&".join(f"{k}={v}" for k, v in (params or {}).items())
    headers = _sign("GET", path, query, "")
    url = BASE_URL + path + (("?" + query) if query else "")
    resp = requests.get(url, headers=headers, timeout=10)
    resp.raise_for_status()
    return resp.json()


def post(path: str, body: dict) -> dict:
    import json
    body_str = json.dumps(body, separators=(",", ":"))
    headers = _sign("POST", path, "", body_str)
    resp = requests.post(BASE_URL + path, headers=headers, data=body_str, timeout=10)
    resp.raise_for_status()
    return resp.json()


def delete(path: str, body: dict) -> dict:
    import json
    body_str = json.dumps(body, separators=(",", ":"))
    headers = _sign("DELETE", path, "", body_str)
    resp = requests.delete(BASE_URL + path, headers=headers, data=body_str, timeout=10)
    resp.raise_for_status()
    return resp.json()


# ── Public helpers ──────────────────────────────────────────────────────────

def get_products() -> list:
    """All perpetual futures products."""
    r = requests.get(BASE_URL + "/v2/products", timeout=10)
    r.raise_for_status()
    data = r.json()
    return [p for p in data.get("result", []) if p.get("contract_type") == "perpetual_futures"]


def get_ticker(symbol: str) -> dict:
    r = requests.get(BASE_URL + f"/v2/tickers/{symbol}", timeout=10)
    r.raise_for_status()
    return r.json().get("result", {})


def get_candles(symbol: str, resolution: str = "5", count: int = 100) -> list:
    """Fetch OHLCV candles. resolution in minutes as string."""
    end   = int(time.time())
    start = end - int(resolution) * 60 * count
    r = requests.get(
        BASE_URL + "/v2/history/candles",
        params={"resolution": resolution, "symbol": symbol, "start": start, "end": end},
        timeout=10,
    )
    r.raise_for_status()
    return r.json().get("result", [])


def get_wallet_balance() -> float:
    """Returns available INR balance."""
    data = get("/v2/wallet/balances")
    for b in data.get("result", []):
        if b.get("asset_symbol") == "INR":
            return float(b.get("available_balance", 0))
    return 0.0


def get_positions() -> list:
    data = get("/v2/positions/margined")
    return data.get("result", [])


def place_order(symbol: str, side: str, size: int, order_type: str = "market_order",
                limit_price: float = None, reduce_only: bool = False) -> dict:
    body = {
        "product_symbol": symbol,
        "size":           size,
        "side":           side,            # "buy" or "sell"
        "order_type":     order_type,
        "reduce_only":    reduce_only,
    }
    if limit_price:
        body["limit_price"] = str(limit_price)
    return post("/v2/orders", body)


def cancel_order(order_id: int, product_id: int) -> dict:
    return delete("/v2/orders", {"id": order_id, "product_id": product_id})


def get_open_orders() -> list:
    data = get("/v2/orders", {"state": "open"})
    return data.get("result", [])
