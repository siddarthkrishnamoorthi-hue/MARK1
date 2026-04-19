//+------------------------------------------------------------------+
//| ICT_OrderBlock.mqh                                               |
//| Order block, breaker block, and mitigation detection             |
//+------------------------------------------------------------------+
#ifndef __ICT_ORDERBLOCK_MQH__
#define __ICT_ORDERBLOCK_MQH__

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
      zone.low        = rates[shift].low;
      zone.high       = rates[shift].high;
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

#endif // __ICT_ORDERBLOCK_MQH__
