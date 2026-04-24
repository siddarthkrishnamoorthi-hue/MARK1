//+------------------------------------------------------------------+
//| ICT_Visualizer.mqh                                               |
//| MARK1 ICT Expert Advisor — Chart rendering for zones and levels  |
//| Copyright 2024-2025, MARK1 Project                               |
//+------------------------------------------------------------------+
#pragma once
#ifndef __ICT_VISUALIZER_MQH__
#define __ICT_VISUALIZER_MQH__

#include "ICT_Session.mqh"
#include "ICT_Liquidity.mqh"
#include "ICT_OrderBlock.mqh"
#include "ICT_FVG.mqh"
#include "ICT_Bias.mqh"   // Phase 8: ENUM_DOW_PHASE
#include "ICT_IPDA.mqh"   // Phase 8: SIPDARange
#include "ICT_SMT.mqh"    // Phase 8: SSMTDivergence

class CICTVisualizer
{
private:
   long   m_chartId;
   string m_prefix;
   bool   m_enabled;

   string ObjectName(const string suffix) const;
   void DrawHorizontalLine(const string name,
                           const double price,
                           const color lineColor,
                           const string text) const;
   void DrawRectangle(const string name,
                      const datetime time1,
                      const datetime time2,
                      const double price1,
                      const double price2,
                      const color fillColor,
                      const ENUM_LINE_STYLE borderStyle = STYLE_SOLID) const;

public:
   CICTVisualizer();

   void Configure(const string prefix, const bool enabled);
   void ClearAll() const;
   void DrawSessionLevels(const ICTSessionSnapshot &session) const;
   void DrawLiquiditySweep(const ICTLiquiditySweepSignal &sweep) const;
   void DrawOrderBlock(const ICTOrderBlockZone &zone, const string label) const;
   void DrawFVG(const ICTFVGZone &zone, const string label) const;
   void DrawBPR(const ICTBPRZone &zone) const;
   void DrawTradePlan(const bool bullish,
                      const double entry,
                      const double stopLoss,
                      const double tp1,
                      const double tp2,
                      const double tp3) const;

   // Phase 8: Extended visual elements
   void DrawNDOGLines(const SOpeningGap &gap) const;
   void DrawNWOGLines(const SOpeningGap &gap) const;
   void DrawPO3Box(const ENUM_PO3_PHASE  phase,
                   const datetime t1, const datetime t2,
                   const double high, const double low) const;
   void DrawJudasMarker(const SJudasSwing &js) const;
   void DrawIPDALevels(const SIPDARange &range) const;
   void DrawDOWPhaseLabel(const ENUM_DOW_PHASE phase) const;
   void DrawSMTMarker(const SSMTDivergence &smt) const;
};

CICTVisualizer::CICTVisualizer()
{
   m_chartId = ChartID();
   m_prefix  = "ICT";
   m_enabled = true;
}

void CICTVisualizer::Configure(const string prefix, const bool enabled)
{
   m_chartId = ChartID();
   m_prefix  = prefix;
   m_enabled = enabled;
}

string CICTVisualizer::ObjectName(const string suffix) const
{
   return m_prefix + "_" + suffix;
}

void CICTVisualizer::DrawHorizontalLine(const string name,
                                        const double price,
                                        const color lineColor,
                                        const string text) const
{
   if(!m_enabled || price <= 0.0)
      return;

   string objectName = ObjectName(name);
   if(ObjectFind(m_chartId, objectName) < 0)
      ObjectCreate(m_chartId, objectName, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(m_chartId, objectName, OBJPROP_PRICE, price);
   ObjectSetInteger(m_chartId, objectName, OBJPROP_COLOR, lineColor);
   ObjectSetInteger(m_chartId, objectName, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetString(m_chartId, objectName, OBJPROP_TEXT, text);
}

void CICTVisualizer::DrawRectangle(const string name,
                                   const datetime time1,
                                   const datetime time2,
                                   const double price1,
                                   const double price2,
                                   const color fillColor,
                                   const ENUM_LINE_STYLE borderStyle = STYLE_SOLID) const
{
   if(!m_enabled || time1 <= 0 || time2 <= 0 || price1 <= 0.0 || price2 <= 0.0)
      return;

   string objectName = ObjectName(name);
   if(ObjectFind(m_chartId, objectName) < 0)
      ObjectCreate(m_chartId, objectName, OBJ_RECTANGLE, 0, time1, price1, time2, price2);

   ObjectMove(m_chartId, objectName, 0, time1, price1);
   ObjectMove(m_chartId, objectName, 1, time2, price2);
   ObjectSetInteger(m_chartId, objectName, OBJPROP_COLOR, fillColor);
   ObjectSetInteger(m_chartId, objectName, OBJPROP_STYLE, borderStyle);
   ObjectSetInteger(m_chartId, objectName, OBJPROP_BACK, true);
   ObjectSetInteger(m_chartId, objectName, OBJPROP_FILL, true);
}

void CICTVisualizer::ClearAll() const
{
   if(!m_enabled)
      return;
   ObjectsDeleteAll(m_chartId, m_prefix);
}

void CICTVisualizer::DrawSessionLevels(const ICTSessionSnapshot &session) const
{
   DrawHorizontalLine("ASIAN_HIGH", session.asianHigh, clrDodgerBlue, "Asian High");
   DrawHorizontalLine("ASIAN_LOW", session.asianLow, clrDodgerBlue, "Asian Low");
   DrawHorizontalLine("NY_AM_HIGH", session.nyAMHigh, clrDarkSlateGray, "NY AM High");
   DrawHorizontalLine("NY_AM_LOW", session.nyAMLow, clrDarkSlateGray, "NY AM Low");
}

void CICTVisualizer::DrawLiquiditySweep(const ICTLiquiditySweepSignal &sweep) const
{
   if(!m_enabled || !sweep.valid)
      return;

   string objectName = ObjectName("SWEEP_" + IntegerToString((int)sweep.time));
   if(ObjectFind(m_chartId, objectName) < 0)
      ObjectCreate(m_chartId, objectName, OBJ_ARROW, 0, sweep.time, sweep.sweepExtreme);
   ObjectSetInteger(m_chartId, objectName, OBJPROP_ARROWCODE, sweep.bullishIntent ? 233 : 234);
   ObjectSetInteger(m_chartId, objectName, OBJPROP_COLOR, sweep.bullishIntent ? clrLimeGreen : clrTomato);
}

void CICTVisualizer::DrawOrderBlock(const ICTOrderBlockZone &zone, const string label) const
{
   if(!m_enabled || !zone.valid)
      return;

   color blockColor = zone.bullish ? clrForestGreen : clrIndianRed;
   ENUM_LINE_STYLE style = (zone.kind == ICT_OB_BREAKER) ? STYLE_DASH : STYLE_SOLID;
   DrawRectangle("OB_" + label + "_" + IntegerToString((int)zone.formedTime),
                 zone.formedTime,
                 TimeCurrent(),
                 zone.low,
                 zone.high,
                 blockColor,
                 style);
}

void CICTVisualizer::DrawFVG(const ICTFVGZone &zone, const string label) const
{
   if(!m_enabled || !zone.valid)
      return;

   color gapColor = zone.bullish ? clrAqua : clrOrange;
   DrawRectangle("FVG_" + label + "_" + IntegerToString((int)zone.formedTime),
                 zone.formedTime,
                 TimeCurrent(),
                 zone.low,
                 zone.high,
                 gapColor,
                 STYLE_SOLID);
}

void CICTVisualizer::DrawBPR(const ICTBPRZone &zone) const
{
   if(!m_enabled || !zone.valid)
      return;

   DrawRectangle("BPR_" + IntegerToString((int)zone.bullishFVGTime),
                 zone.bullishFVGTime,
                 TimeCurrent(),
                 zone.low,
                 zone.high,
                 clrKhaki,
                 STYLE_DOT);
}

void CICTVisualizer::DrawTradePlan(const bool bullish,
                                   const double entry,
                                   const double stopLoss,
                                   const double tp1,
                                   const double tp2,
                                   const double tp3) const
{
   DrawHorizontalLine("ENTRY", entry, bullish ? clrLime : clrRed, "Entry");
   DrawHorizontalLine("SL", stopLoss, clrFireBrick, "SL");
   DrawHorizontalLine("TP1", tp1, clrSeaGreen, "TP1");
   DrawHorizontalLine("TP2", tp2, clrSeaGreen, "TP2");
   DrawHorizontalLine("TP3", tp3, clrSeaGreen, "TP3");
}

// ============================================================
// Phase 8 implementations
// ============================================================

void CICTVisualizer::DrawNDOGLines(const SOpeningGap &gap) const
{
   if(!m_enabled || gap.gapHigh <= 0.0 || gap.gapLow <= 0.0)
      return;
   string n = ObjectName("NDOG_HIGH_" + IntegerToString((int)gap.gapTime));
   if(ObjectFind(m_chartId, n) < 0)
      ObjectCreate(m_chartId, n, OBJ_HLINE, 0, 0, gap.gapHigh);
   ObjectSetDouble (m_chartId, n, OBJPROP_PRICE, gap.gapHigh);
   ObjectSetInteger(m_chartId, n, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(m_chartId, n, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetString (m_chartId, n, OBJPROP_TEXT,  "NDOG High");

   string s = ObjectName("NDOG_LOW_" + IntegerToString((int)gap.gapTime));
   if(ObjectFind(m_chartId, s) < 0)
      ObjectCreate(m_chartId, s, OBJ_HLINE, 0, 0, gap.gapLow);
   ObjectSetDouble (m_chartId, s, OBJPROP_PRICE, gap.gapLow);
   ObjectSetInteger(m_chartId, s, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(m_chartId, s, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetString (m_chartId, s, OBJPROP_TEXT,  "NDOG Low");
}

void CICTVisualizer::DrawNWOGLines(const SOpeningGap &gap) const
{
   if(!m_enabled || gap.gapHigh <= 0.0 || gap.gapLow <= 0.0)
      return;
   string n = ObjectName("NWOG_HIGH_" + IntegerToString((int)gap.gapTime));
   if(ObjectFind(m_chartId, n) < 0)
      ObjectCreate(m_chartId, n, OBJ_HLINE, 0, 0, gap.gapHigh);
   ObjectSetDouble (m_chartId, n, OBJPROP_PRICE, gap.gapHigh);
   ObjectSetInteger(m_chartId, n, OBJPROP_COLOR, clrOrchid);
   ObjectSetInteger(m_chartId, n, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetString (m_chartId, n, OBJPROP_TEXT,  "NWOG High");

   string s = ObjectName("NWOG_LOW_" + IntegerToString((int)gap.gapTime));
   if(ObjectFind(m_chartId, s) < 0)
      ObjectCreate(m_chartId, s, OBJ_HLINE, 0, 0, gap.gapLow);
   ObjectSetDouble (m_chartId, s, OBJPROP_PRICE, gap.gapLow);
   ObjectSetInteger(m_chartId, s, OBJPROP_COLOR, clrOrchid);
   ObjectSetInteger(m_chartId, s, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetString (m_chartId, s, OBJPROP_TEXT,  "NWOG Low");
}

void CICTVisualizer::DrawPO3Box(const ENUM_PO3_PHASE phase,
                                const datetime t1, const datetime t2,
                                const double high, const double low) const
{
   if(!m_enabled || t1 <= 0 || t2 <= 0 || high <= low)
      return;
   string label;
   color  boxColor;
   switch(phase)
   {
      case PO3_ACCUMULATION:  label = "ACCUM";  boxColor = clrSlateGray;  break;
      case PO3_MANIPULATION:  label = "MANIP";  boxColor = clrTomato;     break;
      case PO3_DISTRIBUTION:  label = "DIST";   boxColor = clrLimeGreen;  break;
      default:                label = "PO3";    boxColor = clrSilver;     break;
   }
   DrawRectangle("PO3_" + label + "_" + IntegerToString((int)t1),
                 t1, t2, low, high, boxColor, STYLE_DASH);
}

void CICTVisualizer::DrawJudasMarker(const SJudasSwing &js) const
{
   if(!m_enabled || !js.detected || js.manipulationTime <= 0)
      return;
   double arrowPrice = js.isBullishJudas ? js.manipulationLow : js.manipulationHigh;
   string name = ObjectName("JUDAS_" + IntegerToString((int)js.manipulationTime));
   if(ObjectFind(m_chartId, name) < 0)
      ObjectCreate(m_chartId, name, OBJ_ARROW, 0, js.manipulationTime, arrowPrice);
   ObjectSetInteger(m_chartId, name, OBJPROP_ARROWCODE, js.isBullishJudas ? 233 : 234);
   ObjectSetInteger(m_chartId, name, OBJPROP_COLOR,     clrGold);
   ObjectSetString (m_chartId, name, OBJPROP_TEXT,
                    js.isBullishJudas ? "Judas Buy" : "Judas Sell");
}

void CICTVisualizer::DrawIPDALevels(const SIPDARange &range) const
{
   if(!m_enabled || range.computedAt <= 0)
      return;
   // 20-bar levels (lightest)
   DrawHorizontalLine("IPDA_H20", range.high20, clrAqua,           "IPDA 20 High");
   DrawHorizontalLine("IPDA_L20", range.low20,  clrAqua,           "IPDA 20 Low");
   // 40-bar levels (medium)
   DrawHorizontalLine("IPDA_H40", range.high40, clrCornflowerBlue, "IPDA 40 High");
   DrawHorizontalLine("IPDA_L40", range.low40,  clrCornflowerBlue, "IPDA 40 Low");
   // 60-bar levels (darkest)
   DrawHorizontalLine("IPDA_H60", range.high60, clrMediumBlue,     "IPDA 60 High");
   DrawHorizontalLine("IPDA_L60", range.low60,  clrMediumBlue,     "IPDA 60 Low");
   // Equilibrium dashes
   DrawHorizontalLine("IPDA_EQ20", range.equilibrium20, clrAqua,           "EQ 20");
   DrawHorizontalLine("IPDA_EQ40", range.equilibrium40, clrCornflowerBlue, "EQ 40");
   DrawHorizontalLine("IPDA_EQ60", range.equilibrium60, clrMediumBlue,     "EQ 60");
}

void CICTVisualizer::DrawDOWPhaseLabel(const ENUM_DOW_PHASE phase) const
{
   if(!m_enabled)
      return;
   string text = "";
   switch(phase)
   {
      case DOW_MONDAY:    text = "MON"; break;
      case DOW_TUESDAY:   text = "TUE"; break;
      case DOW_WEDNESDAY: text = "WED"; break;
      case DOW_THURSDAY:  text = "THU"; break;
      case DOW_FRIDAY:    text = "FRI"; break;
      case DOW_WEEKEND:   text = "WKD"; break;
      default:            text = "---"; break;
   }
   string name = ObjectName("DOW_LABEL");
   if(ObjectFind(m_chartId, name) < 0)
      ObjectCreate(m_chartId, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(m_chartId, name, OBJPROP_CORNER, CORNER_TOP_RIGHT);
   ObjectSetInteger(m_chartId, name, OBJPROP_XDISTANCE, 5);
   ObjectSetInteger(m_chartId, name, OBJPROP_YDISTANCE, 20);
   ObjectSetString (m_chartId, name, OBJPROP_TEXT, "DOW: " + text);
   ObjectSetInteger(m_chartId, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(m_chartId, name, OBJPROP_FONTSIZE, 10);
}

void CICTVisualizer::DrawSMTMarker(const SSMTDivergence &smt) const
{
   if(!m_enabled || !smt.detected)
      return;
   datetime t  = (smt.detectedAt > 0) ? smt.detectedAt : TimeCurrent();
   double price = smt.isBullishSMT ? smt.eurSwingLevel - (_Point * 50)
                                   : smt.eurSwingLevel + (_Point * 50);
   string name = ObjectName("SMT_" + IntegerToString((int)t));
   if(ObjectFind(m_chartId, name) < 0)
      ObjectCreate(m_chartId, name, OBJ_TEXT, 0, t, price);
   ObjectSetString (m_chartId, name, OBJPROP_TEXT,
                    smt.isBullishSMT ? "SMT ^" : "SMT v");
   ObjectSetInteger(m_chartId, name, OBJPROP_COLOR, clrMagenta);
   ObjectSetInteger(m_chartId, name, OBJPROP_FONTSIZE, 9);
}

#endif // __ICT_VISUALIZER_MQH__
