//+------------------------------------------------------------------+
//| ICT_Bias.mqh                                                      |
//| MARK1 ICT Expert Advisor — Daily bias, HTF consensus, DOW phase  |
//| Copyright 2024-2025, MARK1 Project                               |
//+------------------------------------------------------------------+
#pragma once
#ifndef __ICT_BIAS_MQH__
#define __ICT_BIAS_MQH__

#include "ICT_Constants.mqh"
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

/// @brief ICT Day-of-Week phase for trade quality gating.
enum ENUM_DOW_PHASE
{
   DOW_MONDAY,     ///< Accumulation — wait for direction
   DOW_TUESDAY,    ///< Optimal — trend continuation setups
   DOW_WEDNESDAY,  ///< Optimal — highest probability continuation
   DOW_THURSDAY,   ///< Distribution — tighten targets
   DOW_FRIDAY,     ///< Reversal risk — TGIF potential, reduce risk
   DOW_WEEKEND     ///< No trading
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
   ENUM_ICT_SESSION_BIAS weeklyBias;    ///< Phase 2: W1 directional bias
   ENUM_ICT_SESSION_BIAS monthlyBias;   ///< Phase 2: MN1 directional bias
   ENUM_ICT_PDA_ZONE     pdaZone;
   ENUM_DOW_PHASE        currentDOWPhase; ///< Phase 4: ICT day-of-week phase
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
   ENUM_ICT_SESSION_BIAS ResolveWeeklyBias() const;
   ENUM_ICT_SESSION_BIAS ResolveMonthlyBias() const;
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

   // BUG FIX: 3-TF consensus (Daily + H4 + H1 — previously only Daily + H4)
   {
      int bullVotes = 0, bearVotes = 0;
      if(m_snapshot.dailyBias     == ICT_SESSION_BIAS_LONG_ONLY)  bullVotes++;
      else if(m_snapshot.dailyBias  == ICT_SESSION_BIAS_SHORT_ONLY) bearVotes++;
      if(m_snapshot.trendBias     == ICT_SESSION_BIAS_LONG_ONLY)  bullVotes++;
      else if(m_snapshot.trendBias  == ICT_SESSION_BIAS_SHORT_ONLY) bearVotes++;
      if(m_snapshot.directionBias == ICT_SESSION_BIAS_LONG_ONLY)  bullVotes++;
      else if(m_snapshot.directionBias == ICT_SESSION_BIAS_SHORT_ONLY) bearVotes++;

      if(bullVotes >= 2)      m_snapshot.consensusBias = ICT_SESSION_BIAS_LONG_ONLY;
      else if(bearVotes >= 2) m_snapshot.consensusBias = ICT_SESSION_BIAS_SHORT_ONLY;
      else                    m_snapshot.consensusBias = ICT_SESSION_BIAS_NEUTRAL;
   }

   // Phase 2: weekly and monthly bias (informational — gating in Phase 5)
   m_snapshot.weeklyBias  = ResolveWeeklyBias();
   m_snapshot.monthlyBias = ResolveMonthlyBias();

   // Phase 4: DOW phase
   m_snapshot.currentDOWPhase = GetDOWPhase(session.gmtTime);

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

/// @brief Resolves weekly directional bias from PERIOD_W1 structure.
ENUM_ICT_SESSION_BIAS CICTBiasEngine::ResolveWeeklyBias() const
{
   double wClose = iClose(m_symbol, PERIOD_W1, 1);
   double wOpen  = iOpen (m_symbol, PERIOD_W1, 1);
   if(wClose <= 0.0 || wOpen <= 0.0) return ICT_SESSION_BIAS_NEUTRAL;
   return (wClose > wOpen) ? ICT_SESSION_BIAS_LONG_ONLY : ICT_SESSION_BIAS_SHORT_ONLY;
}

/// @brief Resolves monthly directional bias from PERIOD_MN1 structure.
ENUM_ICT_SESSION_BIAS CICTBiasEngine::ResolveMonthlyBias() const
{
   double mClose = iClose(m_symbol, PERIOD_MN1, 1);
   double mOpen  = iOpen (m_symbol, PERIOD_MN1, 1);
   if(mClose <= 0.0 || mOpen <= 0.0) return ICT_SESSION_BIAS_NEUTRAL;
   return (mClose > mOpen) ? ICT_SESSION_BIAS_LONG_ONLY : ICT_SESSION_BIAS_SHORT_ONLY;
}

/// @brief Returns the ICT-mapped DOW phase for a given GMT timestamp.
ENUM_DOW_PHASE GetDOWPhase(const datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);
   switch(dt.day_of_week)
   {
      case 1: return DOW_MONDAY;
      case 2: return DOW_TUESDAY;
      case 3: return DOW_WEDNESDAY;
      case 4: return DOW_THURSDAY;
      case 5: return DOW_FRIDAY;
      default: return DOW_WEEKEND;
   }
}

#endif // __ICT_BIAS_MQH__
