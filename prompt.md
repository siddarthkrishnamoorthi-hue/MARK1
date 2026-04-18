CHANGES NEEDED FOR PF 1.88 BASELINE
1. INPUT PARAMETERS (lines 27-66):
mql5// CHANGE:
input double InpRiskPercent = 0.1;   // Was 0.5
input double InpRRRatio = 3.0;       // Was 2.5
input double InpSLPips = 30.0;       // Was 25.0
input int InpOrderExpiryBars = 10;   // Was 60
input int InpMinDisplacementBodyPct = 60;  // Was 65
input int InpMinDisplacementPips = 6;      // Was 8
input int InpMinFVGPips = 3;               // Was 4
input bool InpEnableTrendFilter = false;   // Was true
2. FVG ENTRY LOGIC (lines 422-424 and 453-455):
DELETE this adaptive logic:
mql5// DELETE lines 422-424:
double entryDepth = 0.5;
if(fvgRange > 8.0 * g_pipSize)       entryDepth = 0.382;
else if(fvgRange < 5.0 * g_pipSize)  entryDepth = 0.618;
g_fvgMid = g_fvgHigh - fvgRange * entryDepth;

// DELETE lines 453-455:
double entryDepth = 0.5;
if(fvgRange > 8.0 * g_pipSize)       entryDepth = 0.382;
else if(fvgRange < 5.0 * g_pipSize)  entryDepth = 0.618;
g_fvgMid = g_fvgLow + fvgRange * entryDepth;
REPLACE with simple midpoint:
mql5// Line 425 (bullish):
g_fvgMid = (g_fvgHigh + g_fvgLow) / 2.0;

// Line 456 (bearish):
g_fvgMid = (g_fvgHigh + g_fvgLow) / 2.0;
3. DISABLE NEW FILTERS in PlaceLimitOrder() (lines 555-571):
COMMENT OUT or DELETE:
mql5// DELETE lines 555-559:
if(!HasMomentumAlignment(g_sweepBullish))
{
   Log("MOMENTUM: Setup rejected, recent bars against direction.");
   g_setupConsumed = true; return;
}

// DELETE lines 566-571:
if(!IsH1StructureAligned(g_sweepBullish))
{
   Log("H1 STRUCTURE: Setup rejected — H1 market structure misaligned.");
   g_setupConsumed = true; return;
}
4. DISABLE LOW LIQUIDITY FILTER (lines 320-325):
COMMENT OUT:
mql5// DELETE lines 320-325:
if(IsLowLiquidityPeriod(gmtDt))
{
   Log("LOW LIQUIDITY: halted.");
   return;
}
5. DISABLE ADAPTIVE SL (line 572):
REPLACE:
mql5// Line 572 - REPLACE:
double slDistance = CalculateAdaptiveSL(g_sweepBullish, g_sweepExtreme, isSilverBullet);

// WITH:
double slPips = isSilverBullet ? InpSilverBulletSLPips : InpSLPips;
double slDistance = slPips * g_pipSize;
6. DISABLE MARKET ENTRY FALLBACK (lines 597-622):
DELETE entire block starting at line 597 (the priceInZone logic).

After applying all changes:

Ensure code compiles without errors
Ensure no unused variables like entryDepth remain
Ensure no duplicate input parameters exist
Ensure all logic flows correctly without early unintended returns

GOAL

These changes are intended to:

Improve trade quality

Replace Midpoint with OTE Entry (BIGGEST EDGE)

Midpoint is safe—but OTE (62%–79%, ideally 70.5%) is where ICT edge actually lives.
Avoids shallow retracements

Fix FVG Timing. Even though you partially fixed it, it’s still fragile.
Upgrade to:
Allow multi-bar FVG formation window AFTER sweep
Modify logic:
After sweep:
Keep scanning for FVG for next N bars
Only kill setup AFTER timeout

Add HTF Bias (REAL FILTER, NOT EMA)

Your EMA filter was actually hurting performance.

❌ Problem:

EMA = lagging → kills good reversals

✅ Replace with simple D1 candle bias:

Add “Displacement Quality Score” (SMART FILTER)

Right now displacement is binary → weak.

✅ Upgrade:

Instead of just pass/fail, score it
Remove over-filtering
Prevent late market entries
Stabilize risk model

mprove Risk Model (THIS BOOSTS PF DIRECTLY)
Current:

Fixed RR = 3.0

Upgrade:

Dynamic RR based on volatility:

double rr = 2.0;

if(fvgRange > 8 * g_pipSize)
   rr = 3.0;
else if(fvgRange < 4 * g_pipSize)
   rr = 2.0;
8. 🛑 Add Partial TP (HUGE PF BOOST)

Instead of full TP:

Close 50% at 1R
Let rest run to 3R

✅ Remove market entry fallback (you already did)
🔥 Add OTE entry (BIGGEST WIN)
⏱️ Fix FVG retry logic
🧠 Add D1 bias
🎯 Improve displacement filter

Do not add new features. Only modify as instructed.
