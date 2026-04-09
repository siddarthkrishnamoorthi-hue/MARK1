# ICT London Sweep + FVG Expert Advisor — MARK1

**Version:** v3.0  
**Concept:** ICT (Inner Circle Trader) — Judas Swing + Fair Value Gap Retracement  
**Symbol:** EUR/USD  
**Timeframe:** M15 (recommended)  
**Purpose:** Capital preservation — engineered for funded/prop firm accounts

---

## Strategy Overview

### Logic Flow

```
[00:00–07:00 GMT]  →  Build Asian session high/low range
[08:00 GMT]        →  Lock range; London Kill Zone begins
[08:00–10:00 GMT]  →  Watch for Judas Swing (liquidity sweep)
                       - Price breaks ABOVE AsianHigh, closes back inside → Bearish setup
                       - Price breaks BELOW AsianLow,  closes back inside → Bullish setup
[Post-sweep]       →  Scan last 3 bars for a Fair Value Gap (FVG)
                       - Bullish FVG : bar[3].low  > bar[1].high  (gap up)
                       - Bearish FVG : bar[3].high < bar[1].low   (gap down)
                       - Displacement candle must be strong: body ≥ 70% of range AND ≥ 8 pips
                       - FVG must be ≥ 5 pips wide
[Entry]            →  Place limit order at 25% edge of the FVG (OTE bias)
                       - Bullish: fvgLow  + (range × 0.25)
                       - Bearish: fvgHigh − (range × 0.25)
[Exits]            →  SL = InpSLPips beyond the swept extreme
                       TP = SL × InpRRRatio  (default 1:3)
[Breakeven]        →  When price reaches 1R profit, SL moves to entry + 1 point
```

---

## Installation

1. Copy `ICT_LondonSweep_FVG.mq5` to:
   `<MT5 data folder>\MQL5\Experts\`
2. Open MetaEditor → compile (F7) — must show **0 errors, 0 warnings**.
3. Drag the EA onto an **EUR/USD M15** chart.
4. Enable **"Allow Algo Trading"** in MT5.

---

## Input Parameters

### Risk Management

| Parameter | Default | Description |
|---|---|---|
| `InpRiskPercent` | `0.5` | Risk per trade as % of account equity |
| `InpRRRatio` | `3.0` | Take profit multiplier (1:3 RR) |
| `InpSLPips` | `30` | Pips beyond swept extreme for stop loss |
| `InpMaxOpenTrades` | `2` | Max simultaneous EA positions |

### Session Times (all GMT)

| Parameter | Default | Description |
|---|---|---|
| `InpAsianStartHour` | `0` | Asian session open |
| `InpAsianEndHour` | `7` | Asian session close / range lock |
| `InpLondonStartHour` | `8` | London Kill Zone open |
| `InpLondonEndHour` | `11` | London Kill Zone close |
| `InpJudasEndHour` | `10` | Latest bar for Judas Swing detection |
| `InpNYStartHour` | `13` | NY Kill Zone open |
| `InpNYEndHour` | `16` | NY Kill Zone close |
| `InpSilverBulletStart` | `15` | Silver Bullet window open |
| `InpSilverBulletEnd` | `16` | Silver Bullet window close |
| `InpSilverBulletSLPips` | `12` | Stop loss pips for Silver Bullet trades |

### News Filter

| Parameter | Default | Description |
|---|---|---|
| `InpEnableNewsFilter` | `true` | Pause trading around high-impact news |
| `InpNewsHaltBefore` | `30` | Minutes to pause before news event |
| `InpNewsResumeAfter` | `15` | Minutes to resume after news event |

### H4 Market Structure Filter

| Parameter | Default | Description |
|---|---|---|
| `InpEnableH4Filter` | `false` | Require H4 Break of Structure alignment |
| `InpH4LookbackBars` | `50` | H4 bars to scan for swing BOS |

### Premium / Discount Filter

| Parameter | Default | Description |
|---|---|---|
| `InpEnablePDFilter` | `false` | Only buy in discount, sell in premium (D1 equilibrium) |

### Weekly Bias Filter

| Parameter | Default | Description |
|---|---|---|
| `InpEnableWeeklyBias` | `false` | Require weekly candle direction alignment |

### Order Block Filter

| Parameter | Default | Description |
|---|---|---|
| `InpEnableOBFilter` | `false` | Require price to be near an Order Block |
| `InpOBProximityPips` | `10` | Max distance from OB to qualify |
| `InpOBMaxAgeHours` | `24` | Discard OBs older than this |

### Strong Displacement Filter (v3.0)

| Parameter | Default | Description |
|---|---|---|
| `InpMinDisplacementBodyPct` | `70` | Displacement candle body must be ≥ this % of its range |
| `InpMinDisplacementPips` | `8` | Displacement candle body must be ≥ this many pips |

### FVG Size Filter (v3.0)

| Parameter | Default | Description |
|---|---|---|
| `InpMinFVGPips` | `5` | FVG gap must be ≥ this many pips to qualify |

### D1 Trend Filter (v3.0)

| Parameter | Default | Description |
|---|---|---|
| `InpEnableTrendFilter` | `true` | Only trade in direction of D1 200 EMA trend |

### Daily Loss Circuit Breaker (v3.0)

| Parameter | Default | Description |
|---|---|---|
| `InpDailyLossLimitPct` | `1.5` | Close all and halt if equity drops this % in one day |

### Consecutive Loss Pause (v3.0)

| Parameter | Default | Description |
|---|---|---|
| `InpMaxConsecLosses` | `3` | Pause trading next full day after this many consecutive losses |

### Order Settings

| Parameter | Default | Description |
|---|---|---|
| `InpOrderExpiryBars` | `10` | Cancel unfilled limit order after N M15 bars |
| `InpMagicNumber` | `202601` | EA identifier — change if running multiple instances |

### Debug

| Parameter | Default | Description |
|---|---|---|
| `InpDebugLog` | `true` | Print detailed event log to Experts tab |

---

## Capital Preservation Features (v3.0)

These features are specifically designed for funded/prop firm accounts where drawdown limits are hard constraints.

| Feature | How it works |
|---|---|
| **Daily Loss Circuit Breaker** | Tracks equity from day open. If floating + realised loss exceeds `InpDailyLossLimitPct`, all positions close and the EA halts for the rest of the day. |
| **Consecutive Loss Pause** | After `InpMaxConsecLosses` back-to-back losing trades, the EA skips the entire following trading day. Resets automatically at midnight. |
| **Breakeven at 1R** | Once a trade moves `1 × initial risk` in profit, SL is moved to entry + 1 point, locking the trade risk-free. |
| **D1 Trend Filter** | Compares D1 close to D1 200 EMA. Bullish setups only when close > EMA200; bearish only when close < EMA200. Reduces counter-trend trades. |
| **Strong Displacement Filter** | Rejects FVGs formed by weak candles — body must be ≥ 70% of candle range AND ≥ 8 pips. Ensures the FVG has institutional backing. |
| **FVG Size Filter** | Rejects tiny gaps (< 5 pips). Micro FVGs have poor fill rates and risk/reward. |
| **OTE Entry at 25% Edge** | Enters at the near edge of the FVG (25% in) rather than midpoint, reducing exposure while maintaining high fill probability at the manipulation level. |

---

## News Filter Details

**Option A — MQL5 Calendar (default):**  
`InpEnableNewsFilter = true` — requires MT5 with economic calendar access (standard on any MetaQuotes account). Works in backtesting via `CalendarValueHistory()` with an active internet connection.

**Option B — Disabled:**  
`InpEnableNewsFilter = false` — EA trades through all news without restriction.

**Option C — Hardcoded fallback:**  
If `CalendarValueHistory()` fails (restricted VPS), the EA automatically falls back to:
- NFP block: first Friday of every month, 13:00–14:30 GMT
- FOMC block: Wednesdays 19:00–21:00 GMT in FOMC months (Jan, Mar, May, Jun, Jul, Sep, Nov, Dec)

No configuration needed — fallback activates automatically.

---

## H4 Market Structure Filter

When `InpEnableH4Filter = true`, the EA scans the last `InpH4LookbackBars` H4 bars for the two most recent swing highs and lows. A bullish Break of Structure (higher high than the prior swing high) is required for bullish limit orders, and bearish BOS for bearish orders. Disable to rely on M15 sweep + FVG logic alone.

---

## Backtesting Recommended Settings

| Setting | Value |
|---|---|
| Symbol | EURUSD |
| Timeframe | M15 |
| Model | Every tick based on real ticks |
| Period | 2022–present |
| `InpRiskPercent` | `0.1` (conservative for analysis) |
| `InpEnableTrendFilter` | `true` |
| `InpEnableH4Filter` | `false` (baseline) |
| `InpDailyLossLimitPct` | `1.5` |
| `InpMinFVGPips` | `5` |
| `InpMinDisplacementPips` | `8` |
| `InpMaxConsecLosses` | `3` |

Target metrics for funded accounts: Profit Factor > 2.0, Max DD < 5%, Win Rate > 40%.

---

## File Structure

```
MARK1/
├── ICT_LondonSweep_FVG.mq5    ← Main EA source (all logic in single file)
└── README.md                   ← This file
```

---

## Planned Enhancements

| # | Feature | Target | Notes |
|---|---|---|---|
| 1 | **Consequent Encroachment (CE) of Order Blocks** | v3.1 | Enter at 50% of OB candle body (`(open+close)/2`) instead of full zone edge. More precise ICT entry. |
| 2 | **OTE via Fibonacci** | v3.1 | Shift entry to 62–79% retracement of the displacement swing leg (70.5% midpoint). Toggle via `InpUseOTEEntry`. |
| 3 | **SMT Divergence** | v4.0 | EUR/USD vs GBP/USD sweep divergence confirmation. Requires secondary symbol feed (`iHigh`/`iLow` on GBPUSD). High-confidence filter; needs sweep-context guard against false positives. |
| 4 | **Market Maker Models (MMXM/W/M)** | v4.0 | 3-leg accumulation → manipulation → distribution pattern on H1/H4. Requires swing-point classification logic. Very parameter-sensitive; validate thoroughly before live use. |
