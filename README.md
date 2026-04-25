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
