next step, turn this into a strict severity-ranked bug list with exact fix order.

I want this project to be a strict, pure ICT logic.

I want to Refactor this project to “True ICT Execution Pipeline” (institution-grade).

the final push for my EA is narrative + context + execution timing, “structured probabilistic behavior inspired by ICT”

=======================================================
## Pending Feature Updates & Enhancements
> Status as of 2026-04-25 — Post full codebase audit (Session 6)
> All items below are validated design issues or deferred enhancements.
> Fix in priority order: Critical → High → Medium → Enhancement.

---

### CRITICAL — Structural Logic (Affects Trade Quality)

#### 1. ICT_Structure — Swing Alternation Enforcement
**Area:** `ICT_Structure.mqh` — `Refresh()`, `ClassifyHigh()`, `ClassifyLow()`
**Issue:** The engine builds `m_swingHighs[]` and `m_swingLows[]` arrays independently with no
enforcement that swings alternate H→L→H→L. Two consecutive highs or two consecutive lows can
enter the arrays, corrupting `ResolveBias()` and all BOS/CHoCH/MSS classifications downstream.
**Required Fix:**
- Replace independent `ArrayResize/Append` with an interleaved detection pass.
- After detecting a swing point, only accept it if it is the opposite type to the last accepted swing.
- Maintain a single `m_lastSwingWasHigh` flag. If `IsSwingHigh()` triggers but last accepted was also
  a high, update the existing high if the new one is more extreme — do not append.
- Same rule for lows.
**Why architecture change:** Both arrays must be restructured or a merged chronological array
`m_swings[]` of type `ICTSwingPoint` must replace the two separate arrays. All callers
(`GetSwingHigh`, `GetSwingLow`, `BuildSnapshot`, `GetLatestBreakSignal`) must be updated.

---

#### 2. ICT_Structure — `ClassifyHigh`/`ClassifyLow` Context Blindness
**Area:** `ICT_Structure.mqh` — `ClassifyHigh()` line ~261, `ClassifyLow()` line ~271
**Issue:** Both functions compare a new swing **only to the immediately prior swing** of the same type.
This produces correct labels in trending markets but incorrect labels when two swings are not
contiguous in the structural sequence (e.g., after a range break inserts a counter-swing).
**Required Fix:**
- After fix #1 (alternation), classification automatically becomes correct because each new high is
  always compared to the last confirmed high in a properly alternating sequence.
- As a standalone fix: scan backwards through `m_swingHighs` to find the most recent swing that
  has a confirmed intervening low between it and the new candidate. Use that as the comparator.

---

### HIGH — Entry Model Quality

#### 3. ICT_EntryModels — TurtleSoup IDM Direction Pre-Guessed
**Area:** `ICT_EntryModels.mqh` — `CTurtleSoupModel`, IDM gate ~line 432
**Issue:** The IDM check is run with direction `(bullish ? -1 : 1)` before the actual TurtleSoup
setup is detected. The consensus bias determines `bullish`, but the TurtleSoup model is a
**reversal** model — the actual trade direction is the **opposite** of the continuation bias.
This can result in the IDM gate being checked for the wrong direction, allowing a setup to pass
when the correct directional IDM has not been swept.
**Required Fix:**
- Restructure the model so IDM is checked **after** the reversal setup is detected and the actual
  fade direction is confirmed.
- The IDM gate should use `ctx.reversalBullish` (the fade direction) not `!ctx.biasBullish`.

---

### HIGH — IPDA/SMT Trade Integration

#### 4. IPDA Integration into Trade Decisions
**Area:** `ICT_EURUSD_EA.mq5` — `BuildSetupCandidate()`; `ICT_IPDA.mqh`
**Issue:** IPDA 20/40/60-bar D1 ranges are computed and drawn but have **zero influence on
entry decisions**. Per ICT, price at the equilibrium of an IPDA range is "seeking direction"
and should not trigger entries; price at the discount of an IPDA range is a high-probability long zone.
**Required Fix (from Enhancement #1 of roadmap):**
- In `BuildSetupCandidate()`, retrieve `g_ipda.GetRange()`.
- Add gate: if entry price is within 5 pips of `ipdaRange.eq20`, skip setup (equilibrium — no edge).
- Add confluence: if bullish and entry is within 10 pips of `ipdaRange.low20`, add `+1` to
  `setup.confluenceScore` (price at IPDA discount = institutional accumulation zone).
- Same logic inverted for bearish setups at `ipdaRange.high20`.

---

#### 5. SMT Divergence Integration into Trade Decisions
**Area:** `ICT_EURUSD_EA.mq5` — `BuildSetupCandidate()`; `ICT_SMT.mqh`
**Issue:** SMT divergence is computed on every H1 bar and drawn on the chart but is not used
as a filter or confluence factor in any entry decision.
**Required Fix (from Enhancement #2 of roadmap):**
- After `g_smt.Scan()`, retrieve `g_smt.GetDivergence()` in `BuildSetupCandidate()` or in the
  main setup pipeline.
- If `smtDiv.isBullishSMT && bullish` → add `+1` to `confluenceScore` (correlated divergence confirms).
- If `smtDiv.isBearishSMT && !bullish` → add `+1` to `confluenceScore`.
- Optionally: if SMT signal opposes the trade direction, subtract `−1` or reject outright.

---

### MEDIUM — Bias & Context Accuracy

#### 6. Weekly/Monthly Bias — Replace Single-Candle with Structure
**Area:** `ICT_Bias.mqh` — `ResolveWeeklyBias()` ~line 300, `ResolveMonthlyBias()` ~line 308
**Issue:** Both functions return bias based purely on `close > open` of the prior completed
W1/MN1 candle. A single candle with body direction is **not** ICT weekly bias methodology.
ICT defines weekly bias from the W1 structure: HH+HL = bullish, LH+LL = bearish, mixed = neutral.
**Required Fix (from Enhancement #4 of roadmap):**
- Add W1 and MN1 `CICTStructureEngine` instances (already exists for H4/H1/M15/M5/M1).
- `ResolveWeeklyBias()`: call `g_structureW1.BuildSnapshot()` and derive bias from `snapshot.bias`.
- `ResolveMonthlyBias()`: same with `g_structureMN1`.
- Return `ICT_SESSION_BIAS_NEUTRAL` when W1 structure bias is `ICT_BIAS_RANGE`.
- Wire new engines into `ICT_Bias.mqh::Configure()` and `ICT_EURUSD_EA.mq5::OnInit()`.

---

### LOW — Logging & Diagnostics

#### 7. RiskManager CSV — Fix `pnlPips` and Missing TP Fields
**Area:** `ICT_RiskManager.mqh` — `LogTradeToCSV()`, `OnTradeClosed()` ~line 563
**Issue 1:** `rec.pnlPips` is computed as `DEAL_PROFIT / lotSize / 10.0` — this is a
currency/size ratio, not a pip count. On accounts with different currencies or lotting, it
produces meaningless values.
**Fix:** `rec.pnlPips = (closePrice - entryPrice) / pipSize * (bullish ? 1.0 : -1.0)`
**Issue 2:** `rec.tp2` and `rec.tp3` remain zero in the CSV because only `DEAL_TP` (TP1) is
read from deal history. TP2/TP3 are stored in deal comments or in `m_pendingStates`.
**Fix:** Extract `tp2`/`tp3` from the matching `ICTPendingTargetState` before it is cleaned up,
or encode them in the order comment string at placement and parse on close.

---

### LOW — Cosmetic / Chart Display

#### 8. Visualizer — `TimeCurrent()` vs `TimeGMT()` Inconsistency
**Area:** `ICT_Visualizer.mqh` — `DrawOrderBlock()` ~line 193, `DrawFVG()` ~line 203, `DrawBPR()` ~line 217
**Issue:** Rectangle right-edge timestamps use `TimeCurrent()` while all analytical engines
(IPDA, SMT, Session) use `TimeGMT()`. On brokers with non-GMT server time, zone display boxes
appear shifted right on the chart.
**Fix:** Replace `TimeCurrent()` with `TimeGMT()` in all three `ObjectCreate` rectangle calls.
This is cosmetic — it does not affect trade logic.

---

### Summary Table

| # | Area | Severity | Effort |
|---|------|----------|--------|
| 1 | ICT_Structure alternation enforcement | Critical | High (architecture) |
| 2 | ICT_Structure ClassifyHigh/Low context | Critical | Medium (after #1) |
| 3 | TurtleSoup IDM direction fix | High | Low |
| 4 | IPDA integration into trade decisions | High | Low |
| 5 | SMT confluence scoring | High | Low |
| 6 | Weekly/Monthly bias from structure | Medium | Medium |
| 7 | RiskManager CSV pnlPips + tp2/tp3 | Low | Low |
| 8 | Visualizer TimeCurrent → TimeGMT | Low | Trivial |
