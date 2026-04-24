#include <Trade\PositionInfo.mqh>
#include <Trade\Trade.mqh>
#property strict

// === USER INPUTS ===
input double   LotSize              = 0.1;
input int      NumOrders            = 1;
input int      CandleCount          = 5;
input ENUM_TIMEFRAMES Timeframe    = PERIOD_M1;
input int      TakeProfitPoints     = 3000; // Used as SL
input int      StopLossPoints       = 300;  // Used as TP
input int      MomentumSeconds      = 5;
input double   MinMomentumPoints    = 5.0;
input int      MaxOpenTrades        = 3;
input int      MaxTradesPerDay      = 10;
input bool     InverseLogic         = true;  // Inverse logic: BUY on SELL signal, SELL on BUY signal

// === BREAKEVEN SETTINGS ===
input int      BreakevenTriggerPoints = 1; // Points in profit to trigger breakeven
input int      BreakevenOffsetPoints  = 0; // Points beyond entry to lock profit

// === STATE VARIABLES ===
datetime lastCandleTime = 0;
int tradesToday = 0;
datetime lastTradeDay = 0;
int tradesThisCandle = 0;  // Track trades per candle

CPositionInfo m_position;    // Position info object
CTrade        m_trade;       // Trading operations object

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("✅ ExplosiveInverseBot initialized");
   Print("   InverseLogic: ", (InverseLogic ? "ENABLED" : "DISABLED"));
   if (InverseLogic)
      Print("   TP and SL roles are SWAPPED (TP ⇄ SL)");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Main Tick Logic                                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentCandleTime = iTime(_Symbol, Timeframe, 1);
   if (currentCandleTime == lastCandleTime)
      return;

   // New candle detected - reset trades per candle counter
   lastCandleTime = currentCandleTime;
   tradesThisCandle = 0;

   int bullishCount = 0;
   for (int i = 1; i <= CandleCount; i++)
   {
      double open  = iOpen(_Symbol, Timeframe, i);
      double close = iClose(_Symbol, Timeframe, i);
      if (close > open)
         bullishCount++;
   }

   bool predictedBullish = (bullishCount > CandleCount / 2);
   bool finalTradeDirection = InverseLogic ? !predictedBullish : predictedBullish;

   CheckMomentumAndTrade(finalTradeDirection);

   ManageBreakeven(); // Apply breakeven logic on each tick
}

//+------------------------------------------------------------------+
//| Wait and confirm momentum                                        |
//+------------------------------------------------------------------+
void CheckMomentumAndTrade(bool predictedBuy)
{
   // Limit trades per candle
   if (tradesThisCandle >= NumOrders)
   {
      Print("⚠️ Max trades per candle reached (", tradesThisCandle, "/", NumOrders, "). Skipping.");
      return;
   }

   double startPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int waited = 0;

   while (waited < MomentumSeconds)
   {
      Sleep(1000);
      waited++;
   }

   double endPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double delta = (endPrice - startPrice) / _Point;
   bool momentumBullish = (delta > MinMomentumPoints);
   bool momentumBearish = (delta < -MinMomentumPoints);

   bool confirmed = (predictedBuy && momentumBullish) || (!predictedBuy && momentumBearish);

   if (!confirmed)
   {
      Print("⚠️ Momentum NOT confirmed. Skipping trade. Δ: ", delta, " pts");
      return;
   }

   int currentOpen = CountOpenTrades();
   if (currentOpen >= MaxOpenTrades)
   {
      Print("❌ Max open trades reached (", currentOpen, "/", MaxOpenTrades, "). Skipping.");
      return;
   }

   datetime now = TimeCurrent();
   MqlDateTime nowStruct, lastStruct;
   TimeToStruct(now, nowStruct);
   TimeToStruct(lastTradeDay, lastStruct);

   if (nowStruct.year != lastStruct.year ||
       nowStruct.mon  != lastStruct.mon  ||
       nowStruct.day  != lastStruct.day)
   {
      tradesToday = 0;
   }

   if (tradesToday >= MaxTradesPerDay)
   {
      Print("❌ Max trades per day reached (", tradesToday, "/", MaxTradesPerDay, "). Skipping.");
      return;
   }

   Print("✅ Momentum confirmed. Final direction: ", (predictedBuy ? "BUY" : "SELL"), " | Δ: ", delta, " pts");

   OpenTrade(predictedBuy);

   tradesThisCandle++;
   tradesToday++;
   lastTradeDay = now;
}

//+------------------------------------------------------------------+
//| Open trade with inverse logic                                    |
//+------------------------------------------------------------------+
void OpenTrade(bool predictedBuy)
{
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point  = _Point;
   int digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   bool isBuy = predictedBuy;
   double price = isBuy ? ask : bid;

   double usedSL, usedTP;
   
   if (InverseLogic)
   {
      usedSL = TakeProfitPoints;  // Used as SL
      usedTP = StopLossPoints;    // Used as TP
   }
   else
   {
      usedSL = StopLossPoints;    // Normal SL
      usedTP = TakeProfitPoints;  // Normal TP
   }

   double tp = isBuy ? price + usedTP * point
                     : price - usedTP * point;

   double sl = isBuy ? price - usedSL * point
                     : price + usedSL * point;

   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

   if (MathAbs(price - sl) < stopLevel || MathAbs(price - tp) < stopLevel)
   {
      Print("❌ Trade skipped: SL or TP too close to price (min: ", stopLevel / point, " pts)");
      return;
   }

   int currentOpen = CountOpenTrades();
   int allowedOrders = MathMin(NumOrders, MaxOpenTrades - currentOpen);

   if (allowedOrders <= 0)
   {
      Print("❌ Skipping: allowedOrders = 0 (MaxOpenTrades hit)");
      return;
   }

   if (!m_trade.PositionOpen(_Symbol,
                              isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                              LotSize,
                              price,
                              sl,     // Set SL directly
                              tp,     // Set TP directly
                              NULL))  // comment
   {
      Print("❌ OrderSend failed: ", GetLastError());
      ResetLastError();
      return;
   }

   ulong ticket = m_trade.ResultOrder();
   if (ticket == 0)
   {
      Print("❌ Failed to get ticket for new order.");
      return;
   }

   Print("✅ TRADE PLACED: ", (isBuy ? "BUY" : "SELL"),
         " | Entry: ", NormalizeDouble(price, digits),
         " | SL: ", NormalizeDouble(sl, digits),
         " | TP: ", NormalizeDouble(tp, digits),
         " | Ticket: ", ticket);
}

//+------------------------------------------------------------------+
//| Manage Breakeven Logic                                           |
//+------------------------------------------------------------------+
void ManageBreakeven()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0)
         continue;

      if (!m_position.SelectByTicket(ticket))
         continue;

      string symbol = m_position.Symbol();
      if (symbol != _Symbol)
         continue;

      double entry   = m_position.PriceOpen();
      double sl      = m_position.StopLoss();
      double tp      = m_position.TakeProfit();
      int type       = (int)m_position.PositionType();
      double point   = _Point;
      int digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double current = SymbolInfoDouble(_Symbol, (type == POSITION_TYPE_BUY ? SYMBOL_BID : SYMBOL_ASK));

      bool isBuy = (type == POSITION_TYPE_BUY);
      double profitPoints = (isBuy ? (current - entry) : (entry - current)) / point;

      if (profitPoints >= BreakevenTriggerPoints)
      {
         double newSL = isBuy ? entry + BreakevenOffsetPoints * point
                              : entry - BreakevenOffsetPoints * point;

         // Skip if SL already equal or better than newSL
         if ((isBuy && sl >= newSL) || (!isBuy && sl <= newSL))
            continue;

         if (!m_trade.PositionModify(ticket, newSL, tp))
         {
            Print("❌ Breakeven move failed for ticket ", ticket, " | Error: ", GetLastError());
            ResetLastError();
         }
         else
         {
            Print("🔒 Breakeven set: SL moved to ", NormalizeDouble(newSL, digits),
                  " (Entry: ", NormalizeDouble(entry, digits), 
                  ", Current: ", NormalizeDouble(current, digits),
                  ", Profit: ", NormalizeDouble(profitPoints, 2), " pts)");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Count open trades for this symbol                                |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0)
         continue;

      if (!m_position.SelectByTicket(ticket))
         continue;

      if (m_position.Symbol() == _Symbol)
         count++;
   }
   return count;
}