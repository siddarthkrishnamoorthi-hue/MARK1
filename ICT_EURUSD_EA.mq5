//+------------------------------------------------------------------+
//| ICT_EURUSD_EA.mq5                                                |
//| Modular ICT / SMC EA for EURUSD                                  |
//+------------------------------------------------------------------+
#property copyright "MARK1"
#property version   "4.10"
#property strict

#include <Trade\Trade.mqh>
#include "ICT_Structure.mqh"
#include "ICT_Session.mqh"
#include "ICT_Liquidity.mqh"
#include "ICT_OrderBlock.mqh"
#include "ICT_FVG.mqh"
#include "ICT_Bias.mqh"
#include "ICT_RiskManager.mqh"
#include "ICT_Visualizer.mqh"

input group "=== Core Risk ==="
input double RiskPercent         = 0.50;
input int    MaxTrades           = 2;
input double DailyMaxLoss        = 3.0;
input double WeeklyMaxDD         = 6.0;
input long   MagicNumber         = 20260419;

input group "=== ICT Detection ==="
input int    OB_Lookback         = 10;
input int    FVG_MinGap          = 10;
input int    SwingStrength       = 3;
input int    MinConfluence       = 2;
input double EqualTolerancePips  = 5.0;
input double MinSweepPips        = 2.0;
input int    PendingExpiryBars   = 8;
input double SweepBufferPips     = 2.0;
input double MinRR               = 2.0;
input int    SweepValidityBars   = 36;

input group "=== Session Logic ==="
input bool   EnableSilverBullet  = true;
input bool   EnableMacros        = true;
input bool   EnableNewsFilter    = true;
input int    NewsHaltBeforeMin   = 15;
input int    NewsResumeAfterMin  = 5;

input group "=== Entry Logic ==="
input bool   UseOTE              = true;
input bool   DrawZones           = true;
input bool   EnableTrailingStop  = true;
input double BreakEvenBufferPips = 1.0;
input bool   EnableContinuationModel = true;
input bool   AllowOBOnlyEntries      = true;
input int    ContinuationLookbackBars = 12;
input double MaxZoneDistancePips      = 20.0;

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES Timeframe_Bias    = PERIOD_D1;
input ENUM_TIMEFRAMES Timeframe_Swing   = PERIOD_H4;
input ENUM_TIMEFRAMES Timeframe_Entry   = PERIOD_H1;
input ENUM_TIMEFRAMES Timeframe_Trigger = PERIOD_M5;

input group "=== Debug ==="
input bool   DebugLog            = false;

struct ICTSetupCandidate
{
   bool               valid;
   bool               bullish;
   bool               fromSweep;
   datetime           sweepTime;
   double             sweepExtreme;
   int                confluenceScore;
   ICTFVGZone         triggerFVG;
   ICTOrderBlockZone  h4OB;
   ICTOrderBlockZone  h1OB;
   ICTOrderBlockZone  m5OB;
   ICTOrderBlockZone  triggerOB;
   ICTOrderBlockZone  breakerOB;
   ICTOrderBlockZone  mitigationOB;
   ICTFVGZone         inverseFVG;
   ICTBPRZone         bpr;
   double             zoneLow;
   double             zoneHigh;
   double             entry;
   double             stopLoss;
   double             tp1;
   double             tp2;
   double             tp3;
};

CTrade              g_trade;
CICTSessionEngine   g_session;
CICTLiquidityEngine g_liquidity;
CICTBiasEngine      g_bias;
CICTRiskManager     g_risk;
CICTVisualizer      g_visualizer;

CICTStructureEngine g_structureH4;
CICTStructureEngine g_structureH1;
CICTStructureEngine g_structureM15;
CICTStructureEngine g_structureM5;

CICTOrderBlockEngine g_obH4;
CICTOrderBlockEngine g_obH1;
CICTOrderBlockEngine g_obM15;
CICTOrderBlockEngine g_obM5;

CICTFVGEngine g_fvgH1;
CICTFVGEngine g_fvgM15;
CICTFVGEngine g_fvgM5;

datetime               g_lastBarTime      = 0;
ICTLiquiditySweepSignal g_activeSweep;
bool                   g_hasActiveSweep   = false;
datetime               g_lastSetupSweep   = 0;
bool                   g_lastSetupBullish = false;

void Log(const string message)
{
   if(DebugLog)
      Print("[ICT_EURUSD_EA] ", message);
}

bool IsBullishBreak(const ENUM_ICT_BREAK_CLASSIFICATION classification)
{
   return (classification == ICT_BREAK_BULLISH_BOS ||
           classification == ICT_BREAK_BULLISH_CHOCH ||
           classification == ICT_BREAK_BULLISH_MSS);
}

bool IsBearishBreak(const ENUM_ICT_BREAK_CLASSIFICATION classification)
{
   return (classification == ICT_BREAK_BEARISH_BOS ||
           classification == ICT_BREAK_BEARISH_CHOCH ||
           classification == ICT_BREAK_BEARISH_MSS);
}

bool IsNewBar()
{
   datetime currentBar = iTime(_Symbol, Timeframe_Trigger, 0);
   if(currentBar <= 0)
      return false;
   if(currentBar == g_lastBarTime)
      return false;
   g_lastBarTime = currentBar;
   return true;
}

bool IsWindowEnabled(const ICTSessionSnapshot &session)
{
   if(session.inMacroWindow && !EnableMacros)
      return false;
   if((session.inLondonSilverBullet || session.inNYSilverBulletAM || session.inNYSilverBulletPM) && !EnableSilverBullet)
      return false;
   return (session.inLondonKillzone || session.inNYAMKillzone ||
           (EnableSilverBullet && (session.inLondonSilverBullet || session.inNYSilverBulletAM || session.inNYSilverBulletPM)) ||
           (EnableMacros && session.inMacroWindow));
}

int AvailableTradeSlots()
{
   return MathMax(0, MaxTrades - g_risk.CountManagedExposure());
}

void RefreshAnalysisEngines()
{
   g_structureH4.Refresh(300);
   g_structureH1.Refresh(300);
   g_structureM15.Refresh(400);
   g_structureM5.Refresh(500);
}

double PipSize()
{
   return ((_Digits == 3 || _Digits == 5) ? _Point * 10.0 : _Point);
}

double MinimumOrderDistance()
{
   long stopsLevel  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double distance  = (double)MathMax(stopsLevel, freezeLevel) * _Point;
   return MathMax(distance, _Point * 2.0);
}

bool ZonesOverlap(const double low1, const double high1, const double low2, const double high2)
{
   if(high1 <= low1 || high2 <= low2)
      return false;
   return (MathMax(low1, low2) < MathMin(high1, high2));
}

bool IsZoneNearCurrentPrice(const bool bullish, const double low, const double high)
{
   if(high <= low)
      return false;

   double reference = bullish ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                              : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(reference <= 0.0)
      return false;

   double distance = 0.0;
   if(reference < low)
      distance = low - reference;
   else if(reference > high)
      distance = reference - high;

   return (distance <= (MaxZoneDistancePips * PipSize()));
}

bool GetRecentDirectionalBreak(const bool bullish,
                               const int maxBarsBack,
                               ICTStructureBreakSignal &signal)
{
   ICTStructureBreakSignal m15Signal;
   ICTStructureBreakSignal m5Signal;
   ZeroMemory(m15Signal);
   ZeroMemory(m5Signal);

   bool haveM15 = g_structureM15.GetLatestBreakSignal(m15Signal);
   bool haveM5  = g_structureM5.GetLatestBreakSignal(m5Signal);
   int maxSeconds = maxBarsBack * PeriodSeconds(Timeframe_Trigger);
   datetime cutoff = TimeCurrent() - maxSeconds;

   if(haveM15 && m15Signal.valid && m15Signal.time >= cutoff)
   {
      if((bullish && IsBullishBreak(m15Signal.classification)) ||
         (!bullish && IsBearishBreak(m15Signal.classification)))
      {
         signal = m15Signal;
         return true;
      }
   }

   if(haveM5 && m5Signal.valid && m5Signal.time >= cutoff)
   {
      if((bullish && IsBullishBreak(m5Signal.classification)) ||
         (!bullish && IsBearishBreak(m5Signal.classification)))
      {
         signal = m5Signal;
         return true;
      }
   }

   return false;
}

double SelectProtectiveExtreme(const bool bullish, const double fallbackPrice)
{
   ICTStructureSnapshot snapshot;
   ZeroMemory(snapshot);
   if(g_structureM15.BuildSnapshot(snapshot))
   {
      if(bullish && snapshot.latestLow.valid)
         return snapshot.latestLow.price;
      if(!bullish && snapshot.latestHigh.valid)
         return snapshot.latestHigh.price;
   }

   if(g_structureM5.BuildSnapshot(snapshot))
   {
      if(bullish && snapshot.latestLow.valid)
         return snapshot.latestLow.price;
      if(!bullish && snapshot.latestHigh.valid)
         return snapshot.latestHigh.price;
   }

   return fallbackPrice;
}

bool HasManagedPendingAtPrice(const bool bullish, const double entryPrice, const double stopLoss)
{
   double priceTolerance = MathMax(_Point * 2.0, PipSize() * 0.10);
   double stopTolerance  = MathMax(_Point * 5.0, PipSize() * 0.25);
   ENUM_ORDER_TYPE wantedType = bullish ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != wantedType)
         continue;

      double existingEntry = OrderGetDouble(ORDER_PRICE_OPEN);
      double existingSL    = OrderGetDouble(ORDER_SL);
      if(MathAbs(existingEntry - entryPrice) <= priceTolerance &&
         MathAbs(existingSL - stopLoss) <= stopTolerance)
      {
         return true;
      }
   }

   return false;
}

bool IsValidLimitOrderPlan(const bool bullish,
                           const double entryPrice,
                           const double stopLoss,
                           const double takeProfit)
{
   if(entryPrice <= 0.0 || stopLoss <= 0.0 || takeProfit <= 0.0)
      return false;

   double ask         = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid         = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDistance = MinimumOrderDistance();

   if(bullish)
   {
      if(!(stopLoss < entryPrice && entryPrice < takeProfit))
         return false;
      if((ask - entryPrice) < minDistance)
         return false;
      if((entryPrice - stopLoss) < minDistance)
         return false;
      if((takeProfit - entryPrice) < minDistance)
         return false;
   }
   else
   {
      if(!(takeProfit < entryPrice && entryPrice < stopLoss))
         return false;
      if((entryPrice - bid) < minDistance)
         return false;
      if((stopLoss - entryPrice) < minDistance)
         return false;
      if((entryPrice - takeProfit) < minDistance)
         return false;
   }

   return true;
}

bool GetDirectionalBreakAfterSweep(const bool bullish, const datetime sweepTime, ICTStructureBreakSignal &signal)
{
   ICTStructureBreakSignal m15Signal;
   ICTStructureBreakSignal m5Signal;
   ZeroMemory(m15Signal);
   ZeroMemory(m5Signal);

   bool haveM15 = g_structureM15.GetLatestBreakSignal(m15Signal);
   bool haveM5  = g_structureM5.GetLatestBreakSignal(m5Signal);

   if(haveM15 && m15Signal.valid && m15Signal.time >= sweepTime)
   {
      if((bullish && IsBullishBreak(m15Signal.classification)) ||
         (!bullish && IsBearishBreak(m15Signal.classification)))
      {
         signal = m15Signal;
         return true;
      }
   }

   if(haveM5 && m5Signal.valid && m5Signal.time >= sweepTime)
   {
      if((bullish && IsBullishBreak(m5Signal.classification)) ||
         (!bullish && IsBearishBreak(m5Signal.classification)))
      {
         signal = m5Signal;
         return true;
      }
   }

   return false;
}

bool IsSweepStillValid()
{
   if(!g_hasActiveSweep || !g_activeSweep.valid)
      return false;

   int currentBarShift = iBarShift(_Symbol, Timeframe_Trigger, g_activeSweep.time, true);
   if(currentBarShift < 0)
      return false;

   if(currentBarShift > SweepValidityBars)
   {
      g_hasActiveSweep = false;
      ZeroMemory(g_activeSweep);
      return false;
   }

   return true;
}

double SelectOpposingLiquidityTarget(const bool bullish, const double entryPrice, const ICTSessionSnapshot &session, const bool farther)
{
   double pdh = 0.0, pdl = 0.0, pwh = 0.0, pwl = 0.0;
   g_liquidity.GetPreviousDayHighLow(pdh, pdl);
   g_liquidity.GetPreviousWeekHighLow(pwh, pwl);

   double candidates[5];
   int count = 0;

   if(bullish)
   {
      if(session.asianHigh > entryPrice) candidates[count++] = session.asianHigh;
      if(pdh > entryPrice)               candidates[count++] = pdh;
      if(pwh > entryPrice)               candidates[count++] = pwh;
   }
   else
   {
      if(session.asianLow > 0.0 && session.asianLow < entryPrice) candidates[count++] = session.asianLow;
      if(pdl > 0.0 && pdl < entryPrice)                           candidates[count++] = pdl;
      if(pwl > 0.0 && pwl < entryPrice)                           candidates[count++] = pwl;
   }

   if(count == 0)
      return 0.0;

   double selected = candidates[0];
   for(int i = 1; i < count; i++)
   {
      if(bullish)
      {
         if(farther)
            selected = MathMax(selected, candidates[i]);
         else
            selected = MathMin(selected, candidates[i]);
      }
      else
      {
         if(farther)
            selected = MathMin(selected, candidates[i]);
         else
            selected = MathMax(selected, candidates[i]);
      }
   }

   return selected;
}

bool BuildSetupCandidate(const bool bullish,
                         const datetime contextTime,
                         const double protectiveExtreme,
                         const bool requirePostSweep,
                         const ICTSessionSnapshot &session,
                         const ICTBiasSnapshot &bias,
                         ICTSetupCandidate &setup)
{
   ZeroMemory(setup);
   setup.valid        = false;
   setup.bullish      = bullish;
   setup.fromSweep    = requirePostSweep;
   setup.sweepTime    = contextTime;
   setup.sweepExtreme = protectiveExtreme;

   datetime formedAfter = requirePostSweep ? contextTime : 0;

   ICTFVGZone m5FVG;
   ICTFVGZone m15FVG;
   ICTFVGZone h1FVG;
   ZeroMemory(m5FVG);
   ZeroMemory(m15FVG);
   ZeroMemory(h1FVG);

   bool haveM5FVG  = g_fvgM5.FindLatestFVG(bullish, 80, m5FVG, formedAfter);
   bool haveM15FVG = g_fvgM15.FindLatestFVG(bullish, 80, m15FVG, formedAfter);
   bool haveH1FVG  = g_fvgH1.FindLatestFVG(bullish, 60, h1FVG, formedAfter);

   if(haveM5FVG)
      g_fvgM5.RefreshZoneState(m5FVG, 80);
   if(haveM15FVG)
      g_fvgM15.RefreshZoneState(m15FVG, 80);
   if(haveH1FVG)
      g_fvgH1.RefreshZoneState(h1FVG, 80);

   if(haveM5FVG && (m5FVG.state == ICT_FVG_ACTIVE || m5FVG.state == ICT_FVG_PARTIAL_FILL))
      setup.triggerFVG = m5FVG;
   else if(haveM15FVG && (m15FVG.state == ICT_FVG_ACTIVE || m15FVG.state == ICT_FVG_PARTIAL_FILL))
      setup.triggerFVG = m15FVG;
   else if(haveH1FVG && (h1FVG.state == ICT_FVG_ACTIVE || h1FVG.state == ICT_FVG_PARTIAL_FILL))
      setup.triggerFVG = h1FVG;

   g_obH4.FindLatestOrderBlock(bullish, setup.h4OB);
   g_obH1.FindLatestOrderBlock(bullish, setup.h1OB);
   g_obM5.FindLatestOrderBlock(bullish, setup.m5OB);
   g_obM15.FindLatestOrderBlock(bullish, setup.triggerOB);
   g_obM15.FindBreakerBlock(bullish, setup.breakerOB);
   g_obM15.FindMitigationBlock(bullish, setup.mitigationOB);
   g_fvgM15.FindLatestBPR(80, setup.bpr);

   if(setup.m5OB.valid && !setup.m5OB.invalidated)
      setup.triggerOB = setup.m5OB;

   double zoneLow = 0.0;
   double zoneHigh = 0.0;
   bool haveZone = false;

   if(setup.triggerFVG.valid)
   {
      zoneLow = setup.triggerFVG.low;
      zoneHigh = setup.triggerFVG.high;
      haveZone = true;
   }

   ICTOrderBlockZone zoneCandidates[4];
   zoneCandidates[0] = setup.triggerOB;
   zoneCandidates[1] = setup.breakerOB;
   zoneCandidates[2] = setup.mitigationOB;
   zoneCandidates[3] = setup.h1OB;

   for(int i = 0; i < 4; i++)
   {
      if(!zoneCandidates[i].valid || zoneCandidates[i].invalidated)
         continue;

      if(!haveZone)
      {
         zoneLow = zoneCandidates[i].low;
         zoneHigh = zoneCandidates[i].high;
         haveZone = true;
         continue;
      }

      if(ZonesOverlap(zoneLow, zoneHigh, zoneCandidates[i].low, zoneCandidates[i].high))
      {
         zoneLow = MathMax(zoneLow, zoneCandidates[i].low);
         zoneHigh = MathMin(zoneHigh, zoneCandidates[i].high);
      }
   }

   if(!haveZone && setup.bpr.valid)
   {
      zoneLow = setup.bpr.low;
      zoneHigh = setup.bpr.high;
      haveZone = true;
   }

   if(!haveZone)
      return false;

   if(zoneHigh <= zoneLow)
   {
      if(setup.triggerFVG.valid)
      {
         zoneLow = setup.triggerFVG.low;
         zoneHigh = setup.triggerFVG.high;
      }
      else if(setup.triggerOB.valid)
      {
         zoneLow = setup.triggerOB.low;
         zoneHigh = setup.triggerOB.high;
      }
      else
      {
         return false;
      }
   }

   if(!setup.triggerFVG.valid && !AllowOBOnlyEntries)
      return false;

   if(setup.triggerFVG.valid && setup.triggerFVG.state == ICT_FVG_FILLED)
      g_fvgM15.DetectInverseFVG(setup.triggerFVG, setup.inverseFVG);

   setup.zoneLow  = zoneLow;
   setup.zoneHigh = zoneHigh;

   if(!IsZoneNearCurrentPrice(bullish, setup.zoneLow, setup.zoneHigh))
      return false;

   setup.confluenceScore = 0;
   if(setup.triggerFVG.valid) setup.confluenceScore++;
   if(setup.triggerOB.valid && !setup.triggerOB.invalidated) setup.confluenceScore++;
   if(setup.h1OB.valid && !setup.h1OB.invalidated &&
      ZonesOverlap(setup.zoneLow, setup.zoneHigh, setup.h1OB.low, setup.h1OB.high)) setup.confluenceScore++;
   if(setup.h4OB.valid && !setup.h4OB.invalidated &&
      ZonesOverlap(setup.zoneLow, setup.zoneHigh, setup.h4OB.low, setup.h4OB.high)) setup.confluenceScore++;
   if(setup.breakerOB.valid) setup.confluenceScore++;
   if(setup.mitigationOB.valid) setup.confluenceScore++;
   if(setup.inverseFVG.valid) setup.confluenceScore++;
   if(setup.bpr.valid && ZonesOverlap(setup.zoneLow, setup.zoneHigh, setup.bpr.low, setup.bpr.high)) setup.confluenceScore++;
   if(session.inMacroWindow || session.inLondonSilverBullet || session.inNYSilverBulletAM || session.inNYSilverBulletPM)
      setup.confluenceScore++;
   if((bullish && (bias.pdaZone == ICT_PDA_DISCOUNT || bias.pdaZone == ICT_PDA_EQUILIBRIUM)) ||
      (!bullish && (bias.pdaZone == ICT_PDA_PREMIUM || bias.pdaZone == ICT_PDA_EQUILIBRIUM)))
      setup.confluenceScore++;
   if(requirePostSweep && contextTime > 0)
      setup.confluenceScore++;

   setup.sweepExtreme = SelectProtectiveExtreme(bullish,
                                                (protectiveExtreme > 0.0)
                                                ? protectiveExtreme
                                                : (bullish ? setup.zoneLow : setup.zoneHigh));
   if(setup.sweepExtreme <= 0.0)
      return false;

   setup.valid = true;
   return true;
}

bool BuildContinuationCandidate(const ICTSessionSnapshot &session,
                                const ICTBiasSnapshot &bias,
                                ICTSetupCandidate &setup)
{
   if(!EnableContinuationModel)
      return false;

   bool bullish = false;
   if(bias.consensusBias == ICT_SESSION_BIAS_LONG_ONLY)
      bullish = true;
   else if(bias.consensusBias == ICT_SESSION_BIAS_SHORT_ONLY)
      bullish = false;
   else
      return false;

   if(!g_bias.AllowsTrade(bullish))
      return false;

   ICTStructureBreakSignal continuationBreak;
   ZeroMemory(continuationBreak);
   if(!GetRecentDirectionalBreak(bullish, ContinuationLookbackBars, continuationBreak))
      return false;

   double protectiveExtreme = SelectProtectiveExtreme(bullish, continuationBreak.level);
   if(!BuildSetupCandidate(bullish,
                           continuationBreak.time,
                           protectiveExtreme,
                           false,
                           session,
                           bias,
                           setup))
      return false;

   return true;
}

double ClampToZone(const double price, const double low, const double high)
{
   return MathMax(low, MathMin(high, price));
}

int BuildEntryLevels(const ICTSetupCandidate &setup, double &entries[], double &weights[])
{
   ArrayResize(entries, 0);
   ArrayResize(weights, 0);

   double baseEntry = setup.triggerFVG.valid ? setup.triggerFVG.midpoint
                                             : ((setup.zoneLow + setup.zoneHigh) * 0.5);
   double range = MathAbs(setup.zoneHigh - setup.sweepExtreme);
   if(!setup.bullish)
      range = MathAbs(setup.sweepExtreme - setup.zoneLow);

   int slots = AvailableTradeSlots();
   if(range <= 0.0 || !UseOTE || slots <= 1)
   {
      ArrayResize(entries, 1);
      ArrayResize(weights, 1);
      entries[0] = baseEntry;
      weights[0] = 100.0;
      return 1;
   }

   double impulseLow  = setup.bullish ? setup.sweepExtreme : setup.zoneLow;
   double impulseHigh = setup.bullish ? setup.zoneHigh : setup.sweepExtreme;
   double rangeSize   = impulseHigh - impulseLow;
   if(rangeSize <= 0.0)
   {
      ArrayResize(entries, 1);
      ArrayResize(weights, 1);
      entries[0] = baseEntry;
      weights[0] = 100.0;
      return 1;
   }

   double rawLevels[3];
   rawLevels[0] = setup.bullish ? (impulseHigh - rangeSize * 0.62)  : (impulseLow + rangeSize * 0.62);
   rawLevels[1] = setup.bullish ? (impulseHigh - rangeSize * 0.705) : (impulseLow + rangeSize * 0.705);
   rawLevels[2] = setup.bullish ? (impulseHigh - rangeSize * 0.79)  : (impulseLow + rangeSize * 0.79);

   int plannedEntries = MathMin(3, slots);
   ArrayResize(entries, plannedEntries);
   ArrayResize(weights, plannedEntries);
   for(int i = 0; i < plannedEntries; i++)
   {
      entries[i] = ClampToZone(rawLevels[i], setup.zoneLow, setup.zoneHigh);
      if(plannedEntries == 2)
         weights[i] = 50.0;
      else
         weights[i] = (i < 2) ? 40.0 : 20.0;
   }

   return plannedEntries;
}

bool BuildTradePlan(const ICTSessionSnapshot &session, ICTSetupCandidate &setup)
{
   double stopBuffer = SweepBufferPips * PipSize();
   setup.entry       = setup.triggerFVG.valid ? setup.triggerFVG.midpoint
                                              : ((setup.zoneLow + setup.zoneHigh) * 0.5);
   double stopAnchor = setup.bullish ? MathMin(setup.sweepExtreme, setup.zoneLow)
                                     : MathMax(setup.sweepExtreme, setup.zoneHigh);
   setup.stopLoss    = NormalizeDouble(setup.bullish ? (stopAnchor - stopBuffer)
                                                     : (stopAnchor + stopBuffer), _Digits);

   double minDistance = MinimumOrderDistance();
   if(setup.bullish && setup.stopLoss >= setup.entry)
      setup.stopLoss = NormalizeDouble(setup.entry - MathMax(stopBuffer, minDistance), _Digits);
   if(!setup.bullish && setup.stopLoss <= setup.entry)
      setup.stopLoss = NormalizeDouble(setup.entry + MathMax(stopBuffer, minDistance), _Digits);

   double riskDistance = MathAbs(setup.entry - setup.stopLoss);
   if(riskDistance <= 0.0)
      return false;

   if(setup.triggerFVG.valid)
   {
      if(setup.bullish)
         setup.tp1 = (setup.entry < setup.triggerFVG.consequentEncroachment)
                   ? setup.triggerFVG.consequentEncroachment
                   : setup.triggerFVG.high;
      else
         setup.tp1 = (setup.entry > setup.triggerFVG.consequentEncroachment)
                   ? setup.triggerFVG.consequentEncroachment
                   : setup.triggerFVG.low;
   }
   else
   {
      setup.tp1 = setup.bullish ? (setup.entry + riskDistance)
                                : (setup.entry - riskDistance);
   }

   setup.tp2 = SelectOpposingLiquidityTarget(setup.bullish, setup.entry, session, false);
   setup.tp3 = SelectOpposingLiquidityTarget(setup.bullish, setup.entry, session, true);

   if(setup.tp2 <= 0.0)
      setup.tp2 = setup.bullish ? (setup.entry + (riskDistance * 2.0))
                                : (setup.entry - (riskDistance * 2.0));
   if(setup.tp3 <= 0.0 || setup.tp3 == setup.tp2)
      setup.tp3 = setup.bullish ? (setup.entry + (riskDistance * 3.0))
                                : (setup.entry - (riskDistance * 3.0));
   if(setup.bullish)
   {
      if(setup.tp1 <= setup.entry)
         setup.tp1 = setup.entry + riskDistance;
      if(setup.tp2 <= setup.entry)
         setup.tp2 = setup.entry + (riskDistance * 2.0);
      if(setup.tp3 <= setup.tp2)
         setup.tp3 = setup.entry + (riskDistance * 3.0);
   }
   else
   {
      if(setup.tp1 >= setup.entry)
         setup.tp1 = setup.entry - riskDistance;
      if(setup.tp2 >= setup.entry)
         setup.tp2 = setup.entry - (riskDistance * 2.0);
      if(setup.tp3 >= setup.tp2)
         setup.tp3 = setup.entry - (riskDistance * 3.0);
   }

   double rrToTP3 = MathAbs(setup.tp3 - setup.entry) / riskDistance;
   if(rrToTP3 < MinRR)
      return false;

   setup.tp1 = NormalizeDouble(setup.tp1, _Digits);
   setup.tp2 = NormalizeDouble(setup.tp2, _Digits);
   setup.tp3 = NormalizeDouble(setup.tp3, _Digits);
   return true;
}

bool PlaceSetup(const ICTSetupCandidate &setup)
{
   string reason;
   if(!g_risk.CanTrade(reason))
   {
      Log("Trade blocked: " + reason);
      return false;
   }

   if(setup.sweepTime == g_lastSetupSweep && setup.bullish == g_lastSetupBullish)
      return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double entries[];
   double weights[];
   int entryCount = BuildEntryLevels(setup, entries, weights);
   if(entryCount <= 0)
      return false;

   bool placed = false;
   int slots   = AvailableTradeSlots();
   double submittedEntries[];
   ArrayResize(submittedEntries, 0);
   double duplicateTolerance = MathMax(_Point * 2.0, PipSize() * 0.10);
   for(int i = 0; i < entryCount && i < slots; i++)
   {
      double entryPrice = NormalizeDouble(entries[i], _Digits);
      bool duplicateEntry = false;
      for(int j = 0; j < ArraySize(submittedEntries); j++)
      {
         if(MathAbs(submittedEntries[j] - entryPrice) <= duplicateTolerance)
         {
            duplicateEntry = true;
            break;
         }
      }

      if(duplicateEntry)
         continue;
      if(setup.bullish && entryPrice >= ask)
         continue;
      if(!setup.bullish && entryPrice <= bid)
         continue;
      if(HasManagedPendingAtPrice(setup.bullish, entryPrice, setup.stopLoss))
         continue;
      if(!IsValidLimitOrderPlan(setup.bullish, entryPrice, setup.stopLoss, setup.tp3))
         continue;

      ulong ticket = 0;
      string tag   = setup.bullish ? "ICTB" : "ICTS";
      if(g_risk.PlaceLimitOrder(g_trade,
                                setup.bullish,
                                entryPrice,
                                setup.stopLoss,
                                setup.tp3,
                                setup.tp1,
                                setup.tp2,
                                weights[i],
                                tag,
                                ticket))
      {
         placed = true;
         int nextIndex = ArraySize(submittedEntries);
         ArrayResize(submittedEntries, nextIndex + 1);
         submittedEntries[nextIndex] = entryPrice;
         Log("Placed order ticket=" + IntegerToString((int)ticket) +
             " entry=" + DoubleToString(entryPrice, _Digits));
      }
   }

   if(placed)
   {
      g_lastSetupSweep   = setup.sweepTime;
      g_lastSetupBullish = setup.bullish;
      g_hasActiveSweep   = false;
   }

   return placed;
}

int OnInit()
{
   if(StringFind(_Symbol, "EURUSD") < 0)
      Print("[ICT_EURUSD_EA] WARNING: tuned for EURUSD. Current symbol=", _Symbol);

   g_trade.SetExpertMagicNumber(MagicNumber);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   g_session.Configure(_Symbol, Timeframe_Trigger, EnableNewsFilter, NewsHaltBeforeMin, NewsResumeAfterMin);
   g_liquidity.Configure(_Symbol, Timeframe_Trigger, EqualTolerancePips, MinSweepPips);
   g_bias.Configure(_Symbol, SwingStrength, 80, Timeframe_Bias, Timeframe_Swing, Timeframe_Entry);
   g_risk.Configure(_Symbol, MagicNumber, RiskPercent, MaxTrades, DailyMaxLoss, WeeklyMaxDD,
                    PendingExpiryBars, BreakEvenBufferPips, EnableTrailingStop, Timeframe_Trigger);
   g_visualizer.Configure("ICT", DrawZones);

   g_structureH4.Configure(_Symbol, PERIOD_H4, SwingStrength);
   g_structureH1.Configure(_Symbol, PERIOD_H1, SwingStrength);
   g_structureM15.Configure(_Symbol, PERIOD_M15, SwingStrength);
   g_structureM5.Configure(_Symbol, PERIOD_M5, SwingStrength);

   g_obH4.Configure(_Symbol, PERIOD_H4, SwingStrength, OB_Lookback * 4);
   g_obH1.Configure(_Symbol, PERIOD_H1, SwingStrength, OB_Lookback * 2);
   g_obM15.Configure(_Symbol, PERIOD_M15, SwingStrength, OB_Lookback);
   g_obM5.Configure(_Symbol, PERIOD_M5, SwingStrength, OB_Lookback);

   g_fvgH1.Configure(_Symbol, PERIOD_H1, FVG_MinGap);
   g_fvgM15.Configure(_Symbol, PERIOD_M15, FVG_MinGap);
   g_fvgM5.Configure(_Symbol, PERIOD_M5, FVG_MinGap);

   g_lastBarTime = iTime(_Symbol, Timeframe_Trigger, 0);
   ZeroMemory(g_activeSweep);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Log("Deinit reason=" + IntegerToString(reason));
}

void OnTick()
{
   g_session.Refresh();
   g_risk.Refresh();
   RefreshAnalysisEngines();
   ICTSessionSnapshot session = g_session.Snapshot();
   g_bias.Refresh(session);
   g_risk.ManageOpenPositions(g_trade, g_structureM15, g_structureM5);
   g_risk.CancelExpiredPendingOrders(g_trade);

   ICTBiasSnapshot bias = g_bias.Snapshot();
   ICTRiskSnapshot risk = g_risk.Snapshot();
   g_visualizer.DrawSessionLevels(session);

   if(risk.dailyBlocked || risk.weeklyBlocked || session.newsBlocked)
      g_risk.CancelAllPending(g_trade, "blocked");

   if(!IsNewBar())
      return;

   if(!session.asianRangeReady)
      return;
   if(!IsWindowEnabled(session))
      return;

   string riskReason;
   if(!g_risk.CanTrade(riskReason))
      return;

   ICTLiquiditySweepSignal sweepSignal;
   ZeroMemory(sweepSignal);
   if(g_liquidity.DetectBestSweep(session.asianHigh, session.asianLow, session.asianRangeReady, sweepSignal))
   {
      if(!g_hasActiveSweep || !g_activeSweep.valid || sweepSignal.time > g_activeSweep.time)
      {
         g_activeSweep = sweepSignal;
         g_hasActiveSweep = true;
         g_visualizer.DrawLiquiditySweep(g_activeSweep);
      }
   }

   bool placed = false;

   if(IsSweepStillValid() && g_bias.AllowsTrade(g_activeSweep.bullishIntent))
   {
      ICTStructureBreakSignal confirmation;
      ZeroMemory(confirmation);
      if(GetDirectionalBreakAfterSweep(g_activeSweep.bullishIntent, g_activeSweep.time, confirmation))
      {
         ICTSetupCandidate sweepSetup;
         if(BuildSetupCandidate(g_activeSweep.bullishIntent,
                                g_activeSweep.time,
                                g_activeSweep.sweepExtreme,
                                true,
                                session,
                                bias,
                                sweepSetup))
         {
            if(sweepSetup.confluenceScore >= MinConfluence && BuildTradePlan(session, sweepSetup))
            {
               g_visualizer.DrawOrderBlock(sweepSetup.h4OB, "H4");
               g_visualizer.DrawOrderBlock(sweepSetup.h1OB, "H1");
               g_visualizer.DrawOrderBlock(sweepSetup.triggerOB, "TRIGGER");
               g_visualizer.DrawFVG(sweepSetup.triggerFVG, "ENTRY");
               g_visualizer.DrawBPR(sweepSetup.bpr);
               g_visualizer.DrawTradePlan(sweepSetup.bullish,
                                          sweepSetup.entry,
                                          sweepSetup.stopLoss,
                                          sweepSetup.tp1,
                                          sweepSetup.tp2,
                                          sweepSetup.tp3);
               placed = PlaceSetup(sweepSetup);
            }
         }
      }
   }

   if(!placed)
   {
      ICTSetupCandidate continuationSetup;
      if(BuildContinuationCandidate(session, bias, continuationSetup))
      {
         if(continuationSetup.confluenceScore >= MinConfluence && BuildTradePlan(session, continuationSetup))
         {
            g_visualizer.DrawOrderBlock(continuationSetup.h4OB, "H4");
            g_visualizer.DrawOrderBlock(continuationSetup.h1OB, "H1");
            g_visualizer.DrawOrderBlock(continuationSetup.triggerOB, "TRIGGER");
            g_visualizer.DrawFVG(continuationSetup.triggerFVG, "ENTRY");
            g_visualizer.DrawBPR(continuationSetup.bpr);
            g_visualizer.DrawTradePlan(continuationSetup.bullish,
                                       continuationSetup.entry,
                                       continuationSetup.stopLoss,
                                       continuationSetup.tp1,
                                       continuationSetup.tp2,
                                       continuationSetup.tp3);
            PlaceSetup(continuationSetup);
         }
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   g_risk.OnTradeTransaction(trans);
}
