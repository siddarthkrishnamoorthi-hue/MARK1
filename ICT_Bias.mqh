//+------------------------------------------------------------------+
//| ICT_Bias.mqh                                                     |
//| Daily bias, HTF consensus, PO3 phase, and premium/discount       |
//+------------------------------------------------------------------+
#ifndef __ICT_BIAS_MQH__
#define __ICT_BIAS_MQH__

#include "ICT_Structure.mqh"
#include "ICT_Session.mqh"

enum ENUM_ICT_SESSION_BIAS
{
   ICT_SESSION_BIAS_NEUTRAL = 0,
   ICT_SESSION_BIAS_LONG_ONLY,
   ICT_SESSION_BIAS_SHORT_ONLY
};

enum ENUM_ICT_PDA_ZONE
{
   ICT_PDA_UNKNOWN = 0,
   ICT_PDA_PREMIUM,
   ICT_PDA_DISCOUNT,
   ICT_PDA_EQUILIBRIUM
};

struct ICTBiasSnapshot
{
   bool                  valid;
   datetime              time;
   string                symbol;
   ENUM_ICT_SESSION_BIAS dailyBias;
   ENUM_ICT_SESSION_BIAS trendBias;
   ENUM_ICT_SESSION_BIAS directionBias;
   ENUM_ICT_SESSION_BIAS consensusBias;
   ENUM_ICT_PDA_ZONE     pdaZone;
   double                rangeHigh;
   double                rangeLow;
   double                equilibrium;
   bool                  longAllowed;
   bool                  shortAllowed;
   bool                  po3Accumulation;
   bool                  po3Manipulation;
   bool                  po3Distribution;
};

string ICTSessionBiasToString(const ENUM_ICT_SESSION_BIAS value)
{
   switch(value)
   {
      case ICT_SESSION_BIAS_LONG_ONLY:  return "LONG_ONLY";
      case ICT_SESSION_BIAS_SHORT_ONLY: return "SHORT_ONLY";
      default:                          return "NEUTRAL";
   }
}

string ICTPDAZoneToString(const ENUM_ICT_PDA_ZONE value)
{
   switch(value)
   {
      case ICT_PDA_PREMIUM:     return "PREMIUM";
      case ICT_PDA_DISCOUNT:    return "DISCOUNT";
      case ICT_PDA_EQUILIBRIUM: return "EQUILIBRIUM";
      default:                  return "UNKNOWN";
   }
}

class CICTBiasEngine
{
private:
   string               m_symbol;
   int                  m_swingStrength;
   int                  m_pdaLookbackBars;
   ENUM_TIMEFRAMES      m_biasTimeframe;
   ENUM_TIMEFRAMES      m_trendTimeframe;
   ENUM_TIMEFRAMES      m_directionTimeframe;
   CICTStructureEngine  m_biasStructure;
   CICTStructureEngine  m_trendStructure;
   CICTStructureEngine  m_directionStructure;
   ICTBiasSnapshot      m_snapshot;

   ENUM_ICT_SESSION_BIAS ResolveFromStructure(const ICTStructureSnapshot &snapshot) const;
   ENUM_ICT_SESSION_BIAS ResolveDailyBias() const;
   ENUM_ICT_PDA_ZONE ResolvePDAZone(const double price,
                                    double &rangeHigh,
                                    double &rangeLow,
                                    double &equilibrium) const;

public:
   CICTBiasEngine();

   void Configure(const string symbol,
                  const int swingStrength = 3,
                  const int pdaLookbackBars = 80,
                  const ENUM_TIMEFRAMES biasTimeframe = PERIOD_D1,
                  const ENUM_TIMEFRAMES trendTimeframe = PERIOD_H4,
                  const ENUM_TIMEFRAMES directionTimeframe = PERIOD_H1);
   bool Refresh(const ICTSessionSnapshot &session);
   ICTBiasSnapshot Snapshot() const;
   bool AllowsTrade(const bool bullish) const;
};

CICTBiasEngine::CICTBiasEngine()
{
   m_symbol             = _Symbol;
   m_swingStrength      = 3;
   m_pdaLookbackBars    = 80;
   m_biasTimeframe      = PERIOD_D1;
   m_trendTimeframe     = PERIOD_H4;
   m_directionTimeframe = PERIOD_H1;
   ZeroMemory(m_snapshot);
}

void CICTBiasEngine::Configure(const string symbol,
                               const int swingStrength = 3,
                               const int pdaLookbackBars = 80,
                               const ENUM_TIMEFRAMES biasTimeframe = PERIOD_D1,
                               const ENUM_TIMEFRAMES trendTimeframe = PERIOD_H4,
                               const ENUM_TIMEFRAMES directionTimeframe = PERIOD_H1)
{
   m_symbol             = symbol;
   m_swingStrength      = MathMax(swingStrength, 2);
   m_pdaLookbackBars    = MathMax(pdaLookbackBars, 20);
   m_biasTimeframe      = biasTimeframe;
   m_trendTimeframe     = trendTimeframe;
   m_directionTimeframe = directionTimeframe;

   m_biasStructure.Configure(m_symbol, m_biasTimeframe, m_swingStrength);
   m_trendStructure.Configure(m_symbol, m_trendTimeframe, m_swingStrength);
   m_directionStructure.Configure(m_symbol, m_directionTimeframe, m_swingStrength);
}

ENUM_ICT_SESSION_BIAS CICTBiasEngine::ResolveFromStructure(const ICTStructureSnapshot &snapshot) const
{
   if(!snapshot.valid)
      return ICT_SESSION_BIAS_NEUTRAL;

   if(snapshot.bias == ICT_BIAS_BULLISH)
      return ICT_SESSION_BIAS_LONG_ONLY;
   if(snapshot.bias == ICT_BIAS_BEARISH)
      return ICT_SESSION_BIAS_SHORT_ONLY;
   return ICT_SESSION_BIAS_NEUTRAL;
}

ENUM_ICT_SESSION_BIAS CICTBiasEngine::ResolveDailyBias() const
{
   if(Bars(m_symbol, PERIOD_D1) < 3)
      return ICT_SESSION_BIAS_NEUTRAL;

   double priorClose = iClose(m_symbol, PERIOD_D1, 1);
   double prevHigh   = iHigh(m_symbol, PERIOD_D1, 2);
   double prevLow    = iLow(m_symbol, PERIOD_D1, 2);
   double epsilon    = SymbolInfoDouble(m_symbol, SYMBOL_POINT) * 2.0;

   if(priorClose > prevHigh + epsilon)
      return ICT_SESSION_BIAS_LONG_ONLY;
   if(priorClose < prevLow - epsilon)
      return ICT_SESSION_BIAS_SHORT_ONLY;

   ICTStructureSnapshot snapshot;
   ZeroMemory(snapshot);
   if(m_biasStructure.BuildSnapshot(snapshot))
      return ResolveFromStructure(snapshot);

   return ICT_SESSION_BIAS_NEUTRAL;
}

ENUM_ICT_PDA_ZONE CICTBiasEngine::ResolvePDAZone(const double price,
                                                 double &rangeHigh,
                                                 double &rangeLow,
                                                 double &equilibrium) const
{
   rangeHigh   = 0.0;
   rangeLow    = 0.0;
   equilibrium = 0.0;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(m_symbol, PERIOD_H4, 0, m_pdaLookbackBars, rates);
   if(copied < 10)
   {
      rangeHigh   = iHigh(m_symbol, PERIOD_D1, 1);
      rangeLow    = iLow(m_symbol, PERIOD_D1, 1);
      equilibrium = (rangeHigh + rangeLow) * 0.5;
   }
   else
   {
      rangeHigh = rates[1].high;
      rangeLow  = rates[1].low;
      for(int i = 1; i < copied; i++)
      {
         rangeHigh = MathMax(rangeHigh, rates[i].high);
         rangeLow  = MathMin(rangeLow, rates[i].low);
      }
      equilibrium = (rangeHigh + rangeLow) * 0.5;
   }

   if(rangeHigh <= rangeLow || price <= 0.0)
      return ICT_PDA_UNKNOWN;

   double zoneTolerance = (rangeHigh - rangeLow) * 0.02;
   if(MathAbs(price - equilibrium) <= zoneTolerance)
      return ICT_PDA_EQUILIBRIUM;
   if(price > equilibrium)
      return ICT_PDA_PREMIUM;
   return ICT_PDA_DISCOUNT;
}

bool CICTBiasEngine::Refresh(const ICTSessionSnapshot &session)
{
   ZeroMemory(m_snapshot);
   m_snapshot.valid  = true;
   m_snapshot.time   = session.gmtTime;
   m_snapshot.symbol = m_symbol;

   m_biasStructure.Refresh(300);
   m_trendStructure.Refresh(300);
   m_directionStructure.Refresh(300);

   ICTStructureSnapshot trendSnapshot;
   ICTStructureSnapshot directionSnapshot;
   ZeroMemory(trendSnapshot);
   ZeroMemory(directionSnapshot);
   m_trendStructure.BuildSnapshot(trendSnapshot);
   m_directionStructure.BuildSnapshot(directionSnapshot);

   m_snapshot.dailyBias     = ResolveDailyBias();
   m_snapshot.trendBias     = ResolveFromStructure(trendSnapshot);
   m_snapshot.directionBias = ResolveFromStructure(directionSnapshot);

   if(m_snapshot.dailyBias != ICT_SESSION_BIAS_NEUTRAL &&
      m_snapshot.dailyBias == m_snapshot.trendBias)
   {
      m_snapshot.consensusBias = m_snapshot.dailyBias;
   }
   else
   {
      m_snapshot.consensusBias = ICT_SESSION_BIAS_NEUTRAL;
   }

   double bidPrice = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   m_snapshot.pdaZone = ResolvePDAZone(bidPrice,
                                       m_snapshot.rangeHigh,
                                       m_snapshot.rangeLow,
                                       m_snapshot.equilibrium);

   m_snapshot.po3Accumulation = session.inAsian;
   m_snapshot.po3Manipulation = (session.inLondonKillzone || session.inLondonSilverBullet);
   m_snapshot.po3Distribution = (session.inNYAMKillzone || session.inNYSilverBulletAM || session.inNYSilverBulletPM);

   m_snapshot.longAllowed  = (m_snapshot.consensusBias == ICT_SESSION_BIAS_LONG_ONLY &&
                              (m_snapshot.pdaZone == ICT_PDA_DISCOUNT || m_snapshot.pdaZone == ICT_PDA_EQUILIBRIUM));
   m_snapshot.shortAllowed = (m_snapshot.consensusBias == ICT_SESSION_BIAS_SHORT_ONLY &&
                              (m_snapshot.pdaZone == ICT_PDA_PREMIUM || m_snapshot.pdaZone == ICT_PDA_EQUILIBRIUM));

   return true;
}

ICTBiasSnapshot CICTBiasEngine::Snapshot() const
{
   return m_snapshot;
}

bool CICTBiasEngine::AllowsTrade(const bool bullish) const
{
   return bullish ? m_snapshot.longAllowed : m_snapshot.shortAllowed;
}

#endif // __ICT_BIAS_MQH__
