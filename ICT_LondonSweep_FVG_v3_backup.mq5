//+------------------------------------------------------------------+
//|  ICT_LondonSweep_FVG.mq5                                         |
//|  London Open Asian Sweep + Fair Value Gap EA  v3.1               |
//|  ICT Concepts: Judas Swing, FVG, D1 Trend, Capital Preservation  |
//|  Works on: EUR/USD M5 or M15                                      |
//+------------------------------------------------------------------+
#property copyright   "ICT EA – MARK1"
#property version     "3.10"
#property strict

enum ENUM_OB_STATE
{
   OB_NONE      = 0,
   OB_UNTESTED  = 1,
   OB_MITIGATED = 2,
   OB_BREAKER   = 3
};

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

input group "=== Risk Management ==="
input double InpRiskPercent            = 0.5;   // Risk per trade (% of balance)
input double InpRRRatio                = 3.0;   // Take Profit RR ratio
input double InpSLPips                 = 30.0;  // Stop Loss in pips beyond sweep
input int    InpMaxOpenTrades          = 2;     // Maximum simultaneous open positions

input group "=== Session Times (GMT) ==="
input int    InpAsianStartHour         = 0;     // Asian range start (GMT)
input int    InpAsianEndHour           = 7;     // Asian range end (GMT)
input int    InpLondonStartHour        = 8;     // London Kill Zone start (GMT)
input int    InpLondonEndHour          = 11;    // London Kill Zone end (GMT)
input int    InpJudasEndHour           = 10;    // Judas Swing ceiling — 08:00–10:00 GMT
input int    InpNYStartHour            = 13;    // NY Kill Zone start (GMT)
input int    InpNYEndHour              = 16;    // NY Kill Zone end (GMT)
input int    InpSilverBulletStart      = 15;    // Silver Bullet start (GMT)
input int    InpSilverBulletEnd        = 16;    // Silver Bullet end (GMT)
input double InpSilverBulletSLPips     = 12.0;  // Silver Bullet SL in pips

input group "=== News Filter ==="
input bool   InpEnableNewsFilter       = true;  // Enable high-impact news filter
input int    InpNewsHaltBefore         = 30;    // Halt minutes before event
input int    InpNewsResumeAfter        = 15;    // Resume minutes after event

input group "=== H4 Market Structure ==="
input bool   InpEnableH4Filter         = false; // Require H4 BOS alignment
input int    InpH4LookbackBars         = 50;    // H4 bars to scan for BOS

input group "=== Premium / Discount Filter ==="
input bool   InpEnablePDFilter         = false; // Enforce D1 discount/premium zone

input group "=== Weekly Bias Filter ==="
input bool   InpEnableWeeklyBias       = false; // Filter by W1 directional bias

input group "=== Order Block Settings ==="
input bool   InpEnableOBFilter         = false; // Require OB alignment before entry
input double InpOBProximityPips        = 10.0;  // Max distance from OB zone
input int    InpOBMaxAgeHours          = 24;    // Discard OBs older than N hours

input group "=== Order Settings ==="
input int    InpOrderExpiryBars        = 40;    // Expire pending order after N bars
input int    InpMagicNumber            = 202601;

input group "=== Strong Displacement Filter ==="
input int    InpMinDisplacementBodyPct = 75;    // Min body as % of bar range
input int    InpMinDisplacementPips    = 10;    // Min body size in pips

input group "=== FVG Settings ==="
input int    InpFVGScanBars            = 5;     // Rolling window bars to search for FVG after sweep
input int    InpMinFVGPips             = 6;     // Minimum FVG gap in pips

input group "=== D1 Trend Filter ==="
input bool   InpEnableTrendFilter      = true;  // Gate entries to D1 200 EMA direction

input group "=== Daily Loss Circuit Breaker ==="
input double InpDailyLossLimitPct      = 1.5;   // Daily equity drawdown % to halt

input group "=== Consecutive Loss Pause ==="
input int    InpMaxConsecLosses        = 4;     // Pause next day after N straight losses

input group "=== Debug ==="
input bool   InpDebugLog               = true;  // Enable verbose logging

CTrade         g_trade;
CPositionInfo  g_position;
COrderInfo     g_order;
double   g_asianHigh        = 0.0;
double   g_asianLow         = 0.0;
bool     g_asianRangeSet    = false;
datetime g_asianRangeDate   = 0;
bool     g_sweepDetected    = false;
bool     g_sweepBullish     = false;
double   g_sweepExtreme     = 0.0;
datetime g_sweepTime        = 0;
bool     g_fvgFormed        = false;
double   g_fvgHigh          = 0.0;
double   g_fvgLow           = 0.0;
double   g_fvgMid           = 0.0;
bool     g_setupConsumed    = false;

ulong    g_pendingTicket    = 0;
int      g_pendingBarCount  = 0;

bool     g_weeklyBullish    = false;
datetime g_weeklyBiasDate   = 0;

double   g_d1Equilibrium    = 0.0;

ENUM_OB_STATE g_obState     = OB_NONE;
double   g_obHigh           = 0.0;
double   g_obLow            = 0.0;
bool     g_obBullish        = false;
datetime g_obTime           = 0;

int      g_gmtOffset        = 0;
double   g_pipSize          = 0.0;
datetime g_lastBarTime      = 0;

int      g_ema200Handle       = INVALID_HANDLE;
int      g_atrHandle          = INVALID_HANDLE;

double   g_dailyStartBalance  = 0.0;
bool     g_dailyLimitHit      = false;
datetime g_lastResetDay       = 0;

int      g_consecutiveLosses  = 0;
datetime g_pauseUntilDay      = 0;

//+------------------------------------------------------------------+
//| Logging Helper                                                     |
//+------------------------------------------------------------------+
void Log(const string msg)
{
   if(InpDebugLog)
      Print("[ICT-EA] ", msg);
}

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(Symbol(), "EURUSD") < 0)
      Print("[ICT-EA] WARNING: EA designed for EURUSD. Current: ", Symbol());

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   g_pipSize  = (digits == 3 || digits == 5)
              ? SymbolInfoDouble(Symbol(), SYMBOL_POINT) * 10.0
              : SymbolInfoDouble(Symbol(), SYMBOL_POINT);

   if(InpFVGScanBars < 3)
   {
      Print("[ICT-EA] INIT ERROR: InpFVGScanBars must be >= 3. Got: ", InpFVGScanBars);
      return INIT_PARAMETERS_INCORRECT;
   }

   g_gmtOffset     = CalculateGMTOffset();
   g_asianRangeDate = GetGMTTime() - 86400;
   g_lastBarTime   = (datetime)SeriesInfoInteger(Symbol(), Period(), SERIES_LASTBAR_DATE);

   UpdateD1Equilibrium();
   UpdateWeeklyBias();

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   g_ema200Handle = iMA(_Symbol, PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(g_ema200Handle == INVALID_HANDLE)
      Print("[ICT-EA] WARNING: Failed to create D1 EMA200 handle. Trend filter will pass-through.");

   g_atrHandle = iATR(_Symbol, Period(), 14);
   if(g_atrHandle == INVALID_HANDLE)
      Print("[ICT-EA] WARNING: Failed to create ATR(14) handle. Adaptive SL will use base value.");

   g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_lastResetDay      = TimeCurrent();
   g_dailyLimitHit     = false;

   Log("EA Init v3.10 | Pip=" + DoubleToString(g_pipSize, _Digits) +
       " Risk=" + DoubleToString(InpRiskPercent, 1) + "%" +
       " TrendFilter=" + (InpEnableTrendFilter ? "ON" : "OFF") +
       " DailyLimit=" + DoubleToString(InpDailyLossLimitPct, 1) + "%");

   Print("[ICT-EA] PARAMS | ExpiryBars=", InpOrderExpiryBars,
         " | MinBodyPct=", InpMinDisplacementBodyPct, "%",
         " | MinDisplPips=", InpMinDisplacementPips,
         " | MinFVGPips=", InpMinFVGPips,
         " | TrendFilter=", (InpEnableTrendFilter ? "ON" : "OFF"),
         " | RiskPct=", InpRiskPercent);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_ema200Handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_ema200Handle);
      g_ema200Handle = INVALID_HANDLE;
   }
   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }
   Log("EA Deinitialised. Reason=" + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBarTime = (datetime)SeriesInfoInteger(Symbol(), Period(), SERIES_LASTBAR_DATE);
   if(currentBarTime == 0 || currentBarTime == g_lastBarTime)
      return;
   g_lastBarTime = currentBarTime;

   datetime gmtTime = GetGMTTime();
   MqlDateTime gmtDt;
   TimeToStruct(gmtTime, gmtDt);

   // Daily balance snapshot reset — use GMT so this fires at the same
   // midnight boundary as ResetDailyState(), not at server-local midnight.
   {
      MqlDateTime nowDt, prevDt;
      TimeToStruct(GetGMTTime(), nowDt);
      TimeToStruct(g_lastResetDay, prevDt);
      if(nowDt.year != prevDt.year || nowDt.mon != prevDt.mon || nowDt.day != prevDt.day)
      {
         g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         g_dailyLimitHit     = false;
         g_lastResetDay      = GetGMTTime();
         Log("Daily CB reset. StartBalance=" + DoubleToString(g_dailyStartBalance, 2));
      }
   }
   if(!g_dailyLimitHit && g_dailyStartBalance > 0.0)
   {
      double equity           = AccountInfoDouble(ACCOUNT_EQUITY);
      double dailyDrawdownPct = (g_dailyStartBalance - equity) / g_dailyStartBalance * 100.0;
      if(dailyDrawdownPct >= InpDailyLossLimitPct)
      {
         g_dailyLimitHit = true;
         CloseAllPositions();
         Log("!!! DAILY LOSS LIMIT BREACHED: " + DoubleToString(dailyDrawdownPct, 2) +
             "% >= " + DoubleToString(InpDailyLossLimitPct, 2) +
             "% — TRADING HALTED FOR TODAY !!!");
      }
   }
   if(g_dailyLimitHit) return;
   if(g_pauseUntilDay > 0 && TimeCurrent() < g_pauseUntilDay)
      return;
   ManagePendingOrders();
   ManageOpenPositions();
   if(IsNewTradingDay(gmtTime))
   {
      ResetDailyState(gmtTime);
      UpdateD1Equilibrium();
      Log("New day | " + TimeToString(gmtTime, TIME_DATE) +
          " D1_Eq=" + DoubleToString(g_d1Equilibrium, _Digits));
   }
   UpdateWeeklyBiasIfMonday(gmtDt);
   if(IsInAsianSession(gmtDt) && !g_asianRangeSet)
   {
      UpdateAsianRange();
   }
   if(gmtDt.hour >= InpLondonStartHour && !g_asianRangeSet && g_asianHigh > 0)
   {
      g_asianRangeSet = true;
      Log("Asian Range LOCKED | High=" + DoubleToString(g_asianHigh, _Digits) +
          " | Low=" + DoubleToString(g_asianLow, _Digits));
   }
   bool inLondon       = IsInLondonKillZone(gmtDt);
   bool inNY           = IsInNYKillZone(gmtDt);
   bool inSilverBullet = IsInSilverBulletWindow(gmtDt);

   if(!(inLondon || inNY || inSilverBullet) || !g_asianRangeSet)
      return;

   if(InpEnableNewsFilter && IsNewsTime(gmtTime))
   {
      Log("NEWS FILTER: halted.");
      return;
   }

   if(IsLowLiquidityPeriod(gmtDt))
   {
      Log("LOW LIQUIDITY: halted.");
      return;
   }

   if(CountOpenPositions() >= InpMaxOpenTrades)
      return;
   if(!g_sweepDetected)
   {
      bool inJudasWindow = inLondon && (gmtDt.hour < InpJudasEndHour);
      if(inJudasWindow || inSilverBullet)
         DetectJudasSwing();
   }
   if(g_sweepDetected && !g_setupConsumed && g_pendingTicket == 0)
      ScanForFVGAndEnter(inSilverBullet);
}

//+------------------------------------------------------------------+
//| UpdateAsianRange / DetectJudasSwing                               |
//+------------------------------------------------------------------+

void UpdateAsianRange()
{
   double highVal = iHigh(Symbol(), Period(), 1);
   double lowVal  = iLow(Symbol(), Period(), 1);

   if(g_asianHigh == 0.0 || highVal > g_asianHigh)
      g_asianHigh = highVal;

   if(g_asianLow == 0.0 || lowVal < g_asianLow)
      g_asianLow = lowVal;
}

// Judas Swing: London-open fake breakout sweeping Asian BSL or SSL,
// with price closing back inside the range. 08:00-10:00 GMT window.
void DetectJudasSwing()
{
   double closePrice = iClose(Symbol(), Period(), 1);
   double highPrice  = iHigh(Symbol(), Period(), 1);
   double lowPrice   = iLow(Symbol(), Period(), 1);

   if(highPrice > g_asianHigh && closePrice < g_asianHigh && closePrice > g_asianLow)
   {
      g_sweepDetected = true;
      g_sweepBullish  = false;
      g_sweepExtreme  = highPrice;
      g_sweepTime     = iTime(Symbol(), Period(), 1);
      Log("BEARISH JUDAS SWING | AsianHigh=" + DoubleToString(g_asianHigh, _Digits) +
          " | SweepHigh=" + DoubleToString(highPrice, _Digits) +
          " | Close=" + DoubleToString(closePrice, _Digits));
   }
   else if(lowPrice < g_asianLow && closePrice > g_asianLow && closePrice < g_asianHigh)
   {
      g_sweepDetected = true;
      g_sweepBullish  = true;
      g_sweepExtreme  = lowPrice;
      g_sweepTime     = iTime(Symbol(), Period(), 1);
      Log("BULLISH JUDAS SWING | AsianLow=" + DoubleToString(g_asianLow, _Digits) +
          " | SweepLow=" + DoubleToString(lowPrice, _Digits) +
          " | Close=" + DoubleToString(closePrice, _Digits));
   }
}

//+------------------------------------------------------------------+
//| ScanForFVGAndEnter                                                 |
//+------------------------------------------------------------------+
// 3-candle pattern scanned across a rolling InpFVGScanBars window:
//   Bullish FVG: high[offset+2] < low[offset]  (upside gap — buy retracement)
//   Bearish FVG: low[offset+2]  > high[offset] (downside gap — sell retracement)
// Displacement check is always applied to bar[offset+1] (the impulse candle).
void ScanForFVGAndEnter(bool isSilverBullet = false)
{
   int minBars = InpFVGScanBars + 2;
   if(Bars(Symbol(), Period()) < minBars)
      return;

   bool fvgFound = false;

   for(int offset = 1; offset <= InpFVGScanBars - 2 && !fvgFound; offset++)
   {
      double high_n  = iHigh(Symbol(), Period(), offset);      // newest bar of 3-bar pattern
      double low_n   = iLow(Symbol(),  Period(), offset);
      double high_n2 = iHigh(Symbol(), Period(), offset + 2);  // oldest bar of 3-bar pattern
      double low_n2  = iLow(Symbol(),  Period(), offset + 2);

      if(g_sweepBullish)
      {
         // Bullish FVG: gap between old bar's high and new bar's low
         if(high_n2 < low_n)
         {
            g_fvgHigh = low_n;
            g_fvgLow  = high_n2;

            if(!IsStrongDisplacement(offset + 1, true))
            {
               Log("FVG REJECTED [off=" + IntegerToString(offset) + "] | Weak displacement | "
                   "BodyPct check or Pip check failed");
               continue;
            }
            double fvgRange = g_fvgHigh - g_fvgLow;
            if(fvgRange < InpMinFVGPips * g_pipSize)
            {
               Log("FVG REJECTED [off=" + IntegerToString(offset) + "] | Too small | Size=" +
                   DoubleToString(fvgRange / g_pipSize, 1) + "p < " +
                   IntegerToString(InpMinFVGPips) + "p minimum");
               continue;
            }
            g_fvgMid    = g_fvgHigh - fvgRange * 0.25;
            g_fvgFormed = true;
            fvgFound    = true;
            Log("BULLISH FVG ACCEPTED [off=" + IntegerToString(offset) + "] | Zone: " +
                DoubleToString(g_fvgLow, _Digits) + "-" + DoubleToString(g_fvgHigh, _Digits) +
                " | Entry25%=" + DoubleToString(g_fvgMid, _Digits) +
                " | Size=" + DoubleToString(fvgRange / g_pipSize, 1) + "p");
         }
      }
      else
      {
         // Bearish FVG: gap between old bar's low and new bar's high
         if(low_n2 > high_n)
         {
            g_fvgHigh = low_n2;
            g_fvgLow  = high_n;

            if(!IsStrongDisplacement(offset + 1, false))
            {
               Log("FVG REJECTED [off=" + IntegerToString(offset) + "] | Weak displacement | "
                   "BodyPct check or Pip check failed");
               continue;
            }
            double fvgRange = g_fvgHigh - g_fvgLow;
            if(fvgRange < InpMinFVGPips * g_pipSize)
            {
               Log("FVG REJECTED [off=" + IntegerToString(offset) + "] | Too small | Size=" +
                   DoubleToString(fvgRange / g_pipSize, 1) + "p < " +
                   IntegerToString(InpMinFVGPips) + "p minimum");
               continue;
            }
            g_fvgMid    = g_fvgLow + fvgRange * 0.25;
            g_fvgFormed = true;
            fvgFound    = true;
            Log("BEARISH FVG ACCEPTED [off=" + IntegerToString(offset) + "] | Zone: " +
                DoubleToString(g_fvgLow, _Digits) + "-" + DoubleToString(g_fvgHigh, _Digits) +
                " | Entry25%=" + DoubleToString(g_fvgMid, _Digits) +
                " | Size=" + DoubleToString(fvgRange / g_pipSize, 1) + "p");
         }
      }
   } // end rolling window loop

   if(fvgFound)
      PlaceLimitOrder(isSilverBullet);
   else
   {
      // Only permanently consume the setup once we are past the Judas window.
      // If still inside the kill zone, leave g_setupConsumed=false so the next
      // bar re-runs the scan — the FVG may not have formed yet.
      MqlDateTime gmtDtScan;
      TimeToStruct(GetGMTTime(), gmtDtScan);
      if(gmtDtScan.hour >= InpJudasEndHour + 1)
      {
         Log("FVG SCAN: no valid FVG in " + IntegerToString(InpFVGScanBars - 2) +
             "-bar window after sweep. Past Judas window — setup consumed.");
         g_setupConsumed = true;
      }
      else
         Log("FVG SCAN: no valid FVG yet in " + IntegerToString(InpFVGScanBars - 2) +
             "-bar window — will retry next bar.");
   }
}

//+------------------------------------------------------------------+
//| CalculateAdaptiveSL                                              |
//|  Returns the stop-loss distance in price units, widened when     |
//|  ATR(14) exceeds 15 pips to account for elevated volatility.     |
//+------------------------------------------------------------------+
double CalculateAdaptiveSL(bool isBullish, double sweepExtreme, bool isSilverBullet)
{
   double baseSL = isSilverBullet ? InpSilverBulletSLPips : InpSLPips;

   if(g_atrHandle != INVALID_HANDLE)
   {
      double atrBuffer[1];
      if(CopyBuffer(g_atrHandle, 0, 0, 1, atrBuffer) > 0 && g_pipSize > 0.0)
      {
         double atrPips = atrBuffer[0] / g_pipSize;
         if(atrPips > 15.0)
            baseSL *= (1.0 + (atrPips - 15.0) / 30.0); // Scale up in high volatility
      }
   }

   Log("AdaptiveSL: base=" + DoubleToString(isSilverBullet ? InpSilverBulletSLPips : InpSLPips, 1) +
       "p -> adjusted=" + DoubleToString(baseSL, 1) + "p");
   return baseSL * g_pipSize;
}

//+------------------------------------------------------------------+
//| IsH1StructureAligned                                             |
//|  Bullish: last completed H1 bar made a higher low than the prior |
//|  Bearish: last completed H1 bar made a lower high than the prior |
//+------------------------------------------------------------------+
bool IsH1StructureAligned(bool setupBullish)
{
   if(Bars(_Symbol, PERIOD_H1) < 10) return true; // Pass if insufficient data

   double h1_high_recent = iHigh(_Symbol, PERIOD_H1, 1);
   double h1_low_recent  = iLow(_Symbol,  PERIOD_H1, 1);
   double h1_high_prev   = iHigh(_Symbol, PERIOD_H1, 2);
   double h1_low_prev    = iLow(_Symbol,  PERIOD_H1, 2);

   if(setupBullish)
      return (h1_low_recent > h1_low_prev);   // Bullish: higher lows
   return (h1_high_recent < h1_high_prev);    // Bearish: lower highs
}

//+------------------------------------------------------------------+
//| IsLowLiquidityPeriod                                             |
//|  Returns true during known low-liquidity windows:                |
//|   - Friday >= 15:00 GMT                                          |
//|   - Sunday                                                       |
//|   - NY close to Tokyo open (22:00-00:59 GMT)                     |
//+------------------------------------------------------------------+
bool IsLowLiquidityPeriod(const MqlDateTime &dt)
{
   if(dt.day_of_week == 5 && dt.hour >= 15) return true; // Friday close
   if(dt.day_of_week == 0) return true;                   // Sunday
   if(dt.hour >= 22 || dt.hour < 1) return true;          // Dead zone
   return false;
}

//+------------------------------------------------------------------+
//| PlaceLimitOrder                                                    |
//+------------------------------------------------------------------+
void PlaceLimitOrder(bool isSilverBullet = false)
{
   if(InpEnableWeeklyBias)
   {
      if(g_sweepBullish && !g_weeklyBullish)
         { Log("WEEKLY BIAS: BUY rejected (week=BEARISH)."); g_setupConsumed=true; return; }
      if(!g_sweepBullish && g_weeklyBullish)
         { Log("WEEKLY BIAS: SELL rejected (week=BULLISH)."); g_setupConsumed=true; return; }
   }
   if(InpEnablePDFilter && g_d1Equilibrium > 0)
   {
      double askPD = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      double bidPD = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      if(g_sweepBullish && askPD >= g_d1Equilibrium)
      {
         Log("PD FILTER: BUY in PREMIUM (Ask>=Eq). Skipped.");
         g_setupConsumed = true; return;
      }
      if(!g_sweepBullish && bidPD <= g_d1Equilibrium)
      {
         Log("PD FILTER: SELL in DISCOUNT (Bid<=Eq). Skipped.");
         g_setupConsumed = true; return;
      }
   }

   if(InpEnableH4Filter)
   {
      bool h4Bull = IsH4BullishBOS();
      bool h4Bear = IsH4BearishBOS();
      if(g_sweepBullish && !h4Bull)
         { Log("H4 FILTER: BUY rejected, no bullish BOS."); g_setupConsumed=true; return; }
      if(!g_sweepBullish && !h4Bear)
         { Log("H4 FILTER: SELL rejected, no bearish BOS."); g_setupConsumed=true; return; }
      if(InpEnableOBFilter)
      {
         DetectOrderBlock();
         if(g_obState == OB_NONE)
            { Log("OB FILTER: No OB found."); g_setupConsumed=true; return; }
         double ageH  = (g_obTime>0) ? (double)(TimeCurrent()-g_obTime)/3600.0 : 0;
         if(ageH > InpOBMaxAgeHours)
            { Log("OB FILTER: OB stale."); g_obState=OB_NONE; g_setupConsumed=true; return; }
         double obMid = (SymbolInfoDouble(Symbol(),SYMBOL_ASK)+SymbolInfoDouble(Symbol(),SYMBOL_BID))/2.0;
         double dist  = MathMin(MathAbs(obMid-g_obHigh), MathAbs(obMid-g_obLow));
         if(dist > InpOBProximityPips * g_pipSize)
            { Log("OB FILTER: Too far from OB."); g_setupConsumed=true; return; }
         Log("OB OK | " + DoubleToString(g_obLow,_Digits) + "-" + DoubleToString(g_obHigh,_Digits));
      }
   }
   if(InpEnableTrendFilter && !IsTrendAligned(g_sweepBullish))
   {
      Log("TREND FILTER: Setup rejected — price against D1 EMA200 direction.");
      g_setupConsumed = true; return;
   }
   if(!IsH1StructureAligned(g_sweepBullish))
   {
      Log("H1 STRUCTURE: Setup rejected — H1 market structure misaligned.");
      g_setupConsumed = true; return;
   }
   double slDistance = CalculateAdaptiveSL(g_sweepBullish, g_sweepExtreme, isSilverBullet);

   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double entryPrice, slPrice, tpPrice;
   ENUM_ORDER_TYPE orderType;

   if(g_sweepBullish)
   {
      entryPrice = g_fvgMid;
      slPrice    = g_sweepExtreme - slDistance;
      tpPrice    = entryPrice + (InpRRRatio * (entryPrice - slPrice));
      orderType  = ORDER_TYPE_BUY_LIMIT;
      if(entryPrice >= ask) { Log("BUY skipped: FVG mid>=Ask."); g_setupConsumed=true; return; }
   }
   else
   {
      entryPrice = g_fvgMid;
      slPrice    = g_sweepExtreme + slDistance;
      tpPrice    = entryPrice - (InpRRRatio * (slPrice - entryPrice));
      orderType  = ORDER_TYPE_SELL_LIMIT;
      if(entryPrice <= bid) { Log("SELL skipped: FVG mid<=Bid."); g_setupConsumed=true; return; }
   }

   if(g_sweepBullish  && tpPrice <= entryPrice) { Log("Invalid TP (BUY).");  g_setupConsumed=true; return; }
   if(!g_sweepBullish && tpPrice >= entryPrice) { Log("Invalid TP (SELL)."); g_setupConsumed=true; return; }

   double lotSize = CalculateLotSize(MathAbs(entryPrice - slPrice));
   if(lotSize <= 0) { Log("ERROR: Lots<=0."); g_setupConsumed=true; return; }
   g_setupConsumed = true;

   bool result = (orderType == ORDER_TYPE_BUY_LIMIT)
      ? g_trade.BuyLimit(lotSize, entryPrice, Symbol(), slPrice, tpPrice, 0, 0,
                         "ICT-FVG Buy" + (isSilverBullet ? "-SB|" : "|") + TimeToString(TimeCurrent()))
      : g_trade.SellLimit(lotSize, entryPrice, Symbol(), slPrice, tpPrice, 0, 0,
                          "ICT-FVG Sell"+ (isSilverBullet ? "-SB|" : "|") + TimeToString(TimeCurrent()));

   if(result)
   {
      g_pendingTicket   = g_trade.ResultOrder();
      g_pendingBarCount = 0;
      Log("ORDER PLACED | " + EnumToString(orderType) +
          " Entry=" + DoubleToString(entryPrice, _Digits) +
          " SL=" + DoubleToString(slPrice, _Digits) +
          " TP=" + DoubleToString(tpPrice, _Digits) +
          " Lots=" + DoubleToString(lotSize, 2) +
          " Ticket=" + IntegerToString(g_pendingTicket) +
          (isSilverBullet ? " [SILVER BULLET]" : ""));
   }
   else
   {
      Log("ORDER FAILED | RC=" + IntegerToString(g_trade.ResultRetcode()) +
          " " + g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| ManagePendingOrders                                                |
//+------------------------------------------------------------------+
void ManagePendingOrders()
{
   if(g_pendingTicket == 0)
      return;

   bool orderExists = false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == g_pendingTicket)
      {
         orderExists = true;
         g_pendingBarCount++;
         break;
      }
   }

   if(!orderExists)
   {
      Log("Pending order " + IntegerToString(g_pendingTicket) + " no longer pending (filled or cancelled).");
      g_pendingTicket = 0;
      return;
   }

   if(g_pendingBarCount >= InpOrderExpiryBars)
   {
      Log("EXPIRING stale pending order. Ticket=" + IntegerToString(g_pendingTicket) +
          " Age=" + IntegerToString(g_pendingBarCount) + " bars.");
      if(g_trade.OrderDelete(g_pendingTicket))
      {
         Log("Order deleted successfully.");
         g_pendingTicket = 0;
      }
      else
      {
         Log("Failed to delete order. Error=" + IntegerToString(GetLastError()));
      }
   }
}

//+------------------------------------------------------------------+
//| IsH4BullishBOS                                                     |
//+------------------------------------------------------------------+
bool IsH4BullishBOS()
{
   int lookback = InpH4LookbackBars;
   if(Bars(Symbol(), PERIOD_H4) < lookback + 5)
      return false;

   double swingHigh1 = 0, swingHigh2 = 0;
   int    count = 0;
   for(int i = 2; i < lookback - 1 && count < 2; i++)
   {
      double h   = iHigh(Symbol(), PERIOD_H4, i);
      double hm1 = iHigh(Symbol(), PERIOD_H4, i - 1);
      double hp1 = iHigh(Symbol(), PERIOD_H4, i + 1);

      if(h > hm1 && h > hp1)
      {
         count++;
         if(count == 1) swingHigh1 = h;
         if(count == 2) swingHigh2 = h;
      }
   }

   return (count >= 2 && swingHigh1 > swingHigh2);
}

//+------------------------------------------------------------------+
//| IsH4BearishBOS                                                     |
//+------------------------------------------------------------------+
bool IsH4BearishBOS()
{
   int lookback = InpH4LookbackBars;
   if(Bars(Symbol(), PERIOD_H4) < lookback + 5)
      return false;

   double swingLow1 = 0, swingLow2 = 0;
   int    count = 0;
   for(int i = 2; i < lookback - 1 && count < 2; i++)
   {
      double l   = iLow(Symbol(),  PERIOD_H4, i);
      double lm1 = iLow(Symbol(),  PERIOD_H4, i - 1);
      double lp1 = iLow(Symbol(),  PERIOD_H4, i + 1);

      if(l < lm1 && l < lp1)
      {
         count++;
         if(count == 1) swingLow1 = l;
         if(count == 2) swingLow2 = l;
      }
   }

   return (count >= 2 && swingLow1 < swingLow2);
}

//+------------------------------------------------------------------+
//| IsNewsTime / IsHardcodedNewsTime                                   |
//+------------------------------------------------------------------+
bool IsNewsTime(datetime gmtTime)
{
   datetime checkFrom = gmtTime - (InpNewsHaltBefore * 60);
   datetime checkTo   = gmtTime + (InpNewsHaltBefore * 60);

   MqlCalendarValue calValues[];
   bool calOK = CalendarValueHistory(calValues, checkFrom, checkTo, "USD");

   if(calOK)
   {
      for(int i = 0; i < ArraySize(calValues); i++)
      {
         MqlCalendarEvent evInfo;
         MqlCalendarCountry cInfo;

         if(!CalendarEventById(calValues[i].event_id, evInfo))
            continue;
         if(!CalendarCountryById(evInfo.country_id, cInfo))
            continue;
         if(evInfo.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;

         string cur = cInfo.currency;
         if(cur != "USD" && cur != "EUR")
            continue;

         datetime evTime = calValues[i].time;

         datetime blockStart = evTime - (InpNewsHaltBefore  * 60);
         datetime blockEnd   = evTime + (InpNewsResumeAfter * 60);

         if(gmtTime >= blockStart && gmtTime <= blockEnd)
         {
            Log("News block active: Event at " + TimeToString(evTime) +
                " | Currency=" + cur + " | Impact=HIGH");
            return true;
         }
      }

      MqlCalendarValue calValEUR[];
      if(CalendarValueHistory(calValEUR, checkFrom, checkTo, "EUR"))
      {
         for(int i = 0; i < ArraySize(calValEUR); i++)
         {
            MqlCalendarEvent evInfo;
            MqlCalendarCountry cInfo;
            if(!CalendarEventById(calValEUR[i].event_id, evInfo)) continue;
            if(!CalendarCountryById(evInfo.country_id, cInfo))    continue;
            if(evInfo.importance != CALENDAR_IMPORTANCE_HIGH)     continue;

            datetime evTime    = calValEUR[i].time;
            datetime blockStart = evTime - (InpNewsHaltBefore  * 60);
            datetime blockEnd   = evTime + (InpNewsResumeAfter * 60);

            if(gmtTime >= blockStart && gmtTime <= blockEnd)
            {
               Log("News block active (EUR): Event at " + TimeToString(evTime));
               return true;
            }
         }
      }

      return false;
   }

   Log("Calendar API unavailable – using hardcoded news schedule fallback.");
   return IsHardcodedNewsTime(gmtTime);
}

bool IsHardcodedNewsTime(datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);
   if(dt.day_of_week == 5)  // Friday
   {
      if(dt.day <= 7)        // First week
      {
         if(dt.hour == 13 || (dt.hour == 14 && dt.min <= 30))
         {
            Log("NFP hardcoded block active.");
            return true;
         }
      }
   }
   int fomcMonths[] = {1, 3, 5, 6, 7, 9, 11, 12};
   if(dt.day_of_week == 3) // Wednesday
   {
      for(int i = 0; i < ArraySize(fomcMonths); i++)
      {
         if(dt.mon == fomcMonths[i])
         {
            if(dt.hour >= 19 && dt.hour <= 20)
            {
               Log("FOMC hardcoded block active (approx).");
               return true;
            }
         }
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| CalculateLotSize                                                   |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPriceDistance)
{
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount     = accountBalance * (InpRiskPercent / 100.0);

   // Safety cap: never risk more than 2% of balance regardless of InpRiskPercent
   double maxRiskAmount = accountBalance * 0.02;
   if(riskAmount > maxRiskAmount)
      riskAmount = maxRiskAmount;

   double pipValue       = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);

   if(g_pipSize <= 0 || pipValue <= 0 || slPriceDistance <= 0)
      return 0;

   double slInPips = slPriceDistance / g_pipSize;
   double lotSize  = riskAmount / (slInPips * pipValue);

   double minLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   Log("LotSize calc: Balance=" + DoubleToString(accountBalance, 2) +
       " Risk=" + DoubleToString(riskAmount, 2) +
       " SLpips=" + DoubleToString(slInPips, 1) +
       " PipVal=" + DoubleToString(pipValue, 5) +
       " Lots=" + DoubleToString(lotSize, 2));

   return lotSize;
}

//+------------------------------------------------------------------+
//| CountOpenPositions                                                 |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == Symbol() &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Time Utilities                                                     |
//+------------------------------------------------------------------+

datetime GetGMTTime()
{
   return TimeCurrent() - g_gmtOffset * 3600;
}

int CalculateGMTOffset()
{
   datetime serverTime = TimeCurrent();
   datetime gmtTime    = TimeGMT();
   int offset = (int)((serverTime - gmtTime) / 3600);
   return offset;
}

bool IsInAsianSession(const MqlDateTime &dt)
{
   int h = dt.hour;
   return (h >= InpAsianStartHour && h < InpAsianEndHour);
}

bool IsInLondonKillZone(const MqlDateTime &dt)
{
   int h = dt.hour;
   return (h >= InpLondonStartHour && h < InpLondonEndHour);
}

bool IsInNYKillZone(const MqlDateTime &dt)
{
   int h = dt.hour;
   return (h >= InpNYStartHour && h < InpNYEndHour);
}

bool IsNewTradingDay(datetime gmtTime)
{
   MqlDateTime now, prev;
   TimeToStruct(gmtTime, now);
   if(g_asianRangeDate == 0) return false;

   TimeToStruct(g_asianRangeDate, prev);
   return (now.year != prev.year || now.mon != prev.mon || now.day != prev.day);
}

//+------------------------------------------------------------------+
//| ResetDailyState                                                    |
//+------------------------------------------------------------------+
void ResetDailyState(datetime currentGMT)
{
   if(g_pendingTicket != 0)
   {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if(OrderGetTicket(i) == g_pendingTicket)
         {
            if(g_trade.OrderDelete(g_pendingTicket))
               Log("Daily reset: cancelled order " + IntegerToString(g_pendingTicket));
            break;
         }
      }
   }

   g_asianHigh      = 0.0;
   g_asianLow       = 0.0;
   g_asianRangeSet  = false;
   g_asianRangeDate = currentGMT;
   g_sweepDetected  = false;
   g_sweepBullish   = false;
   g_sweepExtreme   = 0.0;
   g_sweepTime      = 0;
   g_fvgFormed      = false;
   g_fvgHigh        = 0.0;
   g_fvgLow         = 0.0;
   g_fvgMid         = 0.0;
   g_setupConsumed  = false;
   g_pendingTicket  = 0;
   g_pendingBarCount = 0;
   g_obState        = OB_NONE;
   g_obHigh         = 0.0;
   g_obLow          = 0.0;
   g_obTime         = 0;

   // FIX-F: Reset daily circuit breaker so trading resumes each new day
   g_dailyLimitHit      = false;
   g_dailyStartBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   // g_pauseUntilDay is intentionally NOT reset here — it self-expires once
   // TimeCurrent() passes its value (checked in OnTick). This prevents the
   // consecutive-loss pause from being cleared by a regular day rollover.
}

//+------------------------------------------------------------------+
//| OnChartEvent                                                       |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
}

//+------------------------------------------------------------------+
//| IsInSilverBulletWindow / DetectOrderBlock                         |
//+------------------------------------------------------------------+
bool IsInSilverBulletWindow(const MqlDateTime &dt)
{
   return (dt.hour >= InpSilverBulletStart && dt.hour < InpSilverBulletEnd);
}

void DetectOrderBlock()
{
   if(g_obState != OB_NONE && g_obTime > 0)
   {
      double ageH = (double)(TimeCurrent() - g_obTime) / 3600.0;
      if(ageH > InpOBMaxAgeHours) { g_obState = OB_NONE; }
   }

   if(g_obState != OB_NONE)
   {
      double closeH4 = iClose(Symbol(), PERIOD_H4, 1);
      if(g_obBullish)
      {
         if(closeH4 >= g_obLow && closeH4 <= g_obHigh && g_obState == OB_UNTESTED)
            g_obState = OB_MITIGATED;
         else if(closeH4 < g_obLow)
            g_obState = OB_BREAKER;
      }
      else
      {
         if(closeH4 >= g_obLow && closeH4 <= g_obHigh && g_obState == OB_UNTESTED)
            g_obState = OB_MITIGATED;
         else if(closeH4 > g_obHigh)
            g_obState = OB_BREAKER;
      }
      return;
   }

   int lookback = MathMin(InpH4LookbackBars, (int)Bars(Symbol(), PERIOD_H4) - 5);

   if(g_sweepBullish)
   {
      for(int i = 2; i < lookback; i++)
      {
         double o = iOpen(Symbol(),  PERIOD_H4, i);
         double c = iClose(Symbol(), PERIOD_H4, i);
         if(c < o)
         {
            g_obHigh    = iHigh(Symbol(), PERIOD_H4, i);
            g_obLow     = iLow(Symbol(),  PERIOD_H4, i);
            g_obBullish = true;
            g_obState   = OB_UNTESTED;
            g_obTime    = iTime(Symbol(), PERIOD_H4, i);
            Log("BULLISH OB [H4 bar " + IntegerToString(i) + "] " +
                DoubleToString(g_obLow, _Digits) + "-" + DoubleToString(g_obHigh, _Digits));
            break;
         }
      }
   }
   else
   {
      for(int i = 2; i < lookback; i++)
      {
         double o = iOpen(Symbol(),  PERIOD_H4, i);
         double c = iClose(Symbol(), PERIOD_H4, i);
         if(c > o)
         {
            g_obHigh    = iHigh(Symbol(), PERIOD_H4, i);
            g_obLow     = iLow(Symbol(),  PERIOD_H4, i);
            g_obBullish = false;
            g_obState   = OB_UNTESTED;
            g_obTime    = iTime(Symbol(), PERIOD_H4, i);
            Log("BEARISH OB [H4 bar " + IntegerToString(i) + "] " +
                DoubleToString(g_obLow, _Digits) + "-" + DoubleToString(g_obHigh, _Digits));
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| UpdateD1Equilibrium / UpdateWeeklyBias                            |
//+------------------------------------------------------------------+
void UpdateD1Equilibrium()
{
   if(Bars(Symbol(), PERIOD_D1) < 2) return;
   double d1H = iHigh(Symbol(), PERIOD_D1, 1);
   double d1L = iLow(Symbol(),  PERIOD_D1, 1);
   g_d1Equilibrium = (d1H + d1L) / 2.0;
   Log("D1 Eq updated: H=" + DoubleToString(d1H, _Digits) +
       " L=" + DoubleToString(d1L, _Digits) +
       " Mid=" + DoubleToString(g_d1Equilibrium, _Digits));
}

void UpdateWeeklyBias()
{
   if(Bars(Symbol(), PERIOD_W1) < 2) return;
   double wO = iOpen(Symbol(),  PERIOD_W1, 1);
   double wC = iClose(Symbol(), PERIOD_W1, 1);
   g_weeklyBullish  = (wC > wO);
   g_weeklyBiasDate = TimeCurrent();
   Log("Weekly bias: W1 O=" + DoubleToString(wO, _Digits) +
       " C=" + DoubleToString(wC, _Digits) +
       " -> " + (g_weeklyBullish ? "BULLISH" : "BEARISH"));
}

void UpdateWeeklyBiasIfMonday(const MqlDateTime &dt)
{
   if(!InpEnableWeeklyBias || dt.day_of_week != 1) return;
   MqlDateTime last;
   TimeToStruct(g_weeklyBiasDate, last);
   if(last.year == dt.year && last.mon == dt.mon && last.day == dt.day)
      return;
   UpdateWeeklyBias();
}

//+------------------------------------------------------------------+
//| IsStrongDisplacement / IsTrendAligned                             |
//+------------------------------------------------------------------+
// Middle candle body must be >= InpMinDisplacementBodyPct% of range
// AND >= InpMinDisplacementPips pips in size.
bool IsStrongDisplacement(int barIndex, bool isBullish)
{
   // Both thresholds at zero acts as a full disable of the displacement filter.
   if(InpMinDisplacementBodyPct == 0 && InpMinDisplacementPips == 0)
      return true;

   double open  = iOpen(Symbol(),  Period(), barIndex);
   double close = iClose(Symbol(), Period(), barIndex);
   double high  = iHigh(Symbol(),  Period(), barIndex);
   double low   = iLow(Symbol(),   Period(), barIndex);
   double range = high - low;

   if(range <= 0.0) return false;

   if(isBullish  && close <= open) return false;
   if(!isBullish && open  <= close) return false;

   double body        = MathAbs(close - open);
   double bodyPct     = (body / range) * 100.0;
   double minBodySize = InpMinDisplacementPips * g_pipSize;

   if(bodyPct < (double)InpMinDisplacementBodyPct)
   {
      Log("Displacement FAIL: body=" + DoubleToString(bodyPct, 1) +
          "% < required " + IntegerToString(InpMinDisplacementBodyPct) + "%");
      return false;
   }
   if(body < minBodySize)
   {
      Log("Displacement FAIL: body=" + DoubleToString(body / g_pipSize, 1) +
          " pips < required " + IntegerToString(InpMinDisplacementPips) + " pips");
      return false;
   }

   Log("Displacement OK: body=" + DoubleToString(bodyPct, 1) +
       "% / " + DoubleToString(body / g_pipSize, 1) + "p");
   return true;
}

bool IsTrendAligned(bool isBullishSetup)
{
   if(!InpEnableTrendFilter) return true;
   if(g_ema200Handle == INVALID_HANDLE) return true;

   double emaBuffer[1];
   if(CopyBuffer(g_ema200Handle, 0, 0, 1, emaBuffer) < 1)
   {
      Log("TREND FILTER: Failed to read EMA200, passing through.");
      return true;
   }

   double ema200       = emaBuffer[0];
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_BID) +
                          SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;

   Log("TrendFilter: Price=" + DoubleToString(currentPrice, _Digits) +
       " EMA200=" + DoubleToString(ema200, _Digits) +
       " Setup=" + (isBullishSetup ? "BUY" : "SELL"));

   if(isBullishSetup)  return (currentPrice > ema200); // Buy only above EMA200
   else                return (currentPrice < ema200); // Sell only below EMA200
}

//+------------------------------------------------------------------+
//| CloseAllPositions / ManageOpenPositions / OnTradeTransaction      |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == Symbol() &&
         PositionGetInteger(POSITION_MAGIC)  == InpMagicNumber)
      {
         if(g_trade.PositionClose(ticket))
            Log("Circuit Breaker: closed position #" + IntegerToString(ticket));
         else
            Log("Circuit Breaker: FAILED to close #" + IntegerToString(ticket));
      }
   }
}

// Moves SL to breakeven once price reaches 1R profit.
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!g_position.SelectByTicket(ticket)) continue;
      if(g_position.Symbol() != Symbol())    continue;
      if(g_position.Magic()  != InpMagicNumber) continue;

      double entry  = g_position.PriceOpen();
      double sl     = g_position.StopLoss();
      double bid    = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      double ask    = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      double buffer = _Point;

      // SL already at or beyond breakeven — nothing to do
      if(g_position.PositionType() == POSITION_TYPE_BUY  && sl >= entry) continue;
      if(g_position.PositionType() == POSITION_TYPE_SELL && sl <= entry && sl > 0) continue;

      if(g_position.PositionType() == POSITION_TYPE_BUY)
      {
         if(sl <= 0.0) continue;
         double initialRisk = entry - sl;
         if(initialRisk <= 0.0) continue;
         double targetBE    = entry + initialRisk;
         if(bid >= targetBE)
         {
            double newSL = NormalizeDouble(entry + buffer, _Digits);
            if(g_trade.PositionModify(ticket, newSL, g_position.TakeProfit()))
               Log("BREAKEVEN SET | #" + IntegerToString(ticket) +
                   " Buy | New SL=" + DoubleToString(newSL, _Digits));
         }
      }
      else if(g_position.PositionType() == POSITION_TYPE_SELL)
      {
         if(sl <= 0.0) continue;
         double initialRisk = sl - entry;
         if(initialRisk <= 0.0) continue;
         double targetBE    = entry - initialRisk;
         if(ask <= targetBE)
         {
            double newSL = NormalizeDouble(entry - buffer, _Digits);
            if(g_trade.PositionModify(ticket, newSL, g_position.TakeProfit()))
               Log("BREAKEVEN SET | #" + IntegerToString(ticket) +
                   " Sell | New SL=" + DoubleToString(newSL, _Digits));
         }
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   HistorySelect(TimeCurrent() - 86400, TimeCurrent() + 60);
   if(!HistoryDealSelect(dealTicket)) return;

   if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNumber) return;

   ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(dealEntry != DEAL_ENTRY_OUT) return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                 + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                 + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

   if(profit < 0.0)
   {
      g_consecutiveLosses++;
      Log("Consecutive losses: " + IntegerToString(g_consecutiveLosses) +
          " | P&L=" + DoubleToString(profit, 2));

      if(g_consecutiveLosses >= InpMaxConsecLosses)
      {
         MqlDateTime dt;
         TimeToStruct(TimeCurrent(), dt);
         dt.hour = 0; dt.min = 0; dt.sec = 0;
         datetime todayMidnight = StructToTime(dt);
         g_pauseUntilDay = todayMidnight + 86400;

         Log("!!! CONSECUTIVE LOSS PAUSE: " + IntegerToString(g_consecutiveLosses) +
             " losses hit limit of " + IntegerToString(InpMaxConsecLosses) +
             ". Paused until " + TimeToString(g_pauseUntilDay, TIME_DATE|TIME_MINUTES) + " !!!");
      }
   }
   else if(profit >= 0.0)
   {
      if(g_consecutiveLosses > 0)
         Log("Win closes streak of " + IntegerToString(g_consecutiveLosses) + " losses. Reset.");
      g_consecutiveLosses = 0;
   }
}
//+------------------------------------------------------------------+
//| PLANNED ICT CONCEPTS — scheduled for future versions             |
//+------------------------------------------------------------------+
//
//  1. SMT Divergence (v4.0)
//     EUR/USD vs GBP/USD correlated sweep divergence.
//     One pair takes the liquidity level while the other fails to —
//     high-confidence confirmation of manipulation. Requires a second
//     symbol feed (iHigh/iLow on GBPUSD). Must be applied within the
//     same London sweep context; raw divergence alone has false positives.
//
//  2. Market Maker Models — MMXM / W / M patterns (v4.0)
//     3-leg swing structure: accumulation => manipulation => distribution.
//     Requires swing-point detection across HTF (H1/H4) and pattern
//     classification logic. Very parameter-sensitive; tuning needed
//     before enabling in a live funded environment.
//
//  3. Consequent Encroachment of Order Blocks (v3.1)
//     ICT enters at the 50% (CE) of an OB candle body, not the full zone.
//     Implementation: store OB open/close alongside OB high/low, then
//     use (open + close) / 2 as the entry price instead of the zone edge.
//     Current code uses the full OB zone — add CE refinement in v3.1.
//
//  4. Optimal Trade Entry (OTE) via Fibonacci (v3.1)
//     ICT defines highest-probability entry at the 62%-79% retracement
//     of a confirmed displacement swing. Overlay on the FVG: compute
//     swing high/low of the displacement leg and shift entry price to
//     the 70.5% (midpoint of OTE zone) rather than the 25% FVG edge.
//     Add as an optional mode toggled by InpUseOTEEntry (default false).
//
//+------------------------------------------------------------------+
//| END OF FILE                                                        |
//+------------------------------------------------------------------+
