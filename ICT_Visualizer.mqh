//+------------------------------------------------------------------+
//| ICT_Visualizer.mqh                                               |
//| Lightweight chart rendering for ICT zones and session levels     |
//+------------------------------------------------------------------+
#ifndef __ICT_VISUALIZER_MQH__
#define __ICT_VISUALIZER_MQH__

#include "ICT_Session.mqh"
#include "ICT_Liquidity.mqh"
#include "ICT_OrderBlock.mqh"
#include "ICT_FVG.mqh"

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

#endif // __ICT_VISUALIZER_MQH__
