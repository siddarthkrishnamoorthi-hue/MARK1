//+------------------------------------------------------------------+
//| ICT_OrderBlock.mqh                                                |
//| MARK1 ICT Expert Advisor — Order block, breaker, and PD arrays  |
//| Copyright 2024-2025, MARK1 Project                               |
//+------------------------------------------------------------------+
#pragma once
#ifndef __ICT_ORDERBLOCK_MQH__
#define __ICT_ORDERBLOCK_MQH__

#include "ICT_Constants.mqh"
#include "ICT_Structure.mqh"

enum ENUM_ICT_ORDERBLOCK_KIND
{
   ICT_OB_STANDARD   = 0,
   ICT_OB_BREAKER    = 1,
   ICT_OB_MITIGATION = 2
};

struct ICTOrderBlockZone
{
   bool                     valid;
   bool                     bullish;
   ENUM_TIMEFRAMES          timeframe;
   ENUM_ICT_ORDERBLOCK_KIND kind;
   int                      sourceShift;
   datetime                 formedTime;
   double                   low;
   double                   high;
   double                   midpoint;
   bool                     invalidated;
   bool                     mitigated;
   bool                     isReclaimed;      ///< Phase 3: price returned to OB after invalidation
   datetime                 invalidatedTime;
   datetime                 reclaimedTime;
};

string ICTOrderBlockKindToString(const ENUM_ICT_ORDERBLOCK_KIND value)
{
   switch(value)
   {
      case ICT_OB_BREAKER:    return "BREAKER";
      case ICT_OB_MITIGATION: return "MITIGATION";
      default:                return "STANDARD";
   }
}

class CICTOrderBlockEngine
{
private:
   string             m_symbol;
   ENUM_TIMEFRAMES    m_timeframe;
   int                m_swingStrength;
   int                m_lookbackBars;
   double             m_pointSize;

   bool LoadRates(const int count, MqlRates &rates[]) const;
   bool IsBullishDisplacement(const MqlRates &rates[], const int shift) const;
   bool IsBearishDisplacement(const MqlRates &rates[], const int shift) const;
   void FinalizeZone(ICTOrderBlockZone &zone) const;

public:
   CICTOrderBlockEngine();

   void Configure(const string symbol,
                  const ENUM_TIMEFRAMES timeframe,
                  const int swingStrength,
                  const int lookbackBars);

   bool FindLatestOrderBlock(const bool bullish, ICTOrderBlockZone &zone) const;
   bool FindBreakerBlock(const bool bullish, ICTOrderBlockZone &zone) const;
   bool FindMitigationBlock(const bool bullish, ICTOrderBlockZone &zone) const;
};

CICTOrderBlockEngine::CICTOrderBlockEngine()
{
   m_symbol        = _Symbol;
   m_timeframe     = PERIOD_M15;
   m_swingStrength = 3;
   m_lookbackBars  = 20;
   m_pointSize     = _Point;
}

void CICTOrderBlockEngine::Configure(const string symbol,
                                     const ENUM_TIMEFRAMES timeframe,
                                     const int swingStrength,
                                     const int lookbackBars)
{
   m_symbol        = symbol;
   m_timeframe     = timeframe;
   m_swingStrength = MathMax(swingStrength, 2);
   m_lookbackBars  = MathMax(lookbackBars, 8);
   m_pointSize     = SymbolInfoDouble(symbol, SYMBOL_POINT);
}

bool CICTOrderBlockEngine::LoadRates(const int count, MqlRates &rates[]) const
{
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(m_symbol, m_timeframe, 0, count, rates);
   return (copied > 20);
}

bool CICTOrderBlockEngine::IsBullishDisplacement(const MqlRates &rates[], const int shift) const
{
   if(shift < 4)
      return false;

   if(!(rates[shift - 1].close > rates[shift - 1].open &&
        rates[shift - 2].close > rates[shift - 2].open &&
        rates[shift - 3].close > rates[shift - 3].open))
      return false;

   double priorHigh = rates[shift + 1].high;
   for(int i = shift + 1; i <= shift + 5 && i < ArraySize(rates); i++)
      priorHigh = MathMax(priorHigh, rates[i].high);

   double displacementClose = MathMax(rates[shift - 1].close, MathMax(rates[shift - 2].close, rates[shift - 3].close));
   return (displacementClose > priorHigh);
}

bool CICTOrderBlockEngine::IsBearishDisplacement(const MqlRates &rates[], const int shift) const
{
   if(shift < 4)
      return false;

   if(!(rates[shift - 1].close < rates[shift - 1].open &&
        rates[shift - 2].close < rates[shift - 2].open &&
        rates[shift - 3].close < rates[shift - 3].open))
      return false;

   double priorLow = rates[shift + 1].low;
   for(int i = shift + 1; i <= shift + 5 && i < ArraySize(rates); i++)
      priorLow = MathMin(priorLow, rates[i].low);

   double displacementClose = MathMin(rates[shift - 1].close, MathMin(rates[shift - 2].close, rates[shift - 3].close));
   return (displacementClose < priorLow);
}

void CICTOrderBlockEngine::FinalizeZone(ICTOrderBlockZone &zone) const
{
   zone.midpoint = (zone.low + zone.high) * 0.5;
}

bool CICTOrderBlockEngine::FindLatestOrderBlock(const bool bullish, ICTOrderBlockZone &zone) const
{
   ZeroMemory(zone);
   zone.valid = false;

   MqlRates rates[];
   if(!LoadRates(m_lookbackBars + 20, rates))
      return false;

   for(int shift = m_lookbackBars; shift >= 5; shift--)
   {
      bool candidate = bullish ? (rates[shift].close < rates[shift].open) : (rates[shift].close > rates[shift].open);
      if(!candidate)
         continue;

      bool displacement = bullish ? IsBullishDisplacement(rates, shift) : IsBearishDisplacement(rates, shift);
      if(!displacement)
         continue;

      zone.valid      = true;
      zone.bullish    = bullish;
      zone.timeframe  = m_timeframe;
      zone.kind       = ICT_OB_STANDARD;
      zone.sourceShift= shift;
      zone.formedTime = rates[shift].time;
      // ICT OB uses candle body, not wicks
      zone.low        = MathMin(rates[shift].open, rates[shift].close);
      zone.high       = MathMax(rates[shift].open, rates[shift].close);
      FinalizeZone(zone);
      zone.invalidated= false;
      zone.mitigated  = false;

      for(int check = shift - 1; check >= 1; check--)
      {
         if(bullish && rates[check].close < zone.low)
            zone.invalidated = true;
         if(!bullish && rates[check].close > zone.high)
            zone.invalidated = true;

         if(bullish && rates[check].low <= zone.midpoint)
            zone.mitigated = true;
         if(!bullish && rates[check].high >= zone.midpoint)
            zone.mitigated = true;
      }
      return true;
   }

   return false;
}

bool CICTOrderBlockEngine::FindBreakerBlock(const bool bullish, ICTOrderBlockZone &zone) const
{
   ICTOrderBlockZone oppositeZone;
   if(!FindLatestOrderBlock(!bullish, oppositeZone))
      return false;

   if(!oppositeZone.invalidated)
      return false;

   zone         = oppositeZone;
   zone.valid   = true;
   zone.bullish = bullish;
   zone.kind    = ICT_OB_BREAKER;
   return true;
}

bool CICTOrderBlockEngine::FindMitigationBlock(const bool bullish, ICTOrderBlockZone &zone) const
{
   ICTOrderBlockZone baseZone;
   if(!FindLatestOrderBlock(bullish, baseZone))
      return false;

   if(baseZone.invalidated || !baseZone.mitigated)
      return false;

   zone      = baseZone;
   zone.kind = ICT_OB_MITIGATION;
   return true;
}

// ============================================================
// Phase 3 — Rejection Block
// ============================================================

/// @brief Rejection Block zone (large-wick candle indicating institutional rejection).
struct SRejectionBlock
{
   double   wickHigh;   ///< Top of the wick
   double   wickLow;    ///< Bottom of the wick
   double   bodyHigh;   ///< Top of body
   double   bodyLow;    ///< Bottom of body
   datetime time;
   bool     isBullish;  ///< True = bullish rejection (lower wick dominant)
   bool     isActive;
};

/// @brief Detects the most recent Rejection Block on the given timeframe.
/// A candle qualifies when wickLength / totalRange > 0.65.
/// @param symbol    Instrument
/// @param tf        Timeframe
/// @param lookback  Bars to scan
/// @param result    Output struct
/// @return True if a rejection block was found
bool FindRejectionBlock(const string symbol,
                        const ENUM_TIMEFRAMES tf,
                        const int lookback,
                        SRejectionBlock &result)
{
   ZeroMemory(result);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, tf, 0, lookback + 5, rates);
   if(copied < 3) return false;

   for(int i = 1; i < MathMin(copied - 1, lookback + 1); i++)
   {
      double totalRange = rates[i].high - rates[i].low;
      if(totalRange <= 0.0) continue;

      double bodyHigh = MathMax(rates[i].open, rates[i].close);
      double bodyLow  = MathMin(rates[i].open, rates[i].close);
      double upperWick = rates[i].high - bodyHigh;
      double lowerWick = bodyLow - rates[i].low;

      if(lowerWick / totalRange > 0.65)  // bullish rejection
      {
         result.wickLow  = rates[i].low;
         result.wickHigh = bodyLow;
         result.bodyLow  = bodyLow;
         result.bodyHigh = bodyHigh;
         result.time     = rates[i].time;
         result.isBullish= true;
         result.isActive = true;
         return true;
      }
      if(upperWick / totalRange > 0.65)  // bearish rejection
      {
         result.wickLow  = bodyHigh;
         result.wickHigh = rates[i].high;
         result.bodyLow  = bodyLow;
         result.bodyHigh = bodyHigh;
         result.time     = rates[i].time;
         result.isBullish= false;
         result.isActive = true;
         return true;
      }
   }
   return false;
}

// ============================================================
// Phase 3 — Propulsion Block
// ============================================================

/// @brief Propulsion Block (strong displacement candle preceding an FVG).
struct SPropulsionBlock
{
   double   blockHigh;
   double   blockLow;
   double   blockOpen;
   double   blockClose;
   datetime time;
   bool     isBullish;
   bool     isActive;
   bool     hasFVG;  ///< True if a paired FVG was confirmed after this block
};

/// @brief Detects the most recent Propulsion Block on the given timeframe.
/// Qualifies when candle body > 1.5x average of prior 10 candles and close-to-range ratio > 0.70.
/// @param symbol    Instrument
/// @param tf        Timeframe
/// @param lookback  Bars to scan
/// @param result    Output struct
/// @return True if a propulsion block was found
bool FindPropulsionBlock(const string symbol,
                         const ENUM_TIMEFRAMES tf,
                         const int lookback,
                         SPropulsionBlock &result)
{
   ZeroMemory(result);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int needed = lookback + 15;
   int copied = CopyRates(symbol, tf, 0, needed, rates);
   if(copied < 15) return false;

   for(int i = 1; i < MathMin(copied - 12, lookback + 1); i++)
   {
      double bodySize = MathAbs(rates[i].close - rates[i].open);
      if(bodySize <= 0.0) continue;

      // Average body of prior 10 candles
      double avgBody = 0.0;
      for(int k = i + 1; k < i + 11 && k < copied; k++)
         avgBody += MathAbs(rates[k].close - rates[k].open);
      avgBody /= 10.0;
      if(avgBody <= 0.0 || bodySize < avgBody * 1.5) continue;

      double totalRange = rates[i].high - rates[i].low;
      if(totalRange <= 0.0) continue;

      bool isBull = (rates[i].close > rates[i].open);
      double closeToRangeRatio = isBull
         ? (rates[i].close - rates[i].low)  / totalRange
         : (rates[i].high  - rates[i].close) / totalRange;
      if(closeToRangeRatio < 0.70) continue;

      result.blockHigh  = rates[i].high;
      result.blockLow   = rates[i].low;
      result.blockOpen  = rates[i].open;
      result.blockClose = rates[i].close;
      result.time       = rates[i].time;
      result.isBullish  = isBull;
      result.isActive   = true;
      // Check if FVG follows within 3 candles
      result.hasFVG = false;
      for(int j = i - 1; j >= MathMax(1, i - 3); j--)
      {
         if(j + 1 >= copied || j - 1 < 0) continue;
         if(isBull && rates[j + 1].high < rates[j - 1].low)
            { result.hasFVG = true; break; }
         if(!isBull && rates[j + 1].low > rates[j - 1].high)
            { result.hasFVG = true; break; }
      }
      return true;
   }
   return false;
}

// ============================================================
// Phase 3 — Vacuum Block
// ============================================================

/// @brief Vacuum Block (price zone absent of candle bodies but crossed by wicks).
struct SVacuumBlock
{
   double   zoneHigh;
   double   zoneLow;
   datetime formed;
   bool     isFilled;  ///< True once a candle body closes inside the zone
};

/// @brief Detects a Vacuum Block zone on the given timeframe.
/// @param symbol         Instrument
/// @param tf             Timeframe
/// @param lookback       Bars to scan
/// @param minVacuumPips  Minimum zone size in pips
/// @param result         Output struct
/// @return True if a vacuum block was found
bool FindVacuumBlock(const string symbol,
                     const ENUM_TIMEFRAMES tf,
                     const int lookback,
                     const double minVacuumPips,
                     SVacuumBlock &result)
{
   ZeroMemory(result);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, tf, 0, lookback + 5, rates);
   if(copied < 5) return false;

   double pointSize = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize   = ((digits == 3 || digits == 5) ? pointSize * 10.0 : pointSize);
   double minSize   = minVacuumPips * pipSize;

   // Find a price range where no candle bodies appear but wicks crossed it
   for(int i = lookback; i >= 3; i--)
   {
      for(int j = i - 1; j >= 1; j--)
      {
         double zHigh = MathMin(rates[i].high, rates[j].high);
         double zLow  = MathMax(rates[i].low,  rates[j].low);
         if(zHigh - zLow < minSize) continue;

         // Check: no candle body inside zone, at least one wick crossed
         bool noBodies = true;
         bool wickCrossed = false;
         for(int k = i; k >= j; k--)
         {
            double bH = MathMax(rates[k].open, rates[k].close);
            double bL = MathMin(rates[k].open, rates[k].close);
            if(bH > zLow && bL < zHigh) { noBodies = false; break; }
            if(rates[k].high > zLow || rates[k].low < zHigh) wickCrossed = true;
         }
         if(!noBodies || !wickCrossed) continue;

         result.zoneHigh = zHigh;
         result.zoneLow  = zLow;
         result.formed   = rates[i].time;
         result.isFilled = false;
         return true;
      }
   }
   return false;
}

#endif // __ICT_ORDERBLOCK_MQH__
