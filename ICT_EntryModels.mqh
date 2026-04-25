//+------------------------------------------------------------------+
//| ICT_EntryModels.mqh                                               |
//| MARK1 ICT Expert Advisor — All 6 ICT entry model classes         |
//| Copyright 2024-2025, MARK1 Project                               |
//+------------------------------------------------------------------+
#pragma once
#ifndef __ICT_ENTRYMODELS_MQH__
#define __ICT_ENTRYMODELS_MQH__

#include "ICT_Constants.mqh"
#include "ICT_Structure.mqh"
#include "ICT_Session.mqh"
#include "ICT_Liquidity.mqh"
#include "ICT_FVG.mqh"
#include "ICT_OrderBlock.mqh"
#include "ICT_Bias.mqh"

// ============================================================
// Market context passed to all entry models
// ============================================================

/// @brief Complete market context consumed by every entry model each tick.
struct SMarketContext
{
   ICTSessionSnapshot  session;
   ICTBiasSnapshot     bias;
   double              h4RangeHigh;  ///< For IRL/ERL gate
   double              h4RangeLow;
   double              entryPrice;   ///< Used for IRL/ERL gate computation
};

/// @brief Standardised trade setup produced by an entry model.
struct STradeSetup
{
   bool     valid;
   bool     bullish;
   double   entry;
   double   stopLoss;
   double   tp1;
   double   tp2;
   double   tp3;
   string   modelName;
   bool     idmSwept;   ///< IDM gate passed
};

// ============================================================
// Base interface for all entry models
// ============================================================

/// @brief Abstract base class. All entry models inherit from this.
class CEntryModel
{
public:
   virtual bool       Scan(SMarketContext &ctx) = 0;  ///< Returns true if setup is valid
   virtual STradeSetup GetSetup()               = 0;  ///< Returns the confirmed setup
   virtual string     Name()                    = 0;  ///< Model name for logging/CSV
};

// ============================================================
// Phase 5, Item 1 — Silver Bullet
// ============================================================

/// @brief Silver Bullet entry model (FVG inside Silver Bullet windows).
class CSilverBulletModel : public CEntryModel
{
private:
   STradeSetup m_setup;
   string      m_symbol;

public:
   CSilverBulletModel() { m_symbol = _Symbol; ZeroMemory(m_setup); }
   void SetSymbol(const string s) { m_symbol = s; }

   virtual string Name() { return "SilverBullet"; }

   virtual bool Scan(SMarketContext &ctx)
   {
      ZeroMemory(m_setup);
      m_setup.modelName = Name();

      // Gate 1: must be in a Silver Bullet window
      bool inSBWindow = (ctx.session.inLondonSilverBullet ||
                         ctx.session.inNYSilverBulletAM   ||
                         ctx.session.inNYSilverBulletPM);
      if(!inSBWindow) return false;

      // Gate 2: HTF consensus must be established
      if(ctx.bias.consensusBias == ICT_SESSION_BIAS_NEUTRAL) return false;

      bool bullish = (ctx.bias.consensusBias == ICT_SESSION_BIAS_LONG_ONLY);

      // Gate 3: IDM sweep (Phase 5, Item 7)
      SInducementLevel idm;
      if(!FindInducement(m_symbol, PERIOD_M5, bullish ? 1 : -1, 20, idm))
      {
         Print("[MARK1][GATE][SB] IDM not found -- setup rejected");
         return false;
      }
      if(!idm.isSwept)
      {
         Print("[MARK1][GATE][SB] IDM not yet swept -- setup rejected");
         return false;
      }
      m_setup.idmSwept = true;

      // Gate 4: IRL->ERL check (Phase 5, Item 8)
      SDOLTarget dolTarget = SelectDOLTarget(m_symbol, bullish, ctx.entryPrice);
      ENUM_LIQUIDITY_TYPE entryZone  = ClassifyLiquidityType(ctx.entryPrice,
                                                              ctx.h4RangeHigh,
                                                              ctx.h4RangeLow);
      ENUM_LIQUIDITY_TYPE targetZone = ClassifyLiquidityType(dolTarget.price,
                                                              ctx.h4RangeHigh,
                                                              ctx.h4RangeLow);
      if(entryZone == LIQ_IRL && targetZone == LIQ_IRL)
      {
         Print("[MARK1][GATE][SB] IRL->IRL trade rejected -- no liquidity draw");
         return false;
      }

      // Find FVG on M1 or M5 after sweep
      ICTFVGZone fvg;
      ZeroMemory(fvg);
      CICTFVGEngine fvgEngine;
      fvgEngine.Configure(m_symbol, PERIOD_M5, 5.0);
      if(!fvgEngine.FindLatestFVG(bullish, 30, fvg))
         return false;

      double pipSize = SymbolInfoDouble(m_symbol, SYMBOL_POINT)
                       * (double)MARK1_PIP_FACTOR;
      double riskDist = MathAbs(m_setup.entry - m_setup.stopLoss);

      m_setup.valid    = true;
      m_setup.bullish  = bullish;
      m_setup.entry    = fvg.consequentEncroachment;
      m_setup.stopLoss = bullish ? fvg.low  - pipSize * 5.0
                                 : fvg.high + pipSize * 5.0;
      riskDist         = MathAbs(m_setup.entry - m_setup.stopLoss);
      m_setup.tp1      = bullish ? m_setup.entry + riskDist
                                 : m_setup.entry - riskDist;
      m_setup.tp2      = bullish ? m_setup.entry + riskDist * 2.0
                                 : m_setup.entry - riskDist * 2.0;
      m_setup.tp3      = (dolTarget.type != DOL_NONE) ? dolTarget.price : m_setup.tp2;

      Print("[MARK1][SB] Silver Bullet setup: ",
            bullish ? "LONG" : "SHORT",
            " entry=", m_setup.entry,
            " SL=", m_setup.stopLoss,
            " TP3=", m_setup.tp3);
      return true;
   }

   virtual STradeSetup GetSetup() { return m_setup; }
};

// ============================================================
// Phase 5, Item 2 — Judas Swing Entry Model
// ============================================================

/// @brief Judas Swing entry model (PO3 confirmed Judas reversal).
class CJudasSwingModel : public CEntryModel
{
private:
   STradeSetup m_setup;
   string      m_symbol;

public:
   CJudasSwingModel() { m_symbol = _Symbol; ZeroMemory(m_setup); }
   void SetSymbol(const string s) { m_symbol = s; }

   virtual string Name() { return "JudasSwing"; }

   virtual bool Scan(SMarketContext &ctx)
   {
      ZeroMemory(m_setup);
      m_setup.modelName = Name();

      // Require confirmed Judas Swing from Phase 4 SM
      if(!ctx.session.judasSM.confirmed) return false;
      if(ctx.session.judasSM.currentPhase != PO3_DISTRIBUTION) return false;

      bool bullish = ctx.session.judasSM.isBullishJudas;

      // IDM gate
      SInducementLevel idm;
      if(!FindInducement(m_symbol, PERIOD_M15, bullish ? 1 : -1, 20, idm) || !idm.isSwept)
      {
         Print("[MARK1][GATE][JS] IDM not swept -- rejected");
         return false;
      }
      m_setup.idmSwept = true;

      // Gate: IRL->ERL check (Phase 5, Item 8)
      {
         SDOLTarget dolTarget = SelectDOLTarget(m_symbol, bullish, ctx.entryPrice);
         ENUM_LIQUIDITY_TYPE entryZone  = ClassifyLiquidityType(ctx.entryPrice, ctx.h4RangeHigh, ctx.h4RangeLow);
         ENUM_LIQUIDITY_TYPE targetZone = ClassifyLiquidityType(dolTarget.price,  ctx.h4RangeHigh, ctx.h4RangeLow);
         if(entryZone == LIQ_IRL && targetZone == LIQ_IRL)
         {
            Print("[MARK1][GATE][JS] IRL->IRL trade rejected -- no liquidity draw");
            return false;
         }
      }

      // Find M5/M15 FVG or OB for entry
      CICTFVGEngine fvgEngine;
      fvgEngine.Configure(m_symbol, PERIOD_M15, 5.0);
      ICTFVGZone fvg;
      ZeroMemory(fvg);
      if(!fvgEngine.FindLatestFVG(bullish, 40, fvg)) return false;

      const SJudasSwing &js = ctx.session.judasSM;
      double sweepLevel     = bullish ? js.manipulationLow : js.manipulationHigh;
      double pipSize        = SymbolInfoDouble(m_symbol, SYMBOL_POINT)
                              * (double)MARK1_PIP_FACTOR;

      m_setup.valid    = true;
      m_setup.bullish  = bullish;
      m_setup.entry    = fvg.consequentEncroachment;
      m_setup.stopLoss = bullish ? sweepLevel - pipSize * 5.0
                                 : sweepLevel + pipSize * 5.0;
      double rr1       = MathAbs(m_setup.entry - m_setup.stopLoss);
      m_setup.tp1      = bullish ? m_setup.entry + rr1    : m_setup.entry - rr1;
      m_setup.tp2      = bullish ? js.asianRangeHigh      : js.asianRangeLow;
      // Validate TP2 is on correct side of entry; fallback to 2R
      if(bullish && m_setup.tp2 <= m_setup.tp1)
         m_setup.tp2 = m_setup.entry + rr1 * 2.0;
      if(!bullish && m_setup.tp2 >= m_setup.tp1)
         m_setup.tp2 = m_setup.entry - rr1 * 2.0;
      m_setup.tp3      = SelectDOLTarget(m_symbol, bullish, m_setup.entry).price;
      if(m_setup.tp3 == 0.0) m_setup.tp3 = m_setup.tp2;

      Print("[MARK1][JS] Judas Swing setup: ",
            bullish ? "LONG" : "SHORT",
            " entry=", m_setup.entry);
      return true;
   }

   virtual STradeSetup GetSetup() { return m_setup; }
};

// ============================================================
// Phase 5, Item 3 — Market Maker Model
// ============================================================

/// @brief Market Maker 4-phase cycle entry model.
class CMarketMakerModel : public CEntryModel
{
private:
   STradeSetup m_setup;
   string      m_symbol;

public:
   CMarketMakerModel() { m_symbol = _Symbol; ZeroMemory(m_setup); }
   void SetSymbol(const string s) { m_symbol = s; }

   virtual string Name() { return "MarketMaker"; }

   virtual bool Scan(SMarketContext &ctx)
   {
      ZeroMemory(m_setup);
      m_setup.modelName = Name();
      if(ctx.bias.consensusBias == ICT_SESSION_BIAS_NEUTRAL) return false;

      bool bullish = (ctx.bias.consensusBias == ICT_SESSION_BIAS_LONG_ONLY);

      // Gate: IDM sweep (Phase 5, Item 7)
      SInducementLevel idm;
      if(!FindInducement(m_symbol, PERIOD_M15, bullish ? 1 : -1, 30, idm) || !idm.isSwept)
      {
         Print("[MARK1][GATE][MM] IDM not swept -- rejected");
         return false;
      }
      m_setup.idmSwept = true;

      // Find equal highs/lows on H1 (Accumulation phase)
      CICTLiquidityEngine liqEngine;
      liqEngine.Configure(m_symbol, PERIOD_H1, 5.0, 2.0);
      ICTLiquidityLevel equalLevel;
      bool haveEq = bullish ? liqEngine.FindEqualLows(equalLevel, 80, 2)
                             : liqEngine.FindEqualHighs(equalLevel, 80, 2);
      if(!haveEq) return false;

      // Require M15 BOS in direction after equal level was swept
      CICTStructureEngine strM15;
      strM15.Configure(m_symbol, PERIOD_M15, 3);
      strM15.Refresh(200);
      ICTStructureBreakSignal bos;
      if(!strM15.GetLatestBreakSignal(bos)) return false;
      if(!bos.valid) return false;
      if(bullish  && bos.classification != ICT_BREAK_BULLISH_BOS &&
                     bos.classification != ICT_BREAK_BULLISH_CHOCH) return false;
      if(!bullish && bos.classification != ICT_BREAK_BEARISH_BOS &&
                     bos.classification != ICT_BREAK_BEARISH_CHOCH) return false;
      if(bos.time <= equalLevel.time) return false;  // BOS must be AFTER equal level

      // Gate: IRL->ERL check (Phase 5, Item 8)
      {
         SDOLTarget dolTarget = SelectDOLTarget(m_symbol, bullish, ctx.entryPrice);
         ENUM_LIQUIDITY_TYPE entryZone  = ClassifyLiquidityType(ctx.entryPrice, ctx.h4RangeHigh, ctx.h4RangeLow);
         ENUM_LIQUIDITY_TYPE targetZone = ClassifyLiquidityType(dolTarget.price,  ctx.h4RangeHigh, ctx.h4RangeLow);
         if(entryZone == LIQ_IRL && targetZone == LIQ_IRL)
         {
            Print("[MARK1][GATE][MM] IRL->IRL trade rejected -- no liquidity draw");
            return false;
         }
      }

      // Enter on first M15 FVG in direction of BOS
      CICTFVGEngine fvgEng;
      fvgEng.Configure(m_symbol, PERIOD_M15, 5.0);
      ICTFVGZone fvg;
      ZeroMemory(fvg);
      if(!fvgEng.FindLatestFVG(bullish, 40, fvg, bos.time)) return false;

      double pipSize = SymbolInfoDouble(m_symbol, SYMBOL_POINT)
                       * (double)MARK1_PIP_FACTOR;

      m_setup.valid    = true;
      m_setup.bullish  = bullish;
      m_setup.entry    = fvg.consequentEncroachment;
      m_setup.stopLoss = bullish ? fvg.low  - pipSize * 3.0
                                 : fvg.high + pipSize * 3.0;
      double rr1       = MathAbs(m_setup.entry - m_setup.stopLoss);
      m_setup.tp1      = bullish ? m_setup.entry + rr1     : m_setup.entry - rr1;
      m_setup.tp2      = bullish ? m_setup.entry + rr1*2.0 : m_setup.entry - rr1*2.0;
      m_setup.tp3      = SelectDOLTarget(m_symbol, bullish, m_setup.entry).price;
      if(m_setup.tp3 == 0.0) m_setup.tp3 = m_setup.tp2;

      Print("[MARK1][MM] MarketMaker setup: ",
            bullish ? "LONG" : "SHORT",
            " entry=", m_setup.entry);
      return true;
   }

   virtual STradeSetup GetSetup() { return m_setup; }
};

// ============================================================
// Phase 5, Item 4 — Turtle Soup
// ============================================================

/// @brief Turtle Soup counter-trend fade of a 20-bar breakout.
class CTurtleSoupModel : public CEntryModel
{
private:
   STradeSetup m_setup;
   string      m_symbol;

public:
   CTurtleSoupModel() { m_symbol = _Symbol; ZeroMemory(m_setup); }
   void SetSymbol(const string s) { m_symbol = s; }

   virtual string Name() { return "TurtleSoup"; }

   virtual bool Scan(SMarketContext &ctx)
   {
      ZeroMemory(m_setup);
      m_setup.modelName = Name();

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(m_symbol, PERIOD_M15, 0, 30, rates);
      if(copied < 25) return false;

      double pointSize = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      int    digits    = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double pipSize   = ((digits == 3 || digits == 5) ? pointSize * 10.0 : pointSize);
      double maxBreak  = pipSize * 10.0;  // ≤ 10 pips beyond 20-bar extreme

      // Gate: IDM sweep (Phase 5, Item 7)
      {
         int guessDir = (ctx.bias.consensusBias == ICT_SESSION_BIAS_LONG_ONLY) ? -1 : 1; // fade direction
         SInducementLevel idm;
         if(!FindInducement(m_symbol, PERIOD_M15, guessDir, 20, idm) || !idm.isSwept)
         {
            Print("[MARK1][GATE][TS] IDM not swept -- rejected");
            return false;
         }
         m_setup.idmSwept = true;
      }

      // 20-bar high and low
      int h20Shift = (int)iHighest(m_symbol, PERIOD_M15, MODE_HIGH, 20, 2);
      int l20Shift = (int)iLowest (m_symbol, PERIOD_M15, MODE_LOW,  20, 2);
      double h20 = iHigh(m_symbol, PERIOD_M15, h20Shift);
      double l20 = iLow (m_symbol, PERIOD_M15, l20Shift);

      double lastHigh  = rates[1].high;
      double lastClose = rates[1].close;

      // Gate: IRL->ERL check (Phase 5, Item 8)
      // Use current price as proxy since entry is at h20/l20 (range extreme = ERL candidate)
      {
         bool bullishGuess   = (ctx.bias.consensusBias == ICT_SESSION_BIAS_LONG_ONLY);
         SDOLTarget dolTarget = SelectDOLTarget(m_symbol, !bullishGuess, ctx.entryPrice); // fade direction
         ENUM_LIQUIDITY_TYPE entryZone  = ClassifyLiquidityType(ctx.entryPrice, ctx.h4RangeHigh, ctx.h4RangeLow);
         ENUM_LIQUIDITY_TYPE targetZone = ClassifyLiquidityType(dolTarget.price,  ctx.h4RangeHigh, ctx.h4RangeLow);
         if(entryZone == LIQ_IRL && targetZone == LIQ_IRL)
         {
            Print("[MARK1][GATE][TS] IRL->IRL trade rejected -- no liquidity draw");
            return false;
         }
      }

      // Bearish Turtle Soup: price breaks above 20-bar high by ≤ 10 pips then rejection
      if(lastHigh > h20 && lastHigh - h20 <= maxBreak && lastClose < h20)
      {
         m_setup.valid    = true;
         m_setup.bullish  = false;
         m_setup.entry    = h20;
         m_setup.stopLoss = lastHigh + pipSize * 10.0;
         double riskDist  = MathAbs(m_setup.entry - m_setup.stopLoss);
         m_setup.tp1      = m_setup.entry - riskDist;
         m_setup.tp2      = m_setup.entry - riskDist * 2.0;
         SDOLTarget dol   = SelectDOLTarget(m_symbol, false, m_setup.entry);
         m_setup.tp3      = (dol.type != DOL_NONE) ? dol.price : l20;
         Print("[MARK1][TS] Bearish Turtle Soup: entry=", m_setup.entry);
         return true;
      }

      double lastLow = rates[1].low;
      // Bullish Turtle Soup: price breaks below 20-bar low by ≤ 10 pips then rejection
      if(lastLow < l20 && l20 - lastLow <= maxBreak && lastClose > l20)
      {
         m_setup.valid    = true;
         m_setup.bullish  = true;
         m_setup.entry    = l20;
         m_setup.stopLoss = lastLow - pipSize * 10.0;
         double riskDist  = MathAbs(m_setup.entry - m_setup.stopLoss);
         m_setup.tp1      = m_setup.entry + riskDist;
         m_setup.tp2      = m_setup.entry + riskDist * 2.0;
         SDOLTarget dol   = SelectDOLTarget(m_symbol, true, m_setup.entry);
         m_setup.tp3      = (dol.type != DOL_NONE) ? dol.price : h20;
         Print("[MARK1][TS] Bullish Turtle Soup: entry=", m_setup.entry);
         return true;
      }

      return false;
   }

   virtual STradeSetup GetSetup() { return m_setup; }
};

// ============================================================
// Phase 5, Item 5 — London Close Reversal
// ============================================================

/// @brief London Close reversal model (14:00-15:00 GMT sweep fade).
class CLondonCloseReversalModel : public CEntryModel
{
private:
   STradeSetup m_setup;
   string      m_symbol;

public:
   CLondonCloseReversalModel() { m_symbol = _Symbol; ZeroMemory(m_setup); }
   void SetSymbol(const string s) { m_symbol = s; }

   virtual string Name() { return "LondonCloseReversal"; }

   virtual bool Scan(SMarketContext &ctx)
   {
      ZeroMemory(m_setup);
      m_setup.modelName = Name();

      if(!ctx.session.inLondonCloseWindow) return false;
      if(!ctx.session.asianRangeReady)     return false;

      bool bullish = (ctx.bias.consensusBias == ICT_SESSION_BIAS_LONG_ONLY);
      if(ctx.bias.consensusBias == ICT_SESSION_BIAS_NEUTRAL) return false;

      // Gate: IDM sweep (Phase 5, Item 7)
      SInducementLevel idm;
      if(!FindInducement(m_symbol, PERIOD_M5, bullish ? 1 : -1, 20, idm) || !idm.isSwept)
      {
         Print("[MARK1][GATE][LC] IDM not swept -- rejected");
         return false;
      }
      m_setup.idmSwept = true;

      // Detect sweep + close-back on M5
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(m_symbol, PERIOD_M5, 0, 15, rates);
      if(copied < 5) return false;

      double londonHigh = 0.0, londonLow = 0.0;
      for(int i = 1; i < copied; i++)
      {
         londonHigh = (londonHigh == 0.0) ? rates[i].high : MathMax(londonHigh, rates[i].high);
         londonLow  = (londonLow  == 0.0) ? rates[i].low  : MathMin(londonLow,  rates[i].low);
      }

      double pointSize = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double pipSize = ((digits == 3 || digits == 5) ? pointSize * 10.0 : pointSize);

      bool bearishSetup = !bullish && (rates[1].high > londonHigh) && (rates[1].close < londonHigh);
      bool bullishSetup =  bullish && (rates[1].low  < londonLow)  && (rates[1].close > londonLow);

      if(!bearishSetup && !bullishSetup) return false;

      // Gate: IRL->ERL check (Phase 5, Item 8)
      {
         SDOLTarget dolTarget = SelectDOLTarget(m_symbol, bullish, ctx.entryPrice);
         ENUM_LIQUIDITY_TYPE entryZone  = ClassifyLiquidityType(ctx.entryPrice, ctx.h4RangeHigh, ctx.h4RangeLow);
         ENUM_LIQUIDITY_TYPE targetZone = ClassifyLiquidityType(dolTarget.price,  ctx.h4RangeHigh, ctx.h4RangeLow);
         if(entryZone == LIQ_IRL && targetZone == LIQ_IRL)
         {
            Print("[MARK1][GATE][LC] IRL->IRL trade rejected -- no liquidity draw");
            return false;
         }
      }

      // Find M5 FVG for entry
      CICTFVGEngine fvg;
      fvg.Configure(m_symbol, PERIOD_M5, 3.0);
      ICTFVGZone zone;
      ZeroMemory(zone);
      if(!fvg.FindLatestFVG(bullish, 20, zone)) return false;

      m_setup.valid    = true;
      m_setup.bullish  = bullish;
      m_setup.entry    = zone.consequentEncroachment;
      m_setup.stopLoss = bullish ? londonLow  - pipSize * 5.0
                                 : londonHigh + pipSize * 5.0;
      double rr = MathAbs(m_setup.entry - m_setup.stopLoss);
      m_setup.tp1   = bullish ? m_setup.entry + rr     : m_setup.entry - rr;
      m_setup.tp2   = ctx.session.midnightOpenPrice > 0.0
                      ? ctx.session.midnightOpenPrice
                      : (bullish ? m_setup.entry + rr*2 : m_setup.entry - rr*2);
      // Validate TP2 is on correct side; fallback to 2R
      if(bullish && m_setup.tp2 <= m_setup.tp1)
         m_setup.tp2 = m_setup.entry + rr * 2.0;
      if(!bullish && m_setup.tp2 >= m_setup.tp1)
         m_setup.tp2 = m_setup.entry - rr * 2.0;
      {
         SDOLTarget dol = SelectDOLTarget(m_symbol, bullish, m_setup.entry);
         m_setup.tp3   = (dol.type != DOL_NONE) ? dol.price : m_setup.tp2;
      }

      Print("[MARK1][LC] LondonClose Reversal: ",
            bullish ? "LONG" : "SHORT",
            " entry=", m_setup.entry);
      return true;
   }

   virtual STradeSetup GetSetup() { return m_setup; }
};

// ============================================================
// Phase 5, Item 6 — TGIF Friday Reversal
// ============================================================

/// @brief TGIF (Thank God It's Friday) weekly fade reversal model.
class CTGIFModel : public CEntryModel
{
private:
   STradeSetup m_setup;
   string      m_symbol;

public:
   CTGIFModel() { m_symbol = _Symbol; ZeroMemory(m_setup); }
   void SetSymbol(const string s) { m_symbol = s; }

   virtual string Name() { return "TGIF"; }

   virtual bool Scan(SMarketContext &ctx)
   {
      ZeroMemory(m_setup);
      m_setup.modelName = Name();

      // Must be Friday after 10:00 GMT
      if(ctx.bias.currentDOWPhase != DOW_FRIDAY) return false;
      MqlDateTime dt;
      TimeToStruct(TimeGMT(), dt);
      if(dt.hour < 10) return false;

      // Weekly trend direction (opposite = TGIF fade)
      bool weeklyBullish = (ctx.bias.weeklyBias == ICT_SESSION_BIAS_LONG_ONLY);

      // Gate: IDM sweep (Phase 5, Item 7)
      {
         int fadeDir = weeklyBullish ? -1 : 1; // TGIF fades weekly trend
         SInducementLevel idm;
         if(!FindInducement(m_symbol, PERIOD_M15, fadeDir, 20, idm) || !idm.isSwept)
         {
            Print("[MARK1][GATE][TGIF] IDM not swept -- rejected");
            return false;
         }
         m_setup.idmSwept = true;
      }

      // Scan weekly high/low on M15 for sweep
      double weekHigh = iHigh(m_symbol, PERIOD_W1, 0);
      double weekLow  = iLow (m_symbol, PERIOD_W1, 0);

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(m_symbol, PERIOD_M15, 0, 20, rates);
      if(copied < 4) return false;

      double pointSize = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      int    digits    = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double pipSize   = ((digits == 3 || digits == 5) ? pointSize * 10.0 : pointSize);

      // Gate: IRL->ERL check (Phase 5, Item 8)
      {
         bool fadeDir     = !weeklyBullish; // TGIF fades weekly trend
         SDOLTarget dolTarget = SelectDOLTarget(m_symbol, fadeDir, ctx.entryPrice);
         ENUM_LIQUIDITY_TYPE entryZone  = ClassifyLiquidityType(ctx.entryPrice, ctx.h4RangeHigh, ctx.h4RangeLow);
         ENUM_LIQUIDITY_TYPE targetZone = ClassifyLiquidityType(dolTarget.price,  ctx.h4RangeHigh, ctx.h4RangeLow);
         if(entryZone == LIQ_IRL && targetZone == LIQ_IRL)
         {
            Print("[MARK1][GATE][TGIF] IRL->IRL trade rejected -- no liquidity draw");
            return false;
         }
      }

      // Counter-trend: if weekly is bullish, look for sweep of weekly high then fade DOWN
      bool bearSetup =  weeklyBullish && (rates[1].high > weekHigh) && (rates[1].close < weekHigh);
      bool bullSetup = !weeklyBullish && (rates[1].low  < weekLow)  && (rates[1].close > weekLow);

      if(!bearSetup && !bullSetup) return false;

      CICTFVGEngine fvg;
      fvg.Configure(m_symbol, PERIOD_M15, 5.0);
      ICTFVGZone zone;
      ZeroMemory(zone);
      bool bullFVG = !weeklyBullish;
      if(!fvg.FindLatestFVG(bullFVG, 20, zone)) return false;

      m_setup.valid    = true;
      m_setup.bullish  = !weeklyBullish;
      m_setup.entry    = zone.consequentEncroachment;
      m_setup.stopLoss = m_setup.bullish ? weekLow  - pipSize * 5.0
                                         : weekHigh + pipSize * 5.0;
      double riskDist  = MathAbs(m_setup.entry - m_setup.stopLoss);
      m_setup.tp1      = m_setup.bullish ? m_setup.entry + riskDist
                                         : m_setup.entry - riskDist;
      m_setup.tp2      = ctx.session.midnightOpenPrice > 0.0
                         ? ctx.session.midnightOpenPrice
                         : (m_setup.bullish ? m_setup.entry + riskDist * 2.0
                                            : m_setup.entry - riskDist * 2.0);
      // Validate TP2 is on correct side; fallback to 2R
      if(m_setup.bullish && m_setup.tp2 <= m_setup.tp1)
         m_setup.tp2 = m_setup.entry + riskDist * 2.0;
      if(!m_setup.bullish && m_setup.tp2 >= m_setup.tp1)
         m_setup.tp2 = m_setup.entry - riskDist * 2.0;
      {
         bool fadeDir   = !weeklyBullish;
         SDOLTarget dol = SelectDOLTarget(m_symbol, fadeDir, m_setup.entry);
         m_setup.tp3    = (dol.type != DOL_NONE) ? dol.price : m_setup.tp2;
      }

      Print("[MARK1][TGIF] Friday Reversal: ",
            m_setup.bullish ? "LONG" : "SHORT",
            " entry=", m_setup.entry, " TP=", m_setup.tp1);
      return true;
   }

   virtual STradeSetup GetSetup() { return m_setup; }
};

#endif // __ICT_ENTRYMODELS_MQH__
