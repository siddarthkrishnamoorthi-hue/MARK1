//+------------------------------------------------------------------+
//| ICT_Liquidity.mqh                                                 |
//| MARK1 ICT Expert Advisor — Liquidity pool mapping and sweeps    |
//| Copyright 2024-2025, MARK1 Project                               |
//+------------------------------------------------------------------+
#pragma once
#ifndef __ICT_LIQUIDITY_MQH__
#define __ICT_LIQUIDITY_MQH__

#include "ICT_Constants.mqh"

enum ENUM_ICT_LIQUIDITY_SOURCE
{
   ICT_LIQUIDITY_NONE = 0,
   ICT_LIQUIDITY_ASIAN_HIGH,
   ICT_LIQUIDITY_ASIAN_LOW,
   ICT_LIQUIDITY_PDH,
   ICT_LIQUIDITY_PDL,
   ICT_LIQUIDITY_PWH,
   ICT_LIQUIDITY_PWL,
   ICT_LIQUIDITY_EQUAL_HIGHS,
   ICT_LIQUIDITY_EQUAL_LOWS
};

struct ICTLiquidityLevel
{
   bool                      valid;
   ENUM_ICT_LIQUIDITY_SOURCE source;
   string                    label;
   bool                      buySide;
   double                    price;
   datetime                  time;
   int                       touches;
   int                       sweepCount;     ///< Phase 2: number of times swept
   datetime                  lastSweepTime;  ///< Phase 2: most recent sweep timestamp
   bool                      isActive;       ///< Phase 2: false after final sweep/exhaustion
};

struct ICTLiquiditySweepSignal
{
   bool                      valid;
   ENUM_ICT_LIQUIDITY_SOURCE source;
   string                    label;
   bool                      bullishIntent;
   double                    sweptLevel;
   double                    sweepExtreme;
   double                    reclaimClose;
   datetime                  time;
};

string ICTLiquiditySourceToString(const ENUM_ICT_LIQUIDITY_SOURCE value)
{
   switch(value)
   {
      case ICT_LIQUIDITY_ASIAN_HIGH:   return "ASIAN_HIGH";
      case ICT_LIQUIDITY_ASIAN_LOW:    return "ASIAN_LOW";
      case ICT_LIQUIDITY_PDH:          return "PDH";
      case ICT_LIQUIDITY_PDL:          return "PDL";
      case ICT_LIQUIDITY_PWH:          return "PWH";
      case ICT_LIQUIDITY_PWL:          return "PWL";
      case ICT_LIQUIDITY_EQUAL_HIGHS:  return "EQUAL_HIGHS";
      case ICT_LIQUIDITY_EQUAL_LOWS:   return "EQUAL_LOWS";
      default:                         return "NONE";
   }
}

class CICTLiquidityEngine
{
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_timeframe;
   double          m_pointSize;
   double          m_pipSize;
   double          m_equalTolerancePips;
   double          m_minSweepPips;

   bool DetectSweepOfLevel(const ICTLiquidityLevel &level, ICTLiquiditySweepSignal &signal) const;
   bool LoadRates(const ENUM_TIMEFRAMES timeframe, const int count, MqlRates &rates[]) const;

public:
   CICTLiquidityEngine();

   void Configure(const string symbol,
                  const ENUM_TIMEFRAMES timeframe,
                  const double equalTolerancePips = 5.0,
                  const double minSweepPips = 2.0);

   bool GetPreviousDayHighLow(double &highValue, double &lowValue) const;
   bool GetPreviousWeekHighLow(double &highValue, double &lowValue) const;
   bool FindEqualHighs(ICTLiquidityLevel &level, const int lookbackBars = 120, const int minTouches = 2) const;
   bool FindEqualLows(ICTLiquidityLevel &level, const int lookbackBars = 120, const int minTouches = 2) const;
   bool DetectBestSweep(const double asianHigh,
                        const double asianLow,
                        const bool   asianRangeReady,
                        ICTLiquiditySweepSignal &signal) const;
};

CICTLiquidityEngine::CICTLiquidityEngine()
{
   m_symbol             = _Symbol;
   m_timeframe          = PERIOD_M15;
   m_pointSize          = _Point;
   m_pipSize            = _Point;
   m_equalTolerancePips = 5.0;
   m_minSweepPips       = 2.0;
}

void CICTLiquidityEngine::Configure(const string symbol,
                                    const ENUM_TIMEFRAMES timeframe,
                                    const double equalTolerancePips = 5.0,
                                    const double minSweepPips = 2.0)
{
   m_symbol             = symbol;
   m_timeframe          = timeframe;
   m_pointSize          = SymbolInfoDouble(symbol, SYMBOL_POINT);
   m_equalTolerancePips = equalTolerancePips;
   m_minSweepPips       = minSweepPips;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   m_pipSize  = ((digits == 3 || digits == 5) ? m_pointSize * 10.0 : m_pointSize);
}

bool CICTLiquidityEngine::LoadRates(const ENUM_TIMEFRAMES timeframe, const int count, MqlRates &rates[]) const
{
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(m_symbol, timeframe, 0, count, rates);
   return (copied > 10);
}

bool CICTLiquidityEngine::GetPreviousDayHighLow(double &highValue, double &lowValue) const
{
   highValue = iHigh(m_symbol, PERIOD_D1, 1);
   lowValue  = iLow(m_symbol, PERIOD_D1, 1);
   return (highValue > 0.0 && lowValue > 0.0);
}

bool CICTLiquidityEngine::GetPreviousWeekHighLow(double &highValue, double &lowValue) const
{
   highValue = iHigh(m_symbol, PERIOD_W1, 1);
   lowValue  = iLow(m_symbol, PERIOD_W1, 1);
   return (highValue > 0.0 && lowValue > 0.0);
}

bool CICTLiquidityEngine::FindEqualHighs(ICTLiquidityLevel &level, const int lookbackBars, const int minTouches) const
{
   MqlRates rates[];
   if(!LoadRates(m_timeframe, lookbackBars + 10, rates))
      return false;

   double tolerance = m_equalTolerancePips * m_pipSize;
   for(int i = lookbackBars; i >= 5; i--)
   {
      int touches = 1;
      double anchor = rates[i].high;
      for(int j = i - 1; j >= 1; j--)
      {
         if(MathAbs(rates[j].high - anchor) <= tolerance)
            touches++;
      }

      if(touches >= minTouches)
      {
         level.valid   = true;
         level.source  = ICT_LIQUIDITY_EQUAL_HIGHS;
         level.label   = "EQUAL_HIGHS";
         level.buySide = true;
         level.price   = anchor;
         level.time    = rates[i].time;
         level.touches = touches;
         return true;
      }
   }

   return false;
}

bool CICTLiquidityEngine::FindEqualLows(ICTLiquidityLevel &level, const int lookbackBars, const int minTouches) const
{
   MqlRates rates[];
   if(!LoadRates(m_timeframe, lookbackBars + 10, rates))
      return false;

   double tolerance = m_equalTolerancePips * m_pipSize;
   for(int i = lookbackBars; i >= 5; i--)
   {
      int touches = 1;
      double anchor = rates[i].low;
      for(int j = i - 1; j >= 1; j--)
      {
         if(MathAbs(rates[j].low - anchor) <= tolerance)
            touches++;
      }

      if(touches >= minTouches)
      {
         level.valid   = true;
         level.source  = ICT_LIQUIDITY_EQUAL_LOWS;
         level.label   = "EQUAL_LOWS";
         level.buySide = false;
         level.price   = anchor;
         level.time    = rates[i].time;
         level.touches = touches;
         return true;
      }
   }

   return false;
}

bool CICTLiquidityEngine::DetectSweepOfLevel(const ICTLiquidityLevel &level, ICTLiquiditySweepSignal &signal) const
{
   if(!level.valid)
      return false;

   double high1  = iHigh(m_symbol, m_timeframe, 1);
   double low1   = iLow(m_symbol,  m_timeframe, 1);
   double close1 = iClose(m_symbol, m_timeframe, 1);
   double high2  = iHigh(m_symbol, m_timeframe, 2);
   double low2   = iLow(m_symbol,  m_timeframe, 2);
   double close2 = iClose(m_symbol, m_timeframe, 2);
   double minSweepDistance = m_minSweepPips * m_pipSize;

   if(level.buySide)
   {
      bool sameBarSweep = (high1 >= level.price + minSweepDistance && close1 < level.price);
      bool nextBarSweep = (high2 >= level.price + minSweepDistance && close2 >= level.price && close1 < level.price);
      if(sameBarSweep || nextBarSweep)
      {
         signal.valid         = true;
         signal.source        = level.source;
         signal.label         = level.label;
         signal.bullishIntent = false;
         signal.sweptLevel    = level.price;
         signal.sweepExtreme  = sameBarSweep ? high1 : high2;
         signal.reclaimClose  = close1;
         signal.time          = iTime(m_symbol, m_timeframe, sameBarSweep ? 1 : 2);
         return true;
      }
   }
   else
   {
      bool sameBarSweep = (low1 <= level.price - minSweepDistance && close1 > level.price);
      bool nextBarSweep = (low2 <= level.price - minSweepDistance && close2 <= level.price && close1 > level.price);
      if(sameBarSweep || nextBarSweep)
      {
         signal.valid         = true;
         signal.source        = level.source;
         signal.label         = level.label;
         signal.bullishIntent = true;
         signal.sweptLevel    = level.price;
         signal.sweepExtreme  = sameBarSweep ? low1 : low2;
         signal.reclaimClose  = close1;
         signal.time          = iTime(m_symbol, m_timeframe, sameBarSweep ? 1 : 2);
         return true;
      }
   }

   return false;
}

bool CICTLiquidityEngine::DetectBestSweep(const double asianHigh,
                                          const double asianLow,
                                          const bool   asianRangeReady,
                                          ICTLiquiditySweepSignal &signal) const
{
   ZeroMemory(signal);
   signal.valid = false;

   ICTLiquidityLevel levels[8];
   ZeroMemory(levels);

   int levelCount = 0;
   if(asianRangeReady)
   {
      levels[levelCount].valid   = (asianHigh > 0.0);
      levels[levelCount].source  = ICT_LIQUIDITY_ASIAN_HIGH;
      levels[levelCount].label   = "ASIAN_HIGH";
      levels[levelCount].buySide = true;
      levels[levelCount].price   = asianHigh;
      levelCount++;

      levels[levelCount].valid   = (asianLow > 0.0);
      levels[levelCount].source  = ICT_LIQUIDITY_ASIAN_LOW;
      levels[levelCount].label   = "ASIAN_LOW";
      levels[levelCount].buySide = false;
      levels[levelCount].price   = asianLow;
      levelCount++;
   }

   double pdh, pdl, pwh, pwl;
   if(GetPreviousDayHighLow(pdh, pdl))
   {
      levels[levelCount].valid   = true;
      levels[levelCount].source  = ICT_LIQUIDITY_PDH;
      levels[levelCount].label   = "PDH";
      levels[levelCount].buySide = true;
      levels[levelCount].price   = pdh;
      levelCount++;

      levels[levelCount].valid   = true;
      levels[levelCount].source  = ICT_LIQUIDITY_PDL;
      levels[levelCount].label   = "PDL";
      levels[levelCount].buySide = false;
      levels[levelCount].price   = pdl;
      levelCount++;
   }

   if(GetPreviousWeekHighLow(pwh, pwl))
   {
      levels[levelCount].valid   = true;
      levels[levelCount].source  = ICT_LIQUIDITY_PWH;
      levels[levelCount].label   = "PWH";
      levels[levelCount].buySide = true;
      levels[levelCount].price   = pwh;
      levelCount++;

      levels[levelCount].valid   = true;
      levels[levelCount].source  = ICT_LIQUIDITY_PWL;
      levels[levelCount].label   = "PWL";
      levels[levelCount].buySide = false;
      levels[levelCount].price   = pwl;
      levelCount++;
   }

   ICTLiquidityLevel equalHighs;
   if(FindEqualHighs(equalHighs))
      levels[levelCount++] = equalHighs;

   ICTLiquidityLevel equalLows;
   if(FindEqualLows(equalLows))
      levels[levelCount++] = equalLows;

   ICTLiquiditySweepSignal bestCandidate;
   ZeroMemory(bestCandidate);
   bestCandidate.valid = false;

   for(int i = 0; i < levelCount; i++)
   {
      ICTLiquiditySweepSignal candidate;
      ZeroMemory(candidate);
      if(DetectSweepOfLevel(levels[i], candidate))
      {
         if(!bestCandidate.valid || candidate.time > bestCandidate.time)
            bestCandidate = candidate;
      }
   }

   if(bestCandidate.valid)
   {
      signal = bestCandidate;
      return true;
   }

   return false;
}

// ============================================================
// Phase 2 — IRL / ERL Classification
// ============================================================

/// @brief Liquidity classification: Internal or External Range Liquidity.
enum ENUM_LIQUIDITY_TYPE
{
   LIQ_IRL,   ///< Internal Range Liquidity (within H4 dealing range)
   LIQ_ERL,   ///< External Range Liquidity (beyond H4 dealing range)
   LIQ_NONE   ///< Unclassified
};

/// @brief Classifies a price level as IRL or ERL relative to the H4 dealing range.
/// @param level        Price level to classify
/// @param h4RangeHigh  Current H4 swing high
/// @param h4RangeLow   Current H4 swing low
ENUM_LIQUIDITY_TYPE ClassifyLiquidityType(const double level,
                                          const double h4RangeHigh,
                                          const double h4RangeLow)
{
   if(level > h4RangeHigh || level < h4RangeLow) return LIQ_ERL;
   return LIQ_IRL;
}

// ============================================================
// Phase 2 — Inducement (IDM) Detection
// ============================================================

/// @brief Inducement level data structure.
struct SInducementLevel
{
   double          price;      ///< IDM price level
   datetime        time;       ///< Time IDM formed
   bool            isSwept;    ///< True once price trades through this level
   ENUM_TIMEFRAMES timeframe;  ///< Timeframe IDM was detected on
   bool            isBullish;  ///< True = bullish IDM (STL swept), False = bearish
};

/// @brief Scans for an unswept IDM level on the given timeframe.
/// @param symbol        Instrument symbol
/// @param tf            Timeframe to scan (M15 or M5)
/// @param entryDirection +1 for long setup, -1 for short
/// @param lookback      Bars to scan
/// @param result        Output struct
/// @return True if IDM found
bool FindInducement(const string symbol,
                    const ENUM_TIMEFRAMES tf,
                    const int entryDirection,
                    const int lookback,
                    SInducementLevel &result)
{
   ZeroMemory(result);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, tf, 0, lookback + 5, rates);
   if(copied < 5) return false;

   double pointSize = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize = ((digits == 3 || digits == 5) ? pointSize * 10.0 : pointSize);

   // Look for the most recent minor swing (STH for bearish IDM, STL for bullish)
   for(int i = 2; i < lookback - 1; i++)
   {
      if(entryDirection > 0)  // bullish setup: find STL swept
      {
         bool isSTL = (rates[i].low < rates[i+1].low && rates[i].low <= rates[i-1].low);
         if(!isSTL) continue;

         // Check if current price has since swept below this STL
         double lowestSince = rates[0].low;
         for(int k = 1; k < i; k++)
            lowestSince = MathMin(lowestSince, rates[k].low);

         result.price     = rates[i].low;
         result.time      = rates[i].time;
         result.timeframe = tf;
         result.isBullish = true;
         result.isSwept   = (lowestSince < rates[i].low - pipSize * 0.1);
         return true;
      }
      else  // bearish setup: find STH swept
      {
         bool isSTH = (rates[i].high > rates[i+1].high && rates[i].high >= rates[i-1].high);
         if(!isSTH) continue;

         double highestSince = rates[0].high;
         for(int k = 1; k < i; k++)
            highestSince = MathMax(highestSince, rates[k].high);

         result.price     = rates[i].high;
         result.time      = rates[i].time;
         result.timeframe = tf;
         result.isBullish = false;
         result.isSwept   = (highestSince > rates[i].high + pipSize * 0.1);
         return true;
      }
   }
   return false;
}

// ============================================================
// Phase 2 — NDOG / NWOG Opening Gaps
// ============================================================

/// @brief Opening gap data structure.
struct SOpeningGap
{
   double   gapHigh;    ///< Upper boundary of the gap
   double   gapLow;     ///< Lower boundary of the gap
   datetime gapTime;    ///< Timestamp the gap formed
   bool     isFilled;   ///< True once price trades through both boundaries
   bool     isBullish;  ///< True = gap up (bullish), False = gap down (bearish)
};

/// @brief Computes today's New Day Opening Gap (00:00 GMT close vs open).
SOpeningGap ComputeNDOG(const string symbol)
{
   SOpeningGap gap;
   ZeroMemory(gap);
   double prevClose = iClose(symbol, PERIOD_D1, 1);
   double dayOpen   = iOpen (symbol, PERIOD_D1, 0);
   if(prevClose <= 0.0 || dayOpen <= 0.0) return gap;

   gap.gapTime   = iTime(symbol, PERIOD_D1, 0);
   gap.isBullish = (dayOpen > prevClose);
   gap.gapHigh   = MathMax(dayOpen, prevClose);
   gap.gapLow    = MathMin(dayOpen, prevClose);
   double bid    = SymbolInfoDouble(symbol, SYMBOL_BID);
   gap.isFilled  = (gap.isBullish ? bid <= gap.gapLow : bid >= gap.gapHigh);
   return gap;
}

/// @brief Computes this week's New Week Opening Gap (Friday close vs Monday open).
SOpeningGap ComputeNWOG(const string symbol)
{
   SOpeningGap gap;
   ZeroMemory(gap);
   double prevWeekClose = iClose(symbol, PERIOD_W1, 1);
   double weekOpen      = iOpen (symbol, PERIOD_W1, 0);
   if(prevWeekClose <= 0.0 || weekOpen <= 0.0) return gap;

   gap.gapTime   = iTime(symbol, PERIOD_W1, 0);
   gap.isBullish = (weekOpen > prevWeekClose);
   gap.gapHigh   = MathMax(weekOpen, prevWeekClose);
   gap.gapLow    = MathMin(weekOpen, prevWeekClose);
   double bid    = SymbolInfoDouble(symbol, SYMBOL_BID);
   gap.isFilled  = (gap.isBullish ? bid <= gap.gapLow : bid >= gap.gapHigh);
   return gap;
}

// ============================================================
// Phase 4 — Run on Stops
// ============================================================

/// @brief Result of a Run-on-Stops detection.
struct SRunOnStops
{
   double   sweptLevel;
   datetime sweepTime;
   bool     isBullishSetup;  ///< True = stops swept below, expect reversal up
   bool     isConfirmed;     ///< True once close-back confirmed
};

/// @brief Detects a rapid sweep (run on stops) of an equal-level cluster.
/// @param symbol      Instrument
/// @param tf          Timeframe to scan
/// @param equalLevel  The equal-highs or equal-lows level
/// @param isHighLevel True = equal highs (buy-side liquidity)
/// @param result      Output struct
/// @return True if a run on stops was detected
bool DetectRunOnStops(const string symbol,
                      const ENUM_TIMEFRAMES tf,
                      const double equalLevel,
                      const bool isHighLevel,
                      SRunOnStops &result)
{
   ZeroMemory(result);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, tf, 0, 10, rates);
   if(copied < 4) return false;

   double pointSize = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tolerance = pointSize * 5.0;

   // Look for candle that swept the level and closed back
   for(int i = 1; i < MathMin(copied - 1, 4); i++)
   {
      if(isHighLevel)
      {
         // Sweep above equal highs
         if(rates[i].high > equalLevel + tolerance)
         {
            result.sweptLevel      = equalLevel;
            result.sweepTime       = rates[i].time;
            result.isBullishSetup  = false;  // sweep above → bearish
            // Confirm: close below swept level
            result.isConfirmed = (rates[i].close < equalLevel);
            return true;
         }
      }
      else
      {
         // Sweep below equal lows
         if(rates[i].low < equalLevel - tolerance)
         {
            result.sweptLevel      = equalLevel;
            result.sweepTime       = rates[i].time;
            result.isBullishSetup  = true;   // sweep below → bullish
            result.isConfirmed = (rates[i].close > equalLevel);
            return true;
         }
      }
   }
   return false;
}

// ============================================================
// Phase 4 — Draw on Liquidity (DOL) Formal Selector
// ============================================================

/// @brief Type of Draw on Liquidity target.
enum ENUM_DOL_TYPE
{
   DOL_PDH,   ///< Previous Day High
   DOL_PDL,   ///< Previous Day Low
   DOL_PWH,   ///< Previous Week High
   DOL_PWL,   ///< Previous Week Low
   DOL_EQH,   ///< Equal Highs cluster
   DOL_EQL,   ///< Equal Lows cluster
   DOL_NWOG,  ///< New Week Opening Gap fill
   DOL_NDOG,  ///< New Day Opening Gap fill
   DOL_NONE
};

/// @brief A scored Draw on Liquidity target.
struct SDOLTarget
{
   ENUM_DOL_TYPE type;
   double        price;
   double        distancePips;
   int           confluenceScore; ///< Higher = more likely target
};

/// @brief Selects the highest-probability Draw on Liquidity target given current bias.
/// Scoring: PDH/PDL=3, PWH/PWL=4, EQH/EQL(2+ touches)=5, NWOG/NDOG unfilled=4.
/// @param symbol       Instrument
/// @param bullish      True = bullish bias (look for targets above)
/// @param entryPrice   Current entry price
/// @return             Best DOL target, or DOL_NONE if no qualifying targets
SDOLTarget SelectDOLTarget(const string symbol, const bool bullish, const double entryPrice)
{
   SDOLTarget best;
   ZeroMemory(best);
   best.type = DOL_NONE;

   double pointSize = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits    = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize   = ((digits == 3 || digits == 5) ? pointSize * 10.0 : pointSize);
   if(pipSize <= 0.0) return best;

   struct { ENUM_DOL_TYPE t; double p; int s; } candidates[10];
   int count = 0;

   double pdh = iHigh(symbol, PERIOD_D1, 1);
   double pdl = iLow (symbol, PERIOD_D1, 1);
   double pwh = iHigh(symbol, PERIOD_W1, 1);
   double pwl = iLow (symbol, PERIOD_W1, 1);

   if(bullish)
   {
      if(pdh > entryPrice) { candidates[count].t=DOL_PDH; candidates[count].p=pdh; candidates[count++].s=3; }
      if(pwh > entryPrice) { candidates[count].t=DOL_PWH; candidates[count].p=pwh; candidates[count++].s=4; }
   }
   else
   {
      if(pdl > 0.0 && pdl < entryPrice) { candidates[count].t=DOL_PDL; candidates[count].p=pdl; candidates[count++].s=3; }
      if(pwl > 0.0 && pwl < entryPrice) { candidates[count].t=DOL_PWL; candidates[count].p=pwl; candidates[count++].s=4; }
   }

   // EQH / EQL (score=5 for 2+ touch clusters)
   CICTLiquidityEngine tmpLiq;
   tmpLiq.Configure(symbol, PERIOD_M15);
   ICTLiquidityLevel eqh, eql;
   if(bullish && tmpLiq.FindEqualHighs(eqh) && eqh.price > entryPrice)
   { candidates[count].t=DOL_EQH; candidates[count].p=eqh.price; candidates[count++].s=5; }
   if(!bullish && tmpLiq.FindEqualLows(eql) && eql.price < entryPrice)
   { candidates[count].t=DOL_EQL; candidates[count].p=eql.price; candidates[count++].s=5; }

   // NDOG / NWOG (add +4 if unfilled and in direction)
   SOpeningGap ndog = ComputeNDOG(symbol);
   SOpeningGap nwog = ComputeNWOG(symbol);
   if(!ndog.isFilled)
   {
      double target = bullish ? ndog.gapHigh : ndog.gapLow;
      if((bullish && target > entryPrice) || (!bullish && target < entryPrice))
      { candidates[count].t=DOL_NDOG; candidates[count].p=target; candidates[count++].s=4; }
   }
   if(!nwog.isFilled)
   {
      double target = bullish ? nwog.gapHigh : nwog.gapLow;
      if((bullish && target > entryPrice) || (!bullish && target < entryPrice))
      { candidates[count].t=DOL_NWOG; candidates[count].p=target; candidates[count++].s=4; }
   }

   for(int i = 0; i < count; i++)
   {
      double dist = MathAbs(candidates[i].p - entryPrice) / pipSize;
      if(best.type == DOL_NONE || candidates[i].s > best.confluenceScore)
      {
         best.type            = candidates[i].t;
         best.price           = candidates[i].p;
         best.distancePips    = dist;
         best.confluenceScore = candidates[i].s;
      }
   }
   return best;
}

#endif // __ICT_LIQUIDITY_MQH__
