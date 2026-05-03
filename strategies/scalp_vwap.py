"""
strategies/scalp_vwap.py
Strategy: VWAP + EMA Momentum
Signals : Price crosses VWAP with EMA trend confirmation + volume
Timeframe: 5m
"""

import pandas as pd


NAME = "VWAP_MOM"


def _candles_to_df(candles: list) -> pd.DataFrame:
    df = pd.DataFrame(candles, columns=["time", "open", "high", "low", "close", "volume"])
    for col in ["open", "high", "low", "close", "volume"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    return df.dropna().reset_index(drop=True)


def signal(candles: list) -> str | None:
    if len(candles) < 30:
        return None

    df = _candles_to_df(candles)

    # VWAP (rolling, not session-based — works for crypto)
    df["typical"] = (df["high"] + df["low"] + df["close"]) / 3
    df["cum_tv"]  = (df["typical"] * df["volume"]).rolling(20).sum()
    df["cum_v"]   = df["volume"].rolling(20).sum()
    df["vwap"]    = df["cum_tv"] / df["cum_v"].replace(0, 1e-9)

    # EMA trend filter
    df["ema8"]  = df["close"].ewm(span=8,  adjust=False).mean()
    df["ema21"] = df["close"].ewm(span=21, adjust=False).mean()

    # RSI momentum
    delta = df["close"].diff()
    gain  = delta.clip(lower=0).rolling(9).mean()
    loss  = (-delta.clip(upper=0)).rolling(9).mean()
    rs    = gain / loss.replace(0, 1e-9)
    df["rsi"] = 100 - 100 / (1 + rs)

    # Volume
    df["vol_avg"] = df["volume"].rolling(20).mean()

    c = df.iloc[-1]
    p = df.iloc[-2]

    vol_ok        = c["volume"] > c["vol_avg"] * 1.15
    trend_up      = c["ema8"] > c["ema21"]
    trend_down    = c["ema8"] < c["ema21"]
    cross_up_vwap = p["close"] <= p["vwap"] and c["close"] > c["vwap"]
    cross_dn_vwap = p["close"] >= p["vwap"] and c["close"] < c["vwap"]

    # BUY: price crosses above VWAP, trend is up, RSI has room
    if cross_up_vwap and trend_up and c["rsi"] < 65 and vol_ok:
        return "buy"

    # SELL: price crosses below VWAP, trend is down, RSI has room
    if cross_dn_vwap and trend_down and c["rsi"] > 35 and vol_ok:
        return "sell"

    return None
