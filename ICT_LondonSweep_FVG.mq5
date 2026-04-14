//+------------------------------------------------------------------+
//|  ICT_LondonSweep_FVG.mq5                                         |
//|  MARK1 v4.0 — Institutional-Grade ICT Methodology                |
//|  Strategy: Asian Range → Judas Swing → FVG → OTE Limit Entry     |
//|  Target: FTMO Standard Challenge | Platform: EURUSD M15          |
//|                                                                    |
//|  7-Gate entry model:                                              |
//|    G1 Session → G2 Asian Range → G3 Sweep Confirm → G4 Displace  |
//|    → G5 FVG → G6 OTE Limit Order → G7 H4 Bias (lot scale)       |
//|                                                                    |
//|  PropFirm kill switches evaluate on EVERY tick (floating equity). |
//|  ATR H4 regime filter makes EA adaptive across market regimes.    |
//+------------------------------------------------------------------+
#property copyright   "ICT EA – MARK1 v4.0"
#property version     "4.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| ENUMERATIONS                                                       |
//+------------------------------------------------------------------+

// State machine drives the entire bar-by-bar logic flow.
// Prevents duplicate scans and ensures each gate is checked in order.
enum ENUM_EA_STATE
{
   STATE_IDLE,            // Waiting for Asian session / daily reset
   STATE_AWAITING_SWEEP,  // Asian range locked; scanning for Judas sweep
   STATE_AWAITING_FVG,    // Sweep confirmed; scanning for FVG & OTE
   STATE_PENDING_ENTRY,   // Limit order placed; managing expiry
   STATE_IN_TRADE         // Position open; managed in ManageOpenPositions()
};

enum ENUM_OB_STATE
{
   OB_NONE      = 0,
   OB_UNTESTED  = 1,
   OB_MITIGATED = 2,
   OB_BREAKER   = 3
};

//+------------------------------------------------------------------+
//| NAMED CONSTANTS (no magic numbers in logic)                       |
//+------------------------------------------------------------------+
static const int    MIN_SL_PIPS         = 15;    // Dynamic SL floor (pips)
static const int    MAX_SL_PIPS         = 50;    // Dynamic SL ceiling (pips)
static const double SL_RANGE_MULTIPLE   = 1.1;   // SL = AsianRange × this
static const int    LONDON_START_GMT    = 7;     // London Kill Zone open
static const int    LONDON_END_GMT      = 10;    // London Kill Zone close
static const int    SILVER_BULLET_START = 10;    // Silver Bullet window open
static const int    SILVER_BULLET_END   = 11;    // Silver Bullet window close
static const int    NY_START_GMT        = 13;    // NY Kill Zone open
static const int    NY_END_GMT          = 16;    // NY Kill Zone close
static const int    FRIDAY_CUTOFF_GMT   = 20;    // No new trades after this on Fri
static const int    CONSEC_LOSSES_HALF  = 2;     // Streak before halving risk
static const int    CONSEC_LOSSES_STOP  = 4;     // Daily losses before halting day
static const int    ATR_M15_PERIOD      = 14;    // ATR period for trailing stop
static const int    ATR_H4_PERIOD       = 14;    // ATR period for regime detection

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                   |
//+------------------------------------------------------------------+

input group "=== Risk Management ==="
input double InpRiskPercent            = 0.5;    // Base risk per trade (% of equity)
input double InpMaxDailyLossPct        = 4.0;    // Max daily loss % — halt today (FTMO: 5%)
input double InpMaxTotalDDPct          = 8.0;    // Max total DD % — halt EA (FTMO: 10%)
input double InpWeeklyDDSoftCapPct     = 3.5;    // Weekly DD soft cap → 50% lot size

input group "=== Asian Session ==="
input int    InpAsianStartGMT          = 0;      // Asian session start (GMT hour)
input int    InpAsianEndGMT            = 7;      // Asian session end / range lock (GMT hour)
input int    InpMinAsianRangePips      = 8;      // Min Asian range — skip if compressed
input int    InpMaxAsianRangePips      = 40;     // Max Asian range — skip if explosive
input int    InpSweepConfirmPips       = 2;      // Min wick outside Asian level (pips)

input group "=== Entry Settings ==="
input int    InpFVGScanBars            = 5;      // Bars to scan for FVG after sweep
input int    InpMinFVGPips             = 3;      // Minimum FVG size (pips)
input int    InpOTEPercent             = 50;     // OTE entry depth into FVG (%)
input int    InpOrderExpiryBars        = 3;      // Cancel pending order after N bars
input int    InpMinDisplacementBodyPct = 60;     // Min displacement body as % of range
input int    InpMinDisplacementPips    = 6;      // Min displacement body size (pips)

input group "=== Exit Settings ==="
input double InpTP1Ratio               = 1.0;    // TP1 R-multiple (50% partial close)
input double InpTP2Ratio               = 2.0;    // TP2 R-multiple (remaining 50%)
input int    InpMaxTradeDurationHours  = 8;      // Force-close after N hours (no overnight)

input group "=== Regime Filters ==="
input bool   InpEnableH4Filter         = true;   // H4 BOS — reduce lots (not skip) if failing
input double InpMinATRH4               = 30.0;   // H4 ATR(14) min pips — skip day below
input double InpMaxATRH4               = 120.0;  // H4 ATR(14) max pips — reduce risk above
input int    InpNewsHaltMinutes        = 30;     // Halt ±N minutes around high-impact news
input bool   InpEnableTrendFilter      = false;  // Enable D1 EMA200 trend gate

input group "=== Advanced Filters ==="
input bool   InpEnableWeeklyBias       = false;  // Filter by W1 directional bias
input bool   InpEnablePDFilter         = false;  // Enforce D1 discount/premium zone
input bool   InpEnableOBFilter         = false;  // Require Order Block proximity
input double InpOBProximityPips        = 10.0;   // Max distance from OB zone (pips)
input int    InpOBMaxAgeHours          = 24;     // Discard OBs older than N hours
input int    InpH4LookbackBars         = 50;     // H4 bars to scan for BOS

input group "=== Order Settings ==="
input int    InpMagicNumber            = 202601;
input int    InpSlippagePoints         = 20;

input group "=== Debug ==="
input bool   InpEnableDebug            = true;   // Enable verbose debug logging

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                   |
//+------------------------------------------------------------------+

// Trade library objects
CTrade         g_trade;
CPositionInfo  g_pos;
COrderInfo     g_ord;

// State machine
ENUM_EA_STATE  g_state             = STATE_IDLE;

// Asian range data
double         g_asianHigh         = 0.0;
double         g_asianLow          = 0.0;
bool           g_asianLocked       = false;

// Sweep data (set by Gate3)
bool           g_sweepBullish      = false;
double         g_sweepExtreme      = 0.0;    // Actual wick extreme price
datetime       g_sweepTime         = 0;

// FVG data (set by Gate5)
double         g_fvgHigh           = 0.0;
double         g_fvgLow            = 0.0;

// Setup / daily trade guards
bool           g_setupConsumed     = false;  // One attempt per sweep
bool           g_tradedBuyToday    = false;  // Max 1 buy trade per day
bool           g_tradedSellToday   = false;  // Max 1 sell trade per day

// Pending order tracking
ulong          g_pendingTicket     = 0;
int            g_pendingBars       = 0;

// Open position tracking
datetime       g_tradeEntryTime    = 0;      // For max duration check
bool           g_partialClosed     = false;  // TP1 partial close executed flag

// PropFirm & risk state
double         g_initialBalance    = 0.0;   // Set at OnInit — NEVER updated
double         g_dayStartEquity    = 0.0;   // Reset 00:00 GMT each day
double         g_weekStartEquity   = 0.0;   // Reset Monday 00:00 GMT
bool           g_dailyHalt         = false; // Daily loss limit hit
bool           g_totalHalt         = false; // Total DD hit — permanent until restart
int            g_consecutiveLosses = 0;     // Win-to-win streak (reset on WIN only)
int            g_dailyLossCount    = 0;     // Per-day count (reset at midnight)

// Indicator handles
int            g_atrH4Handle       = INVALID_HANDLE;
int            g_atrM15Handle      = INVALID_HANDLE;
int            g_ema200Handle      = INVALID_HANDLE;

// Misc
double         g_pipSize           = 0.0;
datetime       g_lastBarTime       = 0;
datetime       g_lastDayReset      = 0;
datetime       g_lastWeekReset     = 0;

// Optional filter state (behind toggle flags)
ENUM_OB_STATE  g_obState           = OB_NONE;
double         g_obHigh            = 0.0;
double         g_obLow             = 0.0;
bool           g_obBullish         = false;
datetime       g_obTime            = 0;
bool           g_weeklyBullish     = false;
double         g_d1Equilibrium     = 0.0;

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

   // Pip size — handles 3/5-digit and 2/4-digit brokers
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   g_pipSize  = (digits == 3 || digits == 5)
              ? SymbolInfoDouble(Symbol(), SYMBOL_POINT) * 10.0
              : SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   if(g_pipSize <= 0.0) { Print("[MARK1] INIT ERROR: Invalid pip size."); return INIT_FAILED; }

   // Parameter sanity checks
   if(InpFVGScanBars < 3)
   { Print("[MARK1] INIT ERROR: InpFVGScanBars must be >= 3."); return INIT_PARAMETERS_INCORRECT; }
   if(InpTP2Ratio <= InpTP1Ratio)
   { Print("[MARK1] INIT ERROR: InpTP2Ratio must be > InpTP1Ratio."); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxDailyLossPct >= 5.0)
      Print("[MARK1] WARNING: InpMaxDailyLossPct >= FTMO 5% limit. Reduce to stay inside.");
   if(InpMaxTotalDDPct >= 10.0)
      Print("[MARK1] WARNING: InpMaxTotalDDPct >= FTMO 10% limit. Reduce to stay inside.");

   // Indicator handles
   g_atrH4Handle  = iATR(Symbol(), PERIOD_H4,  ATR_H4_PERIOD);
   g_atrM15Handle = iATR(Symbol(), PERIOD_M15, ATR_M15_PERIOD);
   g_ema200Handle = iMA(Symbol(),  PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(g_atrH4Handle  == INVALID_HANDLE) Print("[MARK1] WARNING: H4 ATR handle failed — regime filter passes through.");
   if(g_atrM15Handle == INVALID_HANDLE) Print("[MARK1] WARNING: M15 ATR handle failed — trailing stop disabled.");
   if(g_ema200Handle == INVALID_HANDLE) Print("[MARK1] WARNING: D1 EMA200 handle failed — trend filter passes through.");

   // Trade object setup
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   // PropFirm baseline — initial balance at EA start, never updated
   g_initialBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_weekStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastDayReset    = TimeGMT();
   g_lastWeekReset   = TimeGMT();
   g_lastBarTime     = (datetime)SeriesInfoInteger(Symbol(), Period(), SERIES_LASTBAR_DATE);

   UpdateD1Equilibrium();
   UpdateWeeklyBias();

   Log("INIT v4.0 | Balance=" + DoubleToString(g_initialBalance, 2) +
       " | Pip=" + DoubleToString(g_pipSize, _Digits + 1) +
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
//| OnTick — PropFirm kill switches run EVERY tick                    |
//|          Bar-open strategy logic runs on new M15 bars only        |
//+------------------------------------------------------------------+
void OnTick()
{
   // ── PROPFIRM KILL SWITCHES (floating equity, every tick) ─────
   if(!CheckPropFirmLimits()) return;

   // ── ACTIVE POSITION MANAGEMENT (every tick) ──────────────────
   ManageOpenPositions();

   // ── BAR GATE — strategy logic only runs on new bar ───────────
   datetime barTime = (datetime)SeriesInfoInteger(Symbol(), Period(), SERIES_LASTBAR_DATE);
   if(barTime == 0 || barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   // ── DAILY / WEEKLY RESET ─────────────────────────────────────
   datetime gmtNow = TimeGMT();
   MqlDateTime gmt;
   TimeToStruct(gmtNow, gmt);
   CheckDailyReset(gmt);
   CheckWeeklyReset(gmt);

   // ── POST-RESET HALTS ──────────────────────────────────────────
   if(g_dailyHalt || g_totalHalt) return;

   // ── DAILY LOSS COUNT HALT ─────────────────────────────────────
   if(g_dailyLossCount >= CONSEC_LOSSES_STOP)
   {
      Log("[HALT] Daily loss count = " + IntegerToString(g_dailyLossCount) + " — trading halted today.");
      return;
   }

   // ── ASIAN RANGE ACCUMULATION ──────────────────────────────────
   if(gmt.hour >= InpAsianStartGMT && gmt.hour < InpAsianEndGMT)
   {
      UpdateAsianRange();
      if(g_state == STATE_IDLE) g_state = STATE_AWAITING_SWEEP;
   }

   // ── LOCK ASIAN RANGE AT InpAsianEndGMT (07:00 GMT) ───────────
   if(gmt.hour >= InpAsianEndGMT && !g_asianLocked && g_asianHigh > 0.0 && g_asianLow > 0.0)
   {
      g_asianLocked = true;
      double rangePips = (g_asianHigh - g_asianLow) / g_pipSize;
      Log("[RANGE] LOCKED | High=" + DoubleToString(g_asianHigh, _Digits) +
          " Low="  + DoubleToString(g_asianLow,  _Digits) +
          " Range=" + DoubleToString(rangePips, 1) + " pips");
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

   // ── STATE MACHINE ─────────────────────────────────────────────
   switch(g_state)
   {
      case STATE_AWAITING_SWEEP:
         if(g_asianLocked && !g_setupConsumed)
         {
            bool inJudas  = (gmt.hour >= LONDON_START_GMT  && gmt.hour < LONDON_END_GMT);
            bool inSilver = (gmt.hour >= SILVER_BULLET_START && gmt.hour < SILVER_BULLET_END);
            bool inNY     = (gmt.hour >= NY_START_GMT       && gmt.hour < NY_END_GMT);
            if((inJudas || inSilver || inNY) && Gate3_SweepConfirmed())
               g_state = STATE_AWAITING_FVG;
         }
         break;

      case STATE_AWAITING_FVG:
         if(!g_setupConsumed)
         {
            if(Gate5_FVGDetect())
            {
               double lotsMultiplier = Gate7_HTFBias();
               Gate6_PlaceLimitOrder(lotsMultiplier);
               if(g_pendingTicket != 0)
                  g_state = STATE_PENDING_ENTRY;
            }
            else
            {
               // BUG-2 FIX: consume setup only once all kill zones have closed.
               // While still inside a valid KZ, re-scan on every bar —
               // the FVG may form later in the same session.
               bool inAnyKZ = (gmt.hour >= LONDON_START_GMT && gmt.hour < NY_END_GMT);
               if(!inAnyKZ)
               {
                  Log("[G5] No FVG found and kill zone closed — setup consumed.");
                  g_setupConsumed = true;
               }
            }
         }
         break;

      case STATE_PENDING_ENTRY:
         ManagePendingOrders();
         break;

      case STATE_IN_TRADE:
         // All management is in ManageOpenPositions() on every tick.
         break;

      default:
         break;
   }
}

//+------------------------------------------------------------------+
//| PROPFIRM KILL SWITCHES                                            |
//| Evaluates FLOATING equity (open trades count) every tick.        |
//| Returns false → caller must return immediately, no new orders.   |
//|                                                                    |
//| Daily: (dayStartEquity - currentEquity) / dayStartEquity         |
//| Total: (initialBalance  - currentEquity) / initialBalance        |
//+------------------------------------------------------------------+
bool CheckPropFirmLimits()
{
   if(g_totalHalt) return false;  // Permanent halt until EA restart

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   // Total drawdown from initial balance at EA start
   if(g_initialBalance > 0.0)
   {
      double totalDDPct = (g_initialBalance - equity) / g_initialBalance * 100.0;
      if(totalDDPct >= InpMaxTotalDDPct)
      {
         g_totalHalt = true;
         CloseAllOrders();
         CloseAllPositions();
         Print("[MARK1] !!! TOTAL DD LIMIT BREACHED: ", DoubleToString(totalDDPct, 2),
               "% >= ", DoubleToString(InpMaxTotalDDPct, 1), "% — PERMANENT EA HALT !!!");
         return false;
      }
   }

   // Daily loss from today's opening equity (floating — open trades included)
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
//| ICT concept: Only trade during kill zones where institutional     |
//| order flow is highest: London Open (07-10 GMT), Silver Bullet     |
//| (10-11 GMT), NY Open (13-16 GMT). Reject Friday after 20:00 GMT  |
//| to prevent entering trades that may be held over weekend gaps.    |
//+------------------------------------------------------------------+
bool Gate1_SessionFilter(const MqlDateTime &gmt)
{
   // FTMO rule: no new trades on Friday after 20:00 GMT
   if(gmt.day_of_week == 5 && gmt.hour >= FRIDAY_CUTOFF_GMT)
   {
      Log("[G1] FAIL — Friday " + IntegerToString(FRIDAY_CUTOFF_GMT) + ":00 GMT cutoff.");
      return false;
   }

   bool inLondon  = (gmt.hour >= LONDON_START_GMT   && gmt.hour < LONDON_END_GMT);
   bool inSilver  = (gmt.hour >= SILVER_BULLET_START && gmt.hour < SILVER_BULLET_END);
   bool inNY      = (gmt.hour >= NY_START_GMT        && gmt.hour < NY_END_GMT);

   return (inLondon || inSilver || inNY);
}

//+------------------------------------------------------------------+
//| GATE 2 — ASIAN RANGE VALIDITY                                     |
//| ICT concept: The Asian session defines the liquidity pools —      |
//| buy-side above the high, sell-side below the low. A range < 8p   |
//| means no real pools to sweep. A range > 40p signals the sweep    |
//| likely already happened or volatility is structurally excessive. |
//+------------------------------------------------------------------+
bool Gate2_AsianRange()
{
   if(!g_asianLocked || g_asianHigh <= 0.0 || g_asianLow <= 0.0) return false;

   double rangePips = (g_asianHigh - g_asianLow) / g_pipSize;

   if(rangePips < (double)InpMinAsianRangePips)
   {
      Log("[G2] FAIL — Range " + DoubleToString(rangePips, 1) + "p < min " +
          IntegerToString(InpMinAsianRangePips) + "p. Skipping day.");
      return false;
   }
   if(rangePips > (double)InpMaxAsianRangePips)
   {
      Log("[G2] FAIL — Range " + DoubleToString(rangePips, 1) + "p > max " +
          IntegerToString(InpMaxAsianRangePips) + "p. Skipping day.");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| GATE 3 — LIQUIDITY SWEEP CONFIRMATION (most critical fix)         |
//| ICT concept: The Judas Swing is a deliberate false breakout to    |
//| trigger retail stop clusters above/below the Asian range. BOTH    |
//| conditions must hold on the SAME M15 candle:                      |
//|  (1) Wick extends at least InpSweepConfirmPips beyond level       |
//|  (2) Candle CLOSES back inside the Asian range                    |
//| A breakout candle that does NOT close back inside is a genuine    |
//| breakout, not a stop hunt — no entry signal without this close.   |
//+------------------------------------------------------------------+
bool Gate3_SweepConfirmed()
{
   if(!g_asianLocked) return false;

   double barHigh  = iHigh(Symbol(), Period(), 1);
   double barLow   = iLow(Symbol(),  Period(), 1);
   double barClose = iClose(Symbol(), Period(), 1);
   double minWick  = (double)InpSweepConfirmPips * g_pipSize;

   // Bearish sweep: wick pierces Asian high and closes back inside range
   bool bearish = (barHigh  > g_asianHigh + minWick) &&
                  (barClose < g_asianHigh) &&
                  (barClose > g_asianLow)  &&
                  !g_tradedSellToday;

   // Bullish sweep: wick pierces Asian low and closes back inside range
   bool bullish = (barLow   < g_asianLow - minWick) &&
                  (barClose > g_asianLow)  &&
                  (barClose < g_asianHigh) &&
                  !g_tradedBuyToday;

   if(bearish)
   {
      g_sweepBullish = false;
      g_sweepExtreme = barHigh;
      g_sweepTime    = iTime(Symbol(), Period(), 1);
      Log("[G3] PASS BEARISH SWEEP | AsianHigh=" + DoubleToString(g_asianHigh, _Digits) +
          " WickHigh=" + DoubleToString(barHigh, _Digits) +
          " Wick=" + DoubleToString((barHigh - g_asianHigh) / g_pipSize, 1) + "p" +
          " Close=" + DoubleToString(barClose, _Digits));
      return true;
   }
   if(bullish)
   {
      g_sweepBullish = true;
      g_sweepExtreme = barLow;
      g_sweepTime    = iTime(Symbol(), Period(), 1);
      Log("[G3] PASS BULLISH SWEEP | AsianLow=" + DoubleToString(g_asianLow, _Digits) +
          " WickLow=" + DoubleToString(barLow, _Digits) +
          " Wick=" + DoubleToString((g_asianLow - barLow) / g_pipSize, 1) + "p" +
          " Close=" + DoubleToString(barClose, _Digits));
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| GATE 4 — DISPLACEMENT CANDLE (called from Gate5 scan loop)        |
//| ICT concept: After the sweep, institutional commitment must show  |
//| as a strong purposeful candle in the OPPOSITE direction — the     |
//| smart money reversing from the swept liquidity pool. Small/doji   |
//| candles = indecision, not confirmed institutional entry.          |
//| Both thresholds must pass: ≥60% body ratio AND ≥6 pips body.     |
//+------------------------------------------------------------------+
bool Gate4_Displacement(int barIndex)
{
   if(InpMinDisplacementBodyPct == 0 && InpMinDisplacementPips == 0) return true;

   double open  = iOpen(Symbol(),  Period(), barIndex);
   double close = iClose(Symbol(), Period(), barIndex);
   double high  = iHigh(Symbol(),  Period(), barIndex);
   double low   = iLow(Symbol(),   Period(), barIndex);
   double range = high - low;

   if(range <= 0.0) return false;

   // Direction must OPPOSE the sweep
   if( g_sweepBullish && close <= open) return false;  // Bullish sweep → need bullish displacement
   if(!g_sweepBullish && close >= open) return false;  // Bearish sweep → need bearish displacement

   double body    = MathAbs(close - open);
   double bodyPct = (body / range) * 100.0;

   if(bodyPct < (double)InpMinDisplacementBodyPct)
   {
      Log("[G4] FAIL body=" + DoubleToString(bodyPct, 1) + "% < " +
          IntegerToString(InpMinDisplacementBodyPct) + "% @ bar[" + IntegerToString(barIndex) + "]");
      return false;
   }
   if(body < (double)InpMinDisplacementPips * g_pipSize)
   {
      Log("[G4] FAIL body=" + DoubleToString(body / g_pipSize, 1) + "p < " +
          IntegerToString(InpMinDisplacementPips) + "p @ bar[" + IntegerToString(barIndex) + "]");
      return false;
   }

   Log("[G4] PASS body=" + DoubleToString(bodyPct, 1) + "% / " +
       DoubleToString(body / g_pipSize, 1) + "p @ bar[" + IntegerToString(barIndex) + "]");
   return true;
}

//+------------------------------------------------------------------+
//| GATE 5 — FVG DETECTION                                            |
//| ICT concept: A Fair Value Gap is a price imbalance where buyers   |
//| and sellers did not transact — price moved so fast a void is left.|
//| Price gravitates back to fill this gap, creating OTE entries.    |
//| 3-candle pattern (bar indices: newer=offset, older=offset+2):     |
//|   Bullish FVG: candle[offset+2].high < candle[offset].low        |
//|   Bearish FVG: candle[offset+2].low  > candle[offset].high       |
//| Gate4 displacement check applies to the middle candle [offset+1]. |
//+------------------------------------------------------------------+
bool Gate5_FVGDetect()
{
   if(Bars(Symbol(), Period()) < InpFVGScanBars + 3) return false;

   for(int offset = 1; offset <= InpFVGScanBars - 2; offset++)
   {
      double high_new = iHigh(Symbol(), Period(), offset);
      double low_new  = iLow(Symbol(),  Period(), offset);
      double high_old = iHigh(Symbol(), Period(), offset + 2);
      double low_old  = iLow(Symbol(),  Period(), offset + 2);

      if(g_sweepBullish)
      {
         // Bullish FVG: gap above older candle's high, below newer candle's low
         if(high_old >= low_new) continue;

         double fvgPips = (low_new - high_old) / g_pipSize;
         if(fvgPips < (double)InpMinFVGPips) continue;
         if(!Gate4_Displacement(offset + 1))  continue;

         g_fvgLow  = high_old;
         g_fvgHigh = low_new;
         Log("[G5] PASS BULLISH FVG [off=" + IntegerToString(offset) + "] " +
             DoubleToString(g_fvgLow, _Digits) + "–" + DoubleToString(g_fvgHigh, _Digits) +
             " (" + DoubleToString(fvgPips, 1) + "p)");
         return true;
      }
      else
      {
         // Bearish FVG: gap below older candle's low, above newer candle's high
         if(low_old <= high_new) continue;

         double fvgPips = (low_old - high_new) / g_pipSize;
         if(fvgPips < (double)InpMinFVGPips) continue;
         if(!Gate4_Displacement(offset + 1))  continue;

         g_fvgLow  = high_new;
         g_fvgHigh = low_old;
         Log("[G5] PASS BEARISH FVG [off=" + IntegerToString(offset) + "] " +
             DoubleToString(g_fvgLow, _Digits) + "–" + DoubleToString(g_fvgHigh, _Digits) +
             " (" + DoubleToString(fvgPips, 1) + "p)");
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| GATE 6 — OTE LIMIT ORDER PLACEMENT                                |
//| ICT concept: The Optimal Trade Entry is the 50% midpoint of the  |
//| FVG, where institutional resting orders are concentrated. Using a |
//| LIMIT order means we only enter if price RETRACES to OTE — if it |
//| does not, the setup is simply skipped (no chasing).              |
//|                                                                    |
//| Dynamic SL = AsianRange × 1.1, clamped to [15, 50] pips.        |
//| This adapts automatically to each day's actual market structure   |
//| instead of using a fixed pip value that ignores daily volatility. |
//|                                                                    |
//| All PropFirm and adaptive risk adjustments applied to lot size:  |
//|   2+ consecutive losses → InpRiskPercent × 0.5                   |
//|   Weekly DD soft cap hit → cap at 50% of effective risk          |
//|   Extreme ATR regime (>120p H4) → cap at 0.25%                  |
//|   H4 bias disagrees (Gate7) → lot multiplier = 0.5               |
//+------------------------------------------------------------------+
void Gate6_PlaceLimitOrder(double lotsMultiplier = 1.0)
{
   if(g_fvgHigh <= g_fvgLow) return;

   // --- Optional filters ─────────────────────────────────────────
   if(InpEnableWeeklyBias)
   {
      if( g_sweepBullish && !g_weeklyBullish) { Log("[G6] SKIP — weekly=BEAR, want BUY.");  g_setupConsumed=true; return; }
      if(!g_sweepBullish &&  g_weeklyBullish) { Log("[G6] SKIP — weekly=BULL, want SELL."); g_setupConsumed=true; return; }
   }

   if(InpEnablePDFilter && g_d1Equilibrium > 0.0)
   {
      double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      if( g_sweepBullish && ask >= g_d1Equilibrium) { Log("[G6] SKIP — BUY in D1 premium.");  g_setupConsumed=true; return; }
      if(!g_sweepBullish && bid <= g_d1Equilibrium) { Log("[G6] SKIP — SELL in D1 discount."); g_setupConsumed=true; return; }
   }

   if(InpEnableTrendFilter && !IsTrendAligned(g_sweepBullish))
   { Log("[G6] SKIP — D1 EMA200 trend disagrees."); g_setupConsumed=true; return; }

   if(InpEnableOBFilter)
   {
      DetectOrderBlock();
      if(g_obState == OB_NONE)
         { Log("[G6] SKIP — no valid OB found."); g_setupConsumed=true; return; }
      double ageH = (g_obTime > 0) ? (double)(TimeCurrent() - g_obTime) / 3600.0 : 0.0;
      if(ageH > (double)InpOBMaxAgeHours)
         { Log("[G6] SKIP — OB stale (" + DoubleToString(ageH, 1) + "h)."); g_obState=OB_NONE; g_setupConsumed=true; return; }
      double curMid = (SymbolInfoDouble(Symbol(), SYMBOL_ASK) + SymbolInfoDouble(Symbol(), SYMBOL_BID)) * 0.5;
      double dist   = MathMin(MathAbs(curMid - g_obHigh), MathAbs(curMid - g_obLow));
      if(dist > InpOBProximityPips * g_pipSize)
         { Log("[G6] SKIP — too far from OB."); g_setupConsumed=true; return; }
   }

   // --- OTE entry: InpOTEPercent% into FVG ──────────────────────
   double fvgRange   = g_fvgHigh - g_fvgLow;
   double otePct     = (double)InpOTEPercent / 100.0;
   double entryPrice, slPrice;
   ENUM_ORDER_TYPE orderType;

   // --- Dynamic SL: AsianRange × SL_RANGE_MULTIPLE, clamped ─────
   double asianRange = g_asianHigh - g_asianLow;
   double slRaw      = asianRange * SL_RANGE_MULTIPLE;
   double slMin      = (double)MIN_SL_PIPS * g_pipSize;
   double slMax      = (double)MAX_SL_PIPS * g_pipSize;
   double slDistance = MathMax(slMin, MathMin(slMax, slRaw));

   if(g_sweepBullish)
   {
      entryPrice = NormalizeDouble(g_fvgLow + fvgRange * otePct, _Digits);
      slPrice    = NormalizeDouble(g_asianLow - slDistance, _Digits);
      orderType  = ORDER_TYPE_BUY_LIMIT;
      double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      if(entryPrice >= ask)
      {
         Log("[G6] SKIP BUY — entry " + DoubleToString(entryPrice, _Digits) +
             " >= Ask " + DoubleToString(ask, _Digits) + " (already above FVG).");
         g_setupConsumed = true; return;
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
             " <= Bid " + DoubleToString(bid, _Digits) + " (already below FVG).");
         g_setupConsumed = true; return;
      }
   }

   // --- Risk calculation (all adjustments) ──────────────────────
   double riskPct = InpRiskPercent;
   if(g_consecutiveLosses >= CONSEC_LOSSES_HALF) riskPct = InpRiskPercent * 0.5;
   if(IsWeeklyCapHit())      riskPct = MathMin(riskPct, InpRiskPercent * 0.5);
   if(IsExtremeATRRegime())  riskPct = MathMin(riskPct, 0.25);
   riskPct *= lotsMultiplier; // Gate7 soft adjustment

   double equity       = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount   = equity * (riskPct / 100.0);
   double slPriceDist  = MathAbs(entryPrice - slPrice);
   double totalLots    = CalculateLotSize(slPriceDist, riskAmount);

   if(totalLots <= 0.0)
   {
      Log("[G6] ERROR: Calculated lots = 0. Check SL distance / risk. Skip.");
      g_setupConsumed = true;
      return;
   }

   // --- TP at InpTP2Ratio × R; TP1 (1R) managed via partial close ─
   double risk = MathAbs(entryPrice - slPrice);
   double tp2  = g_sweepBullish
               ? NormalizeDouble(entryPrice + InpTP2Ratio * risk, _Digits)
               : NormalizeDouble(entryPrice - InpTP2Ratio * risk, _Digits);

   if(!IsTradeAllowed()) { Log("[G6] Trade not allowed by terminal settings."); return; }

   bool result = (orderType == ORDER_TYPE_BUY_LIMIT)
      ? g_trade.BuyLimit( totalLots, entryPrice, Symbol(), slPrice, tp2, 0, 0, "MARK1-OTE")
      : g_trade.SellLimit(totalLots, entryPrice, Symbol(), slPrice, tp2, 0, 0, "MARK1-OTE");

   if(result)
   {
      g_pendingTicket = g_trade.ResultOrder();
      g_pendingBars   = 0;
      g_setupConsumed = true;
      g_partialClosed = false;

      Log("[G6] ORDER PLACED | " + EnumToString(orderType) +
          " Entry=" + DoubleToString(entryPrice, _Digits) +
          " SL=" + DoubleToString(slPrice, _Digits) +
          " TP=" + DoubleToString(tp2, _Digits) +
          " Lots=" + DoubleToString(totalLots, 2) +
          " SLpips=" + DoubleToString(slPriceDist / g_pipSize, 1) +
          " EffRisk=" + DoubleToString(riskPct, 3) + "%" +
          " Ticket=" + IntegerToString(g_pendingTicket) +
          " ConsecLoss=" + IntegerToString(g_consecutiveLosses) +
          " WeeklyCap=" + (IsWeeklyCapHit() ? "YES" : "NO"));
   }
   else
   {
      Log("[G6] ORDER FAILED | RC=" + IntegerToString(g_trade.ResultRetcode()) +
          " " + g_trade.ResultRetcodeDescription());
      g_setupConsumed = true;
   }
}

//+------------------------------------------------------------------+
//| GATE 7 — H4 BIAS CONFIRMATION (soft: adjusts lots, does not skip)|
//| ICT concept: Higher timeframe Break of Structure (BOS) defines    |
//| directional bias. Bullish BOS on H4 = sequence of higher swing   |
//| highs; bearish BOS = sequence of lower swing lows. When H4 bias  |
//| agrees with the trade direction, use full lots. When it disagrees |
//| (e.g., trade is long but H4 is bearish), reduce lots by 50% to   |
//| acknowledge reduced probability, but do NOT skip entirely —       |
//| M15 structure can diverge temporarily from H4.                    |
//| Returns: 1.0 = aligned / 0.5 = disagreement.                     |
//+------------------------------------------------------------------+
double Gate7_HTFBias()
{
   if(!InpEnableH4Filter) return 1.0;

   bool h4Agrees = g_sweepBullish ? IsH4BullishBOS() : IsH4BearishBOS();
   if(!h4Agrees)
   {
      Log("[G7] H4 disagrees — lot multiplier = 0.5");
      return 0.5;
   }
   Log("[G7] H4 aligned — lot multiplier = 1.0");
   return 1.0;
}

//+------------------------------------------------------------------+
//| ATR REGIME FILTER                                                  |
//| The EA fails outside its designed regime because fixed-pip logic  |
//| breaks in low/high volatility. H4 ATR(14) measures the current   |
//| regime: below 30p = consolidation (no trends to exploit, no       |
//| meaningful Asian range sweeps); above 120p = extreme volatility   |
//| (risk controlled by capping effective risk% to 0.25%).            |
//+------------------------------------------------------------------+
bool CheckATRRegime()
{
   if(g_atrH4Handle == INVALID_HANDLE) return true;  // Pass-through if no handle

   double atrBuf[1];
   if(CopyBuffer(g_atrH4Handle, 0, 1, 1, atrBuf) < 1) return true;

   double atrPips = atrBuf[0] / g_pipSize;

   if(atrPips < InpMinATRH4)
   {
      Log("[REGIME] SKIP — H4 ATR=" + DoubleToString(atrPips, 1) + "p < min " +
          DoubleToString(InpMinATRH4, 0) + "p. Low-vol regime.");
      return false;
   }
   if(atrPips > InpMaxATRH4)
      Log("[REGIME] H4 ATR=" + DoubleToString(atrPips, 1) + "p > max " +
          DoubleToString(InpMaxATRH4, 0) + "p. Extreme regime — risk capped at 0.25%.");

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
      // Filled or externally cancelled — transition handled in OnTradeTransaction
      Log("[PENDING] Ticket " + IntegerToString(g_pendingTicket) + " no longer pending.");
      g_pendingTicket = 0;
      return;
   }

   g_pendingBars++;
   if(g_pendingBars >= InpOrderExpiryBars)
   {
      if(g_trade.OrderDelete(g_pendingTicket))
      {
         Log("[PENDING] EXPIRED after " + IntegerToString(g_pendingBars) + " bars — deleted.");
         g_pendingTicket = 0;
         g_state = STATE_IDLE;
      }
      else
         Log("[PENDING] Delete failed. RC=" + IntegerToString(g_trade.ResultRetcode()));
   }
}

//+------------------------------------------------------------------+
//| MANAGE OPEN POSITIONS — runs on EVERY tick                        |
//| Handles:                                                           |
//|  1. Max trade duration (force-close after InpMaxTradeDurationHours)|
//|  2. TP1 partial close — close 50% at 1R and move SL to breakeven |
//|  3. ATR trailing stop on remaining 50% after TP1 triggers        |
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

      // ── 1. MAX TRADE DURATION ─────────────────────────────────
      if(g_tradeEntryTime > 0)
      {
         double hoursOpen = (double)(TimeCurrent() - g_tradeEntryTime) / 3600.0;
         if(hoursOpen >= (double)InpMaxTradeDurationHours)
         {
            g_trade.PositionClose(ticket);
            Log("[MGMT] MAX DURATION (" + DoubleToString(hoursOpen, 1) +
                "h) — force closed #" + IntegerToString(ticket));
            continue;
         }
      }

      if(sl <= 0.0) continue;

      if(g_pos.PositionType() == POSITION_TYPE_BUY)
      {
         double initialRisk = entry - sl;
         if(initialRisk <= 0.0) continue;
         double tp1Price = entry + InpTP1Ratio * initialRisk;

         // ── 2a. TP1 PARTIAL CLOSE (50%) ───────────────────────
         if(!g_partialClosed && bid >= tp1Price)
         {
            double halfLots = NormalizeDouble(lots * 0.5,
                              (int)MathRound(-MathLog10(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP))));
            double minLot   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
            double lotStep  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
            halfLots        = MathMax(MathFloor(halfLots / lotStep) * lotStep, minLot);

            if(halfLots < lots && g_trade.PositionClosePartial(ticket, halfLots))
            {
               g_partialClosed = true;
               double newSL = NormalizeDouble(entry + _Point, _Digits);
               g_trade.PositionModify(ticket, newSL, tp);
               Log("[MGMT] TP1 PARTIAL BUY #" + IntegerToString(ticket) +
                   " closed " + DoubleToString(halfLots, 2) + "L SL→BE=" +
                   DoubleToString(newSL, _Digits));
            }
            continue;
         }

         // ── 2b. BREAKEVEN (if no partial close yet) ───────────
         if(!g_partialClosed && sl < entry && bid >= tp1Price)
         {
            double newSL = NormalizeDouble(entry + _Point, _Digits);
            if(newSL > sl) g_trade.PositionModify(ticket, newSL, tp);
         }

         // ── 3. ATR TRAILING STOP (only after TP1 / BE) ────────
         if(g_partialClosed && sl >= entry)
         {
            double trail = GetATRM15Trail();
            if(trail > 0.0)
            {
               double trailSL = NormalizeDouble(bid - trail, _Digits);
               if(trailSL > sl) g_trade.PositionModify(ticket, trailSL, tp);
            }
         }
      }
      else if(g_pos.PositionType() == POSITION_TYPE_SELL)
      {
         double initialRisk = sl - entry;
         if(initialRisk <= 0.0) continue;
         double tp1Price = entry - InpTP1Ratio * initialRisk;

         // ── 2a. TP1 PARTIAL CLOSE (50%) ───────────────────────
         if(!g_partialClosed && ask <= tp1Price)
         {
            double halfLots = NormalizeDouble(lots * 0.5,
                              (int)MathRound(-MathLog10(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP))));
            double minLot   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
            double lotStep  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
            halfLots        = MathMax(MathFloor(halfLots / lotStep) * lotStep, minLot);

            if(halfLots < lots && g_trade.PositionClosePartial(ticket, halfLots))
            {
               g_partialClosed = true;
               double newSL = NormalizeDouble(entry - _Point, _Digits);
               g_trade.PositionModify(ticket, newSL, tp);
               Log("[MGMT] TP1 PARTIAL SELL #" + IntegerToString(ticket) +
                   " closed " + DoubleToString(halfLots, 2) + "L SL→BE=" +
                   DoubleToString(newSL, _Digits));
            }
            continue;
         }

         // ── 2b. BREAKEVEN ─────────────────────────────────────
         if(!g_partialClosed && (sl <= 0.0 || sl > entry) && ask <= tp1Price)
         {
            double newSL = NormalizeDouble(entry - _Point, _Digits);
            if(sl <= 0.0 || newSL < sl) g_trade.PositionModify(ticket, newSL, tp);
         }

         // ── 3. ATR TRAILING STOP ──────────────────────────────
         if(g_partialClosed && sl > 0.0 && sl <= entry)
         {
            double trail = GetATRM15Trail();
            if(trail > 0.0)
            {
               double trailSL = NormalizeDouble(ask + trail, _Digits);
               if(trailSL < sl) g_trade.PositionModify(ticket, trailSL, tp);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| GetATRM15Trail — half of M15 ATR(14) in price units              |
//+------------------------------------------------------------------+
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
//| DAILY RESET — fires at 00:00 GMT using TimeGMT()                 |
//+------------------------------------------------------------------+
void CheckDailyReset(const MqlDateTime &gmt)
{
   MqlDateTime prev;
   TimeToStruct(g_lastDayReset, prev);
   bool newDay = (gmt.year != prev.year || gmt.mon != prev.mon || gmt.day != prev.day);
   if(!newDay) return;

   // Cancel any stale pending order from the previous day
   if(g_pendingTicket != 0)
   {
      bool alive = false;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
         if(OrderGetTicket(i) == g_pendingTicket) { alive = true; break; }
      if(alive) g_trade.OrderDelete(g_pendingTicket);
   }

   g_asianHigh       = 0.0;
   g_asianLow        = 0.0;
   g_asianLocked     = false;
   g_sweepBullish    = false;
   g_sweepExtreme    = 0.0;
   g_sweepTime       = 0;
   g_fvgHigh         = 0.0;
   g_fvgLow          = 0.0;
   g_setupConsumed   = false;
   g_tradedBuyToday  = false;
   g_tradedSellToday = false;
   g_pendingTicket   = 0;
   g_pendingBars     = 0;
   g_tradeEntryTime  = 0;
   g_partialClosed   = false;
   g_obState         = OB_NONE;
   g_obHigh          = 0.0;
   g_obLow           = 0.0;
   g_obTime          = 0;
   g_state           = STATE_IDLE;

   // Reset daily halt and per-day loss count (NOT g_consecutiveLosses — needs a WIN)
   g_dailyHalt       = false;
   g_dailyLossCount  = 0;

   // Save today's starting equity for daily DD calculation
   g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastDayReset    = TimeGMT();

   UpdateD1Equilibrium();

   Log("[RESET] DAY | DayEquity=" + DoubleToString(g_dayStartEquity, 2) +
       " ConsecStreak=" + IntegerToString(g_consecutiveLosses));
}

//+------------------------------------------------------------------+
//| WEEKLY RESET — fires Monday 00:00 GMT                             |
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
//| LOT SIZE CALCULATION                                               |
//| Handles JPY pairs and non-standard tick sizes correctly.          |
//| lots = riskAmount / ((slPriceDistance / tickSize) * tickValue)   |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPriceDistance, double riskAmount)
{
   if(g_pipSize <= 0.0 || slPriceDistance <= 0.0 || riskAmount <= 0.0) return 0.0;

   double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
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
//| CLOSE ALL ORDERS & POSITIONS (PropFirm kill switch utility)       |
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
//| OnTradeTransaction — state transitions, win/loss tracking        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   // HistorySelect() MUST precede HistoryDealSelect() per MQL5 docs
   HistorySelect(TimeCurrent() - 86400 * 2, TimeCurrent() + 60);
   if(!HistoryDealSelect(dealTicket)) return;
   if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNumber) return;

   ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

   // Entry deal: record time and mark direction traded today
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
          " | DailyCount=" + IntegerToString(g_dailyLossCount));
   }
   else
   {
      Log("[TXN] WIN P&L=+" + DoubleToString(profit, 2) +
          " | Reset streak from " + IntegerToString(g_consecutiveLosses));
      g_consecutiveLosses = 0; // Streak only resets on a WIN
   }

   // If all positions closed, return to IDLE
   if(CountOpenPositions() == 0 && g_pendingTicket == 0)
   {
      g_state          = STATE_IDLE;
      g_tradeEntryTime = 0;
      g_partialClosed  = false;
   }
}

//+------------------------------------------------------------------+
//| H4 STRUCTURE — BREAK OF STRUCTURE DETECTION                      |
//| Bullish BOS: two swing highs where most-recent > prior (HH)      |
//| Bearish BOS: two swing lows where most-recent < prior (LL)       |
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
//| ORDER BLOCK DETECTION (optional — InpEnableOBFilter)              |
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
   for(int i = 2; i < lookback; i++)
   {
      double o = iOpen(Symbol(), PERIOD_H4, i);
      double c = iClose(Symbol(), PERIOD_H4, i);
      if(g_sweepBullish && c < o)  // Bearish H4 candle = bullish OB
      {
         g_obHigh = iHigh(Symbol(), PERIOD_H4, i); g_obLow = iLow(Symbol(), PERIOD_H4, i);
         g_obBullish=true; g_obState=OB_UNTESTED; g_obTime=iTime(Symbol(), PERIOD_H4, i);
         Log("[OB] Bullish OB bar[" + IntegerToString(i) + "] " +
             DoubleToString(g_obLow,_Digits) + "-" + DoubleToString(g_obHigh,_Digits));
         break;
      }
      if(!g_sweepBullish && c > o)  // Bullish H4 candle = bearish OB
      {
         g_obHigh = iHigh(Symbol(), PERIOD_H4, i); g_obLow = iLow(Symbol(), PERIOD_H4, i);
         g_obBullish=false; g_obState=OB_UNTESTED; g_obTime=iTime(Symbol(), PERIOD_H4, i);
         Log("[OB] Bearish OB bar[" + IntegerToString(i) + "] " +
             DoubleToString(g_obLow,_Digits) + "-" + DoubleToString(g_obHigh,_Digits));
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| NEWS FILTER — MT5 calendar API with hardcoded fallback            |
//| Backtester: calendar API returns empty arrays — hardcoded         |
//| schedule activates automatically to block NFP/FOMC windows.      |
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
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH)  continue;
         datetime evT = vals[i].time;
         if(gmtTime >= evT - (datetime)(InpNewsHaltMinutes * 60) &&
            gmtTime <= evT + (datetime)(InpNewsHaltMinutes * 60))
         {
            Log("[NEWS] " + curs[j] + " high-impact event @ " + TimeToString(evT));
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
   // NFP: first Friday of month, ~13:30 GMT
   if(dt.day_of_week == 5 && dt.day <= 7 && dt.hour == 13) return true;
   // FOMC: select Wednesdays, ~19:00-20:00 GMT
   int fomcMonths[] = {1,3,5,6,7,9,11,12};
   if(dt.day_of_week == 3)
      for(int i = 0; i < ArraySize(fomcMonths); i++)
         if(dt.mon == fomcMonths[i] && dt.hour >= 19 && dt.hour <= 20)
            return true;
   return false;
}

//+------------------------------------------------------------------+
//| D1 EQUILIBRIUM / WEEKLY BIAS / TREND ALIGNMENT                    |
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
