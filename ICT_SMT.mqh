//+------------------------------------------------------------------+
//| ICT_SMT.mqh                                                       |
//| MARK1 ICT Expert Advisor — Smart Money Technique divergence      |
//| Copyright 2024-2025, MARK1 Project                               |
//+------------------------------------------------------------------+
#pragma once
#ifndef __ICT_SMT_MQH__
#define __ICT_SMT_MQH__

#include "ICT_Constants.mqh"

/// @brief Primary SMT correlation pair for EURUSD.
#define SMT_CORRELATED_SYMBOL  "GBPUSD"

/// @brief SMT divergence detection result.
struct SSMTDivergence
{
   bool     detected;
   bool     isBullishSMT;      ///< EURUSD makes lower low but GBPUSD does NOT
   bool     isBearishSMT;      ///< EURUSD makes higher high but GBPUSD does NOT
   double   eurSwingLevel;     ///< The new swing high/low on EURUSD
   double   gbpSwingLevel;     ///< Corresponding swing level on GBPUSD
   datetime detectedAt;
   int      confirmationBars;  ///< Bars since divergence formed (staleness)
};

/// @brief Engine that scans for SMT divergence between EURUSD and GBPUSD.
class CSMTEngine
{
private:
   SSMTDivergence m_divergence;
   string         m_primarySymbol;
   string         m_correlatedSymbol;

public:
   CSMTEngine()
   {
      m_primarySymbol    = _Symbol;
      m_correlatedSymbol = SMT_CORRELATED_SYMBOL;
      ZeroMemory(m_divergence);
   }

   /// @brief Override the correlated symbol (default GBPUSD).
   void SetCorrelatedSymbol(const string sym) { m_correlatedSymbol = sym; }

   /// @brief Scans for SMT divergence on the specified timeframe.
   /// @param tf       Timeframe to use (H1 recommended)
   /// @param lookback Number of bars per comparison window
   /// @return True if a divergence is currently detected
   bool Scan(const ENUM_TIMEFRAMES tf, const int lookback = 10)
   {
      ZeroMemory(m_divergence);

      // --- Bullish SMT: EUR makes lower low, GBP does NOT ---
      int eurLowShift  = (int)iLowest(m_primarySymbol,    tf, MODE_LOW,  lookback, 1);
      int gbpLowShift  = (int)iLowest(m_correlatedSymbol, tf, MODE_LOW,  lookback, 1);
      int eurPrevLShft = (int)iLowest(m_primarySymbol,    tf, MODE_LOW,  lookback, lookback + 1);
      int gbpPrevLShft = (int)iLowest(m_correlatedSymbol, tf, MODE_LOW,  lookback, lookback + 1);

      if(eurLowShift >= 0 && gbpLowShift >= 0 && eurPrevLShft >= 0 && gbpPrevLShft >= 0)
      {
         double eurLow      = iLow(m_primarySymbol,    tf, eurLowShift);
         double gbpLow      = iLow(m_correlatedSymbol, tf, gbpLowShift);
         double eurPrevLow  = iLow(m_primarySymbol,    tf, eurPrevLShft);
         double gbpPrevLow  = iLow(m_correlatedSymbol, tf, gbpPrevLShft);

         if(eurLow < eurPrevLow && gbpLow > gbpPrevLow)
         {
            m_divergence.detected       = true;
            m_divergence.isBullishSMT   = true;
            m_divergence.eurSwingLevel  = eurLow;
            m_divergence.gbpSwingLevel  = gbpLow;
            m_divergence.detectedAt     = TimeGMT();
            m_divergence.confirmationBars = 0;
            return true;
         }
      }

      // --- Bearish SMT: EUR makes higher high, GBP does NOT ---
      int eurHighShift  = (int)iHighest(m_primarySymbol,    tf, MODE_HIGH, lookback, 1);
      int gbpHighShift  = (int)iHighest(m_correlatedSymbol, tf, MODE_HIGH, lookback, 1);
      int eurPrevHShift = (int)iHighest(m_primarySymbol,    tf, MODE_HIGH, lookback, lookback + 1);
      int gbpPrevHShift = (int)iHighest(m_correlatedSymbol, tf, MODE_HIGH, lookback, lookback + 1);

      if(eurHighShift >= 0 && gbpHighShift >= 0 && eurPrevHShift >= 0 && gbpPrevHShift >= 0)
      {
         double eurHigh     = iHigh(m_primarySymbol,    tf, eurHighShift);
         double gbpHigh     = iHigh(m_correlatedSymbol, tf, gbpHighShift);
         double eurPrevHigh = iHigh(m_primarySymbol,    tf, eurPrevHShift);
         double gbpPrevHigh = iHigh(m_correlatedSymbol, tf, gbpPrevHShift);

         if((eurHigh > eurPrevHigh) && (gbpHigh < gbpPrevHigh))
         {
            m_divergence.detected       = true;
            m_divergence.isBullishSMT   = false;
            m_divergence.isBearishSMT   = true;
            m_divergence.eurSwingLevel  = eurHigh;
            m_divergence.gbpSwingLevel  = gbpHigh;
            m_divergence.detectedAt     = TimeGMT();
            m_divergence.confirmationBars = 0;
            return true;
         }
      }

      return false;
   }

   /// @brief Returns a copy of the most recent divergence result.
   SSMTDivergence GetDivergence() const { return m_divergence; }
};

#endif // __ICT_SMT_MQH__
