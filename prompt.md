You are an expert MQL5 developer and institutional-grade forex EA architect. 
I am providing you with my complete MARK1.mq5 EA code. Your task is a deep, 
systematic refactor to make it robust, prop-firm compliant, and profitable 
across any date range and market regime.

=== CONTEXT ===
Strategy: ICT methodology — Asian Range definition → London Judas Swing 
(liquidity sweep) → Fair Value Gap entry → M15 EURUSD
Goal: Pass FTMO Standard Challenge and trade funded account
Problem: EA worked in early 2023 but performance degrades over time, 
win rate too low (~23%), max DD too high (~37%), only 26 trades/15 months

=== PROP FIRM HARD RULES (embed as kill switches in code) ===
- Max Daily Loss: 4.0% of starting day equity (FTMO limit is 5% — stay 1% inside)
- Max Total Drawdown: 8.0% of initial balance (FTMO limit is 10% — stay 2% inside)
- Daily loss is calculated on FLOATING equity (open trades count) — check every tick
- If either limit is hit → close ALL trades + block new trades for rest of day
- Weekly drawdown soft cap: 3.5% — reduce lot size to 50% for remainder of week
- No trades on Friday after 20:00 GMT (weekend gap risk)
- No trades during news (high-impact, ±30 min window)
- Max 1 trade per day per direction

=== ENTRY LOGIC — REBUILD IN THIS EXACT ORDER (all must pass) ===

GATE 1 — SESSION FILTER
  Valid sessions: London Kill Zone 07:00–10:00 GMT, NY Kill Zone 13:00–16:00 GMT
  Silver Bullet bonus window: 10:00–11:00 GMT (London close)
  Outside these windows → no new trades

GATE 2 — ASIAN RANGE LOCK
  Asian session: 00:00–07:00 GMT (your current InpAsianStart/End)
  Lock the high and low at 07:00 GMT exactly
  Require Asian range to be between 8–40 pips (filter dead/explosive days)
  If range < 8 pips → skip day (range too compressed, no sweep opportunity)
  If range > 40 pips → skip day (already too volatile, sweep likely done)

GATE 3 — LIQUIDITY SWEEP CONFIRMATION (CRITICAL — add this, it's missing)
  For LONG setup: 
    Price must wick BELOW asian_low by at least 2 pips
    AND the M15 candle must CLOSE BACK ABOVE asian_low
    This confirms the stop hunt / Judas sweep happened
  For SHORT setup:
    Price must wick ABOVE asian_high by at least 2 pips  
    AND the M15 candle must CLOSE BACK BELOW asian_high
  Without this confirmation → NO ENTRY. This is the single biggest fix.

GATE 4 — DISPLACEMENT CANDLE
  After the sweep candle, the NEXT candle must show displacement:
  Body size ≥ 60% of full candle range
  Body size in pips ≥ 6 pips
  Direction must OPPOSE the sweep (sweep down → displacement up = bullish)
  Both conditions must be true simultaneously

GATE 5 — FVG DETECTION
  Scan the last InpFVGScanBars (default 5) candles after displacement
  Bullish FVG: candle[i].low > candle[i+2].high (gap between candle 0 top and candle 2 bottom)
  Bearish FVG: candle[i].high < candle[i+2].low
  FVG must be ≥ InpMinFVGPips (default 3 pips) wide
  Only use the MOST RECENT valid FVG

GATE 6 — OTE ENTRY (fix: change from 25% to 50% of FVG)
  Entry price = fvg_low + (fvg_high - fvg_low) * 0.50  // for longs
  Entry price = fvg_high - (fvg_high - fvg_low) * 0.50  // for shorts
  Use pending limit order (not market order) so entry only triggers at OTE
  Order expires after InpOrderExpiryBars bars if not filled

GATE 7 — HTF BIAS CONFIRMATION (enable this — was falsely disabled)
  H4 timeframe: Check if last 3 H4 candles show BOS in trade direction
  BOS for long = H4 made a higher low recently
  BOS for short = H4 made a lower high recently
  If H4 disagrees with trade direction → reduce lot size to 50%, don't skip entirely

=== STOP LOSS — REPLACE FIXED PIPS WITH DYNAMIC ===
  asian_range = asian_high - asian_low
  sl_distance = asian_range * 1.1 (10% beyond the swept extreme)
  Minimum SL: 15 pips, Maximum SL: 50 pips
  Place SL at: asian_low - sl_distance (for longs)
                asian_high + sl_distance (for shorts)
  This adapts to each day's actual market structure automatically

=== TAKE PROFIT — TIERED EXITS (replace single TP) ===
  TP1: 1.0 × risk (50% of position) → close and move SL to breakeven
  TP2: 2.0 × risk (remaining 50%) → final close
  This secures profit early and lets remainder run
  Do NOT use a 3RR single TP — too few winners reach it

=== RISK MANAGEMENT RULES ===
  Base risk per trade: 0.5% of current equity
  After 2 consecutive losses → reduce to 0.25% until 1 win
  After 4 consecutive losses → stop trading for the day
  After hitting weekly soft cap (3.5% DD) → trade at 0.25% rest of week
  Lot size formula: lots = (equity * risk_pct) / (sl_pips * pip_value)
  Always recalculate lots fresh per trade, never cache it

=== REGIME FILTER — MAKES IT WORK ACROSS ANY DATE RANGE ===
  Add ATR-based regime detection on H4:
  atr_14 = iATR(Symbol(), PERIOD_H4, 14)
  If atr_14 < 30 pips → low volatility regime → skip day (market not moving)
  If atr_14 > 120 pips → extreme regime → reduce risk to 0.25%
  Normal regime (30-120 pips ATR) → trade normally
  This is WHY the EA fails in different periods — regime changes break fixed-pip logic

=== TRADE MANAGEMENT (add these) ===
  Breakeven: Move SL to entry + 1 pip after TP1 hits
  Trailing stop: After TP1, trail SL by 50% of ATR on M15
  Max trade duration: 8 hours — close any open trade at session end regardless of PnL
  No overnight holds (FTMO standard account restriction)

=== CODE QUALITY REQUIREMENTS ===
  1. Every gate must be a separate bool function: 
     bool Gate1_SessionFilter(), Gate2_AsianRange(), Gate3_SweepConfirmed(), etc.
  2. All gates logged to file when InpEnableDebug=true
  3. Enum for trade state machine: IDLE, AWAITING_SWEEP, AWAITING_FVG, PENDING_ENTRY, IN_TRADE
  4. No magic numbers in code — all values must reference named constants or input params
  5. HistorySelect() before every HistoryDealSelect() call
  6. Check IsTradeAllowed() before every OrderSend()
  7. Daily reset at 00:00 GMT sharp (not broker time) using TimeGMT()
  8. g_setupConsumed reset only after kill zone ends (preserve your BUG-2 fix)
  9. PropFirm safety check runs on EVERY tick, not just on bar open
  10. All monetary calculations in account currency, handle JPY pairs correctly

=== INPUTS TO EXPOSE ===
  // Risk
  InpRiskPercent = 0.5
  InpMaxDailyLossPct = 4.0
  InpMaxTotalDDPct = 8.0
  InpWeeklyDDSoftCapPct = 3.5
  
  // Structure
  InpAsianStartGMT = 0
  InpAsianEndGMT = 7
  InpMinAsianRangePips = 8
  InpMaxAsianRangePips = 40
  InpSweepConfirmPips = 2
  
  // Entry
  InpFVGScanBars = 5
  InpMinFVGPips = 3
  InpOTEPercent = 50  // 50% of FVG = OTE
  InpOrderExpiryBars = 3
  InpMinDisplacementBodyPct = 60
  InpMinDisplacementPips = 6
  
  // Exit
  InpTP1Ratio = 1.0
  InpTP2Ratio = 2.0
  InpMaxTradeDurationHours = 8
  
  // Filters
  InpEnableH4Filter = true
  InpMinATRH4 = 30
  InpMaxATRH4 = 120
  InpNewsHaltMinutes = 30
  InpEnableDebug = true

=== BACKTEST VALIDATION TARGETS ===
  After refactor, backtest on EURUSD M15, Every Tick, 2023-01-02 to 2023-06-08
  Minimum pass criteria:
  - Trade count: 60–150
  - Profit Factor: ≥ 1.5
  - Win Rate: ≥ 30%
  - Max Drawdown: ≤ 8%
  - Consecutive losses: ≤ 5
  
  If not met, report which gate is filtering too many or too few trades by checking
  the debug log counts per gate.

=== WHAT TO DELIVER ===
  1. Complete refactored MARK1.mq5 — compiles with zero errors/warnings
  2. Brief comment above each gate function explaining the ICT concept it implements
  3. A summary of every logical change made vs the current code
  4. Flag any remaining risks or edge cases I should test manually

Now read my attached MARK1.mq5 code and perform this full refactor.

Key Reasons Why Your EA Was Declining
Root CauseFix in PromptNo sweep confirmation gateGate 3 — mandatory wick+close checkFixed 30-pip SL ignores market structureDynamic SL = Asian range × 1.125% FVG entry → bad fill rateGate 6 → 50% OTE entryNo regime detection → breaks in low/high volATR H4 regime filterSingle 3RR TP → almost never hitTiered TP1 at 1R + TP2 at 2RDD checks only on bar openPropFirm check every tick (open equity counts)H4 filter disabledRe-enabled, softened to lot reduction not skipRisk not reducing after lossesDrawdown-adaptive lot sizing
The ATR regime filter and sweep confirmation gate are the two changes that will most directly fix the "works early, degrades later" problem — because they make the EA skip days where the strategy structurally doesn't apply, rather than forcing entries in wrong conditions.
