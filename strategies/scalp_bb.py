"""
strategies/scalp_bb.py
Strategy: Bollinger Band Squeeze Breakout
Signals : BB squeeze -> price breaks out with volume
Timeframe: 5m
"""

import pandas as pd


NAME = "BB_SQUEEZE"


def _candles_to_df(candles: list) -> pd.DataFrame:
    df = pd.DataFrame(candles, columns=["time", "open", "high", "low", "close", "volume"])
    for col in ["open", "high", "low", "close", "volume"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    return df.dropna().reset_index(drop=True)


def signal(candles: list) -> str | None:
    if len(candles) < 30:
        return None

    df = _candles_to_df(candles)

    # Bollinger Bands
    df["sma20"]   = df["close"].rolling(20).mean()
    df["std20"]   = df["close"].rolling(20).std()
    df["bb_up"]   = df["sma20"] + 2.0 * df["std20"]
    df["bb_dn"]   = df["sma20"] - 2.0 * df["std20"]
    df["bb_w"]    = (df["bb_up"] - df["bb_dn"]) / df["sma20"]

    # Keltner Channels (for squeeze detection)
    df["tr"]   = df[["high", "low", "close"]].apply(
        lambda r: max(r["high"] - r["low"],
                      abs(r["high"] - df["close"].shift(1).iloc[r.name] if r.name > 0 else 0),
                      abs(r["low"]  - df["close"].shift(1).iloc[r.name] if r.name > 0 else 0)),
        axis=1,
    )
    df["atr14"] = df["tr"].rolling(14).mean()
    df["kc_up"] = df["sma20"] + 1.5 * df["atr14"]
    df["kc_dn"] = df["sma20"] - 1.5 * df["atr14"]

    df["squeeze"] = (df["bb_up"] < df["kc_up"]) & (df["bb_dn"] > df["kc_dn"])

    # Volume
    df["vol_avg"] = df["volume"].rolling(20).mean()

    c = df.iloc[-1]
    p = df.iloc[-2]

    # Squeeze just released (was squeezed, now not)
    squeeze_release = bool(p["squeeze"]) and not bool(c["squeeze"])

    if not squeeze_release:
        return None

    vol_ok = c["volume"] > c["vol_avg"] * 1.2

    if not vol_ok:
        return None

    # Direction of breakout
    if c["close"] > c["bb_up"]:
        return "buy"
    if c["close"] < c["bb_dn"]:
        return "sell"

    return None
