"""
bot.py — Delta Exchange India Scalp Bot
========================================
Capital  : ₹300  (uses 25% per trade = ₹75 max per slot)
Slots    : 4 simultaneous trades
SL       : ≤ ₹15 per trade (hard cap)
TP       : 2× SL (risk:reward 1:2)
Interval : every 10 minutes (force-scans all strategies)
Test trade: 1 INR market order on startup to verify connectivity

Strategies (auto-loaded from strategies/):
  • scalp_ema   — EMA 5/13 ribbon crossover
  • scalp_bb    — Bollinger Band squeeze breakout
  • scalp_stoch — Stochastic RSI reversal
  • scalp_vwap  — VWAP momentum cross

Fixes vs previous version:
  • Correct HMAC auth (no DeltaRestClient dependency)
  • RISK_PCT parsed with .strip() to avoid whitespace ValueError
  • 401 fix: proper timestamp + signature in every signed request
"""

import os
import sys
import time
import importlib
import logging
from pathlib import Path

import exchange

# ── Logging ─────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("DeltaBot")

# ── Config from env (all .strip() to prevent whitespace bugs) ────────────────
TOTAL_CAPITAL   = float(os.getenv("TOTAL_CAPITAL",   "300").strip())
MAX_SLOTS       = int(os.getenv("MAX_SLOTS",         "4").strip())
SLOT_PCT        = float(os.getenv("SLOT_PCT",        "0.25").strip())   # 25% per trade
MAX_SL_INR      = float(os.getenv("MAX_SL_INR",      "15").strip())     # ₹15 hard SL cap
RR_RATIO        = float(os.getenv("RR_RATIO",        "2.0").strip())    # TP = 2× SL
SCAN_INTERVAL   = int(os.getenv("SCAN_INTERVAL",     "600").strip())    # 10 min in seconds
TEST_SYMBOL     = os.getenv("TEST_SYMBOL",           "XRPUSD").strip()
CANDLE_RES      = os.getenv("CANDLE_RES",            "5").strip()       # 5m candles

SLOT_CAPITAL    = TOTAL_CAPITAL * SLOT_PCT   # ₹75 per trade

# ── Load all strategy modules ────────────────────────────────────────────────
STRATEGY_DIR = Path(__file__).parent / "strategies"

def load_strategies() -> list:
    strats = []
    for f in sorted(STRATEGY_DIR.glob("scalp_*.py")):
        mod_name = f"strategies.{f.stem}"
        try:
            mod = importlib.import_module(mod_name)
            strats.append(mod)
            log.info(f"  ✓ Loaded strategy: {mod.NAME}")
        except Exception as e:
            log.error(f"  ✗ Failed to load {f.stem}: {e}")
    return strats

# ── Open trade tracking ──────────────────────────────────────────────────────
# { symbol: { side, entry_price, size, sl_price, tp_price, order_id, strategy } }
open_trades: dict = {}


def slots_free() -> int:
    return MAX_SLOTS - len(open_trades)


def calc_trade(symbol: str, side: str, entry_price: float):
    """
    Given entry price and slot capital, calculate:
      - contract size (integer, minimum 1)
      - SL price (capped so SL loss ≤ MAX_SL_INR)
      - TP price (RR_RATIO × SL distance)
    Returns (size, sl_price, tp_price, sl_inr, tp_inr)
    """
    # Price per contract ≈ entry_price in USD terms, but Delta uses INR margin
    # We use SLOT_CAPITAL / entry_price to approximate contracts
    raw_size = SLOT_CAPITAL / entry_price
    size     = max(1, int(raw_size))

    # SL distance: how many price units can we lose before hitting ₹15?
    # loss_INR ≈ size × price_move   (simplified, ignores leverage funding)
    # → price_move = MAX_SL_INR / size
    sl_dist = MAX_SL_INR / size
    tp_dist = sl_dist * RR_RATIO

    if side == "buy":
        sl_price = round(entry_price - sl_dist, 4)
        tp_price = round(entry_price + tp_dist, 4)
    else:
        sl_price = round(entry_price + sl_dist, 4)
        tp_price = round(entry_price - tp_dist, 4)

    sl_inr = size * sl_dist
    tp_inr = size * tp_dist
    return size, sl_price, tp_price, sl_inr, tp_inr


def open_trade(symbol: str, side: str, entry_price: float, strategy_name: str):
    size, sl_price, tp_price, sl_inr, tp_inr = calc_trade(symbol, side, entry_price)

    log.info(
        f"  → OPEN {side.upper()} {symbol} | size={size} "
        f"entry={entry_price:.4f} SL={sl_price:.4f}(₹{sl_inr:.1f}) "
        f"TP={tp_price:.4f}(₹{tp_inr:.1f}) [{strategy_name}]"
    )

    try:
        resp = exchange.place_order(symbol, side, size)
        order_id = resp.get("result", {}).get("id")
        open_trades[symbol] = {
            "side":          side,
            "entry":         entry_price,
            "size":          size,
            "sl":            sl_price,
            "tp":            tp_price,
            "order_id":      order_id,
            "strategy":      strategy_name,
            "open_time":     time.time(),
        }
        log.info(f"  ✓ Order placed. ID={order_id}")
    except Exception as e:
        log.error(f"  ✗ Order failed for {symbol}: {e}")


def close_trade(symbol: str, reason: str):
    t = open_trades.get(symbol)
    if not t:
        return
    close_side = "sell" if t["side"] == "buy" else "buy"
    log.info(f"  ← CLOSE {symbol} [{reason}]")
    try:
        exchange.place_order(symbol, close_side, t["size"], reduce_only=True)
        del open_trades[symbol]
    except Exception as e:
        log.error(f"  ✗ Close order failed for {symbol}: {e}")


def monitor_exits():
    """Check SL/TP for all open trades."""
    for symbol, t in list(open_trades.items()):
        try:
            ticker = exchange.get_ticker(symbol)
            price  = float(ticker.get("close", 0) or ticker.get("mark_price", 0))
            if price <= 0:
                continue

            if t["side"] == "buy":
                if price <= t["sl"]:
                    close_trade(symbol, f"SL HIT @ {price:.4f}")
                elif price >= t["tp"]:
                    close_trade(symbol, f"TP HIT @ {price:.4f}")
            else:
                if price >= t["sl"]:
                    close_trade(symbol, f"SL HIT @ {price:.4f}")
                elif price <= t["tp"]:
                    close_trade(symbol, f"TP HIT @ {price:.4f}")
        except Exception as e:
            log.warning(f"  Monitor error for {symbol}: {e}")


def run_test_trade():
    """Place a tiny 1-INR test trade on startup to verify auth + connectivity."""
    log.info(f"━━ TEST TRADE: placing 1-contract market buy on {TEST_SYMBOL} ━━")
    try:
        ticker = exchange.get_ticker(TEST_SYMBOL)
        price  = float(ticker.get("close", 1))
        resp   = exchange.place_order(TEST_SYMBOL, "buy", 1)
        oid    = resp.get("result", {}).get("id")
        log.info(f"  ✓ Test buy placed (ID={oid}). Closing immediately...")
        time.sleep(2)
        exchange.place_order(TEST_SYMBOL, "sell", 1, reduce_only=True)
        log.info(f"  ✓ Test trade closed. API auth is working!\n")
    except Exception as e:
        log.error(f"  ✗ TEST TRADE FAILED: {e}")
        log.error("  Check DELTA_API_KEY / DELTA_API_SECRET env vars!")
        sys.exit(1)


def scan_and_trade(strategies: list):
    """
    For each free slot, scan all products with all strategies.
    First strategy+symbol that fires gets the slot.
    """
    if slots_free() <= 0:
        log.info("  All slots full — skipping scan.")
        return

    log.info(f"  Scanning… ({slots_free()}/{MAX_SLOTS} slots free)")

    try:
        products = exchange.get_products()
    except Exception as e:
        log.error(f"  Could not fetch products: {e}")
        return

    # Filter to liquid USDT/USD perps with reasonable price
    symbols = [
        p["symbol"] for p in products
        if "USD" in p.get("symbol", "")
        and p.get("symbol") not in open_trades
    ][:80]   # cap at 80 to keep scan fast

    fired = 0
    for strat in strategies:
        if slots_free() <= 0:
            break
        for symbol in symbols:
            if symbol in open_trades:
                continue
            if slots_free() <= 0:
                break
            try:
                candles = exchange.get_candles(symbol, CANDLE_RES, 60)
                if not candles or len(candles) < 30:
                    continue
                sig = strat.signal(candles)
                if sig:
                    ticker = exchange.get_ticker(symbol)
                    price  = float(ticker.get("close", 0) or ticker.get("mark_price", 0))
                    if price > 0:
                        open_trade(symbol, sig, price, strat.NAME)
                        fired += 1
                        time.sleep(0.5)   # rate limit buffer
            except Exception as e:
                log.debug(f"  Skip {symbol} ({strat.NAME}): {e}")
                continue

    if fired == 0:
        log.info("  No signals found this scan.")


def main():
    log.info("=" * 55)
    log.info("  Delta Exchange Scalp Bot  |  Capital: ₹300")
    log.info(f"  Slots: {MAX_SLOTS}  |  Per trade: ₹{SLOT_CAPITAL:.0f}  |  Max SL: ₹{MAX_SL_INR}")
    log.info(f"  Scan every: {SCAN_INTERVAL // 60} min  |  TP:SL = {RR_RATIO}:1")
    log.info("=" * 55)

    strategies = load_strategies()
    if not strategies:
        log.error("No strategies loaded — check strategies/ folder.")
        sys.exit(1)

    # Startup test trade
    run_test_trade()

    log.info("  Bot running! Starting main loop...\n")

    while True:
        cycle_start = time.time()

        log.info(f"── Cycle @ {time.strftime('%H:%M:%S')} | Open trades: {len(open_trades)}/{MAX_SLOTS} ──")

        # 1. Check SL/TP on open trades
        if open_trades:
            monitor_exits()

        # 2. Scan for new entries
        scan_and_trade(strategies)

        # 3. Log open positions
        if open_trades:
            log.info("  Open positions:")
            for sym, t in open_trades.items():
                age = int((time.time() - t["open_time"]) / 60)
                log.info(f"    {sym} {t['side']} entry={t['entry']:.4f} SL={t['sl']:.4f} TP={t['tp']:.4f} age={age}m [{t['strategy']}]")

        # 4. Sleep remainder of interval (exit monitors during wait)
        elapsed = time.time() - cycle_start
        sleep_time = max(0, SCAN_INTERVAL - elapsed)
        log.info(f"  Sleeping {sleep_time / 60:.1f} min...\n")

        # Sleep in 30s chunks so we can monitor exits more frequently
        slept = 0
        while slept < sleep_time:
            chunk = min(30, sleep_time - slept)
            time.sleep(chunk)
            slept += chunk
            if open_trades:
                monitor_exits()


if __name__ == "__main__":
    main()
