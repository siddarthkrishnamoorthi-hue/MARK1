//+------------------------------------------------------------------+
//| ICT_RiskManager.mqh                                              |
//| Fixed-risk sizing, funded-account limits, pending-order control  |
//+------------------------------------------------------------------+
#ifndef __ICT_RISKMANAGER_MQH__
#define __ICT_RISKMANAGER_MQH__

#include <Trade\Trade.mqh>
#include "ICT_Structure.mqh"

struct ICTRiskSnapshot
{
   bool     valid;
   int      dayKey;
   int      weekKey;
   double   dayStartEquity;
   double   weekStartEquity;
   double   dailyLossPct;
   double   weeklyDrawdownPct;
   bool     dailyBlocked;
   bool     weeklyBlocked;
};

struct ICTPendingTargetState
{
   bool     active;
   ulong    orderTicket;
   bool     bullish;
   double   tp1;
   double   tp2;
   double   tp3;
   double   initialVolume;
   datetime createdTime;
};

struct ICTPositionTargetState
{
   bool     active;
   ulong    positionTicket;
   bool     bullish;
   double   tp1;
   double   tp2;
   double   tp3;
   double   initialVolume;
   int      stage;
};

class CICTRiskManager
{
private:
   string                   m_symbol;
   long                     m_magicNumber;
   double                   m_riskPercent;
   int                      m_maxTrades;
   double                   m_dailyMaxLossPct;
   double                   m_weeklyMaxDDPct;
   int                      m_pendingExpiryBars;
   double                   m_breakEvenBufferPips;
   bool                     m_enableTrailing;
   ENUM_TIMEFRAMES          m_triggerTimeframe;
   double                   m_pointSize;
   double                   m_pipSize;
   ICTRiskSnapshot          m_snapshot;
   ICTPendingTargetState    m_pendingStates[];
   ICTPositionTargetState   m_positionStates[];

   int  CurrentDayKey() const;
   int  CurrentWeekKey() const;
   void ResetDay();
   void ResetWeek();
   bool OrderExists(const ulong ticket) const;
   bool PositionExists(const ulong ticket) const;
   int  FindPendingStateIndex(const ulong orderTicket) const;
   int  FindPositionStateIndex(const ulong positionTicket) const;
   double NormalizeVolume(const double volume) const;
   double ResolveTrailStop(const bool bullish,
                           CICTStructureEngine &structureEngine,
                           const double currentSL) const;
   void CleanupStates();

public:
   CICTRiskManager();

   void Configure(const string symbol,
                  const long magicNumber,
                  const double riskPercent,
                  const int maxTrades,
                  const double dailyMaxLossPct,
                  const double weeklyMaxDDPct,
                  const int pendingExpiryBars,
                  const double breakEvenBufferPips,
                  const bool enableTrailing,
                  const ENUM_TIMEFRAMES triggerTimeframe);
   bool Refresh();
   ICTRiskSnapshot Snapshot() const;
   bool CanTrade(string &reason) const;
   int  CountManagedPositions() const;
   int  CountManagedPendingOrders() const;
   int  CountManagedExposure() const;
   double CalculatePositionSize(const double entryPrice,
                                const double stopLoss,
                                const double riskWeightPct = 100.0) const;
   bool PlaceLimitOrder(CTrade &trade,
                        const bool bullish,
                        const double entryPrice,
                        const double stopLoss,
                        const double takeProfit,
                        const double tp1,
                        const double tp2,
                        const double riskWeightPct,
                        const string tag,
                        ulong &ticket);
   bool CancelAllPending(CTrade &trade, const string reason = "");
   void CancelExpiredPendingOrders(CTrade &trade);
   void OnTradeTransaction(const MqlTradeTransaction &trans);
   void ManageOpenPositions(CTrade &trade,
                            CICTStructureEngine &m15Structure,
                            CICTStructureEngine &m5Structure);
};

CICTRiskManager::CICTRiskManager()
{
   m_symbol              = _Symbol;
   m_magicNumber         = 0;
   m_riskPercent         = 0.25;
   m_maxTrades           = 1;
   m_dailyMaxLossPct     = 3.0;
   m_weeklyMaxDDPct      = 6.0;
   m_pendingExpiryBars   = 8;
   m_breakEvenBufferPips = 1.0;
   m_enableTrailing      = true;
   m_triggerTimeframe    = PERIOD_M5;
   m_pointSize           = _Point;
   m_pipSize             = _Point;
   ZeroMemory(m_snapshot);
   ArrayResize(m_pendingStates, 0);
   ArrayResize(m_positionStates, 0);
}

void CICTRiskManager::Configure(const string symbol,
                                const long magicNumber,
                                const double riskPercent,
                                const int maxTrades,
                                const double dailyMaxLossPct,
                                const double weeklyMaxDDPct,
                                const int pendingExpiryBars,
                                const double breakEvenBufferPips,
                                const bool enableTrailing,
                                const ENUM_TIMEFRAMES triggerTimeframe)
{
   m_symbol              = symbol;
   m_magicNumber         = magicNumber;
   m_riskPercent         = MathMin(MathMax(riskPercent, 0.01), 5.0);
   m_maxTrades           = MathMax(maxTrades, 1);
   m_dailyMaxLossPct     = MathMax(dailyMaxLossPct, 0.1);
   m_weeklyMaxDDPct      = MathMax(weeklyMaxDDPct, 0.1);
   m_pendingExpiryBars   = MathMax(pendingExpiryBars, 1);
   m_breakEvenBufferPips = MathMax(breakEvenBufferPips, 0.0);
   m_enableTrailing      = enableTrailing;
   m_triggerTimeframe    = triggerTimeframe;
   m_pointSize           = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   int digits            = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   m_pipSize             = ((digits == 3 || digits == 5) ? m_pointSize * 10.0 : m_pointSize);
}

int CICTRiskManager::CurrentDayKey() const
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.year * 10000) + (dt.mon * 100) + dt.day;
}

int CICTRiskManager::CurrentWeekKey() const
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.year * 100) + dt.day_of_year / 7;
}

void CICTRiskManager::ResetDay()
{
   m_snapshot.dayKey         = CurrentDayKey();
   m_snapshot.dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   m_snapshot.dailyLossPct   = 0.0;
   m_snapshot.dailyBlocked   = false;
}

void CICTRiskManager::ResetWeek()
{
   m_snapshot.weekKey           = CurrentWeekKey();
   m_snapshot.weekStartEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
   m_snapshot.weeklyDrawdownPct = 0.0;
   m_snapshot.weeklyBlocked     = false;
}

bool CICTRiskManager::OrderExists(const ulong ticket) const
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong currentTicket = OrderGetTicket(i);
      if(currentTicket == 0 || currentTicket != ticket)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != m_symbol)
         return false;
      if((long)OrderGetInteger(ORDER_MAGIC) != m_magicNumber)
         return false;
      return true;
   }
   return false;
}

bool CICTRiskManager::PositionExists(const ulong ticket) const
{
   if(!PositionSelectByTicket(ticket))
      return false;
   if(PositionGetString(POSITION_SYMBOL) != m_symbol)
      return false;
   if((long)PositionGetInteger(POSITION_MAGIC) != m_magicNumber)
      return false;
   return true;
}

int CICTRiskManager::FindPendingStateIndex(const ulong orderTicket) const
{
   for(int i = 0; i < ArraySize(m_pendingStates); i++)
   {
      if(m_pendingStates[i].active && m_pendingStates[i].orderTicket == orderTicket)
         return i;
   }
   return -1;
}

int CICTRiskManager::FindPositionStateIndex(const ulong positionTicket) const
{
   for(int i = 0; i < ArraySize(m_positionStates); i++)
   {
      if(m_positionStates[i].active && m_positionStates[i].positionTicket == positionTicket)
         return i;
   }
   return -1;
}

double CICTRiskManager::NormalizeVolume(const double volume) const
{
   double minLot  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0.0)
      lotStep = 0.01;

   double normalized = MathFloor(volume / lotStep) * lotStep;
   normalized        = NormalizeDouble(normalized, 2);
   normalized        = MathMax(normalized, minLot);
   normalized        = MathMin(normalized, maxLot);
   return normalized;
}

double CICTRiskManager::ResolveTrailStop(const bool bullish,
                                         CICTStructureEngine &structureEngine,
                                         const double currentSL) const
{
   ICTStructureSnapshot snapshot;
   ZeroMemory(snapshot);
   if(!structureEngine.BuildSnapshot(snapshot))
      return currentSL;

   double buffer = m_breakEvenBufferPips * m_pipSize;
   if(bullish && snapshot.latestLow.valid)
      return MathMax(currentSL, snapshot.latestLow.price - buffer);
   if(!bullish && snapshot.latestHigh.valid)
      return MathMin(currentSL, snapshot.latestHigh.price + buffer);
   return currentSL;
}

void CICTRiskManager::CleanupStates()
{
   for(int i = ArraySize(m_pendingStates) - 1; i >= 0; i--)
   {
      if(!m_pendingStates[i].active || !OrderExists(m_pendingStates[i].orderTicket))
      {
         if(i < ArraySize(m_pendingStates) - 1)
            m_pendingStates[i] = m_pendingStates[ArraySize(m_pendingStates) - 1];
         ArrayResize(m_pendingStates, ArraySize(m_pendingStates) - 1);
      }
   }

   for(int i = ArraySize(m_positionStates) - 1; i >= 0; i--)
   {
      if(!m_positionStates[i].active || !PositionExists(m_positionStates[i].positionTicket))
      {
         if(i < ArraySize(m_positionStates) - 1)
            m_positionStates[i] = m_positionStates[ArraySize(m_positionStates) - 1];
         ArrayResize(m_positionStates, ArraySize(m_positionStates) - 1);
      }
   }
}

bool CICTRiskManager::Refresh()
{
   if(!m_snapshot.valid)
   {
      m_snapshot.valid = true;
      ResetDay();
      ResetWeek();
   }

   if(m_snapshot.dayKey != CurrentDayKey())
      ResetDay();
   if(m_snapshot.weekKey != CurrentWeekKey())
      ResetWeek();

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(m_snapshot.dayStartEquity > 0.0)
   {
      m_snapshot.dailyLossPct = MathMax(0.0, ((m_snapshot.dayStartEquity - equity) / m_snapshot.dayStartEquity) * 100.0);
      m_snapshot.dailyBlocked = (m_snapshot.dailyLossPct >= m_dailyMaxLossPct);
   }
   if(m_snapshot.weekStartEquity > 0.0)
   {
      m_snapshot.weeklyDrawdownPct = MathMax(0.0, ((m_snapshot.weekStartEquity - equity) / m_snapshot.weekStartEquity) * 100.0);
      m_snapshot.weeklyBlocked     = (m_snapshot.weeklyDrawdownPct >= m_weeklyMaxDDPct);
   }

   CleanupStates();
   return true;
}

ICTRiskSnapshot CICTRiskManager::Snapshot() const
{
   return m_snapshot;
}

bool CICTRiskManager::CanTrade(string &reason) const
{
   reason = "";

   if(m_snapshot.dailyBlocked)
   {
      reason = "daily max loss reached";
      return false;
   }
   if(m_snapshot.weeklyBlocked)
   {
      reason = "weekly max drawdown reached";
      return false;
   }
   if(CountManagedExposure() >= m_maxTrades)
   {
      reason = "max exposure reached";
      return false;
   }

   return true;
}

int CICTRiskManager::CountManagedPositions() const
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != m_magicNumber)
         continue;
      count++;
   }
   return count;
}

int CICTRiskManager::CountManagedPendingOrders() const
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != m_symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != m_magicNumber)
         continue;

      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isPending = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT ||
                        orderType == ORDER_TYPE_BUY_STOP  || orderType == ORDER_TYPE_SELL_STOP ||
                        orderType == ORDER_TYPE_BUY_STOP_LIMIT || orderType == ORDER_TYPE_SELL_STOP_LIMIT);
      if(isPending)
         count++;
   }
   return count;
}

int CICTRiskManager::CountManagedExposure() const
{
   return CountManagedPositions() + CountManagedPendingOrders();
}

double CICTRiskManager::CalculatePositionSize(const double entryPrice,
                                              const double stopLoss,
                                              const double riskWeightPct = 100.0) const
{
   double stopDistance = MathAbs(entryPrice - stopLoss);
   if(stopDistance <= 0.0)
      return 0.0;

   double equity       = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount   = equity * ((m_riskPercent / 100.0) * MathMax(0.0, riskWeightPct / 100.0));
   double tickSize     = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue    = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;

   double riskPerLot = (stopDistance / tickSize) * tickValue;
   if(riskPerLot <= 0.0)
      return 0.0;

   return NormalizeVolume(riskAmount / riskPerLot);
}

bool CICTRiskManager::PlaceLimitOrder(CTrade &trade,
                                      const bool bullish,
                                      const double entryPrice,
                                      const double stopLoss,
                                      const double takeProfit,
                                      const double tp1,
                                      const double tp2,
                                      const double riskWeightPct,
                                      const string tag,
                                      ulong &ticket)
{
   ticket = 0;

   double volume = CalculatePositionSize(entryPrice, stopLoss, riskWeightPct);
   if(volume <= 0.0)
      return false;

   bool ok = bullish
      ? trade.BuyLimit(volume, entryPrice, m_symbol, stopLoss, takeProfit, 0, 0, tag)
      : trade.SellLimit(volume, entryPrice, m_symbol, stopLoss, takeProfit, 0, 0, tag);

   if(!ok)
      return false;

   ticket = trade.ResultOrder();
   if(ticket == 0)
      return false;

   ICTPendingTargetState state;
   ZeroMemory(state);
   state.active        = true;
   state.orderTicket   = ticket;
   state.bullish       = bullish;
   state.tp1           = tp1;
   state.tp2           = tp2;
   state.tp3           = takeProfit;
   state.initialVolume = volume;
   state.createdTime   = TimeCurrent();

   int nextIndex = ArraySize(m_pendingStates);
   ArrayResize(m_pendingStates, nextIndex + 1);
   m_pendingStates[nextIndex] = state;
   return true;
}

bool CICTRiskManager::CancelAllPending(CTrade &trade, const string reason)
{
   bool cancelledAny = false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != m_symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != m_magicNumber)
         continue;

      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isPending = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT ||
                        orderType == ORDER_TYPE_BUY_STOP  || orderType == ORDER_TYPE_SELL_STOP ||
                        orderType == ORDER_TYPE_BUY_STOP_LIMIT || orderType == ORDER_TYPE_SELL_STOP_LIMIT);
      if(!isPending)
         continue;

      if(trade.OrderDelete(ticket))
         cancelledAny = true;
   }

   CleanupStates();
   return cancelledAny;
}

void CICTRiskManager::CancelExpiredPendingOrders(CTrade &trade)
{
   int expirySeconds = m_pendingExpiryBars * PeriodSeconds(m_triggerTimeframe);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != m_symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != m_magicNumber)
         continue;

      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isPending = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT ||
                        orderType == ORDER_TYPE_BUY_STOP  || orderType == ORDER_TYPE_SELL_STOP ||
                        orderType == ORDER_TYPE_BUY_STOP_LIMIT || orderType == ORDER_TYPE_SELL_STOP_LIMIT);
      if(!isPending)
         continue;

      datetime setupTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(setupTime > 0 && (TimeCurrent() - setupTime) >= expirySeconds)
         trade.OrderDelete(ticket);
   }

   CleanupStates();
}

void CICTRiskManager::OnTradeTransaction(const MqlTradeTransaction &trans)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   HistorySelect(TimeCurrent() - 86400, TimeCurrent() + 60);
   if(!HistoryDealSelect(trans.deal))
      return;

   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != m_magicNumber)
      return;

   ENUM_DEAL_ENTRY entryType = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entryType != DEAL_ENTRY_IN)
      return;

   int pendingIndex = FindPendingStateIndex(trans.order);
   if(pendingIndex < 0)
      return;

   ICTPositionTargetState state;
   ZeroMemory(state);
   state.active        = true;
   state.positionTicket= trans.position;
   state.bullish       = m_pendingStates[pendingIndex].bullish;
   state.tp1           = m_pendingStates[pendingIndex].tp1;
   state.tp2           = m_pendingStates[pendingIndex].tp2;
   state.tp3           = m_pendingStates[pendingIndex].tp3;
   state.initialVolume = m_pendingStates[pendingIndex].initialVolume;
   state.stage         = 0;

   int nextIndex = ArraySize(m_positionStates);
   ArrayResize(m_positionStates, nextIndex + 1);
   m_positionStates[nextIndex] = state;

   if(pendingIndex < ArraySize(m_pendingStates) - 1)
      m_pendingStates[pendingIndex] = m_pendingStates[ArraySize(m_pendingStates) - 1];
   ArrayResize(m_pendingStates, ArraySize(m_pendingStates) - 1);
}

void CICTRiskManager::ManageOpenPositions(CTrade &trade,
                                          CICTStructureEngine &m15Structure,
                                          CICTStructureEngine &m5Structure)
{
   CleanupStates();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != m_magicNumber)
         continue;

      int stateIndex = FindPositionStateIndex(ticket);
      if(stateIndex < 0)
         continue;

      bool bullish   = m_positionStates[stateIndex].bullish;
      double entry   = PositionGetDouble(POSITION_PRICE_OPEN);
      double stopLoss= PositionGetDouble(POSITION_SL);
      double takeProfit = PositionGetDouble(POSITION_TP);
      double volume  = PositionGetDouble(POSITION_VOLUME);
      double bid     = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask     = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double price   = bullish ? bid : ask;
      double bePrice = bullish ? entry + (m_breakEvenBufferPips * m_pipSize)
                               : entry - (m_breakEvenBufferPips * m_pipSize);

      if(m_positionStates[stateIndex].stage == 0)
      {
         bool hitTP1 = bullish ? (price >= m_positionStates[stateIndex].tp1)
                               : (price <= m_positionStates[stateIndex].tp1);
         if(hitTP1)
         {
            if(trade.PositionModify(ticket, NormalizeDouble(bePrice, _Digits), takeProfit))
            {
               double closeVolume = NormalizeVolume(m_positionStates[stateIndex].initialVolume * 0.40);
               double minLot      = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
               if(closeVolume < volume && (volume - closeVolume) >= minLot)
                  trade.PositionClosePartial(ticket, closeVolume);
               m_positionStates[stateIndex].stage = 1;
            }
         }
         continue;
      }

      if(m_positionStates[stateIndex].stage == 1)
      {
         bool hitTP2 = bullish ? (price >= m_positionStates[stateIndex].tp2)
                               : (price <= m_positionStates[stateIndex].tp2);
         if(hitTP2)
         {
            double m15Trail = ResolveTrailStop(bullish, m15Structure, stopLoss);
            if(m15Trail != stopLoss)
            {
               trade.PositionModify(ticket, NormalizeDouble(m15Trail, _Digits), takeProfit);
               stopLoss = m15Trail;
            }

            double targetClose = NormalizeVolume(m_positionStates[stateIndex].initialVolume * 0.40);
            double minLot      = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
            if(targetClose < volume && (volume - targetClose) >= minLot)
               trade.PositionClosePartial(ticket, targetClose);
            m_positionStates[stateIndex].stage = 2;
         }
         continue;
      }

      if(m_enableTrailing)
      {
         double newSL = ResolveTrailStop(bullish, m5Structure, stopLoss);
         if(bullish && newSL > stopLoss + m_pointSize)
            trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), takeProfit);
         if(!bullish && newSL < stopLoss - m_pointSize)
            trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), takeProfit);
      }
   }
}

#endif // __ICT_RISKMANAGER_MQH__
