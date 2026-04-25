next step, turn this into a strict severity-ranked bug list with exact fix order.

I want this project to be a strict, pure ICT logic.

I want to Refactor this project to “True ICT Execution Pipeline” (institution-grade).

the final push for my EA is narrative + context + execution timing, “structured probabilistic behavior inspired by ICT”

=======================================================

The system trades more on pattern-matching than true ICT logic. 

CRITICAL ISSUES — TOP 10

Issue 1 — FindLatestFVG returns the OLDEST FVG, not the latest
In ICT_FVG.mqh, LoadRates uses ArraySetAsSeries(rates, true), making index 0 = most recent.
for(int center = lookbackBars; center >= 2; center--)

Issue 2 — FindLatestOrderBlock returns the OLDEST OB
Same problem as Issue 1. In ICT_OrderBlock.mqh:
for(int shift = m_lookbackBars; shift >= 5; shift--)

Issue 3 — Phase 7 (IPDA and SMT) is visualization-only, zero impact on trades
In the main EA's OnTick:
g_ipda.Compute();
g_smt.Scan(PERIOD_H1, 100);
g_visualizer.DrawIPDALevels(ipdaSnap);
g_visualizer.DrawSMTMarker(smtSnap);

Issue 4 — RefreshAnalysisEngines is called on every single tick
In OnTick:
g_session.Refresh();
g_risk.Refresh();
RefreshAnalysisEngines();  // 5x CopyRates calls for 300-1000 bars each

Issue 5 — MARK1_MAGIC constant vs set file MagicNumber mismatch is live-trade dangerous
ICT_Constants.mqh: #define MARK1_MAGIC 20240001
MARK1_Funded.set: MagicNumber=20260419

Issue 6 — ResolveBias uses last 2 swings with no chronological alternation check
In ICT_Structure.mqh, ResolveBias():
bool bullish = (latestHigh > previousHigh + epsilon) && (latestLow > previousLow + epsilon);

Issue 7 — Weekly and Monthly bias resolution is a single candle's direction, not structure
In ICT_Bias.mqh:
double wClose = iClose(m_symbol, PERIOD_W1, 1);
double wOpen  = iOpen(m_symbol, PERIOD_W1, 1);
return (wClose > wOpen) ? ICT_SESSION_BIAS_LONG_ONLY : ICT_SESSION_BIAS_SHORT_ONLY;

Issue 8 — IsHardcodedNewsTime blocks ALL trading on Tuesday and Thursday 13:00-14:00 GMT every week
In ICT_Session.mqh:
if((dt.hour == 13 || dt.hour == 14) && (dt.day_of_week == 2 || dt.day_of_week == 4))
    return true;

Issue 9 — Swing classification compares to the immediately prior swing regardless of timeframe or structural context
ClassifyHigh() and ClassifyLow() in ICT_Structure.mqh:
double previous = m_swingHighs[count - 1].price;
return (price > previous + epsilon) ? ICT_SWING_HH : ICT_SWING_LH;

Issue 10 — The MARK1_Optimizer.py run_backtest_and_read_result is a permanent stub
def run_backtest_and_read_result(symbol, set_path):
    return {
        "profit_factor": 0.0,
        "net_profit": 0.0,
        "drawdown_pct": 0.0,
        "win_rate": 0.0,
    }

Improvement Roadmap:
Immediate Fixes (Bugs that affect live trades)
Fix 1: Reverse FindLatestFVG loop to return newest FVG. Change for(int center = lookbackBars; center >= 2; center--) to for(int center = 2; center <= lookbackBars; center++). Store all candidates and return the last one found, or return on first match from the newest direction.
Fix 2: Same fix for FindLatestOrderBlock. for(int shift = 5; shift <= m_lookbackBars; shift++), return last valid match (most recently formed = highest shift in reversed time = lowest shift in as-series... wait, let me re-clarify). With as-series=true, lowest shift = most recent. Scan from shift=m_lookbackBars (oldest) to shift=5 (newest, but still historical), and don't return on first match — continue scanning and overwrite the result, so the LAST overwrite is the newest qualifying OB. Or scan from shift=5 to shift=m_lookbackBars (newest to oldest) and return on first match. The latter is more efficient.
Fix 3: Correct FVG Consequent Encroachment: change zone.consequentEncroachment = (centerCandleOpen + centerCandleClose) / 2.0 to zone.consequentEncroachment = (zone.low + zone.high) / 2.0. This restores the gap midpoint as CE per ICT definition.
Fix 4: Move RefreshAnalysisEngines() inside the IsNewBar() block to eliminate tick-based structure engine spam.
Fix 5: Remove the Tuesday/Thursday blanket 13:00-14:00 hardcoded block from IsHardcodedNewsTime. Let the MQL5 calendar handle real news events.
Fix 6: Remove ICT_PDA_EQUILIBRIUM from longAllowed and shortAllowed gates. Only trade from discount (longs) and premium (shorts).
Fix 7: Reset m_consecutiveLosses in ResetDay(). Add m_consecutiveLosses = 0; to the ResetDay() function.
Fix 8: Fix MARK1_Optimizer.py write_set_file BOM handling. Use encoding="utf-16" (Python includes BOM automatically) instead of encoding="utf-16-le". Add try/finally to restore base_params on exception.
Fix 9: Add required timestamp check in SMT and IPDA — update them on H1 bar change, not D1 bar change. Change the trigger from d1Bar > g_lastD1BarTime to h1Bar > g_lastH1BarTime for SMT, and keep IPDA on D1.
Fix 10: OB zone should include wicks. Change zone.low = MathMin(rates[shift].open, rates[shift].close) to zone.low = rates[shift].low and zone.high = rates[shift].high. Update midpoint accordingly.

Medium Enhancements:
Enhancement 1: Integrate IPDA into trade decisions. In BuildSetupCandidate, add: if price is within 5 pips of IPDA 20-bar equilibrium, skip setup (price is seeking direction, not delivering). Add +1 confluence if entry price is within 10 pips of IPDA 20-bar low (bullish setup, price at discount of IPDA range).
Enhancement 2: Integrate SMT into confluence score. In BuildSetupCandidate, after g_smt.Scan(): if smtDivergence.isBullishSMT && bullish or smtDivergence.isBearishSMT && !bullish, add setup.confluenceScore++. This gives SMT-aligned trades higher priority.
Enhancement 3: Add minimum swing size filter to structure engine. In ClassifyHigh/ClassifyLow, only classify if the price difference from the previous swing exceeds a minimum (e.g., 5 pips). Reduces noise in ranging markets dramatically.
Enhancement 4: Replace weekly/monthly bias single-candle logic with structure-based bias. Use the existing W1 and MN1 structure engines (or add them) to determine whether the weekly structure has HH/HL or LH/LL. ResolveWeeklyBias() should call the W1 structure engine and return NEUTRAL when the weekly structure is in range.
Enhancement 5: Add MarketMaker model sweep verification. After finding equal levels on H1, verify with liqEngine.DetectSweepOfLevel(equalLevel, sweepSignal) before accepting the setup. Reject if the equal level has not been swept.
Enhancement 6: Extend FindInducement swing detection to require N bars on each side (N=2 minimum). Change rates[i].low < rates[i+1].low && rates[i].low <= rates[i-1].low to a proper mini-swing scan requiring at least 2 higher bars on each side.
Enhancement 7: Add DOW phase gates to the canonical pipeline. In BuildSetupCandidate or the main OnTick flow, block continuation setups on Monday (DOW_MONDAY = accumulation only, no direction). Restrict TGIF to short sessions (block after 14:00 GMT on Fridays). Block all entries on DOW_WEEKEND (handled by session windows, but explicit gate is cleaner).
Enhancement 8: Fix Python SMT scanner to use proper swing detection. In scan_smt_divergences(), instead of window min/max comparison, implement a rolling swing low detector: find the local minimum within each window (requiring N bars higher on each side) and compare those specific swing lows between EUR and GBP.

Advanced Upgrades:
Upgrade 1: HTF Bias cascade — add a W1 structure engine and integrate it into the consensus vote as a 4th timeframe. Use a supermajority rule: 3 of 4 timeframes must agree for a trade to fire. This dramatically reduces counter-trend false positives.
Upgrade 2: Regime detection — implement a volatility regime classifier (e.g., H4 ATR ratio relative to 20-day average). In low-volatility regime (ATR < 0.5×20d average): tighten MinRR to 3:1, increase MinConfluence to 3, disable OB-only entries. In high-volatility regime: widen spread filter, tighten SL buffers, block continuation model. ICT concepts work differently in different volatility regimes.
Upgrade 3: Formal pipeline state machine — replace global g_hasActiveSweep/g_lastSetupSweep variables with an enum-driven state machine class: ENUM_PIPELINE_STATE { IDLE, SWEEP_DETECTED, AWAITING_BOS, SETUP_BUILDING, ORDER_PENDING, POSITION_OPEN, BLOCKED }. Each state transition has validation logic and a timeout.
Upgrade 4: Per-session drawdown tracking — add separate daily drawdown buckets for London and NY sessions. If London session loses DailyMaxLoss/2, halt for NY. If both sessions are profitable, increase SL buffer size slightly. This prevents a bad London day from compounding into a bad NY day.
Upgrade 5: NDOG/NWOG as hard TP targets when unfilled — currently NDOG/NWOG are drawn on the chart but not enforced as TP caps. If price is between entry and an unfilled NDOG, the NDOG gap boundary should act as a minimum TP target (DOL logic). Wire ComputeNDOG and ComputeNWOG into SelectOpposingLiquidityTarget as additional candidates.
Upgrade 6: Implement the optimizer properly. Use MT5's terminal.exe /config:backtest_config.ini subprocess approach or the MT5 Python API's mt5.strategy_tester_start() (if available in your MT5 build). Without a functional optimizer, parameter selection is purely manual and unvalidated.