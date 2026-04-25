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
   CICTStructureEngine  m_weeklyStructure;   ///< Fix #6: W1 structure for weekly bias
   CICTStructureEngine  m_monthlyStructure;  ///< Fix #6: MN1 structure for monthly bias
   datetime             m_lastD1BarTime;     ///< Bar-change gate: avoid tick-spam CopyRates on D1
   datetime             m_lastH4BarTime;     ///< Bar-change gate: avoid tick-spam CopyRates on H4
   datetime             m_lastH1BarTime;     ///< Bar-change gate: avoid tick-spam CopyRates on H1
   datetime             m_lastW1BarTime;     ///< Bar-change gate: avoid tick-spam CopyRates on W1
   datetime             m_lastMN1BarTime;    ///< Bar-change gate: avoid tick-spam CopyRates on MN1
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
   m_lastD1BarTime      = 0;
   m_lastH4BarTime      = 0;
   m_lastH1BarTime      = 0;
   m_lastW1BarTime      = 0;
   m_lastMN1BarTime     = 0;
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
   // Fix #6: W1 and MN1 use swingStrength≥2 — monthly bars are inherently slow-forming
   m_weeklyStructure.Configure(m_symbol, PERIOD_W1, MathMax(m_swingStrength, 2));
   m_monthlyStructure.Configure(m_symbol, PERIOD_MN1, MathMax(m_swingStrength, 2));
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

   // Bar-change gates: only refresh each structure when its timeframe bar changes.
   // Avoids redundant CopyRates(300) calls on every tick.
   {
      datetime d1Bar = iTime(m_symbol, m_biasTimeframe, 0);
      if(d1Bar > 0 && d1Bar != m_lastD1BarTime)
      {
         m_lastD1BarTime = d1Bar;
         m_biasStructure.Refresh(300);
      }
      datetime h4Bar = iTime(m_symbol, m_trendTimeframe, 0);
      if(h4Bar > 0 && h4Bar != m_lastH4BarTime)
      {
         m_lastH4BarTime = h4Bar;
         m_trendStructure.Refresh(300);
      }
      datetime h1Bar = iTime(m_symbol, m_directionTimeframe, 0);
      if(h1Bar > 0 && h1Bar != m_lastH1BarTime)
      {
         m_lastH1BarTime = h1Bar;
         m_directionStructure.Refresh(300);
      }
   }

   // Fix #6: W1/MN1 only refresh when a new bar forms (once/week and once/month).
   // Avoids unnecessary CopyRates overhead on every tick.
   {
      datetime w1Bar = iTime(m_symbol, PERIOD_W1, 0);
      if(w1Bar > 0 && w1Bar != m_lastW1BarTime)
      {
         m_lastW1BarTime = w1Bar;
         m_weeklyStructure.Refresh(100);
      }
      datetime mn1Bar = iTime(m_symbol, PERIOD_MN1, 0);
      if(mn1Bar > 0 && mn1Bar != m_lastMN1BarTime)
      {
         m_lastMN1BarTime = mn1Bar;
         m_monthlyStructure.Refresh(60);
      }
   }

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
                              m_snapshot.pdaZone == ICT_PDA_DISCOUNT);
   m_snapshot.shortAllowed = (m_snapshot.consensusBias == ICT_SESSION_BIAS_SHORT_ONLY &&
                              m_snapshot.pdaZone == ICT_PDA_PREMIUM);

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

/// @brief Resolves weekly bias from W1 swing structure (HH+HL=bullish, LH+LL=bearish).
/// Fix #6: replaced single W1 candle body-direction with proper ICT structural bias.
ENUM_ICT_SESSION_BIAS CICTBiasEngine::ResolveWeeklyBias() const
{
   ICTStructureSnapshot snapshot;
   ZeroMemory(snapshot);
   if(!m_weeklyStructure.BuildSnapshot(snapshot))
      return ICT_SESSION_BIAS_NEUTRAL;
   if(snapshot.bias == ICT_BIAS_RANGE)
      return ICT_SESSION_BIAS_NEUTRAL;
   return ResolveFromStructure(snapshot);
}

/// @brief Resolves monthly bias from MN1 swing structure (HH+HL=bullish, LH+LL=bearish).
/// Fix #6: replaced single MN1 candle body-direction with proper ICT structural bias.
ENUM_ICT_SESSION_BIAS CICTBiasEngine::ResolveMonthlyBias() const
{
   ICTStructureSnapshot snapshot;
   ZeroMemory(snapshot);
   if(!m_monthlyStructure.BuildSnapshot(snapshot))
      return ICT_SESSION_BIAS_NEUTRAL;
   if(snapshot.bias == ICT_BIAS_RANGE)
      return ICT_SESSION_BIAS_NEUTRAL;
   return ResolveFromStructure(snapshot);
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
