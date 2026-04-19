//+------------------------------------------------------------------+
//| ICT_Session.mqh                                                  |
//| Session, killzone, macro, PO3, and news-block tracking           |
//+------------------------------------------------------------------+
#ifndef __ICT_SESSION_MQH__
#define __ICT_SESSION_MQH__

enum ENUM_ICT_SESSION_WINDOW
{
   ICT_SESSION_NONE = 0,
   ICT_SESSION_ASIAN,
   ICT_SESSION_LONDON_KZ,
   ICT_SESSION_LONDON_SB,
   ICT_SESSION_NY_AM_KZ,
   ICT_SESSION_NY_SB_AM,
   ICT_SESSION_NY_SB_PM,
   ICT_SESSION_MACRO
};

struct ICTSessionSnapshot
{
   bool                    valid;
   datetime                gmtTime;
   int                     dayKey;
   bool                    inAsian;
   bool                    inLondonKillzone;
   bool                    inLondonSilverBullet;
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
};

string ICTSessionWindowToString(const ENUM_ICT_SESSION_WINDOW value)
{
   switch(value)
   {
      case ICT_SESSION_ASIAN:      return "ASIAN";
      case ICT_SESSION_LONDON_KZ:  return "LONDON_KZ";
      case ICT_SESSION_LONDON_SB:  return "LONDON_SB";
      case ICT_SESSION_NY_AM_KZ:   return "NY_AM_KZ";
      case ICT_SESSION_NY_SB_AM:   return "NY_SB_AM";
      case ICT_SESSION_NY_SB_PM:   return "NY_SB_PM";
      case ICT_SESSION_MACRO:      return "MACRO";
      default:                     return "NONE";
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

   MqlCalendarValue usdValues[];
   bool calendarOk = CalendarValueHistory(usdValues, checkFrom, checkTo, "USD");
   if(calendarOk)
   {
      for(int i = 0; i < ArraySize(usdValues); i++)
      {
         MqlCalendarEvent eventInfo;
         MqlCalendarCountry countryInfo;
         if(!CalendarEventById(usdValues[i].event_id, eventInfo))
            continue;
         if(!CalendarCountryById(eventInfo.country_id, countryInfo))
            continue;
         if(eventInfo.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;

         string currency = countryInfo.currency;
         if(currency != "USD" && currency != "EUR")
            continue;

         datetime eventTime  = usdValues[i].time;
         datetime blockStart = eventTime - (m_newsHaltBeforeMinutes * 60);
         datetime blockEnd   = eventTime + (m_newsResumeAfterMinutes * 60);
         if(gmtTime >= blockStart && gmtTime <= blockEnd)
            return true;
      }

      MqlCalendarValue eurValues[];
      if(CalendarValueHistory(eurValues, checkFrom, checkTo, "EUR"))
      {
         for(int i = 0; i < ArraySize(eurValues); i++)
         {
            MqlCalendarEvent eventInfo;
            MqlCalendarCountry countryInfo;
            if(!CalendarEventById(eurValues[i].event_id, eventInfo))
               continue;
            if(!CalendarCountryById(eventInfo.country_id, countryInfo))
               continue;
            if(eventInfo.importance != CALENDAR_IMPORTANCE_HIGH)
               continue;

            datetime eventTime  = eurValues[i].time;
            datetime blockStart = eventTime - (m_newsHaltBeforeMinutes * 60);
            datetime blockEnd   = eventTime + (m_newsResumeAfterMinutes * 60);
            if(gmtTime >= blockStart && gmtTime <= blockEnd)
               return true;
         }
      }

      return false;
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
      ResetForDay(gmtDt);

   int minuteOfDay = MinuteOfDay(gmtDt);
   m_snapshot.gmtTime               = gmtTime;
   m_snapshot.inAsian               = IsWindow(minuteOfDay, 60, 300);
   m_snapshot.inLondonKillzone      = IsWindow(minuteOfDay, 420, 600);
   m_snapshot.inLondonSilverBullet  = IsWindow(minuteOfDay, 480, 540);
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

#endif // __ICT_SESSION_MQH__
