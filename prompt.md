You are a senior MQL5 architect. I am attaching my complete ICT_LondonSweep_FVG.mq5 
EA (MARK1 project). It compiles clean but produces terrible backtest results:
19 trades, PF 0.25, Win Rate 15.79%, Max DD 3.93%.

The DD is acceptable but the win rate and PF are broken. I need you to fix 
specific diagnosed bugs and refactor the entry quality logic. Do NOT change 
the overall ICT strategy concept. Work with the existing code structure.

==============================================================
PART 1 — FIX THESE SPECIFIC BUGS (in order of impact)
==============================================================

BUG-1: FVG SCAN IS HARDCODED TO BARS 1 AND 3 ONLY
  Location: ScanForFVGAndEnter()
  Problem: Variables high1/low1 and high3/low3 only check one fixed 3-bar window.
           InpFVGScanBars input exists but is completely unused in this function.
  Fix: Loop from i=1 to InpFVGScanBars, checking each 3-bar combination [i, i+1, i+2].
       Use the FIRST (most recent) valid FVG found that matches sweep direction.
       Minimum FVG size: (fvgHigh - fvgLow) >= InpMinFVGPips * g_pipSize
       If no FVG found in the scan window, log "No FVG in scan window" and return 
       without setting g_setupConsumed = true (allow retry next bar).

BUG-2: g_setupConsumed = true FIRES ON FILTER REJECTION — KILLS THE WHOLE DAY
  Location: PlaceLimitOrder() — every early return from filters sets g_setupConsumed=true
  Problem: If H4 filter rejects a London trade, g_setupConsumed=true blocks the 
           Silver Bullet and NY session for the rest of the day.
  Fix: g_setupConsumed should ONLY be set to true when:
       (a) An order was successfully placed, OR
       (b) The FVG was found but the price geometry was invalid (entry >= ask, etc.)
       Filter rejections (H4, WeeklyBias, PD, OB) must NOT set g_setupConsumed=true.
       Instead, return silently — allow the next session window to retry.
       Add a new bool g_londonSetupConsumed and g_nySetupConsumed for per-session tracking.

BUG-3: NY KILL ZONE USES STALE ASIAN RANGE FOR SWEEP DETECTION
  Location: OnTick() — DetectJudasSwing() called for both London AND NY
  Problem: At 13:00 GMT, the Asian range is 13 hours old. Any "sweep" detected 
           against it is meaningless.
  Fix: For NY session, detect sweeps of the LONDON SESSION RANGE (08:00-12:00 GMT 
       high and low), not the Asian range.
       Add new globals: g_londonHigh, g_londonLow, g_londonRangeSet
       Capture London range high/low during 08:00-12:00 GMT (after Asian range locks)
       In NY sweep detection, use g_londonHigh and g_londonLow as the reference levels.
       Separate the sweep function: DetectLondonJudasSwing() and DetectNYSweep()

BUG-4: SILVER BULLET HAS NO INDEPENDENT ENTRY STATE
  Location: OnTick(), ScanForFVGAndEnter()
  Problem: Silver Bullet (15:00-16:00 GMT) reuses g_sweepDetected from London session.
           If London ran and was consumed, Silver Bullet never fires.
           If London was rejected by filters, Silver Bullet uses a stale 7-hour-old sweep.
  Fix: Silver Bullet is an independent model. It needs:
       - Its own sweep state: g_sbSweepDetected, g_sbSweepBullish, g_sbSweepExtreme
       - Sweep reference: NY morning range (13:00-15:00 GMT high/low)
       - Its own FVG scan and entry placement
       - Its own g_sbSetupConsumed flag
       Add: g_nyMorningHigh, g_nyMorningLow captured during 13:00-15:00 GMT
       Silver Bullet sweep: wick beyond g_nyMorningHigh/Low + close back inside
       Silver Bullet SL: use g_sbSweepExtreme ± InpSilverBulletSLPips (keep existing input)

BUG-5: SL PLACEMENT IS INCONSISTENT
  Location: PlaceLimitOrder()
  Current: slPrice = g_sweepExtreme - slDistance (fixed pip offset from wick tip)
  Problem: Makes SL distance random — depends on how far the wick extended.
           On some days SL is 15 pips, others 40 pips, making lot sizing erratic.
  Fix: Use the Asian range itself to set a consistent SL:
       asian_range_pips = (g_asianHigh - g_asianLow) / g_pipSize
       For LONG: slPrice = g_asianLow - (0.2 * asian_range_pips * g_pipSize)
       For SHORT: slPrice = g_asianHigh + (0.2 * asian_range_pips * g_pipSize)
       Then: sl_pips = MathAbs(entryPrice - slPrice) / g_pipSize
       Clamp: if sl_pips < 12 → set sl_pips = 12; if sl_pips > 45 → set sl_pips = 45
       This gives a consistent, structure-based SL every day.

==============================================================
PART 2 — ENTRY QUALITY IMPROVEMENTS (add these)
==============================================================

IMPROVEMENT-1: TIERED TAKE PROFIT (replace single 3RR TP)
  Current: Single TP at 3RR — almost never hit, explains low win rate.
  Replace with:
    TP1 = entry ± (1.0 * risk_distance) → close 60% of position, move SL to breakeven
    TP2 = entry ± (2.0 * risk_distance) → close remaining 40%
  This gives "wins" at 1RR which a 3RR target never produces.
  Implementation: Place order with TP at 2RR. After TP1 level is hit 
  (check in OnTick via position profit >= 1R), close 60% and modify SL to breakeven.
  Add globals: g_tp1Hit = false, g_positionTicket for tracking.
  Add function: ManageOpenPosition() called every tick when a position is open.

IMPROVEMENT-2: ASIAN RANGE SIZE FILTER
  Before any trade, validate the Asian range is tradeable:
  asian_range_pips = (g_asianHigh - g_asianLow) / g_pipSize
  If asian_range_pips < 8 → Log("Asian range too small, skip day") and set 
    g_londonSetupConsumed = true (skip London) but NOT NY/Silver Bullet
  If asian_range_pips > 50 → Log("Asian range too large, skip day — already volatile")
    and block ALL sessions for the day.
  This single filter eliminates the worst trading days.

IMPROVEMENT-3: DISPLACEMENT CONFIRMATION BEFORE FVG SCAN
  Before calling ScanForFVGAndEnter(), require a displacement candle:
  bool HasDisplacementCandle():
    Check bar[1] (the bar right after the sweep candle)
    body = MathAbs(iClose - iOpen) of bar[1]
    range = iHigh - iLow of bar[1]  
    body_pct = (body / range) * 100 if range > 0 else 0
    body_pips = body / g_pipSize
    Return: body_pct >= InpMinDisplacementBodyPct AND body_pips >= InpMinDisplacementPips
             AND direction matches sweep (bullish sweep → bar[1] is bullish close > open)
  Only call ScanForFVGAndEnter() if HasDisplacementCandle() returns true.

IMPROVEMENT-4: PROP FIRM DAILY EQUITY GUARD (runs every tick)
  Add at the TOP of OnTick() before any other logic:
  
  double startDayEquity — recorded at midnight GMT each day (in ResetDailyState)
  double startBalance — recorded at OnInit() and updated after TP2 hits
  
  Every tick, check:
    currentEquity = AccountInfoDouble(ACCOUNT_EQUITY)
    dailyLoss = (startDayEquity - currentEquity) / startDayEquity * 100
    totalDD = (startBalance - currentEquity) / startBalance * 100
    
    if dailyLoss >= InpMaxDailyLossPct (default 4.0):
      Close all positions (loop PositionsTotal, call trade.PositionClose)
      Delete all pending orders
      Set g_tradingHaltedToday = true
      Log("DAILY LOSS LIMIT HIT — trading halted")
      return
    
    if totalDD >= InpMaxTotalDDPct (default 8.0):
      Close all positions
      Set g_tradingHaltedPermanent = true
      Log("MAX DRAWDOWN LIMIT HIT — EA disabled")
      return
    
    if g_tradingHaltedToday or g_tradingHaltedPermanent: return
  
  Add inputs:
    InpMaxDailyLossPct = 4.0   // Hard stop: 4% daily (FTMO limit is 5%)
    InpMaxTotalDDPct = 8.0     // Hard stop: 8% total (FTMO limit is 10%)
  
  Reset g_tradingHaltedToday = false in ResetDailyState() each morning.

IMPROVEMENT-5: ATR REGIME FILTER
  In OnTick(), after Asian range locks at London open:
  Add function bool IsGoodVolatilityRegime():
    atrHandle = iATR(Symbol(), PERIOD_H4, 14)
    Get ATR value into array, check atrValue[0]
    atr_pips = atrValue[0] / g_pipSize
    if atr_pips < 20 → return false (dead market)
    if atr_pips > 150 → return false (extreme/news spike)
    return true
  If !IsGoodVolatilityRegime() → skip day (log reason), return from OnTick.
  This makes the EA regime-adaptive across any date range.

==============================================================
PART 3 — INPUT PARAMETERS TO ADD
==============================================================
  input double InpMaxDailyLossPct = 4.0;    // Prop firm daily loss guard (%)
  input double InpMaxTotalDDPct = 8.0;      // Prop firm total drawdown guard (%)
  input double InpMinAsianRangePips = 8.0;  // Skip days with tiny Asian range
  input double InpMaxAsianRangePips = 50.0; // Skip days with huge Asian range  
  input double InpTP1RR = 1.0;              // First TP at 1R (close 60%)
  input double InpTP2RR = 2.0;              // Second TP at 2R (close 40%)
  input int    InpMinDisplacementBodyPct = 60; // Min displacement body %
  input int    InpMinDisplacementPips = 6;     // Min displacement body pips
  input int    InpFVGScanBars = 5;          // Bars to scan for FVG (was unused)
  input double InpMinFVGPips = 3.0;         // Minimum FVG gap size in pips
  input double InpMinATRH4Pips = 20.0;      // Min H4 ATR for regime filter
  input double InpMaxATRH4Pips = 150.0;     // Max H4 ATR for regime filter

==============================================================
PART 4 — DO NOT CHANGE
==============================================================
  - FIX-01 through FIX-16 already in the code (keep all of them)
  - ORDER_FILLING_RETURN (FIX-15) — keep
  - CalendarValueHistory news filter with hardcoded fallback — keep  
  - H4 BOS functions IsH4BullishBOS() / IsH4BearishBOS() — keep as is
  - GMT offset calculation — keep
  - Magic number tracking — keep
  - Order expiry logic (InpOrderExpiryBars) — keep

==============================================================
PART 5 — VALIDATION TARGETS AFTER REFACTOR
==============================================================
  Backtest: EURUSD M15, Every Tick, 2023-01-02 to 2023-06-08
  Pass criteria:
  - Trades: 50-120
  - Profit Factor: >= 1.4
  - Win Rate: >= 32% (tiered TP makes this achievable)
  - Max Drawdown: <= 6%
  - Max Consecutive Losses: <= 5

  If win rate is below 32% after changes, report which gate is 
  filtering the most setups by adding a counter to each gate and 
  printing a daily summary: 
  "Gate stats: Sweep=X FVG=X Displacement=X H4=X Asian=X ATR=X Orders=X"

==============================================================
DELIVER:
==============================================================
  1. Complete refactored ICT_LondonSweep_FVG.mq5 — zero compile errors
  2. Comment each change with // [MARK1-FIX-XX] tag
  3. List of every change made with before/after summary
  4. Any remaining risks to test manually
