//+------------------------------------------------------------------+
//| ICT_Structure.mqh                                                 |
//| MARK1 ICT Expert Advisor — Multi-timeframe swing/BOS/CHoCH/MSS  |
//| Copyright 2024-2025, MARK1 Project                               |
//+------------------------------------------------------------------+
#pragma once
#ifndef __ICT_STRUCTURE_MQH__
#define __ICT_STRUCTURE_MQH__

#include "ICT_Constants.mqh"

enum ENUM_ICT_SWING_CLASSIFICATION
{
   ICT_SWING_UNCLASSIFIED = 0,
   ICT_SWING_HH           = 1,
   ICT_SWING_HL           = 2,
   ICT_SWING_LH           = 3,
   ICT_SWING_LL           = 4
};

enum ENUM_ICT_STRUCTURE_BIAS
{
   ICT_BIAS_NEUTRAL = 0,
   ICT_BIAS_BULLISH = 1,
   ICT_BIAS_BEARISH = 2,
   ICT_BIAS_RANGE   = 3
};

enum ENUM_ICT_BREAK_CLASSIFICATION
{
   ICT_BREAK_NONE        = 0,
   ICT_BREAK_BULLISH_BOS = 1,
   ICT_BREAK_BEARISH_BOS = 2,
   ICT_BREAK_BULLISH_CHOCH = 3,
   ICT_BREAK_BEARISH_CHOCH = 4,
   ICT_BREAK_BULLISH_MSS = 5,
   ICT_BREAK_BEARISH_MSS = 6
};

struct ICTSwingPoint
{
   bool                           valid;
   bool                           isHigh;
   int                            barShift;
   datetime                       time;
   double                         price;
   ENUM_ICT_SWING_CLASSIFICATION  classification;
};

struct ICTStructureSnapshot
{
   bool                     valid;
   string                   symbol;
   ENUM_TIMEFRAMES          timeframe;
   int                      swingStrength;
   int                      barsAnalyzed;
   ENUM_ICT_STRUCTURE_BIAS  bias;
   ICTSwingPoint            latestHigh;
   ICTSwingPoint            previousHigh;
   ICTSwingPoint            latestLow;
   ICTSwingPoint            previousLow;
};

struct ICTStructureBreakSignal
{
   bool                          valid;
   ENUM_ICT_BREAK_CLASSIFICATION classification;
   ENUM_ICT_STRUCTURE_BIAS       priorBias;
   datetime                      time;
   int                           barShift;
   double                        level;
   double                        closePrice;
};

string ICTSwingClassificationToString(const ENUM_ICT_SWING_CLASSIFICATION value)
{
   switch(value)
   {
      case ICT_SWING_HH:           return "HH";
      case ICT_SWING_HL:           return "HL";
      case ICT_SWING_LH:           return "LH";
      case ICT_SWING_LL:           return "LL";
      default:                     return "UNCLASSIFIED";
   }
}

string ICTStructureBiasToString(const ENUM_ICT_STRUCTURE_BIAS value)
{
   switch(value)
   {
      case ICT_BIAS_BULLISH: return "BULLISH";
      case ICT_BIAS_BEARISH: return "BEARISH";
      case ICT_BIAS_RANGE:   return "RANGE";
      default:               return "NEUTRAL";
   }
}

string ICTBreakClassificationToString(const ENUM_ICT_BREAK_CLASSIFICATION value)
{
   switch(value)
   {
      case ICT_BREAK_BULLISH_BOS:   return "BULLISH_BOS";
      case ICT_BREAK_BEARISH_BOS:   return "BEARISH_BOS";
      case ICT_BREAK_BULLISH_CHOCH: return "BULLISH_CHOCH";
      case ICT_BREAK_BEARISH_CHOCH: return "BEARISH_CHOCH";
      case ICT_BREAK_BULLISH_MSS:   return "BULLISH_MSS";
      case ICT_BREAK_BEARISH_MSS:   return "BEARISH_MSS";
      default:                      return "NONE";
   }
}

bool ICTTimeframeIsH1OrHigher(const ENUM_TIMEFRAMES timeframe)
{
   switch(timeframe)
   {
      case PERIOD_H1:
      case PERIOD_H2:
      case PERIOD_H3:
      case PERIOD_H4:
      case PERIOD_H6:
      case PERIOD_H8:
      case PERIOD_H12:
      case PERIOD_D1:
      case PERIOD_W1:
      case PERIOD_MN1:
         return true;
      default:
         return false;
   }
}

class CICTStructureEngine
{
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_timeframe;
   int             m_swingStrength;
   double          m_pointSize;
   MqlRates        m_rates[];
   ICTSwingPoint   m_swingHighs[];
   ICTSwingPoint   m_swingLows[];
   datetime        m_lastBar0Time;  ///< Time of bar[0] at previous Refresh() — enables incremental scan

   bool   IsValidIndex(const int index) const;
   bool   IsSwingHigh(const int index) const;
   bool   IsSwingLow(const int index) const;
   void   ResetState();
   void   AppendSwing(ICTSwingPoint &target[], const ICTSwingPoint &swing);
   ENUM_ICT_SWING_CLASSIFICATION ClassifyHigh(const double price) const;
   ENUM_ICT_SWING_CLASSIFICATION ClassifyLow(const double price) const;
   ENUM_ICT_STRUCTURE_BIAS ResolveBias() const;
   bool   GetLatestClosedBar(MqlRates &bar) const;

public:
   CICTStructureEngine();

   void Configure(const string symbol, const ENUM_TIMEFRAMES timeframe, const int swingStrength = 3);
   bool Refresh(const int barsToLoad = 400);
   int  SwingHighCount() const;
   int  SwingLowCount() const;
   bool GetSwingHigh(const int logicalIndex, ICTSwingPoint &swing) const;
   bool GetSwingLow(const int logicalIndex, ICTSwingPoint &swing) const;
   bool BuildSnapshot(ICTStructureSnapshot &snapshot) const;
   bool GetLatestBreakSignal(ICTStructureBreakSignal &signal) const;
};

CICTStructureEngine::CICTStructureEngine()
{
   m_symbol        = _Symbol;
   m_timeframe     = PERIOD_CURRENT;
   m_swingStrength = 3;
   m_pointSize     = _Point;
   m_lastBar0Time  = 0;
   ArraySetAsSeries(m_rates, true);
   ResetState();
}

void CICTStructureEngine::Configure(const string symbol, const ENUM_TIMEFRAMES timeframe, const int swingStrength)
{
   m_symbol        = symbol;
   m_timeframe     = timeframe;
   m_swingStrength = MathMax(swingStrength, 1);
   m_pointSize     = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(m_pointSize <= 0.0)
      m_pointSize = _Point;
   m_lastBar0Time = 0;  // Force full rescan after reconfiguration
}

void CICTStructureEngine::ResetState()
{
   ArrayResize(m_swingHighs, 0);
   ArrayResize(m_swingLows, 0);
}

int CICTStructureEngine::SwingHighCount() const
{
   return ArraySize(m_swingHighs);
}

int CICTStructureEngine::SwingLowCount() const
{
   return ArraySize(m_swingLows);
}

bool CICTStructureEngine::IsValidIndex(const int index) const
{
   if(index < m_swingStrength)
      return false;

   int barsCount = ArraySize(m_rates);
   if(index > (barsCount - 1 - m_swingStrength))
      return false;

   return true;
}

bool CICTStructureEngine::IsSwingHigh(const int index) const
{
   if(!IsValidIndex(index))
      return false;

   for(int step = 1; step <= m_swingStrength; step++)
   {
      // Allow equal highs on older bars (right side) — BUG FIX: was <= which rejected equal highs
      if(m_rates[index].high < m_rates[index + step].high)
         return false;
      if(m_rates[index].high < m_rates[index - step].high)
         return false;
   }

   return true;
}

bool CICTStructureEngine::IsSwingLow(const int index) const
{
   if(!IsValidIndex(index))
      return false;

   for(int step = 1; step <= m_swingStrength; step++)
   {
      // Allow equal lows on older bars (right side) — BUG FIX: was >= which rejected equal lows
      if(m_rates[index].low > m_rates[index + step].low)
         return false;
      if(m_rates[index].low > m_rates[index - step].low)
         return false;
   }

   return true;
}

void CICTStructureEngine::AppendSwing(ICTSwingPoint &target[], const ICTSwingPoint &swing)
{
   int nextIndex = ArraySize(target);
   ArrayResize(target, nextIndex + 1);
   target[nextIndex] = swing;
}

ENUM_ICT_SWING_CLASSIFICATION CICTStructureEngine::ClassifyHigh(const double price) const
{
   int count = ArraySize(m_swingHighs);
   if(count == 0)
      return ICT_SWING_UNCLASSIFIED;

   double previous = m_swingHighs[count - 1].price;
   double epsilon  = MathMax(m_pointSize * 0.5, 0.00000001);
   return (price > previous + epsilon) ? ICT_SWING_HH : ICT_SWING_LH;
}

ENUM_ICT_SWING_CLASSIFICATION CICTStructureEngine::ClassifyLow(const double price) const
{
   int count = ArraySize(m_swingLows);
   if(count == 0)
      return ICT_SWING_UNCLASSIFIED;

   double previous = m_swingLows[count - 1].price;
   double epsilon  = MathMax(m_pointSize * 0.5, 0.00000001);
   return (price > previous + epsilon) ? ICT_SWING_HL : ICT_SWING_LL;
}

ENUM_ICT_STRUCTURE_BIAS CICTStructureEngine::ResolveBias() const
{
   if(ArraySize(m_swingHighs) < 2 || ArraySize(m_swingLows) < 2)
      return ICT_BIAS_NEUTRAL;

   double epsilon      = MathMax(m_pointSize * 0.5, 0.00000001);
   double latestHigh   = m_swingHighs[ArraySize(m_swingHighs) - 1].price;
   double previousHigh = m_swingHighs[ArraySize(m_swingHighs) - 2].price;
   double latestLow    = m_swingLows[ArraySize(m_swingLows) - 1].price;
   double previousLow  = m_swingLows[ArraySize(m_swingLows) - 2].price;

   bool bullish = (latestHigh > previousHigh + epsilon) && (latestLow > previousLow + epsilon);
   bool bearish = (latestHigh < previousHigh - epsilon) && (latestLow < previousLow - epsilon);

   if(bullish)
      return ICT_BIAS_BULLISH;
   if(bearish)
      return ICT_BIAS_BEARISH;

   return ICT_BIAS_RANGE;
}

bool CICTStructureEngine::GetLatestClosedBar(MqlRates &bar) const
{
   if(ArraySize(m_rates) < 2)
      return false;

   bar = m_rates[1];
   return true;
}

bool CICTStructureEngine::Refresh(const int barsToLoad)
{
   // ── Same-bar gate: if the bar hasn't changed, state is current ──
   // Skips CopyRates entirely — handles callers without external bar-change gates
   // (e.g. RefreshAnalysisEngines calls H4/H1 engines every M1 bar).
   if(m_lastBar0Time > 0
      && (ArraySize(m_swingHighs) > 0 || ArraySize(m_swingLows) > 0))
   {
      datetime quickCheck = iTime(m_symbol, m_timeframe, 0);
      if(quickCheck > 0 && quickCheck == m_lastBar0Time)
         return true;
   }

   int requiredBars = MathMax(barsToLoad, (m_swingStrength * 2) + 20);
   int copied = CopyRates(m_symbol, m_timeframe, 0, requiredBars, m_rates);
   if(copied < (m_swingStrength * 2) + 5)
      return false;

   ArraySetAsSeries(m_rates, true);

   datetime currentBar0 = m_rates[0].time;

   int  oldestEligible = copied - 1 - m_swingStrength;
   bool haveAny        = false;
   bool lastWasHigh    = false;
   int  scanFrom       = oldestEligible;
   bool fullScan       = true;

   // ── Incremental path: only rescan the frontier zone ──
   // When few new bars have formed, keep stable swings intact and only
   // process the newly confirmable bars (those that were within m_swingStrength
   // of the newest bar at the previous scan and now have enough right-side bars).
   if(m_lastBar0Time > 0 && currentBar0 > m_lastBar0Time
      && (ArraySize(m_swingHighs) > 0 || ArraySize(m_swingLows) > 0))
   {
      // Count new bars since last refresh
      int newBars = 0;
      for(int b = 0; b < copied; b++)
      {
         if(m_rates[b].time <= m_lastBar0Time)
         { newBars = b; break; }
      }

      if(newBars > 0 && newBars <= m_swingStrength * 3)
      {
         // Frontier = bars at barShift [m_swingStrength .. m_swingStrength + newBars]
         int frontierOldest = MathMin(m_swingStrength + newBars, oldestEligible);
         datetime frontierTime = m_rates[frontierOldest].time;

         // Strip swings in frontier zone — they'll be re-detected
         while(ArraySize(m_swingHighs) > 0
               && m_swingHighs[ArraySize(m_swingHighs) - 1].time >= frontierTime)
            ArrayResize(m_swingHighs, ArraySize(m_swingHighs) - 1);
         while(ArraySize(m_swingLows) > 0
               && m_swingLows[ArraySize(m_swingLows) - 1].time >= frontierTime)
            ArrayResize(m_swingLows, ArraySize(m_swingLows) - 1);

         // Recover alternation state from the most recent stable swing
         datetime lastHT = (ArraySize(m_swingHighs) > 0)
                           ? m_swingHighs[ArraySize(m_swingHighs) - 1].time : 0;
         datetime lastLT = (ArraySize(m_swingLows) > 0)
                           ? m_swingLows[ArraySize(m_swingLows) - 1].time : 0;

         if(lastHT > 0 || lastLT > 0)
         {
            haveAny     = true;
            lastWasHigh = (lastHT > lastLT);
         }

         scanFrom = frontierOldest;
         fullScan = false;
      }
   }

   if(fullScan)
      ResetState();

   // BUG FIX #1 — Alternation enforcement: swings must alternate H→L→H→L.
   // Consecutive same-type swings collapse into the more extreme one.
   // BUG FIX #2 — Classification context: when a same-type swing is replaced by a
   // more extreme one, re-classify it against the prior confirmed swing of the same type.
   for(int index = scanFrom; index >= m_swingStrength; index--)
   {
      bool isHigh = IsSwingHigh(index);
      bool isLow  = IsSwingLow(index);

      // Resolve conflict: same bar qualifies as both — prefer opposite of last accepted
      if(isHigh && isLow)
      {
         if(haveAny && lastWasHigh) isHigh = false;
         else                       isLow  = false;
      }

      if(isHigh)
      {
         if(!haveAny || !lastWasHigh)
         {
            // Valid: first swing or correct alternation (low→high)
            ICTSwingPoint sp;
            sp.valid          = true;
            sp.isHigh         = true;
            sp.barShift       = index;
            sp.time           = m_rates[index].time;
            sp.price          = m_rates[index].high;
            sp.classification = ClassifyHigh(sp.price);
            AppendSwing(m_swingHighs, sp);
            lastWasHigh = true;
            haveAny     = true;
         }
         else
         {
            // Consecutive high — keep only the more extreme (higher) one
            int lastIdx = ArraySize(m_swingHighs) - 1;
            if(m_rates[index].high > m_swingHighs[lastIdx].price)
            {
               m_swingHighs[lastIdx].barShift = index;
               m_swingHighs[lastIdx].time     = m_rates[index].time;
               m_swingHighs[lastIdx].price    = m_rates[index].high;
               // Re-classify against the prior confirmed high
               if(lastIdx > 0)
               {
                  double priorPrice = m_swingHighs[lastIdx - 1].price;
                  double eps        = MathMax(m_pointSize * 0.5, 0.00000001);
                  m_swingHighs[lastIdx].classification =
                     (m_rates[index].high > priorPrice + eps) ? ICT_SWING_HH : ICT_SWING_LH;
               }
            }
         }
      }
      else if(isLow)
      {
         if(!haveAny || lastWasHigh)
         {
            // Valid: first swing or correct alternation (high→low)
            ICTSwingPoint sp;
            sp.valid          = true;
            sp.isHigh         = false;
            sp.barShift       = index;
            sp.time           = m_rates[index].time;
            sp.price          = m_rates[index].low;
            sp.classification = ClassifyLow(sp.price);
            AppendSwing(m_swingLows, sp);
            lastWasHigh = false;
            haveAny     = true;
         }
         else
         {
            // Consecutive low — keep only the more extreme (lower) one
            int lastIdx = ArraySize(m_swingLows) - 1;
            if(m_rates[index].low < m_swingLows[lastIdx].price)
            {
               m_swingLows[lastIdx].barShift = index;
               m_swingLows[lastIdx].time     = m_rates[index].time;
               m_swingLows[lastIdx].price    = m_rates[index].low;
               // Re-classify against the prior confirmed low
               if(lastIdx > 0)
               {
                  double priorPrice = m_swingLows[lastIdx - 1].price;
                  double eps        = MathMax(m_pointSize * 0.5, 0.00000001);
                  m_swingLows[lastIdx].classification =
                     (m_rates[index].low > priorPrice + eps) ? ICT_SWING_HL : ICT_SWING_LL;
               }
            }
         }
      }
   }

   m_lastBar0Time = currentBar0;
   return (ArraySize(m_swingHighs) > 0 || ArraySize(m_swingLows) > 0);
}

bool CICTStructureEngine::GetSwingHigh(const int logicalIndex, ICTSwingPoint &swing) const
{
   int count = ArraySize(m_swingHighs);
   if(logicalIndex < 0 || logicalIndex >= count)
      return false;

   swing = m_swingHighs[count - 1 - logicalIndex];
   return swing.valid;
}

bool CICTStructureEngine::GetSwingLow(const int logicalIndex, ICTSwingPoint &swing) const
{
   int count = ArraySize(m_swingLows);
   if(logicalIndex < 0 || logicalIndex >= count)
      return false;

   swing = m_swingLows[count - 1 - logicalIndex];
   return swing.valid;
}

bool CICTStructureEngine::BuildSnapshot(ICTStructureSnapshot &snapshot) const
{
   snapshot.valid         = false;
   snapshot.symbol        = m_symbol;
   snapshot.timeframe     = m_timeframe;
   snapshot.swingStrength = m_swingStrength;
   snapshot.barsAnalyzed  = ArraySize(m_rates);
   snapshot.bias          = ResolveBias();

   if(ArraySize(m_swingHighs) > 0)
      snapshot.latestHigh = m_swingHighs[ArraySize(m_swingHighs) - 1];
   if(ArraySize(m_swingHighs) > 1)
      snapshot.previousHigh = m_swingHighs[ArraySize(m_swingHighs) - 2];
   if(ArraySize(m_swingLows) > 0)
      snapshot.latestLow = m_swingLows[ArraySize(m_swingLows) - 1];
   if(ArraySize(m_swingLows) > 1)
      snapshot.previousLow = m_swingLows[ArraySize(m_swingLows) - 2];

   snapshot.valid = (ArraySize(m_swingHighs) >= 2 && ArraySize(m_swingLows) >= 2);
   return snapshot.valid;
}

bool CICTStructureEngine::GetLatestBreakSignal(ICTStructureBreakSignal &signal) const
{
   signal.valid          = false;
   signal.classification = ICT_BREAK_NONE;
   signal.priorBias      = ICT_BIAS_NEUTRAL;
   signal.time           = 0;
   signal.barShift       = 1;
   signal.level          = 0.0;
   signal.closePrice     = 0.0;

   ICTStructureSnapshot snapshot;
   if(!BuildSnapshot(snapshot))
      return false;

   MqlRates latestClosedBar;
   if(!GetLatestClosedBar(latestClosedBar))
      return false;

   double epsilon = MathMax(m_pointSize * 0.5, 0.00000001);
   signal.priorBias  = snapshot.bias;
   signal.time       = latestClosedBar.time;
   signal.closePrice = latestClosedBar.close;

   if(snapshot.bias == ICT_BIAS_BULLISH)
   {
      if(latestClosedBar.close > snapshot.latestHigh.price + epsilon)
      {
         signal.valid          = true;
         signal.classification = ICT_BREAK_BULLISH_BOS;
         signal.level          = snapshot.latestHigh.price;
         return true;
      }

      if(latestClosedBar.close < snapshot.latestLow.price - epsilon)
      {
         signal.valid          = true;
         signal.classification = ICTTimeframeIsH1OrHigher(m_timeframe) ? ICT_BREAK_BEARISH_MSS : ICT_BREAK_BEARISH_CHOCH;
         signal.level          = snapshot.latestLow.price;
         return true;
      }

      return false;
   }

   if(snapshot.bias == ICT_BIAS_BEARISH)
   {
      if(latestClosedBar.close < snapshot.latestLow.price - epsilon)
      {
         signal.valid          = true;
         signal.classification = ICT_BREAK_BEARISH_BOS;
         signal.level          = snapshot.latestLow.price;
         return true;
      }

      if(latestClosedBar.close > snapshot.latestHigh.price + epsilon)
      {
         signal.valid          = true;
         signal.classification = ICTTimeframeIsH1OrHigher(m_timeframe) ? ICT_BREAK_BULLISH_MSS : ICT_BREAK_BULLISH_CHOCH;
         signal.level          = snapshot.latestHigh.price;
         return true;
      }

      return false;
   }

   if(latestClosedBar.close > snapshot.latestHigh.price + epsilon)
   {
      signal.valid          = true;
      signal.classification = ICT_BREAK_BULLISH_BOS;
      signal.level          = snapshot.latestHigh.price;
      return true;
   }

   if(latestClosedBar.close < snapshot.latestLow.price - epsilon)
   {
      signal.valid          = true;
      signal.classification = ICT_BREAK_BEARISH_BOS;
      signal.level          = snapshot.latestLow.price;
      return true;
   }

   return false;
}

#endif // __ICT_STRUCTURE_MQH__
