//+------------------------------------------------------------------+
//| ICT_IPDA.mqh                                                      |
//| MARK1 ICT Expert Advisor — Interbank Price Delivery Algorithm    |
//| Copyright 2024-2025, MARK1 Project                               |
//+------------------------------------------------------------------+
#pragma once
#ifndef __ICT_IPDA_MQH__
#define __ICT_IPDA_MQH__

#include "ICT_Constants.mqh"

/// IPDA lookback ranges per ICT specification (D1 bars).
#define IPDA_20_BAR    20   ///< Short-term IPDA range
#define IPDA_40_BAR    40   ///< Medium-term IPDA range
#define IPDA_60_BAR    60   ///< Long-term IPDA range

/// @brief Snapshot of all three IPDA range levels.
struct SIPDARange
{
   double   high20;          ///< Highest high in last 20 D1 bars
   double   low20;           ///< Lowest low in last 20 D1 bars
   double   high40;
   double   low40;
   double   high60;
   double   low60;
   double   equilibrium20;   ///< 50% of 20-bar IPDA range
   double   equilibrium40;
   double   equilibrium60;
   datetime computedAt;
};

/// @brief Engine that computes IPDA 20/40/60 bar levels on D1.
class CIPDAEngine
{
private:
   SIPDARange  m_range;
   string      m_symbol;

public:
   CIPDAEngine() { m_symbol = _Symbol; ZeroMemory(m_range); }

   /// @brief Set the symbol to compute IPDA for.
   void SetSymbol(const string symbol) { m_symbol = symbol; }

   /// @brief Computes all three IPDA ranges using D1 bars.
   void Compute()
   {
      int h20 = (int)iHighest(m_symbol, PERIOD_D1, MODE_HIGH, IPDA_20_BAR, 1);
      int l20 = (int)iLowest (m_symbol, PERIOD_D1, MODE_LOW,  IPDA_20_BAR, 1);
      int h40 = (int)iHighest(m_symbol, PERIOD_D1, MODE_HIGH, IPDA_40_BAR, 1);
      int l40 = (int)iLowest (m_symbol, PERIOD_D1, MODE_LOW,  IPDA_40_BAR, 1);
      int h60 = (int)iHighest(m_symbol, PERIOD_D1, MODE_HIGH, IPDA_60_BAR, 1);
      int l60 = (int)iLowest (m_symbol, PERIOD_D1, MODE_LOW,  IPDA_60_BAR, 1);

      if(h20 < 0 || l20 < 0 || h40 < 0 || l40 < 0 || h60 < 0 || l60 < 0)
      {
         ZeroMemory(m_range);
         return;
      }

      m_range.high20 = iHigh(m_symbol, PERIOD_D1, h20);
      m_range.low20  = iLow (m_symbol, PERIOD_D1, l20);
      m_range.high40 = iHigh(m_symbol, PERIOD_D1, h40);
      m_range.low40  = iLow (m_symbol, PERIOD_D1, l40);
      m_range.high60 = iHigh(m_symbol, PERIOD_D1, h60);
      m_range.low60  = iLow (m_symbol, PERIOD_D1, l60);

      m_range.equilibrium20 = (m_range.high20 + m_range.low20) / 2.0;
      m_range.equilibrium40 = (m_range.high40 + m_range.low40) / 2.0;
      m_range.equilibrium60 = (m_range.high60 + m_range.low60) / 2.0;
      m_range.computedAt    = TimeGMT();
   }

   /// @brief Returns a copy of the current IPDA range snapshot.
   SIPDARange GetRange() const { return m_range; }

   /// @brief Returns true if price is within tolerancePips of the IPDA equilibrium.
   /// @param price          Price to test
   /// @param tolerancePips  Tolerance in pips
   /// @param barRange       20, 40, or 60 (selects which equilibrium)
   bool IsAtEquilibrium(const double price,
                        const double tolerancePips,
                        const int    barRange = 20) const
   {
      double pointSize = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      int digits       = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double pipSize   = ((digits == 3 || digits == 5) ? pointSize * 10.0 : pointSize);

      double eq = (barRange == 20) ? m_range.equilibrium20 :
                  (barRange == 40) ? m_range.equilibrium40 :
                                     m_range.equilibrium60;
      return (MathAbs(price - eq) <= tolerancePips * pipSize);
   }
};

#endif // __ICT_IPDA_MQH__
