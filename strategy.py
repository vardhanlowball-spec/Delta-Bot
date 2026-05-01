import pandas as pd
import numpy as np


def calculate_kyle_ribbon(df, fast=5, slow=20, signal=9):
    """
    KyleRibbon Strategy:
    - Uses EMA ribbon (multiple EMAs) to detect trend direction
    - Entry: when fast EMAs cross above slow EMAs (bullish ribbon)
    - Exit: when fast EMAs cross below slow EMAs (bearish ribbon)
    - Additional RSI filter to avoid overbought/oversold entries
    """
    # EMA Ribbon - 8 EMAs from fast to slow
    periods = [3, 5, 8, 10, 12, 15, fast, slow]
    for p in periods:
        df[f'ema_{p}'] = df['close'].ewm(span=p, adjust=False).mean()

    # Ribbon direction: count how many fast EMAs are above slow EMAs
    fast_emas = [df[f'ema_{p}'] for p in [3, 5, 8, 10]]
    slow_emas = [df[f'ema_{p}'] for p in [12, 15, fast, slow]]

    bullish_count = sum(f > s for f, s in zip(fast_emas, slow_emas))
    df['ribbon_bullish'] = bullish_count == 4  # All fast above all slow

    bearish_count = sum(f < s for f, s in zip(fast_emas, slow_emas))
    df['ribbon_bearish'] = bearish_count == 4  # All fast below all slow

    # RSI
    delta = df['close'].diff()
    gain = delta.where(delta > 0, 0).rolling(14).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(14).mean()
    rs = gain / loss
    df['rsi'] = 100 - (100 / (1 + rs))

    # MACD for confirmation
    ema_fast = df['close'].ewm(span=12, adjust=False).mean()
    ema_slow = df['close'].ewm(span=26, adjust=False).mean()
    df['macd'] = ema_fast - ema_slow
    df['macd_signal'] = df['macd'].ewm(span=signal, adjust=False).mean()
    df['macd_hist'] = df['macd'] - df['macd_signal']

    # ATR for stop loss calculation
    high_low = df['high'] - df['low']
    high_close = (df['high'] - df['close'].shift()).abs()
    low_close = (df['low'] - df['close'].shift()).abs()
    true_range = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
    df['atr'] = true_range.rolling(14).mean()

    return df


def get_signal(df):
    """
    Returns: 'buy', 'sell', or None
    """
    if len(df) < 30:
        return None

    latest = df.iloc[-1]
    prev = df.iloc[-2]

    # BUY signal: ribbon turns bullish + RSI not overbought + MACD confirms
    if (
        latest['ribbon_bullish'] and
        not prev['ribbon_bullish'] and  # fresh crossover
        latest['rsi'] < 65 and
        latest['macd_hist'] > 0
    ):
        return 'buy'

    # SELL signal: ribbon turns bearish + RSI not oversold + MACD confirms
    if (
        latest['ribbon_bearish'] and
        not prev['ribbon_bearish'] and  # fresh crossover
        latest['rsi'] > 35 and
        latest['macd_hist'] < 0
    ):
        return 'sell'

    return None
