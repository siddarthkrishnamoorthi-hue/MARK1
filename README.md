# ICT London Sweep + FVG Expert Advisor — MARK1

## Strategy Overview

**Concept:** ICT (Inner Circle Trader) — Judas Swing + Fair Value Gap Retracement  
**Symbol:** EUR/USD  
**Timeframe:** M5 or M15 (recommended M15 for fewer false signals)

### Logic Flow

```
[00:00–07:00 GMT]  →  Build Asian session high/low range
[08:00 GMT]        →  Lock range; London Kill Zone begins
[08:00–11:00 GMT]  →  Watch for Judas Swing (liquidity sweep)
                       - Price breaks ABOVE AsianHigh but CLOSES back inside  → Bearish setup
                       - Price breaks BELOW AsianLow  but CLOSES back inside  → Bullish setup
[Post-sweep]       →  Scan last 3 bars for a Fair Value Gap (FVG)
                       - Bullish FVG : bar[3].low > bar[1].high
                       - Bearish FVG : bar[3].high < bar[1].low
[Entry]            →  Place limit order at FVG midpoint
[Exits]            →  SL = 20 pips beyond the swept extreme
                       TP = 3 × SL distance (1:3 RR)
```

---

## Installation

1. Copy `ICT_LondonSweep_FVG.mq5` to:  
   `MetaTrader 5\MQL5\Experts\`
2. Open MetaEditor → compile (F7) — should show 0 errors, 0 warnings.
3. Drag the EA onto an **EUR/USD M5 or M15** chart.
4. Enable **"Allow Algo Trading"** in MT5.

---

## Input Parameters

| Group | Parameter | Default | Description |
|---|---|---|---|
| Risk Management | `InpRiskPercent` | `0.5` | Risk per trade as % of account balance |
| Risk Management | `InpRRRatio` | `3.0` | Take Profit multiplier (1:3 RR) |
| Risk Management | `InpSLPips` | `20` | Pips beyond sweep extreme for SL |
| Risk Management | `InpMaxOpenTrades` | `2` | Max simultaneous EA positions |
| Session Times | `InpAsianStartHour` | `0` | Asian session open (GMT) |
| Session Times | `InpAsianEndHour` | `7` | Asian session close (GMT) |
| Session Times | `InpLondonStartHour` | `8` | London Kill Zone open (GMT) |
| Session Times | `InpLondonEndHour` | `11` | London Kill Zone close (GMT) |
| Session Times | `InpNYStartHour` | `13` | NY Kill Zone open (GMT) |
| Session Times | `InpNYEndHour` | `16` | NY Kill Zone close (GMT) |
| News Filter | `InpEnableNewsFilter` | `true` | Use economic calendar filter |
| News Filter | `InpNewsHaltBefore` | `30` | Minutes to pause before event |
| News Filter | `InpNewsResumeAfter` | `15` | Minutes to resume after event |
| H4 BOS Filter | `InpEnableH4Filter` | `true` | Require H4 Break of Structure alignment |
| H4 BOS Filter | `InpH4LookbackBars` | `50` | H4 bars to scan for BOS |
| Order Settings | `InpOrderExpiryBars` | `10` | Cancel unfilled limit order after N bars |
| Order Settings | `InpMagicNumber` | `202601` | EA magic number (unique per instance) |
| Debug | `InpDebugLog` | `true` | Print detailed events to Experts log |

---

## News Filter — Enable / Disable

### Option A: Use the MQL5 Calendar (default, recommended for live trading)
- `InpEnableNewsFilter = true`  
- Requires: MT5 account with **economic calendar access** enabled (any standard MetaQuotes account has this).
- For backtesting, `CalendarValueHistory()` works on historical data — no changes needed.

### Option B: Disable the filter entirely
- Set `InpEnableNewsFilter = false`  
- The EA trades through all news events without restriction.

### Option C: Use hardcoded fallback only (no live calendar)
If `CalendarValueHistory()` fails (returns `false`) — e.g., restricted VPS environment — the EA **automatically falls back** to a hardcoded schedule:
- **NFP block:** Every first Friday of the month, 13:00–14:30 GMT  
- **FOMC block:** Every Wednesday 19:00–21:00 GMT during FOMC months (Jan, Mar, May, Jun, Jul, Sep, Nov, Dec)

No code changes required — the fallback activates automatically when the API call fails.

---

## H4 Market Structure Filter

When `InpEnableH4Filter = true`:
- EA scans the **H4 chart** for the two most recent swing highs/lows.
- **Bullish BOS confirmed** if the latest swing high is higher than the prior swing high.
- Bullish limit orders are only placed when H4 BOS is bullish.
- Bearish limit orders are only placed when H4 BOS is bearish (not bullish).

To rely purely on M15 sweep + FVG logic without the H4 filter, set `InpEnableH4Filter = false`.

---

## Backtesting Notes

- All logic runs on **fully closed bars** (`index 1` or higher) — no future-leaking, no repainting.
- `CalendarValueHistory()` supports historical data in Strategy Tester with an active internet connection.
- Use **"Every tick based on real ticks"** or **"Open prices only"** mode.  
  Open prices mode is sufficient and much faster since bar-close logic is used.
- Recommended test period: **2022–present** (sufficient GMT session data).
- Set Strategy Tester symbol to `EURUSD`, timeframe to `M15`.

---

## File Structure

```
MARK1/
├── ICT_LondonSweep_FVG.mq5    ← Main EA source file
└── README.md                   ← This file
```
