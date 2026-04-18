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
Remove over-filtering
Prevent late market entries
Stabilize risk model

Do not add new features. Only modify as instructed.
