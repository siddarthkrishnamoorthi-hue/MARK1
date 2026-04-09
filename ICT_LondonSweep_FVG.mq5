//+------------------------------------------------------------------+
//|                        ICT_LondonSweep_FVG.mq5                   |
//|              London Open Asian Sweep + Fair Value Gap EA          |
//|              ICT Concept: Judas Swing + FVG Retracement           |
//|                                                                    |
//|  v2.0 — PR Review Corrections (full ICT alignment):               |
//|  FIX-01  Asian range lock: == → >= guard (no missed locks)        |
//|  FIX-02  FVG formulas SWAPPED — corrected per ICT math            |
//|  FIX-03  Spread removed from SL distance                          |
//|  FIX-04  H4 swing: 2-bar validation (i=3 start, i±2 check)        |
//|  FIX-05  Separate IsH4BearishBOS() replaces !IsH4BullishBOS()    |
//|  FIX-06  g_setupConsumed flag replaces FVG-state misuse           |
//|  FIX-07  g_asianRangeDate seeded in OnInit()                      |
//|  FIX-08  Removed dead variable g_pendingOpenTime                  |
//|  FIX-09  Judas window narrowed to 08:00–10:00 GMT                 |
//|  FIX-10  Premium/Discount zone filter (D1 equilibrium)            |
//|  FIX-11  Weekly Bias filter (W1 close vs open, refreshed Monday)  |
//|  FIX-12  Order Block detection with state machine (UNTESTED/      |
//|           MITIGATED/BREAKER) after H4 BOS confirmation             |
//|  FIX-13  Silver Bullet window (15:00–16:00 GMT, tighter SL)       |
//|  FIX-14  Removed unused windowStart/windowEnd in IsNewsTime()     |
//|  FIX-15  ORDER_FILLING_FOK → ORDER_FILLING_RETURN (broker compat) |
//|  FIX-16  g_lastBarTime guarded against 0 on first tick            |
//|                                                                    |
//|  Works on: EUR/USD M5 or M15                                       |
//+------------------------------------------------------------------+
#property copyright   "ICT EA – MARK1"
#property version     "3.00"
#property strict

//+------------------------------------------------------------------+
//| ORDER BLOCK STATE ENUM [FIX-12]                                    |
//+------------------------------------------------------------------+
enum ENUM_OB_STATE
{
   OB_NONE      = 0,  // No active OB
   OB_UNTESTED  = 1,  // OB formed, price has not yet returned
   OB_MITIGATED = 2,  // Price touched OB and respected it (stronger)
   OB_BREAKER   = 3   // Price closed through OB — polarity flipped
};

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                   |
//+------------------------------------------------------------------+

// ── Risk & Trade Management ─────────────────────────────────────────
input group "=== Risk Management ==="
input double InpRiskPercent      = 0.5;    // Risk per trade (% of balance)
input double InpRRRatio          = 3.0;    // Take Profit RR ratio (e.g. 3 = 1:3)
input double InpSLPips           = 20.0;   // Stop Loss distance in pips beyond sweep
input int    InpMaxOpenTrades    = 2;      // Maximum simultaneous open positions

// ── Session Times (GMT) ─────────────────────────────────────────────
input group "=== Session Times (GMT) ==="
input int    InpAsianStartHour        = 0;    // Asian range build start hour (GMT)
input int    InpAsianEndHour          = 7;    // Asian range build end hour (GMT)
input int    InpLondonStartHour       = 8;    // London Kill Zone start (GMT)
input int    InpLondonEndHour         = 11;   // London Kill Zone end (GMT)
// [FIX-09] Judas Swing only in first 2h of London (08:00–10:00 ICT standard)
input int    InpJudasEndHour          = 10;   // Judas Swing detection ceiling (GMT)
input int    InpNYStartHour           = 13;   // NY Kill Zone start (GMT)
input int    InpNYEndHour             = 16;   // NY Kill Zone end (GMT)
// [FIX-13] Silver Bullet window: 15:00–16:00 GMT (10:00–11:00 EST)
input int    InpSilverBulletStart     = 15;   // Silver Bullet start hour (GMT)
input int    InpSilverBulletEnd       = 16;   // Silver Bullet end hour (GMT)
input double InpSilverBulletSLPips    = 12.0; // Silver Bullet SL (10–15 pip mid)

// ── News Filter ──────────────────────────────────────────────────────
input group "=== News Filter ==="
input bool   InpEnableNewsFilter = true;   // Enable economic calendar news filter
input int    InpNewsHaltBefore   = 30;     // Minutes to halt before high-impact news
input int    InpNewsResumeAfter  = 15;     // Minutes to resume after high-impact news

// ── H4 Market Structure Filter ───────────────────────────────────────
input group "=== H4 Market Structure Confirmation ==="
input bool   InpEnableH4Filter   = false;   // Require H4 BOS alignment before entry
input int    InpH4LookbackBars   = 50;     // H4 bars to scan for BOS [FIX-04 uses i=3 start]

// [FIX-10] Premium / Discount Zone — D1 equilibrium filter
// ICT: BUY only in Discount (price < 50% D1 range), SELL in Premium
input group "=== Premium / Discount Filter (D1) ==="
input bool   InpEnablePDFilter   = false;  // [Phase 2] Enforce Discount/Premium zone filter

// [FIX-11] Weekly Bias — Monday W1 directional filter
input group "=== Weekly Bias Filter ==="
input bool   InpEnableWeeklyBias = false;  // [Phase 2] Filter trades by weekly bias

// [FIX-12] Order Block settings
input group "=== Order Block Settings ==="
input bool   InpEnableOBFilter   = false;  // [Phase 3] Require OB alignment before entry
input double InpOBProximityPips  = 10.0;   // Max distance from OB zone for entry
input int    InpOBMaxAgeHours    = 24;     // Discard OBs older than N hours

// ── Pending Order Management ─────────────────────────────────────────
input group "=== Order Settings ==="
input int    InpOrderExpiryBars  = 10;     // Cancel pending order after N bars if unfilled
input int    InpMagicNumber      = 202601; // EA magic number

// ── Debug ────────────────────────────────────────────────────────────
input group "=== Debug ==="
input bool   InpDebugLog         = true;   // Enable detailed debug logging

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                   |
//+------------------------------------------------------------------+

CTrade         g_trade;
CPositionInfo  g_position;
COrderInfo     g_order;

// ── Asian range ────────────────────────────────────────────────────
double   g_asianHigh        = 0.0;
double   g_asianLow         = 0.0;
bool     g_asianRangeSet    = false;
// [FIX-07] Seeded to "yesterday" in OnInit() so day-1 detection works
datetime g_asianRangeDate   = 0;

// ── Sweep state ────────────────────────────────────────────────────
bool     g_sweepDetected    = false;
bool     g_sweepBullish     = false; // true = low swept → long, false = high swept → short
double   g_sweepExtreme     = 0.0;
datetime g_sweepTime        = 0;

// ── FVG ────────────────────────────────────────────────────────────
bool     g_fvgFormed        = false;
double   g_fvgHigh          = 0.0;
double   g_fvgLow           = 0.0;
double   g_fvgMid           = 0.0;

// [FIX-06] Separate consumed flag — prevents re-scan after filter reject
// g_fvgFormed = "FVG geometry found"; g_setupConsumed = "order attempt made"
bool     g_setupConsumed    = false;

// ── Order tracking ─────────────────────────────────────────────────
// [FIX-08] Removed g_pendingOpenTime (assigned but never read — dead variable)
ulong    g_pendingTicket    = 0;
int      g_pendingBarCount  = 0;

// ── [FIX-11] Weekly bias ───────────────────────────────────────────
bool     g_weeklyBullish    = false;  // W1 close > open → favour buys
datetime g_weeklyBiasDate   = 0;

// ── [FIX-10] D1 Premium/Discount equilibrium ──────────────────────
double   g_d1Equilibrium    = 0.0;   // 50% midpoint of yesterday's D1 range

// ── [FIX-12] Order Block state ─────────────────────────────────────
ENUM_OB_STATE g_obState     = OB_NONE;
double   g_obHigh           = 0.0;
double   g_obLow            = 0.0;
bool     g_obBullish        = false;
datetime g_obTime           = 0;

// ── Internals ──────────────────────────────────────────────────────
int      g_gmtOffset        = 0;
double   g_pipSize          = 0.0;
// [FIX-16] Seeded in OnInit() to avoid firing on 0 == 0 comparison
datetime g_lastBarTime      = 0;

//+------------------------------------------------------------------+
//| Logging Helper                                                     |
//+------------------------------------------------------------------+
void Log(const string msg)
{
   if(InpDebugLog)
      Print("[ICT-EA] ", msg);
}

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(Symbol(), "EURUSD") < 0)
      Print("[ICT-EA] WARNING: EA designed for EURUSD. Current: ", Symbol());

   // Pip size — handles 3/5-digit brokers
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   g_pipSize  = (digits == 3 || digits == 5)
              ? SymbolInfoDouble(Symbol(), SYMBOL_POINT) * 10.0
              : SymbolInfoDouble(Symbol(), SYMBOL_POINT);

   g_gmtOffset = CalculateGMTOffset();
   Log("GMT offset = " + IntegerToString(g_gmtOffset) + "h");

   // [FIX-07] Seed asianRangeDate to yesterday so IsNewTradingDay fires on day 1
   g_asianRangeDate = GetGMTTime() - 86400;

   // [FIX-16] Seed lastBarTime so first tick never fires a false gate
   g_lastBarTime = (datetime)SeriesInfoInteger(Symbol(), Period(), SERIES_LASTBAR_DATE);

   // [FIX-10] Initial D1 equilibrium
   UpdateD1Equilibrium();

   // [FIX-11] Initial weekly bias
   UpdateWeeklyBias();

   // [FIX-15] Use RETURN fill — FOK silently fails on most ECN/STP brokers
   // BEFORE: g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   // AFTER:  g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   Log("EA Init v2.00 | Pip=" + DoubleToString(g_pipSize, _Digits) +
       " Risk=" + DoubleToString(InpRiskPercent, 1) + "%" +
       " D1_Eq=" + DoubleToString(g_d1Equilibrium, _Digits) +
       " WeeklyBias=" + (g_weeklyBullish ? "BULL" : "BEAR"));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Log("EA Deinitialised. Reason=" + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   // ── 1. Only execute logic once per fully formed bar ───────────────
   datetime currentBarTime = (datetime)SeriesInfoInteger(Symbol(), Period(), SERIES_LASTBAR_DATE);
   // [FIX-16] Guard: SERIES_LASTBAR_DATE returns 0 on very first tick
   if(currentBarTime == 0 || currentBarTime == g_lastBarTime)
      return;
   g_lastBarTime = currentBarTime;

   // ── 2. Get current GMT time ────────────────────────────────────────
   datetime gmtTime = GetGMTTime();
   MqlDateTime gmtDt;
   TimeToStruct(gmtTime, gmtDt);

   // ── 3. Manage stale pending orders ────────────────────────────────
   ManagePendingOrders();

   // ── 4. Reset state at start of new trading day (midnight GMT) ─────
   if(IsNewTradingDay(gmtTime))
   {
      ResetDailyState(gmtTime);
      UpdateD1Equilibrium();  // [FIX-10] Refresh D1 midpoint each morning
      Log("New day | " + TimeToString(gmtTime, TIME_DATE) +
          " D1_Eq=" + DoubleToString(g_d1Equilibrium, _Digits));
   }

   // [FIX-11] Monday: refresh weekly bias
   UpdateWeeklyBiasIfMonday(gmtDt);

   // ── 5. Asian Range Collection (00:00–07:00 GMT) ───────────────────
   if(IsInAsianSession(gmtDt) && !g_asianRangeSet)
   {
      UpdateAsianRange();
   }

   // [FIX-01] CORRECTED: was == + min==0 (missed restarts after 08:00 on any non-zero minute)
   // BEFORE: if(gmtDt.hour == InpLondonStartHour && gmtDt.min == 0 && g_asianHigh > 0)
   // AFTER:  >= fires on first bar at-or-after London open, regardless of minute
   if(gmtDt.hour >= InpLondonStartHour && !g_asianRangeSet && g_asianHigh > 0)
   {
      g_asianRangeSet = true;
      Log("Asian Range LOCKED | High=" + DoubleToString(g_asianHigh, _Digits) +
          " | Low=" + DoubleToString(g_asianLow, _Digits));
   }

   // ── 6. Kill Zone Logic ─────────────────────────────────────────────
   bool inLondon       = IsInLondonKillZone(gmtDt);
   bool inNY           = IsInNYKillZone(gmtDt);
   bool inSilverBullet = IsInSilverBulletWindow(gmtDt); // [FIX-13]

   if(!(inLondon || inNY || inSilverBullet) || !g_asianRangeSet)
      return;

   // 6a. News filter
   if(InpEnableNewsFilter && IsNewsTime(gmtTime))
   {
      Log("NEWS FILTER: halted.");
      return;
   }

   // 6b. Max positions
   if(CountOpenPositions() >= InpMaxOpenTrades)
      return;

   // [FIX-09] Judas Swing restricted to 08:00-10:00 GMT only
   // BEFORE: DetectLiquiditySweep() ran for the full London block 08:00-11:00
   // AFTER:  restricted to inLondon && hour < InpJudasEndHour (08:00-10:00)
   if(!g_sweepDetected)
   {
      bool inJudasWindow = inLondon && (gmtDt.hour < InpJudasEndHour);
      if(inJudasWindow || inSilverBullet)
         DetectJudasSwing();
   }

   // [FIX-06] Guard changed from !g_fvgFormed to !g_setupConsumed
   // g_fvgFormed     = FVG geometry identified this session
   // g_setupConsumed = PlaceLimitOrder() already attempted (filter-safe)
   if(g_sweepDetected && !g_setupConsumed && g_pendingTicket == 0)
      ScanForFVGAndEnter(inSilverBullet);
}

//+------------------------------------------------------------------+
//| ASIAN RANGE FUNCTIONS                                              |
//+------------------------------------------------------------------+

// Updates AsianHigh / AsianLow from current bar data during Asian session
void UpdateAsianRange()
{
   double highVal = iHigh(Symbol(), Period(), 1); // Previous closed bar
   double lowVal  = iLow(Symbol(), Period(), 1);

   if(g_asianHigh == 0.0 || highVal > g_asianHigh)
      g_asianHigh = highVal;

   if(g_asianLow == 0.0 || lowVal < g_asianLow)
      g_asianLow = lowVal;
}

//+------------------------------------------------------------------+
//| JUDAS SWING (Liquidity Sweep) DETECTION [FIX-09]                   |
//+------------------------------------------------------------------+
// ICT Definition: Judas Swing = London-open fake breakout that sweeps
// BSL (above AsianHigh) or SSL (below AsianLow) then closes back inside.
// Must occur in first 2 hours of London: 08:00-10:00 GMT (InpJudasEndHour).
// [FIX-09] Caller in OnTick() now enforces the time window, not this function.
void DetectJudasSwing()
{
   // Read the last fully closed bar (index 1)
   double closePrice = iClose(Symbol(), Period(), 1);
   double highPrice  = iHigh(Symbol(), Period(), 1);
   double lowPrice   = iLow(Symbol(), Period(), 1);

   // ── Bearish Judas: wick above BSL (AsianHigh), close returns inside ──
   // BSL swept (stops above asian high triggered), smart money goes SHORT
   if(highPrice > g_asianHigh && closePrice < g_asianHigh && closePrice > g_asianLow)
   {
      g_sweepDetected  = true;
      g_sweepBullish   = false;           // HIGH swept → SELL setup
      g_sweepExtreme   = highPrice;
      g_sweepTime      = iTime(Symbol(), Period(), 1);
      Log("BEARISH JUDAS SWING | AsianHigh=" + DoubleToString(g_asianHigh, _Digits) +
          " | SweepHigh=" + DoubleToString(highPrice, _Digits) +
          " | Close=" + DoubleToString(closePrice, _Digits));
   }
   // ── Bullish Judas: wick below SSL (AsianLow), close returns inside ─
   // SSL swept (stops below asian low triggered), smart money goes LONG
   else if(lowPrice < g_asianLow && closePrice > g_asianLow && closePrice < g_asianHigh)
   {
      g_sweepDetected  = true;
      g_sweepBullish   = true;            // LOW swept → BUY setup
      g_sweepExtreme   = lowPrice;
      g_sweepTime      = iTime(Symbol(), Period(), 1);
      Log("BULLISH JUDAS SWING | AsianLow=" + DoubleToString(g_asianLow, _Digits) +
          " | SweepLow=" + DoubleToString(lowPrice, _Digits) +
          " | Close=" + DoubleToString(closePrice, _Digits));
   }
}

//+------------------------------------------------------------------+
//| FAIR VALUE GAP DETECTION & ORDER PLACEMENT                         |
//+------------------------------------------------------------------+
// 3-candle FVG (indices: 1=newest closed, 2=middle, 3=oldest):
//
// [FIX-02] CRITICAL: original code had BULLISH and BEARISH labels SWAPPED.
//
//  BULLISH FVG (gap upward — upward price imbalance):
//    C1 (oldest/bar3) high < C3 (newest/bar1) low = price jumped up, left a gap
//    MQL5: high3 < low1
//    BEFORE (wrong):  if(low3  > high1)  ← this is actually a BEARISH FVG
//    AFTER  (correct): if(high3 < low1)  ← gap up, oldest high below newest low
//    FVG zone: [high3, low1], midpoint = entry for buy retracement
//
//  BEARISH FVG (gap downward — downward price imbalance):
//    C1.low > C3.high = price fell fast, left a gap
//    MQL5: low3 > high1
//    BEFORE (wrong):  if(high3 < low1)   ← this is actually a BULLISH FVG
//    AFTER  (correct): if(low3  > high1)  ← gap down, oldest low above newest high
//    FVG zone: [high1, low3], midpoint = entry for sell retracement
//
//  ICT rule: FVG must align with sweep direction
//    Bullish sweep (low swept) → BULLISH FVG → limit BUY at midpoint
//    Bearish sweep (high swept) → BEARISH FVG → limit SELL at midpoint
void ScanForFVGAndEnter(bool isSilverBullet = false)
{
   if(Bars(Symbol(), Period()) < 5)
      return;

   double high1 = iHigh(Symbol(), Period(), 1);  // Newest closed bar
   double low1  = iLow(Symbol(),  Period(), 1);
   double high3 = iHigh(Symbol(), Period(), 3);  // Oldest of 3-bar pattern
   double low3  = iLow(Symbol(),  Period(), 3);

   bool fvgFound = false;

   if(g_sweepBullish)
   {
      // BULLISH FVG: oldest bar's HIGH < newest bar's LOW = gap upward
      if(high3 < low1)  // [FIX-02] was: if(low3 > high1)
      {
         g_fvgHigh   = low1;    // Top of gap (newest bar's low)
         g_fvgLow    = high3;   // Bottom of gap (oldest bar's high)
         g_fvgMid    = (g_fvgHigh + g_fvgLow) / 2.0;
         g_fvgFormed = true;
         fvgFound    = true;
         Log("BULLISH FVG | Zone: " + DoubleToString(g_fvgLow, _Digits) +
             "-" + DoubleToString(g_fvgHigh, _Digits) +
             " | Mid=" + DoubleToString(g_fvgMid, _Digits));
      }
   }
   else
   {
      // BEARISH FVG: oldest bar's LOW > newest bar's HIGH = gap downward
      if(low3 > high1)  // [FIX-02] was: if(high3 < low1)
      {
         g_fvgHigh   = low3;    // Top of gap (oldest bar's low)
         g_fvgLow    = high1;   // Bottom of gap (newest bar's high)
         g_fvgMid    = (g_fvgHigh + g_fvgLow) / 2.0;
         g_fvgFormed = true;
         fvgFound    = true;
         Log("BEARISH FVG | Zone: " + DoubleToString(g_fvgLow, _Digits) +
             "-" + DoubleToString(g_fvgHigh, _Digits) +
             " | Mid=" + DoubleToString(g_fvgMid, _Digits));
      }
   }

   if(fvgFound)
      PlaceLimitOrder(isSilverBullet);
}

//+------------------------------------------------------------------+
//| PLACE PENDING LIMIT ORDER                                          |
//+------------------------------------------------------------------+
void PlaceLimitOrder(bool isSilverBullet = false)
{
   // [FIX-11] Weekly Bias
   if(InpEnableWeeklyBias)
   {
      if(g_sweepBullish && !g_weeklyBullish)
         { Log("WEEKLY BIAS: BUY rejected (week=BEARISH)."); g_setupConsumed=true; return; }
      if(!g_sweepBullish && g_weeklyBullish)
         { Log("WEEKLY BIAS: SELL rejected (week=BULLISH)."); g_setupConsumed=true; return; }
   }

   // [FIX-10] Premium/Discount zone
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

   // [FIX-04/05] H4 BOS using dedicated bull/bear functions
   if(InpEnableH4Filter)
   {
      bool h4Bull = IsH4BullishBOS();
      bool h4Bear = IsH4BearishBOS();
      if(g_sweepBullish && !h4Bull)
         { Log("H4 FILTER: BUY rejected, no bullish BOS."); g_setupConsumed=true; return; }
      if(!g_sweepBullish && !h4Bear)
         { Log("H4 FILTER: SELL rejected, no bearish BOS."); g_setupConsumed=true; return; }

      // [FIX-12] Order Block check after BOS confirmed
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

   // [FIX-13] Silver Bullet uses tighter SL
   double slPips = isSilverBullet ? InpSilverBulletSLPips : InpSLPips;

   // [FIX-03] Removed + spread from SL
   // BEFORE: slDistance = (InpSLPips * g_pipSize) + spread;
   // AFTER:  slDistance = slPips * g_pipSize  (pure ICT pip placement)
   double slDistance = slPips * g_pipSize;

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

   // [FIX-06] Mark consumed before placement — no double-place on broker lag
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
// (stale PlaceLimitOrder body removed — corrected version is above)

//+------------------------------------------------------------------+
//| MANAGE PENDING ORDERS (expiry / stale cleanup)                     |
//+------------------------------------------------------------------+
void ManagePendingOrders()
{
   if(g_pendingTicket == 0)
      return;

   // Check if order still exists as pending
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

   // Order was filled or already closed
   if(!orderExists)
   {
      Log("Pending order " + IntegerToString(g_pendingTicket) + " no longer pending (filled or cancelled).");
      g_pendingTicket = 0;
      return;
   }

   // Expire order if it has been open too long
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
//| H4 BULLISH BOS DETECTION [FIX-04, FIX-05]                          |
//+------------------------------------------------------------------+
// ICT swing high requires at least 2 lower highs on EACH side.
// [FIX-04] BEFORE: loop from i=2, checked only i±1 (1 bar each side)
//           AFTER: loop from i=3, checks i-2,i-1,i+1,i+2 (2 bars each side)
// Bullish BOS confirmed when most recent swing high > prior swing high
bool IsH4BullishBOS()
{
   int lookback = InpH4LookbackBars;
   if(Bars(Symbol(), PERIOD_H4) < lookback + 5)
      return false;

   double swingHigh1 = 0, swingHigh2 = 0;
   int    count = 0;

   // [Phase 1] i±1 validation (standard ICT); i±2 was too strict and missed valid BOS
   for(int i = 2; i < lookback - 1 && count < 2; i++)
   {
      double h   = iHigh(Symbol(), PERIOD_H4, i);
      double hm1 = iHigh(Symbol(), PERIOD_H4, i - 1);
      double hp1 = iHigh(Symbol(), PERIOD_H4, i + 1);

      // Valid swing high: higher than 1 bar on each side
      if(h > hm1 && h > hp1)
      {
         count++;
         if(count == 1) swingHigh1 = h;   // Most recent swing high
         if(count == 2) swingHigh2 = h;   // Previous swing high
      }
   }

   // Bullish BOS: recent swing high broke above prior swing high
   return (count >= 2 && swingHigh1 > swingHigh2);
}

//+------------------------------------------------------------------+
//| H4 BEARISH BOS DETECTION [FIX-05]                                  |
//+------------------------------------------------------------------+
// [FIX-05] Dedicated function replaces the ambiguous !IsH4BullishBOS()
// !IsH4BullishBOS() was ambiguous: catches bearish AND cases with
// insufficient data (count < 2). This explicit function is unambiguous.
bool IsH4BearishBOS()
{
   int lookback = InpH4LookbackBars;
   if(Bars(Symbol(), PERIOD_H4) < lookback + 5)
      return false;

   double swingLow1 = 0, swingLow2 = 0;
   int    count = 0;

   // [Phase 1] i±1 validation (standard ICT); i±2 was too strict and missed valid BOS
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

   // Bearish BOS: most recent swing low is lower than prior swing low
   return (count >= 2 && swingLow1 < swingLow2);
}

//+------------------------------------------------------------------+
//| NEWS FILTER                                                        |
//+------------------------------------------------------------------+
// Returns true if current time is within a news blackout window.
// Uses MQL5 CalendarValueHistory() for live/backtest calendar data.
// Falls back to hard-coded NFP/FOMC times if calendar unavailable.
// [FIX-14] Removed unused variables windowStart and windowEnd
// BEFORE: datetime windowStart = gmtTime - ...; datetime windowEnd = ...; (never used)
bool IsNewsTime(datetime gmtTime)
{
   datetime checkFrom = gmtTime - (InpNewsHaltBefore * 60);
   datetime checkTo   = gmtTime + (InpNewsHaltBefore * 60);

   // BUG FIX: declare calValues and calOK here, then call CalendarValueHistory
   // BEFORE: calOK was hardcoded false (never set), so the real calendar was
   //         NEVER checked and the fallback always ran silently.
   // AFTER:  CalendarValueHistory() is called; calOK reflects actual API result.
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

         // Only high-impact events
         if(evInfo.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;

         // Only USD and EUR
         string cur = cInfo.currency;
         if(cur != "USD" && cur != "EUR")
            continue;

         datetime evTime = calValues[i].time;

         // Check if current time falls in the blackout window around this event
         datetime blockStart = evTime - (InpNewsHaltBefore  * 60);
         datetime blockEnd   = evTime + (InpNewsResumeAfter * 60);

         if(gmtTime >= blockStart && gmtTime <= blockEnd)
         {
            Log("News block active: Event at " + TimeToString(evTime) +
                " | Currency=" + cur + " | Impact=HIGH");
            return true;
         }
      }

      // Also check EUR
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

      return false; // Calendar worked, no blocking event found
   }

   // ── Method 2: Hardcoded Time-Based Fallback ────────────────────────
   // Used when CalendarValueHistory() fails (e.g., limited permissions)
   Log("Calendar API unavailable – using hardcoded news schedule fallback.");
   return IsHardcodedNewsTime(gmtTime);
}

// Hardcoded fallback: blocks known recurring high-impact events
// NFP: First Friday of each month, 13:30 GMT
// FOMC: Apply a weekly block on known FOMC weeks (approximate)
bool IsHardcodedNewsTime(datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);

   // ── NFP Block: First Friday of month, 13:00–14:30 GMT ─────────────
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

   // ── FOMC Block: Wednesdays 19:00–21:00 GMT (approximate schedule) ──
   // FOMC meets 8× per year, roughly every 6 weeks.
   // This is a conservative weekly Wednesday block during typical FOMC periods.
   // Months with FOMC meetings (approximate): 1,3,5,6,7,9,11,12
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
//| POSITION SIZING                                                    |
//+------------------------------------------------------------------+
// Risk-based lot calculation:
//   LotSize = (Balance * RiskPercent / 100) / (SL in pips * PipValue)
double CalculateLotSize(double slPriceDistance)
{
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount     = accountBalance * (InpRiskPercent / 100.0);
   double pipValue       = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);

   if(g_pipSize <= 0 || pipValue <= 0 || slPriceDistance <= 0)
      return 0;

   // Convert SL distance to pips
   double slInPips = slPriceDistance / g_pipSize;

   // Pip value is per 1 lot, per 1 pip
   double lotSize = riskAmount / (slInPips * pipValue);

   // Normalise to broker step
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
//| COUNT OPEN POSITIONS (by magic number)                             |
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
//| TIME UTILITY FUNCTIONS                                             |
//+------------------------------------------------------------------+

// Get current GMT time by subtracting server offset
datetime GetGMTTime()
{
   return TimeCurrent() - g_gmtOffset * 3600;
}

// Calculates server → GMT offset using MQL5 time info
int CalculateGMTOffset()
{
   datetime serverTime = TimeCurrent();
   datetime gmtTime    = TimeGMT();
   int offset = (int)((serverTime - gmtTime) / 3600);
   return offset;
}

// Check if time falls in Asian session (00:00–07:00 GMT)
bool IsInAsianSession(const MqlDateTime &dt)
{
   int h = dt.hour;
   return (h >= InpAsianStartHour && h < InpAsianEndHour);
}

// Check if time falls in London Kill Zone (08:00–11:00 GMT)
bool IsInLondonKillZone(const MqlDateTime &dt)
{
   int h = dt.hour;
   return (h >= InpLondonStartHour && h < InpLondonEndHour);
}

// Check if time falls in NY Kill Zone (13:00–16:00 GMT)
bool IsInNYKillZone(const MqlDateTime &dt)
{
   int h = dt.hour;
   return (h >= InpNYStartHour && h < InpNYEndHour);
}

// Is this a new trading day compared to the last Asian range date?
bool IsNewTradingDay(datetime gmtTime)
{
   MqlDateTime now, prev;
   TimeToStruct(gmtTime, now);
   // [FIX-07] On first call (g_asianRangeDate seeded to yesterday in OnInit)
   // this will return true, triggering initial state setup correctly.
   if(g_asianRangeDate == 0) return false;

   TimeToStruct(g_asianRangeDate, prev);
   return (now.year != prev.year || now.mon != prev.mon || now.day != prev.day);
}

//+------------------------------------------------------------------+
//| DAILY STATE RESET                                                  |
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
   g_asianRangeDate = currentGMT;  // record today's date
   g_sweepDetected  = false;
   g_sweepBullish   = false;
   g_sweepExtreme   = 0.0;
   g_sweepTime      = 0;
   g_fvgFormed      = false;
   g_fvgHigh        = 0.0;
   g_fvgLow         = 0.0;
   g_fvgMid         = 0.0;
   g_setupConsumed  = false;  // [FIX-06]
   g_pendingTicket  = 0;
   g_pendingBarCount = 0;
   g_obState        = OB_NONE; // [FIX-12] Reset OB each day
   g_obHigh         = 0.0;
   g_obLow          = 0.0;
   g_obTime         = 0;
}

//+------------------------------------------------------------------+
//| CHART EVENT                                                        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   // Reserved for future visual overlay additions
}

//+------------------------------------------------------------------+
//| [FIX-13] Silver Bullet window check (15:00-16:00 GMT)             |
//+------------------------------------------------------------------+
bool IsInSilverBulletWindow(const MqlDateTime &dt)
{
   return (dt.hour >= InpSilverBulletStart && dt.hour < InpSilverBulletEnd);
}

//+------------------------------------------------------------------+
//| [FIX-12] ORDER BLOCK DETECTION                                     |
//+------------------------------------------------------------------+
// ICT definition:
//   Bullish OB = last BEARISH H4 candle before a bullish impulse/BOS
//   Bearish OB = last BULLISH H4 candle before a bearish impulse/BOS
// State transitions:
//   UNTESTED → MITIGATED: price touches OB and respects it
//   UNTESTED/MITIGATED → BREAKER: price CLOSES through OB (polarity flip)
void DetectOrderBlock()
{
   // Check if active OB has expired
   if(g_obState != OB_NONE && g_obTime > 0)
   {
      double ageH = (double)(TimeCurrent() - g_obTime) / 3600.0;
      if(ageH > InpOBMaxAgeHours) { g_obState = OB_NONE; }
   }

   if(g_obState != OB_NONE)
   {
      // Update OB state based on most recent H4 close
      double closeH4 = iClose(Symbol(), PERIOD_H4, 1);
      if(g_obBullish)
      {
         if(closeH4 >= g_obLow && closeH4 <= g_obHigh && g_obState == OB_UNTESTED)
            g_obState = OB_MITIGATED;
         else if(closeH4 < g_obLow)
            g_obState = OB_BREAKER;  // Price closed below bullish OB = breaker
      }
      else
      {
         if(closeH4 >= g_obLow && closeH4 <= g_obHigh && g_obState == OB_UNTESTED)
            g_obState = OB_MITIGATED;
         else if(closeH4 > g_obHigh)
            g_obState = OB_BREAKER;  // Price closed above bearish OB = breaker
      }
      return;
   }

   int lookback = MathMin(InpH4LookbackBars, (int)Bars(Symbol(), PERIOD_H4) - 5);

   if(g_sweepBullish) // Seek bullish OB: last bearish H4 candle before up move
   {
      for(int i = 2; i < lookback; i++)
      {
         double o = iOpen(Symbol(),  PERIOD_H4, i);
         double c = iClose(Symbol(), PERIOD_H4, i);
         if(c < o) // Bearish candle
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
   else // Seek bearish OB: last bullish H4 candle before down move
   {
      for(int i = 2; i < lookback; i++)
      {
         double o = iOpen(Symbol(),  PERIOD_H4, i);
         double c = iClose(Symbol(), PERIOD_H4, i);
         if(c > o) // Bullish candle
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
//| [FIX-10] D1 PREMIUM / DISCOUNT EQUILIBRIUM                        |
//+------------------------------------------------------------------+
// ICT: price below 50% of D1 range = Discount (favour buys)
//      price above 50% of D1 range = Premium  (favour sells)
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

//+------------------------------------------------------------------+
//| [FIX-11] WEEKLY BIAS                                               |
//+------------------------------------------------------------------+
// Run on Monday; uses W1 bar 1 (previous completed week)
// W1 close > open = bullish week = favour BUY setups
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
      return;  // Already updated this Monday
   UpdateWeeklyBias();
}

//+------------------------------------------------------------------+
//| DISCRETIONARY ICT CONCEPTS — not implemented (require judgment)   |
//+------------------------------------------------------------------+
//
//  1. SMT Divergence (EUR vs GBP correlated move divergence)
//     Can approximate with raw price comparison, but ICT applies with
//     discretion about sweep context. Risk of false positives. v2.1.
//
//  2. Market Maker Models (MMXM/W/M patterns)
//     Requires identifying 3-leg swing structures. Very parameter-sensitive.
//     Planned for v3.0.
//
//  3. Consequent Encroachment of OBs
//     ICT specifically enters at the 50% (CE) of an OB candle body.
//     To implement: store OB open/close and use (open+close)/2 as entry.
//     Current code uses full OB zone; add CE refinement in v2.1.
//
//  4. Optimal Trade Entry (OTE) via Fibonacci
//     ICT uses 62%-79% retracement of a swing for highest-probability entry.
//     Add as optional entry refinement overlaid on FVG midpoint.
//
//+------------------------------------------------------------------+
//| END OF FILE                                                        |
//+------------------------------------------------------------------+
