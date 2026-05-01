import hashlib
import hmac
import time
import requests
import logging

logger = logging.getLogger(__name__)

BASE_URL = "https://api.india.delta.exchange"

class DeltaClient:
    def __init__(self, api_key: str, api_secret: str):
        self.api_key = api_key
        self.api_secret = api_secret
        self.session = requests.Session()
        self.session.headers.update({
            'Content-Type': 'application/json',
            'User-Agent': 'kyle-ribbon-bot/1.0'
        })

    def _sign(self, method: str, path: str, query: str = '', payload: str = '') -> dict:
        timestamp = str(int(time.time()))
        message = method + timestamp + path + query + payload
        signature = hmac.new(
            self.api_secret.encode(),
            message.encode(),
            hashlib.sha256
        ).hexdigest()
        return {
            'api-key': self.api_key,
            'timestamp': timestamp,
            'signature': signature
        }

    def _get(self, path: str, params: dict = None, auth: bool = False) -> dict:
        query = ''
        if params:
            query = '?' + '&'.join(f"{k}={v}" for k, v in params.items())
        headers = self._sign('GET', path, query) if auth else {}
        url = BASE_URL + path + query
        resp = self.session.get(url, headers=headers, timeout=10)
        resp.raise_for_status()
        return resp.json()

    def _post(self, path: str, body: dict) -> dict:
        import json
        payload = json.dumps(body)
        headers = self._sign('POST', path, '', payload)
        url = BASE_URL + path
        resp = self.session.post(url, headers=headers, data=payload, timeout=10)
        resp.raise_for_status()
        return resp.json()

    def _delete(self, path: str, body: dict) -> dict:
        import json
        payload = json.dumps(body)
        headers = self._sign('DELETE', path, '', payload)
        url = BASE_URL + path
        resp = self.session.delete(url, headers=headers, data=payload, timeout=10)
        resp.raise_for_status()
        return resp.json()

    # ── Market Data ──────────────────────────────────────────────
    def get_candles(self, symbol: str, resolution: str = '5', limit: int = 100):
        """Fetch OHLCV candles. resolution in minutes: 1,5,15,60,D"""
        end = int(time.time())
        start = end - (limit * int(resolution) * 60)
        data = self._get('/v2/history/candles', {
            'symbol': symbol,
            'resolution': resolution,
            'start': start,
            'end': end
        })
        if data.get('success'):
            return data['result']
        return []

    def get_ticker(self, symbol: str) -> dict:
        data = self._get(f'/v2/tickers/{symbol}')
        if data.get('success'):
            return data['result']
        return {}

    def get_product(self, symbol: str) -> dict:
        data = self._get('/v2/products', {'contract_types': 'perpetual_futures'})
        if data.get('success'):
            for p in data['result']:
                if p['symbol'] == symbol:
                    return p
        return {}

    # ── Account ──────────────────────────────────────────────────
    def get_balance(self) -> dict:
        data = self._get('/v2/wallet/balances', auth=True)
        if data.get('success'):
            return {b['asset_symbol']: float(b['available_balance'])
                    for b in data['result']}
        return {}

    def get_positions(self) -> list:
        data = self._get('/v2/positions/margined', auth=True)
        if data.get('success'):
            return data['result']
        return []

    def get_open_orders(self, product_id: int) -> list:
        data = self._get('/v2/orders', {'product_id': product_id, 'state': 'open'}, auth=True)
        if data.get('success'):
            return data['result']
        return []

    # ── Trading ──────────────────────────────────────────────────
    def place_market_order(self, product_id: int, side: str, size: int) -> dict:
        """side: 'buy' or 'sell', size: number of contracts"""
        body = {
            'product_id': product_id,
            'side': side,
            'order_type': 'market_order',
            'size': size
        }
        data = self._post('/v2/orders', body)
        return data

    def place_limit_order(self, product_id: int, side: str, size: int, price: float) -> dict:
        body = {
            'product_id': product_id,
            'side': side,
            'order_type': 'limit_order',
            'size': size,
            'limit_price': str(price)
        }
        data = self._post('/v2/orders', body)
        return data

    def cancel_all_orders(self, product_id: int) -> dict:
        body = {'product_id': product_id, 'cancel_limit_orders': True}
        return self._delete('/v2/orders/all', body)

    def close_position(self, product_id: int, current_size: int, current_side: str) -> dict:
        """Close an open position with a market order in opposite direction"""
        close_side = 'sell' if current_side == 'buy' else 'buy'
        return self.place_market_order(product_id, close_side, abs(current_size))

