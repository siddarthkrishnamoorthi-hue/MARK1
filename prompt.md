The six bugs ranked by damage
Bug 1 — H4 BOS kills all buy trades (most damaging)
IsH4BullishBOS() requires the most recent H4 swing high to be higher than the previous one. EURUSD spent much of 2024–2026 in a broad downtrend or range, so H4 was never printing clean higher-highs during London session. Every single bullish Judas setup got rejected here. This is why you have 0 buy trades. The filter is conceptually correct — you want directional bias alignment — but it's too tightly coupled to the macro trend rather than the local session structure.
Bug 2 — FVG scan looks at only 3 bars (45 minutes on M15)
This is the single biggest trade-killer. ScanForFVGAndEnter() checks high[1] vs high[3] and low[1] vs low[3] — literally only the last three candles. After a Judas sweep, price usually needs 5–15 bars to print the impulse move that creates the FVG. By the time the gap is obvious and clean, it's already 45–120 minutes old and your function can't see it. You're missing probably 80%+ of valid FVG setups just from this.
Bug 3 — g_setupConsumed prevents all same-day retries
Every filter rejection — H4, premium/discount, news, price check — immediately sets g_setupConsumed = true. So if H4 BOS rejects a 9:00 AM setup, the EA is completely blind for the rest of the day even if a perfect FVG prints at 2:00 PM in NY session with ideal structure. This flag should only be set when you actually place an order or make a deliberate "skip this entire day" decision. Remove it from all filter-rejection return paths.
Bug 4 — Kill zone gate closes before FVG can form
The OnTick() gate if(!(inLondon || inNY || inSilverBullet)) return exits early between sessions. A London sweep at 10:45 AM followed by an FVG forming at 11:15 AM (just outside the London window) never gets caught. ICT setups don't care about session boundaries after the sweep is established — the FVG is valid until price trades through it from the other side.
Bug 5 — Silver Bullet is conceptually misimplemented
The Silver Bullet at 15:00–16:00 GMT currently calls DetectJudasSwing() and compares against the 8-hour-old Asian range. That's not what Silver Bullet is. Correctly, SB should identify a fresh local liquidity pool from the NY morning (13:00–15:00 GMT), watch for a sweep of that pool in the 15:00–16:00 window, then look for an FVG in the 1-hour move. Trade 1 happened to work because price re-swept the Asian range at that time, but this is coincidental.
Bug 6 — Order expiry + SL too tight
10 bars = 150 minutes on M15. A London sweep order placed at 10:00 AM expires by 12:30 PM and never sees the NY open retracement. Set InpOrderExpiryBars = 25–30. The 20-pip SL is also tight for EURUSD — common wick extensions on M15 are 25–35 pips, so you'd get stopped before entry on fast days.

The fix sequence
Do this first (trade frequency):

In ScanForFVGAndEnter(), replace the single bar[1]/bar[3] check with a loop from i=1 to i=13, checking high[i+2] < low[i] (bullish FVG) or low[i+2] > high[i] (bearish FVG). Take the most recently formed gap.
Remove g_setupConsumed = true from all filter rejection return statements. Add a g_lastRejectBar datetime guard to prevent re-firing on the same bar.
Set InpEnableH4Filter = false temporarily. Run the backtest — you'll see how many setups now appear without it. Then replace it with a simpler iClose(PERIOD_H4, 1) > iMA(PERIOD_H4, 50) check instead of the swing-structure BOS.
Set InpOrderExpiryBars = 25 and InpSLPips = 25.

5. After g_sweepDetected = true, allow ScanForFVGAndEnter() to keep running until 21:00 GMT regardless of inLondon/inNY flags.
6. Rewrite Silver Bullet as a separate state machine: collect local NY morning range (13:00–15:00 GMT), detect sweep in SB window, scan for FVG in that window's bars.
7. Enable InpEnablePDFilter and InpEnableWeeklyBias — these are already correctly coded, they just need to be switched on once your trade frequency is healthy.
8. Add a full AMD (Accumulation–Manipulation–Distribution) model for the NY session with its own sweep detection separate from the London Judas logic.
