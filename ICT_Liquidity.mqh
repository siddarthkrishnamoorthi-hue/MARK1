//+------------------------------------------------------------------+
//| ICT_Liquidity.mqh                                                |
//| Liquidity pool mapping and sweep detection                       |
//+------------------------------------------------------------------+
#ifndef __ICT_LIQUIDITY_MQH__
#define __ICT_LIQUIDITY_MQH__

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

#endif // __ICT_LIQUIDITY_MQH__
