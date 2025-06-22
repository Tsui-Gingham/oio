//+------------------------------------------------------------------+
//|                                                 OIO_Strategy.mq5 |
//|                        Copyright 2023, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//| Description: EA based on the Outside-Inside-Outside (OIO)        |
//|              candlestick pattern.                                |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.01" // Incremented version for clarity
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

    // Clean up chart objects created by this EA instance
    if(currentOIO.id != 0) { // If an OIO was active or identified
        string objectName = "OIO_Rect_" + (string)currentOIO.id;
        Print("Attempting to remove chart object during deinitialization: ", objectName);
        ObjectDelete(0, objectName);
    }

    // Optional: Cancel any pending orders placed by this EA.
    // However, the current strategy is designed to manage its orders through its lifecycle.
    // CancelAllPendingOrdersByMagic(); // Example if such a function existed and was desired.

    Print("OIO_Strategy deinitialized.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//| Called on every new tick for the symbol the EA is attached to.   |
//+------------------------------------------------------------------+
void OnTick()
{
    SymbolInfoTick(_Symbol, last_tick); // Update global last_tick data

    // If an OIO cycle is currently active, manage its orders.
    if(currentOIO.isActive)
    {
        ManageOrders();
        return; // Do not look for new OIOs while one is active
    }

    // If no OIO cycle is active, check for new bars to identify potential OIO patterns.
    if(IsNewBar())
    {
        UpdateOIOStructure();
    }
}

//+------------------------------------------------------------------+
//| Trade event handler                                              |
//| Called when a trade event occurs (e.g., order filled, modified). |
//+------------------------------------------------------------------+
void OnTrade()
{
    // Only process trade events if an OIO cycle is active for this EA instance.
    if(!currentOIO.isActive) return;

    // Scenario 1: Waiting for the first of the initial two limit orders to be filled.
    if(currentOIO.firstFilledOrderTicket == 0 && (currentOIO.buyLimitTicket != 0 || currentOIO.sellLimitTicket != 0))
    {
        CheckLimitOrdersExecution();
    }
    // Scenario 2: First order filled, chase order placed, waiting for chase order to fill or TP adjustment.
    else if(currentOIO.firstFilledOrderTicket != 0 && currentOIO.secondChaseOrderTicket != 0 && !currentOIO.takeProfitsAdjusted)
    {
        CheckChaseOrderExecution();
    }

    // Always check if the trade cycle has ended after any trade event.
    CheckTradeCycleEnd();
}

//+------------------------------------------------------------------+
//| Manages active OIO orders (called from OnTick).                  |
//| Primarily ensures that the trade cycle end condition is checked. |
//+------------------------------------------------------------------+
void ManageOrders()
{
    if(!currentOIO.isActive) return;

    // The main logic for order execution, cancellation, and modification is handled in OnTrade.
    // ManageOrders, called from OnTick, serves as a polling mechanism, especially to ensure
    // that CheckTradeCycleEnd is called regularly, catching states that OnTrade might miss
    // or if OnTrade events are delayed/missed for any reason (e.g. SL/TP hit without explicit OnTrade trigger for positions).
    CheckTradeCycleEnd();
}

//+------------------------------------------------------------------+
//| Identifies an OIO pattern from the last three closed bars.       |
//+------------------------------------------------------------------+
void UpdateOIOStructure()
{
    MqlRates rates[];
    // Request data for the last 4 bars to analyze the 3 most recent closed bars.
    if(CopyRates(_Symbol, InpTimeframe, 0, 4, rates) < 4) { Print("Failed to get rates for ", _Symbol, " ", EnumToString(InpTimeframe)); return; }

    // rates[3] is Bar1 (oldest), rates[2] is Bar2 (middle), rates[1] is Bar3 (most recent closed)
    double high1 = rates[3].high, low1 = rates[3].low;
    double high2 = rates[2].high, low2 = rates[2].low;
    double high3 = rates[1].high, low3 = rates[1].low;

    PrintFormat("Bar Data for OIO Check: B1(H:%.*f L:%.*f), B2(H:%.*f L:%.*f), B3(H:%.*f L:%.*f)",
        _Digits, high1, _Digits, low1, _Digits, high2, _Digits, low2, _Digits, high3, _Digits, low3);

    // OIO pattern conditions:
    // 1. Bar1's High >= Bar2's High AND Bar3's High >= Bar2's High
    // 2. Bar1's Low <= Bar2's Low AND Bar3's Low <= Bar2's Low
    bool condition1 = (high1 >= high2 && high3 >= high2);
    bool condition2 = (low1 <= low2 && low3 <= low2);

    if(condition1 && condition2) // OIO Pattern identified
    {
        // Avoid re-processing the same OIO if it's already active or was just processed.
        if(currentOIO.id == (int)rates[1].time && currentOIO.isActive) {
            return;
        }
        // If ID matches but not active, it might be a retry after a failed order placement.

        ResetOIOStructure(); // Clear previous OIO data and prepare for a new one.

        currentOIO.startTime = rates[3].time; // Start time of the OIO pattern (Bar1 open time)
        currentOIO.endTime = rates[1].time + PeriodSeconds(InpTimeframe); // End time (Bar3 close time)
        currentOIO.high = MathMax(high1, high3); // OIO High is the higher of Bar1 and Bar3 highs
        currentOIO.low  = MathMin(low1, low3);   // OIO Low is the lower of Bar1 and Bar3 lows
        currentOIO.midPoint = NormalizeDouble((currentOIO.high + currentOIO.low) / 2.0, _Digits);
        currentOIO.id = (int)rates[1].time; // Unique ID based on the timestamp of the third bar

        Print("OIO Pattern Identified: ID ", currentOIO.id, ", Time: ", TimeToString(currentOIO.startTime), " to ", TimeToString(rates[1].time));
        Print("OIO Details - High: ", DoubleToString(currentOIO.high, _Digits), ", Low: ", DoubleToString(currentOIO.low, _Digits), ", Mid: ", DoubleToString(currentOIO.midPoint, _Digits));
        Print("OIO Conditions Met. Proceeding to place orders for OIO ID: ", currentOIO.id);

        DrawOIORectangle(); // Mark the OIO pattern on the chart
        PlaceOIOOrders();   // Proceed to place initial pending orders
    } else {
        // Print("OIO conditions not met for the last 3 bars.");
    }
}

//+------------------------------------------------------------------+
//| Places initial Buy Limit and Sell Limit orders for an OIO.       |
//+------------------------------------------------------------------+
void PlaceOIOOrders()
{
    // Ensure no orders are pending from a previous attempt for this OIO.
    if(currentOIO.isActive || currentOIO.buyLimitTicket != 0 || currentOIO.sellLimitTicket != 0) { Print("PlaceOIOOrders: OIO state is already active or has pending tickets."); return; }

    string symbolName = _Symbol;
    double tickSize = SymbolInfoDouble(symbolName, SYMBOL_TRADE_TICK_SIZE);
    int digits = (int)SymbolInfoInteger(symbolName, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(symbolName, SYMBOL_POINT);
    long stopsLevel = SymbolInfoInteger(symbolName, SYMBOL_TRADE_STOPS_LEVEL);

    PrintFormat("PlaceOIOOrders for ID %d: TickSize=%.*f, Point=%.*f, StopsLevel=%d points", currentOIO.id, digits, tickSize, digits, point, stopsLevel);

    if(tickSize == 0) { Print("Error: Could not retrieve tick size for ", symbolName, ". Cannot place OIO orders."); return; }

    // Calculate parameters for Buy Limit order
    double buyEntryPrice   = NormalizeDouble(currentOIO.high + tickSize, digits);
    double buyTakeProfit   = NormalizeDouble(buyEntryPrice + InpTakeProfitTicks * tickSize, digits);
    double buyStopLoss     = NormalizeDouble(currentOIO.low - tickSize, digits); // SL for Buy is OIO Low - 1 tick

    // Calculate parameters for Sell Limit order
    double sellEntryPrice  = NormalizeDouble(currentOIO.low - tickSize, digits);
    double sellTakeProfit  = NormalizeDouble(sellEntryPrice - InpTakeProfitTicks * tickSize, digits);
    double sellStopLoss    = NormalizeDouble(currentOIO.high + tickSize, digits); // SL for Sell is OIO High + 1 tick

    PrintFormat("Buy Limit Params: Entry=%.*f, SL=%.*f (Dist: %.1f pts), TP=%.*f (Dist: %.1f pts)", digits, buyEntryPrice, digits, buyStopLoss, MathAbs(buyEntryPrice-buyStopLoss)/point, digits, buyTakeProfit, MathAbs(buyEntryPrice-buyTakeProfit)/point);
    PrintFormat("Sell Limit Params: Entry=%.*f, SL=%.*f (Dist: %.1f pts), TP=%.*f (Dist: %.1f pts)", digits, sellEntryPrice, digits, sellStopLoss, MathAbs(sellEntryPrice-sellStopLoss)/point, digits, sellTakeProfit, MathAbs(sellEntryPrice-sellTakeProfit)/point);

    // Validate SL/TP prices against entry prices
    if (buyStopLoss >= buyEntryPrice || buyTakeProfit <= buyEntryPrice) { PrintFormat("Invalid SL/TP for Buy Limit: E=%.*f, SL=%.*f, TP=%.*f",digits,buyEntryPrice,digits,buyStopLoss,digits,buyTakeProfit); ObjectDelete(0,"OIO_Rect_" + (string)currentOIO.id); return; }
    if (sellStopLoss <= sellEntryPrice || sellTakeProfit >= sellEntryPrice) { PrintFormat("Invalid SL/TP for Sell Limit: E=%.*f, SL=%.*f, TP=%.*f",digits,sellEntryPrice,digits,sellStopLoss,digits,sellTakeProfit); ObjectDelete(0,"OIO_Rect_" + (string)currentOIO.id); return; }

    // Validate against SYMBOL_TRADE_STOPS_LEVEL
    // For Buy orders, SL must be current price (or entry for pending) - StopsLevel * Point or lower. TP must be current price + StopsLevel * Point or higher.
    // For Buy Limit, SL must be entry_price - StopsLevel*Point or lower. TP must be entry_price + StopsLevel*Point or higher.
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

    // Place Buy Limit order
    ticket = SendPendingOrder(ORDER_TYPE_BUY_LIMIT, buyEntryPrice, buyStopLoss, buyTakeProfit, "OIO Buy Limit");
    if(ticket == 0) { Print("Failed to place OIO Buy Limit order."); ObjectDelete(0,"OIO_Rect_" + (string)currentOIO.id); return; } // Cleanup rectangle if buy order fails
    currentOIO.buyLimitTicket = ticket;

    // Place Sell Limit order
    ticket = SendPendingOrder(ORDER_TYPE_SELL_LIMIT, sellEntryPrice, sellStopLoss, sellTakeProfit, "OIO Sell Limit");
    if(ticket == 0) {
        Print("Failed to place OIO Sell Limit order. Cancelling Buy Limit.");
        CancelOrder(currentOIO.buyLimitTicket, "Sell limit failed"); // Attempt to cancel the already placed buy limit
        currentOIO.buyLimitTicket = 0; // Reset buy ticket
        ObjectDelete(0,"OIO_Rect_" + (string)currentOIO.id); // Cleanup rectangle
        return;
    }
    currentOIO.sellLimitTicket = ticket;

    currentOIO.isActive = true; // Both orders successfully placed, OIO cycle is now active
    Print("OIO initial orders placed successfully. BuyLimit Ticket: ", currentOIO.buyLimitTicket, ", SellLimit Ticket: ", currentOIO.sellLimitTicket, ". OIO Active ID: ", currentOIO.id);
}

//+------------------------------------------------------------------+
//| Helper function to send a pending order.                         |
//| Returns order ticket if successful, 0 otherwise.                 |
//+------------------------------------------------------------------+
long SendPendingOrder(ENUM_ORDER_TYPE type, double price, double sl, double tp, string comment)
{
    MqlTradeRequest request;
    MqlTradeResult result;
    ZeroMemory(request); ZeroMemory(result);

    request.action = TRADE_ACTION_PENDING;
    request.magic = InpMagicNumber;
    request.symbol = _Symbol;
    request.volume = InpLotSize;
    request.price = price;
    request.sl = sl;
    request.tp = tp;
    request.type = type;
    request.type_filling = ORDER_FILLING_FOK; // Fill Or Kill: entire order or none
    request.comment = comment + " ID " + (string)currentOIO.id;

    Print("Attempting to place pending order: ", EnumToString(type), " Price=", DoubleToString(price,_Digits), " SL=", DoubleToString(sl,_Digits), " TP=", DoubleToString(tp,_Digits), " Comment: ", request.comment);
    if(!OrderSend(request,result)) {
        Print("OrderSend call failed for pending order '",request.comment,"'. Error: ", GetLastError(), " (OS Error). Server RetCode from result struct (if available):",result.retcode);
        return 0;
    }

    // Always print retcode and comment from server for diagnostics
    Print("OrderSend for '",request.comment,"' - Server Response: RetCode=", result.retcode, " (", TradeRetcodeToString(result.retcode), "), Comment='", result.comment,
          "', OrderTicket=", (long)result.order, ", Price=", DoubleToString(result.price,_Digits), ", Volume=", DoubleToString(result.volume,2));

    if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED) { // Standard success codes for pending orders
        Print("Pending order '",request.comment,"' placed successfully. Ticket: ", (long)result.order);
        return (long)result.order;
    } else {
        Print("Pending order '",request.comment,"' placement request returned non-success code: ", result.retcode);
        return 0;
    }
}

//+------------------------------------------------------------------+
//| Helper function to cancel a pending order.                       |
//| Returns true if cancellation was successful or order didn't exist.|
//+------------------------------------------------------------------+
bool CancelOrder(long ticket, string reasonComment)
{
    if(ticket == 0) return true; // No order to cancel

    MqlTradeRequest request; MqlTradeResult result;
    ZeroMemory(request); ZeroMemory(result);
    request.action = TRADE_ACTION_REMOVE; // Action to remove a pending order
    request.order = ticket;

    Print("Attempting to cancel pending order: ", ticket, " (Reason: ", reasonComment, ")");
    if(!OrderSend(request,result)) { Print("OrderSend failed for cancel request (Order:",ticket, "), Error: ", GetLastError(), " (Server RetCode:", result.retcode, ") - ", result.comment); return false;}

    // For TRADE_ACTION_REMOVE, TRADE_RETCODE_DONE means successful removal.
    // Other codes like TRADE_RETCODE_INVALID_ORDER or specific errors if order doesn't exist might occur.
    if(result.retcode == TRADE_RETCODE_DONE) {
         Print("Cancel request for order ", ticket, " successful. Server RetCode: ", result.retcode); return true;
    } else {
        Print("Cancel request for order ", ticket, " returned: ", result.retcode, " - ", result.comment);
        // If the order was already gone (e.g. filled, cancelled prior), specific error codes might indicate this.
        // For simplicity, if not DONE, we consider it potentially problematic unless it's an "already gone" type error.
        // TRADE_RETCODE_INVALID_ORDER (10013), TRADE_RETCODE_REJECT (10006, if order no longer valid for cancellation)
        if(result.retcode == TRADE_RETCODE_INVALID_ORDER || result.retcode == TRADE_RETCODE_REJECT) {
             Print("Order ", ticket, " likely already invalid or gone, considering cancellation effective.");
             return true; // Effectively cancelled from our perspective
        }
        return false;
    }
}

//+------------------------------------------------------------------+
//| Checks execution of initial Buy/Sell limit orders. (Called by OnTrade) |
//+------------------------------------------------------------------+
void CheckLimitOrdersExecution()
{
    // Ensure OIO is active and no first order has been filled yet.
    if(!currentOIO.isActive || currentOIO.firstFilledOrderTicket != 0) return;

    long filledTicket = 0; ENUM_ORDER_TYPE filledOrderType = WRONG_VALUE;
    bool buyFilled = false, sellFilled = false;

    // Check if the Buy Limit order was filled (became a position)
    if(currentOIO.buyLimitTicket != 0 && PositionSelectByTicket(currentOIO.buyLimitTicket)) {
        if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            filledTicket = currentOIO.buyLimitTicket; // The order ticket becomes the position identifier
            filledOrderType = ORDER_TYPE_BUY;
            buyFilled = true;
            Print("OIO Buy Limit (Ticket:",filledTicket,") filled. Position Price: ",PositionGetDouble(POSITION_PRICE_OPEN));
        }
    }
    // Check if the Sell Limit order was filled (only if buy wasn't)
    if(!buyFilled && currentOIO.sellLimitTicket != 0 && PositionSelectByTicket(currentOIO.sellLimitTicket)) {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
            filledTicket = currentOIO.sellLimitTicket;
            filledOrderType = ORDER_TYPE_SELL;
            sellFilled = true;
            Print("OIO Sell Limit (Ticket:",filledTicket,") filled. Position Price: ",PositionGetDouble(POSITION_PRICE_OPEN));
        }
    }

    if(buyFilled || sellFilled) { // One of the initial orders was filled
        currentOIO.firstFilledOrderTicket = filledTicket;
        currentOIO.firstFilledOrderType = filledOrderType;
        currentOIO.isLongTrade = (filledOrderType == ORDER_TYPE_BUY);
        Print("First OIO order filled: Ticket ", filledTicket, ", Type: ", EnumToString(filledOrderType), ", Direction: ", (currentOIO.isLongTrade?"Long":"Short"));

        // Cancel the opposing unfilled limit order
        if(buyFilled) { CancelOrder(currentOIO.sellLimitTicket, "Buy Limit Filled"); currentOIO.sellLimitTicket = 0; }
        if(sellFilled) { CancelOrder(currentOIO.buyLimitTicket, "Sell Limit Filled"); currentOIO.buyLimitTicket = 0; }

        PlaceChaseOrder(); // Place the second (chase) order at the OIO midpoint
    } else {
        // If no order filled, check if pending orders still exist or were cancelled/expired externally.
        // If a pending order ticket is non-zero but OrderSelect fails, it means the order is gone.
        if(currentOIO.buyLimitTicket != 0 && !OrderSelect(currentOIO.buyLimitTicket)) { Print("Buy Limit Ticket ",currentOIO.buyLimitTicket," no longer exists (not filled)."); currentOIO.buyLimitTicket = 0; }
        if(currentOIO.sellLimitTicket != 0 && !OrderSelect(currentOIO.sellLimitTicket)) { Print("Sell Limit Ticket ",currentOIO.sellLimitTicket," no longer exists (not filled)."); currentOIO.sellLimitTicket = 0; }

        // If both initial pending orders are gone and none were filled, reset the OIO cycle.
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
    // Conditions: OIO active, first order filled, no chase order yet placed.
    if(!currentOIO.isActive || currentOIO.firstFilledOrderTicket == 0 || currentOIO.secondChaseOrderTicket != 0) { Print("PlaceChaseOrder: Conditions not met."); return; }

    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

    PrintFormat("PlaceChaseOrder for OIO ID %d: MidPoint=%.*f, StopsLevel=%d points", currentOIO.id, digits, currentOIO.midPoint, stopsLevel);

    double entryPrice = currentOIO.midPoint; // Midpoint already normalized
    double stopLoss = 0, takeProfit = 0;
    ENUM_ORDER_TYPE orderType = WRONG_VALUE;

    // The SL for the chase order should be the same as the first filled order's SL.
    if(!PositionSelectByTicket(currentOIO.firstFilledOrderTicket)) { Print("PlaceChaseOrder: Failed to select first filled position (TicketID:", currentOIO.firstFilledOrderTicket,"). Cannot set chase order SL."); return; }
    double firstOrderSL = PositionGetDouble(POSITION_SL);

    if(currentOIO.isLongTrade) { // Chase order is also a Buy Limit
        orderType = ORDER_TYPE_BUY_LIMIT;
        stopLoss = firstOrderSL;
        takeProfit = NormalizeDouble(entryPrice + InpTakeProfitTicks * tickSize, digits); // Temporary TP
        PrintFormat("Chase Buy Limit Params: Entry=%.*f, SL=%.*f (Dist: %.1f pts), TP=%.*f (Dist: %.1f pts)", digits, entryPrice, digits, stopLoss, (stopLoss==0)?0:MathAbs(entryPrice-stopLoss)/point, digits, takeProfit, MathAbs(entryPrice-takeProfit)/point);
        if (stopLoss !=0 && stopLoss >= entryPrice) { PrintFormat("Chase Buy SL (%.*f) invalid vs Entry (%.*f)",digits,stopLoss,digits,entryPrice); return; }
        if (takeProfit <= entryPrice) { PrintFormat("Chase Buy TP (%.*f) invalid vs Entry (%.*f)",digits,takeProfit,digits,entryPrice); return; }
         if (stopsLevel > 0 && stopLoss != 0 && MathAbs(entryPrice - stopLoss) < stopsLevel * point) {
            PrintFormat("Chase Buy SL distance (%.1f points) is less than StopsLevel (%d points).", MathAbs(entryPrice-stopLoss)/point, stopsLevel);
        }
    } else { // Chase order is a Sell Limit
        orderType = ORDER_TYPE_SELL_LIMIT;
        stopLoss = firstOrderSL;
        takeProfit = NormalizeDouble(entryPrice - InpTakeProfitTicks * tickSize, digits);
        PrintFormat("Chase Sell Limit Params: Entry=%.*f, SL=%.*f (Dist: %.1f pts), TP=%.*f (Dist: %.1f pts)", digits, entryPrice, digits, stopLoss, (stopLoss==0)?0:MathAbs(entryPrice-stopLoss)/point, digits, takeProfit, MathAbs(entryPrice-takeProfit)/point);
        if (stopLoss != 0 && stopLoss <= entryPrice) { PrintFormat("Chase Sell SL (%.*f) invalid vs Entry (%.*f)",digits,stopLoss,digits,entryPrice); return; }
        if (takeProfit >= entryPrice) { PrintFormat("Chase Sell TP (%.*f) invalid vs Entry (%.*f)",digits,takeProfit,digits,entryPrice); return; }
        if (stopsLevel > 0 && stopLoss != 0 && MathAbs(entryPrice - stopLoss) < stopsLevel * point) {
            PrintFormat("Chase Sell SL distance (%.1f points) is less than StopsLevel (%d points).", MathAbs(entryPrice-stopLoss)/point, stopsLevel);
        }
    }

    // Simple check for limit order price relative to current market (can be improved)
    if(orderType == ORDER_TYPE_BUY_LIMIT && entryPrice > last_tick.ask - tickSize * 2) { Print("Warning: Chase Buy Limit price ",DoubleToString(entryPrice,digits)," is close to/above Ask ",DoubleToString(last_tick.ask,digits)); }
    if(orderType == ORDER_TYPE_SELL_LIMIT && entryPrice < last_tick.bid + tickSize * 2) { Print("Warning: Chase Sell Limit price ",DoubleToString(entryPrice,digits)," is close to/below Bid ",DoubleToString(last_tick.bid,digits)); }

    long ticket = SendPendingOrder(orderType, entryPrice, stopLoss, takeProfit, "OIO Chase " + EnumToString(orderType));
    if(ticket != 0) {
        currentOIO.secondChaseOrderTicket = ticket;
        Print("OIO Chase Order placed successfully. Ticket: ", ticket);
    } else {
        Print("Failed to place OIO Chase Order. First order (TicketID:",currentOIO.firstFilledOrderTicket,") will proceed with its original SL/TP.");
        currentOIO.secondChaseOrderTicket = 0; // Ensure it's zero if placement failed
    }
}

//+------------------------------------------------------------------+
//| Checks execution of the second (chase) order. (Called by OnTrade)|
//+------------------------------------------------------------------+
void CheckChaseOrderExecution()
{
    // Conditions: OIO active, first order filled, chase order was placed, TPs not yet adjusted.
    if(!currentOIO.isActive || currentOIO.firstFilledOrderTicket == 0 || currentOIO.secondChaseOrderTicket == 0 || currentOIO.takeProfitsAdjusted) return;

    // Check if the chase order (identified by its original ticket) has become a position.
    if(PositionSelectByTicket(currentOIO.secondChaseOrderTicket)) {
        if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) { // Ensure it's our EA's position
            Print("OIO Chase Order (Original Ticket:", currentOIO.secondChaseOrderTicket, ") filled. Position Price: ", PositionGetDouble(POSITION_PRICE_OPEN));
            AdjustTakeProfit(); // Both orders are now open, adjust TPs.
        }
    } else if(!OrderSelect(currentOIO.secondChaseOrderTicket)) { // If not a position AND not a pending order, it's gone.
         Print("OIO Chase Order (Ticket:",currentOIO.secondChaseOrderTicket,") no longer exists (not filled, possibly cancelled/expired).");
         currentOIO.secondChaseOrderTicket = 0; // Mark as no longer valid/active
    }
    // If OrderSelect is true, it's still a pending order; wait for it to fill or expire.
}

//+------------------------------------------------------------------+
//| Adjusts Take Profit for both orders after the chase order fills. |
//+------------------------------------------------------------------+
void AdjustTakeProfit()
{
    if(currentOIO.takeProfitsAdjusted) return; // Avoid redundant adjustments
    if(!currentOIO.isActive || currentOIO.firstFilledOrderTicket == 0 || currentOIO.secondChaseOrderTicket == 0) { Print("AdjustTakeProfit: Conditions not met (active OIO and both tickets required)."); return; }

    // Select first position
    if(!PositionSelectByTicket(currentOIO.firstFilledOrderTicket)) { Print("AdjustTakeProfit: Failed to select first position (TicketID:", currentOIO.firstFilledOrderTicket,")"); return; }
    if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) { Print("AdjustTakeProfit: First position (TicketID:",currentOIO.firstFilledOrderTicket,") magic number mismatch."); return; }
    double price1 = PositionGetDouble(POSITION_PRICE_OPEN), vol1 = PositionGetDouble(POSITION_VOLUME), sl1 = PositionGetDouble(POSITION_SL);

    // Select second position (chase order that became a position)
    if(!PositionSelectByTicket(currentOIO.secondChaseOrderTicket)) { Print("AdjustTakeProfit: Failed to select second position (Original Chase TicketID:", currentOIO.secondChaseOrderTicket,")"); return; }
    if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) { Print("AdjustTakeProfit: Second position (Original Chase TicketID:",currentOIO.secondChaseOrderTicket,") magic number mismatch."); return; }
    double price2 = PositionGetDouble(POSITION_PRICE_OPEN), vol2 = PositionGetDouble(POSITION_VOLUME), sl2 = PositionGetDouble(POSITION_SL);

    if(vol1 <= 0 || vol2 <= 0) { Print("AdjustTakeProfit: Invalid position volume(s). V1:",vol1," V2:",vol2); return; }

    // Calculate average entry price for both positions
    double avgEntry = NormalizeDouble(((price1 * vol1) + (price2 * vol2)) / (vol1 + vol2), _Digits);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    // Calculate new Take Profit based on average entry and trade direction
    double newTP = currentOIO.isLongTrade ? NormalizeDouble(avgEntry + InpTakeProfitTicks * tickSize, _Digits) : NormalizeDouble(avgEntry - InpTakeProfitTicks * tickSize, _Digits);

    PrintFormat("AdjustTakeProfit for OIO ID %d: P1=%.*f,V1=%.2f; P2=%.*f,V2=%.2f. AvgEntry=%.*f. New Global TP=%.*f",
        currentOIO.id, _Digits,price1,vol1,_Digits,price2,vol2,_Digits,avgEntry,_Digits,newTP);

    // Modify TP for both positions. SLs remain unchanged.
    bool mod1_success = ModifyPositionSLTP(currentOIO.firstFilledOrderTicket, sl1, newTP);
    bool mod2_success = ModifyPositionSLTP(currentOIO.secondChaseOrderTicket, sl2, newTP);

    if(mod1_success && mod2_success) { Print("Successfully requested TP adjustment for both OIO positions to: ", DoubleToString(newTP, _Digits)); currentOIO.takeProfitsAdjusted = true; }
    else { Print("Error or partial success in adjusting TPs for OIO positions."); }
}

//+------------------------------------------------------------------+
//| Modifies SL/TP for a given position.                             |
//| positionIdentifier is the original order ticket that became this position. |
//+------------------------------------------------------------------+
bool ModifyPositionSLTP(long positionIdentifier, double newSL, double newTP)
{
    // Select the position using its original order ticket (which is its POSITION_IDENTIFIER)
    if(!PositionSelectByTicket(positionIdentifier)) { Print("ModifyPositionSLTP: Failed to select position by original ticket ID: ", positionIdentifier); return false; }
    if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) { Print("ModifyPositionSLTP: Position (Original TicketID:", positionIdentifier,") magic number mismatch."); return false; }

    // Normalize new SL/TP and compare with current to avoid redundant modifications
    double currentSL = NormalizeDouble(PositionGetDouble(POSITION_SL),_Digits);
    double currentTP = NormalizeDouble(PositionGetDouble(POSITION_TP),_Digits);
    newSL = NormalizeDouble(newSL,_Digits); newTP = NormalizeDouble(newTP,_Digits);

    if(currentSL == newSL && currentTP == newTP) { Print("ModifyPositionSLTP: Position (Original TicketID:", positionIdentifier, ") SL/TP already at target values. No modification needed."); return true; }

    MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
    req.action = TRADE_ACTION_SLTP; // Action to modify SL/TP of an open position
    req.position = PositionGetInteger(POSITION_TICKET); // IMPORTANT: For SLTP modification, use POSITION_TICKET
    req.symbol = _Symbol;
    req.sl = newSL;
    req.tp = newTP;

    Print("Attempting to modify SL/TP for Position Ticket:", req.position, " (Original OrderID:",positionIdentifier,") to NewSL:",DoubleToString(newSL,_Digits), ", NewTP:", DoubleToString(newTP,_Digits));
    if(!OrderSend(req, res)) { Print("OrderSend failed for SL/TP modification (PosTicket:", req.position, "), Error: ", GetLastError(), " (Server RetCode:",res.retcode,") - ", res.comment); return false; }

    if(res.retcode == TRADE_RETCODE_DONE) { // For SLTP modification, DONE is the primary success code.
        Print("SL/TP modification request for Position Ticket:", req.position," successful. Server RetCode:",res.retcode); return true;
    } else {
        Print("SL/TP modification request for Position Ticket:", req.position," returned: ", res.retcode, " - ", res.comment); return false;
    }
}

//+------------------------------------------------------------------+
//| Checks if the entire OIO trading cycle has ended.                |
//| (Called by OnTick and OnTrade)                                   |
//+------------------------------------------------------------------+
void CheckTradeCycleEnd()
{
    if(!currentOIO.isActive) return; // Nothing to check if no OIO cycle is active

    // An OIO cycle ends if there are no more active pending orders or open positions related to it.
    bool initialLimitsStillActive = false;
    if(currentOIO.buyLimitTicket != 0 && OrderSelect(currentOIO.buyLimitTicket) && OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED) initialLimitsStillActive = true;
    if(currentOIO.sellLimitTicket != 0 && OrderSelect(currentOIO.sellLimitTicket) && OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED) initialLimitsStillActive = true;

    bool firstPositionStillActive = false;
    if(currentOIO.firstFilledOrderTicket != 0 && PositionSelectByTicket(currentOIO.firstFilledOrderTicket) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) firstPositionStillActive = true;

    bool chaseOrderStillActive = false;
    if(currentOIO.secondChaseOrderTicket != 0) {
        // Check if it's an active pending order
        if(OrderSelect(currentOIO.secondChaseOrderTicket) && OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber) chaseOrderStillActive = true;
        // Check if it's an active position
        else if (PositionSelectByTicket(currentOIO.secondChaseOrderTicket) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) chaseOrderStillActive = true;
    }

    // If none of the potential orders/positions are active, the cycle has ended.
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
    ObjectDelete(0, objectName); // Delete if a rectangle with the same name already exists

    if(!ObjectCreate(0, objectName, OBJ_RECTANGLE, 0, currentOIO.startTime, currentOIO.high, currentOIO.endTime, currentOIO.low)) { Print("Failed to create OIO rectangle '",objectName,"': ", GetLastError()); return; }

    ObjectSetInteger(0, objectName, OBJPROP_COLOR, clrOrange);
    ObjectSetInteger(0, objectName, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, objectName, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, objectName, OBJPROP_BACK, true); // Draw rectangle in the background
    ObjectSetString(0, objectName, OBJPROP_TOOLTIP, "OIO Pattern ID: " + (string)currentOIO.id); // Tooltip for the rectangle
    ChartRedraw(0); // Redraw chart to display the new object
}

//+------------------------------------------------------------------+
//| Resets the global OIO structure to its initial state.            |
//| Also cleans up the chart object associated with the previous OIO.|
//+------------------------------------------------------------------+
void ResetOIOStructure()
{
    // If a previous OIO was active (id is not 0), attempt to delete its chart object.
    if(currentOIO.id != 0) {
      ObjectDelete(0, "OIO_Rect_" + (string)currentOIO.id);
    }

    // Reset all fields of the currentOIO structure.
    currentOIO.startTime = 0; currentOIO.endTime = 0;
    currentOIO.high = 0.0; currentOIO.low = 0.0; currentOIO.midPoint = 0.0;
    currentOIO.isActive = false;
    currentOIO.buyLimitTicket = 0; currentOIO.sellLimitTicket = 0;
    currentOIO.firstFilledOrderTicket = 0; currentOIO.secondChaseOrderTicket = 0;
    currentOIO.firstFilledOrderType = WRONG_VALUE; // Use an invalid enum value for initialization
    currentOIO.isLongTrade = false;
    currentOIO.id = 0;
    currentOIO.takeProfitsAdjusted = false;
    // Print("OIO Structure has been reset."); // Optional: Can be too verbose if called frequently.
}

//+------------------------------------------------------------------+
//| Checks if a new bar has started for the EA's timeframe.          |
//| Returns true if a new bar, false otherwise.                      |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    static datetime lastBarTime = 0; // Stores the time of the last known bar
    datetime currentTime = (datetime)SeriesInfoInteger(_Symbol, InpTimeframe, SERIES_LASTBAR_DATE); // Time of the latest bar on chart

    if(lastBarTime < currentTime) { // If current latest bar time is newer than last known
        lastBarTime = currentTime;  // Update last known bar time
        return(true);               // A new bar has started
    }
    return(false); // No new bar
}

//+------------------------------------------------------------------+
//| Helper function to get the minimum stop level for the symbol.    |
//+------------------------------------------------------------------+
long GetStopsLevel() { return SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL); }

//+------------------------------------------------------------------+
//| Helper to convert Trade Retcode to String for logging            |
//+------------------------------------------------------------------+
string TradeRetcodeToString(uint retcode)
  {
   switch(retcode)
     {
      //--- successful codes
      case TRADE_RETCODE_DONE:                    return("TRADE_RETCODE_DONE (Request accomplished)");
      case TRADE_RETCODE_DONE_PARTIAL:            return("TRADE_RETCODE_DONE_PARTIAL (Request accomplished partially)");
      case TRADE_RETCODE_PLACED:                  return("TRADE_RETCODE_PLACED (Order placed)");
      //--- common errors
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
      //--- other specific errors
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
      case TRADE_RETCODE_INVALID_ACCOUNT:         return("TRADE_RETCODE_INVALID_ACCOUNT (Invalid account or account disabled)");
      default:                                    return("UNKNOWN_TRADE_RETCODE ("+(string)retcode+")");
     }
  }
//+------------------------------------------------------------------+
