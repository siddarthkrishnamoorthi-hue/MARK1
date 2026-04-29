# MARK1 — ICT Expert Advisor v4.0

> **Strategy:** Inner Circle Trader (ICT) | **Symbol:** EUR/USD | **Platform:** MetaTrader 5
> **Purpose:** Fully-automated, prop-firm-safe algorithmic trading system built on institutional order flow concepts.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [9-Phase Implementation](#9-phase-implementation)
4. [Strategy Logic](#strategy-logic)
5. [Entry Models](#entry-models)
6. [Risk Management](#risk-management)
7. [Configuration Parameters](#configuration-parameters)
8. [Installation](#installation)
9. [Python Analytics Suite](#python-analytics-suite)
10. [Standards & Conventions](#standards--conventions)

---

## Overview

MARK1 is a multi-phase, modular MetaTrader 5 Expert Advisor that implements the full ICT trading methodology. It is engineered for:

- **Funded / prop-firm accounts** — hard daily and weekly drawdown guards, spread filter, consecutive-loss circuit breaker, and precise lot sizing enforce the rules of any funded challenge or live allocation.
- **Institutional order flow alignment** — every trade requires a liquidity sweep, a market structure break (BOS/CHoCH/MSS), alignment with higher-timeframe bias, and at least one premium/discount array confirmation (FVG, Order Block, BPR).
- **Full ICT concept coverage** — Silver Bullet windows, Judas Swing / Power of 3, IPDA draw-on-liquidity levels, SMT divergence between EUR/USD and GBP/USD, and a full six-model entry suite.

---

## Architecture

The codebase is split into a thin EA driver and nine single-responsibility header modules:

| File | Role |
|------|------|
| `ICT_EURUSD_EA.mq5` | EA entry point — `OnInit`, `OnTick`, `OnTradeTransaction`; wires all engines together |
| `ICT_Constants.mqh` | Global constants: `MARK1_MAGIC`, `MARK1_VERSION`, pip factor, TP ratios |
| `ICT_Structure.mqh` | Swing-high/low detection with H→L→H→L alternation enforcement, BOS/CHoCH/MSS classification, structure snapshots |
| `ICT_FVG.mqh` | Fair Value Gap detection, Consequent Encroachment, Implied FVG, Balanced Price Range |
| `ICT_Session.mqh` | Kill-zone windows, Silver Bullet windows, Asian range, Judas Swing / PO3, London Close, Midnight Open |
| `ICT_Bias.mqh` | 3-TF consensus bias (D1 + H4 + H1), W1/MN1 structure-based weekly/monthly bias, DOW phase filter, PDA zone (premium / discount / equilibrium) |
| `ICT_Liquidity.mqh` | Liquidity sweep detection, BSL/SSL classification, PDH/PDL/PWH/PWL, NDOG/NWOG, DOL target selection, Run-on-Stops |
| `ICT_OrderBlock.mqh` | Order Block detection, Breaker Block, Mitigation Block, Rejection Block, Propulsion Block, Vacuum Block |
| `ICT_RiskManager.mqh` | Position sizing, TP-split execution, break-even, trailing stop, drawdown guards, spread filter, loss circuit breaker, CSV trade log |
| `ICT_EntryModels.mqh` | Six ICT entry model classes — Silver Bullet, Judas Swing, Market Maker, Turtle Soup, London Close Reversal, TGIF |
| `ICT_IPDA.mqh` | IPDA draw-on-liquidity 20/40/60-bar range engine, equilibrium gate for trade decisions |
| `ICT_SMT.mqh` | Smart Money Technique divergence scanner (EUR/USD vs GBP/USD), confluence scoring integration |
| `ICT_Visualizer.mqh` | Chart-object drawing layer — zones, sweeps, IPDA levels, SMT markers, PO3 boxes, DOW labels, NDOG/NWOG lines |

---

## 9-Phase Implementation

| Phase | Description | Status |
|-------|-------------|--------|
| **1** | Core infrastructure — constants, structure detection (BOS/CHoCH/MSS), FVG engine (CE fix), session windows, 3-TF bias, risk manager skeleton, GMT time standard, magic constant | ✅ Complete |
| **2** | IRL/ERL liquidity classification, IDM (Inducement), NDOG/NWOG opening gaps, Midnight Open, London Close window, Judas Swing / PO3, Weekly/Monthly bias, DOW phase filter, M1 structure engine for STH/STL hooks | ✅ Complete |
| **3** | Implied FVG, Rejection Block, Propulsion Block, Vacuum Block, Order Block reclaim/invalidation tracking | ✅ Complete |
| **4** | Session Opening Range Gaps (NYORG / LDORG), Run-on-Stops detector, DOL target selector, Judas Swing SM signal, DOW phase trade filter | ✅ Complete |
| **5** | Six ICT entry model classes with shared IDM sweep gate and IRL→ERL alignment gate | ✅ Complete |
| **6** | Spread filter, consecutive-loss circuit breaker, pending-order age/session invalidation, per-trade CSV audit log | ✅ Complete |
| **7** | IPDA draw-on-liquidity engine (`ICT_IPDA.mqh`), SMT divergence engine (`ICT_SMT.mqh`), EA wiring on each new D1 bar | ✅ Complete |
| **8** | Full visualizer layer — NDOG/NWOG lines, PO3 box, Judas marker, IPDA high/low/equilibrium lines, DOW phase label, SMT divergence marker | ✅ Complete |
| **9** | Python analytics suite — trade analytics, multi-run optimizer, IPDA script, SMT divergence script | ✅ Complete |

---

## Strategy Logic

### Higher-Timeframe Bias

Bias is determined by a **2-of-3 majority vote** across three timeframes (default: D1, H4, H1). Each timeframe casts a vote based on whether price is delivering from a discount (bullish) or premium (bearish) array relative to its most recent swing range. The result is one of: `LONG_ONLY`, `SHORT_ONLY`, `NEUTRAL`, or `AVOID`. Only `LONG_ONLY` and `SHORT_ONLY` allow new entries.

The **DOW Phase** (Monday–Friday / Weekend) provides an additional timing filter — e.g., TGIF model only fires on Fridays, and Weekend is automatically excluded.

### Power of 3 / Judas Swing

Each London session is monitored for a **Judas Swing**: a false breakout of the Asian range (manipulation phase) followed by a reversal back through the session open (distribution phase). The EA tracks `SJudasSwing` state — `PO3_ACCUMULATION`, `PO3_MANIPULATION`, `PO3_DISTRIBUTION` — and uses this as a directional bias amplifier during the London kill zone.

### Liquidity Sweep

A valid trade requires a **liquidity sweep** of an identifiable pool: Asian session high/low, equal highs/lows (BSL/SSL), previous day high/low, or previous week high/low. The sweep must cover at least `MinSweepPips`. Once detected, the sweep remains valid for `SweepValidityBars` bars.

### Market Structure Break

After the sweep, a **BOS, CHoCH, or MSS** must form on M15 or M5 in the direction of the intended trade. The break time is used to anchor all FVG/OB searches (only zones formed _after_ the sweep are considered).

### Premium / Discount Arrays

Entry is from within a **premium/discount array** — one or more of:
- **FVG** (Fair Value Gap) — entry at Consequent Encroachment or zone midpoint
- **Order Block** (standard, breaker, mitigation, rejection, propulsion, vacuum)
- **Balanced Price Range** (FVG + OB overlap)
- **Implied FVG** (adjacent FVG pair)

Multiple overlapping zones are intersected into a single high-probability entry band. Confluence scoring (`confluenceScore`) counts active zone types; trades require `MinConfluence` points.

### IPDA Levels

The **IPDA engine** computes 20-, 40-, and 60-bar draw-on-liquidity levels on D1. These define the macro premium/discount array and the expected price delivery range for the current quarter or month. IPDA levels are integrated directly into trade decisions:

- **Equilibrium gate**: If the entry zone midpoint is within 5 pips of the 20-bar IPDA equilibrium, the setup is rejected (price is seeking direction — no directional edge).
- **Discount/premium confluence**: If a bullish entry is within 10 pips of the 20-bar IPDA low (institutional accumulation zone), `+1` confluence is added. Mirror logic for bearish setups at the IPDA high.

### SMT Divergence

When EUR/USD makes a new swing low (bullish setup) but GBP/USD does **not** confirm that low, an **SMT bullish divergence** is flagged — indicating institutional accumulation on EUR/USD. The mirror applies for bearish setups. SMT divergence is updated on each new H1 bar and integrated into the confluence scoring:

- **Aligned SMT**: If the divergence direction matches the trade direction, `+1` confluence.
- **Opposing SMT**: If the divergence direction opposes the trade direction, `−1` confluence (reduces edge).

### OTE (Optimal Trade Entry)

When `UseOTE=true` and multiple trade slots are available, entries are distributed across the **62%–79% Fibonacci retracement** zone of the impulse leg (OTE pocket). Up to three limit orders are placed at the 62%, 70.5%, and 79% levels.

---

## Entry Models

All six models share two mandatory gates:
1. **IDM Gate** — An **Inducement** (small structure point engineered to trigger retail stops) must have been swept before the model activates.
2. **IRL → ERL Gate** — Price must be delivering from an Internal Range Liquidity level (FVG / OB) toward an External Range Liquidity target (PDH, PDL, swing extreme).

| Model | Class | Session Window | Key Condition |
|-------|-------|---------------|---------------|
| Silver Bullet | `CSilverBulletModel` | London 03:00–04:00 / NY AM 10:00–11:00 / NY PM 14:00–15:00 UTC | FVG fill entry during SB window after IDM sweep |
| Judas Swing | `CJudasSwingModel` | London kill zone | Asian range false break confirmed + BOS back through session open |
| Market Maker | `CMarketMakerModel` | NY AM kill zone | Stop-hunt on both sides of Asian range; entry from OB/FVG on reversal |
| Turtle Soup | `CTurtleSoupModel` | Any kill zone | Equal highs/lows sweep failure; entry from nearest FVG/OB |
| London Close Reversal | `CLondonCloseReversalModel` | London Close 15:00–16:00 UTC | Price reaches premium/discount extreme during close; fades the move |
| TGIF (Friday Reversal) | `CTGIFModel` | Friday NY session | End-of-week liquidity grab; fades the week's range extension |

---

## Risk Management

### Position Sizing

Lot size is computed per-order from `RiskPercent` of account balance, divided proportionally by the TP-split weights:

| TP Level | Default Allocation | Notes |
|----------|-------------------|-------|
| TP1 | 35% (`TP1_RATIO`) | Close-in target — FVG CE or 1:1 RR |
| TP2 | 40% (`TP2_RATIO`) | Mid target — nearest opposing liquidity pool |
| TP3 | 25% (`TP3_RATIO`) | Runner — farthest opposing liquidity pool |

### Drawdown Guards

| Guard | Parameter | Default |
|-------|-----------|---------|
| Daily max loss | `DailyMaxLoss` | 3.0% |
| Weekly max drawdown | `WeeklyMaxDD` | 6.0% |
| Consecutive loss circuit breaker | `MaxConsecLosses` | 3 |
| Spread filter | `MaxSpreadPips` | 3.0 pips |

When daily or weekly limits are breached, **all pending orders are cancelled** and no new entries are accepted until the relevant period rolls over.

### Position Management

- **Break-even**: SL moves to entry + `BreakEvenBufferPips` after TP1 is hit.
- **Trailing stop**: Optionally enabled via `EnableTrailingStop`; trails behind the most recent M15/M5 swing point.
- **Pending expiry**: Unfilled limit orders are cancelled after `PendingExpiryBars` bars or at session change.

### Trade Logging

Every closed trade is appended to `MARK1_trades.csv` in the MQL5 `Files/` directory with: ticket, symbol, direction, entry/exit prices, lot, PnL, bias at entry, DOW phase, and session window.

---

## Configuration Parameters

### Core Risk

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `RiskPercent` | 0.50 | 0.05–2.0 | % of balance risked per trade |
| `MaxTrades` | 2 | 1–3 | Max concurrent positions |
| `DailyMaxLoss` | 3.0 | 0.25–5.0 | Daily loss limit (% balance) |
| `WeeklyMaxDD` | 6.0 | 0.25–8.0 | Weekly drawdown limit (% balance) |
| `MaxSpreadPips` | 3.0 | — | Block new entries above this spread |
| `MaxConsecLosses` | 3 | — | Halt after N consecutive losses |

### ICT Detection

| Parameter | Default | Description |
|-----------|---------|-------------|
| `OB_Lookback` | 10 | Bars to scan for Order Blocks |
| `FVG_MinGap` | 10 | Minimum FVG size in points |
| `SwingStrength` | 3 | Bars each side to confirm a swing point |
| `MinConfluence` | 2 | Minimum confluence score to place a trade |
| `EqualTolerancePips` | 5.0 | Tolerance for equal highs/lows classification |
| `MinSweepPips` | 2.0 | Minimum sweep extension to qualify |
| `PendingExpiryBars` | 8 | Bars before an unfilled limit order expires |
| `SweepBufferPips` | 2.0 | SL buffer beyond sweep extreme |
| `MinRR` | 2.0 | Minimum risk-to-reward to accept a setup |
| `SweepValidityBars` | 36 | Bars a detected sweep remains actionable |

### Session Logic

| Parameter | Default | Description |
|-----------|---------|-------------|
| `EnableSilverBullet` | true | Allow Silver Bullet model entries |
| `EnableMacros` | true | Allow entries during ICT macro windows |
| `EnableNewsFilter` | true | Halt entries around high-impact news |
| `NewsHaltBeforeMin` | 15 | Minutes before news to halt entries |
| `NewsResumeAfterMin` | 5 | Minutes after news to resume entries |

### Entry Logic

| Parameter | Default | Description |
|-----------|---------|-------------|
| `UseOTE` | true | Distribute entries across OTE Fibonacci pocket |
| `DrawZones` | true | Draw all detected zones on chart |
| `EnableTrailingStop` | true | Enable swing-based trailing stop |
| `BreakEvenBufferPips` | 1.0 | Buffer above entry for break-even move |
| `EnableContinuationModel` | true | Allow continuation setups without sweep trigger |
| `AllowOBOnlyEntries` | true | Accept setups without FVG (OB-only) |
| `ContinuationLookbackBars` | 12 | Bars to look back for a recent BOS/CHoCH |
| `MaxZoneDistancePips` | 20.0 | Max distance from price to valid zone |

### Timeframes

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Timeframe_Bias` | D1 | Primary bias voting timeframe |
| `Timeframe_Swing` | H4 | Swing structure timeframe |
| `Timeframe_Entry` | H1 | Entry confirmation timeframe |
| `Timeframe_Trigger` | M5 | Trigger / bar-loop timeframe |

---

## Installation

> **Full step-by-step guide** with screenshots-equivalent detail is in [instructions.md](instructions.md).

### Quick Start (5 Steps)

1. **Copy files** — Copy all `.mq5`, `.mqh`, and `.set` files into `MQL5\Experts\MARK1\` inside your MT5 data folder.
   (To find it: MT5 → File → Open Data Folder → MQL5 → Experts → create MARK1 folder)

2. **Compile** — Open MetaEditor (F4 in MT5), open `ICT_EURUSD_EA.mq5`, press F7. Expect `0 errors, 0 warnings`.

3. **Load GBPUSD data** — Open a GBPUSD H1 chart in MT5 (File → New Chart → GBPUSD). Wait for history to load. Close the chart.

4. **Attach EA** — Drag `ICT_EURUSD_EA` from Navigator onto a EURUSD M5 chart. Load `MARK1_Funded.set` preset. Click OK.

5. **Enable AutoTrading** — Click the AutoTrading button in the toolbar (must be green).

### Required Files

All 14 files must be in the **same flat folder** — no subfolders:

```
MQL5\Experts\MARK1\
├── ICT_EURUSD_EA.mq5     ← Main EA (compiles to .ex5)
├── ICT_Constants.mqh      ← Magic number, version, pip factor
├── ICT_Structure.mqh      ← Swing detection, BOS/CHoCH/MSS
├── ICT_FVG.mqh            ← FVG, CE, Implied FVG, BPR
├── ICT_Session.mqh        ← Kill zones, Silver Bullet, Judas Swing
├── ICT_Bias.mqh           ← 3-TF consensus, DOW phase
├── ICT_Liquidity.mqh      ← Sweeps, IRL/ERL, IDM, NDOG/NWOG, DOL
├── ICT_OrderBlock.mqh     ← OB, Breaker, Rejection, Propulsion, Vacuum
├── ICT_RiskManager.mqh    ← Lot sizing, TP splits, drawdown guards, CSV log
├── ICT_EntryModels.mqh    ← 6 entry model classes
├── ICT_IPDA.mqh           ← IPDA 20/40/60-bar levels
├── ICT_SMT.mqh            ← SMT divergence (EURUSD vs GBPUSD)
├── ICT_Visualizer.mqh     ← Chart drawing layer
└── MARK1_Funded.set       ← Prop-firm preset
```

### Dependencies

- MetaTrader 5 build 3000+ (for strict MQL5 struct semantics)
- No external DLLs — only `<Trade\Trade.mqh>` from the built-in MT5 standard library

---

## Python Analytics Suite

Four Python scripts in the `Python/` folder provide post-trade analysis and optimization.

### Data Flow

```
EA (ICT_RiskManager.mqh)
  └─ writes MARK1_Trades.csv on each trade close
       └─ ICT_Analytics.py reads it → stats, equity curve, model breakdown

MARK1_Funded.set
  └─ MARK1_Optimizer.py reads/modifies/restores → grid search report

MT5 Terminal (live connection)
  └─ IPDA_Script.py → D1 IPDA levels chart
  └─ SMT_Script.py  → H1 divergence scan
```

### Setup

```bash
cd MARK1
python -m venv .venv
.venv\Scripts\activate
pip install pandas matplotlib        # For analytics
pip install MetaTrader5              # For live MT5 scripts (optional)
```

### Scripts

| Script | What It Does | MT5 Needed? |
|--------|-------------|-------------|
| `Python\ICT_Analytics.py` | Trade stats, win rate, avg RR, equity curve PNG, per-model breakdown | No — reads CSV |
| `Python\MARK1_Optimizer.py` | Grid-search EA params via .set file injection | Optional |
| `Python\IPDA_Script.py` | Computes and charts IPDA 20/40/60 levels from live D1 data | Yes |
| `Python\SMT_Script.py` | Scans EURUSD vs GBPUSD for SMT divergences | Yes |

### Usage

```bash
# After a backtest — analyze trades
python Python\ICT_Analytics.py

# Optimize parameters
python Python\MARK1_Optimizer.py --set MARK1_Funded.set

# Live IPDA levels (requires MT5 running)
python Python\IPDA_Script.py --symbol EURUSD

# Live SMT scan (requires MT5 running)
python Python\SMT_Script.py --verbose
```

See [instructions.md](instructions.md) §11 for detailed usage of each script.

---

## Standards & Conventions

### MQL5 Implementation Rules

- **Magic number**: `MARK1_MAGIC = 20240001` — defined as a `const long` in `ICT_Constants.mqh`. Never use the `MagicNumber` input for internal logic; the constant is always used.
- **Time**: All time comparisons use `TimeGMT()`. Session windows are defined in UTC offsets. No broker-local-time assumptions.
- **Struct vs class pointers**: MQL5 forbids raw pointers to struct instances. All structs are passed and returned by value or const reference. Only class instances (heap-allocated with `new`) use pointer semantics.
- **TP ratios**: `TP1_RATIO = 0.35`, `TP2_RATIO = 0.40`, `TP3_RATIO = 0.25` (sum = 1.0), declared as `static const double` in `ICT_RiskManager.mqh`.
- **Include guard pattern**: Every `.mqh` file uses `#pragma once` to prevent double inclusion.
- **Logging**: All `Print()` calls are guarded by the `DebugLog` input or the `Log()` helper, keeping the Experts log clean in production.

### Enterprise Coding Standards

- Single-responsibility headers — each `.mqh` owns exactly one domain concept.
- All public structs use zero-initialisation via `ZeroMemory()` before use.
- `NormalizeDouble(_Digits)` applied to all price levels before order submission.
- No magic numbers in logic — all thresholds are named constants or EA inputs.
- Functions return `bool` for fallible operations; output is via reference parameters.
- Array parameters use MQL5 reference semantics (`double &arr[]`) to avoid copies.

### Version History

| Version | Notes |
|---------|-------|
| v1.0 | Single-file EA — London sweep + FVG entry, fixed lot |
| v2.0 | Modular split into headers; dynamic lot sizing; kill-zone filter |
| v3.0 | Phase 1–6 — full ICT concept suite, entry models, risk hardening |
| **v4.0** | Phase 7–9 — IPDA engine, SMT divergence, visualizer layer, Python suite; all compile errors resolved |
| **v4.1** | Enhancement session — swing alternation enforcement (H→L→H→L), W1/MN1 structure-based bias, IPDA equilibrium gate + discount/premium confluence, SMT confluence scoring, TurtleSoup IDM direction fix, RiskManager CSV pnlPips/tp2/tp3 fix, Visualizer TimeGMT consistency, W1/MN1 bar-change performance gate |


You are an expert MQL5 developer and quantitative forex strategist. 
Your task is to build a complete, production-grade Expert Advisor for 
MetaTrader 5 from absolute scratch. The EA is named RONIN. Every single 
step — architecture, logic, risk management, testing, and optimization — 
must be completed to the highest professional standard.

Do not use any third-party libraries. Do not use any indicators. 
Pure price action and OHLC data only. No code smells. No plagiarism. 
No copy-paste patterns. Write every function clean, minimal, and purposeful.

══════════════════════════════════════════════
EA IDENTITY
══════════════════════════════════════════════

Name        : RONIN
Version     : 1.0
Symbol      : GBPUSD
Timeframe   : M15
Concept     : London Session Asian Range Breakout + Retest Confirmation
Philosophy  : Wait in silence during Asia. Strike at London open. 
              Confirm the retest before committing. One clean trade per day.

══════════════════════════════════════════════
STRATEGY LOGIC — COMPLETE SPECIFICATION
══════════════════════════════════════════════

PHASE 1 — ASIAN RANGE CAPTURE (00:00 – 07:00 GMT)
- Every trading day, at candle close, scan all M15 candles between 
  00:00 GMT and 07:00 GMT.
- Record:
    AsianHigh = highest high across all M15 candles in that window
    AsianLow  = lowest low across all M15 candles in that window
    AsianRange = AsianHigh - AsianLow (in pips)
- Store these values globally. Reset at the start of each new GMT day.

PHASE 2 — RANGE FILTER
- If AsianRange < MinRangePips (input, default 15 pips): skip the day. 
  Too tight = noise, not a real session range.
- If AsianRange > MaxRangePips (input, default 80 pips): skip the day. 
  Too wide = abnormal event, spread risk.

PHASE 3 — BREAKOUT DETECTION (07:00 – 12:00 GMT only)
- At each M15 candle close after 07:00 GMT:
    BullishBreakout: candle closes ABOVE (AsianHigh + BreakoutBuffer pips)
    BearishBreakout: candle closes BELOW (AsianLow - BreakoutBuffer pips)
  where BreakoutBuffer (input, default 3 pips) prevents shadow fakeouts.
- On first valid breakout candle close, set a flag:
    BreakoutDirection = LONG or SHORT
    BreakoutLevel = AsianHigh or AsianLow accordingly
    BreakoutTime = current candle close time
- Only one breakout direction is tracked per day. First one wins.
- If time passes 12:00 GMT and no breakout has triggered: mark day as 
  NO_TRADE, do nothing.

PHASE 4 — RETEST DETECTION
- After breakout is flagged, begin watching for a retest:
    For LONG: price must return to within RetestZonePips (input, 
    default 8 pips) ABOVE the BreakoutLevel.
    For SHORT: price must return to within RetestZonePips BELOW 
    the BreakoutLevel.
- Retest must happen within RetestTimeoutCandles (input, default 12 
  M15 candles = 3 hours) after breakout candle. If it doesn't, 
  cancel and mark day NO_TRADE.
- Retest must NOT close back inside the Asian range. If price closes 
  back inside the Asian range during retest, it is a false breakout — 
  cancel the day, no trade.

PHASE 5 — REJECTION CANDLE CONFIRMATION
- Once price touches the retest zone, wait for a M15 candle to close 
  with a valid rejection pattern. Evaluate using pure OHLC:

  For LONG (retest of broken Asian High as new support):
    Condition A — Bullish Engulfing:
      current close > current open (bullish body)
      current open <= previous close
      current close >= previous open
    Condition B — Pin Bar / Hammer:
      lower_wick = open - low (if bearish body) or close - low (if bullish)
      body = abs(close - open)
      lower_wick >= 2.0 * body
      close in upper 40% of candle range

  For SHORT (retest of broken Asian Low as new resistance):
    Mirror conditions — Bearish Engulfing or Shooting Star.

  If neither condition is met within the retest zone, wait up to 
  RetestTimeoutCandles. If still no valid pattern, cancel day.

PHASE 6 — ENTRY
- Entry: Market order at the CLOSE of the rejection candle.
  Use OrderSend with ORDER_TYPE_BUY or ORDER_TYPE_SELL.
- No pending orders. Market execution only.
- Entry is in the direction of the original breakout.

PHASE 7 — STOP LOSS
- SL for LONG : BreakoutLevel - SLBufferPips (input, default 12 pips)
  but also check: SL must not be wider than MaxSLPips (input, default 
  25 pips). If it is, skip the trade.
- SL for SHORT: BreakoutLevel + SLBufferPips
- Hard coded SL on every order. No trade without SL ever.

PHASE 8 — TAKE PROFIT
- TP = Entry ± (AsianRange * RRMultiplier)
  where RRMultiplier (input, default 1.8)
- This creates a measured-move TP proportional to the day's range.
- Also set a secondary TP: MaxTPPips (input, default 80 pips). 
  TP is the lesser of measured-move TP and MaxTPPips.

PHASE 9 — TRADE MANAGEMENT (BREAKEVEN + PARTIAL EXIT)
- Breakeven trigger: when price moves BreakevenTriggerPips 
  (input, default 20 pips) in profit, move SL to entry + 1 pip 
  (for LONG) or entry - 1 pip (for SHORT). Do this once per trade.
- Partial close: when price hits 50% of TP distance, close 50% of 
  the position and trail the remaining 50% with a TrailingStopPips 
  (input, default 15 pips) trailing SL.
- Use ModifyOrder / PositionModify for SL adjustments.

PHASE 10 — TIME EXIT
- If the trade is still open at 17:00 GMT, close it at market price. 
  No overnight holding. Use a time-based forced close check on every tick.

══════════════════════════════════════════════
RISK MANAGEMENT — NON-NEGOTIABLE
══════════════════════════════════════════════

POSITION SIZING:
- Risk % per trade: RiskPercent (input, default 1.0%)
- Lot = (AccountBalance * RiskPercent / 100) / (SL_pips * PipValue)
- PipValue must be dynamically calculated for GBPUSD using 
  SymbolInfoDouble(). Never hardcode pip value.
- Lot must be rounded down to nearest lot step using SymbolInfoDouble 
  SYMBOL_VOLUME_STEP.
- Lot must not exceed MaxLot (input, default 1.0) as a safety cap.
- Lot must not be below MinLot (SymbolInfoDouble SYMBOL_VOLUME_MIN).

DAILY LOSS CIRCUIT BREAKER:
- Track DailyPnL = sum of all closed trade profits today.
- If DailyPnL falls below -DailyLossLimitPercent (input, default 2.0%) 
  of balance at day start, stop trading for the rest of that GMT day. 
  No new orders.

MAX DRAWDOWN MONITOR:
- Calculate running drawdown = (PeakEquity - CurrentEquity) / 
  PeakEquity * 100.
- If drawdown exceeds MaxDrawdownPercent (input, default 10%): 
  pause ALL trading until drawdown recovers below HalfOfMaxDrawdown. 
  Log a warning to the Experts tab.

ONE TRADE PER DAY:
- Strict one trade per day maximum. Use a boolean DayTraded flag 
  reset on each new GMT day.

SPREAD FILTER:
- Before entry, check current spread: if spread > MaxSpreadPips 
  (input, default 3 pips for GBPUSD), do not enter. Skip the trade.

══════════════════════════════════════════════
CODE ARCHITECTURE
══════════════════════════════════════════════

STRUCTURE:
- One .mq5 file. No includes from external sources.
- Modular functions. One responsibility per function. No function 
  over 40 lines.
- Use enum for states: 
    enum RONIN_STATE { WAITING_RANGE, WAITING_BREAKOUT, 
                       WAITING_RETEST, WAITING_REJECTION, 
                       IN_TRADE, DAY_DONE }
- Global state machine: RONIN_STATE CurrentState
- All input parameters grouped at the top with clear comments.
- All magic numbers as named constants or inputs. No raw numbers 
  in logic code.

REQUIRED FUNCTIONS (minimum):
  OnInit()           — initialization, validation, symbol checks
  OnTick()           — main state machine router
  OnDeinit()         — cleanup
  CaptureAsianRange()        — Phase 1-2 logic
  DetectBreakout()           — Phase 3 logic
  DetectRetest()             — Phase 4 logic  
  IsRejectionCandle()        — Phase 5 OHLC pattern check, returns bool
  ExecuteEntry()             — Phase 6-8 order execution
  ManageTrade()              — Phase 9 breakeven and partial close
  CheckTimeExit()            — Phase 10 forced close
  CalculateLotSize()         — risk-based lot calculation
  CheckDailyCircuitBreaker() — daily loss limit
  CheckDrawdownBreaker()     — max drawdown monitor
  ResetDailyState()          — reset all daily flags at new GMT day
  GmtHour()                  — helper: return current GMT hour
  GmtMinute()                — helper: return current GMT minute
  PipsToPrice()              — helper: convert pips to price distance
  PriceToPips()              — helper: convert price distance to pips
  IsNewDay()                 — helper: detect new GMT day
  LogStatus()                — print current state to Experts tab

VARIABLE NAMING:
- PascalCase for globals and inputs.
- camelCase for locals inside functions.
- All prices stored as double with sufficient precision.
- All pip values computed, never hardcoded.

ERROR HANDLING:
- Check return value of every OrderSend call. Log error code if failed.
- Check ChartSymbol and Period in OnInit. Warn if wrong symbol/TF.
- If PositionModify fails, log and retry on next tick with a counter 
  (max 3 retries, then give up and log).
- All array accesses bounds-checked.

COMMENTS:
- Every function has a header comment: what it does, inputs, outputs.
- Complex calculations explained inline.
- No dead code. No commented-out blocks.

══════════════════════════════════════════════
BACKTESTING PROTOCOL
══════════════════════════════════════════════

MINIMUM REQUIRED BACKTEST:
- Symbol   : GBPUSD
- Timeframe: M15
- Data     : Every tick based on real ticks (highest quality in MT5 
             Strategy Tester)
- Period   : January 2013 – December 2024 (minimum 11 years)
- Spread   : Use variable spread (real spread simulation)
- Initial deposit: $10,000
- Commission: set to your broker's actual commission per lot

WHAT TO RECORD FROM BACKTEST:
  Net Profit
  Profit Factor (target: > 1.4)
  Win Rate (target: 52–65%)
  Max Drawdown % (target: < 15%)
  Max Drawdown $ amount
  Total Trades (should be 1000+ over 11 years for statistical validity)
  Average trade duration
  Average Win / Average Loss ratio
  Consecutive losses max (tells you risk of ruin)
  Recovery Factor = Net Profit / Max Drawdown (target: > 2.0)
  Sharpe Ratio (target: > 0.5)

Run the 11-year backtest first with DEFAULT settings before any 
optimization to establish the baseline.

WALK-FORWARD VALIDATION:
  Split data into:
    In-Sample   : Jan 2013 – Dec 2019 (7 years) — optimize here
    Out-of-Sample: Jan 2020 – Dec 2024 (5 years) — validate here
  The strategy must be profitable on BOTH segments independently.
  If out-of-sample results are dramatically worse than in-sample, 
  the strategy is overfit. Start over with less aggressive optimization.

══════════════════════════════════════════════
OPTIMIZATION PROTOCOL (after baseline backtest)
══════════════════════════════════════════════

Use MT5 Genetic Optimization. Optimize ONE parameter group at a time.
Never optimize everything simultaneously — that guarantees overfitting.

ROUND 1 — Range Filters:
  MinRangePips     : 10 to 25, step 5
  MaxRangePips     : 60 to 100, step 10
  Optimize for: Profit Factor

ROUND 2 — Breakout / Retest Parameters:
  BreakoutBuffer   : 2 to 8, step 1
  RetestZonePips   : 5 to 15, step 2
  RetestTimeoutCandles: 8 to 16, step 2
  SLBufferPips     : 8 to 18, step 2
  Optimize for: Recovery Factor

ROUND 3 — Risk/Reward:
  RRMultiplier     : 1.2 to 2.5, step 0.1
  BreakevenTriggerPips: 15 to 30, step 5
  TrailingStopPips : 10 to 25, step 5
  Optimize for: Net Profit with Drawdown < 15% constraint

OPTIMIZATION RULES:
- Reject any parameter set that has fewer than 800 trades over 7 years.
- Reject any parameter set where Max Drawdown > 20%.
- Reject any parameter set where Profit Factor < 1.3.
- From the passing sets, pick the one with the highest Recovery Factor,
  not the highest net profit. Chasing highest profit = overfitting.
- After selecting best params, re-run full 11-year backtest to confirm.

ROBUSTNESS CHECKS (run these after optimization):
1. Spread stress test: increase MaxSpreadPips to 5. Run full backtest. 
   Strategy must remain profitable.
2. Slippage test: add 2 pip slippage simulation. Must remain profitable.
3. Seasonal test: break results by year. At least 8 of 11 years must 
   be profitable individually.
4. Parameter sensitivity test: shift each optimized parameter ±1 step.
   Results must not collapse. Gradual degradation = robust. 
   Cliff-edge = overfit.

══════════════════════════════════════════════
ALL-WEATHER CONDITIONS HANDLING
══════════════════════════════════════════════

The EA must handle all of these correctly without blowing the account:

TRENDING MARKET:
  The retest confirmation naturally catches continuation moves in 
  trending conditions. RR multiplier of 1.8 should capture large 
  trend day moves. No special handling needed.

RANGING MARKET:
  The MinRangePips and MaxRangePips filters prevent trading on 
  abnormally tight or wide days. The MaxTPPips cap prevents 
  setting unrealistic targets in a ranging environment.

HIGH VOLATILITY / NEWS DAYS:
  MaxRangePips filter will exclude most news-spike days where the 
  Asian range was already blown out.
  Spread filter prevents entry if spread has spiked (as it does 
  during news).
  As an optional enhancement: add a NewsFilter boolean input 
  (default false) — when true, fetch the economic calendar events 
  for the day (use iCustom or manual time inputs) and skip trading 
  if a GBP or USD red-folder news event falls within 60 minutes of 
  the planned entry window.

LOW VOLATILITY MARKETS:
  MinRangePips filter handles this. Dead market days are skipped.

GAPS (Sunday opens):
  In IsNewDay() check: if today is Monday and the gap between 
  Friday close and current price > GapFilterPips (input, default 30),
  skip the day.

══════════════════════════════════════════════
FINAL DELIVERABLES
══════════════════════════════════════════════

Produce in this exact sequence:

1. RONIN.mq5 — complete compilable EA source code
   - Must compile in MT5 with zero errors, zero warnings.
   - Must pass MT5 MetaEditor's syntax check.

2. RONIN_DefaultBacktest.txt — Strategy Tester report
   - Full 11-year backtest with default settings.
   - All metrics listed above recorded.

3. RONIN_OptimizationReport.txt — Optimization results
   - Best parameter set per each optimization round.
   - Final selected parameter set with justification.

4. RONIN_RobustnessChecks.txt
   - Results of all 4 robustness checks.
   - Pass/fail per check.

5. RONIN_FinalParams.set
   - MT5-compatible .set file with the final optimized parameters.

6. RONIN_README.txt
   - Setup instructions: symbol, timeframe, broker requirements.
   - VPS recommendation.
   - What each input parameter does.
   - Known limitations.
   - Conditions under which the EA should be paused manually 
     (e.g., central bank week, extreme geopolitical events).

══════════════════════════════════════════════
QUALITY CHECKLIST — VERIFY EVERY ITEM BEFORE DELIVERY
══════════════════════════════════════════════

[ ] No martingale. No grid. No averaging down. Ever.
[ ] Every trade has a hard SL set at order submission.
[ ] Position size is risk-percent based, never fixed lot.
[ ] Daily loss limit enforced.
[ ] Max drawdown circuit breaker enforced.
[ ] One trade per day maximum.
[ ] Spread filter on entry.
[ ] No overnight holds (17:00 GMT time exit).
[ ] No magic numbers in code body — all as named constants or inputs.
[ ] Every OrderSend return value checked.
[ ] Every function has a single clear responsibility.
[ ] Code compiles clean — zero warnings in MetaEditor.
[ ] 11+ years backtest completed on real tick data.
[ ] Walk-forward validation passed (2013-2019 in-sample, 
    2020-2024 out-of-sample).
[ ] Minimum 4 robustness checks passed.
[ ] Final .set file produced.
[ ] README complete.

══════════════════════════════════════════════
BEGIN EXECUTION
══════════════════════════════════════════════

Start with RONIN.mq5. 
Write the full source code first, section by section, 
without skipping any function. 
Do not summarize or placeholder any function with a comment 
like "// implement later". Every function must be complete and 
working in the first pass.
After the full code is written, proceed to the backtesting 
protocol, optimization, and then the remaining deliverables.
