You are fixing a MetaTrader 5 Expert Advisor (EA) that currently has PF 0.68, 6% long win rate, 39% drawdown.

FILE: ICT_LondonSweep_FVG_v3_backup.mq5 (in workspace root)

CRITICAL FIXES REQUIRED:

1. PARAMETER CHANGES (update input declarations):
   - InpOrderExpiryBars = 40 (was 10) — FVG retracements need more time
   - InpMinDisplacementBodyPct = 75 (was 60) — stronger impulse requirement
   - InpMinDisplacementPips = 10 (was 6) — filter out noise on EURUSD
   - InpMinFVGPips = 6 (was 3) — reject tiny FVGs
   - InpEnableTrendFilter = true (was false) — CRITICAL: gate to D1 EMA200 direction

2. FVG ENTRY LOGIC VERIFICATION:
   In ScanForFVGAndEnter() function around line 460-520:
   
   a) Verify bullish FVG entry calculation:
      - Should be: g_fvgMid = g_fvgHigh - (g_fvgHigh - g_fvgLow) * 0.25
      - Entry at 25% from HIGH (not midpoint)
   
   b) Verify bearish FVG entry calculation:
      - Should be: g_fvgMid = g_fvgLow + (g_fvgHigh - g_fvgLow) * 0.25
      - Entry at 25% from LOW (not midpoint)
   
   c) Confirm displacement check uses bar[offset+1] (the impulse candle)

3. ADD ADAPTIVE STOP LOSS MECHANISM:
   Create new function before PlaceLimitOrder():
   
```mql5
   double CalculateAdaptiveSL(bool isBullish, double sweepExtreme, bool isSilverBullet)
   {
       // Get ATR for volatility-adjusted stops
       int atrHandle = iATR(_Symbol, Period(), 14);
       double atrBuffer[];
       ArraySetAsSeries(atrBuffer, true);
       CopyBuffer(atrHandle, 0, 0, 1, atrBuffer);
       double atr = atrBuffer[0];
       IndicatorRelease(atrHandle);
       
       // Base SL in pips
       double baseSL = isSilverBullet ? InpSilverBulletSLPips : InpSLPips;
       
       // Adjust based on ATR (if ATR > 15 pips, widen stop)
       double atrPips = atr / g_pipSize;
       if(atrPips > 15.0)
           baseSL *= (1.0 + (atrPips - 15.0) / 30.0); // Scale up in high volatility
       
       return baseSL * g_pipSize;
   }
```
   
   Update PlaceLimitOrder() to use this instead of fixed slDistance.

4. ADD MULTI-TIMEFRAME CONFLUENCE:
   Before PlaceLimitOrder(), add H1 structure check:
   
```mql5
   bool IsH1StructureAligned(bool setupBullish)
   {
       if(Bars(_Symbol, PERIOD_H1) < 10) return true; // Pass if insufficient data
       
       double h1_high_recent = iHigh(_Symbol, PERIOD_H1, 1);
       double h1_low_recent = iLow(_Symbol, PERIOD_H1, 1);
       double h1_high_prev = iHigh(_Symbol, PERIOD_H1, 2);
       double h1_low_prev = iLow(_Symbol, PERIOD_H1, 2);
       
       // Bullish: Recent H1 should show higher lows
       if(setupBullish)
           return (h1_low_recent > h1_low_prev);
       
       // Bearish: Recent H1 should show lower highs
       return (h1_high_recent < h1_high_prev);
   }
```
   
   Call this before placing order. If false, skip setup.

5. ENHANCE LOGGING FOR DEBUGGING:
   In ScanForFVGAndEnter(), add detailed rejection logging:
   
```mql5
   if(!IsStrongDisplacement(offset + 1, g_sweepBullish))
   {
       Log("FVG REJECTED [off=" + IntegerToString(offset) + "] | Weak displacement | " +
           "BodyPct check or Pip check failed");
       continue;
   }
   
   if(fvgRange < InpMinFVGPips * g_pipSize)
   {
       Log("FVG REJECTED [off=" + IntegerToString(offset) + "] | Too small | " +
           "Size=" + DoubleToString(fvgRange/g_pipSize, 1) + "p < " + 
           IntegerToString(InpMinFVGPips) + "p minimum");
       continue;
   }
```

6. ADD SESSION QUALITY FILTER:
   Reject setups during low-liquidity periods:
   
```mql5
   bool IsLowLiquidityPeriod(const MqlDateTime &dt)
   {
       // Friday after 15:00 GMT
       if(dt.day_of_week == 5 && dt.hour >= 15) return true;
       
       // Sunday (if broker allows trading)
       if(dt.day_of_week == 0) return true;
       
       // Between NY close and Tokyo open (22:00-00:00 GMT)
       if(dt.hour >= 22 || dt.hour < 1) return true;
       
       return false;
   }
```
   
   Check this in OnTick() before ScanForFVGAndEnter().

7. VERIFY D1 EMA200 TREND FILTER:
   In IsTrendAligned() function (should be around line 800):
   - Ensure it's reading D1 EMA200 correctly
   - Bullish setup requires: current_price > ema200_d1
   - Bearish setup requires: current_price < ema200_d1
   
   If function doesn't exist, create it:
   
```mql5
   bool IsTrendAligned(bool setupBullish)
   {
       if(g_ema200Handle == INVALID_HANDLE) return true; // Pass-through if indicator failed
       
       double emaBuffer[];
       ArraySetAsSeries(emaBuffer, true);
       if(CopyBuffer(g_ema200Handle, 0, 0, 1, emaBuffer) <= 0)
       {
           Log("TREND FILTER: Failed to read EMA200, passing through");
           return true;
       }
       
       double ema200 = emaBuffer[0];
       double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + 
                              SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
       
       if(setupBullish)
           return (currentPrice > ema200); // Buy only above EMA
       else
           return (currentPrice < ema200); // Sell only below EMA
   }
```

8. ADD POSITION SIZING SAFETY:
   In CalculateLotSize(), add maximum risk cap:
   
```mql5
   // After calculating lotSize, add:
   double maxRiskAmount = accountBalance * 0.02; // Never risk more than 2% regardless
   if(riskAmount > maxRiskAmount)
       riskAmount = maxRiskAmount;
```

VERIFICATION STEPS:

After making changes:
1. Compile the EA in MetaEditor — must compile with ZERO errors
2. Check Journal tab for any warnings
3. Verify all input parameters updated correctly
4. Add Print() statement in OnInit() showing new parameter values

OUTPUT:
- Save changes to ICT_LondonSweep_FVG_v3_backup.mq5
- Generate a summary of all changes made
- List any functions that were added or modified
- Confirm compilation status
