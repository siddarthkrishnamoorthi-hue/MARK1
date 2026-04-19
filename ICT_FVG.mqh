//+------------------------------------------------------------------+
//| ICT_FVG.mqh                                                      |
//| Fair Value Gap, inverse gap, and BPR engine                      |
//+------------------------------------------------------------------+
#ifndef __ICT_FVG_MQH__
#define __ICT_FVG_MQH__

enum ENUM_ICT_FVG_STATE
{
   ICT_FVG_INVALID = 0,
   ICT_FVG_ACTIVE,
   ICT_FVG_PARTIAL_FILL,
   ICT_FVG_FILLED,
   ICT_FVG_INVERSE
};

struct ICTFVGZone
{
   bool               valid;
   bool               bullish;
   ENUM_TIMEFRAMES    timeframe;
   int                sourceShift;
   datetime           formedTime;
   double             low;
   double             high;
   double             midpoint;
   double             consequentEncroachment;
   double             sizePoints;
   ENUM_ICT_FVG_STATE state;
};

struct ICTBPRZone
{
   bool            valid;
   ENUM_TIMEFRAMES timeframe;
   double          low;
   double          high;
   double          midpoint;
   datetime        bullishFVGTime;
   datetime        bearishFVGTime;
};

string ICTFVGStateToString(const ENUM_ICT_FVG_STATE value)
{
   switch(value)
   {
      case ICT_FVG_ACTIVE:       return "ACTIVE";
      case ICT_FVG_PARTIAL_FILL: return "PARTIAL_FILL";
      case ICT_FVG_FILLED:       return "FILLED";
      case ICT_FVG_INVERSE:      return "INVERSE";
      default:                   return "INVALID";
   }
}

class CICTFVGEngine
{
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_timeframe;
   double          m_pointSize;
   double          m_minGapPoints;

   bool LoadRates(const int count, MqlRates &rates[]) const;
   void FinalizeZone(ICTFVGZone &zone) const;

public:
   CICTFVGEngine();

   void Configure(const string symbol, const ENUM_TIMEFRAMES timeframe, const double minGapPoints);
   bool FindLatestFVG(const bool bullish, const int lookbackBars, ICTFVGZone &zone, const datetime formedAfter = 0) const;
   bool RefreshZoneState(ICTFVGZone &zone, const int barsToCheck = 80) const;
   bool DetectInverseFVG(const ICTFVGZone &zone, ICTFVGZone &inverseZone) const;
   bool FindLatestBPR(const int lookbackBars, ICTBPRZone &bpr) const;
};

CICTFVGEngine::CICTFVGEngine()
{
   m_symbol       = _Symbol;
   m_timeframe    = PERIOD_M15;
   m_pointSize    = _Point;
   m_minGapPoints = 10.0;
}

void CICTFVGEngine::Configure(const string symbol, const ENUM_TIMEFRAMES timeframe, const double minGapPoints)
{
   m_symbol       = symbol;
   m_timeframe    = timeframe;
   m_pointSize    = SymbolInfoDouble(symbol, SYMBOL_POINT);
   m_minGapPoints = minGapPoints;
}

bool CICTFVGEngine::LoadRates(const int count, MqlRates &rates[]) const
{
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(m_symbol, m_timeframe, 0, count, rates);
   return (copied > 10);
}

void CICTFVGEngine::FinalizeZone(ICTFVGZone &zone) const
{
   zone.midpoint                = (zone.low + zone.high) * 0.5;
   zone.consequentEncroachment  = zone.midpoint;
   zone.sizePoints              = (zone.high - zone.low) / m_pointSize;
}

bool CICTFVGEngine::FindLatestFVG(const bool bullish,
                                  const int lookbackBars,
                                  ICTFVGZone &zone,
                                  const datetime formedAfter = 0) const
{
   ZeroMemory(zone);
   zone.valid = false;

   MqlRates rates[];
   if(!LoadRates(lookbackBars + 10, rates))
      return false;

   for(int center = lookbackBars; center >= 2; center--)
   {
      datetime formedTime = rates[center].time;
      if(formedAfter > 0 && formedTime <= formedAfter)
         continue;

      if(bullish)
      {
         double oldHigh = rates[center + 1].high;
         double newLow  = rates[center - 1].low;
         if(oldHigh < newLow && (newLow - oldHigh) >= (m_minGapPoints * m_pointSize))
         {
            zone.valid      = true;
            zone.bullish    = true;
            zone.timeframe  = m_timeframe;
            zone.sourceShift= center;
            zone.formedTime = formedTime;
            zone.low        = oldHigh;
            zone.high       = newLow;
            zone.state      = ICT_FVG_ACTIVE;
            FinalizeZone(zone);
            return true;
         }
      }
      else
      {
         double oldLow  = rates[center + 1].low;
         double newHigh = rates[center - 1].high;
         if(oldLow > newHigh && (oldLow - newHigh) >= (m_minGapPoints * m_pointSize))
         {
            zone.valid      = true;
            zone.bullish    = false;
            zone.timeframe  = m_timeframe;
            zone.sourceShift= center;
            zone.formedTime = formedTime;
            zone.low        = newHigh;
            zone.high       = oldLow;
            zone.state      = ICT_FVG_ACTIVE;
            FinalizeZone(zone);
            return true;
         }
      }
   }

   return false;
}

bool CICTFVGEngine::RefreshZoneState(ICTFVGZone &zone, const int barsToCheck) const
{
   if(!zone.valid)
      return false;

   MqlRates rates[];
   if(!LoadRates(MathMax(barsToCheck, zone.sourceShift + 10), rates))
      return false;

   zone.state = ICT_FVG_ACTIVE;
   for(int shift = zone.sourceShift - 1; shift >= 1; shift--)
   {
      if(zone.bullish)
      {
         if(rates[shift].low <= zone.low)
         {
            zone.state = ICT_FVG_FILLED;
            return true;
         }
         if(rates[shift].low < zone.high)
            zone.state = ICT_FVG_PARTIAL_FILL;
      }
      else
      {
         if(rates[shift].high >= zone.high)
         {
            zone.state = ICT_FVG_FILLED;
            return true;
         }
         if(rates[shift].high > zone.low)
            zone.state = ICT_FVG_PARTIAL_FILL;
      }
   }

   return true;
}

bool CICTFVGEngine::DetectInverseFVG(const ICTFVGZone &zone, ICTFVGZone &inverseZone) const
{
   ZeroMemory(inverseZone);
   if(!zone.valid || zone.state != ICT_FVG_FILLED)
      return false;

   double closePrice = iClose(m_symbol, m_timeframe, 1);
   if(closePrice <= 0.0)
      return false;

   inverseZone = zone;
   inverseZone.valid = true;
   if(zone.bullish && closePrice < zone.low)
   {
      inverseZone.bullish = false;
      inverseZone.state   = ICT_FVG_INVERSE;
      return true;
   }
   if(!zone.bullish && closePrice > zone.high)
   {
      inverseZone.bullish = true;
      inverseZone.state   = ICT_FVG_INVERSE;
      return true;
   }

   return false;
}

bool CICTFVGEngine::FindLatestBPR(const int lookbackBars, ICTBPRZone &bpr) const
{
   ZeroMemory(bpr);
   bpr.valid = false;

   ICTFVGZone bullishZone;
   ICTFVGZone bearishZone;
   if(!FindLatestFVG(true, lookbackBars, bullishZone))
      return false;
   if(!FindLatestFVG(false, lookbackBars, bearishZone))
      return false;

   double overlapLow  = MathMax(bullishZone.low, bearishZone.low);
   double overlapHigh = MathMin(bullishZone.high, bearishZone.high);
   if(overlapHigh <= overlapLow)
      return false;

   bpr.valid          = true;
   bpr.timeframe      = m_timeframe;
   bpr.low            = overlapLow;
   bpr.high           = overlapHigh;
   bpr.midpoint       = (overlapLow + overlapHigh) * 0.5;
   bpr.bullishFVGTime = bullishZone.formedTime;
   bpr.bearishFVGTime = bearishZone.formedTime;
   return true;
}

#endif // __ICT_FVG_MQH__
