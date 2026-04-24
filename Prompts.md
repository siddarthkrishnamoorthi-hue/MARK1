# MARK1 — Complete ICT EA: Phased Coding Agent Prompts
**Repo:** `https://github.com/siddarthkrishnamoorthi-hue/MARK1` (branch: `main`)  
**Language:** MQL5 (`.mqh` / `.mq5`) + Python 3.11+  
**Total scope:** 9 bugs · 41 missing items · 4 partial completions → 99 items to 100%  
**Coding standard:** Enterprise/institutional — no magic literals, `const`-correct, explicit type casting, `#pragma once` guards, Doxygen-style `///` comments on every public method, `ENUM_` prefix on all enumerations, `I` prefix on all interface-style structs, `C` prefix on all classes, single-responsibility per file.

---

## GLOBAL RULES FOR ALL PHASES

Apply these constraints to every file touched in every phase:

1. **Never break existing compile** — every phase must produce a zero-error, zero-warning compile in MetaEditor 5.
2. **File header** — every `.mqh` file must begin with:
   ```mql5
   //+------------------------------------------------------------------+
   //| <Filename>.mqh                                                   |
   //| MARK1 ICT Expert Advisor — <module description>                  |
   //| Copyright 2024-2025, MARK1 Project                               |
   //+------------------------------------------------------------------+
   #pragma once
   ```
3. **Magic number** — `MARK1_MAGIC` is a single `#define` constant declared once in `ICT_Constants.mqh` and `#include`d everywhere. Never recompute it.
4. **GMT offset** — All time comparisons use `TimeGMT()`, never `TimeCurrent()` alone unless explicitly noted.
5. **Error handling** — every `OrderSend()` / `PositionModify()` result must be checked; log errors with `Print("[MARK1][ERROR]", ...)`.
6. **No hardcoded strings** — all label names for chart objects must be built from `MARK1_MAGIC` + timestamp to prevent collision.
7. **Python bridge** — Python tools communicate with MT5 via the `MetaTrader5` Python package (`import MetaTrader5 as mt5`). No DLL bridge is required; use the official MT5 Python API.

---

## PHASE 1 — CRITICAL BUG FIXES
**Objective:** Fix all 9 confirmed bugs before any new code is added. This phase does not add new features.  
**Files to modify:** `ICT_Structure.mqh`, `ICT_FVG.mqh`, `ICT_Session.mqh`, `ICT_Bias.mqh`, `ICT_RiskManager.mqh`, `ICT_EURUSD_EA.mq5`, `ICT_Constants.mqh` (create if missing).

---

### BUG 1 — `IsSwingHigh` Strict Equality [Item #4 — ICT_Structure.mqh]

**Problem:** The right-side confirmation check uses `<` operator. This rejects equal highs, causing valid swing highs to be missed when adjacent candles share the same high price.

**Fix:**
Locate the `IsSwingHigh()` function. Find the line performing the right-side comparison. Change every occurrence of:
```mql5
bars[i].high < bars[i + k].high   // WRONG — rejects equal highs
```
to:
```mql5
bars[i].high <= bars[i + k].high  // CORRECT — equal highs pass
```
Apply the same fix symmetrically to `IsSwingLow()` — the left-side and right-side checks must both use `<=` for lows (i.e., `bars[i].low >= bars[i + k].low` becomes `bars[i].low >= bars[i - k].low` with `>=`).

**Verification:** After fix, a 3-bar sequence `[1.1000, 1.1005, 1.1005]` must classify bar index 1 as a swing high.

---

### BUG 2 — FVG Consequent Encroachment (CE) [Item #12 — ICT_FVG.mqh]

**Problem:** `consequentEncroachment` is computed as the midpoint of the gap (gap_high + gap_low) / 2. True ICT CE is the 50% level of the **center candle's body** (open + close of candle[i]), not the gap midpoint.

**Fix:**
Locate `RefreshZoneState()` or wherever `consequentEncroachment` is assigned. Replace:
```mql5
// WRONG
zone.consequentEncroachment = (zone.gapHigh + zone.gapLow) / 2.0;
```
with:
```mql5
// CORRECT — 50% of center candle body (candle index 1 in the 3-candle formation)
zone.consequentEncroachment = (zone.centerCandleOpen + zone.centerCandleClose) / 2.0;
```
The `FVGZone` struct (or equivalent) must store `centerCandleOpen` and `centerCandleClose` populated at detection time. Add these two fields to the struct if not present:
```mql5
double centerCandleOpen;   ///< Open of center candle (candle[1] in FVG detection)
double centerCandleClose;  ///< Close of center candle
```
Populate them in `DetectFVG()` at the point where the FVG is first registered.

---

### BUG 3 — EUR News Filter [Item #40 — ICT_Session.mqh]

**Problem:** The EUR currency check in the news filter never fires due to an incorrect string comparison or wrong variable reference.

**Fix:**
Locate the news filter loop that queries `MqlCalendarValue`. Find the currency check block. The comparison for EUR likely reads:
```mql5
if(event.currency == "USD")  // Only USD is checked; EUR branch is broken
```
or there is an `&&` where there should be `||`, or the EUR string literal is misspelled. Apply:
```mql5
if(event.currency == "USD" || event.currency == "EUR")
{
    isNewsTime = true;
    break;
}
```
Ensure the `CalendarValueHistory()` or `CalendarValueSelect()` call is called **twice** — once with `"USD"` and once with `"EUR"` — or that a single call uses the correct filter. Log `"[MARK1][NEWS] EUR filter active"` when EUR event blocks trading.

---

### BUG 4 — HTF Consensus Ignores H1 [Item #49 — ICT_Bias.mqh]

**Problem:** `ResolveDailyBias()` or the HTF consensus function computes consensus from H4 + Daily only, discarding the already-computed `directionBias` from H1.

**Fix:**
Locate the HTF consensus logic. Change the scoring/voting to include all three timeframes:
```mql5
// CORRECT — 3-TF consensus: Daily + H4 + H1
int bullVotes = 0, bearVotes = 0;
if(dailyBias == BIAS_BULLISH)   bullVotes++;  else bearVotes++;
if(h4Bias    == BIAS_BULLISH)   bullVotes++;  else bearVotes++;
if(h1DirectionBias == BIAS_BULLISH) bullVotes++;  else bearVotes++;

htfConsensus = (bullVotes >= 2) ? BIAS_BULLISH : BIAS_BEARISH;
```
The variable `h1DirectionBias` (or however the H1 `directionBias` field is named) must be read from the H1 `CICTStructureEngine` instance. Do not recompute it — read the already-computed value.

---

### BUG 5 — Partial Close Ratio [Item #69 — ICT_RiskManager.mqh]

**Problem:** TP partial close split uses `40% / 40% / 20%` instead of the correct ICT split of `35% / 40% / 25%`.

**Fix:**
Locate the partial close ratio constants or the `CalculatePartialLot()` function:
```mql5
// WRONG
const double TP1_RATIO = 0.40;
const double TP2_RATIO = 0.40;
const double TP3_RATIO = 0.20;

// CORRECT
const double TP1_RATIO = 0.35;  ///< Close 35% at TP1
const double TP2_RATIO = 0.40;  ///< Close 40% at TP2
const double TP3_RATIO = 0.25;  ///< Trailing remainder 25% to TP3
```
Ensure `TP1_RATIO + TP2_RATIO + TP3_RATIO == 1.0` is enforced by a compile-time assertion or a runtime `Print()` warning in `OnInit()`.

---

### BUG 6 — `CurrentWeekKey()` Incorrect Calculation [Item #75 — ICT_RiskManager.mqh]

**Problem:** `CurrentWeekKey()` returns an incorrect value, breaking the weekly drawdown cap.

**Fix:**
Replace the existing implementation entirely with:
```mql5
/// @brief Returns an integer key representing the ISO week (year * 100 + week_number).
/// Uses Monday as the first day of the week per ICT convention.
int CurrentWeekKey()
{
    MqlDateTime dt;
    TimeToStruct(TimeGMT(), dt);
    // Day of week: 0=Sun,1=Mon,...,6=Sat — shift so Monday=0
    int dow = (dt.day_of_week == 0) ? 6 : dt.day_of_week - 1;
    // Find Monday of current week
    datetime monday = TimeGMT() - (datetime)(dow * 86400);
    TimeToStruct(monday, dt);
    return dt.year * 100 + dt.day_of_year / 7;
}
```
After fixing, verify that the weekly drawdown accumulator resets correctly on each new Monday at 00:00 GMT.

---

### BUG 7 — Magic Number Version Drift [Item #80 — ICT_EURUSD_EA.mq5 + ICT_Constants.mqh]

**Problem:** The magic number changes across versions, causing the EA to lose track of its own open positions after recompile.

**Fix — Step 1:** Create `ICT_Constants.mqh` if it does not exist with:
```mql5
//+------------------------------------------------------------------+
//| ICT_Constants.mqh                                                |
//| MARK1 — Single source of truth for all compile-time constants    |
//+------------------------------------------------------------------+
#pragma once

#define MARK1_MAGIC        20240001  ///< FIXED. Never change this value.
#define MARK1_VERSION      "3.2"
#define MARK1_SYMBOL       "EURUSD"
#define MARK1_GMT_OFFSET   0         ///< Broker GMT offset (0 = true GMT broker)
```

**Fix — Step 2:** In `ICT_EURUSD_EA.mq5`, remove any hardcoded integer magic number. Replace with:
```mql5
#include "ICT_Constants.mqh"
// ...
riskManager.SetMagicNumber(MARK1_MAGIC);
```
Ensure every `.mqh` file that previously had its own magic integer now includes `ICT_Constants.mqh`.

---

### PHASE 1 — Compile & Validation Checklist
Before committing Phase 1:
- [ ] Full compile in MetaEditor → 0 errors, 0 warnings
- [ ] Run Strategy Tester on `EURUSD M15`, `2023-01-02` to `2023-06-08`, Every Tick
- [ ] Baseline must be within ±5% of: 132 trades, PF 1.88, Max DD 8.48%
- [ ] If baseline drifts >5% → isolate which bug fix caused it before proceeding

---

## PHASE 2 — CORE INFRASTRUCTURE: MISSING FOUNDATIONAL ITEMS
**Objective:** Add all structural primitives that downstream phases depend on. No new strategies yet.  
**Files to modify/create:** `ICT_Structure.mqh`, `ICT_Session.mqh`, `ICT_Liquidity.mqh`, `ICT_Bias.mqh`

---

### ITEM 1 — M1 STH/STL Engine [Item #5 — ICT_Structure.mqh]

**Task:** Wire a fifth `CICTStructureEngine` instance operating on `PERIOD_M1` to detect Short-Term Highs (STH) and Short-Term Lows (STL).

**Implementation:**
In `ICT_Bias.mqh` (or wherever the 4 existing engines are instantiated), add:
```mql5
CICTStructureEngine m1Engine;  ///< M1 STH/STL detection only

// In Init():
m1Engine.Init(PERIOD_M1, _Symbol, 3);  // 3-bar swing for STH/STL
```
Add accessor: `bool IsSTH(double price)` and `bool IsSTL(double price)` that delegate to `m1Engine`.
STH/STL are used exclusively for entry refinement — they do not affect the main bias.

---

### ITEM 2 — IRL / ERL Classification [Item #6 — ICT_Liquidity.mqh]

**Task:** Implement `ClassifyLiquidityType()` to classify any identified liquidity level as Internal Range Liquidity (IRL) or External Range Liquidity (ERL).

**Definition:**
- **IRL:** Liquidity pool that lies **within** the current dealing range (between the most recent significant swing high and swing low on H4).
- **ERL:** Liquidity pool that lies **outside** the current dealing range — above the H4 swing high or below the H4 swing low.

**Implementation:**
```mql5
/// Liquidity classification type
enum ENUM_LIQUIDITY_TYPE
{
    LIQ_IRL,   ///< Internal Range Liquidity
    LIQ_ERL,   ///< External Range Liquidity
    LIQ_NONE   ///< Unclassified
};

/// @brief Classifies a price level as IRL or ERL relative to H4 dealing range.
/// @param level        The price level to classify
/// @param h4RangeHigh  Current H4 range high (most recent H4 swing high)
/// @param h4RangeLow   Current H4 range low  (most recent H4 swing low)
ENUM_LIQUIDITY_TYPE ClassifyLiquidityType(double level, double h4RangeHigh, double h4RangeLow)
{
    if(level > h4RangeHigh || level < h4RangeLow) return LIQ_ERL;
    return LIQ_IRL;
}
```
Add field `ENUM_LIQUIDITY_TYPE liqType` to the `LiquidityLevel` struct (or equivalent). Populate on creation.

---

### ITEM 3 — Inducement (IDM) Detection [Item #7 — ICT_Liquidity.mqh]

**Task:** Implement `FindInducement()` to detect IDM — a minor swing high/low that is swept before a true institutional move.

**Definition:** IDM is a short-term swing high (for bearish IDM) or short-term swing low (for bullish IDM) on M15/M5 that forms **after** a higher-timeframe (H1/H4) order block or FVG is identified, and that is subsequently taken out (swept) before price delivers into the PD array.

**Implementation:**
```mql5
struct SInducementLevel
{
    double        price;        ///< IDM price level
    datetime      time;         ///< Time IDM formed
    bool          isSwept;      ///< True once price trades through this level
    ENUM_TIMEFRAMES timeframe;  ///< Timeframe IDM was detected on
    bool          isBullish;    ///< True = bullish IDM (STL swept), False = bearish IDM (STH swept)
};

/// @brief Scans lookback bars on tf for an unswept IDM relative to entryDirection.
/// @param tf              Timeframe to scan (M15 or M5)
/// @param entryDirection  +1 for long setup (look for bullish IDM), -1 for short
/// @param lookback        Number of bars to scan (default 20)
/// @param result          Output: populated SInducementLevel if found
/// @return True if IDM found and not yet swept
bool FindInducement(ENUM_TIMEFRAMES tf, int entryDirection, int lookback, SInducementLevel &result);
```
IDM sweep gate (Item #63) will call `FindInducement()` and require `isSwept == true` before allowing entry.

---

### ITEM 4 — NDOG / NWOG [Items #26, #27 — ICT_Liquidity.mqh]

**Task:** Implement `ComputeNDOG()` and `ComputeNWOG()`.

**Definitions:**
- **NDOG (New Day Opening Gap):** The gap between the previous day's close (4-candle body close at 23:59 GMT) and the current day's open (00:00 GMT candle open). If `|dayOpen - prevDayClose| > 0` (adjusted for spread), an NDOG exists.
- **NWOG (New Week Opening Gap):** The gap between Friday's close (22:00 GMT candle close on EURUSD) and Sunday's open (21:00 GMT or Monday 00:00 GMT). If `|weekOpen - prevWeekClose| > 0`, an NWOG exists.

**Implementation:**
```mql5
struct SOpeningGap
{
    double   gapHigh;     ///< Upper boundary of the gap
    double   gapLow;      ///< Lower boundary of the gap
    datetime gapTime;     ///< Timestamp the gap formed
    bool     isFilled;    ///< True once price trades through both boundaries
    bool     isBullish;   ///< True = gap up (bullish), False = gap down (bearish)
};

SOpeningGap ComputeNDOG();   ///< Computes today's New Day Opening Gap
SOpeningGap ComputeNWOG();   ///< Computes this week's New Week Opening Gap
```
Both functions must use `iBarShift()` and `iClose()` on the relevant daily/weekly series, not on the current chart timeframe directly.

---

### ITEM 5 — Sweep Count Tracking [Item #29 — ICT_Liquidity.mqh]

**Task:** Add `sweepCount` field to the `LiquidityLevel` struct and increment it each time `DetectSweepOfLevel()` fires for that level.

```mql5
struct SLiquidityLevel
{
    double   price;
    datetime formed;
    int      sweepCount;      ///< Number of times this level has been swept
    datetime lastSweepTime;   ///< Timestamp of most recent sweep
    bool     isActive;        ///< False after final sweep/exhaustion
    ENUM_LIQUIDITY_TYPE liqType;
};
```

---

### ITEM 6 — Midnight Open Price [Item #43 — ICT_Session.mqh]

**Task:** Compute and store the Midnight Open Price (MOP) — the open price of the 00:00 GMT candle of the current trading day on the current chart timeframe.

```mql5
double GetMidnightOpen()
{
    datetime midnightGMT = iTime(_Symbol, PERIOD_D1, 0); // 00:00 GMT of current D1 bar
    int shift = iBarShift(_Symbol, _Period, midnightGMT, false);
    if(shift < 0) return 0.0;
    return iOpen(_Symbol, _Period, shift);
}
```
Cache this value on bar open. Expose as `double midnightOpenPrice` on the session struct.

---

### ITEM 7 — London Close Window [Item #44 — ICT_Session.mqh]

**Task:** Add London Close session window (14:00–15:00 GMT) to `ICT_Session.mqh`.

```mql5
#define LONDON_CLOSE_START_GMT  14  ///< 14:00 GMT
#define LONDON_CLOSE_END_GMT    15  ///< 15:00 GMT

bool IsLondonCloseWindow(datetime gmtTime)
{
    MqlDateTime dt;
    TimeToStruct(gmtTime, dt);
    return (dt.hour >= LONDON_CLOSE_START_GMT && dt.hour < LONDON_CLOSE_END_GMT);
}
```
Add `bool isLondonCloseWindow` to the `SSessionState` struct and populate it in `UpdateSessionState()`.

---

### ITEM 8 — Weekly & Monthly Bias [Items #52, #53 — ICT_Bias.mqh]

**Task:** Implement `ResolveWeeklyBias()` and `ResolveMonthlyBias()` using H4 candle series on weekly and monthly aggregations.

```mql5
/// @brief Resolves weekly directional bias from PERIOD_W1 structure.
ENUM_MARKET_BIAS ResolveWeeklyBias()
{
    // Last closed W1 candle: close vs open
    double wClose = iClose(_Symbol, PERIOD_W1, 1);
    double wOpen  = iOpen (_Symbol, PERIOD_W1, 1);
    return (wClose > wOpen) ? BIAS_BULLISH : BIAS_BEARISH;
}

/// @brief Resolves monthly directional bias from PERIOD_MN1 structure.
ENUM_MARKET_BIAS ResolveMonthlyBias()
{
    double mClose = iClose(_Symbol, PERIOD_MN1, 1);
    double mOpen  = iOpen (_Symbol, PERIOD_MN1, 1);
    return (mClose > mOpen) ? BIAS_BULLISH : BIAS_BEARISH;
}
```
Add `weeklyBias` and `monthlyBias` fields to `SBiasState`. These are informational and do not gate trades in Phase 2 — gating is added in Phase 5.

---

### PHASE 2 — Compile & Validation Checklist
- [ ] Full compile → 0 errors, 0 warnings
- [ ] Strategy Tester baseline still within ±5% of v3.2 reference (132 trades, PF 1.88, Max DD 8.48%)
- [ ] Verify `ClassifyLiquidityType()` returns correct IRL/ERL on a manual price input test in `OnInit()`
- [ ] Verify `ComputeNDOG()` returns non-zero gap on a day with a known gap in historical data

---

## PHASE 3 — PD ARRAYS: MISSING BLOCK TYPES
**Objective:** Implement the 5 missing PD array types.  
**Files to modify:** `ICT_OrderBlock.mqh`

---

### ITEM 1 — Implied FVG [Item #13 — ICT_FVG.mqh]

**Task:** Implement Implied Fair Value Gap detection. An Implied FVG forms when a candle's wick (not body) creates a gap with the adjacent candle's body — it is "implied" because the gap is based on wicks, not a clean body gap.

**Definition:** On a 3-candle sequence [A, B, C]:
- Standard FVG: `A.high < C.low` (bull) or `A.low > C.high` (bear)
- Implied FVG: `A.high < C.open` (bull IFVG) — wick-to-open gap
- Implied FVG: `A.low > C.open` (bear IFVG) — wick-to-open gap

```mql5
struct SImpliedFVG
{
    double   gapHigh;
    double   gapLow;
    double   consequentEncroachment;  ///< 50% of center candle body (same formula as FVG)
    datetime time;
    bool     isBullish;
    bool     isFilled;
};

/// @brief Detects the most recent unfilled Implied FVG on the given timeframe.
bool DetectImpliedFVG(ENUM_TIMEFRAMES tf, int lookback, SImpliedFVG &result);
```

---

### ITEM 2 — Rejection Block [Item #17 — ICT_OrderBlock.mqh]

**Task:** Implement `FindRejectionBlock()`. A Rejection Block is a candle or cluster of candles with a significantly large wick relative to body, indicating price was rejected at that level.

**Definition:** A candle qualifies as a Rejection Block when:
- `wickLength / totalRange > 0.65` (wick is >65% of total candle range)
- The wick points in the direction of the opposing institutional order flow

```mql5
struct SRejectionBlock
{
    double   wickHigh;     ///< Top of the wick
    double   wickLow;      ///< Bottom of the wick  
    double   bodyHigh;     ///< Top of body
    double   bodyLow;      ///< Bottom of body
    datetime time;
    bool     isBullish;    ///< True = bullish rejection (lower wick dominant)
    bool     isActive;
};

bool FindRejectionBlock(ENUM_TIMEFRAMES tf, int lookback, SRejectionBlock &result);
```

---

### ITEM 3 — Propulsion Block [Item #18 — ICT_OrderBlock.mqh]

**Task:** Implement `FindPropulsionBlock()`. A Propulsion Block is a strong displacement candle (momentum candle) that precedes an FVG, acting as the "engine" of the move.

**Definition:** A candle qualifies as a Propulsion Block when:
- Candle body > 1.5× average body of prior 10 candles (displacement)
- Candle is followed by an FVG within the next 3 candles
- The candle body closes at or near its high (bull) or low (bear) — close-to-range ratio > 0.70

```mql5
struct SPropulsionBlock
{
    double   blockHigh;
    double   blockLow;
    double   blockOpen;
    double   blockClose;
    datetime time;
    bool     isBullish;
    bool     isActive;
    bool     hasFVG;      ///< True if a paired FVG was confirmed after this block
};

bool FindPropulsionBlock(ENUM_TIMEFRAMES tf, int lookback, SPropulsionBlock &result);
```

---

### ITEM 4 — Vacuum Block [Item #19 — ICT_OrderBlock.mqh]

**Task:** Implement `FindVacuumBlock()`. A Vacuum Block is a price zone where there is an absence of candle bodies — only wicks pass through — indicating a liquidity vacuum that price will be drawn to fill.

**Definition:** A Vacuum Block zone is identified when:
- A price range `[low, high]` spanning at least `minVacuumPips` (configurable, default 10 pips)
- Contains no candle body (open or close) in the lookback period
- At least one candle wick has passed through the zone

```mql5
struct SVacuumBlock
{
    double   zoneHigh;
    double   zoneLow;
    datetime formed;
    bool     isFilled;    ///< True once a candle body closes inside the zone
};

bool FindVacuumBlock(ENUM_TIMEFRAMES tf, int lookback, double minVacuumPips, SVacuumBlock &result);
```

---

### ITEM 5 — Reclaimed Order Block [Item #20 — ICT_OrderBlock.mqh]

**Task:** Add reclaimed OB tracking. A Reclaimed Block is an Order Block that was previously invalidated (price traded fully through it) but has since been "reclaimed" — price has returned to the zone and is now trading back in its original direction.

**Implementation:**
Add to `SOrderBlock` struct:
```mql5
bool   isInvalidated;      ///< True once price has fully closed through this OB
bool   isReclaimed;        ///< True once price returns to zone after invalidation
datetime invalidatedTime;
datetime reclaimedTime;
```
In `RefreshOrderBlockState()`, after setting `isInvalidated = true`, monitor for subsequent candles that re-enter the OB zone. When re-entry is confirmed by a candle close inside the zone, set `isReclaimed = true`.

---

### PHASE 3 — Compile & Validation Checklist
- [ ] Full compile → 0 errors, 0 warnings
- [ ] `DetectImpliedFVG()` detects at least 1 IFVG on `EURUSD M15` in 2023-01 data
- [ ] `FindRejectionBlock()` returns valid data; wick ratio check passes for a known pinbar

---

## PHASE 4 — LIQUIDITY, SESSION & BIAS COMPLETIONS
**Objective:** Complete all partial and missing items in Liquidity, Session/Time, and Bias modules.  
**Files to modify:** `ICT_Liquidity.mqh`, `ICT_Session.mqh`, `ICT_Bias.mqh`

---

### ITEM 1 — Session Opening Range Gap [Item #28 — ICT_Session.mqh]

**Task:** Detect the Opening Range Gap at the start of each killzone session.

**Definition:** The gap between the last candle close of the pre-session period and the first candle open of the session. Specifically:
- **London ORG:** Last M15 close before 07:00 GMT vs. first M15 open at 07:00 GMT
- **NY ORG:** Last M15 close before 12:00 GMT vs. first M15 open at 12:00 GMT

```mql5
struct SSessionORG
{
    double      gapHigh;
    double      gapLow;
    bool        isBullish;
    bool        isFilled;
    ENUM_SESSION session;  // SESSION_LONDON or SESSION_NY_AM
};

SSessionORG ComputeLondonORG();
SSessionORG ComputeNYORG();
```

---

### ITEM 2 — Run on Stops [Item #30 — ICT_Liquidity.mqh]

**Task:** Implement `DetectRunOnStops()`. A Run on Stops is a rapid, short-duration move that sweeps a cluster of equal highs or equal lows (retail stop clusters) before reversing.

**Definition:**
- Price sweeps a previously identified `EqualHighs` or `EqualLows` level
- The sweep candle closes back below (for equal highs sweep) or above (for equal lows sweep) the swept level within the same candle
- The sweep duration is ≤ 3 candles on the current timeframe

```mql5
struct SRunOnStops
{
    double      sweptLevel;
    datetime    sweepTime;
    bool        isBullishSetup;  ///< True = stops run below, expect reversal up
    bool        isConfirmed;     ///< True once close-back is confirmed
};

bool DetectRunOnStops(ENUM_TIMEFRAMES tf, double equalLevel, bool isHighLevel, SRunOnStops &result);
```

---

### ITEM 3 — Draw on Liquidity (DOL) Formal Selector [Item #31 — ICT_Liquidity.mqh]

**Task:** Replace the informal PDH/PDL TP3 usage with a formal DOL selector that evaluates multiple competing liquidity pools and returns the highest-probability target.

**Implementation:**
```mql5
enum ENUM_DOL_TYPE
{
    DOL_PDH,   ///< Previous Day High
    DOL_PDL,   ///< Previous Day Low
    DOL_PWH,   ///< Previous Week High
    DOL_PWL,   ///< Previous Week Low
    DOL_EQH,   ///< Equal Highs cluster
    DOL_EQL,   ///< Equal Lows cluster
    DOL_NWOG,  ///< New Week Opening Gap fill
    DOL_NDOG,  ///< New Day Opening Gap fill
    DOL_NONE
};

struct SDOLTarget
{
    ENUM_DOL_TYPE type;
    double        price;
    double        distancePips;
    int           confluenceScore;  ///< Higher = more likely target
};

/// @brief Selects the highest-probability Draw on Liquidity target given current bias.
/// @param bias        Current HTF bias (BULLISH or BEARISH)
/// @param entryPrice  Current entry price
/// @return            Best DOL target
SDOLTarget SelectDOLTarget(ENUM_MARKET_BIAS bias, double entryPrice);
```
Scoring: PDH/PDL = 3 pts, PWH/PWL = 4 pts, EQH/EQL (touched 2+ times) = 5 pts, NWOG/NDOG unfilled = 4 pts. Select highest score in the direction of bias.

---

### ITEM 4 — Judas Swing State Machine [Item #41 — ICT_Session.mqh]

**Task:** Implement a full Judas Swing state machine with `PO3_MANIPULATION` phase and confirmation logic.

**PO3 Phases:**
- `PO3_ACCUMULATION`: Asian session — price consolidates in range
- `PO3_MANIPULATION` (Judas Swing): London open (07:00–08:30 GMT) — false move opposite to true direction
- `PO3_DISTRIBUTION`: True move begins — entry window

**Implementation:**
```mql5
enum ENUM_PO3_PHASE
{
    PO3_ACCUMULATION,   ///< Asian range building
    PO3_MANIPULATION,   ///< Judas Swing — false move
    PO3_DISTRIBUTION,   ///< True institutional delivery
    PO3_UNKNOWN
};

struct SJudasSwing
{
    bool            detected;
    bool            confirmed;          ///< True once reversal candle closes
    ENUM_PO3_PHASE  currentPhase;
    double          manipulationHigh;   ///< High of the false move
    double          manipulationLow;    ///< Low of the false move
    double          asianRangeHigh;
    double          asianRangeLow;
    bool            isBullishJudas;     ///< True = price swept below Asian low then reversed up
    datetime        manipulationTime;
    datetime        confirmationTime;
};
```

**Confirmation logic:**
1. Asian range established (01:00–05:00 GMT)
2. During London Killzone (07:00–08:30 GMT), price sweeps BELOW Asian low (bullish Judas) or ABOVE Asian high (bearish Judas)
3. A M15 candle closes back INSIDE the Asian range = Judas Swing confirmed
4. Set `confirmed = true`, set `currentPhase = PO3_DISTRIBUTION`

---

### ITEM 5 — Day of Week Bias Filter [Item #42 — ICT_Bias.mqh]

**Task:** Implement DOW-based phase gating. ICT's DOW model: Tuesday–Wednesday = highest probability setups; Monday = accumulation; Thursday = distribution; Friday = reversal/TGIF potential.

```mql5
enum ENUM_DOW_PHASE
{
    DOW_MONDAY,     ///< Accumulation — avoid entries, wait for direction
    DOW_TUESDAY,    ///< Optimal — take trend continuation setups
    DOW_WEDNESDAY,  ///< Optimal — highest probability continuation
    DOW_THURSDAY,   ///< Distribution — take setups but tighten targets
    DOW_FRIDAY,     ///< Reversal risk — TGIF potential, reduce risk
    DOW_WEEKEND     ///< No trading
};

/// @brief Returns the ICT-mapped DOW phase for a given GMT timestamp.
ENUM_DOW_PHASE GetDOWPhase(datetime gmtTime)
{
    MqlDateTime dt;
    TimeToStruct(gmtTime, dt);
    switch(dt.day_of_week)
    {
        case 1: return DOW_MONDAY;
        case 2: return DOW_TUESDAY;
        case 3: return DOW_WEDNESDAY;
        case 4: return DOW_THURSDAY;
        case 5: return DOW_FRIDAY;
        default: return DOW_WEEKEND;
    }
}
```
Add `ENUM_DOW_PHASE currentDOWPhase` to `SBiasState`. For Phase 4, this is informational only — entry gating is Phase 5.

---

### PHASE 4 — Compile & Validation Checklist
- [ ] Full compile → 0 errors, 0 warnings
- [ ] `SelectDOLTarget()` returns a valid non-NONE target on a live chart
- [ ] Judas Swing confirmed on at least one historical London session in 2023-01 data
- [ ] Baseline still within ±5%

---

## PHASE 5 — ENTRY MODELS: ALL STRATEGY COMPLETIONS
**Objective:** Complete all 5 missing entry models, fix the 1 partial, and add all entry gates.  
**Files to modify:** `ICT_EURUSD_EA.mq5`, new file `ICT_EntryModels.mqh`

**Architecture:** Create a new file `ICT_EntryModels.mqh` with one class per strategy inheriting from a base `CEntryModel` interface:
```mql5
/// Base interface for all entry models
class CEntryModel
{
public:
    virtual bool      Scan(SMarketContext &ctx) = 0;  ///< Returns true if setup is valid
    virtual STradeSetup GetSetup()              = 0;  ///< Returns the trade setup
    virtual string    Name()                    = 0;  ///< Model name for logging
};
```

---

### ITEM 1 — Silver Bullet Dedicated Builder [Item #56]

**Task:** Build a `CSilverBulletModel` class implementing the complete Silver Bullet entry:
1. Session must be in Silver Bullet window (London: 08:00–09:00 GMT, NY AM: 15:00–16:00 GMT, NY PM: 19:00–20:00 GMT)
2. HTF bias must be established (Phase 2 consensus)
3. Within the window, detect a sweep of the preceding session's high/low
4. After sweep, wait for an FVG to form on M1/M5
5. Enter on a limit order at the FVG CE (50% of center candle body — Phase 1 fix)
6. SL: below/above the sweep wick
7. TP: 1:2 RR minimum, DOL target preferred

---

### ITEM 2 — Judas Swing Entry Model [Item #58]

**Task:** Build `CJudasSwingModel`. Requires Phase 4 Judas Swing state machine to be active.

**Entry sequence:**
1. Asian range confirmed (Phase 2)
2. Judas Swing `confirmed == true` (Phase 4)
3. Price pulls back into Asian range and creates an FVG or OB on M5/M15
4. Enter at FVG CE or OB 50% level
5. SL: below sweep wick (bullish) or above sweep wick (bearish) + 5 pip buffer
6. TP1: 1:1 RR · TP2: Asian range opposite extreme · TP3: DOL target (Phase 4 selector)

---

### ITEM 3 — Market Maker Model [Item #59]

**Task:** Build `CMarketMakerModel` implementing the 4-phase MM cycle.

**4 Phases:**
1. **Accumulation:** Equal highs/lows form on H1 — consolidation
2. **Manipulation:** False break of equal highs/lows sweeping retail stops
3. **Distribution:** BOS on M15 in opposite direction to manipulation
4. **Re-accumulation (optional):** Consolidation before continuation

**Entry:** After Distribution BOS, enter on first M15 FVG in direction of BOS.
**Invalidation:** If price exceeds 50% of the Manipulation range without a BOS, model is invalid.

---

### ITEM 4 — Turtle Soup [Item #60]

**Task:** Build `CTurtleSoupModel`. Turtle Soup is a counter-trend setup that fades a 20-bar breakout.

**Entry sequence:**
1. Identify the 20-bar highest high (for bearish TS) or lowest low (for bullish TS)
2. Price breaks above the 20-bar high by a small margin (≤ 10 pips for EURUSD)
3. Within 2 candles on M15, a rejection/reversal candle closes back below the 20-bar high
4. Enter short at market or on a limit at the 20-bar high
5. SL: 10 pips above entry · TP: 20-bar low (for bearish)

---

### ITEM 5 — London Close Reversal [Item #61]

**Task:** Build `CLondonCloseReversalModel`. Uses the London Close window (Phase 2, Item 7).

**Entry sequence:**
1. Time: 14:00–15:00 GMT (London Close window)
2. Must have a clear intraday trend established during London session
3. Look for a sweep of the London session high (for bearish reversal) or low (for bullish reversal)
4. Sweep candle must close back inside the range = reversal confirmation
5. Enter with FVG or OB confluence on M5
6. TP: NY AM opening range midpoint or DOL target

---

### ITEM 6 — TGIF Friday Reversal [Item #62]

**Task:** Build `CTGIFModel`. TGIF (Thank God It's Friday) fades the weekly continuation bias on Fridays.

**Entry sequence:**
1. `GetDOWPhase() == DOW_FRIDAY` (Phase 4)
2. Identify the direction of the weekly move (Tuesday–Thursday trend)
3. After 10:00 GMT on Friday, look for a sweep of the week's high (bearish) or low (bullish)
4. Enter counter to weekly trend on M15 FVG after sweep
5. TP: Friday's opening price (Midnight Open — Phase 2, Item 6)
6. Hard close: all TGIF positions must be closed by 20:00 GMT Friday

---

### ITEM 7 — IDM Sweep Gate [Item #63]

**Task:** Wire `FindInducement()` (Phase 2, Item 3) as a mandatory gate for the Sweep→FVG model and the Continuation model.

In `ICT_EURUSD_EA.mq5`, in the entry validation function for both `SweepFVGModel` and `ContinuationModel`, add:
```mql5
SInducementLevel idm;
if(!FindInducement(_Period, entryDirection, 20, idm))
{
    Print("[MARK1][GATE] IDM not found — setup rejected");
    return false;
}
if(!idm.isSwept)
{
    Print("[MARK1][GATE] IDM not yet swept — setup rejected");
    return false;
}
```

---

### ITEM 8 — IRL→ERL Trade Gate [Item #64]

**Task:** Wire `ClassifyLiquidityType()` (Phase 2, Item 2) as a mandatory gate. Only take trades that target ERL from IRL (or IRL from ERL with higher confluence). Trades targeting IRL-to-IRL are rejected.

```mql5
SDOLTarget dolTarget = SelectDOLTarget(htfBias, entryPrice);
ENUM_LIQUIDITY_TYPE entryZoneType = ClassifyLiquidityType(entryPrice, h4RangeHigh, h4RangeLow);
ENUM_LIQUIDITY_TYPE targetType    = ClassifyLiquidityType(dolTarget.price, h4RangeHigh, h4RangeLow);

if(entryZoneType == LIQ_IRL && targetType == LIQ_IRL)
{
    Print("[MARK1][GATE] IRL→IRL trade rejected — no liquidity draw");
    return false;
}
```

---

### PHASE 5 — Compile & Validation Checklist
- [ ] Full compile → 0 errors, 0 warnings
- [ ] Each entry model logs its setup detection independently — verify in Journal tab
- [ ] Run Strategy Tester 2023-01-02 to 2023-06-08 — trade count should increase vs v3.2 baseline
- [ ] No trade should open without a valid IDM sweep gate pass (check journal)

---

## PHASE 6 — RISK MANAGER: MISSING PROTECTIVE MECHANICS
**Objective:** Add spread filter, consecutive loss breaker, CSV logger, and pending order invalidation.  
**Files to modify:** `ICT_RiskManager.mqh`

---

### ITEM 1 — Spread Filter [Item #76]

**Task:** Reject any trade attempt when the current spread exceeds `maxSpreadPips` (input parameter, default 3.0 pips for EURUSD).

```mql5
/// @brief Returns true if current spread is within acceptable limits.
bool IsSpreadAcceptable()
{
    double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
    double spreadPips = spread / _Point / 10.0;  // Convert to pips for 5-digit broker
    if(spreadPips > m_maxSpreadPips)
    {
        Print("[MARK1][RISK] Spread too high: ", spreadPips, " pips. Max: ", m_maxSpreadPips);
        return false;
    }
    return true;
}
```
Input parameter `MaxSpreadPips` must be exposed in `ICT_EURUSD_EA.mq5` input block.

---

### ITEM 2 — Max Consecutive Loss Breaker [Item #77]

**Task:** Halt all new trade entries if `consecutiveLosses >= maxConsecutiveLosses` (input parameter, default 3).

```mql5
int  m_consecutiveLosses;    ///< Current streak of consecutive losses
int  m_maxConsecutiveLosses; ///< Circuit breaker threshold (input)

/// @brief Called by trade close handler. Tracks win/loss streak.
void OnTradeClosed(bool isWin)
{
    if(isWin)
        m_consecutiveLosses = 0;
    else
    {
        m_consecutiveLosses++;
        if(m_consecutiveLosses >= m_maxConsecutiveLosses)
            Print("[MARK1][RISK] Consecutive loss breaker triggered. No new trades today.");
    }
}

bool IsConsecutiveLossBreaker()
{
    return (m_consecutiveLosses >= m_maxConsecutiveLosses);
}
```
Reset `m_consecutiveLosses` to 0 at the start of each new trading day (on new D1 candle open).

---

### ITEM 3 — CSV Trade Logger [Item #78]

**Task:** Write every completed trade to a CSV file in `MQL5/Files/MARK1_Trades.csv`.

**CSV columns:**
```
TradeID,OpenTime,CloseTime,Symbol,Type,EntryPrice,SLPrice,TP1Price,TP2Price,TP3Price,ClosePrice,LotSize,PnLPips,PnLDollars,Model,BiasAtEntry,DayOfWeek,Session,IDM_Swept,FVG_Type,OB_Type
```

```mql5
void LogTradeToCSV(STradeRecord &trade)
{
    int handle = FileOpen("MARK1_Trades.csv", FILE_WRITE | FILE_READ | FILE_CSV | FILE_ANSI, ',');
    if(handle == INVALID_HANDLE)
    {
        Print("[MARK1][LOG] Cannot open MARK1_Trades.csv");
        return;
    }
    FileSeek(handle, 0, SEEK_END);
    FileWrite(handle,
        trade.id, TimeToString(trade.openTime), TimeToString(trade.closeTime),
        _Symbol, EnumToString(trade.type), trade.entryPrice,
        trade.slPrice, trade.tp1, trade.tp2, trade.tp3,
        trade.closePrice, trade.lotSize, trade.pnlPips, trade.pnlDollars,
        trade.modelName, EnumToString(trade.biasAtEntry),
        EnumToString(trade.dowPhase), EnumToString(trade.session),
        (int)trade.idmSwept, trade.fvgType, trade.obType
    );
    FileClose(handle);
}
```

---

### ITEM 4 — Pending Order Invalidation [Item #79]

**Task:** Automatically cancel pending limit/stop orders that are no longer valid.

**Invalidation conditions:**
1. The candle that created the setup has been exceeded (e.g., price moves through the OB/FVG without triggering the order — the zone is now compromised)
2. The session window that generated the setup has closed (e.g., a Silver Bullet limit order still open after 09:00 GMT)
3. A new opposing BOS has formed on M15

```mql5
void ScanAndInvalidatePending()
{
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(!OrderSelect(ticket)) continue;
        if((long)OrderGetInteger(ORDER_MAGIC) != MARK1_MAGIC) continue;

        datetime orderTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
        string   comment   = OrderGetString(ORDER_COMMENT);

        // Rule 1: Order older than 4 hours — cancel
        if(TimeGMT() - orderTime > 4 * 3600)
        {
            trade.OrderDelete(ticket);
            Print("[MARK1][RISK] Pending invalidated (age): #", ticket);
            continue;
        }
        // Rule 2: Session expired — cancel Silver Bullet orders after window close
        if(StringFind(comment, "SilverBullet") >= 0 && !IsInAnySilverBulletWindow())
        {
            trade.OrderDelete(ticket);
            Print("[MARK1][RISK] Pending invalidated (SB session closed): #", ticket);
        }
    }
}
```
Call `ScanAndInvalidatePending()` on every new M15 bar.

---

### PHASE 6 — Compile & Validation Checklist
- [ ] Full compile → 0 errors, 0 warnings
- [ ] `MARK1_Trades.csv` is created and populated after any backtest run
- [ ] Confirm consecutive loss counter resets on new day in Strategy Tester journal
- [ ] Verify spread filter rejects entries when spread is artificially set > 3 pips in tester

---

## PHASE 7 — NEW FILES: ICT_IPDA.mqh + ICT_SMT.mqh
**Objective:** Create two entirely new files implementing IPDA and SMT logic.

---

### FILE 1 — ICT_IPDA.mqh [Item #81]

**IPDA (Interbank Price Delivery Algorithm) Concepts to implement:**

```mql5
//+------------------------------------------------------------------+
//| ICT_IPDA.mqh                                                      |
//| MARK1 — Interbank Price Delivery Algorithm levels                |
//+------------------------------------------------------------------+
#pragma once
#include "ICT_Constants.mqh"

/// IPDA lookback ranges per ICT specification
#define IPDA_20_BAR    20   ///< Short-term IPDA range
#define IPDA_40_BAR    40   ///< Medium-term IPDA range
#define IPDA_60_BAR    60   ///< Long-term IPDA range

struct SIPDARange
{
    double   high20;      ///< Highest high in last 20 D1 bars
    double   low20;       ///< Lowest low in last 20 D1 bars
    double   high40;
    double   low40;
    double   high60;
    double   low60;
    double   equilibrium20; ///< 50% of 20-bar range
    double   equilibrium40;
    double   equilibrium60;
    datetime computedAt;
};

class CIPDAEngine
{
private:
    SIPDARange m_range;

public:
    /// @brief Computes all three IPDA ranges on D1.
    void Compute()
    {
        m_range.high20 = iHighest(_Symbol, PERIOD_D1, MODE_HIGH, IPDA_20_BAR, 1);
        m_range.low20  = iLowest (_Symbol, PERIOD_D1, MODE_LOW,  IPDA_20_BAR, 1);
        m_range.high40 = iHighest(_Symbol, PERIOD_D1, MODE_HIGH, IPDA_40_BAR, 1);
        m_range.low40  = iLowest (_Symbol, PERIOD_D1, MODE_LOW,  IPDA_40_BAR, 1);
        m_range.high60 = iHighest(_Symbol, PERIOD_D1, MODE_HIGH, IPDA_60_BAR, 1);
        m_range.low60  = iLowest (_Symbol, PERIOD_D1, MODE_LOW,  IPDA_60_BAR, 1);
        m_range.equilibrium20 = (m_range.high20 + m_range.low20) / 2.0;
        m_range.equilibrium40 = (m_range.high40 + m_range.low40) / 2.0;
        m_range.equilibrium60 = (m_range.high60 + m_range.low60) / 2.0;
        m_range.computedAt = TimeGMT();
    }

    const SIPDARange* GetRange() const { return &m_range; }

    /// @brief Returns true if price is at or near (within tolerancePips) IPDA equilibrium.
    bool IsAtEquilibrium(double price, double tolerancePips, int barRange = 20)
    {
        double eq = (barRange == 20) ? m_range.equilibrium20 :
                    (barRange == 40) ? m_range.equilibrium40 : m_range.equilibrium60;
        return (MathAbs(price - eq) <= tolerancePips * _Point * 10);
    }
};
```
Add `CIPDAEngine ipdaEngine` to the main EA and call `ipdaEngine.Compute()` on each new D1 candle.

---

### FILE 2 — ICT_SMT.mqh [Item #82]

**SMT (Smart Money Technique / Divergence) to implement:**

```mql5
//+------------------------------------------------------------------+
//| ICT_SMT.mqh                                                      |
//| MARK1 — Smart Money Technique divergence between correlated pairs|
//+------------------------------------------------------------------+
#pragma once
#include "ICT_Constants.mqh"

/// @brief SMT correlation pair for EURUSD
#define SMT_CORRELATED_SYMBOL  "GBPUSD"  ///< Primary SMT correlation pair for EURUSD

struct SSMTDivergence
{
    bool     detected;
    bool     isBullishSMT;      ///< True = EURUSD makes lower low but GBPUSD does NOT
    bool     isBearishSMT;      ///< True = EURUSD makes higher high but GBPUSD does NOT
    double   eurSwingLevel;     ///< The new swing high/low on EURUSD
    double   gbpSwingLevel;     ///< The corresponding swing level on GBPUSD
    datetime detectedAt;
    int      confirmationBars;  ///< Bars since divergence formed (staleness)
};

class CSMTEngine
{
private:
    SSMTDivergence m_divergence;

public:
    /// @brief Scans for SMT divergence between EURUSD and GBPUSD on the given timeframe.
    /// @param tf       Timeframe to scan (H1 recommended for SMT)
    /// @param lookback Number of bars to compare swing highs/lows
    bool Scan(ENUM_TIMEFRAMES tf, int lookback = 10)
    {
        // EURUSD recent swing low
        int eurLowShift = (int)iLowest(_Symbol,           tf, MODE_LOW,  lookback, 1);
        int gbpLowShift = (int)iLowest(SMT_CORRELATED_SYMBOL, tf, MODE_LOW,  lookback, 1);

        double eurLow = iLow(_Symbol,                tf, eurLowShift);
        double gbpLow = iLow(SMT_CORRELATED_SYMBOL,  tf, gbpLowShift);

        // Previous swing lows (further back)
        int eurPrevLowShift = (int)iLowest(_Symbol,           tf, MODE_LOW,  lookback, lookback + 1);
        int gbpPrevLowShift = (int)iLowest(SMT_CORRELATED_SYMBOL, tf, MODE_LOW,  lookback, lookback + 1);

        double eurPrevLow = iLow(_Symbol,               tf, eurPrevLowShift);
        double gbpPrevLow = iLow(SMT_CORRELATED_SYMBOL, tf, gbpPrevLowShift);

        // Bullish SMT: EUR makes LOWER low, GBP does NOT (higher low) — institutional divergence
        m_divergence.isBullishSMT = (eurLow < eurPrevLow) && (gbpLow > gbpPrevLow);
        m_divergence.isBearishSMT = false;

        // Bearish SMT: EUR makes HIGHER high, GBP does NOT
        int eurHighShift  = (int)iHighest(_Symbol,           tf, MODE_HIGH, lookback, 1);
        int gbpHighShift  = (int)iHighest(SMT_CORRELATED_SYMBOL, tf, MODE_HIGH, lookback, 1);
        int eurPrevHShift = (int)iHighest(_Symbol,           tf, MODE_HIGH, lookback, lookback + 1);
        int gbpPrevHShift = (int)iHighest(SMT_CORRELATED_SYMBOL, tf, MODE_HIGH, lookback, lookback + 1);

        double eurHigh     = iHigh(_Symbol,               tf, eurHighShift);
        double gbpHigh     = iHigh(SMT_CORRELATED_SYMBOL, tf, gbpHighShift);
        double eurPrevHigh = iHigh(_Symbol,               tf, eurPrevHShift);
        double gbpPrevHigh = iHigh(SMT_CORRELATED_SYMBOL, tf, gbpPrevHShift);

        if((eurHigh > eurPrevHigh) && (gbpHigh < gbpPrevHigh))
            m_divergence.isBearishSMT = true;

        m_divergence.detected = (m_divergence.isBullishSMT || m_divergence.isBearishSMT);
        m_divergence.detectedAt = TimeGMT();
        return m_divergence.detected;
    }

    const SSMTDivergence* GetDivergence() const { return &m_divergence; }
};
```

---

### ITEM 3 — NWOG/NDOG as Price Magnets [Item #83]

In `ICT_EURUSD_EA.mq5`, after `ComputeNDOG()` and `ComputeNWOG()` return unfilled gaps, add them to the `SelectDOLTarget()` scoring system (Phase 4 Item 3). An unfilled NDOG in the direction of bias adds +4 to confluence score; unfilled NWOG adds +4.

---

### PHASE 7 — Compile & Validation Checklist
- [ ] Full compile → 0 errors, 0 warnings
- [ ] `ipdaEngine.Compute()` returns valid 20/40/60 bar levels on `EURUSD D1`
- [ ] `smtEngine.Scan(PERIOD_H1)` detects at least one divergence in 2023-Q1 data
- [ ] NWOG/NDOG appear in DOL target scoring

---

## PHASE 8 — VISUALIZER COMPLETIONS
**Objective:** Add all 6 missing visual elements to `ICT_Visualizer.mqh`.  
**Files to modify:** `ICT_Visualizer.mqh`

All chart objects must follow naming convention: `"MARK1_" + objectType + "_" + TimeToString(time, TIME_DATE|TIME_MINUTES)` to prevent duplication. Delete-and-redraw on each new bar.

---

### ITEM 1 — NDOG/NWOG Lines [Item #90]

```mql5
void DrawNDOGLines(SOpeningGap &ndog)
{
    if(ndog.gapHigh == 0.0 || ndog.isFilled) return;
    string nameH = "MARK1_NDOG_H_" + TimeToString(ndog.gapTime);
    string nameL = "MARK1_NDOG_L_" + TimeToString(ndog.gapTime);
    ObjectCreate(0, nameH, OBJ_HLINE, 0, 0, ndog.gapHigh);
    ObjectSetInteger(0, nameH, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, nameH, OBJPROP_STYLE, STYLE_DASH);
    ObjectCreate(0, nameL, OBJ_HLINE, 0, 0, ndog.gapLow);
    ObjectSetInteger(0, nameL, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, nameL, OBJPROP_STYLE, STYLE_DASH);
}
// Repeat symmetrically for DrawNWOGLines()
```

---

### ITEM 2 — PO3 Shaded Boxes [Item #91]

```mql5
void DrawPO3Box(ENUM_PO3_PHASE phase, datetime startTime, datetime endTime, double high, double low)
{
    color boxColor = (phase == PO3_ACCUMULATION)  ? clrLightBlue  :
                     (phase == PO3_MANIPULATION)   ? clrLightCoral :
                     (phase == PO3_DISTRIBUTION)   ? clrLightGreen : clrGray;
    string name = "MARK1_PO3_" + EnumToString(phase) + "_" + TimeToString(startTime);
    ObjectCreate(0, name, OBJ_RECTANGLE, 0, startTime, high, endTime, low);
    ObjectSetInteger(0, name, OBJPROP_COLOR,   boxColor);
    ObjectSetInteger(0, name, OBJPROP_FILL,    true);
    ObjectSetInteger(0, name, OBJPROP_BACK,    true);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, boxColor);
}
```

---

### ITEM 3 — Judas Confirmation Marker [Item #92]

```mql5
void DrawJudasMarker(SJudasSwing &judas)
{
    if(!judas.confirmed) return;
    string name = "MARK1_JUDAS_" + TimeToString(judas.confirmationTime);
    ObjectCreate(0, name, OBJ_ARROW, 0, judas.confirmationTime,
                 judas.isBullishJudas ? judas.manipulationLow : judas.manipulationHigh);
    ObjectSetInteger(0, name, OBJPROP_ARROWCODE, judas.isBullishJudas ? 233 : 234);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clrGold);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
}
```

---

### ITEM 4 — IPDA Level Lines [Item #93]

```mql5
void DrawIPDALevels(const SIPDARange* ipda)
{
    struct { string name; double price; color clr; } levels[] =
    {
        {"MARK1_IPDA_H20", ipda.high20, clrAqua},
        {"MARK1_IPDA_L20", ipda.low20,  clrAqua},
        {"MARK1_IPDA_EQ20",ipda.equilibrium20, clrYellow},
        {"MARK1_IPDA_H40", ipda.high40, clrCornflowerBlue},
        {"MARK1_IPDA_L40", ipda.low40,  clrCornflowerBlue},
        {"MARK1_IPDA_H60", ipda.high60, clrMediumBlue},
        {"MARK1_IPDA_L60", ipda.low60,  clrMediumBlue}
    };
    for(int i = 0; i < ArraySize(levels); i++)
    {
        ObjectCreate(0, levels[i].name, OBJ_HLINE, 0, 0, levels[i].price);
        ObjectSetInteger(0, levels[i].name, OBJPROP_COLOR, levels[i].clr);
        ObjectSetInteger(0, levels[i].name, OBJPROP_STYLE, STYLE_DOT);
    }
}
```

---

### ITEM 5 — DOW Phase Label [Item #94]

```mql5
void DrawDOWPhaseLabel(ENUM_DOW_PHASE phase)
{
    string name = "MARK1_DOW_LABEL";
    ObjectDelete(0, name);
    ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_TOP_RIGHT);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 30);
    ObjectSetString (0, name, OBJPROP_TEXT, "DOW: " + EnumToString(phase));
    ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
}
```

---

### ITEM 6 — SMT Divergence Marker [Item #95]

```mql5
void DrawSMTMarker(const SSMTDivergence* smt)
{
    if(!smt.detected) return;
    string name = "MARK1_SMT_" + TimeToString(smt.detectedAt);
    ObjectCreate(0, name, OBJ_TEXT, 0, smt.detectedAt,
                 smt.isBullishSMT ? smt.eurSwingLevel - 20 * _Point : smt.eurSwingLevel + 20 * _Point);
    ObjectSetString (0, name, OBJPROP_TEXT, smt.isBullishSMT ? "SMT↑" : "SMT↓");
    ObjectSetInteger(0, name, OBJPROP_COLOR, clrMagenta);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
}
```

---

### PHASE 8 — Compile & Validation Checklist
- [ ] Full compile → 0 errors, 0 warnings
- [ ] All chart objects appear on live EURUSD M15 chart — verify in MetaTrader 5
- [ ] No "object already exists" errors in Journal tab (confirm unique naming works)

---

## PHASE 9 — PYTHON TOOLS
**Objective:** Create 4 Python scripts using the official `MetaTrader5` Python package.  
**Python version:** 3.11+ · **Package:** `MetaTrader5`, `pandas`, `numpy`, `scipy`, `matplotlib`  
**File location:** `/Python/` folder in repo root.

---

### FILE 1 — ICT_Analytics.py [Item #96]

**Purpose:** Load `MARK1_Trades.csv` (Phase 6 CSV logger) and produce statistical analysis.

**Required outputs:**
- Win rate by model (SweepFVG, SilverBullet, JudasSwing, etc.)
- Average RR achieved vs. planned
- Performance by DOW phase
- Performance by session
- Max consecutive losses
- Profit factor by time-of-day heatmap (24 hours × 5 days)
- Monthly equity curve plot

```python
# ICT_Analytics.py
import pandas as pd
import matplotlib.pyplot as plt
from pathlib import Path

TRADES_CSV = Path("../MQL5/Files/MARK1_Trades.csv")

def load_trades(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, parse_dates=["OpenTime", "CloseTime"])
    df["IsWin"] = df["PnLPips"] > 0
    return df

def win_rate_by_model(df: pd.DataFrame) -> pd.DataFrame:
    return df.groupby("Model")["IsWin"].agg(["sum", "count", "mean"]).rename(
        columns={"sum": "Wins", "count": "Trades", "mean": "WinRate"})

def plot_equity_curve(df: pd.DataFrame):
    df = df.sort_values("CloseTime")
    df["CumPnL"] = df["PnLDollars"].cumsum()
    plt.figure(figsize=(14, 5))
    plt.plot(df["CloseTime"], df["CumPnL"])
    plt.title("MARK1 Equity Curve")
    plt.xlabel("Date")
    plt.ylabel("Cumulative P&L ($)")
    plt.grid(True)
    plt.tight_layout()
    plt.savefig("MARK1_EquityCurve.png", dpi=150)

if __name__ == "__main__":
    df = load_trades(TRADES_CSV)
    print(win_rate_by_model(df).to_string())
    plot_equity_curve(df)
```

---

### FILE 2 — MARK1_Optimizer.py [Item #97]

**Purpose:** Parameter optimization using MT5 Python API to run backtests across parameter ranges.

**Parameters to optimize:**
- `MaxSpreadPips` (2.0 – 5.0, step 0.5)
- `TP1_RR_Ratio` (1.0 – 2.0, step 0.25)
- `OTE_FibDeep` (0.62 – 0.79, step 0.017)
- `MaxConsecutiveLosses` (2 – 5, step 1)

```python
# MARK1_Optimizer.py
import MetaTrader5 as mt5
import itertools
import pandas as pd
from datetime import datetime

def run_backtest(params: dict) -> dict:
    """Submit a single backtest via MT5 Python API and return performance metrics."""
    # MT5 Python API does not expose Strategy Tester programmatically —
    # use file-based parameter injection via .set files instead.
    set_file = generate_set_file(params)
    # ... write set_file, trigger tester via subprocess or MT5 terminal config
    # Read results from tester report HTML/XML
    return parse_tester_report("MARK1_TestReport.xml")

def grid_search():
    param_grid = {
        "MaxSpreadPips":       [2.0, 2.5, 3.0, 3.5],
        "TP1_RR_Ratio":        [1.0, 1.25, 1.5, 1.75, 2.0],
        "MaxConsecutiveLosses":[2, 3, 4],
    }
    keys, values = zip(*param_grid.items())
    results = []
    for combo in itertools.product(*values):
        params = dict(zip(keys, combo))
        metrics = run_backtest(params)
        results.append({**params, **metrics})

    df = pd.DataFrame(results)
    df.to_csv("MARK1_OptResults.csv", index=False)
    best = df.sort_values("ProfitFactor", ascending=False).head(5)
    print("Top 5 parameter sets:\n", best.to_string())

if __name__ == "__main__":
    grid_search()
```

---

### FILE 3 — IPDA_Script.py [Item #98]

**Purpose:** Pull D1 EURUSD data from MT5 and compute IPDA 20/40/60 bar ranges externally for cross-validation against the in-EA `CIPDAEngine`.

```python
# IPDA_Script.py
import MetaTrader5 as mt5
import pandas as pd

def get_ipda_ranges(symbol="EURUSD", n_bars=100):
    mt5.initialize()
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_D1, 0, n_bars)
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s")

    for n in [20, 40, 60]:
        df[f"ipda_high_{n}"] = df["high"].rolling(n).max()
        df[f"ipda_low_{n}"]  = df["low"].rolling(n).min()
        df[f"ipda_eq_{n}"]   = (df[f"ipda_high_{n}"] + df[f"ipda_low_{n}"]) / 2

    mt5.shutdown()
    return df[["time", "close",
               "ipda_high_20","ipda_low_20","ipda_eq_20",
               "ipda_high_40","ipda_low_40","ipda_eq_40",
               "ipda_high_60","ipda_low_60","ipda_eq_60"]].tail(5)

if __name__ == "__main__":
    print(get_ipda_ranges().to_string())
```

---

### FILE 4 — SMT_Script.py [Item #99]

**Purpose:** Pull EURUSD and GBPUSD H1 data and detect SMT divergences externally, cross-validating against `CSMTEngine` in the EA.

```python
# SMT_Script.py
import MetaTrader5 as mt5
import pandas as pd

def detect_smt_divergence(tf=mt5.TIMEFRAME_H1, lookback=200):
    mt5.initialize()
    eur = pd.DataFrame(mt5.copy_rates_from_pos("EURUSD", tf, 0, lookback))
    gbp = pd.DataFrame(mt5.copy_rates_from_pos("GBPUSD", tf, 0, lookback))
    mt5.shutdown()

    eur["time"] = pd.to_datetime(eur["time"], unit="s")
    gbp["time"] = pd.to_datetime(gbp["time"], unit="s")

    window = 10
    eur["swing_low"]  = eur["low"].rolling(window).min()
    gbp["swing_low"]  = gbp["low"].rolling(window).min()
    eur["prev_sl"]    = eur["swing_low"].shift(window)
    gbp["prev_sl"]    = gbp["swing_low"].shift(window)

    # Bullish SMT: EUR makes lower low, GBP does NOT
    divergences = eur[
        (eur["swing_low"] < eur["prev_sl"]) &
        (gbp["swing_low"] > gbp["prev_sl"])
    ][["time","swing_low"]].copy()
    divergences["type"] = "BULLISH_SMT"

    print(f"SMT Divergences found: {len(divergences)}")
    print(divergences.tail(10).to_string())
    return divergences

if __name__ == "__main__":
    detect_smt_divergence()
```

---

### PHASE 9 — Validation Checklist
- [ ] All 4 Python scripts run without error: `python ICT_Analytics.py`, etc.
- [ ] IPDA Python values match EA `CIPDAEngine` values within 0.00001 tolerance
- [ ] SMT Python detects same divergences as EA `CSMTEngine` on same date range

---

## FINAL INTEGRATION — POST ALL PHASES

Once all 9 phases are committed and the repo is clean:

### Final Backtest Parameters
```
Symbol:        EURUSD
Timeframe:     M15
Start:         2023-01-02
End:           2023-06-08
Mode:          Every Tick (most precise)
Initial Deposit: $10,000
Leverage:      1:100
```

### Expected v4.0 Performance Targets (vs v3.2 baseline)
| Metric          | v3.2 Baseline| v4.0 Target  |
|-----------------|--------------|--------------|
| Total Trades    | 132          | 180–250      |
| Profit Factor   | 1.88         | ≥ 2.10       |
| Max DD          | 8.48%        | ≤ 8.00%      |
| Win Rate        | ~50%         | ≥ 52%        |

### File Structure After All Phases
```
MARK1/
├── MQL5/
│   ├── Experts/
│   │   └── ICT_EURUSD_EA.mq5       ← Main EA
│   ├── Include/
│   │   ├── ICT_Constants.mqh        ← NEW (Phase 1)
│   │   ├── ICT_Structure.mqh        ← BUG FIX + M1 engine
│   │   ├── ICT_FVG.mqh              ← BUG FIX + Implied FVG
│   │   ├── ICT_OrderBlock.mqh       ← 4 new block types
│   │   ├── ICT_Liquidity.mqh        ← IDM, IRL/ERL, NDOG/NWOG, ROS, DOL
│   │   ├── ICT_Session.mqh          ← EUR fix, Judas SM, ORG, London Close
│   │   ├── ICT_Bias.mqh             ← H1 consensus fix, DOW, weekly/monthly
│   │   ├── ICT_RiskManager.mqh      ← All 4 fixes + 4 new items
│   │   ├── ICT_EntryModels.mqh      ← NEW (Phase 5) — all 6 models
│   │   ├── ICT_IPDA.mqh             ← NEW (Phase 7)
│   │   ├── ICT_SMT.mqh              ← NEW (Phase 7)
│   │   └── ICT_Visualizer.mqh       ← 6 new visual elements
│   └── Files/
│       └── MARK1_Trades.csv         ← Auto-generated by EA
└── Python/
    ├── ICT_Analytics.py
    ├── MARK1_Optimizer.py
    ├── IPDA_Script.py
    └── SMT_Script.py
```

---

*This document covers all 99 items: 45 existing → preserved, 9 bugs → fixed, 41 missing → implemented, 4 partial → completed.*  
*Each phase is a self-contained commit. Do not merge a phase until its checklist passes.*