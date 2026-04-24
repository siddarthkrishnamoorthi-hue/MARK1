//+------------------------------------------------------------------+
//| ICT_Session.mqh                                                   |
//| MARK1 ICT Expert Advisor — Session, killzone, PO3, news blocking |
//| Copyright 2024-2025, MARK1 Project                               |
//+------------------------------------------------------------------+
#pragma once
#ifndef __ICT_SESSION_MQH__
#define __ICT_SESSION_MQH__

#include "ICT_Constants.mqh"

/// London Close session window constants (GMT hours)
#define LONDON_CLOSE_START_GMT  14   ///< 14:00 GMT
#define LONDON_CLOSE_END_GMT    15   ///< 15:00 GMT

enum ENUM_ICT_SESSION_WINDOW
{
   ICT_SESSION_NONE = 0,
   ICT_SESSION_ASIAN,
   ICT_SESSION_LONDON_KZ,
   ICT_SESSION_LONDON_SB,
   ICT_SESSION_LONDON_CLOSE,   ///< London Close window 14:00-15:00 GMT
   ICT_SESSION_NY_AM_KZ,
   ICT_SESSION_NY_SB_AM,
   ICT_SESSION_NY_SB_PM,
   ICT_SESSION_MACRO
};

/// @brief ICT Power of Three phase enumeration.
enum ENUM_PO3_PHASE
{
   PO3_ACCUMULATION,   ///< Asian range building
   PO3_MANIPULATION,   ///< Judas Swing — false move opposite true direction
   PO3_DISTRIBUTION,   ///< True institutional delivery
   PO3_UNKNOWN
};

/// @brief Judas Swing detection and confirmation state.
struct SJudasSwing
{
   bool            detected;
   bool            confirmed;           ///< True once reversal candle closes inside Asian range
   ENUM_PO3_PHASE  currentPhase;
   double          manipulationHigh;    ///< High of the false move
   double          manipulationLow;     ///< Low of the false move
   double          asianRangeHigh;
   double          asianRangeLow;
   bool            isBullishJudas;      ///< True = swept below Asian low then reversed up
   datetime        manipulationTime;
   datetime        confirmationTime;
};

/// @brief Opening Range Gap for a session.
struct SSessionORG
{
   double            gapHigh;
   double            gapLow;
   bool              isBullish;
   bool              isFilled;
   ENUM_ICT_SESSION_WINDOW session;  ///< SESSION_LONDON_KZ or SESSION_NY_AM_KZ
};

struct ICTSessionSnapshot
{
   bool                    valid;
   datetime                gmtTime;
   int                     dayKey;
   bool                    inAsian;
   bool                    inLondonKillzone;
   bool                    inLondonSilverBullet;
   bool                    inLondonCloseWindow;  ///< Phase 2: 14:00-15:00 GMT
   bool                    inNYAMKillzone;
   bool                    inNYSilverBulletAM;
   bool                    inNYSilverBulletPM;
   bool                    inMacroWindow;
   bool                    newsBlocked;
   ENUM_ICT_SESSION_WINDOW activeWindow;
   double                  asianHigh;
   double                  asianLow;
   bool                    asianRangeReady;
   double                  nyAMHigh;
   double                  nyAMLow;
   bool                    nyAMRangeReady;
   double                  midnightOpenPrice;  ///< Phase 2: 00:00 GMT open price of current day
   SJudasSwing             judasSM;            ///< Phase 4: Judas Swing state machine
};

string ICTSessionWindowToString(const ENUM_ICT_SESSION_WINDOW value)
{
   switch(value)
   {
      case ICT_SESSION_ASIAN:         return "ASIAN";
      case ICT_SESSION_LONDON_KZ:     return "LONDON_KZ";
      case ICT_SESSION_LONDON_SB:     return "LONDON_SB";
      case ICT_SESSION_LONDON_CLOSE:  return "LONDON_CLOSE";   ///< Phase 2 addition
      case ICT_SESSION_NY_AM_KZ:      return "NY_AM_KZ";
      case ICT_SESSION_NY_SB_AM:      return "NY_SB_AM";
      case ICT_SESSION_NY_SB_PM:      return "NY_SB_PM";
      case ICT_SESSION_MACRO:         return "MACRO";
      default:                        return "NONE";
   }
}

class CICTSessionEngine
{
private:
   string             m_symbol;
   ENUM_TIMEFRAMES    m_triggerTimeframe;
   int                m_gmtOffsetSeconds;
   int                m_lastDayKey;
   datetime           m_lastRangeBarTime;
   bool               m_enableNewsFilter;
   int                m_newsHaltBeforeMinutes;
   int                m_newsResumeAfterMinutes;
   ICTSessionSnapshot m_snapshot;

   bool IsWindow(const int minuteOfDay, const int startMinute, const int endMinute) const;
   int  DateToKey(const MqlDateTime &dt) const;
   int  MinuteOfDay(const MqlDateTime &dt) const;
   void ResetForDay(const MqlDateTime &dt);
   void UpdateRangeState();
   void UpdateJudasSwing(const datetime gmtTime, const int hour, const int minute);
   bool IsHardcodedNewsTime(const datetime gmtTime) const;
   bool IsNewsBlockedInternal(const datetime gmtTime) const;

public:
   CICTSessionEngine();

   void Configure(const string symbol,
                  const ENUM_TIMEFRAMES triggerTimeframe,
                  const bool enableNewsFilter = true,
                  const int newsHaltBeforeMinutes = 15,
                  const int newsResumeAfterMinutes = 5);
   datetime GetGMTTime() const;
   bool Refresh();
   bool IsTradingWindow() const;
   bool IsMacroWindow() const;
   bool IsNewsBlocked() const;
   ICTSessionSnapshot Snapshot() const;
};

CICTSessionEngine::CICTSessionEngine()
{
   m_symbol                 = _Symbol;
   m_triggerTimeframe       = PERIOD_M5;
   m_gmtOffsetSeconds       = (int)(TimeCurrent() - TimeGMT());
   m_lastDayKey             = 0;
   m_lastRangeBarTime       = 0;
   m_enableNewsFilter       = true;
   m_newsHaltBeforeMinutes  = 15;
   m_newsResumeAfterMinutes = 5;
   ZeroMemory(m_snapshot);
}

void CICTSessionEngine::Configure(const string symbol,
                                  const ENUM_TIMEFRAMES triggerTimeframe,
                                  const bool enableNewsFilter = true,
                                  const int newsHaltBeforeMinutes = 15,
                                  const int newsResumeAfterMinutes = 5)
{
   m_symbol                 = symbol;
   m_triggerTimeframe       = triggerTimeframe;
   m_gmtOffsetSeconds       = (int)(TimeCurrent() - TimeGMT());
   m_enableNewsFilter       = enableNewsFilter;
   m_newsHaltBeforeMinutes  = MathMax(newsHaltBeforeMinutes, 0);
   m_newsResumeAfterMinutes = MathMax(newsResumeAfterMinutes, 0);
}

datetime CICTSessionEngine::GetGMTTime() const
{
   return TimeCurrent() - m_gmtOffsetSeconds;
}

bool CICTSessionEngine::IsWindow(const int minuteOfDay, const int startMinute, const int endMinute) const
{
   if(startMinute <= endMinute)
      return (minuteOfDay >= startMinute && minuteOfDay < endMinute);
   return (minuteOfDay >= startMinute || minuteOfDay < endMinute);
}

int CICTSessionEngine::DateToKey(const MqlDateTime &dt) const
{
   return (dt.year * 10000) + (dt.mon * 100) + dt.day;
}

int CICTSessionEngine::MinuteOfDay(const MqlDateTime &dt) const
{
   return (dt.hour * 60) + dt.min;
}

void CICTSessionEngine::ResetForDay(const MqlDateTime &dt)
{
   m_snapshot.valid           = true;
   m_snapshot.dayKey          = DateToKey(dt);
   m_snapshot.asianHigh       = 0.0;
   m_snapshot.asianLow        = 0.0;
   m_snapshot.asianRangeReady = false;
   m_snapshot.nyAMHigh        = 0.0;
   m_snapshot.nyAMLow         = 0.0;
   m_snapshot.nyAMRangeReady  = false;
   m_snapshot.activeWindow    = ICT_SESSION_NONE;
   m_snapshot.newsBlocked     = false;
   m_lastDayKey               = m_snapshot.dayKey;
   m_lastRangeBarTime         = 0;
}

void CICTSessionEngine::UpdateRangeState()
{
   datetime lastClosedBarTime = iTime(m_symbol, m_triggerTimeframe, 1);
   if(lastClosedBarTime <= 0 || lastClosedBarTime == m_lastRangeBarTime)
      return;

   m_lastRangeBarTime = lastClosedBarTime;

   double highValue = iHigh(m_symbol, m_triggerTimeframe, 1);
   double lowValue  = iLow(m_symbol, m_triggerTimeframe, 1);
   if(highValue <= 0.0 || lowValue <= 0.0)
      return;

   if(m_snapshot.inAsian)
   {
      if(m_snapshot.asianHigh == 0.0 || highValue > m_snapshot.asianHigh)
         m_snapshot.asianHigh = highValue;
      if(m_snapshot.asianLow == 0.0 || lowValue < m_snapshot.asianLow)
         m_snapshot.asianLow = lowValue;
   }

   if(m_snapshot.inNYAMKillzone)
   {
      if(m_snapshot.nyAMHigh == 0.0 || highValue > m_snapshot.nyAMHigh)
         m_snapshot.nyAMHigh = highValue;
      if(m_snapshot.nyAMLow == 0.0 || lowValue < m_snapshot.nyAMLow)
         m_snapshot.nyAMLow = lowValue;
   }
}

bool CICTSessionEngine::IsHardcodedNewsTime(const datetime gmtTime) const
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);

   if(dt.day_of_week == 5 && dt.day <= 7)
   {
      if((dt.hour == 13 && dt.min >= 15) || dt.hour == 14)
         return true;
   }

   int fomcMonths[] = {1, 3, 5, 6, 7, 9, 11, 12};
   if(dt.day_of_week == 3)
   {
      for(int i = 0; i < ArraySize(fomcMonths); i++)
      {
         if(dt.mon == fomcMonths[i] && dt.hour >= 18 && dt.hour <= 20)
            return true;
      }
   }

   if((dt.hour == 13 || dt.hour == 14) && (dt.day_of_week == 2 || dt.day_of_week == 4))
      return true;

   return false;
}

bool CICTSessionEngine::IsNewsBlockedInternal(const datetime gmtTime) const
{
   if(!m_enableNewsFilter)
      return false;

   datetime checkFrom = gmtTime - (m_newsHaltBeforeMinutes * 60);
   datetime checkTo   = gmtTime + (m_newsResumeAfterMinutes * 60);

   // BUG FIX: USD and EUR calendar checks are now INDEPENDENT so a failed USD
   // calendar call cannot prevent EUR events from being evaluated.
   MqlCalendarValue usdValues[];
   if(CalendarValueHistory(usdValues, checkFrom, checkTo, "USD"))
   {
      for(int i = 0; i < ArraySize(usdValues); i++)
      {
         MqlCalendarEvent eventInfo;
         MqlCalendarCountry countryInfo;
         if(!CalendarEventById(usdValues[i].event_id, eventInfo))   continue;
         if(!CalendarCountryById(eventInfo.country_id, countryInfo)) continue;
         if(eventInfo.importance != CALENDAR_IMPORTANCE_HIGH)        continue;

         datetime eventTime  = usdValues[i].time;
         datetime blockStart = eventTime - (m_newsHaltBeforeMinutes * 60);
         datetime blockEnd   = eventTime + (m_newsResumeAfterMinutes * 60);
         if(gmtTime >= blockStart && gmtTime <= blockEnd)
            return true;
      }
   }

   // EUR filter — independent check (BUG FIX: was nested inside USD calendar if-block)
   MqlCalendarValue eurValues[];
   if(CalendarValueHistory(eurValues, checkFrom, checkTo, "EUR"))
   {
      for(int i = 0; i < ArraySize(eurValues); i++)
      {
         MqlCalendarEvent eventInfo;
         MqlCalendarCountry countryInfo;
         if(!CalendarEventById(eurValues[i].event_id, eventInfo))   continue;
         if(!CalendarCountryById(eventInfo.country_id, countryInfo)) continue;
         if(eventInfo.importance != CALENDAR_IMPORTANCE_HIGH)        continue;

         datetime eventTime  = eurValues[i].time;
         datetime blockStart = eventTime - (m_newsHaltBeforeMinutes * 60);
         datetime blockEnd   = eventTime + (m_newsResumeAfterMinutes * 60);
         if(gmtTime >= blockStart && gmtTime <= blockEnd)
         {
            Print("[MARK1][NEWS] EUR filter active — event blocked trading at ",
                  TimeToString(eventTime, TIME_DATE|TIME_MINUTES));
            return true;
         }
      }
   }

   return IsHardcodedNewsTime(gmtTime);
}

bool CICTSessionEngine::Refresh()
{
   m_gmtOffsetSeconds = (int)(TimeCurrent() - TimeGMT());
   datetime gmtTime   = GetGMTTime();
   MqlDateTime gmtDt;
   TimeToStruct(gmtTime, gmtDt);

   int currentDayKey = DateToKey(gmtDt);
   if(currentDayKey != m_lastDayKey)
   {
      ResetForDay(gmtDt);
      // Compute Midnight Open Price (00:00 GMT candle) on new day
      datetime midnightGMT = iTime(m_symbol, PERIOD_D1, 0);
      int shift = iBarShift(m_symbol, m_triggerTimeframe, midnightGMT, false);
      m_snapshot.midnightOpenPrice = (shift >= 0) ? iOpen(m_symbol, m_triggerTimeframe, shift) : 0.0;
   }

   int minuteOfDay = MinuteOfDay(gmtDt);
   m_snapshot.gmtTime               = gmtTime;
   m_snapshot.inAsian               = IsWindow(minuteOfDay, 60, 300);
   m_snapshot.inLondonKillzone      = IsWindow(minuteOfDay, 420, 600);
   m_snapshot.inLondonSilverBullet  = IsWindow(minuteOfDay, 480, 540);
   m_snapshot.inLondonCloseWindow   = IsWindow(minuteOfDay,
                                               LONDON_CLOSE_START_GMT * 60,
                                               LONDON_CLOSE_END_GMT   * 60);
   m_snapshot.inNYAMKillzone        = IsWindow(minuteOfDay, 720, 900);
   m_snapshot.inNYSilverBulletAM    = IsWindow(minuteOfDay, 900, 960);
   m_snapshot.inNYSilverBulletPM    = IsWindow(minuteOfDay, 1140, 1200);

   bool macroLondonPre  = IsWindow(minuteOfDay, 453, 480);
   bool macroLondonPost = IsWindow(minuteOfDay, 543, 570);
   bool macroPreNY      = IsWindow(minuteOfDay, 830, 850);
   bool macroNYOpen     = IsWindow(minuteOfDay, 890, 910);
   bool macroSBClose    = IsWindow(minuteOfDay, 950, 970);
   m_snapshot.inMacroWindow = (macroLondonPre || macroLondonPost || macroPreNY || macroNYOpen || macroSBClose);
   m_snapshot.newsBlocked   = IsNewsBlockedInternal(gmtTime);

   m_snapshot.activeWindow = ICT_SESSION_NONE;
   if(m_snapshot.inLondonSilverBullet)
      m_snapshot.activeWindow = ICT_SESSION_LONDON_SB;
   else if(m_snapshot.inNYSilverBulletAM)
      m_snapshot.activeWindow = ICT_SESSION_NY_SB_AM;
   else if(m_snapshot.inNYSilverBulletPM)
      m_snapshot.activeWindow = ICT_SESSION_NY_SB_PM;
   else if(m_snapshot.inLondonCloseWindow)
      m_snapshot.activeWindow = ICT_SESSION_LONDON_CLOSE;
   else if(m_snapshot.inLondonKillzone)
      m_snapshot.activeWindow = ICT_SESSION_LONDON_KZ;
   else if(m_snapshot.inNYAMKillzone)
      m_snapshot.activeWindow = ICT_SESSION_NY_AM_KZ;
   else if(m_snapshot.inAsian)
      m_snapshot.activeWindow = ICT_SESSION_ASIAN;
   else if(m_snapshot.inMacroWindow)
      m_snapshot.activeWindow = ICT_SESSION_MACRO;

   UpdateRangeState();

   if(!m_snapshot.inAsian && m_snapshot.asianHigh > 0.0 && m_snapshot.asianLow > 0.0)
      m_snapshot.asianRangeReady = true;

   if(!m_snapshot.inNYAMKillzone && m_snapshot.nyAMHigh > 0.0 && m_snapshot.nyAMLow > 0.0)
      m_snapshot.nyAMRangeReady = true;

   // Judas Swing state machine (Phase 4)
   UpdateJudasSwing(gmtTime, gmtDt.hour, gmtDt.min);

   return true;
}

bool CICTSessionEngine::IsTradingWindow() const
{
   return (m_snapshot.inLondonKillzone || m_snapshot.inLondonSilverBullet ||
           m_snapshot.inNYAMKillzone   || m_snapshot.inNYSilverBulletAM ||
           m_snapshot.inNYSilverBulletPM || m_snapshot.inMacroWindow);
}

bool CICTSessionEngine::IsMacroWindow() const
{
   return m_snapshot.inMacroWindow;
}

bool CICTSessionEngine::IsNewsBlocked() const
{
   return m_snapshot.newsBlocked;
}

ICTSessionSnapshot CICTSessionEngine::Snapshot() const
{
   return m_snapshot;
}

/// @brief Updates the Judas Swing state machine. Called every tick from Refresh().
void CICTSessionEngine::UpdateJudasSwing(const datetime gmtTime, const int hour, const int minute)
{
   SJudasSwing &js = m_snapshot.judasSM;

   // Reset Judas state when Asian range is not yet ready
   if(!m_snapshot.asianRangeReady)
   {
      js.asianRangeHigh = m_snapshot.asianHigh;
      js.asianRangeLow  = m_snapshot.asianLow;
      js.currentPhase   = PO3_ACCUMULATION;
      return;
   }

   // Capture Asian range boundaries once available
   if(js.asianRangeHigh == 0.0)
   {
      js.asianRangeHigh = m_snapshot.asianHigh;
      js.asianRangeLow  = m_snapshot.asianLow;
   }

   // Only evaluate Judas manipulation during London Killzone 07:00-08:30 GMT
   int minuteOfDay = hour * 60 + minute;
   bool inLondonManipWindow = (minuteOfDay >= 420 && minuteOfDay < 510); // 07:00-08:30

   if(!inLondonManipWindow || js.confirmed)
      return;

   js.currentPhase = PO3_MANIPULATION;

   double currentHigh = iHigh(m_symbol, m_triggerTimeframe, 0);
   double currentLow  = iLow (m_symbol, m_triggerTimeframe, 0);

   // Detect sweep of Asian range extremes during London manipulation window
   if(!js.detected)
   {
      if(currentLow < js.asianRangeLow)
      {
         js.detected          = true;
         js.isBullishJudas    = true;   // swept below → expect reversal UP
         js.manipulationLow   = currentLow;
         js.manipulationTime  = gmtTime;
      }
      else if(currentHigh > js.asianRangeHigh)
      {
         js.detected          = true;
         js.isBullishJudas    = false;  // swept above → expect reversal DOWN
         js.manipulationHigh  = currentHigh;
         js.manipulationTime  = gmtTime;
      }
      return;
   }

   // Confirmation: a M15 candle closes BACK INSIDE the Asian range
   double lastClose = iClose(m_symbol, PERIOD_M15, 1);
   if(js.isBullishJudas)
   {
      if(lastClose > js.asianRangeLow)
      {
         js.confirmed         = true;
         js.currentPhase      = PO3_DISTRIBUTION;
         js.confirmationTime  = iTime(m_symbol, PERIOD_M15, 1);
      }
   }
   else
   {
      if(lastClose < js.asianRangeHigh)
      {
         js.confirmed         = true;
         js.currentPhase      = PO3_DISTRIBUTION;
         js.confirmationTime  = iTime(m_symbol, PERIOD_M15, 1);
      }
   }
}

/// @brief Returns the Midnight Open Price (00:00 GMT candle open).
double GetMidnightOpen(const string symbol, const ENUM_TIMEFRAMES tf)
{
   datetime midnightGMT = iTime(symbol, PERIOD_D1, 0);
   int shift = iBarShift(symbol, tf, midnightGMT, false);
   if(shift < 0) return 0.0;
   return iOpen(symbol, tf, shift);
}

/// @brief Returns true if gmtTime falls within the London Close window.
bool IsLondonCloseWindow(const datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);
   return (dt.hour >= LONDON_CLOSE_START_GMT && dt.hour < LONDON_CLOSE_END_GMT);
}

/// @brief Computes the London session Opening Range Gap (last M15 close before 07:00 vs first open at 07:00).
SSessionORG ComputeLondonORG(const string symbol)
{
   SSessionORG org;
   ZeroMemory(org);
   org.session = ICT_SESSION_LONDON_KZ;

   // Find the M15 bar that opens at 07:00 GMT
   datetime londonOpen = iTime(symbol, PERIOD_D1, 0)
                         + (datetime)(7 * 3600);  // 07:00 GMT of current day
   int openShift  = iBarShift(symbol, PERIOD_M15, londonOpen, false);
   if(openShift < 0) return org;

   double openPrice  = iOpen (symbol, PERIOD_M15, openShift);
   double prevClose  = iClose(symbol, PERIOD_M15, openShift + 1);
   if(openPrice <= 0.0 || prevClose <= 0.0) return org;

   org.isBullish = (openPrice > prevClose);
   org.gapHigh   = MathMax(openPrice, prevClose);
   org.gapLow    = MathMin(openPrice, prevClose);

   // Mark filled if current price has crossed both boundaries
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   org.isFilled = (org.isBullish ? bid <= org.gapLow : bid >= org.gapHigh);
   return org;
}

/// @brief Computes the NY AM session Opening Range Gap (last M15 close before 12:00 vs first open at 12:00).
SSessionORG ComputeNYORG(const string symbol)
{
   SSessionORG org;
   ZeroMemory(org);
   org.session = ICT_SESSION_NY_AM_KZ;

   datetime nyOpen   = iTime(symbol, PERIOD_D1, 0)
                       + (datetime)(12 * 3600);  // 12:00 GMT
   int openShift  = iBarShift(symbol, PERIOD_M15, nyOpen, false);
   if(openShift < 0) return org;

   double openPrice  = iOpen (symbol, PERIOD_M15, openShift);
   double prevClose  = iClose(symbol, PERIOD_M15, openShift + 1);
   if(openPrice <= 0.0 || prevClose <= 0.0) return org;

   org.isBullish = (openPrice > prevClose);
   org.gapHigh   = MathMax(openPrice, prevClose);
   org.gapLow    = MathMin(openPrice, prevClose);

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   org.isFilled = (org.isBullish ? bid <= org.gapLow : bid >= org.gapHigh);
   return org;
}

#endif // __ICT_SESSION_MQH__
