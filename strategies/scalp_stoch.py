"""
strategies/scalp_stoch.py
Strategy: Stochastic RSI Reversal
Signals : StochRSI oversold/overbought + MACD cross
Timeframe: 5m
"""

import pandas as pd


NAME = "STOCHRSI"


def _candles_to_df(candles: list) -> pd.DataFrame:
    df = pd.DataFrame(candles, columns=["time", "open", "high", "low", "close", "volume"])
    for col in ["open", "high", "low", "close", "volume"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    return df.dropna().reset_index(drop=True)


def signal(candles: list) -> str | None:
    if len(candles) < 50:
        return None

    df = _candles_to_df(candles)

    # RSI
    delta = df["close"].diff()
    gain  = delta.clip(lower=0).rolling(14).mean()
    loss  = (-delta.clip(upper=0)).rolling(14).mean()
    rs    = gain / loss.replace(0, 1e-9)
    df["rsi"] = 100 - 100 / (1 + rs)

    # Stochastic RSI
    rsi_min = df["rsi"].rolling(14).min()
    rsi_max = df["rsi"].rolling(14).max()
    df["stoch_rsi"] = (df["rsi"] - rsi_min) / (rsi_max - rsi_min + 1e-9) * 100
    df["stoch_k"]   = df["stoch_rsi"].rolling(3).mean()
    df["stoch_d"]   = df["stoch_k"].rolling(3).mean()

    # MACD
    df["ema12"] = df["close"].ewm(span=12, adjust=False).mean()
    df["ema26"] = df["close"].ewm(span=26, adjust=False).mean()
    df["macd"]  = df["ema12"] - df["ema26"]
    df["sig"]   = df["macd"].ewm(span=9, adjust=False).mean()
    df["hist"]  = df["macd"] - df["sig"]

    c = df.iloc[-1]
    p = df.iloc[-2]

    stoch_cross_up   = p["stoch_k"] <= p["stoch_d"] and c["stoch_k"] > c["stoch_d"]
    stoch_cross_down = p["stoch_k"] >= p["stoch_d"] and c["stoch_k"] < c["stoch_d"]
    macd_rising      = c["hist"] > p["hist"]
    macd_falling     = c["hist"] < p["hist"]

    # BUY: stoch crosses up from oversold + MACD hist rising
    if stoch_cross_up and c["stoch_k"] < 25 and macd_rising:
        return "buy"

    # SELL: stoch crosses down from overbought + MACD hist falling
    if stoch_cross_down and c["stoch_k"] > 75 and macd_falling:
        return "sell"

    return None
