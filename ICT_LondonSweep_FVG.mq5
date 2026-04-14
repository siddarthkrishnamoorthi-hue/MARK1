//+------------------------------------------------------------------+
//|  ICT_LondonSweep_FVG.mq5                                         |
//|  MARK1 v4.1 — Institutional-Grade ICT Methodology                |
//|  Strategy: Asian Range → Judas Swing → FVG → OTE Limit Entry     |
//|  Target: FTMO Standard Challenge | Platform: EURUSD M15          |
//|                                                                    |
//|  7-Gate entry model:                                              |
//|    G1 Session → G2 Asian Range → G3 Sweep Confirm → G4 Displace  |
//|    → G5 FVG → G6 OTE Limit Order → G7 H4 Bias (lot scale)       |
//|                                                                    |
//|  v4.1 fixes (tagged [MARK1-FIX-XX]):                             |
//|  FIX-17: BUG-2 — filter rejections no longer set g_setupConsumed |
//|  FIX-18: BUG-3 — NY session sweeps off London range, not Asian   |
//|  FIX-19: BUG-4 — Silver Bullet fully independent (own sweep/FVG) |
//|  FIX-20: BUG-5 — SL = structure-based (asianLow±0.2×range)      |
//|  FIX-21: Gate stat counters + daily summary log                   |
//+------------------------------------------------------------------+
#property copyright   "ICT EA – MARK1 v4.1"
#property version     "4.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| ENUMERATIONS                                                       |
//+------------------------------------------------------------------+

enum ENUM_EA_STATE
{
   STATE_IDLE,           // Waiting for Asian session / daily reset
   STATE_AWAITING_SWEEP, // Asian range locked; scanning for Judas sweep
   STATE_AWAITING_FVG,   // Sweep confirmed; scanning for FVG & OTE
   STATE_PENDING_ENTRY,  // Limit order placed; managing expiry
   STATE_IN_TRADE        // Position open; managed in ManageOpenPositions()
};

enum ENUM_OB_STATE
{
   OB_NONE      = 0,
   OB_UNTESTED  = 1,
   OB_MITIGATED = 2,
   OB_BREAKER   = 3
};

//+------------------------------------------------------------------+
//| NAMED CONSTANTS                                                    |
//+------------------------------------------------------------------+
static const double SL_STRUCTURE_BUFFER = 0.2;  // [FIX-20] SL = asianLow - 0.2*range
static const int    MIN_SL_PIPS         = 12;   // [FIX-20] Clamp floor
static const int    MAX_SL_PIPS         = 45;   // [FIX-20] Clamp ceiling
static const int    LONDON_START_GMT    = 7;
static const int    LONDON_END_GMT      = 10;
static const int    LONDON_RANGE_END    = 12;   // [FIX-18] London range captured 07-12
static const int    SILVER_BULLET_START = 10;   // [FIX-19] Silver Bullet: 10-11 GMT
static const int    SILVER_BULLET_END   = 11;
static const int    NY_START_GMT        = 13;
static const int    NY_END_GMT          = 16;
static const int    NY_MORNING_END      = 15;   // [FIX-19] NY morning range: 13-15 GMT
static const int    FRIDAY_CUTOFF_GMT   = 20;
static const int    CONSEC_LOSSES_HALF  = 2;
static const int    CONSEC_LOSSES_STOP  = 4;
static const int    ATR_M15_PERIOD      = 14;
static const int    ATR_H4_PERIOD       = 14;

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                   |
//+------------------------------------------------------------------+

input group "=== Risk Management ==="
input double InpRiskPercent            = 0.5;   // Base risk per trade (% of equity)
input double InpMaxDailyLossPct        = 4.0;   // Max daily loss % — halt today (FTMO: 5%)
input double InpMaxTotalDDPct          = 8.0;   // Max total DD % — halt EA (FTMO: 10%)
input double InpWeeklyDDSoftCapPct     = 3.5;   // Weekly DD soft cap → 50% lot size

input group "=== Asian Session ==="
input int    InpAsianStartGMT          = 0;     // Asian session start (GMT hour)
input int    InpAsianEndGMT            = 7;     // Asian session end / range lock (GMT hour)
input double InpMinAsianRangePips      = 8.0;   // Min Asian range — skip if compressed
input double InpMaxAsianRangePips      = 50.0;  // Max Asian range — skip if explosive
input int    InpSweepConfirmPips       = 2;     // Min wick outside Asian level (pips)

input group "=== Entry Settings ==="
input int    InpFVGScanBars            = 5;     // Bars to scan for FVG after sweep
input double InpMinFVGPips             = 3.0;   // Minimum FVG size (pips)
input int    InpOTEPercent             = 50;    // OTE entry depth into FVG (%)
input int    InpOrderExpiryBars        = 3;     // Cancel pending order after N bars
input int    InpMinDisplacementBodyPct = 60;    // Min displacement body as % of range
input int    InpMinDisplacementPips    = 6;     // Min displacement body size (pips)

input group "=== Exit Settings ==="
input double InpTP1RR                  = 1.0;   // TP1 R-multiple (60% partial close)
input double InpTP2RR                  = 2.0;   // TP2 R-multiple (remaining 40%)
input int    InpMaxTradeDurationHours  = 8;     // Force-close after N hours (no overnight)

input group "=== Silver Bullet ==="
input double InpSilverBulletSLPips     = 12.0;  // SL for Silver Bullet entries (pips)

input group "=== Regime Filters ==="
input bool   InpEnableH4Filter         = true;  // H4 BOS — reduce lots if failing
input double InpMinATRH4               = 30.0;  // H4 ATR(14) min pips — skip day below
input double InpMaxATRH4               = 120.0; // H4 ATR(14) max pips — reduce risk above
input int    InpNewsHaltMinutes        = 30;    // Halt ±N minutes around high-impact news
input bool   InpEnableTrendFilter      = false; // Enable D1 EMA200 trend gate

input group "=== Advanced Filters ==="
input bool   InpEnableWeeklyBias       = false; // Filter by W1 directional bias
input bool   InpEnablePDFilter         = false; // Enforce D1 discount/premium zone
input bool   InpEnableOBFilter         = false; // Require Order Block proximity
input double InpOBProximityPips        = 10.0;  // Max distance from OB zone (pips)
input int    InpOBMaxAgeHours          = 24;    // Discard OBs older than N hours
input int    InpH4LookbackBars         = 50;    // H4 bars to scan for BOS

input group "=== Order Settings ==="
input int    InpMagicNumber            = 202601;
input int    InpSlippagePoints         = 20;

input group "=== Debug ==="
input bool   InpEnableDebug            = true;  // Enable verbose debug logging

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                   |
//+------------------------------------------------------------------+

CTrade        g_trade;
CPositionInfo g_pos;
COrderInfo    g_ord;

// State machine (London + NY shared)
ENUM_EA_STATE g_state             = STATE_IDLE;

// Asian range
double        g_asianHigh         = 0.0;
double        g_asianLow          = 0.0;
bool          g_asianLocked       = false;

// [FIX-18] London range (07-12 GMT) — used as reference for NY sweeps
double        g_londonHigh        = 0.0;
double        g_londonLow         = 0.0;
bool          g_londonRangeSet    = false;

// [FIX-19] NY morning range (13-15 GMT) — used as reference for Silver Bullet sweeps
double        g_nyMorningHigh     = 0.0;
double        g_nyMorningLow      = 0.0;
bool          g_nyMorningRangeSet = false;

// London / NY sweep data
bool          g_sweepBullish      = false;
double        g_sweepExtreme      = 0.0;
datetime      g_sweepTime         = 0;

// [FIX-19] Silver Bullet independent sweep state
bool          g_sbSweepDetected   = false;
bool          g_sbSweepBullish    = false;
double        g_sbSweepExtreme    = 0.0;

// FVG data
double        g_fvgHigh           = 0.0;
double        g_fvgLow            = 0.0;

// Setup consumed flags (per-session — [FIX-17])
bool          g_londonConsumed    = false;  // London + Silver Bullet setup consumed
bool          g_nyConsumed        = false;  // NY setup consumed
bool          g_sbConsumed        = false;  // [FIX-19] Silver Bullet consumed
bool          g_setupConsumed     = false;  // General alias (resolved per session in OnTick)

// Daily trade direction guards
bool          g_tradedBuyToday    = false;
bool          g_tradedSellToday   = false;

// Pending order tracking
ulong         g_pendingTicket     = 0;
int           g_pendingBars       = 0;

// Open position tracking
datetime      g_tradeEntryTime    = 0;
bool          g_partialClosed     = false;

// PropFirm state
double        g_initialBalance    = 0.0;
double        g_dayStartEquity    = 0.0;
double        g_weekStartEquity   = 0.0;
bool          g_dailyHalt         = false;
bool          g_totalHalt         = false;
int           g_consecutiveLosses = 0;
int           g_dailyLossCount    = 0;

// Indicator handles
int           g_atrH4Handle       = INVALID_HANDLE;
int           g_atrM15Handle      = INVALID_HANDLE;
int           g_ema200Handle      = INVALID_HANDLE;

// Misc
double        g_pipSize           = 0.0;
datetime      g_lastBarTime       = 0;
datetime      g_lastDayReset      = 0;
datetime      g_lastWeekReset     = 0;

// Optional filter state
ENUM_OB_STATE g_obState           = OB_NONE;
double        g_obHigh            = 0.0;
double        g_obLow             = 0.0;
bool          g_obBullish         = false;
datetime      g_obTime            = 0;
bool          g_weeklyBullish     = false;
double        g_d1Equilibrium     = 0.0;

// [FIX-21] Gate stat counters — reset each day
int           g_statSweeps        = 0;
int           g_statFVG           = 0;
int           g_statDisplacement  = 0;
int           g_statH4            = 0;
int           g_statAsianFilter   = 0;
int           g_statATRFilter     = 0;
int           g_statOrders        = 0;

//+------------------------------------------------------------------+
//| LOGGING HELPER                                                     |
//+------------------------------------------------------------------+
void Log(const string msg)
{
   if(InpEnableDebug)
      Print("[MARK1] ", msg);
}

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(Symbol(), "EURUSD") < 0)
      Print("[MARK1] WARNING: Designed for EURUSD. Current symbol: ", Symbol());

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   g_pipSize  = (digits == 3 || digits == 5)
              ? SymbolInfoDouble(Symbol(), SYMBOL_POINT) * 10.0
              : SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   if(g_pipSize <= 0.0) { Print("[MARK1] INIT ERROR: Invalid pip size."); return INIT_FAILED; }

   if(InpFVGScanBars < 3)
   { Print("[MARK1] INIT ERROR: InpFVGScanBars must be >= 3."); return INIT_PARAMETERS_INCORRECT; }
   if(InpTP2RR <= InpTP1RR)
   { Print("[MARK1] INIT ERROR: InpTP2RR must be > InpTP1RR."); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxDailyLossPct >= 5.0)
      Print("[MARK1] WARNING: InpMaxDailyLossPct >= FTMO 5% limit. Reduce to stay inside.");
   if(InpMaxTotalDDPct >= 10.0)
      Print("[MARK1] WARNING: InpMaxTotalDDPct >= FTMO 10% limit. Reduce to stay inside.");

   g_atrH4Handle  = iATR(Symbol(), PERIOD_H4,  ATR_H4_PERIOD);
   g_atrM15Handle = iATR(Symbol(), PERIOD_M15, ATR_M15_PERIOD);
   g_ema200Handle = iMA(Symbol(),  PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(g_atrH4Handle  == INVALID_HANDLE) Print("[MARK1] WARNING: H4 ATR handle failed.");
   if(g_atrM15Handle == INVALID_HANDLE) Print("[MARK1] WARNING: M15 ATR handle failed.");
   if(g_ema200Handle == INVALID_HANDLE) Print("[MARK1] WARNING: D1 EMA200 handle failed.");

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   g_initialBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_weekStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastDayReset    = TimeGMT();
   g_lastWeekReset   = TimeGMT();
   g_lastBarTime     = (datetime)SeriesInfoInteger(Symbol(), Period(), SERIES_LASTBAR_DATE);

   UpdateD1Equilibrium();
   UpdateWeeklyBias();

   Log("INIT v4.1 | Balance=" + DoubleToString(g_initialBalance, 2) +
       " | MaxDailyDD=" + DoubleToString(InpMaxDailyLossPct, 1) + "%" +
       " | MaxTotalDD="  + DoubleToString(InpMaxTotalDDPct,  1) + "%" +
       " | H4Filter="    + (InpEnableH4Filter    ? "ON" : "OFF") +
       " | TrendFilter=" + (InpEnableTrendFilter ? "ON" : "OFF"));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrH4Handle  != INVALID_HANDLE) { IndicatorRelease(g_atrH4Handle);  g_atrH4Handle  = INVALID_HANDLE; }
   if(g_atrM15Handle != INVALID_HANDLE) { IndicatorRelease(g_atrM15Handle); g_atrM15Handle = INVALID_HANDLE; }
   if(g_ema200Handle != INVALID_HANDLE) { IndicatorRelease(g_ema200Handle); g_ema200Handle = INVALID_HANDLE; }
   Log("DEINIT | Reason=" + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // PropFirm kill switches run EVERY tick (floating equity)
   if(!CheckPropFirmLimits()) return;

   // Position management runs EVERY tick
   ManageOpenPositions();

   // Bar gate — strategy logic only on new bars
   datetime barTime = (datetime)SeriesInfoInteger(Symbol(), Period(), SERIES_LASTBAR_DATE);
   if(barTime == 0 || barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   datetime gmtNow = TimeGMT();
   MqlDateTime gmt;
   TimeToStruct(gmtNow, gmt);

   CheckDailyReset(gmt);
   CheckWeeklyReset(gmt);

   if(g_dailyHalt || g_totalHalt) return;
   if(g_dailyLossCount >= CONSEC_LOSSES_STOP)
   {
      Log("[HALT] Daily loss count = " + IntegerToString(g_dailyLossCount) + " — halted.");
      return;
   }

   // ── ASIAN RANGE ACCUMULATION (00-07 GMT) ──────────────────────
   if(gmt.hour >= InpAsianStartGMT && gmt.hour < InpAsianEndGMT)
   {
      UpdateAsianRange();
      if(g_state == STATE_IDLE) g_state = STATE_AWAITING_SWEEP;
   }

   // ── LOCK ASIAN RANGE AT 07:00 GMT ─────────────────────────────
   if(gmt.hour >= InpAsianEndGMT && !g_asianLocked && g_asianHigh > 0.0 && g_asianLow > 0.0)
   {
      g_asianLocked = true;
      double rangePips = (g_asianHigh - g_asianLow) / g_pipSize;
      Log("[RANGE] ASIAN LOCKED | High=" + DoubleToString(g_asianHigh, _Digits) +
          " Low=" + DoubleToString(g_asianLow, _Digits) +
          " Range=" + DoubleToString(rangePips, 1) + "p");
   }

   // [FIX-18] ACCUMULATE LONDON RANGE (07-12 GMT)
   if(gmt.hour >= LONDON_START_GMT && gmt.hour < LONDON_RANGE_END)
   {
      double hi = iHigh(Symbol(), Period(), 1);
      double lo = iLow(Symbol(),  Period(), 1);
      if(!g_londonRangeSet || hi > g_londonHigh) g_londonHigh = hi;
      if(!g_londonRangeSet || lo < g_londonLow)  g_londonLow  = lo;
      g_londonRangeSet = true;
   }

   // [FIX-19] ACCUMULATE NY MORNING RANGE (13-15 GMT) for Silver Bullet reference
   if(gmt.hour >= NY_START_GMT && gmt.hour < NY_MORNING_END)
   {
      double hi = iHigh(Symbol(), Period(), 1);
      double lo = iLow(Symbol(),  Period(), 1);
      if(!g_nyMorningRangeSet || hi > g_nyMorningHigh) g_nyMorningHigh = hi;
      if(!g_nyMorningRangeSet || lo < g_nyMorningLow)  g_nyMorningLow  = lo;
      g_nyMorningRangeSet = true;
   }

   // ── GATE 1: SESSION FILTER ────────────────────────────────────
   if(!Gate1_SessionFilter(gmt)) return;

   // ── GATE 2: ASIAN RANGE VALIDITY ─────────────────────────────
   if(!Gate2_AsianRange()) return;

   // ── ATR REGIME FILTER ─────────────────────────────────────────
   if(!CheckATRRegime()) return;

   // ── NEWS FILTER ───────────────────────────────────────────────
   if(IsNewsTime(gmtNow))
   {
      Log("[NEWS] High-impact news window — skip bar.");
      return;
   }

   bool inLondon  = (gmt.hour >= LONDON_START_GMT   && gmt.hour < LONDON_END_GMT);
   bool inSilver  = (gmt.hour >= SILVER_BULLET_START && gmt.hour < SILVER_BULLET_END);
   bool inNY      = (gmt.hour >= NY_START_GMT        && gmt.hour < NY_END_GMT);

   // ──────────────────────────────────────────────────────────────
   // LONDON SESSION (07-10 GMT): sweeps off Asian range
   // ──────────────────────────────────────────────────────────────
   if(inLondon && !g_londonConsumed)
   {
      if(g_state == STATE_AWAITING_SWEEP || g_state == STATE_IDLE)
      {
         if(g_asianLocked && Gate3_LondonSweep())
            g_state = STATE_AWAITING_FVG;
      }

      if(g_state == STATE_AWAITING_FVG)
      {
         if(Gate5_FVGDetect(g_sweepBullish, g_sweepExtreme))
         {
            g_statFVG++;
            double m = Gate7_HTFBias(g_sweepBullish);
            Gate6_PlaceLimitOrder(g_sweepBullish, g_sweepExtreme, m, false);
            if(g_pendingTicket != 0) { g_state = STATE_PENDING_ENTRY; g_londonConsumed = true; }
         }
         // [FIX-17] Do NOT set g_londonConsumed on failed FVG scan —
         // allow retry on next bar until London window closes.
      }
   }

   // End of London window — consume if no order placed
   if(!g_londonConsumed && gmt.hour == LONDON_END_GMT && gmt.min == 0)
   {
      if(g_state == STATE_AWAITING_FVG || g_state == STATE_AWAITING_SWEEP)
         g_state = STATE_IDLE;
   }

   // ──────────────────────────────────────────────────────────────
   // [FIX-19] SILVER BULLET (10-11 GMT): independent model
   // Sweeps the NY morning range (or Asian range if NY range not ready)
   // ──────────────────────────────────────────────────────────────
   if(inSilver && !g_sbConsumed)
   {
      // Silver Bullet sweeps the Asian high/low (opening range at this time)
      if(!g_sbSweepDetected)
         Gate3_SilverBulletSweep();

      if(g_sbSweepDetected)
      {
         if(Gate5_FVGDetect(g_sbSweepBullish, g_sbSweepExtreme))
         {
            double m = Gate7_HTFBias(g_sbSweepBullish);
            Gate6_PlaceLimitOrder(g_sbSweepBullish, g_sbSweepExtreme, m, true);
            g_sbConsumed = true;
            if(g_pendingTicket != 0) g_state = STATE_PENDING_ENTRY;
         }
      }
   }

   // ──────────────────────────────────────────────────────────────
   // [FIX-18] NY SESSION (13-16 GMT): sweeps the London range
   // ──────────────────────────────────────────────────────────────
   if(inNY && !g_nyConsumed)
   {
      // Need London range to be set before NY can sweep it
      if(g_londonRangeSet)
      {
         if(g_state == STATE_IDLE || g_state == STATE_AWAITING_SWEEP)
         {
            if(Gate3_NYSweep())
               g_state = STATE_AWAITING_FVG;
         }

         if(g_state == STATE_AWAITING_FVG)
         {
            if(Gate5_FVGDetect(g_sweepBullish, g_sweepExtreme))
            {
               g_statFVG++;
               double m = Gate7_HTFBias(g_sweepBullish);
               Gate6_PlaceLimitOrder(g_sweepBullish, g_sweepExtreme, m, false);
               if(g_pendingTicket != 0) { g_state = STATE_PENDING_ENTRY; g_nyConsumed = true; }
            }
         }
      }
   }

   // Manage pending order expiry
   if(g_state == STATE_PENDING_ENTRY)
      ManagePendingOrders();
}

//+------------------------------------------------------------------+
//| PROPFIRM KILL SWITCHES — every tick, floating equity             |
//+------------------------------------------------------------------+
bool CheckPropFirmLimits()
{
   if(g_totalHalt) return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(g_initialBalance > 0.0)
   {
      double totalDDPct = (g_initialBalance - equity) / g_initialBalance * 100.0;
      if(totalDDPct >= InpMaxTotalDDPct)
      {
         g_totalHalt = true;
         CloseAllOrders();
         CloseAllPositions();
         Print("[MARK1] !!! TOTAL DD LIMIT BREACHED: ", DoubleToString(totalDDPct, 2),
               "% >= ", DoubleToString(InpMaxTotalDDPct, 1), "% — PERMANENT HALT !!!");
         return false;
      }
   }

   if(!g_dailyHalt && g_dayStartEquity > 0.0)
   {
      double dailyDDPct = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;
      if(dailyDDPct >= InpMaxDailyLossPct)
      {
         g_dailyHalt = true;
         CloseAllOrders();
         CloseAllPositions();
         Print("[MARK1] !!! DAILY LOSS LIMIT BREACHED: ", DoubleToString(dailyDDPct, 2),
               "% >= ", DoubleToString(InpMaxDailyLossPct, 1), "% — DAILY HALT !!!");
         return false;
      }
   }

   if(g_dailyHalt) return false;
   return true;
}

//+------------------------------------------------------------------+
//| GATE 1 — SESSION FILTER                                           |
//| ICT: Only trade London (07-10), Silver Bullet (10-11), NY (13-16)|
//| Reject Friday after 20:00 GMT — no overnight/weekend exposure.   |
//+------------------------------------------------------------------+
bool Gate1_SessionFilter(const MqlDateTime &gmt)
{
   if(gmt.day_of_week == 5 && gmt.hour >= FRIDAY_CUTOFF_GMT)
   {
      Log("[G1] FAIL — Friday cutoff.");
      return false;
   }

   bool inLondon  = (gmt.hour >= LONDON_START_GMT   && gmt.hour < LONDON_END_GMT);
   bool inSilver  = (gmt.hour >= SILVER_BULLET_START && gmt.hour < SILVER_BULLET_END);
   bool inNY      = (gmt.hour >= NY_START_GMT        && gmt.hour < NY_END_GMT);

   return (inLondon || inSilver || inNY);
}

//+------------------------------------------------------------------+
//| GATE 2 — ASIAN RANGE VALIDITY                                     |
//| ICT: Range < 8p = no meaningful liquidity pools to sweep.        |
//| Range > 50p = sweep likely already occurred / day too volatile.  |
//+------------------------------------------------------------------+
bool Gate2_AsianRange()
{
   if(!g_asianLocked || g_asianHigh <= 0.0 || g_asianLow <= 0.0) return false;

   double rangePips = (g_asianHigh - g_asianLow) / g_pipSize;

   if(rangePips < InpMinAsianRangePips)
   {
      g_statAsianFilter++;
      Log("[G2] FAIL — Range " + DoubleToString(rangePips, 1) + "p < min " +
          DoubleToString(InpMinAsianRangePips, 0) + "p. Skip day.");
      return false;
   }
   if(rangePips > InpMaxAsianRangePips)
   {
      g_statAsianFilter++;
      Log("[G2] FAIL — Range " + DoubleToString(rangePips, 1) + "p > max " +
          DoubleToString(InpMaxAsianRangePips, 0) + "p. Skip day.");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| GATE 3a — LONDON JUDAS SWEEP (07-10 GMT, sweeps Asian range)     |
//| ICT: Wick extends ≥ InpSweepConfirmPips beyond Asian high/low    |
//| AND the M15 candle closes BACK inside the Asian range.           |
//| Both conditions on the SAME candle confirm stop-hunt, not breakout|
//+------------------------------------------------------------------+
bool Gate3_LondonSweep()
{
   if(!g_asianLocked) return false;

   double barHigh  = iHigh(Symbol(), Period(), 1);
   double barLow   = iLow(Symbol(),  Period(), 1);
   double barClose = iClose(Symbol(), Period(), 1);
   double minWick  = (double)InpSweepConfirmPips * g_pipSize;

   bool bearish = (barHigh  > g_asianHigh + minWick) &&
                  (barClose < g_asianHigh) &&
                  (barClose > g_asianLow)  &&
                  !g_tradedSellToday;

   bool bullish = (barLow   < g_asianLow - minWick) &&
                  (barClose > g_asianLow)  &&
                  (barClose < g_asianHigh) &&
                  !g_tradedBuyToday;

   if(bearish)
   {
      g_sweepBullish = false;
      g_sweepExtreme = barHigh;
      g_sweepTime    = iTime(Symbol(), Period(), 1);
      g_statSweeps++;
      Log("[G3L] BEARISH Sweep | AH=" + DoubleToString(g_asianHigh, _Digits) +
          " WickH=" + DoubleToString(barHigh, _Digits) +
          " Wick=" + DoubleToString((barHigh - g_asianHigh) / g_pipSize, 1) + "p");
      return true;
   }
   if(bullish)
   {
      g_sweepBullish = true;
      g_sweepExtreme = barLow;
      g_sweepTime    = iTime(Symbol(), Period(), 1);
      g_statSweeps++;
      Log("[G3L] BULLISH Sweep | AL=" + DoubleToString(g_asianLow, _Digits) +
          " WickL=" + DoubleToString(barLow, _Digits) +
          " Wick=" + DoubleToString((g_asianLow - barLow) / g_pipSize, 1) + "p");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| GATE 3b — [FIX-18] NY SWEEP (13-16 GMT, sweeps London range)     |
//| ICT: By NY open the Asian range is 13h old and irrelevant.       |
//| NY Judas swing instead sweeps the London session high/low         |
//| (07-12 GMT range), which is the relevant recent liquidity pool.  |
//+------------------------------------------------------------------+
bool Gate3_NYSweep()
{
   if(!g_londonRangeSet || g_londonHigh <= 0.0 || g_londonLow <= 0.0) return false;

   double barHigh  = iHigh(Symbol(), Period(), 1);
   double barLow   = iLow(Symbol(),  Period(), 1);
   double barClose = iClose(Symbol(), Period(), 1);
   double minWick  = (double)InpSweepConfirmPips * g_pipSize;

   bool bearish = (barHigh  > g_londonHigh + minWick) &&
                  (barClose < g_londonHigh) &&
                  (barClose > g_londonLow)  &&
                  !g_tradedSellToday;

   bool bullish = (barLow   < g_londonLow - minWick) &&
                  (barClose > g_londonLow)  &&
                  (barClose < g_londonHigh) &&
                  !g_tradedBuyToday;

   if(bearish)
   {
      g_sweepBullish = false;
      g_sweepExtreme = barHigh;
      g_sweepTime    = iTime(Symbol(), Period(), 1);
      g_statSweeps++;
      Log("[G3N] BEARISH NY Sweep | LondonHigh=" + DoubleToString(g_londonHigh, _Digits) +
          " WickH=" + DoubleToString(barHigh, _Digits) +
          " Wick=" + DoubleToString((barHigh - g_londonHigh) / g_pipSize, 1) + "p");
      return true;
   }
   if(bullish)
   {
      g_sweepBullish = true;
      g_sweepExtreme = barLow;
      g_sweepTime    = iTime(Symbol(), Period(), 1);
      g_statSweeps++;
      Log("[G3N] BULLISH NY Sweep | LondonLow=" + DoubleToString(g_londonLow, _Digits) +
          " WickL=" + DoubleToString(barLow, _Digits) +
          " Wick=" + DoubleToString((g_londonLow - barLow) / g_pipSize, 1) + "p");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| GATE 3c — [FIX-19] SILVER BULLET SWEEP (10-11 GMT)               |
//| ICT: Silver Bullet is a standalone ICT model with its own         |
//| reference range. Uses Asian range as reference at 10:00 GMT.     |
//| Sweep + close-back-inside on same M15 candle required.           |
//| Stored in independent g_sbSweep* globals.                        |
//+------------------------------------------------------------------+
void Gate3_SilverBulletSweep()
{
   if(!g_asianLocked) return;

   double barHigh  = iHigh(Symbol(), Period(), 1);
   double barLow   = iLow(Symbol(),  Period(), 1);
   double barClose = iClose(Symbol(), Period(), 1);
   double minWick  = (double)InpSweepConfirmPips * g_pipSize;

   // Use Asian range as Silver Bullet reference
   double refHigh = g_asianHigh;
   double refLow  = g_asianLow;

   bool bearish = (barHigh  > refHigh + minWick) &&
                  (barClose < refHigh) &&
                  (barClose > refLow)  &&
                  !g_tradedSellToday;

   bool bullish = (barLow   < refLow - minWick) &&
                  (barClose > refLow)  &&
                  (barClose < refHigh) &&
                  !g_tradedBuyToday;

   if(bearish)
   {
      g_sbSweepDetected = true;
      g_sbSweepBullish  = false;
      g_sbSweepExtreme  = barHigh;
      g_statSweeps++;
      Log("[G3S] BEARISH SilverBullet Sweep | Ref=" + DoubleToString(refHigh, _Digits));
   }
   else if(bullish)
   {
      g_sbSweepDetected = true;
      g_sbSweepBullish  = true;
      g_sbSweepExtreme  = barLow;
      g_statSweeps++;
      Log("[G3S] BULLISH SilverBullet Sweep | Ref=" + DoubleToString(refLow, _Digits));
   }
}

//+------------------------------------------------------------------+
//| GATE 4 — DISPLACEMENT CANDLE                                      |
//| ICT: Impulse candle after sweep must have strong directional body |
//| Body ≥ 60% of candle range AND ≥ 6 pips. Direction must OPPOSE  |
//| the sweep (bullish sweep → bullish displacement candle).          |
//+------------------------------------------------------------------+
bool Gate4_Displacement(int barIndex, bool isBullishSweep)
{
   if(InpMinDisplacementBodyPct == 0 && InpMinDisplacementPips == 0) return true;

   double open  = iOpen(Symbol(),  Period(), barIndex);
   double close = iClose(Symbol(), Period(), barIndex);
   double high  = iHigh(Symbol(),  Period(), barIndex);
   double low   = iLow(Symbol(),   Period(), barIndex);
   double range = high - low;

   if(range <= 0.0) return false;

   if( isBullishSweep && close <= open) return false;
   if(!isBullishSweep && close >= open) return false;

   double body    = MathAbs(close - open);
   double bodyPct = (body / range) * 100.0;

   if(bodyPct < (double)InpMinDisplacementBodyPct)
   {
      g_statDisplacement++;
      Log("[G4] FAIL body=" + DoubleToString(bodyPct, 1) + "% < " +
          IntegerToString(InpMinDisplacementBodyPct) + "%");
      return false;
   }
   if(body < (double)InpMinDisplacementPips * g_pipSize)
   {
      g_statDisplacement++;
      Log("[G4] FAIL body=" + DoubleToString(body / g_pipSize, 1) + "p < " +
          IntegerToString(InpMinDisplacementPips) + "p");
      return false;
   }

   Log("[G4] PASS body=" + DoubleToString(bodyPct, 1) + "% / " +
       DoubleToString(body / g_pipSize, 1) + "p");
   return true;
}

//+------------------------------------------------------------------+
//| GATE 5 — FVG DETECTION                                            |
//| ICT: Fair Value Gap (price imbalance) is the OTE entry zone.     |
//| Scans last InpFVGScanBars bars for a 3-candle FVG pattern.       |
//|   Bullish FVG: bar[i+2].high < bar[i].low  (gap upward)          |
//|   Bearish FVG: bar[i+2].low  > bar[i].high (gap downward)        |
//| Gate4 displacement applied to middle candle [i+1].               |
//| Returns FIRST (most recent) valid FVG that passes all checks.    |
//+------------------------------------------------------------------+
bool Gate5_FVGDetect(bool isBullishSweep, double sweepExtreme)
{
   if(Bars(Symbol(), Period()) < InpFVGScanBars + 3) return false;

   for(int offset = 1; offset <= InpFVGScanBars - 2; offset++)
   {
      double high_new = iHigh(Symbol(), Period(), offset);
      double low_new  = iLow(Symbol(),  Period(), offset);
      double high_old = iHigh(Symbol(), Period(), offset + 2);
      double low_old  = iLow(Symbol(),  Period(), offset + 2);

      if(isBullishSweep)
      {
         if(high_old >= low_new) continue;

         double fvgPips = (low_new - high_old) / g_pipSize;
         if(fvgPips < InpMinFVGPips) continue;
         if(!Gate4_Displacement(offset + 1, isBullishSweep)) continue;

         g_fvgLow  = high_old;
         g_fvgHigh = low_new;
         Log("[G5] BULLISH FVG [off=" + IntegerToString(offset) + "] " +
             DoubleToString(g_fvgLow, _Digits) + "–" + DoubleToString(g_fvgHigh, _Digits) +
             " (" + DoubleToString(fvgPips, 1) + "p)");
         return true;
      }
      else
      {
         if(low_old <= high_new) continue;

         double fvgPips = (low_old - high_new) / g_pipSize;
         if(fvgPips < InpMinFVGPips) continue;
         if(!Gate4_Displacement(offset + 1, isBullishSweep)) continue;

         g_fvgLow  = high_new;
         g_fvgHigh = low_old;
         Log("[G5] BEARISH FVG [off=" + IntegerToString(offset) + "] " +
             DoubleToString(g_fvgLow, _Digits) + "–" + DoubleToString(g_fvgHigh, _Digits) +
             " (" + DoubleToString(fvgPips, 1) + "p)");
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| GATE 6 — OTE LIMIT ORDER PLACEMENT                                |
//| ICT: Entry at 50% of FVG (OTE). Limit order ensures price must   |
//| retrace to OTE level — no chasing entries.                       |
//|                                                                    |
//| [FIX-17] Filter rejections (H4, Bias, PD, OB) do NOT consume     |
//| the setup — they return silently so next session can retry.      |
//| Only geometry failures (entry vs bid/ask) and successful orders  |
//| mark the session as consumed.                                     |
//|                                                                    |
//| [FIX-20] SL = structure-based: Asian low/high ± 20% of range.   |
//| Clamped to [12, 45] pips for consistency.                        |
//|                                                                    |
//| isSlverBullet=true: uses InpSilverBulletSLPips as fixed SL.      |
//+------------------------------------------------------------------+
void Gate6_PlaceLimitOrder(bool isBullishSweep, double sweepExtreme,
                           double lotsMultiplier, bool isSilverBullet)
{
   if(g_fvgHigh <= g_fvgLow) return;

   // [FIX-17] Optional filters — return without consuming if rejected
   if(InpEnableWeeklyBias)
   {
      if( isBullishSweep && !g_weeklyBullish) { Log("[G6] WeeklyBias rejects BUY — retry next session."); return; }
      if(!isBullishSweep &&  g_weeklyBullish) { Log("[G6] WeeklyBias rejects SELL — retry next session."); return; }
   }

   if(InpEnablePDFilter && g_d1Equilibrium > 0.0)
   {
      double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      if( isBullishSweep && ask >= g_d1Equilibrium) { Log("[G6] PD filter rejects BUY."); return; }
      if(!isBullishSweep && bid <= g_d1Equilibrium) { Log("[G6] PD filter rejects SELL."); return; }
   }

   if(InpEnableTrendFilter && !IsTrendAligned(isBullishSweep))
   { Log("[G6] Trend filter rejects — retry."); return; }

   if(InpEnableOBFilter)
   {
      DetectOrderBlock();
      if(g_obState == OB_NONE)       { Log("[G6] OB filter — no OB, retry."); return; }
      double ageH = (g_obTime > 0) ? (double)(TimeCurrent() - g_obTime) / 3600.0 : 0.0;
      if(ageH > (double)InpOBMaxAgeHours) { g_obState = OB_NONE; Log("[G6] OB stale, retry."); return; }
      double curMid = (SymbolInfoDouble(Symbol(), SYMBOL_ASK) + SymbolInfoDouble(Symbol(), SYMBOL_BID)) * 0.5;
      double dist   = MathMin(MathAbs(curMid - g_obHigh), MathAbs(curMid - g_obLow));
      if(dist > InpOBProximityPips * g_pipSize) { Log("[G6] Too far from OB, retry."); return; }
   }

   // Also check H4 — if disagreement, reduce lots (handled by lotsMultiplier from Gate7)
   // Gate7 already logged its result.

   // OTE entry price
   double fvgRange   = g_fvgHigh - g_fvgLow;
   double otePct     = (double)InpOTEPercent / 100.0;
   double entryPrice, slPrice;
   ENUM_ORDER_TYPE orderType;

   // [FIX-20] Structure-based SL: asianLow - 20% of Asian range (for longs)
   //                               asianHigh + 20% of Asian range (for shorts)
   double slPips;
   if(isSilverBullet)
   {
      slPips = InpSilverBulletSLPips;
   }
   else
   {
      double asianRange     = g_asianHigh - g_asianLow;
      double asianRangePips = asianRange / g_pipSize;
      slPips = asianRangePips * SL_STRUCTURE_BUFFER;
      if(slPips < (double)MIN_SL_PIPS) slPips = (double)MIN_SL_PIPS;
      if(slPips > (double)MAX_SL_PIPS) slPips = (double)MAX_SL_PIPS;
   }
   double slDistance = slPips * g_pipSize;

   if(isBullishSweep)
   {
      entryPrice = NormalizeDouble(g_fvgLow + fvgRange * otePct, _Digits);
      slPrice    = NormalizeDouble(g_asianLow - slDistance, _Digits);
      orderType  = ORDER_TYPE_BUY_LIMIT;
      double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      if(entryPrice >= ask)
      {
         Log("[G6] SKIP BUY — entry " + DoubleToString(entryPrice, _Digits) +
             " >= Ask " + DoubleToString(ask, _Digits));
         return; // [FIX-17] geometry failure — don't retry, but don't block session either
      }
   }
   else
   {
      entryPrice = NormalizeDouble(g_fvgHigh - fvgRange * otePct, _Digits);
      slPrice    = NormalizeDouble(g_asianHigh + slDistance, _Digits);
      orderType  = ORDER_TYPE_SELL_LIMIT;
      double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      if(entryPrice <= bid)
      {
         Log("[G6] SKIP SELL — entry " + DoubleToString(entryPrice, _Digits) +
             " <= Bid " + DoubleToString(bid, _Digits));
         return;
      }
   }

   // Risk calculation
   double riskPct = InpRiskPercent;
   if(g_consecutiveLosses >= CONSEC_LOSSES_HALF) riskPct = InpRiskPercent * 0.5;
   if(IsWeeklyCapHit())     riskPct = MathMin(riskPct, InpRiskPercent * 0.5);
   if(IsExtremeATRRegime()) riskPct = MathMin(riskPct, 0.25);
   riskPct *= lotsMultiplier;

   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount  = equity * (riskPct / 100.0);
   double slPriceDist = MathAbs(entryPrice - slPrice);
   double totalLots   = CalculateLotSize(slPriceDist, riskAmount);

   if(totalLots <= 0.0)
   {
      Log("[G6] ERROR: Lots = 0. Skip.");
      return;
   }

   double risk = MathAbs(entryPrice - slPrice);
   double tp2  = isBullishSweep
               ? NormalizeDouble(entryPrice + InpTP2RR * risk, _Digits)
               : NormalizeDouble(entryPrice - InpTP2RR * risk, _Digits);

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   { Log("[G6] Trade not allowed by terminal."); return; }

   bool result = (orderType == ORDER_TYPE_BUY_LIMIT)
      ? g_trade.BuyLimit( totalLots, entryPrice, Symbol(), slPrice, tp2, 0, 0, "MARK1-OTE")
      : g_trade.SellLimit(totalLots, entryPrice, Symbol(), slPrice, tp2, 0, 0, "MARK1-OTE");

   if(result)
   {
      g_pendingTicket = g_trade.ResultOrder();
      g_pendingBars   = 0;
      g_partialClosed = false;
      g_statOrders++;

      Log("[G6] ORDER PLACED | " + EnumToString(orderType) +
          " Entry=" + DoubleToString(entryPrice, _Digits) +
          " SL=" + DoubleToString(slPrice, _Digits) +
          " TP=" + DoubleToString(tp2, _Digits) +
          " Lots=" + DoubleToString(totalLots, 2) +
          " SLpips=" + DoubleToString(slPips, 1) +
          " EffRisk=" + DoubleToString(riskPct, 3) + "%" +
          " Ticket=" + IntegerToString(g_pendingTicket) +
          " SB=" + (isSilverBullet ? "YES" : "NO"));
   }
   else
   {
      Log("[G6] ORDER FAILED | RC=" + IntegerToString(g_trade.ResultRetcode()) +
          " " + g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| GATE 7 — H4 BIAS (soft: lot multiplier only, no skip)            |
//| ICT: H4 BOS confirms institutional directional commitment.       |
//| Disagreement reduces lots to 50%, does NOT skip the trade.       |
//| [FIX-17] Always returns multiplier — never sets g_setupConsumed. |
//+------------------------------------------------------------------+
double Gate7_HTFBias(bool isBullishSweep)
{
   if(!InpEnableH4Filter) return 1.0;

   bool h4Agrees = isBullishSweep ? IsH4BullishBOS() : IsH4BearishBOS();
   if(!h4Agrees)
   {
      g_statH4++;
      Log("[G7] H4 disagrees — lots × 0.5");
      return 0.5;
   }
   Log("[G7] H4 aligned — lots × 1.0");
   return 1.0;
}

//+------------------------------------------------------------------+
//| ATR REGIME FILTER                                                  |
//| Below 30p H4 ATR = consolidation, no sweep opportunities.        |
//| Above 120p = extreme vol, risk reduced to 0.25% by Gate6.        |
//+------------------------------------------------------------------+
bool CheckATRRegime()
{
   if(g_atrH4Handle == INVALID_HANDLE) return true;

   double atrBuf[1];
   if(CopyBuffer(g_atrH4Handle, 0, 1, 1, atrBuf) < 1) return true;

   double atrPips = atrBuf[0] / g_pipSize;

   if(atrPips < InpMinATRH4)
   {
      g_statATRFilter++;
      Log("[REGIME] SKIP — H4 ATR=" + DoubleToString(atrPips, 1) + "p < min " +
          DoubleToString(InpMinATRH4, 0) + "p.");
      return false;
   }
   if(atrPips > InpMaxATRH4)
      Log("[REGIME] Extreme ATR=" + DoubleToString(atrPips, 1) + "p — risk capped 0.25%.");

   return true;
}

bool IsExtremeATRRegime()
{
   if(g_atrH4Handle == INVALID_HANDLE) return false;
   double atrBuf[1];
   if(CopyBuffer(g_atrH4Handle, 0, 1, 1, atrBuf) < 1) return false;
   return ((atrBuf[0] / g_pipSize) > InpMaxATRH4);
}

//+------------------------------------------------------------------+
//| MANAGE PENDING ORDERS — expire after InpOrderExpiryBars bars      |
//+------------------------------------------------------------------+
void ManagePendingOrders()
{
   if(g_pendingTicket == 0) return;

   bool alive = false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderGetTicket(i) == g_pendingTicket) { alive = true; break; }

   if(!alive)
   {
      Log("[PENDING] Ticket " + IntegerToString(g_pendingTicket) + " no longer pending.");
      g_pendingTicket = 0;
      return;
   }

   g_pendingBars++;
   if(g_pendingBars >= InpOrderExpiryBars)
   {
      if(g_trade.OrderDelete(g_pendingTicket))
      {
         Log("[PENDING] EXPIRED after " + IntegerToString(g_pendingBars) + " bars.");
         g_pendingTicket = 0;
         g_state = STATE_IDLE;
      }
      else
         Log("[PENDING] Delete failed. RC=" + IntegerToString(g_trade.ResultRetcode()));
   }
}

//+------------------------------------------------------------------+
//| MANAGE OPEN POSITIONS — every tick                                |
//| 1. Max duration force-close                                       |
//| 2. TP1 partial close (60%) at 1R → move SL to breakeven          |
//| 3. ATR trailing stop on remaining 40% after TP1                  |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!g_pos.SelectByTicket(ticket)) continue;
      if(g_pos.Symbol() != Symbol())    continue;
      if(g_pos.Magic()  != InpMagicNumber) continue;

      double entry = g_pos.PriceOpen();
      double sl    = g_pos.StopLoss();
      double tp    = g_pos.TakeProfit();
      double lots  = g_pos.Volume();
      double bid   = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      double ask   = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

      // 1. Max trade duration
      if(g_tradeEntryTime > 0)
      {
         double hoursOpen = (double)(TimeCurrent() - g_tradeEntryTime) / 3600.0;
         if(hoursOpen >= (double)InpMaxTradeDurationHours)
         {
            g_trade.PositionClose(ticket);
            Log("[MGMT] MAX DURATION (" + DoubleToString(hoursOpen, 1) + "h) — closed #" + IntegerToString(ticket));
            continue;
         }
      }

      if(sl <= 0.0) continue;

      if(g_pos.PositionType() == POSITION_TYPE_BUY)
      {
         double initialRisk = entry - sl;
         if(initialRisk <= 0.0) continue;
         double tp1Price = entry + InpTP1RR * initialRisk;

         // TP1 partial close 60%
         if(!g_partialClosed && bid >= tp1Price)
         {
            double lotStep  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
            double minLot   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
            double closeLot = MathMax(MathFloor(lots * 0.6 / lotStep) * lotStep, minLot);

            if(closeLot < lots && g_trade.PositionClosePartial(ticket, closeLot))
            {
               g_partialClosed = true;
               double newSL = NormalizeDouble(entry + _Point, _Digits);
               g_trade.PositionModify(ticket, newSL, tp);
               Log("[MGMT] TP1(60%) BUY #" + IntegerToString(ticket) +
                   " closed " + DoubleToString(closeLot, 2) + "L SL→BE");
            }
            continue;
         }

         // ATR trailing after TP1
         if(g_partialClosed && sl >= entry)
         {
            double trail   = GetATRM15Trail();
            double trailSL = NormalizeDouble(bid - trail, _Digits);
            if(trail > 0.0 && trailSL > sl) g_trade.PositionModify(ticket, trailSL, tp);
         }
      }
      else if(g_pos.PositionType() == POSITION_TYPE_SELL)
      {
         double initialRisk = sl - entry;
         if(initialRisk <= 0.0) continue;
         double tp1Price = entry - InpTP1RR * initialRisk;

         // TP1 partial close 60%
         if(!g_partialClosed && ask <= tp1Price)
         {
            double lotStep  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
            double minLot   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
            double closeLot = MathMax(MathFloor(lots * 0.6 / lotStep) * lotStep, minLot);

            if(closeLot < lots && g_trade.PositionClosePartial(ticket, closeLot))
            {
               g_partialClosed = true;
               double newSL = NormalizeDouble(entry - _Point, _Digits);
               g_trade.PositionModify(ticket, newSL, tp);
               Log("[MGMT] TP1(60%) SELL #" + IntegerToString(ticket) +
                   " closed " + DoubleToString(closeLot, 2) + "L SL→BE");
            }
            continue;
         }

         // ATR trailing after TP1
         if(g_partialClosed && sl > 0.0 && sl <= entry)
         {
            double trail   = GetATRM15Trail();
            double trailSL = NormalizeDouble(ask + trail, _Digits);
            if(trail > 0.0 && trailSL < sl) g_trade.PositionModify(ticket, trailSL, tp);
         }
      }
   }
}

double GetATRM15Trail()
{
   if(g_atrM15Handle == INVALID_HANDLE) return 0.0;
   double buf[1];
   if(CopyBuffer(g_atrM15Handle, 0, 1, 1, buf) < 1) return 0.0;
   return buf[0] * 0.5;
}

//+------------------------------------------------------------------+
//| ASIAN RANGE ACCUMULATION                                          |
//+------------------------------------------------------------------+
void UpdateAsianRange()
{
   double hi = iHigh(Symbol(), Period(), 1);
   double lo = iLow(Symbol(),  Period(), 1);
   if(g_asianHigh == 0.0 || hi > g_asianHigh) g_asianHigh = hi;
   if(g_asianLow  == 0.0 || lo < g_asianLow)  g_asianLow  = lo;
}

//+------------------------------------------------------------------+
//| DAILY RESET — fires at 00:00 GMT                                  |
//+------------------------------------------------------------------+
void CheckDailyReset(const MqlDateTime &gmt)
{
   MqlDateTime prev;
   TimeToStruct(g_lastDayReset, prev);
   bool newDay = (gmt.year != prev.year || gmt.mon != prev.mon || gmt.day != prev.day);
   if(!newDay) return;

   // [FIX-21] Print gate stats from yesterday before reset
   Log("[STATS] Sweeps=" + IntegerToString(g_statSweeps) +
       " FVG=" + IntegerToString(g_statFVG) +
       " Disp=" + IntegerToString(g_statDisplacement) +
       " H4=" +   IntegerToString(g_statH4) +
       " Asian=" + IntegerToString(g_statAsianFilter) +
       " ATR=" +   IntegerToString(g_statATRFilter) +
       " Orders=" + IntegerToString(g_statOrders));

   // Cancel stale pending order
   if(g_pendingTicket != 0)
   {
      bool alive = false;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
         if(OrderGetTicket(i) == g_pendingTicket) { alive = true; break; }
      if(alive) g_trade.OrderDelete(g_pendingTicket);
   }

   // Reset all daily state
   g_asianHigh          = 0.0;
   g_asianLow           = 0.0;
   g_asianLocked        = false;
   g_londonHigh         = 0.0;
   g_londonLow          = 0.0;
   g_londonRangeSet     = false;
   g_nyMorningHigh      = 0.0;
   g_nyMorningLow       = 0.0;
   g_nyMorningRangeSet  = false;
   g_sweepBullish       = false;
   g_sweepExtreme       = 0.0;
   g_sweepTime          = 0;
   g_sbSweepDetected    = false;
   g_sbSweepBullish     = false;
   g_sbSweepExtreme     = 0.0;
   g_fvgHigh            = 0.0;
   g_fvgLow             = 0.0;
   g_londonConsumed     = false;
   g_nyConsumed         = false;
   g_sbConsumed         = false;
   g_setupConsumed      = false;
   g_tradedBuyToday     = false;
   g_tradedSellToday    = false;
   g_pendingTicket      = 0;
   g_pendingBars        = 0;
   g_tradeEntryTime     = 0;
   g_partialClosed      = false;
   g_obState            = OB_NONE;
   g_obHigh             = 0.0;
   g_obLow              = 0.0;
   g_obTime             = 0;
   g_state              = STATE_IDLE;
   g_dailyHalt          = false;
   g_dailyLossCount     = 0;
   // Reset stat counters
   g_statSweeps         = 0;
   g_statFVG            = 0;
   g_statDisplacement   = 0;
   g_statH4             = 0;
   g_statAsianFilter    = 0;
   g_statATRFilter      = 0;
   g_statOrders         = 0;

   g_dayStartEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastDayReset       = TimeGMT();

   UpdateD1Equilibrium();
   Log("[RESET] DAY | DayEquity=" + DoubleToString(g_dayStartEquity, 2) +
       " ConsecLoss=" + IntegerToString(g_consecutiveLosses));
}

//+------------------------------------------------------------------+
//| WEEKLY RESET — Monday 00:00 GMT                                   |
//+------------------------------------------------------------------+
void CheckWeeklyReset(const MqlDateTime &gmt)
{
   if(gmt.day_of_week != 1) return;
   MqlDateTime prev;
   TimeToStruct(g_lastWeekReset, prev);
   bool newWeek = (gmt.year != prev.year || gmt.mon != prev.mon || gmt.day != prev.day);
   if(!newWeek) return;

   g_weekStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastWeekReset   = TimeGMT();
   UpdateWeeklyBias();
   Log("[RESET] WEEK | WeekEquity=" + DoubleToString(g_weekStartEquity, 2));
}

bool IsWeeklyCapHit()
{
   if(g_weekStartEquity <= 0.0 || g_initialBalance <= 0.0) return false;
   double wDDPct = (g_weekStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_initialBalance * 100.0;
   return (wDDPct >= InpWeeklyDDSoftCapPct);
}

//+------------------------------------------------------------------+
//| LOT SIZE — handles JPY pairs via tick size/value                  |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPriceDistance, double riskAmount)
{
   if(g_pipSize <= 0.0 || slPriceDistance <= 0.0 || riskAmount <= 0.0) return 0.0;

   double tickValue  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return 0.0;

   double lossPerLot = (slPriceDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return 0.0;

   double lots    = riskAmount / lossPerLot;
   double minLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   Log("[LOT] Risk=$" + DoubleToString(riskAmount, 2) +
       " SL=" + DoubleToString(slPriceDistance / g_pipSize, 1) + "p" +
       " LossPerLot=$" + DoubleToString(lossPerLot, 2) +
       " Lots=" + DoubleToString(lots, 2));
   return lots;
}

//+------------------------------------------------------------------+
//| CLOSE ALL (PropFirm kill switch utilities)                        |
//+------------------------------------------------------------------+
void CloseAllOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      g_trade.OrderDelete(ticket);
   }
   g_pendingTicket = 0;
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!g_pos.SelectByTicket(ticket)) continue;
      if(g_pos.Symbol() != Symbol())    continue;
      if(g_pos.Magic()  != InpMagicNumber) continue;
      g_trade.PositionClose(ticket);
      Log("[HALT] Closed position #" + IntegerToString(ticket));
   }
}

int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!g_pos.SelectByTicket(ticket)) continue;
      if(g_pos.Symbol() != Symbol())    continue;
      if(g_pos.Magic()  != InpMagicNumber) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| OnTradeTransaction                                                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   HistorySelect(TimeCurrent() - 86400 * 2, TimeCurrent() + 60);
   if(!HistoryDealSelect(dealTicket)) return;
   if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNumber) return;

   ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

   if(dealEntry == DEAL_ENTRY_IN)
   {
      g_tradeEntryTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      g_state          = STATE_IN_TRADE;
      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      if(dealType == DEAL_TYPE_BUY)  g_tradedBuyToday  = true;
      if(dealType == DEAL_TYPE_SELL) g_tradedSellToday = true;
      Log("[TXN] ENTRY " + EnumToString(dealType) + " @ " + TimeToString(g_tradeEntryTime));
      return;
   }

   if(dealEntry != DEAL_ENTRY_OUT) return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                 + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                 + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

   if(profit < 0.0)
   {
      g_consecutiveLosses++;
      g_dailyLossCount++;
      Log("[TXN] LOSS P&L=" + DoubleToString(profit, 2) +
          " | Streak=" + IntegerToString(g_consecutiveLosses) +
          " | DayCount=" + IntegerToString(g_dailyLossCount));
   }
   else
   {
      Log("[TXN] WIN P&L=+" + DoubleToString(profit, 2) +
          " | Reset streak from " + IntegerToString(g_consecutiveLosses));
      g_consecutiveLosses = 0;
   }

   if(CountOpenPositions() == 0 && g_pendingTicket == 0)
   {
      g_state          = STATE_IDLE;
      g_tradeEntryTime = 0;
      g_partialClosed  = false;
   }
}

//+------------------------------------------------------------------+
//| H4 BOS DETECTION                                                   |
//+------------------------------------------------------------------+
bool IsH4BullishBOS()
{
   int lb = InpH4LookbackBars;
   if(Bars(Symbol(), PERIOD_H4) < lb + 5) return false;
   double sh1 = 0.0, sh2 = 0.0;
   int    cnt = 0;
   for(int i = 2; i < lb - 1 && cnt < 2; i++)
   {
      double h = iHigh(Symbol(), PERIOD_H4, i);
      if(h > iHigh(Symbol(), PERIOD_H4, i-1) && h > iHigh(Symbol(), PERIOD_H4, i+1))
         { cnt++; if(cnt == 1) sh1 = h; else sh2 = h; }
   }
   return (cnt >= 2 && sh1 > sh2);
}

bool IsH4BearishBOS()
{
   int lb = InpH4LookbackBars;
   if(Bars(Symbol(), PERIOD_H4) < lb + 5) return false;
   double sl1 = 0.0, sl2 = 0.0;
   int    cnt = 0;
   for(int i = 2; i < lb - 1 && cnt < 2; i++)
   {
      double l = iLow(Symbol(), PERIOD_H4, i);
      if(l < iLow(Symbol(), PERIOD_H4, i-1) && l < iLow(Symbol(), PERIOD_H4, i+1))
         { cnt++; if(cnt == 1) sl1 = l; else sl2 = l; }
   }
   return (cnt >= 2 && sl1 < sl2);
}

//+------------------------------------------------------------------+
//| ORDER BLOCK DETECTION                                              |
//+------------------------------------------------------------------+
void DetectOrderBlock()
{
   if(g_obState != OB_NONE && g_obTime > 0)
   {
      double ageH = (double)(TimeCurrent() - g_obTime) / 3600.0;
      if(ageH > (double)InpOBMaxAgeHours) { g_obState = OB_NONE; return; }
      double closeH4 = iClose(Symbol(), PERIOD_H4, 1);
      if(g_obBullish)
      {
         if(closeH4 >= g_obLow && closeH4 <= g_obHigh && g_obState == OB_UNTESTED) g_obState = OB_MITIGATED;
         else if(closeH4 < g_obLow) g_obState = OB_BREAKER;
      }
      else
      {
         if(closeH4 >= g_obLow && closeH4 <= g_obHigh && g_obState == OB_UNTESTED) g_obState = OB_MITIGATED;
         else if(closeH4 > g_obHigh) g_obState = OB_BREAKER;
      }
      return;
   }

   int lookback = (int)MathMin((double)InpH4LookbackBars, (double)(Bars(Symbol(), PERIOD_H4) - 5));
   bool isBullishSweep = g_sbSweepDetected ? g_sbSweepBullish : g_sweepBullish;
   for(int i = 2; i < lookback; i++)
   {
      double o = iOpen(Symbol(), PERIOD_H4, i);
      double c = iClose(Symbol(), PERIOD_H4, i);
      if(isBullishSweep && c < o)
      {
         g_obHigh=iHigh(Symbol(),PERIOD_H4,i); g_obLow=iLow(Symbol(),PERIOD_H4,i);
         g_obBullish=true; g_obState=OB_UNTESTED; g_obTime=iTime(Symbol(),PERIOD_H4,i);
         Log("[OB] Bullish bar[" + IntegerToString(i) + "]"); break;
      }
      if(!isBullishSweep && c > o)
      {
         g_obHigh=iHigh(Symbol(),PERIOD_H4,i); g_obLow=iLow(Symbol(),PERIOD_H4,i);
         g_obBullish=false; g_obState=OB_UNTESTED; g_obTime=iTime(Symbol(),PERIOD_H4,i);
         Log("[OB] Bearish bar[" + IntegerToString(i) + "]"); break;
      }
   }
}

//+------------------------------------------------------------------+
//| NEWS FILTER — MT5 calendar API + hardcoded fallback               |
//+------------------------------------------------------------------+
bool IsNewsTime(datetime gmtTime)
{
   datetime from = gmtTime - (datetime)(InpNewsHaltMinutes * 60);
   datetime to   = gmtTime + (datetime)(InpNewsHaltMinutes * 60);

   string curs[2] = {"USD", "EUR"};
   for(int j = 0; j < 2; j++)
   {
      MqlCalendarValue vals[];
      if(!CalendarValueHistory(vals, from, to, curs[j])) continue;
      for(int i = 0; i < ArraySize(vals); i++)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev)) continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
         datetime evT = vals[i].time;
         if(gmtTime >= evT - (datetime)(InpNewsHaltMinutes * 60) &&
            gmtTime <= evT + (datetime)(InpNewsHaltMinutes * 60))
         {
            Log("[NEWS] " + curs[j] + " high-impact @ " + TimeToString(evT));
            return true;
         }
      }
   }
   return IsHardcodedNewsTime(gmtTime);
}

bool IsHardcodedNewsTime(datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);
   if(dt.day_of_week == 5 && dt.day <= 7 && dt.hour == 13) return true;
   int fomcMonths[] = {1,3,5,6,7,9,11,12};
   if(dt.day_of_week == 3)
      for(int i = 0; i < ArraySize(fomcMonths); i++)
         if(dt.mon == fomcMonths[i] && dt.hour >= 19 && dt.hour <= 20)
            return true;
   return false;
}

//+------------------------------------------------------------------+
//| D1 / WEEKLY / TREND HELPERS                                       |
//+------------------------------------------------------------------+
void UpdateD1Equilibrium()
{
   if(Bars(Symbol(), PERIOD_D1) < 2) return;
   g_d1Equilibrium = (iHigh(Symbol(), PERIOD_D1, 1) + iLow(Symbol(), PERIOD_D1, 1)) * 0.5;
}

void UpdateWeeklyBias()
{
   if(Bars(Symbol(), PERIOD_W1) < 2) return;
   g_weeklyBullish = (iClose(Symbol(), PERIOD_W1, 1) > iOpen(Symbol(), PERIOD_W1, 1));
   Log("[BIAS] W1 = " + (g_weeklyBullish ? "BULLISH" : "BEARISH"));
}

bool IsTrendAligned(bool isBullish)
{
   if(!InpEnableTrendFilter || g_ema200Handle == INVALID_HANDLE) return true;
   double buf[1];
   if(CopyBuffer(g_ema200Handle, 0, 1, 1, buf) < 1) return true;
   double d1Close = iClose(Symbol(), PERIOD_D1, 1);
   return isBullish ? (d1Close > buf[0]) : (d1Close < buf[0]);
}

//+------------------------------------------------------------------+
//| END OF FILE                                                        |
//+------------------------------------------------------------------+
