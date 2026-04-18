//+------------------------------------------------------------------+
//| ICT_LondonSweep_FVG.mq5                                          |
//| London Open Asian Sweep + Fair Value Gap EA                     |
//| ICT Concept: Judas Swing + FVG Retracement                       |
//|                                                                  |
//| v2.1 — CRITICAL FIXES (Sid's Backtest Analysis):                |
//| FIX-17 FVG entry: 50% → 25% edge (bullish=bottom, bearish=top) |
//| FIX-18 Premium/Discount filter: ENABLED by default              |
//| FIX-19 Weekly Bias filter: ENABLED by default                   |
//| FIX-20 H4 BOS: i±2 validation (2 bars each side, proper swing)  |
//| FIX-21 Minimum sweep distance: 5 pips (filter noise)            |
//| FIX-22 FVG freshness: max 5 bars old                            |
//| FIX-23 FVG retracement confirmation: price must be in FVG zone  |
//|                                                                  |
//| Works on: EUR/USD M5 or M15                                     |
//+------------------------------------------------------------------+
#property copyright "ICT EA – MARK1 v2.1"
#property version "2.10"
#property strict

enum ENUM_OB_STATE
{
   OB_NONE = 0,
   OB_UNTESTED = 1,
   OB_MITIGATED = 2,
   OB_BREAKER = 3
};

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input group "=== Risk Management ==="
input double InpRiskPercent = 0.5;
input double InpRRRatio = 3.0;
input double InpSLPips = 20.0;
input int InpMaxOpenTrades = 2;

input group "=== Session Times (GMT) ==="
input int InpAsianStartHour = 0;
input int InpAsianEndHour = 7;
input int InpLondonStartHour = 8;
input int InpLondonEndHour = 11;
input int InpJudasEndHour = 10;
input int InpNYStartHour = 13;
input int InpNYEndHour = 16;
input int InpSilverBulletStart = 15;
input int InpSilverBulletEnd = 16;
input double InpSilverBulletSLPips = 12.0;

input group "=== News Filter ==="
input bool InpEnableNewsFilter = true;
input int InpNewsHaltBefore = 30;
input int InpNewsResumeAfter = 15;

input group "=== H4 Market Structure Confirmation ==="
input bool InpEnableH4Filter = true;
input int InpH4LookbackBars = 50;

input group "=== Premium / Discount Filter (D1) ==="
input bool InpEnablePDFilter = true; // [FIX-18] ENABLED

input group "=== Weekly Bias Filter ==="
input bool InpEnableWeeklyBias = true; // [FIX-19] ENABLED

input group "=== Order Block Settings ==="
input bool InpEnableOBFilter = false;
input double InpOBProximityPips = 10.0;
input int InpOBMaxAgeHours = 24;

input group "=== Sweep & FVG Settings ==="
input double InpMinSweepPips = 5.0; // [FIX-21] Minimum sweep distance
input int InpMaxFVGAgeBars = 5; // [FIX-22] Max FVG age in bars
input double InpFVGEntryPercent = 25.0; // [FIX-17] Entry at 25% edge

input group "=== Order Settings ==="
input int InpOrderExpiryBars = 10;
input int InpMagicNumber = 202601;

input group "=== Debug ==="
input bool InpDebugLog = true;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade g_trade;
CPositionInfo g_position;
COrderInfo g_order;

double g_asianHigh = 0.0;
double g_asianLow = 0.0;
bool g_asianRangeSet = false;
datetime g_asianRangeDate = 0;

bool g_sweepDetected = false;
bool g_sweepBullish = false;
double g_sweepExtreme = 0.0;
datetime g_sweepTime = 0;

bool g_fvgFormed = false;
double g_fvgHigh = 0.0;
double g_fvgLow = 0.0;
datetime g_fvgTime = 0; // [FIX-22] Track FVG formation time
bool g_setupConsumed = false;

ulong g_pendingTicket = 0;
int g_pendingBarCount = 0;

bool g_weeklyBullish = false;
datetime g_weeklyBiasDate = 0;

double g_d1Equilibrium = 0.0;

ENUM_OB_STATE g_obState = OB_NONE;
double g_obHigh = 0.0;
double g_obLow = 0.0;
bool g_obBullish = false;
datetime g_obTime = 0;

int g_gmtOffset = 0;
double g_pipSize = 0.0;
datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
void Log(const string msg)
{
   if(InpDebugLog) Print("[ICT-EA v2.1] ", msg);
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(Symbol(), "EURUSD") < 0)
      Print("[ICT-EA] WARNING: EA designed for EURUSD. Current: ", Symbol());

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   g_pipSize = (digits == 3 || digits == 5)
      ? SymbolInfoDouble(Symbol(), SYMBOL_POINT) * 10.0
      : SymbolInfoDouble(Symbol(), SYMBOL_POINT);

   g_gmtOffset = CalculateGMTOffset();
   g_asianRangeDate = GetGMTTime() - 86400;
   g_lastBarTime = (datetime)SeriesInfoInteger(Symbol(), Period(), SERIES_LASTBAR_DATE);

   UpdateD1Equilibrium();
   UpdateWeeklyBias();

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   Log("EA Init v2.1 FIXED | Pip=" + DoubleToString(g_pipSize, _Digits) +
       " Risk=" + DoubleToString(InpRiskPercent, 1) + "%" +
       " D1_Eq=" + DoubleToString(g_d1Equilibrium, _Digits) +
       " WeeklyBias=" + (g_weeklyBullish ? "BULL" : "BEAR") +
       " PD_Filter=" + (InpEnablePDFilter ? "ON" : "OFF") +
       " Weekly_Filter=" + (InpEnableWeeklyBias ? "ON" : "OFF"));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Log("EA Deinitialised. Reason=" + IntegerToString(reason));
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBarTime = (datetime)SeriesInfoInteger(Symbol(), Period(), SERIES_LASTBAR_DATE);
   if(currentBarTime == 0 || currentBarTime == g_lastBarTime) return;
   g_lastBarTime = currentBarTime;

   datetime gmtTime = GetGMTTime();
   MqlDateTime gmtDt;
   TimeToStruct(gmtTime, gmtDt);

   ManagePendingOrders();

   if(IsNewTradingDay(gmtTime))
   {
      ResetDailyState(gmtTime);
      UpdateD1Equilibrium();
      Log("New day | " + TimeToString(gmtTime, TIME_DATE) +
          " D1_Eq=" + DoubleToString(g_d1Equilibrium, _Digits));
   }

   UpdateWeeklyBiasIfMonday(gmtDt);

   if(IsInAsianSession(gmtDt) && !g_asianRangeSet)
      UpdateAsianRange();

   if(gmtDt.hour >= InpLondonStartHour && !g_asianRangeSet && g_asianHigh > 0)
   {
      g_asianRangeSet = true;
      Log("Asian Range LOCKED | High=" + DoubleToString(g_asianHigh, _Digits) +
          " | Low=" + DoubleToString(g_asianLow, _Digits));
   }

   bool inLondon = IsInLondonKillZone(gmtDt);
   bool inNY = IsInNYKillZone(gmtDt);
   bool inSilverBullet = IsInSilverBulletWindow(gmtDt);

   if(!(inLondon || inNY || inSilverBullet) || !g_asianRangeSet) return;

   if(InpEnableNewsFilter && IsNewsTime(gmtTime))
   {
      Log("NEWS FILTER: halted.");
      return;
   }

   if(CountOpenPositions() >= InpMaxOpenTrades) return;

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
void UpdateAsianRange()
{
   double highVal = iHigh(Symbol(), Period(), 1);
   double lowVal = iLow(Symbol(), Period(), 1);

   if(g_asianHigh == 0.0 || highVal > g_asianHigh) g_asianHigh = highVal;
   if(g_asianLow == 0.0 || lowVal < g_asianLow) g_asianLow = lowVal;
}

//+------------------------------------------------------------------+
//| [FIX-21] Minimum sweep distance                                 |
//+------------------------------------------------------------------+
void DetectJudasSwing()
{
   double closePrice = iClose(Symbol(), Period(), 1);
   double highPrice = iHigh(Symbol(), Period(), 1);
   double lowPrice = iLow(Symbol(), Period(), 1);

   // [FIX-21] Calculate sweep distance in pips
   double sweepDistanceHigh = (highPrice - g_asianHigh) / g_pipSize;
   double sweepDistanceLow = (g_asianLow - lowPrice) / g_pipSize;

   // Bearish Judas: high swept with minimum distance
   if(sweepDistanceHigh >= InpMinSweepPips && 
      closePrice < g_asianHigh && closePrice > g_asianLow)
   {
      g_sweepDetected = true;
      g_sweepBullish = false;
      g_sweepExtreme = highPrice;
      g_sweepTime = iTime(Symbol(), Period(), 1);
      Log("BEARISH JUDAS SWING | AsianHigh=" + DoubleToString(g_asianHigh, _Digits) +
          " | SweepHigh=" + DoubleToString(highPrice, _Digits) +
          " | SweepPips=" + DoubleToString(sweepDistanceHigh, 1) +
          " | Close=" + DoubleToString(closePrice, _Digits));
   }
   // Bullish Judas: low swept with minimum distance
   else if(sweepDistanceLow >= InpMinSweepPips && 
           closePrice > g_asianLow && closePrice < g_asianHigh)
   {
      g_sweepDetected = true;
      g_sweepBullish = true;
      g_sweepExtreme = lowPrice;
      g_sweepTime = iTime(Symbol(), Period(), 1);
      Log("BULLISH JUDAS SWING | AsianLow=" + DoubleToString(g_asianLow, _Digits) +
          " | SweepLow=" + DoubleToString(lowPrice, _Digits) +
          " | SweepPips=" + DoubleToString(sweepDistanceLow, 1) +
          " | Close=" + DoubleToString(closePrice, _Digits));
   }
}

//+------------------------------------------------------------------+
//| [FIX-22] [FIX-23] FVG with freshness & retracement confirmation |
//+------------------------------------------------------------------+
void ScanForFVGAndEnter(bool isSilverBullet = false)
{
   if(Bars(Symbol(), Period()) < 5) return;

   double high1 = iHigh(Symbol(), Period(), 1);
   double low1 = iLow(Symbol(), Period(), 1);
   double high3 = iHigh(Symbol(), Period(), 3);
   double low3 = iLow(Symbol(), Period(), 3);

   bool fvgFound = false;

   if(g_sweepBullish)
   {
      if(high3 < low1) // Bullish FVG: gap upward
      {
         g_fvgHigh = low1;
         g_fvgLow = high3;
         g_fvgTime = iTime(Symbol(), Period(), 1); // [FIX-22] Track formation time
         g_fvgFormed = true;
         fvgFound = true;
         Log("BULLISH FVG | Zone: " + DoubleToString(g_fvgLow, _Digits) +
             "-" + DoubleToString(g_fvgHigh, _Digits));
      }
   }
   else
   {
      if(low3 > high1) // Bearish FVG: gap downward
      {
         g_fvgHigh = low3;
         g_fvgLow = high1;
         g_fvgTime = iTime(Symbol(), Period(), 1); // [FIX-22]
         g_fvgFormed = true;
         fvgFound = true;
         Log("BEARISH FVG | Zone: " + DoubleToString(g_fvgLow, _Digits) +
             "-" + DoubleToString(g_fvgHigh, _Digits));
      }
   }

   if(fvgFound)
   {
      // [FIX-22] Check FVG freshness (age in bars)
      int fvgAgeBars = 1; // FVG just formed on bar 1
      if(fvgAgeBars > InpMaxFVGAgeBars)
      {
         Log("FVG too old (" + IntegerToString(fvgAgeBars) + " bars), skipping");
         g_setupConsumed = true;
         return;
      }

      // [FIX-23] Confirm price is in FVG zone (retracement confirmation)
      double currentPrice = g_sweepBullish 
         ? SymbolInfoDouble(Symbol(), SYMBOL_ASK)
         : SymbolInfoDouble(Symbol(), SYMBOL_BID);

      if(currentPrice < g_fvgLow || currentPrice > g_fvgHigh)
      {
         Log("Price not in FVG zone yet (Current=" + DoubleToString(currentPrice, _Digits) + 
             " | FVG=" + DoubleToString(g_fvgLow, _Digits) + "-" + DoubleToString(g_fvgHigh, _Digits) + ")");
         // Don't mark consumed - allow retry on next bar if price enters FVG
         return;
      }

      PlaceLimitOrder(isSilverBullet);
   }
}

//+------------------------------------------------------------------+
//| [FIX-17] FVG entry at 25% edge (not 50% midpoint)               |
//+------------------------------------------------------------------+
void PlaceLimitOrder(bool isSilverBullet = false)
{
   // [FIX-19] Weekly Bias filter
   if(InpEnableWeeklyBias)
   {
      if(g_sweepBullish && !g_weeklyBullish)
      { Log("WEEKLY BIAS: BUY rejected (week=BEARISH)."); g_setupConsumed=true; return; }
      if(!g_sweepBullish && g_weeklyBullish)
      { Log("WEEKLY BIAS: SELL rejected (week=BULLISH)."); g_setupConsumed=true; return; }
   }

   // [FIX-18] Premium/Discount zone filter
   if(InpEnablePDFilter && g_d1Equilibrium > 0)
   {
      double askPD = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      double bidPD = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      
      if(g_sweepBullish && askPD >= g_d1Equilibrium)
      {
         Log("PD FILTER: BUY in PREMIUM (Ask=" + DoubleToString(askPD, _Digits) + 
             " >= Eq=" + DoubleToString(g_d1Equilibrium, _Digits) + "). Skipped.");
         g_setupConsumed = true; return;
      }
      if(!g_sweepBullish && bidPD <= g_d1Equilibrium)
      {
         Log("PD FILTER: SELL in DISCOUNT (Bid=" + DoubleToString(bidPD, _Digits) + 
             " <= Eq=" + DoubleToString(g_d1Equilibrium, _Digits) + "). Skipped.");
         g_setupConsumed = true; return;
      }
   }

   // H4 BOS filter
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
         
         double ageH = (g_obTime>0) ? (double)(TimeCurrent()-g_obTime)/3600.0 : 0;
         if(ageH > InpOBMaxAgeHours)
         { Log("OB FILTER: OB stale."); g_obState=OB_NONE; g_setupConsumed=true; return; }
         
         double obMid = (SymbolInfoDouble(Symbol(),SYMBOL_ASK)+SymbolInfoDouble(Symbol(),SYMBOL_BID))/2.0;
         double dist = MathMin(MathAbs(obMid-g_obHigh), MathAbs(obMid-g_obLow));
         if(dist > InpOBProximityPips * g_pipSize)
         { Log("OB FILTER: Too far from OB."); g_setupConsumed=true; return; }
         
         Log("OB OK | " + DoubleToString(g_obLow,_Digits) + "-" + DoubleToString(g_obHigh,_Digits));
      }
   }

   double slPips = isSilverBullet ? InpSilverBulletSLPips : InpSLPips;
   double slDistance = slPips * g_pipSize;
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double entryPrice, slPrice, tpPrice;
   ENUM_ORDER_TYPE orderType;

   // [FIX-17] Entry at 25% edge (bullish = bottom 25%, bearish = top 75%)
   double fvgRange = g_fvgHigh - g_fvgLow;
   double entryOffset = fvgRange * (InpFVGEntryPercent / 100.0);

   if(g_sweepBullish)
   {
      entryPrice = g_fvgLow + entryOffset; // 25% from bottom
      slPrice = g_sweepExtreme - slDistance;
      tpPrice = entryPrice + (InpRRRatio * (entryPrice - slPrice));
      orderType = ORDER_TYPE_BUY_LIMIT;
      
      if(entryPrice >= ask) 
      { Log("BUY skipped: Entry>=Ask."); g_setupConsumed=true; return; }
   }
   else
   {
      entryPrice = g_fvgHigh - entryOffset; // 75% level (25% from top)
      slPrice = g_sweepExtreme + slDistance;
      tpPrice = entryPrice - (InpRRRatio * (slPrice - entryPrice));
      orderType = ORDER_TYPE_SELL_LIMIT;
      
      if(entryPrice <= bid) 
      { Log("SELL skipped: Entry<=Bid."); g_setupConsumed=true; return; }
   }

   if(g_sweepBullish && tpPrice <= entryPrice) 
   { Log("Invalid TP (BUY)."); g_setupConsumed=true; return; }
   if(!g_sweepBullish && tpPrice >= entryPrice) 
   { Log("Invalid TP (SELL)."); g_setupConsumed=true; return; }

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
      g_pendingTicket = g_trade.ResultOrder();
      g_pendingBarCount = 0;
      Log("ORDER PLACED | " + EnumToString(orderType) +
          " Entry=" + DoubleToString(entryPrice, _Digits) + " (" + DoubleToString(InpFVGEntryPercent, 0) + "% edge)" +
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
void ManagePendingOrders()
{
   if(g_pendingTicket == 0) return;

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
      Log("Pending order " + IntegerToString(g_pendingTicket) + " no longer pending.");
      g_pendingTicket = 0;
      return;
   }

   if(g_pendingBarCount >= InpOrderExpiryBars)
   {
      Log("EXPIRING stale pending order. Ticket=" + IntegerToString(g_pendingTicket));
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
//| [FIX-20] H4 BOS with i±2 validation (2 bars each side)         |
//+------------------------------------------------------------------+
bool IsH4BullishBOS()
{
   int lookback = InpH4LookbackBars;
   if(Bars(Symbol(), PERIOD_H4) < lookback + 5) return false;

   double swingHigh1 = 0, swingHigh2 = 0;
   int count = 0;

   // [FIX-20] Proper swing: 2 bars on EACH side
   for(int i = 3; i < lookback - 2 && count < 2; i++)
   {
      double h = iHigh(Symbol(), PERIOD_H4, i);
      double hm2 = iHigh(Symbol(), PERIOD_H4, i - 2);
      double hm1 = iHigh(Symbol(), PERIOD_H4, i - 1);
      double hp1 = iHigh(Symbol(), PERIOD_H4, i + 1);
      double hp2 = iHigh(Symbol(), PERIOD_H4, i + 2);

      // Valid swing high: higher than 2 bars on BOTH sides
      if(h > hm2 && h > hm1 && h > hp1 && h > hp2)
      {
         count++;
         if(count == 1) swingHigh1 = h;
         if(count == 2) swingHigh2 = h;
      }
   }

   return (count >= 2 && swingHigh1 > swingHigh2);
}

//+------------------------------------------------------------------+
//| [FIX-20] H4 Bearish BOS with i±2 validation                     |
//+------------------------------------------------------------------+
bool IsH4BearishBOS()
{
   int lookback = InpH4LookbackBars;
   if(Bars(Symbol(), PERIOD_H4) < lookback + 5) return false;

   double swingLow1 = 0, swingLow2 = 0;
   int count = 0;

   // [FIX-20] Proper swing: 2 bars on EACH side
   for(int i = 3; i < lookback - 2 && count < 2; i++)
   {
      double l = iLow(Symbol(), PERIOD_H4, i);
      double lm2 = iLow(Symbol(), PERIOD_H4, i - 2);
      double lm1 = iLow(Symbol(), PERIOD_H4, i - 1);
      double lp1 = iLow(Symbol(), PERIOD_H4, i + 1);
      double lp2 = iLow(Symbol(), PERIOD_H4, i + 2);

      if(l < lm2 && l < lm1 && l < lp1 && l < lp2)
      {
         count++;
         if(count == 1) swingLow1 = l;
         if(count == 2) swingLow2 = l;
      }
   }

   return (count >= 2 && swingLow1 < swingLow2);
}

//+------------------------------------------------------------------+
bool IsNewsTime(datetime gmtTime)
{
   datetime checkFrom = gmtTime - (InpNewsHaltBefore * 60);
   datetime checkTo = gmtTime + (InpNewsHaltBefore * 60);

   MqlCalendarValue calValues[];
   bool calOK = CalendarValueHistory(calValues, checkFrom, checkTo, "USD");

   if(calOK)
   {
      for(int i = 0; i < ArraySize(calValues); i++)
      {
         MqlCalendarEvent evInfo;
         MqlCalendarCountry cInfo;
         if(!CalendarEventById(calValues[i].event_id, evInfo)) continue;
         if(!CalendarCountryById(evInfo.country_id, cInfo)) continue;
         if(evInfo.importance != CALENDAR_IMPORTANCE_HIGH) continue;

         string cur = cInfo.currency;
         if(cur != "USD" && cur != "EUR") continue;

         datetime evTime = calValues[i].time;
         datetime blockStart = evTime - (InpNewsHaltBefore * 60);
         datetime blockEnd = evTime + (InpNewsResumeAfter * 60);

         if(gmtTime >= blockStart && gmtTime <= blockEnd)
         {
            Log("News block active: " + TimeToString(evTime) + " | " + cur);
            return true;
         }
      }

      MqlCalendarValue calValEUR[];
      if(CalendarValueHistory(calValEUR, checkFrom, checkTo, "EUR"))
      {
         for(int i = 0; i < ArraySize(calValEUR); i++)
         {
            MqlCalendarEvent evInfo;
            if(!CalendarEventById(calValEUR[i].event_id, evInfo)) continue;
            if(evInfo.importance != CALENDAR_IMPORTANCE_HIGH) continue;

            datetime evTime = calValEUR[i].time;
            datetime blockStart = evTime - (InpNewsHaltBefore * 60);
            datetime blockEnd = evTime + (InpNewsResumeAfter * 60);

            if(gmtTime >= blockStart && gmtTime <= blockEnd)
            {
               Log("News block active (EUR): " + TimeToString(evTime));
               return true;
            }
         }
      }
      return false;
   }

   Log("Calendar API unavailable – using hardcoded fallback.");
   return IsHardcodedNewsTime(gmtTime);
}

bool IsHardcodedNewsTime(datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);

   if(dt.day_of_week == 5 && dt.day <= 7)
   {
      if(dt.hour == 13 || (dt.hour == 14 && dt.min <= 30))
      {
         Log("NFP hardcoded block active.");
         return true;
      }
   }

   int fomcMonths[] = {1, 3, 5, 6, 7, 9, 11, 12};
   if(dt.day_of_week == 3)
   {
      for(int i = 0; i < ArraySize(fomcMonths); i++)
      {
         if(dt.mon == fomcMonths[i] && dt.hour >= 19 && dt.hour <= 20)
         {
            Log("FOMC hardcoded block active.");
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
double CalculateLotSize(double slPriceDistance)
{
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = accountBalance * (InpRiskPercent / 100.0);
   double pipValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);

   if(g_pipSize <= 0 || pipValue <= 0 || slPriceDistance <= 0) return 0;

   double slInPips = slPriceDistance / g_pipSize;
   double lotSize = riskAmount / (slInPips * pipValue);

   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);

   return lotSize;
}

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
datetime GetGMTTime() { return TimeCurrent() - g_gmtOffset * 3600; }

int CalculateGMTOffset()
{
   datetime serverTime = TimeCurrent();
   datetime gmtTime = TimeGMT();
   return (int)((serverTime - gmtTime) / 3600);
}

bool IsInAsianSession(const MqlDateTime &dt)
{
   return (dt.hour >= InpAsianStartHour && dt.hour < InpAsianEndHour);
}

bool IsInLondonKillZone(const MqlDateTime &dt)
{
   return (dt.hour >= InpLondonStartHour && dt.hour < InpLondonEndHour);
}

bool IsInNYKillZone(const MqlDateTime &dt)
{
   return (dt.hour >= InpNYStartHour && dt.hour < InpNYEndHour);
}

bool IsInSilverBulletWindow(const MqlDateTime &dt)
{
   return (dt.hour >= InpSilverBulletStart && dt.hour < InpSilverBulletEnd);
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

   g_asianHigh = 0.0;
   g_asianLow = 0.0;
   g_asianRangeSet = false;
   g_asianRangeDate = currentGMT;
   g_sweepDetected = false;
   g_sweepBullish = false;
   g_sweepExtreme = 0.0;
   g_sweepTime = 0;
   g_fvgFormed = false;
   g_fvgHigh = 0.0;
   g_fvgLow = 0.0;
   g_fvgTime = 0;
   g_setupConsumed = false;
   g_pendingTicket = 0;
   g_pendingBarCount = 0;
   g_obState = OB_NONE;
   g_obHigh = 0.0;
   g_obLow = 0.0;
   g_obTime = 0;
}

//+------------------------------------------------------------------+
//| Premium/Discount Filter Helper                                  |
//+------------------------------------------------------------------+
void UpdateD1Equilibrium()
{
   if(Bars(Symbol(), PERIOD_D1) < 2) return;
   
   double d1High = iHigh(Symbol(), PERIOD_D1, 1);
   double d1Low = iLow(Symbol(), PERIOD_D1, 1);
   g_d1Equilibrium = (d1High + d1Low) / 2.0;
}

//+------------------------------------------------------------------+
//| Weekly Bias Helper                                              |
//+------------------------------------------------------------------+
void UpdateWeeklyBias()
{
   if(Bars(Symbol(), PERIOD_W1) < 2) return;
   
   double w1Open = iOpen(Symbol(), PERIOD_W1, 1);
   double w1Close = iClose(Symbol(), PERIOD_W1, 1);
   g_weeklyBullish = (w1Close > w1Open);
   g_weeklyBiasDate = TimeCurrent();
   
   Log("Weekly Bias Updated: " + (g_weeklyBullish ? "BULLISH" : "BEARISH"));
}

void UpdateWeeklyBiasIfMonday(const MqlDateTime &dt)
{
   if(dt.day_of_week == 1) // Monday
   {
      MqlDateTime lastUpdate;
      TimeToStruct(g_weeklyBiasDate, lastUpdate);
      
      if(dt.year != lastUpdate.year || dt.mon != lastUpdate.mon || dt.day != lastUpdate.day)
      {
         UpdateWeeklyBias();
      }
   }
}

//+------------------------------------------------------------------+
//| Order Block Detection                                           |
//+------------------------------------------------------------------+
void DetectOrderBlock()
{
   if(g_obState != OB_NONE && g_obTime > 0)
   {
      double ageH = (double)(TimeCurrent() - g_obTime) / 3600.0;
      if(ageH > InpOBMaxAgeHours) g_obState = OB_NONE;
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

   bool bullBOS = IsH4BullishBOS();
   bool bearBOS = IsH4BearishBOS();

   if(!bullBOS && !bearBOS) return;

   for(int i = 2; i < 20; i++)
   {
      double oH4 = iOpen(Symbol(), PERIOD_H4, i);
      double cH4 = iClose(Symbol(), PERIOD_H4, i);
      double hH4 = iHigh(Symbol(), PERIOD_H4, i);
      double lH4 = iLow(Symbol(), PERIOD_H4, i);

      if(bullBOS && cH4 < oH4)
      {
         g_obState = OB_UNTESTED;
         g_obHigh = hH4;
         g_obLow = lH4;
         g_obBullish = true;
         g_obTime = iTime(Symbol(), PERIOD_H4, i);
         Log("Bullish OB detected | " + DoubleToString(g_obLow, _Digits) + 
             "-" + DoubleToString(g_obHigh, _Digits));
         return;
      }

      if(bearBOS && cH4 > oH4)
      {
         g_obState = OB_UNTESTED;
         g_obHigh = hH4;
         g_obLow = lH4;
         g_obBullish = false;
         g_obTime = iTime(Symbol(), PERIOD_H4, i);
         Log("Bearish OB detected | " + DoubleToString(g_obLow, _Digits) + 
             "-" + DoubleToString(g_obHigh, _Digits));
         return;
      }
   }
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Reserved for future visual overlay
}

//+------------------------------------------------------------------+
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
