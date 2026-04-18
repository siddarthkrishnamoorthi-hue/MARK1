Analysis:
Longs: 17 taken, 1 win (5.88%) — essentially all losing. The bullish FVG logic or entry conditions are fundamentally broken without the H4 filter gatekeeping.
Shorts: 17 taken, 5 wins (29.41%) — better but still losing.
Root cause: Removing H4 filter opened the floodgates to counter-trend entries. The EA is now selling into uptrends and buying into downtrends blindly.
The expanded FVG loop (1–15 bars) is finding stale FVGs that price has already partially filled, creating bad entry levels.
No FVG validity check — the code doesn't verify the gap is still open before placing the limit.

In ICT_LondonSweep_FVG.mq5, apply these targeted fixes:

---

FIX 1 — Re-enable H4 filter with EMA bias (replace swing BOS logic)

In IsH4BullishBOS(), replace the entire swing-scanning loop with:
  double ema50 = iMA(Symbol(), PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);
  double h4close = iClose(Symbol(), PERIOD_H4, 1);
  return (h4close > ema50);

In IsH4BearishBOS(), replace with:
  double ema50 = iMA(Symbol(), PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);
  double h4close = iClose(Symbol(), PERIOD_H4, 1);
  return (h4close < ema50);

Set InpEnableH4Filter default to true.

---

FIX 2 — Add FVG validity check in the scan loop

In ScanForFVGAndEnter(), after the FVG loop finds a gap and sets g_fvgHigh/g_fvgLow/g_fvgMid, add this check before calling PlaceLimitOrder():

For bullish FVG:
  double currentAsk = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
  // Gap must still be open: current price must be ABOVE fvgHigh (gap not yet filled from below)
  if (currentAsk <= g_fvgHigh) {
    Log("BULLISH FVG already filled or price below gap. Skip.");
    g_fvgFormed = false;
    return;
  }

For bearish FVG:
  double currentBid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
  // Gap must still be open: current price must be BELOW fvgLow (gap not yet filled from above)
  if (currentBid >= g_fvgLow) {
    Log("BEARISH FVG already filled or price above gap. Skip.");
    g_fvgFormed = false;
    return;
  }

---

FIX 3 — Add minimum FVG size filter (avoid micro-gaps)

After computing g_fvgMid, add:
  double fvgSizePips = (g_fvgHigh - g_fvgLow) / g_pipSize;
  if (fvgSizePips < 5.0) {
    Log("FVG too small: " + DoubleToString(fvgSizePips, 1) + " pips. Skip.");
    return;
  }

---

FIX 4 — Fix g_setupConsumed: only set it on actual order placement

Search the entire file for every occurrence of:
  g_setupConsumed = true;
that appears BEFORE a return statement inside a filter rejection block (H4, PD, weekly bias, news, price check).

Remove g_setupConsumed = true from ALL of those filter-rejection paths.

Keep g_setupConsumed = true ONLY in two places:
  1. Immediately before g_trade.BuyLimit() / g_trade.SellLimit() is called.
  2. After an order placement attempt regardless of success/failure.

Add instead a per-bar rejection guard:
  At the top of ScanForFVGAndEnter(), add:
    static datetime lastScanBar = 0;
    datetime currentBar = iTime(Symbol(), Period(), 0);
    if (currentBar == lastScanBar) return;
    lastScanBar = currentBar;

---

FIX 5 — Add D1 trend filter as additional confirmation

Add a new function:
  bool IsD1Bullish() {
    double ema200 = iMA(Symbol(), PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
    return (iClose(Symbol(), PERIOD_D1, 1) > ema200);
  }

In PlaceLimitOrder(), before placing any order:
  bool d1Bull = IsD1Bullish();
  if (g_sweepBullish && !d1Bull) {
    Log("D1 FILTER: BUY rejected — price below D1 EMA200.");
    return;   // do NOT set g_setupConsumed here
  }
  if (!g_sweepBullish && d1Bull) {
    Log("D1 FILTER: SELL rejected — price above D1 EMA200.");
    return;   // do NOT set g_setupConsumed here
  }

---

FIX 6 — Increase default SL to 25 pips and order expiry to 25 bars

Change:
  input double InpSLPips = 20.0   →  input double InpSLPips = 25.0
  input int InpOrderExpiryBars = 10  →  input int InpOrderExpiryBars = 25

---

After all changes, compile, then backtest on EURUSD M15 from Jan 2024 to Apr 2026 with $10,000 initial deposit and report the results.
