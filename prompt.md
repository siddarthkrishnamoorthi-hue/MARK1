File: ICT_LondonSweep_FVG_v3_backup.mq5

CRITICAL DIAGNOSIS: EA filters valid setups but enters at wrong price levels, causing 75-87% of trades to hit SL. The 25% entry point is being rejected by market structure.

CORE FIX - DYNAMIC FVG ENTRY:

1. REPLACE STATIC 25% ENTRY with MARKET-ADAPTIVE:
   
   In ScanForFVGAndEnter(), change FVG entry logic:
   
```mql5
   // OLD (delete):
   // g_fvgMid = g_fvgHigh - fvgRange * 0.25;  // Bullish
   // g_fvgMid = g_fvgLow + fvgRange * 0.25;   // Bearish
   
   // NEW (adaptive entry based on FVG size):
   double entryDepth = 0.5; // Start at 50% (midpoint)
   
   // If FVG is large (>8 pips), can afford deeper entry
   if(fvgRange > 8.0 * g_pipSize)
       entryDepth = 0.382; // 38.2% Fibonacci retracement
   
   // If FVG is small (3-5 pips), stay shallow to avoid missing fill
   else if(fvgRange < 5.0 * g_pipSize)
       entryDepth = 0.618; // 61.8% into the zone
   
   if(g_sweepBullish)
       g_fvgMid = g_fvgHigh - fvgRange * entryDepth;
   else
       g_fvgMid = g_fvgLow + fvgRange * entryDepth;
```

2. ADD IMMEDIATE ENTRY FALLBACK:
   
   After limit order placement, check if price already in FVG:
   
```mql5
   // In PlaceLimitOrder(), after calculating entryPrice, ADD:
   
   double currentPrice = (g_sweepBullish ? 
       SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
       SymbolInfoDouble(_Symbol, SYMBOL_BID));
   
   // If price already swept through FVG zone, enter at market
   bool priceInZone = false;
   if(g_sweepBullish)
       priceInZone = (currentPrice >= g_fvgLow && currentPrice <= entryPrice);
   else
       priceInZone = (currentPrice <= g_fvgHigh && currentPrice >= entryPrice);
   
   if(priceInZone)
   {
       // Use MARKET order instead of LIMIT
       orderType = g_sweepBullish ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
       entryPrice = currentPrice;
       
       // Place market order immediately
       result = g_sweepBullish ?
           g_trade.Buy(lotSize, _Symbol, 0, slPrice, tpPrice, "ICT-FVG Market Buy") :
           g_trade.Sell(lotSize, _Symbol, 0, slPrice, tpPrice, "ICT-FVG Market Sell");
       
       Log("MARKET ENTRY: Price already in FVG zone");
       return;
   }
```

3. RELAX DISPLACEMENT FILTER (currently rejecting valid impulse):
   
   Change inputs:
```mql5
   input int InpMinDisplacementBodyPct = 65; // Was 75, too strict
   input int InpMinDisplacementPips = 8;     // Was 10, missing smaller valid moves
```

4. EXTEND ORDER LIFETIME (price needs more time to retrace):
   
```mql5
   input int InpOrderExpiryBars = 60; // Was 40, still expiring too soon
```

5. ADD MOMENTUM CONFIRMATION (prevent counter-trend entries):
   
   Create new function before PlaceLimitOrder():
   
```mql5
   bool HasMomentumAlignment(bool setupBullish)
   {
       // Check last 3 M15 closes support direction
       int bullishBars = 0;
       for(int i = 1; i <= 3; i++)
       {
           double open = iOpen(_Symbol, Period(), i);
           double close = iClose(_Symbol, Period(), i);
           if(close > open) bullishBars++;
       }
       
       if(setupBullish)
           return (bullishBars >= 2); // Need 2/3 bullish bars for buy
       else
           return (bullishBars <= 1); // Need 2/3 bearish bars for sell
   }
```
   
   Call in PlaceLimitOrder() BEFORE trend filter:
```mql5
   if(!HasMomentumAlignment(g_sweepBullish))
   {
       Log("MOMENTUM: Setup rejected, recent bars against direction");
       g_setupConsumed = true; return;
   }
```

6. FIX TREND FILTER LOGIC (may be inverted):
   
   In IsTrendAligned() verify:
```mql5
   // Should use CLOSE price, not mid-price
   double closeD1_current = iClose(_Symbol, PERIOD_D1, 0);
   
   if(setupBullish)
       return (closeD1_current > ema200); // Correct
   else
       return (closeD1_current < ema200); // Correct
```

7. OPTIMIZE PARAMETERS:
   
```mql5
   input double InpRRRatio = 2.5;        // Was 3.0, too ambitious
   input double InpSLPips = 25.0;        // Was 30, too wide
   input int InpMinFVGPips = 4;          // Was 6, missing smaller valid FVGs
   input bool InpEnableTrendFilter = true; // Keep enabled
```

COMPILE → Test Jan 2024 - Apr 2026 → Report:
- Profit Factor
- Win Rate % (target: >40%)
- Total Trades (target: 30-50)
- Max DD % (target: <18%)

ANALYSIS
Progress: PF 0.68→1.05 ✅ | DD 39%→21% ✅ | Trades 42→16 ❌
Problem: Filters TOO strict now. 16 trades in 2+ years = missed opportunities.
Root Issue: Win rate 12.5% long / 25% short = entry timing wrong, not filter problem.
