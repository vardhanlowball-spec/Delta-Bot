#!/data/data/com.termux/files/usr/bin/bash

pkg update -y && pkg install -y python git
pip install requests pandas

mkdir -p ~/delta_bot/strategies
cd ~/delta_bot

export DELTA_API_KEY="77UmGhdaRfqhSEweHmme91F9aUthrn"
export DELTA_API_SECRET=EmtQrwyT0MzEFMKRqUuumsUCwoKtFhuBtdX6kKcAw7Bb9QPubwEtF9k7UJgM"

cat > exchange.py << 'PYEOF'
import hashlib, hmac, json, time, os, requests

API_KEY    = os.getenv("DELTA_API_KEY",    "").strip()
API_SECRET = os.getenv("DELTA_API_SECRET", "").strip()
BASE_URL   = "https://api.india.delta.exchange"

def _sign(method, path, query_string="", body=""):
    timestamp = str(int(time.time()))
    message   = method + timestamp + path + query_string + body
    signature = hmac.new(API_SECRET.encode(), message.encode(), hashlib.sha256).hexdigest()
    return {"api-key": API_KEY, "timestamp": timestamp, "signature": signature,
            "Content-Type": "application/json", "User-Agent": "python-rest-client"}

def get(path, params=None):
    qs = ("?" + "&".join(f"{k}={v}" for k,v in params.items())) if params else ""
    r  = requests.get(BASE_URL + path, headers=_sign("GET", path, qs), params=params, timeout=10)
    r.raise_for_status(); return r.json()

def post(path, body):
    b = json.dumps(body, separators=(",",":"))
    r = requests.post(BASE_URL + path, headers=_sign("POST", path, "", b), data=b, timeout=10)
    r.raise_for_status(); return r.json()

def get_products():
    r = requests.get(BASE_URL+"/v2/products", headers={"User-Agent":"python-rest-client"}, timeout=10)
    r.raise_for_status()
    return [p for p in r.json().get("result",[]) if p.get("contract_type")=="perpetual_futures"]

def get_ticker(symbol):
    r = requests.get(BASE_URL+f"/v2/tickers/{symbol}", headers={"User-Agent":"python-rest-client"}, timeout=10)
    r.raise_for_status(); return r.json().get("result", {})

def get_candles(symbol, resolution="5", count=60):
    end=int(time.time()); start=end-int(resolution)*60*count
    r = requests.get(BASE_URL+"/v2/history/candles",
        headers={"User-Agent":"python-rest-client"},
        params={"resolution":resolution,"symbol":symbol,"start":start,"end":end}, timeout=10)
    r.raise_for_status(); return r.json().get("result",[])

def get_wallet_balance():
    for b in get("/v2/wallet/balances").get("result",[]):
        if b.get("asset_symbol")=="INR": return float(b.get("available_balance",0))
    return 0.0

def place_order(symbol, side, size, order_type="market_order", limit_price=None, reduce_only=False):
    body={"product_symbol":symbol,"size":size,"side":side,"order_type":order_type,"reduce_only":reduce_only}
    if limit_price: body["limit_price"]=str(limit_price)
    return post("/v2/orders", body)
PYEOF

touch strategies/__init__.py

cat > strategies/s01_ema_cross.py << 'PYEOF'
import pandas as pd
NAME = "EMA_CROSS"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<30: return None
    df=_df(candles)
    df["e5"]=df["close"].ewm(span=5,adjust=False).mean()
    df["e13"]=df["close"].ewm(span=13,adjust=False).mean()
    df["e21"]=df["close"].ewm(span=21,adjust=False).mean()
    d=df["close"].diff(); g=d.clip(lower=0).rolling(9).mean(); l=(-d.clip(upper=0)).rolling(9).mean()
    df["rsi"]=100-100/(1+g/l.replace(0,1e-9))
    df["va"]=df["volume"].rolling(20).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    vol=c["volume"]>c["va"]*1.1
    if p["e5"]<=p["e13"] and c["e5"]>c["e13"] and c["close"]>c["e21"] and c["rsi"]<60 and vol: return "buy"
    if p["e5"]>=p["e13"] and c["e5"]<c["e13"] and c["close"]<c["e21"] and c["rsi"]>40 and vol: return "sell"
    return None
PYEOF

cat > strategies/s02_bb_squeeze.py << 'PYEOF'
import pandas as pd
NAME = "BB_SQUEEZE"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<30: return None
    df=_df(candles)
    df["sma"]=df["close"].rolling(20).mean(); df["std"]=df["close"].rolling(20).std()
    df["bbu"]=df["sma"]+2*df["std"]; df["bbd"]=df["sma"]-2*df["std"]
    df["bbw"]=(df["bbu"]-df["bbd"])/df["sma"]
    df["va"]=df["volume"].rolling(20).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    squeeze_release=c["bbw"]>p["bbw"] and p["bbw"]<df["bbw"].rolling(20).mean().iloc[-1]
    if not squeeze_release: return None
    if c["volume"]<c["va"]*1.2: return None
    if c["close"]>c["bbu"]: return "buy"
    if c["close"]<c["bbd"]: return "sell"
    return None
PYEOF

cat > strategies/s03_stochrsi.py << 'PYEOF'
import pandas as pd
NAME = "STOCHRSI_MACD"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<50: return None
    df=_df(candles)
    d=df["close"].diff(); g=d.clip(lower=0).rolling(14).mean(); l=(-d.clip(upper=0)).rolling(14).mean()
    df["rsi"]=100-100/(1+g/l.replace(0,1e-9))
    mn=df["rsi"].rolling(14).min(); mx=df["rsi"].rolling(14).max()
    df["sk"]=((df["rsi"]-mn)/(mx-mn+1e-9)*100).rolling(3).mean()
    df["sd"]=df["sk"].rolling(3).mean()
    df["e12"]=df["close"].ewm(span=12,adjust=False).mean(); df["e26"]=df["close"].ewm(span=26,adjust=False).mean()
    df["hist"]=df["e12"]-df["e26"]-(df["e12"]-df["e26"]).ewm(span=9,adjust=False).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    if p["sk"]<=p["sd"] and c["sk"]>c["sd"] and c["sk"]<25 and c["hist"]>p["hist"]: return "buy"
    if p["sk"]>=p["sd"] and c["sk"]<c["sd"] and c["sk"]>75 and c["hist"]<p["hist"]: return "sell"
    return None
PYEOF

cat > strategies/s04_vwap_mom.py << 'PYEOF'
import pandas as pd
NAME = "VWAP_MOM"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<30: return None
    df=_df(candles)
    df["tp"]=(df["high"]+df["low"]+df["close"])/3
    df["vwap"]=(df["tp"]*df["volume"]).rolling(20).sum()/df["volume"].rolling(20).sum()
    df["e8"]=df["close"].ewm(span=8,adjust=False).mean()
    df["e21"]=df["close"].ewm(span=21,adjust=False).mean()
    d=df["close"].diff(); g=d.clip(lower=0).rolling(9).mean(); l=(-d.clip(upper=0)).rolling(9).mean()
    df["rsi"]=100-100/(1+g/l.replace(0,1e-9))
    df["va"]=df["volume"].rolling(20).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    vol=c["volume"]>c["va"]*1.15
    if p["close"]<=p["vwap"] and c["close"]>c["vwap"] and c["e8"]>c["e21"] and c["rsi"]<65 and vol: return "buy"
    if p["close"]>=p["vwap"] and c["close"]<c["vwap"] and c["e8"]<c["e21"] and c["rsi"]>35 and vol: return "sell"
    return None
PYEOF

cat > strategies/s05_rsi_reversal.py << 'PYEOF'
import pandas as pd
NAME = "RSI_REVERSAL"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<20: return None
    df=_df(candles)
    d=df["close"].diff(); g=d.clip(lower=0).rolling(14).mean(); l=(-d.clip(upper=0)).rolling(14).mean()
    df["rsi"]=100-100/(1+g/l.replace(0,1e-9))
    df["e20"]=df["close"].ewm(span=20,adjust=False).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    if p["rsi"]<28 and c["rsi"]>28 and c["close"]>c["e20"]: return "buy"
    if p["rsi"]>72 and c["rsi"]<72 and c["close"]<c["e20"]: return "sell"
    return None
PYEOF

cat > strategies/s06_supertrend.py << 'PYEOF'
import pandas as pd
NAME = "SUPERTREND"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<20: return None
    df=_df(candles)
    atr_period=10; mult=3.0
    df["hl"]=df["high"]-df["low"]
    df["hc"]=(df["high"]-df["close"].shift()).abs()
    df["lc"]=(df["low"]-df["close"].shift()).abs()
    df["tr"]=df[["hl","hc","lc"]].max(axis=1)
    df["atr"]=df["tr"].rolling(atr_period).mean()
    df["ub"]=(df["high"]+df["low"])/2+mult*df["atr"]
    df["lb"]=(df["high"]+df["low"])/2-mult*df["atr"]
    trend=[1]*len(df)
    for i in range(1,len(df)):
        if df["close"].iloc[i]>df["ub"].iloc[i-1]: trend[i]=1
        elif df["close"].iloc[i]<df["lb"].iloc[i-1]: trend[i]=-1
        else: trend[i]=trend[i-1]
    df["trend"]=trend
    c,p=df.iloc[-1],df.iloc[-2]
    if p["trend"]==-1 and c["trend"]==1: return "buy"
    if p["trend"]==1 and c["trend"]==-1: return "sell"
    return None
PYEOF

cat > strategies/s07_macd_hist.py << 'PYEOF'
import pandas as pd
NAME = "MACD_HIST"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<35: return None
    df=_df(candles)
    df["e12"]=df["close"].ewm(span=12,adjust=False).mean()
    df["e26"]=df["close"].ewm(span=26,adjust=False).mean()
    df["macd"]=df["e12"]-df["e26"]
    df["sig"]=df["macd"].ewm(span=9,adjust=False).mean()
    df["hist"]=df["macd"]-df["sig"]
    df["va"]=df["volume"].rolling(20).mean()
    c,p,pp=df.iloc[-1],df.iloc[-2],df.iloc[-3]
    if pp["hist"]<p["hist"]<0 and c["hist"]>p["hist"] and c["volume"]>c["va"]: return "buy"
    if pp["hist"]>p["hist"]>0 and c["hist"]<p["hist"] and c["volume"]>c["va"]: return "sell"
    return None
PYEOF

cat > strategies/s08_ichimoku.py << 'PYEOF'
import pandas as pd
NAME = "ICHIMOKU"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<52: return None
    df=_df(candles)
    df["tenkan"]=(df["high"].rolling(9).max()+df["low"].rolling(9).min())/2
    df["kijun"]=(df["high"].rolling(26).max()+df["low"].rolling(26).min())/2
    df["ssa"]=((df["tenkan"]+df["kijun"])/2).shift(26)
    df["ssb"]=((df["high"].rolling(52).max()+df["low"].rolling(52).min())/2).shift(26)
    c,p=df.iloc[-1],df.iloc[-2]
    above_cloud=c["close"]>max(c["ssa"],c["ssb"]) if not pd.isna(c["ssa"]) else False
    below_cloud=c["close"]<min(c["ssa"],c["ssb"]) if not pd.isna(c["ssa"]) else False
    if p["tenkan"]<=p["kijun"] and c["tenkan"]>c["kijun"] and above_cloud: return "buy"
    if p["tenkan"]>=p["kijun"] and c["tenkan"]<c["kijun"] and below_cloud: return "sell"
    return None
PYEOF

cat > strategies/s09_donchian.py << 'PYEOF'
import pandas as pd
NAME = "DONCHIAN"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<22: return None
    df=_df(candles)
    df["dc_hi"]=df["high"].rolling(20).max().shift(1)
    df["dc_lo"]=df["low"].rolling(20).min().shift(1)
    df["va"]=df["volume"].rolling(20).mean()
    c=df.iloc[-1]
    if c["close"]>c["dc_hi"] and c["volume"]>c["va"]*1.2: return "buy"
    if c["close"]<c["dc_lo"] and c["volume"]>c["va"]*1.2: return "sell"
    return None
PYEOF

cat > strategies/s10_cci.py << 'PYEOF'
import pandas as pd
NAME = "CCI_MOM"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<22: return None
    df=_df(candles)
    df["tp"]=(df["high"]+df["low"]+df["close"])/3
    df["sma"]=df["tp"].rolling(20).mean()
    df["mad"]=df["tp"].rolling(20).apply(lambda x:(x-x.mean()).abs().mean())
    df["cci"]=(df["tp"]-df["sma"])/(0.015*df["mad"].replace(0,1e-9))
    c,p=df.iloc[-1],df.iloc[-2]
    if p["cci"]<-100 and c["cci"]>-100: return "buy"
    if p["cci"]>100 and c["cci"]<100: return "sell"
    return None
PYEOF

cat > strategies/s11_williamsr.py << 'PYEOF'
import pandas as pd
NAME = "WILLIAMS_R"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<20: return None
    df=_df(candles)
    n=14
    df["hh"]=df["high"].rolling(n).max()
    df["ll"]=df["low"].rolling(n).min()
    df["wr"]=-100*(df["hh"]-df["close"])/(df["hh"]-df["ll"]+1e-9)
    df["e10"]=df["close"].ewm(span=10,adjust=False).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    if p["wr"]<-80 and c["wr"]>-80 and c["close"]>c["e10"]: return "buy"
    if p["wr"]>-20 and c["wr"]<-20 and c["close"]<c["e10"]: return "sell"
    return None
PYEOF

cat > strategies/s12_psar.py << 'PYEOF'
import pandas as pd
NAME = "PSAR"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<10: return None
    df=_df(candles)
    af=0.02; max_af=0.2; step=0.02
    bull=True; sar=df["low"].iloc[0]; ep=df["high"].iloc[0]; cur_af=af
    sars=[]
    for i in range(len(df)):
        sars.append(sar)
        if bull:
            sar=min(sar,df["low"].iloc[max(0,i-1)],df["low"].iloc[max(0,i-2)])
            if df["close"].iloc[i]>ep: ep=df["close"].iloc[i]; cur_af=min(cur_af+step,max_af)
            if df["low"].iloc[i]<sar: bull=False; sar=ep; ep=df["low"].iloc[i]; cur_af=af
            else: sar=sar+cur_af*(ep-sar)
        else:
            sar=max(sar,df["high"].iloc[max(0,i-1)],df["high"].iloc[max(0,i-2)])
            if df["close"].iloc[i]<ep: ep=df["close"].iloc[i]; cur_af=min(cur_af+step,max_af)
            if df["high"].iloc[i]>sar: bull=True; sar=ep; ep=df["high"].iloc[i]; cur_af=af
            else: sar=sar+cur_af*(ep-sar)
    df["sar"]=sars
    c,p=df.iloc[-1],df.iloc[-2]
    if p["close"]<p["sar"] and c["close"]>c["sar"]: return "buy"
    if p["close"]>p["sar"] and c["close"]<c["sar"]: return "sell"
    return None
PYEOF

cat > strategies/s13_vol_spike.py << 'PYEOF'
import pandas as pd
NAME = "VOL_SPIKE"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<25: return None
    df=_df(candles)
    df["va"]=df["volume"].rolling(20).mean()
    df["vs"]=df["volume"]/df["va"]
    df["body"]=(df["close"]-df["open"]).abs()
    df["avg_body"]=df["body"].rolling(20).mean()
    c=df.iloc[-1]
    if c["vs"]>2.5 and c["body"]>c["avg_body"]*1.5:
        if c["close"]>c["open"]: return "buy"
        if c["close"]<c["open"]: return "sell"
    return None
PYEOF

cat > strategies/s14_tema.py << 'PYEOF'
import pandas as pd
NAME = "TEMA"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<40: return None
    df=_df(candles)
    n=14
    e1=df["close"].ewm(span=n,adjust=False).mean()
    e2=e1.ewm(span=n,adjust=False).mean()
    e3=e2.ewm(span=n,adjust=False).mean()
    df["tema"]=3*e1-3*e2+e3
    df["e50"]=df["close"].ewm(span=50,adjust=False).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    if p["tema"]<=p["e50"] and c["tema"]>c["e50"]: return "buy"
    if p["tema"]>=p["e50"] and c["tema"]<c["e50"]: return "sell"
    return None
PYEOF

cat > strategies/s15_keltner.py << 'PYEOF'
import pandas as pd
NAME = "KELTNER"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<25: return None
    df=_df(candles)
    df["ema20"]=df["close"].ewm(span=20,adjust=False).mean()
    df["hl"]=df["high"]-df["low"]
    df["hc"]=(df["high"]-df["close"].shift()).abs()
    df["lc"]=(df["low"]-df["close"].shift()).abs()
    df["atr"]=df[["hl","hc","lc"]].max(axis=1).rolling(10).mean()
    df["ku"]=df["ema20"]+2*df["atr"]; df["kl"]=df["ema20"]-2*df["atr"]
    df["va"]=df["volume"].rolling(20).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    if p["close"]<=p["ku"] and c["close"]>c["ku"] and c["volume"]>c["va"]*1.1: return "buy"
    if p["close"]>=p["kl"] and c["close"]<c["kl"] and c["volume"]>c["va"]*1.1: return "sell"
    return None
PYEOF

cat > strategies/s16_heikin.py << 'PYEOF'
import pandas as pd
NAME = "HEIKIN_ASHI"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<10: return None
    df=_df(candles)
    df["ha_c"]=(df["open"]+df["high"]+df["low"]+df["close"])/4
    ha_o=[( df["open"].iloc[0]+df["close"].iloc[0])/2]
    for i in range(1,len(df)): ha_o.append((ha_o[-1]+df["close"].iloc[i-1])/2)
    df["ha_o"]=ha_o
    df["e10"]=df["close"].ewm(span=10,adjust=False).mean()
    c,p,pp=df.iloc[-1],df.iloc[-2],df.iloc[-3]
    green=lambda r: r["ha_c"]>r["ha_o"]
    if not green(pp) and not green(p) and green(c) and c["close"]>c["e10"]: return "buy"
    if green(pp) and green(p) and not green(c) and c["close"]<c["e10"]: return "sell"
    return None
PYEOF

cat > strategies/s17_adx.py << 'PYEOF'
import pandas as pd
NAME = "ADX_TREND"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<30: return None
    df=_df(candles)
    n=14
    df["c1"]=df["close"].shift(1); df["h1"]=df["high"].shift(1); df["l1"]=df["low"].shift(1)
    df["tr"]=df.apply(lambda r:max(r["high"]-r["low"],abs(r["high"]-r["c1"]) if not pd.isna(r["c1"]) else 0,abs(r["low"]-r["c1"]) if not pd.isna(r["c1"]) else 0),axis=1)
    df["pdm"]=df.apply(lambda r:(r["high"]-r["h1"]) if not pd.isna(r["h1"]) and (r["high"]-r["h1"])>(r["l1"]-r["low"]) and (r["high"]-r["h1"])>0 else 0,axis=1)
    df["ndm"]=df.apply(lambda r:(r["l1"]-r["low"]) if not pd.isna(r["l1"]) and (r["l1"]-r["low"])>(r["high"]-r["h1"]) and (r["l1"]-r["low"])>0 else 0,axis=1)
    atr=df["tr"].rolling(n).mean()
    pdi=100*df["pdm"].rolling(n).mean()/atr.replace(0,1e-9)
    ndi=100*df["ndm"].rolling(n).mean()/atr.replace(0,1e-9)
    dx=100*(pdi-ndi).abs()/(pdi+ndi+1e-9)
    df["adx"]=dx.rolling(n).mean(); df["pdi"]=pdi; df["ndi"]=ndi
    c,p=df.iloc[-1],df.iloc[-2]
    if c["adx"]>25 and p["pdi"]<=p["ndi"] and c["pdi"]>c["ndi"]: return "buy"
    if c["adx"]>25 and p["pdi"]>=p["ndi"] and c["pdi"]<c["ndi"]: return "sell"
    return None
PYEOF

cat > strategies/s18_inside_bar.py << 'PYEOF'
import pandas as pd
NAME = "INSIDE_BAR"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<10: return None
    df=_df(candles)
    df["e20"]=df["close"].ewm(span=20,adjust=False).mean()
    c,p,pp=df.iloc[-1],df.iloc[-2],df.iloc[-3]
    inside=p["high"]<pp["high"] and p["low"]>pp["low"]
    if not inside: return None
    if c["close"]>pp["high"] and c["close"]>c["e20"]: return "buy"
    if c["close"]<pp["low"] and c["close"]<c["e20"]: return "sell"
    return None
PYEOF

cat > strategies/s19_obv.py << 'PYEOF'
import pandas as pd
NAME = "OBV_TREND"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<25: return None
    df=_df(candles)
    obv=[0]
    for i in range(1,len(df)):
        if df["close"].iloc[i]>df["close"].iloc[i-1]: obv.append(obv[-1]+df["volume"].iloc[i])
        elif df["close"].iloc[i]<df["close"].iloc[i-1]: obv.append(obv[-1]-df["volume"].iloc[i])
        else: obv.append(obv[-1])
    df["obv"]=obv
    df["obv_ema"]=df["obv"].ewm(span=10,adjust=False).mean()
    df["price_ema"]=df["close"].ewm(span=10,adjust=False).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    if p["obv"]<=p["obv_ema"] and c["obv"]>c["obv_ema"] and c["close"]>c["price_ema"]: return "buy"
    if p["obv"]>=p["obv_ema"] and c["obv"]<c["obv_ema"] and c["close"]<c["price_ema"]: return "sell"
    return None
PYEOF

cat > strategies/s20_engulfing.py << 'PYEOF'
import pandas as pd
NAME = "ENGULFING"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<10: return None
    df=_df(candles)
    df["e20"]=df["close"].ewm(span=20,adjust=False).mean()
    df["va"]=df["volume"].rolling(10).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    bull=p["close"]<p["open"] and c["close"]>c["open"] and c["open"]<p["close"] and c["close"]>p["open"]
    bear=p["close"]>p["open"] and c["close"]<c["open"] and c["open"]>p["close"] and c["close"]<p["open"]
    vol=c["volume"]>c["va"]*1.1
    if bull and vol and c["close"]>c["e20"]: return "buy"
    if bear and vol and c["close"]<c["e20"]: return "sell"
    return None
PYEOF

cat > strategies/s21_bb_revert.py << 'PYEOF'
import pandas as pd
NAME = "BB_REVERT"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<25: return None
    df=_df(candles)
    df["sma"]=df["close"].rolling(20).mean(); df["std"]=df["close"].rolling(20).std()
    df["bbu"]=df["sma"]+2.5*df["std"]; df["bbd"]=df["sma"]-2.5*df["std"]
    d=df["close"].diff(); g=d.clip(lower=0).rolling(9).mean(); l=(-d.clip(upper=0)).rolling(9).mean()
    df["rsi"]=100-100/(1+g/l.replace(0,1e-9))
    c,p=df.iloc[-1],df.iloc[-2]
    if p["close"]<p["bbd"] and c["close"]>c["bbd"] and c["rsi"]<40: return "buy"
    if p["close"]>p["bbu"] and c["close"]<c["bbu"] and c["rsi"]>60: return "sell"
    return None
PYEOF

cat > strategies/s22_pivot.py << 'PYEOF'
import pandas as pd
NAME = "PIVOT"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<10: return None
    df=_df(candles)
    prev=df.iloc[-2]
    pp=(prev["high"]+prev["low"]+prev["close"])/3
    s1=2*pp-prev["high"]; r1=2*pp-prev["low"]
    s2=pp-(prev["high"]-prev["low"]); r2=pp+(prev["high"]-prev["low"])
    c=df.iloc[-1]; tol=0.002
    if abs(c["close"]-s1)/(s1+1e-9)<tol and c["close"]>c["open"]: return "buy"
    if abs(c["close"]-s2)/(s2+1e-9)<tol and c["close"]>c["open"]: return "buy"
    if abs(c["close"]-r1)/(r1+1e-9)<tol and c["close"]<c["open"]: return "sell"
    if abs(c["close"]-r2)/(r2+1e-9)<tol and c["close"]<c["open"]: return "sell"
    return None
PYEOF

cat > strategies/s23_3candles.py << 'PYEOF'
import pandas as pd
NAME = "THREE_CANDLES"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<10: return None
    df=_df(candles)
    df["avg_body"]=((df["close"]-df["open"]).abs()).rolling(10).mean()
    c,p,pp=df.iloc[-1],df.iloc[-2],df.iloc[-3]
    mb=c["avg_body"]*0.8
    soldiers=(pp["close"]>pp["open"] and p["close"]>p["open"] and c["close"]>c["open"] and
              p["open"]>pp["open"] and c["open"]>p["open"] and
              (pp["close"]-pp["open"])>mb and (p["close"]-p["open"])>mb and (c["close"]-c["open"])>mb)
    crows=(pp["close"]<pp["open"] and p["close"]<p["open"] and c["close"]<c["open"] and
           p["open"]<pp["open"] and c["open"]<p["open"] and
           (pp["open"]-pp["close"])>mb and (p["open"]-p["close"])>mb and (c["open"]-c["close"])>mb)
    if soldiers: return "buy"
    if crows: return "sell"
    return None
PYEOF

cat > strategies/s24_cmf.py << 'PYEOF'
import pandas as pd
NAME = "CMF"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<25: return None
    df=_df(candles)
    df["mfm"]=((df["close"]-df["low"])-(df["high"]-df["close"]))/(df["high"]-df["low"]+1e-9)
    df["mfv"]=df["mfm"]*df["volume"]
    df["cmf"]=df["mfv"].rolling(20).sum()/df["volume"].rolling(20).sum()
    df["e15"]=df["close"].ewm(span=15,adjust=False).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    if p["cmf"]<=0 and c["cmf"]>0 and c["close"]>c["e15"]: return "buy"
    if p["cmf"]>=0 and c["cmf"]<0 and c["close"]<c["e15"]: return "sell"
    return None
PYEOF

cat > strategies/s25_doji.py << 'PYEOF'
import pandas as pd
NAME = "DOJI"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<15: return None
    df=_df(candles)
    df["avg_body"]=((df["close"]-df["open"]).abs()).rolling(10).mean()
    df["e20"]=df["close"].ewm(span=20,adjust=False).mean()
    p,c=df.iloc[-2],df.iloc[-1]
    doji=abs(p["close"]-p["open"])<p["avg_body"]*0.1
    if not doji: return None
    if c["close"]>c["open"] and c["close"]>c["e20"]: return "buy"
    if c["close"]<c["open"] and c["close"]<c["e20"]: return "sell"
    return None
PYEOF

cat > strategies/s26_hammer.py << 'PYEOF'
import pandas as pd
NAME = "HAMMER"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<15: return None
    df=_df(candles)
    df["e20"]=df["close"].ewm(span=20,adjust=False).mean()
    c=df.iloc[-1]
    body=abs(c["close"]-c["open"])
    if body==0: return None
    upper=c["high"]-max(c["close"],c["open"])
    lower=min(c["close"],c["open"])-c["low"]
    hammer=lower>2*body and upper<body*0.5
    star=upper>2*body and lower<body*0.5
    if hammer and c["close"]<c["e20"]: return "buy"
    if star and c["close"]>c["e20"]: return "sell"
    return None
PYEOF

cat > strategies/s27_ema_ribbon.py << 'PYEOF'
import pandas as pd
NAME = "EMA_RIBBON"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<50: return None
    df=_df(candles)
    spans=[5,8,13,21,34]
    for s in spans: df[f"e{s}"]=df["close"].ewm(span=s,adjust=False).mean()
    c=df.iloc[-1]; p=df.iloc[-2]
    bull=all(c[f"e{spans[i]}"]>c[f"e{spans[i+1]}"] for i in range(len(spans)-1))
    bear=all(c[f"e{spans[i]}"]<c[f"e{spans[i+1]}"] for i in range(len(spans)-1))
    was_bull=all(p[f"e{spans[i]}"]>p[f"e{spans[i+1]}"] for i in range(len(spans)-1))
    was_bear=all(p[f"e{spans[i]}"]<p[f"e{spans[i+1]}"] for i in range(len(spans)-1))
    if not was_bull and bull: return "buy"
    if not was_bear and bear: return "sell"
    return None
PYEOF

cat > strategies/s28_price_channel.py << 'PYEOF'
import pandas as pd
NAME = "PRICE_CHANNEL"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<15: return None
    df=_df(candles)
    df["ch_hi"]=df["high"].rolling(10).max().shift(1)
    df["ch_lo"]=df["low"].rolling(10).min().shift(1)
    df["va"]=df["volume"].rolling(10).mean()
    c=df.iloc[-1]
    if c["close"]>c["ch_hi"] and c["volume"]>c["va"]*1.25: return "buy"
    if c["close"]<c["ch_lo"] and c["volume"]>c["va"]*1.25: return "sell"
    return None
PYEOF

cat > strategies/s29_rsi_ema.py << 'PYEOF'
import pandas as pd
NAME = "RSI_EMA_CONF"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<30: return None
    df=_df(candles)
    d=df["close"].diff(); g=d.clip(lower=0).rolling(14).mean(); l=(-d.clip(upper=0)).rolling(14).mean()
    df["rsi"]=100-100/(1+g/l.replace(0,1e-9))
    df["e9"]=df["close"].ewm(span=9,adjust=False).mean()
    df["e21"]=df["close"].ewm(span=21,adjust=False).mean()
    df["e50"]=df["close"].ewm(span=50,adjust=False).mean()
    c=df.iloc[-1]
    if c["e9"]>c["e21"]>c["e50"] and 50<c["rsi"]<70: return "buy"
    if c["e9"]<c["e21"]<c["e50"] and 30<c["rsi"]<50: return "sell"
    return None
PYEOF

cat > strategies/s30_atr_break.py << 'PYEOF'
import pandas as pd
NAME = "ATR_BREAK"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<20: return None
    df=_df(candles)
    df["hl"]=df["high"]-df["low"]
    df["hc"]=(df["high"]-df["close"].shift()).abs()
    df["lc"]=(df["low"]-df["close"].shift()).abs()
    df["atr"]=df[["hl","hc","lc"]].max(axis=1).rolling(14).mean()
    df["e20"]=df["close"].ewm(span=20,adjust=False).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    move=abs(c["close"]-p["close"])
    if move>c["atr"]*1.5:
        if c["close"]>p["close"] and c["close"]>c["e20"]: return "buy"
        if c["close"]<p["close"] and c["close"]<c["e20"]: return "sell"
    return None
PYEOF

cat > strategies/s31_orb.py << 'PYEOF'
import pandas as pd
NAME = "ORB"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<10: return None
    df=_df(candles)
    orb_hi=df.head(5)["high"].max(); orb_lo=df.head(5)["low"].min()
    df["va"]=df["volume"].rolling(10).mean()
    c=df.iloc[-1]
    if c["close"]>orb_hi and c["volume"]>c["va"]*1.3: return "buy"
    if c["close"]<orb_lo and c["volume"]>c["va"]*1.3: return "sell"
    return None
PYEOF

cat > strategies/s32_donchian_mid.py << 'PYEOF'
import pandas as pd
NAME = "DONCHIAN_MID"
def _df(c):
    df=pd.DataFrame(c,columns=["time","open","high","low","close","volume"])
    for x in["open","high","low","close","volume"]: df[x]=pd.to_numeric(df[x],errors="coerce")
    return df.dropna().reset_index(drop=True)
def signal(candles):
    if len(candles)<22: return None
    df=_df(candles)
    df["dc_hi"]=df["high"].rolling(20).max()
    df["dc_lo"]=df["low"].rolling(20).min()
    df["dc_mid"]=(df["dc_hi"]+df["dc_lo"])/2
    df["va"]=df["volume"].rolling(20).mean()
    c,p=df.iloc[-1],df.iloc[-2]
    if p["close"]<=p["dc_mid"] and c["close"]>c["dc_mid"] and c["volume"]>c["va"]: return "buy"
    if p["close"]>=p["dc_mid"] and c["close"]<c["dc_mid"] and c["volume"]>c["va"]: return "sell"
    return None
PYEOF

# ── bot.py ────────────────────────────────────────────────────────────────────
cat > bot.py << 'PYEOF'
import os, sys, time, importlib, logging
from pathlib import Path
import exchange

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("DeltaBot")

TOTAL_CAPITAL  = float(os.getenv("TOTAL_CAPITAL",  "300").strip())
MAX_SLOTS      = int(os.getenv("MAX_SLOTS",         "4").strip())
MAX_SL_INR     = float(os.getenv("MAX_SL_INR",      "15").strip())
RR_RATIO       = float(os.getenv("RR_RATIO",        "2.0").strip())
SCAN_INTERVAL  = int(os.getenv("SCAN_INTERVAL",     "10").strip())   # every 10 seconds
FORCE_INTERVAL = int(os.getenv("FORCE_INTERVAL",    "600").strip())  # force trade every 10 mins
TEST_SYMBOL    = os.getenv("TEST_SYMBOL",            "XRPUSD").strip()
SLOT_CAPITAL   = TOTAL_CAPITAL * 0.25

STRATEGY_DIR   = Path(__file__).parent / "strategies"

def load_strategies():
    strats=[]
    for f in sorted(STRATEGY_DIR.glob("s[0-9]*.py")):
        mod=importlib.import_module(f"strategies.{f.stem}")
        strats.append(mod)
        log.info(f"✓ {mod.NAME}")
    log.info(f"Total: {len(strats)} strategies loaded")
    return strats

open_trades = {}
last_force_time = time.time()

def calc_trade(symbol, side, price):
    size    = max(1, int(SLOT_CAPITAL / price))
    sl_dist = MAX_SL_INR / size
    tp_dist = sl_dist * RR_RATIO
    sl = round(price - sl_dist if side=="buy" else price + sl_dist, 4)
    tp = round(price + tp_dist if side=="buy" else price - tp_dist, 4)
    return size, sl, tp

def open_trade(symbol, side, price, strat):
    size, sl, tp = calc_trade(symbol, side, price)
    log.info(f"OPEN {side.upper()} {symbol} size={size} entry={price:.4f} SL={sl:.4f} TP={tp:.4f} [{strat}]")
    try:
        resp = exchange.place_order(symbol, side, size)
        open_trades[symbol] = {"side":side,"entry":price,"size":size,"sl":sl,"tp":tp,"strategy":strat,"t":time.time()}
        log.info(f"✓ Order placed ID={resp.get('result',{}).get('id')}")
    except Exception as e:
        log.error(f"✗ Order failed {symbol}: {e}")

def close_trade(symbol, reason):
    t = open_trades.get(symbol)
    if not t: return
    try:
        exchange.place_order(symbol, "sell" if t["side"]=="buy" else "buy", t["size"], reduce_only=True)
        log.info(f"CLOSE {symbol} [{reason}]")
        del open_trades[symbol]
    except Exception as e:
        log.error(f"✗ Close failed {symbol}: {e}")

def monitor():
    for sym, t in list(open_trades.items()):
        try:
            price = float(exchange.get_ticker(sym).get("close", 0))
            if price <= 0: continue
            if t["side"]=="buy":
                if price<=t["sl"]: close_trade(sym, f"SL@{price}")
                elif price>=t["tp"]: close_trade(sym, f"TP@{price}")
            else:
                if price>=t["sl"]: close_trade(sym, f"SL@{price}")
                elif price<=t["tp"]: close_trade(sym, f"TP@{price}")
        except Exception as e:
            log.warning(f"Monitor error {sym}: {e}")

def test_trade():
    log.info(f"── TEST TRADE on {TEST_SYMBOL} ──")
    try:
        price = float(exchange.get_ticker(TEST_SYMBOL).get("close", 1))
        resp  = exchange.place_order(TEST_SYMBOL, "buy", 1)
        log.info(f"✓ Test buy OK (ID={resp.get('result',{}).get('id')}). Closing...")
        time.sleep(2)
        exchange.place_order(TEST_SYMBOL, "sell", 1, reduce_only=True)
        log.info("✓ Test trade closed. Auth working!\n")
    except Exception as e:
        log.error(f"✗ TEST FAILED: {e}"); sys.exit(1)

def scan(strategies, force=False):
    global last_force_time
    if len(open_trades) >= MAX_SLOTS: return
    log.info(f"Scanning... ({MAX_SLOTS-len(open_trades)} slots free){' [FORCE]' if force else ''}")
    try: products = exchange.get_products()
    except Exception as e: log.error(f"Products fetch failed: {e}"); return

    symbols = [p["symbol"] for p in products if "USD" in p.get("symbol","") and p["symbol"] not in open_trades][:80]
    force_candidate = None

    for sym in symbols:
        if len(open_trades) >= MAX_SLOTS: return
        if sym in open_trades: continue
        log.info(f"  scanning {sym}")  # log every coin scanned

        try:
            candles_1m = exchange.get_candles(sym, "1", 60)
            candles_5m = exchange.get_candles(sym, "5", 60)
        except: continue

        traded = False
        for strat in strategies:
            if traded: break
            sig = None
            # try 1m first, then 5m — either timeframe triggers trade
            try: sig = strat.signal(candles_1m)
            except: pass
            if not sig:
                try: sig = strat.signal(candles_5m)
                except: pass

            if sig:
                try:
                    price = float(exchange.get_ticker(sym).get("close", 0))
                    if price > 0:
                        if force_candidate is None:
                            force_candidate = (sym, sig, price, strat.NAME)
                        open_trade(sym, sig, price, strat.NAME)
                        time.sleep(0.5)
                        traded = True
                        last_force_time = time.time()
                except: pass

    # if 10 mins passed with no trade, force the best available signal
    if force and len(open_trades) == 0 and force_candidate:
        sym, sig, price, sname = force_candidate
        log.info(f"[FORCE TRADE] No trade in {FORCE_INTERVAL//60}min → forcing {sym} {sig} [{sname}]")
        open_trade(sym, sig, price, sname)
        last_force_time = time.time()

def main():
    global last_force_time
    log.info(f"Delta Scalp Bot | capital=₹{TOTAL_CAPITAL} | slots={MAX_SLOTS} | SL≤₹{MAX_SL_INR} | scan={SCAN_INTERVAL}s | force={FORCE_INTERVAL//60}min")
    strategies = load_strategies()
    test_trade()
    last_force_time = time.time()

    while True:
        log.info(f"── Cycle | Open trades: {len(open_trades)}/{MAX_SLOTS} ──")
        monitor()
        force = (time.time() - last_force_time) >= FORCE_INTERVAL
        scan(strategies, force=force)
        time.sleep(SCAN_INTERVAL)

if __name__=="__main__": main()
PYEOF

echo ""
echo "✓ Done! 32 unique strategies created."
echo "✓ Any 1 strategy signal triggers a trade."
echo "✓ Both 1m and 5m candles checked per coin."
echo "✓ Scans every 10 seconds."
echo "✓ Forces a trade every 10 minutes if no trade."
echo "✓ Logs every coin scanned."
echo ""
echo "Run: cd ~/delta_bot && python bot.py"
