# MARK1 — MetaTrader 5 Setup, Compilation & Run Instructions

> Complete step-by-step guide: install MetaEditor, copy all required files, compile the EA, load it onto a live chart, and run a backtest.

---

## Table of Contents

1. [Prerequisites & Required Software](#1-prerequisites--required-software)
2. [Required Files & Their Roles](#2-required-files--their-roles)
3. [MQL5 Internal Dependencies](#3-mql5-internal-dependencies)
4. [Step-by-Step: Copy Files to MT5](#4-step-by-step-copy-files-to-mt5)
5. [Step-by-Step: Compile in MetaEditor](#5-step-by-step-compile-in-metaeditor)
6. [Step-by-Step: Load GBPUSD Data (Required)](#6-step-by-step-load-gbpusd-data-required)
7. [Step-by-Step: Attach EA to a Live Chart](#7-step-by-step-attach-ea-to-a-live-chart)
8. [Step-by-Step: Configure EA Inputs](#8-step-by-step-configure-ea-inputs)
9. [Step-by-Step: Verify the EA is Trading](#9-step-by-step-verify-the-ea-is-trading)
10. [Step-by-Step: Backtest in Strategy Tester](#10-step-by-step-backtest-in-strategy-tester)
11. [Python Analytics Suite (Optional)](#11-python-analytics-suite-optional)
12. [Troubleshooting](#12-troubleshooting)
13. [Important Constants — Do Not Change](#13-important-constants--do-not-change)

---

## 1. Prerequisites & Required Software

Install all of the following before proceeding:

| Software | Version | Where to Get It | Notes |
|----------|---------|-----------------|-------|
| **MetaTrader 5** | Build 3000+ | Your broker's download page | Includes MetaEditor — no separate download |
| **Broker Account** | Any | Your prop firm or retail broker | Must support EUR/USD with ECN/STP execution |
| **Python** *(optional)* | 3.11+ | python.org | Only needed for the `Python/` analytics scripts |

> MetaEditor is bundled with MetaTrader 5. You do **not** need to install it separately. It opens with **F4** from inside MT5.

---

## 2. Required Files & Their Roles

All of the following files must be present together in **one folder**. No file can be missing — the EA will fail to compile if any header is absent.

### MQL5 Source Files (Mandatory)

| File | Type | Role |
|------|------|------|
| `ICT_EURUSD_EA.mq5` | EA entry point | `OnInit`, `OnTick`, `OnTradeTransaction` — the main executable |
| `ICT_Constants.mqh` | Header | Magic number, version string, pip factor, TP ratios |
| `ICT_Structure.mqh` | Header | Swing-high/low detection, BOS/CHoCH/MSS classification |
| `ICT_FVG.mqh` | Header | Fair Value Gap, Consequent Encroachment, Implied FVG, BPR |
| `ICT_Session.mqh` | Header | Kill zones, Silver Bullet windows, Asian range, Judas Swing, London Close |
| `ICT_Bias.mqh` | Header | 3-TF consensus bias, DOW phase, PDA zone classification |
| `ICT_Liquidity.mqh` | Header | Sweep detection, IRL/ERL, IDM, NDOG/NWOG, Run-on-Stops, DOL selector |
| `ICT_OrderBlock.mqh` | Header | Order Block, Breaker, Mitigation, Rejection, Propulsion, Vacuum blocks |
| `ICT_RiskManager.mqh` | Header | Position sizing, TP splits, drawdown guards, spread filter, CSV logger |
| `ICT_EntryModels.mqh` | Header | All 6 ICT entry model classes (Silver Bullet, Judas Swing, MM, TS, LC, TGIF) |
| `ICT_IPDA.mqh` | Header | IPDA 20/40/60-bar draw-on-liquidity engine |
| `ICT_SMT.mqh` | Header | SMT divergence scanner (EURUSD vs GBPUSD) |
| `ICT_Visualizer.mqh` | Header | Chart objects: zones, lines, labels, markers |

### Configuration File (Recommended)

| File | Role |
|------|------|
| `MARK1_Funded.set` | Pre-filled input preset for prop-firm/funded accounts |

### Python Scripts (Optional)

| File | Role |
|------|------|
| `Python\ICT_Analytics.py` | Trade statistics from `MARK1_Trades.csv` |
| `Python\MARK1_Optimizer.py` | Parameter grid-search optimizer |
| `Python\IPDA_Script.py` | IPDA level viewer |
| `Python\SMT_Script.py` | SMT divergence visualizer |

---

## 3. MQL5 Internal Dependencies

The EA's `#include` chain is:

```
ICT_EURUSD_EA.mq5
├── <Trade\Trade.mqh>          ← MetaTrader 5 standard library (built-in, always available)
├── ICT_Constants.mqh
├── ICT_Structure.mqh
│   └── ICT_Constants.mqh
├── ICT_Session.mqh
│   └── ICT_Constants.mqh
├── ICT_Liquidity.mqh
│   └── ICT_Constants.mqh
├── ICT_OrderBlock.mqh
│   ├── ICT_Constants.mqh
│   └── ICT_Structure.mqh
├── ICT_FVG.mqh
│   └── ICT_Constants.mqh
├── ICT_Bias.mqh
│   ├── ICT_Constants.mqh
│   ├── ICT_Structure.mqh
│   └── ICT_Session.mqh
├── ICT_RiskManager.mqh
│   ├── <Trade\Trade.mqh>
│   ├── ICT_Constants.mqh
│   ├── ICT_Structure.mqh
│   └── ICT_Bias.mqh
├── ICT_Visualizer.mqh
│   ├── ICT_Session.mqh
│   ├── ICT_Liquidity.mqh
│   ├── ICT_OrderBlock.mqh
│   ├── ICT_FVG.mqh
│   ├── ICT_Bias.mqh
│   ├── ICT_IPDA.mqh
│   └── ICT_SMT.mqh
├── ICT_EntryModels.mqh
│   ├── ICT_Constants.mqh
│   ├── ICT_Structure.mqh
│   ├── ICT_Session.mqh
│   ├── ICT_Liquidity.mqh
│   ├── ICT_FVG.mqh
│   ├── ICT_OrderBlock.mqh
│   └── ICT_Bias.mqh
├── ICT_IPDA.mqh
│   └── ICT_Constants.mqh
└── ICT_SMT.mqh
    └── ICT_Constants.mqh
```

**Key points:**
- `<Trade\Trade.mqh>` is part of the MT5 standard library and is always available — no action needed.
- All other `.mqh` files must be in the **same folder** as `ICT_EURUSD_EA.mq5`.
- Every file uses `#pragma once` to prevent double-inclusion errors.
- There are **no circular dependencies** and **no external DLLs** required.

---

## 4. Step-by-Step: Copy Files to MT5

### 4.1 — Find your MT5 Data Folder

1. Open **MetaTrader 5**.
2. In the top menu click **File → Open Data Folder**.
3. A Windows Explorer window opens at the MT5 data root, e.g.:
   ```
   C:\Users\YourName\AppData\Roaming\MetaQuotes\Terminal\<hash>\
   ```

### 4.2 — Create the MARK1 folder

Inside the data folder, navigate to:
```
MQL5\Experts\
```
Create a new subfolder named `MARK1`:
```
MQL5\Experts\MARK1\
```

### 4.3 — Copy all MQL5 files

Copy every file listed in §2 into `MQL5\Experts\MARK1\`. Do **not** create sub-folders — all 14 files must sit flat in the same directory:

```
MQL5\Experts\MARK1\
│
├── ICT_EURUSD_EA.mq5        ← the EA (compiled to .ex5)
├── ICT_Constants.mqh
├── ICT_Structure.mqh
├── ICT_FVG.mqh
├── ICT_Session.mqh
├── ICT_Bias.mqh
├── ICT_Liquidity.mqh
├── ICT_OrderBlock.mqh
├── ICT_RiskManager.mqh
├── ICT_EntryModels.mqh
├── ICT_IPDA.mqh
├── ICT_SMT.mqh
├── ICT_Visualizer.mqh
└── MARK1_Funded.set
```

---

## 5. Step-by-Step: Compile in MetaEditor

### 5.1 — Open MetaEditor

Press **F4** inside MetaTrader 5, **or** use the menu: **Tools → MetaQuotes Language Editor**.

MetaEditor opens as a separate window.

### 5.2 — Open the EA source file

In MetaEditor's left-hand **Navigator** panel:

```
Navigator → Expert Advisors → MARK1 → ICT_EURUSD_EA.mq5
```

Double-click `ICT_EURUSD_EA.mq5` to open it in the editor.

> If the `MARK1` folder does not appear, click the **Refresh** button (circular arrow) at the top of the Navigator panel.

### 5.3 — Compile

Press **F7**, or click the green **Compile** toolbar button (▶).

MetaEditor will:
1. Parse `ICT_EURUSD_EA.mq5`
2. Automatically resolve and compile all 12 `.mqh` headers in the same folder
3. Produce a compiled binary: `ICT_EURUSD_EA.ex5`

### 5.4 — Check the result

Look at the **Errors** panel at the bottom of MetaEditor (the tab row shows Errors / Warnings / Find Results):

| Result | Meaning |
|--------|---------|
| `0 error(s), 0 warning(s)` | ✅ Success — ready to use |
| Any errors listed | ❌ See §5.5 below |

### 5.5 — Common compile errors and fixes

| Error Message | Cause | Fix |
|---------------|-------|-----|
| `'ICT_Constants.mqh' - file not found` | A `.mqh` file is missing or in the wrong folder | Confirm all 13 files are in `MQL5\Experts\MARK1\` |
| `'SIPDARange' - undeclared identifier` | `ICT_IPDA.mqh` not in the same folder | Copy `ICT_IPDA.mqh` into the `MARK1\` folder |
| `'Trade' - undeclared identifier` | MT5 standard library `<Trade\Trade.mqh>` not found | Reinstall MetaTrader 5 — this file is always built in |
| Warning: `'variable' is never used` | Minor — does not block execution | Safe to ignore |

### 5.6 — Verify the compiled binary exists

After a successful compile, the file `ICT_EURUSD_EA.ex5` is automatically created in:
```
MQL5\Experts\MARK1\ICT_EURUSD_EA.ex5
```
You should see this file in Windows Explorer. This is the actual binary that MetaTrader 5 runs.

---

## 6. Step-by-Step: Load GBPUSD Data (Required)

The SMT divergence engine compares EURUSD against GBPUSD in real time. MT5 must have GBPUSD price history cached before the EA can use it.

1. In MetaTrader 5, go to **File → New Chart**.
2. Select **GBPUSD** and click **Open**.
3. Set the chart to **H1** timeframe and wait for the candles to load (a progress bar may briefly appear in the bottom of MT5).
4. Optionally scroll back to verify at least 6 months of history has loaded.
5. You can now close the GBPUSD chart — MT5 will have cached the data.

> **If you skip this step:** The `CSMTEngine::Scan()` call will silently return no divergence on every tick. The EA will still trade, but SMT signals will never fire.

---

## 7. Step-by-Step: Attach EA to a Live Chart

1. In MetaTrader 5, open a **EURUSD** chart:
   - Menu: **File → New Chart → EURUSD**
   - Or right-click in the Market Watch panel → **Chart Window**

2. Set the timeframe to **M5** by clicking the `M5` button in the toolbar.

3. Enable automated trading — the **AutoTrading** button in the toolbar must be **green**. Click it if it is grey/red.

4. Open the **Navigator** panel: **View → Navigator** or press **Ctrl+N**.

5. In Navigator, expand: **Expert Advisors → MARK1**

6. **Drag** `ICT_EURUSD_EA` from the Navigator onto the EURUSD M5 chart.

7. The **EA Inputs dialog** opens. Proceed to §8.

---

## 8. Step-by-Step: Configure EA Inputs

### 8.1 — Load the funded account preset

In the EA Inputs dialog:

1. Click **Load** (bottom-left of the dialog).
2. Navigate to `MQL5\Experts\MARK1\` and select `MARK1_Funded.set`.
3. Click **Open** — all fields auto-fill.
4. Click **OK**.

### 8.2 — All available input parameters

| Group | Parameter | Default | Range | Description |
|-------|-----------|---------|-------|-------------|
| **Core Risk** | `RiskPercent` | 0.50 | 0.05–2.0 | % of balance risked per trade |
| | `MaxTrades` | 2 | 1–3 | Max simultaneous positions + pending orders |
| | `DailyMaxLoss` | 3.0 | 0.25–5.0 | Daily equity loss limit (%) — all pending cancelled on breach |
| | `WeeklyMaxDD` | 6.0 | 0.25–8.0 | Weekly drawdown cap (%) |
| | `MaxSpreadPips` | 3.0 | — | Block new entries when spread exceeds this value |
| | `MaxConsecLosses` | 3 | — | Halt new entries after N consecutive losing trades |
| **ICT Detection** | `OB_Lookback` | 10 | 1–20 | Bars to scan for Order Blocks |
| | `FVG_MinGap` | 10 | 1–20 | Minimum FVG size in points |
| | `SwingStrength` | 3 | 1–5 | Bars each side to confirm a swing point |
| | `MinConfluence` | 2 | 1–4 | Minimum zone-confluence score to place a trade |
| | `EqualTolerancePips` | 5.0 | 0.5–8.0 | Tolerance for equal highs/lows |
| | `MinSweepPips` | 2.0 | 0.25–5.0 | Minimum sweep extension to qualify |
| | `PendingExpiryBars` | 8 | 1–20 | Bars before unfilled limit order is cancelled |
| | `SweepBufferPips` | 2.0 | 0.5–5.0 | Stop-loss buffer beyond the sweep wick |
| | `MinRR` | 2.0 | 0.25–4.0 | Minimum risk-to-reward ratio required |
| | `SweepValidityBars` | 36 | 6–72 | How many bars a detected sweep remains active |
| **Session Logic** | `EnableSilverBullet` | true | — | Enable Silver Bullet window entries |
| | `EnableMacros` | true | — | Enable ICT macro-window entries |
| | `EnableNewsFilter` | true | — | Halt entries around high-impact USD/EUR news |
| | `NewsHaltBeforeMin` | 15 | 5–45 | Minutes before news to halt |
| | `NewsResumeAfterMin` | 5 | 5–20 | Minutes after news to resume |
| **Entry Logic** | `UseOTE` | true | — | Distribute entries across OTE Fibonacci pocket |
| | `DrawZones` | true | — | Draw detected zones on chart |
| | `EnableTrailingStop` | true | — | Enable swing-based trailing stop |
| | `BreakEvenBufferPips` | 1.0 | 0.25–3.0 | Buffer above entry for break-even SL move |
| | `EnableContinuationModel` | true | — | Allow continuation setups without a sweep trigger |
| | `AllowOBOnlyEntries` | true | — | Allow entries with OB but no FVG |
| | `ContinuationLookbackBars` | 12 | 1–24 | Bars back to look for a recent BOS/CHoCH |
| | `MaxZoneDistancePips` | 20.0 | 1–40 | Maximum distance from price to a valid zone |
| **Timeframes** | `Timeframe_Bias` | D1 | — | Bias voting primary timeframe |
| | `Timeframe_Swing` | H4 | — | Swing structure timeframe |
| | `Timeframe_Entry` | H1 | — | Entry confirmation timeframe |
| | `Timeframe_Trigger` | M5 | — | Trigger / bar-loop timeframe |
| **Debug** | `DebugLog` | false | — | Print verbose diagnostics to the Experts tab |

---

## 9. Step-by-Step: Verify the EA is Trading

After attaching:

### Check 1 — Smiley face icon
A **smiley face** (☺) in the **top-right corner** of the EURUSD chart means the EA compiled and initialised successfully. A sad face (☹) means an error occurred in `OnInit()`.

### Check 2 — Experts tab
Open the Terminal panel: **View → Terminal** or **Ctrl+T**, then click the **Experts** tab.

You should see initialisation messages such as:
```
2026.04.24 10:00:01   ICT_EURUSD_EA (EURUSD,M5): [ICT_EURUSD_EA] ...
```

With `DebugLog = true` you will also see per-tick log lines like:
```
[MARK1][RISK] Spread too high: 3.2 pips. Max: 3.0
[MARK1][GATE][SB] IDM not found -- setup rejected
[MARK1][SB] Silver Bullet setup: LONG entry=1.08420 SL=1.08370 TP3=1.08620
[MARK1][EA][SilverBullet] ticket=12345 entry=1.08420 SL=1.08370
```

### Check 3 — AutoTrading is on
The **AutoTrading** toolbar button must be **green**. If it turns grey or red (e.g., after an internet drop), click it to re-enable.

### Check 4 — Journal tab (startup errors)
Click the **Journal** tab in the Terminal panel. Any MT5 system-level errors (e.g., invalid account, disconnected) appear here.

### What to expect during live trading
- The EA scans for setups on every **new M5 bar** (not every tick).
- IPDA levels update once per **new D1 bar** and are used as a trade gate (equilibrium rejection) and confluence factor.
- SMT divergence updates once per **new H1 bar** and is scored as a confluence factor (aligned +1, opposing −1).
- Weekly/monthly bias updates once per **new W1/MN1 bar** using structure-based analysis (HH+HL / LH+LL), not single-candle direction.
- Trades are placed as **limit orders** at FVG / OB levels. You will see them in the **Trade** tab of the Terminal as pending orders.
- When a limit order fills, it becomes an open position. Break-even and partial TP management happen automatically.
- All closed trades are logged to `MQL5\Files\MARK1_Trades.csv`.

---

## 10. Step-by-Step: Backtest in Strategy Tester

Always run a backtest before trading live funds.

1. Press **Ctrl+R** to open the Strategy Tester.

2. Configure the tester as follows:

   | Setting | Recommended Value | Notes |
   |---------|------------------|-------|
   | **Expert** | `MARK1\ICT_EURUSD_EA` | Select from the dropdown |
   | **Symbol** | `EURUSD` | Must match the EA's tuning |
   | **Timeframe** | `M5` | Matches `Timeframe_Trigger` default |
   | **Date** | e.g. `2024.01.01` to `2025.12.31` | At least 1 full year |
   | **Forward** | No forward period for initial testing | |
   | **Model** | **Every tick based on real ticks** | Most accurate for limit orders |
   | **Deposit** | Match your live account size | |
   | **Leverage** | Match your broker | |
   | **Optimization** | Off (for a single run) | |

3. Click the **Inputs** tab, then **Load** → select `MARK1_Funded.set`.

4. Click **Start**.

5. After completion, review:

   | Tab | What to Check |
   |-----|--------------|
   | **Results** | Individual trades — verify TPs/SLs look correct |
   | **Graph** | Equity curve — should be smooth, not spiking |
   | **Report** | Profit factor, max DD, total trades |
   | **Journal** | No `[ERROR]` lines; `[MARK1][GATE]` lines are normal |

6. The file `MQL5\Files\MARK1_Trades.csv` is written during the backtest and can be analysed with `Python\ICT_Analytics.py`.

---

## 11. Python Analytics Suite (Optional)

The Python suite reads data produced by the EA and generates statistics, charts, and optimization reports. It does **not** need to run while the EA is live — you use it after backtests or at end-of-day.

### 11.1 — Prerequisites

- Python 3.11+ installed ([python.org](https://python.org))
- Create a virtual environment (recommended):

```bash
cd "C:\Work\Automation Tools\New folder\MARK1"
python -m venv .venv
.venv\Scripts\activate
pip install pandas matplotlib
```

For live MT5 data scripts (IPDA_Script, SMT_Script, Optimizer), also install:
```bash
pip install MetaTrader5
```

### 11.2 — Data Flow: EA → CSV → Python

```
MetaTrader 5                          Python
─────────────────────────────────────────────────────
ICT_RiskManager.mqh                   ICT_Analytics.py
   │                                     ▲
   │ On each trade close:                │
   │ LogTradeToCSV(rec)                  │ pd.read_csv()
   │    ▼                                │
   └─ MQL5\Files\MARK1_Trades.csv ──────┘
       (20 columns, header row)

MARK1_Funded.set ◄───────────────────── MARK1_Optimizer.py
   (read/modify/restore)                (grid search)
```

**CSV Columns** (written by EA, read by Python):
`id, openTime, closeTime, type, entry, sl, tp1, tp2, tp3, closePrice, lots, pnlPips, profit, model, bias, dowPhase, session, idmSwept, fvgType, obType`

### 11.3 — Finding the CSV File

MT5 writes `MARK1_Trades.csv` to its `Files` directory:
```
C:\Users\<YOU>\AppData\Roaming\MetaQuotes\Terminal\<hash>\MQL5\Files\MARK1_Trades.csv
```
To find it: in MT5, click **File → Open Data Folder**, then navigate to `MQL5\Files\`.

Copy this file to the MARK1 root folder, **or** pass it as an argument:
```bash
python Python\ICT_Analytics.py "C:\path\to\MQL5\Files\MARK1_Trades.csv"
```

### 11.4 — Script Reference

| Script | Purpose | Requires MT5 Running? | Command |
|--------|---------|-----------------------|---------|
| `ICT_Analytics.py` | Win rate, RR, equity curve, per-model stats | No — reads CSV | `python Python\ICT_Analytics.py` |
| `MARK1_Optimizer.py` | Grid-search EA parameters via .set injection | Optional — stubs if no MT5 | `python Python\MARK1_Optimizer.py` |
| `IPDA_Script.py` | Live IPDA 20/40/60-bar levels chart | Yes — pulls D1 data | `python Python\IPDA_Script.py` |
| `SMT_Script.py` | Live EURUSD vs GBPUSD divergence scan | Yes — pulls H1 data | `python Python\SMT_Script.py` |

### 11.5 — ICT_Analytics.py (Trade Analysis)

After a backtest or live trading session:

```bash
python Python\ICT_Analytics.py
```

**Output:**
- Console: total trades, win rate %, avg RR, net P&L, per-model breakdown
- `MARK1_EquityCurve.png` — cumulative equity chart
- `MARK1_ModelWinRate.png` — bar chart of win rate per entry model

The script auto-computes **RR** (risk-reward) from `pnlPips / abs(entry - sl)` in pip units. No `rr` column is needed in the CSV.

### 11.6 — MARK1_Optimizer.py (Parameter Optimization)

```bash
python Python\MARK1_Optimizer.py --set MARK1_Funded.set --report MARK1_OptReport.csv
```

The optimizer:
1. Reads `MARK1_Funded.set` (auto-detects ANSI or UTF-16 encoding)
2. Generates all combinations of the active parameter grid
3. Injects each combination into the `.set` file
4. Runs the Strategy Tester (requires MT5 terminal running)
5. Restores the original `.set` file values
6. Writes results to `MARK1_OptReport.csv`

Default search grid: `RiskPercent × MaxSpreadPips × MinRR` (48 combinations).
Edit `ACTIVE_PARAMS` and `PARAM_GRID` at the top of the script to customise.

### 11.7 — IPDA_Script.py (IPDA Levels)

```bash
python Python\IPDA_Script.py --symbol EURUSD --out IPDA_Levels.png
```

Requires MT5 running. Pulls 200 D1 bars, computes and displays the 20/40/60-bar high-low-equilibrium levels as horizontal lines overlaid on D1 close prices.

### 11.8 — SMT_Script.py (Divergence Scanner)

```bash
python Python\SMT_Script.py --primary EURUSD --correlated GBPUSD --bars 200 --verbose
```

Requires MT5 running. Scans H1 bars for:
- **Bullish SMT**: EURUSD lower low + GBPUSD does NOT confirm → potential long
- **Bearish SMT**: EURUSD higher high + GBPUSD does NOT confirm → potential short

Outputs a dual-panel chart with divergence markers and a summary table.

---

## 12. Troubleshooting

| Symptom | Most Likely Cause | Fix |
|---------|------------------|-----|
| Sad face on chart after attach | `OnInit` error — often a bad parameter value | Open Experts tab; look for `[MARK1][ERROR]` or MT5 error code |
| Compile error: file not found | Missing `.mqh` file | Confirm all 13 source files are in the same `MARK1\` folder |
| No trades placed (journal is clean) | Spread filter, daily loss cap, or no valid setup | Check Experts tab; set `DebugLog=true`; verify AutoTrading is green |
| Spread filter fires constantly | Broker spread > 3 pips on EURUSD | Trade during London or NY sessions; increase `MaxSpreadPips` slightly |
| SMT marker never appears | GBPUSD history not loaded | Open a GBPUSD H1 chart and wait for history to download |
| Consecutive loss breaker active | 3 losses in a row | Resets automatically at midnight GMT; or restart EA |
| CSV not created | No trades closed yet | Run a backtest with at least one closed trade |
| EA stops after internet drop | AutoTrading button toggled off by MT5 | Click the AutoTrading button to re-enable (it turns green again) |
| `[MARK1][GATE] IDM not found` | Normal — no inducement level has formed | Not an error; EA is correctly filtering setups |
| `[MARK1][GATE] IRL->IRL rejected` | Entry and target are both inside the H4 range | Normal; EA prevents low-quality IRL-to-IRL trades |

---

## 13. Important Constants — Do Not Change

| Constant | Value | Location |
|----------|-------|----------|
| `MARK1_MAGIC` | `20240001` | `ICT_Constants.mqh` |
| `MARK1_VERSION` | `"4.0"` | `ICT_Constants.mqh` |
| Time reference | `TimeGMT()` | All files |

> **Warning:** Never change `MARK1_MAGIC`. Changing it causes the EA to lose track of all its open positions and pending orders on the next restart.
