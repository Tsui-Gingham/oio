//+------------------------------------------------------------------+
//|                                                 OIO_Strategy.mq5 |
//|                        Copyright 2023, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//| Description: EA based on the Outside-Inside-Outside (OIO)        |
//|              candlestick pattern.                                |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.02" // Incremented version for logging changes
#property strict

//--- Input Parameters
input int      InpMagicNumber = 12345; // Magic number for EA's orders
input double   InpLotSize     = 0.01;   // Trading lot size
input int      InpStopLossTicks = 10;    // Stop Loss distance in ticks from OIO low/high
input int      InpTakeProfitTicks = 30;  // Take Profit distance in ticks from entry price (or average entry for 2 orders)
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M5; // Timeframe for OIO pattern detection

//--- OIO Structure Definition
// Stores all relevant information about an identified OIO pattern and subsequent trades.
struct OIOStructure
{
    datetime startTime;         // OIO pattern start time (time of the first bar)
    datetime endTime;           // OIO pattern end time (time of the third bar's close)
    double   high;              // High point of the OIO pattern (Max of 1st and 3rd bar's high)
    double   low;               // Low point of the OIO pattern (Min of 1st and 3rd bar's low)
    double   midPoint;          // Midpoint of the OIO pattern (high + low) / 2
    bool     isActive;          // True if OIO is identified and orders are being managed
    long     buyLimitTicket;    // Ticket for the initial pending buy limit order
    long     sellLimitTicket;   // Ticket for the initial pending sell limit order
    long     firstFilledOrderTicket; // Ticket of the first order that was filled (becomes a position identifier)
    long     secondChaseOrderTicket; // Ticket of the second (chase) order (pending or position identifier)
    ENUM_ORDER_TYPE firstFilledOrderType; // Type (BUY/SELL) of the first filled order
    bool     isLongTrade;       // True if the first filled order was a buy, determining overall trade direction
    int      id;                // Unique ID for the OIO instance (usually timestamp of the 3rd bar)
    bool     takeProfitsAdjusted; // True if take profits for both orders have been adjusted
};

OIOStructure currentOIO; // Global instance for the current OIO cycle
MqlTick last_tick;      // Global variable to store the latest symbol tick data

//+------------------------------------------------------------------+
//| Helper to convert boolean to string for logging                  |
//+------------------------------------------------------------------+
string BoolToString(bool value)
{
    return(value ? "true" : "false");
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//| Called once when the EA is loaded or MetaTrader 5 starts.        |
//+------------------------------------------------------------------+
int OnInit()
{
    ResetOIOStructure(); // Initialize/reset OIO state variables

    // Validate input parameters
    if(InpLotSize <= 0) { Print("Error: Lot size (InpLotSize) must be greater than 0."); return(INIT_PARAMETERS_INCORRECT); }
    if(InpStopLossTicks <= 0) { Print("Error: Stop Loss ticks (InpStopLossTicks) must be greater than 0."); return(INIT_PARAMETERS_INCORRECT); }
    if(InpTakeProfitTicks <= 0) { Print("Error: Take Profit ticks (InpTakeProfitTicks) must be greater than 0."); return(INIT_PARAMETERS_INCORRECT); }
    if(InpMagicNumber <= 0) { Print("Error: Magic number (InpMagicNumber) must be greater than 0."); return(INIT_PARAMETERS_INCORRECT); }

    // Check if trading is allowed
    if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
    {
        Print("Error: Trading is not allowed in the terminal. Please enable it in Terminal settings.");
        Alert("Trading is not allowed in the terminal for OIO_Strategy.mq5!");
        return(INIT_FAILED);
    }
    if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
    {
        Print("Error: EA trading is not allowed. Please enable 'Allow live trading' in EA properties.");
        Alert("Automated trading is not allowed for OIO_Strategy.mq5! Check EA settings.");
        return(INIT_FAILED);
    }

    Print("OIO_Strategy initialized successfully. Magic: ", InpMagicNumber, ", Lots: ", InpLotSize, ", TF: ", EnumToString(InpTimeframe));
    Print("SL Ticks: ", InpStopLossTicks, ", TP Ticks: ", InpTakeProfitTicks);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//| Called once when the EA is unloaded or MetaTrader 5 shuts down.  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("OIO_Strategy (Last OIO ID: ", currentOIO.id, ") is being deinitialized. Reason code: ", reason);

    if(currentOIO.id != 0) {
        string objectName = "OIO_Rect_" + (string)currentOIO.id;
        Print("Attempting to remove chart object during deinitialization: ", objectName);
        ObjectDelete(0, objectName);
    }
    Print("OIO_Strategy deinitialized.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    Print("OnTick called.");
    SymbolInfoTick(_Symbol, last_tick);

    if(currentOIO.isActive)
    {
        ManageOrders();
        return;
    }

    if(IsNewBar())
    {
        Print("OnTick: New bar detected, calling UpdateOIOStructure.");
        UpdateOIOStructure();
    }
}

//+------------------------------------------------------------------+
//| Trade event handler                                              |
//+------------------------------------------------------------------+
void OnTrade()
{
    if(!currentOIO.isActive) return;
    if(currentOIO.firstFilledOrderTicket == 0 && (currentOIO.buyLimitTicket != 0 || currentOIO.sellLimitTicket != 0))
    {
        CheckLimitOrdersExecution();
    }
    else if(currentOIO.firstFilledOrderTicket != 0 && currentOIO.secondChaseOrderTicket != 0 && !currentOIO.takeProfitsAdjusted)
    {
        CheckChaseOrderExecution();
    }
    CheckTradeCycleEnd();
}

//+------------------------------------------------------------------+
//| Manages active OIO orders (called from OnTick).                  |
//+------------------------------------------------------------------+
void ManageOrders()
{
    if(!currentOIO.isActive) return;
    CheckTradeCycleEnd();
}

//+------------------------------------------------------------------+
//| Identifies an OIO pattern from the last three closed bars.       |
//+------------------------------------------------------------------+
void UpdateOIOStructure()
{
    MqlRates rates[];
    if(CopyRates(_Symbol, InpTimeframe, 0, 4, rates) < 4) { Print("UpdateOIOStructure: Failed to get rates for ", _Symbol, " ", EnumToString(InpTimeframe)); return; }
    PrintFormat("UpdateOIOStructure called for bar time: %s (rates[1].time)", TimeToString(rates[1].time));

    double high1 = rates[3].high, low1 = rates[3].low;
    double high2 = rates[2].high, low2 = rates[2].low;
    double high3 = rates[1].high, low3 = rates[1].low;

    // User request: Commented out detailed bar data log
    // PrintFormat("Bar Data for OIO Check: B1(H:%.*f L:%.*f), B2(H:%.*f L:%.*f), B3(H:%.*f L:%.*f)",
    //     _Digits, high1, _Digits, low1, _Digits, high2, _Digits, low2, _Digits, high3, _Digits, low3);

    bool condition1 = (high1 >= high2 && high3 >= high2);
    bool condition2 = (low1 <= low2 && low3 <= low2);
    PrintFormat("OIO Check for bar %s (rates[1].time): condition1=%s, condition2=%s", TimeToString(rates[1].time), BoolToString(condition1), BoolToString(condition2));

    if(condition1 && condition2)
    {
        if(currentOIO.id == (int)rates[1].time && currentOIO.isActive) {
            return;
        }
        ResetOIOStructure();
        currentOIO.startTime = rates[3].time;
        currentOIO.endTime = rates[1].time + PeriodSeconds(InpTimeframe);
        currentOIO.high = MathMax(high1, high3);
        currentOIO.low  = MathMin(low1, low3);
        currentOIO.midPoint = NormalizeDouble((currentOIO.high + currentOIO.low) / 2.0, _Digits);
        currentOIO.id = (int)rates[1].time;

        Print("OIO Pattern Identified: ID ", currentOIO.id, ", Time: ", TimeToString(currentOIO.startTime), " to ", TimeToString(rates[1].time));
        Print("OIO Details - High: ", DoubleToString(currentOIO.high, _Digits), ", Low: ", DoubleToString(currentOIO.low, _Digits), ", Mid: ", DoubleToString(currentOIO.midPoint, _Digits));
        Print("OIO Conditions Met. Proceeding to place orders for OIO ID: ", currentOIO.id);

        DrawOIORectangle();
        PlaceOIOOrders();
    } else {
         PrintFormat("OIO conditions not met for bar %s (rates[1].time). condition1=%s, condition2=%s", TimeToString(rates[1].time), BoolToString(condition1), BoolToString(condition2));
    }
}

//+------------------------------------------------------------------+
//| Places initial Buy Limit and Sell Limit orders for an OIO.       |
//+------------------------------------------------------------------+
void PlaceOIOOrders()
{
    if(currentOIO.isActive || currentOIO.buyLimitTicket != 0 || currentOIO.sellLimitTicket != 0) { Print("PlaceOIOOrders: OIO state is already active or has pending tickets."); return; }

    string symbolName = _Symbol;
    double tickSize = SymbolInfoDouble(symbolName, SYMBOL_TRADE_TICK_SIZE);
    int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
    long stopsLevel = SymbolInfoInteger(symbolName, SYMBOL_TRADE_STOPS_LEVEL);

    PrintFormat("PlaceOIOOrders for ID %d: TickSize=%.*f, Point=%.*f, StopsLevel=%d points", currentOIO.id, digits, tickSize, digits, point, stopsLevel);

    if(tickSize == 0) { Print("Error: Could not retrieve tick size for ", symbolName, ". Cannot place OIO orders."); return; }

    double buyEntryPrice   = NormalizeDouble(currentOIO.high + tickSize, digits);
    double buyTakeProfit   = NormalizeDouble(buyEntryPrice + InpTakeProfitTicks * tickSize, digits);
    double buyStopLoss     = NormalizeDouble(currentOIO.low - tickSize, digits);

    double sellEntryPrice  = NormalizeDouble(currentOIO.low - tickSize, digits);
    double sellTakeProfit  = NormalizeDouble(sellEntryPrice - InpTakeProfitTicks * tickSize, digits);
    double sellStopLoss    = NormalizeDouble(currentOIO.high + tickSize, digits);

    PrintFormat("Buy Limit Params: Entry=%.*f, SL=%.*f (Dist: %.1f pts), TP=%.*f (Dist: %.1f pts)", digits, buyEntryPrice, digits, buyStopLoss, MathAbs(buyEntryPrice-buyStopLoss)/point, digits, buyTakeProfit, MathAbs(buyEntryPrice-buyTakeProfit)/point);
    PrintFormat("Sell Limit Params: Entry=%.*f, SL=%.*f (Dist: %.1f pts), TP=%.*f (Dist: %.1f pts)", digits, sellEntryPrice, digits, sellStopLoss, MathAbs(sellEntryPrice-sellStopLoss)/point, digits, sellTakeProfit, MathAbs(sellEntryPrice-sellTakeProfit)/point);

    if (buyStopLoss >= buyEntryPrice || buyTakeProfit <= buyEntryPrice) { PrintFormat("Invalid SL/TP for Buy Limit: E=%.*f, SL=%.*f, TP=%.*f",digits,buyEntryPrice,digits,buyStopLoss,digits,buyTakeProfit); ObjectDelete(0,"OIO_Rect_" + (string)currentOIO.id); return; }
    if (sellStopLoss <= sellEntryPrice || sellTakeProfit >= sellEntryPrice) { PrintFormat("Invalid SL/TP for Sell Limit: E=%.*f, SL=%.*f, TP=%.*f",digits,sellEntryPrice,digits,sellStopLoss,digits,sellTakeProfit); ObjectDelete(0,"OIO_Rect_" + (string)currentOIO.id); return; }

    if (stopsLevel > 0) {
        if (MathAbs(buyEntryPrice - buyStopLoss) < stopsLevel * point) {
            PrintFormat("Buy StopLoss distance (%.1f points) is less than StopsLevel (%d points). Order may be rejected.", MathAbs(buyEntryPrice-buyStopLoss)/point, stopsLevel);
        }
        if (MathAbs(buyEntryPrice - buyTakeProfit) < stopsLevel * point) {
             PrintFormat("Buy TakeProfit distance (%.1f points) is less than StopsLevel (%d points). Order may be rejected.", MathAbs(buyEntryPrice-buyTakeProfit)/point, stopsLevel);
        }
        if (MathAbs(sellEntryPrice - sellStopLoss) < stopsLevel * point) {
            PrintFormat("Sell StopLoss distance (%.1f points) is less than StopsLevel (%d points). Order may be rejected.", MathAbs(sellEntryPrice-sellStopLoss)/point, stopsLevel);
        }
        if (MathAbs(sellEntryPrice - sellTakeProfit) < stopsLevel * point) {
             PrintFormat("Sell TakeProfit distance (%.1f points) is less than StopsLevel (%d points). Order may be rejected.", MathAbs(sellEntryPrice-sellTakeProfit)/point, stopsLevel);
        }
    }
    long ticket;
    ticket = SendPendingOrder(ORDER_TYPE_BUY_LIMIT, buyEntryPrice, buyStopLoss, buyTakeProfit, "OIO Buy Limit");
    if(ticket == 0) { Print("Failed to place OIO Buy Limit order."); ObjectDelete(0,"OIO_Rect_" + (string)currentOIO.id); return; }
    currentOIO.buyLimitTicket = ticket;

    ticket = SendPendingOrder(ORDER_TYPE_SELL_LIMIT, sellEntryPrice, sellStopLoss, sellTakeProfit, "OIO Sell Limit");
    if(ticket == 0) {
        Print("Failed to place OIO Sell Limit order. Cancelling Buy Limit.");
        CancelOrder(currentOIO.buyLimitTicket, "Sell limit failed");
        currentOIO.buyLimitTicket = 0;
        ObjectDelete(0,"OIO_Rect_" + (string)currentOIO.id);
        return;
    }
    currentOIO.sellLimitTicket = ticket;
    currentOIO.isActive = true;
    Print("OIO initial orders placed successfully. BuyLimit Ticket: ", currentOIO.buyLimitTicket, ", SellLimit Ticket: ", currentOIO.sellLimitTicket, ". OIO Active ID: ", currentOIO.id);
}

//+------------------------------------------------------------------+
//| Helper function to send a pending order.                         |
//+------------------------------------------------------------------+
long SendPendingOrder(ENUM_ORDER_TYPE type, double price, double sl, double tp, string comment)
{
    MqlTradeRequest request; MqlTradeResult result; ZeroMemory(request); ZeroMemory(result);
    request.action = TRADE_ACTION_PENDING; request.magic = InpMagicNumber; request.symbol = _Symbol;
    request.volume = InpLotSize; request.price = price; request.sl = sl; request.tp = tp;
    request.type = type; request.type_filling = ORDER_FILLING_FOK;
    request.comment = comment + " ID " + (string)currentOIO.id;

    Print("Attempting to place pending order: ", EnumToString(type), " Price=", DoubleToString(price,_Digits), " SL=", DoubleToString(sl,_Digits), " TP=", DoubleToString(tp,_Digits), " Comment: ", request.comment);
    if(!OrderSend(request,result)) {
        Print("OrderSend call failed for pending order '",request.comment,"'. Error: ", GetLastError(), " (OS Error). Server RetCode from result struct (if available):",result.retcode);
        return 0;
    }
    Print("OrderSend for '",request.comment,"' - Server Response: RetCode=", result.retcode, " (", TradeRetcodeToString(result.retcode), "), Comment='", result.comment,
          "', OrderTicket=", (long)result.order, ", Price=", DoubleToString(result.price,_Digits), ", Volume=", DoubleToString(result.volume,2));

    if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED) {
        Print("Pending order '",request.comment,"' placed successfully. Ticket: ", (long)result.order);
        return (long)result.order;
    } else {
        Print("Pending order '",request.comment,"' placement request returned non-success code: ", result.retcode);
        return 0;
    }
}

//+------------------------------------------------------------------+
//| Helper function to cancel a pending order.                       |
//+------------------------------------------------------------------+
bool CancelOrder(long ticket, string reasonComment)
{
    if(ticket == 0) return true;
    MqlTradeRequest request; MqlTradeResult result; ZeroMemory(request); ZeroMemory(result);
    request.action = TRADE_ACTION_REMOVE; request.order = ticket;
    Print("Attempting to cancel pending order: ", ticket, " (Reason: ", reasonComment, ")");
    if(!OrderSend(request,result)) { Print("OrderSend failed for cancel request (Order:",ticket, "), Error: ", GetLastError(), " (Server RetCode:", result.retcode, ") - ", result.comment); return false;}
    if(result.retcode == TRADE_RETCODE_DONE) {
         Print("Cancel request for order ", ticket, " successful. Server RetCode: ", result.retcode); return true;
    } else {
        Print("Cancel request for order ", ticket, " returned: ", result.retcode, " - ", result.comment);
        if(result.retcode == TRADE_RETCODE_INVALID_ORDER || result.retcode == TRADE_RETCODE_REJECT) {
             Print("Order ", ticket, " likely already invalid or gone, considering cancellation effective.");
             return true;
        }
        return false;
    }
}

//+------------------------------------------------------------------+
//| Checks execution of initial Buy/Sell limit orders.               |
//+------------------------------------------------------------------+
void CheckLimitOrdersExecution()
{
    if(!currentOIO.isActive || currentOIO.firstFilledOrderTicket != 0) return;
    long filledTicket = 0; ENUM_ORDER_TYPE filledOrderType = WRONG_VALUE;
    bool buyFilled = false, sellFilled = false;

    if(currentOIO.buyLimitTicket != 0 && PositionSelectByTicket(currentOIO.buyLimitTicket)) {
        if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            filledTicket = currentOIO.buyLimitTicket;
            filledOrderType = ORDER_TYPE_BUY; buyFilled = true;
            Print("OIO Buy Limit (Ticket:",filledTicket,") filled. Position Price: ",PositionGetDouble(POSITION_PRICE_OPEN));
        }
    }
    if(!buyFilled && currentOIO.sellLimitTicket != 0 && PositionSelectByTicket(currentOIO.sellLimitTicket)) {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
            filledTicket = currentOIO.sellLimitTicket;
            filledOrderType = ORDER_TYPE_SELL; sellFilled = true;
            Print("OIO Sell Limit (Ticket:",filledTicket,") filled. Position Price: ",PositionGetDouble(POSITION_PRICE_OPEN));
        }
    }
    if(buyFilled || sellFilled) {
        currentOIO.firstFilledOrderTicket = filledTicket;
        currentOIO.firstFilledOrderType = filledOrderType;
        currentOIO.isLongTrade = (filledOrderType == ORDER_TYPE_BUY);
        Print("First OIO order filled: Ticket ", filledTicket, ", Type: ", EnumToString(filledOrderType), ", Direction: ", (currentOIO.isLongTrade?"Long":"Short"));
        if(buyFilled) { CancelOrder(currentOIO.sellLimitTicket, "Buy Limit Filled"); currentOIO.sellLimitTicket = 0; }
        if(sellFilled) { CancelOrder(currentOIO.buyLimitTicket, "Sell Limit Filled"); currentOIO.buyLimitTicket = 0; }
        PlaceChaseOrder();
    } else {
        if(currentOIO.buyLimitTicket != 0 && !OrderSelect(currentOIO.buyLimitTicket)) { Print("Buy Limit Ticket ",currentOIO.buyLimitTicket," no longer exists (not filled)."); currentOIO.buyLimitTicket = 0; }
        if(currentOIO.sellLimitTicket != 0 && !OrderSelect(currentOIO.sellLimitTicket)) { Print("Sell Limit Ticket ",currentOIO.sellLimitTicket," no longer exists (not filled)."); currentOIO.sellLimitTicket = 0; }
        if(currentOIO.buyLimitTicket == 0 && currentOIO.sellLimitTicket == 0 && currentOIO.firstFilledOrderTicket == 0) {
            Print("Both initial OIO limit orders are gone without filling. OIO ID:", currentOIO.id, " cycle terminated.");
            ResetOIOStructure();
        }
    }
}

//+------------------------------------------------------------------+
//| Places the second (chase) order at the OIO midpoint.             |
//+------------------------------------------------------------------+
void PlaceChaseOrder()
{
    if(!currentOIO.isActive || currentOIO.firstFilledOrderTicket == 0 || currentOIO.secondChaseOrderTicket != 0) { Print("PlaceChaseOrder: Conditions not met."); return; }
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    PrintFormat("PlaceChaseOrder for OIO ID %d: MidPoint=%.*f, StopsLevel=%d points", currentOIO.id, digits, currentOIO.midPoint, stopsLevel);

    double entryPrice = currentOIO.midPoint;
    double stopLoss = 0, takeProfit = 0;
    ENUM_ORDER_TYPE orderType = WRONG_VALUE;

    if(!PositionSelectByTicket(currentOIO.firstFilledOrderTicket)) { Print("PlaceChaseOrder: Failed to select first filled position (TicketID:", currentOIO.firstFilledOrderTicket,"). Cannot set chase order SL."); return; }
    double firstOrderSL = PositionGetDouble(POSITION_SL);

    if(currentOIO.isLongTrade) {
        orderType = ORDER_TYPE_BUY_LIMIT; stopLoss = firstOrderSL;
        takeProfit = NormalizeDouble(entryPrice + InpTakeProfitTicks * tickSize, digits);
        PrintFormat("Chase Buy Limit Params: Entry=%.*f, SL=%.*f (Dist: %.1f pts), TP=%.*f (Dist: %.1f pts)", digits, entryPrice, digits, stopLoss, (stopLoss==0)?0:MathAbs(entryPrice-stopLoss)/point, digits, takeProfit, MathAbs(entryPrice-takeProfit)/point);
        if (stopLoss !=0 && stopLoss >= entryPrice) { PrintFormat("Chase Buy SL (%.*f) invalid vs Entry (%.*f)",digits,stopLoss,digits,entryPrice); return; }
        if (takeProfit <= entryPrice) { PrintFormat("Chase Buy TP (%.*f) invalid vs Entry (%.*f)",digits,takeProfit,digits,entryPrice); return; }
         if (stopsLevel > 0 && stopLoss != 0 && MathAbs(entryPrice - stopLoss) < stopsLevel * point) {
            PrintFormat("Chase Buy SL distance (%.1f points) is less than StopsLevel (%d points).", MathAbs(entryPrice-stopLoss)/point, stopsLevel);
        }
    } else {
        orderType = ORDER_TYPE_SELL_LIMIT; stopLoss = firstOrderSL;
        takeProfit = NormalizeDouble(entryPrice - InpTakeProfitTicks * tickSize, digits);
        PrintFormat("Chase Sell Limit Params: Entry=%.*f, SL=%.*f (Dist: %.1f pts), TP=%.*f (Dist: %.1f pts)", digits, entryPrice, digits, stopLoss, (stopLoss==0)?0:MathAbs(entryPrice-stopLoss)/point, digits, takeProfit, MathAbs(entryPrice-takeProfit)/point);
        if (stopLoss != 0 && stopLoss <= entryPrice) { PrintFormat("Chase Sell SL (%.*f) invalid vs Entry (%.*f)",digits,stopLoss,digits,entryPrice); return; }
        if (takeProfit >= entryPrice) { PrintFormat("Chase Sell TP (%.*f) invalid vs Entry (%.*f)",digits,takeProfit,digits,entryPrice); return; }
        if (stopsLevel > 0 && stopLoss != 0 && MathAbs(entryPrice - stopLoss) < stopsLevel * point) {
            PrintFormat("Chase Sell SL distance (%.1f points) is less than StopsLevel (%d points).", MathAbs(entryPrice-stopLoss)/point, stopsLevel);
        }
    }
    if(orderType == ORDER_TYPE_BUY_LIMIT && entryPrice > last_tick.ask - tickSize * 2) { Print("Warning: Chase Buy Limit price ",DoubleToString(entryPrice,digits)," is close to/above Ask ",DoubleToString(last_tick.ask,digits)); }
    if(orderType == ORDER_TYPE_SELL_LIMIT && entryPrice < last_tick.bid + tickSize * 2) { Print("Warning: Chase Sell Limit price ",DoubleToString(entryPrice,digits)," is close to/below Bid ",DoubleToString(last_tick.bid,digits)); }

    long ticket = SendPendingOrder(orderType, entryPrice, stopLoss, takeProfit, "OIO Chase " + EnumToString(orderType));
    if(ticket != 0) {
        currentOIO.secondChaseOrderTicket = ticket;
        Print("OIO Chase Order placed successfully. Ticket: ", ticket);
    } else {
        Print("Failed to place OIO Chase Order. First order (TicketID:",currentOIO.firstFilledOrderTicket,") will proceed with its original SL/TP.");
        currentOIO.secondChaseOrderTicket = 0;
    }
}

//+------------------------------------------------------------------+
//| Checks execution of the second (chase) order.                    |
//+------------------------------------------------------------------+
void CheckChaseOrderExecution()
{
    if(!currentOIO.isActive || currentOIO.firstFilledOrderTicket == 0 || currentOIO.secondChaseOrderTicket == 0 || currentOIO.takeProfitsAdjusted) return;
    if(PositionSelectByTicket(currentOIO.secondChaseOrderTicket)) {
        if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            Print("OIO Chase Order (Original Ticket:", currentOIO.secondChaseOrderTicket, ") filled. Position Price: ", PositionGetDouble(POSITION_PRICE_OPEN));
            AdjustTakeProfit();
        }
    } else if(!OrderSelect(currentOIO.secondChaseOrderTicket)) {
         Print("OIO Chase Order (Ticket:",currentOIO.secondChaseOrderTicket,") no longer exists (not filled, possibly cancelled/expired).");
         currentOIO.secondChaseOrderTicket = 0;
    }
}

//+------------------------------------------------------------------+
//| Adjusts Take Profit for both orders after the chase order fills. |
//+------------------------------------------------------------------+
void AdjustTakeProfit()
{
    if(currentOIO.takeProfitsAdjusted) return;
    if(!currentOIO.isActive || currentOIO.firstFilledOrderTicket == 0 || currentOIO.secondChaseOrderTicket == 0) { Print("AdjustTakeProfit: Conditions not met (active OIO and both tickets required)."); return; }
    if(!PositionSelectByTicket(currentOIO.firstFilledOrderTicket)) { Print("AdjustTakeProfit: Failed to select first position (TicketID:", currentOIO.firstFilledOrderTicket,")"); return; }
    if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) { Print("AdjustTakeProfit: First position (TicketID:",currentOIO.firstFilledOrderTicket,") magic number mismatch."); return; }
    double price1 = PositionGetDouble(POSITION_PRICE_OPEN), vol1 = PositionGetDouble(POSITION_VOLUME), sl1 = PositionGetDouble(POSITION_SL);
    if(!PositionSelectByTicket(currentOIO.secondChaseOrderTicket)) { Print("AdjustTakeProfit: Failed to select second position (Original Chase TicketID:", currentOIO.secondChaseOrderTicket,")"); return; }
    if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) { Print("AdjustTakeProfit: Second position (Original Chase TicketID:",currentOIO.secondChaseOrderTicket,") magic number mismatch."); return; }
    double price2 = PositionGetDouble(POSITION_PRICE_OPEN), vol2 = PositionGetDouble(POSITION_VOLUME), sl2 = PositionGetDouble(POSITION_SL);
    if(vol1 <= 0 || vol2 <= 0) { Print("AdjustTakeProfit: Invalid position volume(s). V1:",vol1," V2:",vol2); return; }
    double avgEntry = NormalizeDouble(((price1 * vol1) + (price2 * vol2)) / (vol1 + vol2), _Digits);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double newTP = currentOIO.isLongTrade ? NormalizeDouble(avgEntry + InpTakeProfitTicks * tickSize, _Digits) : NormalizeDouble(avgEntry - InpTakeProfitTicks * tickSize, _Digits);
    PrintFormat("AdjustTakeProfit for OIO ID %d: P1=%.*f,V1=%.2f; P2=%.*f,V2=%.2f. AvgEntry=%.*f. New Global TP=%.*f", currentOIO.id, _Digits,price1,vol1,_Digits,price2,vol2,_Digits,avgEntry,_Digits,newTP);
    bool mod1_success = ModifyPositionSLTP(currentOIO.firstFilledOrderTicket, sl1, newTP);
    bool mod2_success = ModifyPositionSLTP(currentOIO.secondChaseOrderTicket, sl2, newTP);
    if(mod1_success && mod2_success) { Print("Successfully requested TP adjustment for both OIO positions to: ", DoubleToString(newTP, _Digits)); currentOIO.takeProfitsAdjusted = true; }
    else { Print("Error or partial success in adjusting TPs for OIO positions."); }
}

//+------------------------------------------------------------------+
//| Modifies SL/TP for a given position.                             |
//+------------------------------------------------------------------+
bool ModifyPositionSLTP(long positionIdentifier, double newSL, double newTP)
{
    if(!PositionSelectByTicket(positionIdentifier)) { Print("ModifyPositionSLTP: Failed to select position by original ticket ID: ", positionIdentifier); return false; }
    if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) { Print("ModifyPositionSLTP: Position (Original TicketID:", positionIdentifier,") magic number mismatch."); return false; }
    double currentSL = NormalizeDouble(PositionGetDouble(POSITION_SL),_Digits);
    double currentTP = NormalizeDouble(PositionGetDouble(POSITION_TP),_Digits);
    newSL = NormalizeDouble(newSL,_Digits); newTP = NormalizeDouble(newTP,_Digits);
    if(currentSL == newSL && currentTP == newTP) { Print("ModifyPositionSLTP: Position (Original TicketID:", positionIdentifier, ") SL/TP already at target values. No modification needed."); return true; }
    MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
    req.action = TRADE_ACTION_SLTP;
    req.position = PositionGetInteger(POSITION_TICKET);
    req.symbol = _Symbol; req.sl = newSL; req.tp = newTP;
    Print("Attempting to modify SL/TP for Position Ticket:", req.position, " (Original OrderID:",positionIdentifier,") to NewSL:",DoubleToString(newSL,_Digits), ", NewTP:", DoubleToString(newTP,_Digits));
    if(!OrderSend(req, res)) { Print("OrderSend failed for SL/TP modification (PosTicket:", req.position, "), Error: ", GetLastError(), " (Server RetCode:",res.retcode,") - ", res.comment); return false; }
    if(res.retcode == TRADE_RETCODE_DONE) {
        Print("SL/TP modification request for Position Ticket:", req.position," successful. Server RetCode:",res.retcode); return true;
    } else {
        Print("SL/TP modification request for Position Ticket:", req.position," returned: ", res.retcode, " - ", res.comment); return false;
    }
}

//+------------------------------------------------------------------+
//| Checks if the entire OIO trading cycle has ended.                |
//+------------------------------------------------------------------+
void CheckTradeCycleEnd()
{
    if(!currentOIO.isActive) return;
    bool initialLimitsStillActive = false;
    if(currentOIO.buyLimitTicket != 0 && OrderSelect(currentOIO.buyLimitTicket) && OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED) initialLimitsStillActive = true;
    if(currentOIO.sellLimitTicket != 0 && OrderSelect(currentOIO.sellLimitTicket) && OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED) initialLimitsStillActive = true;
    bool firstPositionStillActive = false;
    if(currentOIO.firstFilledOrderTicket != 0 && PositionSelectByTicket(currentOIO.firstFilledOrderTicket) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) firstPositionStillActive = true;
    bool chaseOrderStillActive = false;
    if(currentOIO.secondChaseOrderTicket != 0) {
        if(OrderSelect(currentOIO.secondChaseOrderTicket) && OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber) chaseOrderStillActive = true;
        else if (PositionSelectByTicket(currentOIO.secondChaseOrderTicket) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) chaseOrderStillActive = true;
    }
    if(!initialLimitsStillActive && !firstPositionStillActive && !chaseOrderStillActive) {
        Print("OIO Trading Cycle Ended for OIO ID: ", currentOIO.id, ". Resetting OIO state.");
        ResetOIOStructure();
    }
}

//+------------------------------------------------------------------+
//| Draws an orange rectangle on the chart to mark an OIO pattern.   |
//+------------------------------------------------------------------+
void DrawOIORectangle()
{
    string objectName = "OIO_Rect_" + (string)currentOIO.id;
    ObjectDelete(0, objectName);
    if(!ObjectCreate(0, objectName, OBJ_RECTANGLE, 0, currentOIO.startTime, currentOIO.high, currentOIO.endTime, currentOIO.low)) { Print("Failed to create OIO rectangle '",objectName,"': ", GetLastError()); return; }
    ObjectSetInteger(0, objectName, OBJPROP_COLOR, clrOrange);
    ObjectSetInteger(0, objectName, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, objectName, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, objectName, OBJPROP_BACK, true);
    ObjectSetString(0, objectName, OBJPROP_TOOLTIP, "OIO Pattern ID: " + (string)currentOIO.id);
    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Resets the global OIO structure to its initial state.            |
//+------------------------------------------------------------------+
void ResetOIOStructure()
{
    if(currentOIO.id != 0) {
      ObjectDelete(0, "OIO_Rect_" + (string)currentOIO.id);
    }
    currentOIO.startTime = 0; currentOIO.endTime = 0;
    currentOIO.high = 0.0; currentOIO.low = 0.0; currentOIO.midPoint = 0.0;
    currentOIO.isActive = false;
    currentOIO.buyLimitTicket = 0; currentOIO.sellLimitTicket = 0;
    currentOIO.firstFilledOrderTicket = 0; currentOIO.secondChaseOrderTicket = 0;
    currentOIO.firstFilledOrderType = WRONG_VALUE;
    currentOIO.isLongTrade = false;
    currentOIO.id = 0;
    currentOIO.takeProfitsAdjusted = false;
    // Print("OIO Structure has been reset.");
}

//+------------------------------------------------------------------+
//| Checks if a new bar has started for the EA's timeframe.          |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    static datetime lastBarTime = 0;
    datetime currentTime = (datetime)SeriesInfoInteger(_Symbol, InpTimeframe, SERIES_LASTBAR_DATE);
    // PrintFormat("IsNewBar Check: lastBarTime=%s, currentTime=%s", TimeToString(lastBarTime), TimeToString(currentTime)); // Can be very verbose

    if(lastBarTime < currentTime) {
        PrintFormat("IsNewBar: New bar detected. lastBarTime=%s, newBarTime=%s", TimeToString(lastBarTime), TimeToString(currentTime));
        lastBarTime = currentTime;
        return(true);
    }
    // else { PrintFormat("IsNewBar: No new bar. lastBarTime=%s, currentTime=%s", TimeToString(lastBarTime), TimeToString(currentTime));} // Verbose
    return(false);
}

//+------------------------------------------------------------------+
//| Helper function to get the minimum stop level for the symbol.    |
//+------------------------------------------------------------------+
long GetStopsLevel() { return SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL); }

//+------------------------------------------------------------------+
//| Helper to convert Trade Retcode to String for logging            |
//+------------------------------------------------------------------+
string TradeRetcodeToString(int retcode) // Changed uint to int
  {
   switch(retcode)
     {
      case TRADE_RETCODE_DONE:                    return("TRADE_RETCODE_DONE (Request accomplished)");
      case TRADE_RETCODE_DONE_PARTIAL:            return("TRADE_RETCODE_DONE_PARTIAL (Request accomplished partially)");
      case TRADE_RETCODE_PLACED:                  return("TRADE_RETCODE_PLACED (Order placed)");
      case TRADE_RETCODE_REJECT:                  return("TRADE_RETCODE_REJECT (Request rejected)");
      case TRADE_RETCODE_TIMEOUT:                 return("TRADE_RETCODE_TIMEOUT (Request canceled by timeout)");
      case TRADE_RETCODE_INVALID_VOLUME:          return("TRADE_RETCODE_INVALID_VOLUME (Invalid volume in request)");
      case TRADE_RETCODE_INVALID_PRICE:           return("TRADE_RETCODE_INVALID_PRICE (Invalid price in request)");
      case TRADE_RETCODE_INVALID_STOPS:           return("TRADE_RETCODE_INVALID_STOPS (Invalid stops in request)");
      case TRADE_RETCODE_TRADE_DISABLED:          return("TRADE_RETCODE_TRADE_DISABLED (Trade is disabled)");
      case TRADE_RETCODE_MARKET_CLOSED:           return("TRADE_RETCODE_MARKET_CLOSED (Market is closed)");
      case TRADE_RETCODE_NO_MONEY:                return("TRADE_RETCODE_NO_MONEY (Not enough money to accomplish request)");
      case TRADE_RETCODE_PRICE_CHANGED:           return("TRADE_RETCODE_PRICE_CHANGED (Price changed)");
      case TRADE_RETCODE_PRICE_OFF:               return("TRADE_RETCODE_PRICE_OFF (There are no quotes to accomplish request)");
      case TRADE_RETCODE_INVALID_ORDER:           return("TRADE_RETCODE_INVALID_ORDER (Invalid order's type or status for request)");
      case TRADE_RETCODE_INVALID_EXPIRATION:      return("TRADE_RETCODE_INVALID_EXPIRATION (Invalid expiration date in request)");
      case TRADE_RETCODE_ORDER_CHANGED:           return("TRADE_RETCODE_ORDER_CHANGED (Order changed)");
      case TRADE_RETCODE_TOO_MANY_REQUESTS:       return("TRADE_RETCODE_TOO_MANY_REQUESTS (Too many requests)");
      case TRADE_RETCODE_NO_CHANGES:              return("TRADE_RETCODE_NO_CHANGES (No changes in request)");
      case TRADE_RETCODE_SERVER_DISABLES_AT:      return("TRADE_RETCODE_SERVER_DISABLES_AT (Autotrading disabled by server)");
      case TRADE_RETCODE_CLIENT_DISABLES_AT:      return("TRADE_RETCODE_CLIENT_DISABLES_AT (Autotrading disabled by client terminal)");
      case TRADE_RETCODE_LOCKED:                  return("TRADE_RETCODE_LOCKED (Request locked for processing)");
      case TRADE_RETCODE_FROZEN:                  return("TRADE_RETCODE_FROZEN (Order is frozen and cannot be changed)");
      case TRADE_RETCODE_CONNECTION:              return("TRADE_RETCODE_CONNECTION (No connection to trade server)");
      case TRADE_RETCODE_ONLY_REAL:               return("TRADE_RETCODE_ONLY_REAL (Operation is allowed only for live accounts)");
      case TRADE_RETCODE_LIMIT_ORDERS:            return("TRADE_RETCODE_LIMIT_ORDERS (The number of pending orders has reached the limit)");
      case TRADE_RETCODE_LIMIT_VOLUME:            return("TRADE_RETCODE_LIMIT_VOLUME (The volume of orders and positions for the symbol has reached the limit)");
      // case TRADE_RETCODE_INVALID_ACCOUNT:      return("TRADE_RETCODE_INVALID_ACCOUNT (Invalid account or account disabled)"); // Temporarily removed due to compilation issues
      default:                                    return("UNKNOWN_TRADE_RETCODE ("+(string)retcode+")");
     }
  }
//+------------------------------------------------------------------+

[end of OIO_Strategy.mq5]
