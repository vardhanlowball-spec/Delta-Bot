import os
import time
import logging
import pandas as pd
from datetime import datetime
from exchange import DeltaClient
from strategy import calculate_kyle_ribbon, get_signal

# ── Logging ──────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler('bot.log')
    ]
)
logger = logging.getLogger(__name__)

# ── Config from environment ───────────────────────────────────────
API_KEY    = os.environ['DELTA_API_KEY']
API_SECRET = os.environ['DELTA_API_SECRET']

SYMBOL         = os.getenv('SYMBOL', 'ETHUSD')          # ETH/USDT Perpetual on Delta India
TIMEFRAME      = os.getenv('TIMEFRAME', '5')             # 5-minute candles
RISK_PCT       = float(os.getenv('RISK_PCT', '0.02'))    # 2% risk per trade
ATR_MULTIPLIER = float(os.getenv('ATR_MULTIPLIER', '2')) # Stop loss = 2x ATR
LOOP_SLEEP     = int(os.getenv('LOOP_SLEEP', '60'))      # Seconds between checks

# ── Bot State ─────────────────────────────────────────────────────
class Bot:
    def __init__(self):
        self.client = DeltaClient(API_KEY, API_SECRET)
        self.product_id = None
        self.position = None  # 'long', 'short', or None
        self.entry_price = None
        self.stop_loss = None
        self.contracts = 0

    def setup(self):
        logger.info(f"🚀 Starting KyleRibbon Bot | {SYMBOL} | {TIMEFRAME}m")
        product = self.client.get_product(SYMBOL)
        if not product:
            raise ValueError(f"Product {SYMBOL} not found on Delta India")
        self.product_id = product['id']
        self.contract_value = float(product.get('contract_value', 1))
        logger.info(f"✅ Product ID: {self.product_id} | Contract value: {self.contract_value}")

    def get_candles_df(self):
        raw = self.client.get_candles(SYMBOL, TIMEFRAME, limit=100)
        if not raw:
            return None
        df = pd.DataFrame(raw, columns=['time', 'open', 'high', 'low', 'close', 'volume'])
        df = df.astype({'open': float, 'high': float, 'low': float, 'close': float, 'volume': float})
        df = df.sort_values('time').reset_index(drop=True)
        return df

    def calculate_position_size(self, price: float, atr: float) -> int:
        balance = self.client.get_balance()
        usdt = balance.get('USDT', 0)
        if usdt <= 0:
            logger.warning("No USDT balance available")
            return 0

        risk_amount = usdt * RISK_PCT
        stop_distance = atr * ATR_MULTIPLIER
        if stop_distance <= 0:
            return 0

        # Contracts = risk_amount / (stop_distance * contract_value)
        contracts = int(risk_amount / (stop_distance * self.contract_value))
        contracts = max(1, contracts)
        logger.info(f"💰 Balance: {usdt:.2f} USDT | Risk: {risk_amount:.2f} | Contracts: {contracts}")
        return contracts

    def sync_position(self):
        positions = self.client.get_positions()
        for pos in positions:
            if pos.get('product_id') == self.product_id:
                size = float(pos.get('size', 0))
                if size > 0:
                    self.position = 'long'
                    self.contracts = int(size)
                elif size < 0:
                    self.position = 'short'
                    self.contracts = int(abs(size))
                else:
                    self.position = None
                    self.contracts = 0
                return
        self.position = None
        self.contracts = 0

    def check_stop_loss(self, current_price: float):
        if not self.position or not self.stop_loss:
            return
        if self.position == 'long' and current_price <= self.stop_loss:
            logger.warning(f"🛑 STOP LOSS HIT | Price: {current_price} | SL: {self.stop_loss}")
            self.close_position()
        elif self.position == 'short' and current_price >= self.stop_loss:
            logger.warning(f"🛑 STOP LOSS HIT | Price: {current_price} | SL: {self.stop_loss}")
            self.close_position()

    def open_long(self, price: float, atr: float):
        contracts = self.calculate_position_size(price, atr)
        if contracts == 0:
            return
        logger.info(f"📈 OPENING LONG | Price: {price} | Contracts: {contracts}")
        result = self.client.place_market_order(self.product_id, 'buy', contracts)
        if result.get('success'):
            self.position = 'long'
            self.entry_price = price
            self.stop_loss = price - (atr * ATR_MULTIPLIER)
            self.contracts = contracts
            logger.info(f"✅ Long opened | SL: {self.stop_loss:.2f}")
        else:
            logger.error(f"❌ Failed to open long: {result}")

    def open_short(self, price: float, atr: float):
        contracts = self.calculate_position_size(price, atr)
        if contracts == 0:
            return
        logger.info(f"📉 OPENING SHORT | Price: {price} | Contracts: {contracts}")
        result = self.client.place_market_order(self.product_id, 'sell', contracts)
        if result.get('success'):
            self.position = 'short'
            self.entry_price = price
            self.stop_loss = price + (atr * ATR_MULTIPLIER)
            self.contracts = contracts
            logger.info(f"✅ Short opened | SL: {self.stop_loss:.2f}")
        else:
            logger.error(f"❌ Failed to open short: {result}")

    def close_position(self):
        if not self.position:
            return
        logger.info(f"🔒 Closing {self.position} | Contracts: {self.contracts}")
        result = self.client.close_position(self.product_id, self.contracts, self.position)
        if result.get('success'):
            logger.info("✅ Position closed")
            self.position = None
            self.entry_price = None
            self.stop_loss = None
            self.contracts = 0
        else:
            logger.error(f"❌ Failed to close position: {result}")

    def run(self):
        self.setup()

        while True:
            try:
                logger.info(f"--- Checking {SYMBOL} @ {datetime.utcnow().strftime('%H:%M:%S')} UTC ---")

                # Sync real position from exchange
                self.sync_position()

                # Get market data
                df = self.get_candles_df()
                if df is None or len(df) < 30:
                    logger.warning("Not enough candle data, skipping...")
                    time.sleep(LOOP_SLEEP)
                    continue

                # Run strategy
                df = calculate_kyle_ribbon(df)
                signal = get_signal(df)

                latest = df.iloc[-1]
                price = float(latest['close'])
                atr = float(latest['atr'])

                logger.info(f"Price: {price} | RSI: {latest['rsi']:.1f} | ATR: {atr:.2f} | Signal: {signal} | Position: {self.position}")

                # Stop loss check
                self.check_stop_loss(price)

                # Signal handling
                if signal == 'buy':
                    if self.position == 'short':
                        logger.info("Reversing short → long")
                        self.close_position()
                        time.sleep(2)
                        self.open_long(price, atr)
                    elif self.position is None:
                        self.open_long(price, atr)
                    else:
                        logger.info("Already long, holding")

                elif signal == 'sell':
                    if self.position == 'long':
                        logger.info("Reversing long → short")
                        self.close_position()
                        time.sleep(2)
                        self.open_short(price, atr)
                    elif self.position is None:
                        self.open_short(price, atr)
                    else:
                        logger.info("Already short, holding")

                else:
                    logger.info("No signal, holding current position")

            except KeyboardInterrupt:
                logger.info("Bot stopped by user")
                break
            except Exception as e:
                logger.error(f"Error in main loop: {e}", exc_info=True)

            time.sleep(LOOP_SLEEP)


if __name__ == '__main__':
    bot = Bot()
    bot.run()
