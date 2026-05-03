"""
strategies/scalp_ema.py
Strategy: EMA Ribbon Scalp
Signals : EMA 5/13 crossover + RSI < 55 + volume spike
Timeframe: 5m
"""

import pandas as pd


NAME = "EMA_SCALP"


def _candles_to_df(candles: list) -> pd.DataFrame:
    df = pd.DataFrame(candles, columns=["time", "open", "high", "low", "close", "volume"])
    for col in ["open", "high", "low", "close", "volume"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    return df.dropna().reset_index(drop=True)


def signal(candles: list) -> str | None:
    """Return 'buy', 'sell', or None."""
    if len(candles) < 30:
        return None

    df = _candles_to_df(candles)

    df["ema5"]  = df["close"].ewm(span=5,  adjust=False).mean()
    df["ema13"] = df["close"].ewm(span=13, adjust=False).mean()
    df["ema21"] = df["close"].ewm(span=21, adjust=False).mean()

    # RSI
    delta = df["close"].diff()
    gain  = delta.clip(lower=0).rolling(9).mean()
    loss  = (-delta.clip(upper=0)).rolling(9).mean()
    rs    = gain / loss.replace(0, 1e-9)
    df["rsi"] = 100 - 100 / (1 + rs)

    # Volume
    df["vol_avg"] = df["volume"].rolling(20).mean()

    c  = df.iloc[-1]   # current
    p  = df.iloc[-2]   # previous

    vol_ok = c["volume"] > c["vol_avg"] * 1.1

    # BUY: ema5 crosses above ema13, price above ema21, rsi not overbought
    if (p["ema5"] <= p["ema13"] and c["ema5"] > c["ema13"]
            and c["close"] > c["ema21"]
            and c["rsi"] < 60
            and vol_ok):
        return "buy"

    # SELL: ema5 crosses below ema13, price below ema21, rsi not oversold
    if (p["ema5"] >= p["ema13"] and c["ema5"] < c["ema13"]
            and c["close"] < c["ema21"]
            and c["rsi"] > 40
            and vol_ok):
        return "sell"

    return None
