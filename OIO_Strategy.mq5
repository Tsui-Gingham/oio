//+------------------------------------------------------------------+
//|                                                 OIO_Strategy.mq5 |
//|                        Copyright 2023, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//| Description: EA based on the Outside-Inside-Outside (OIO)        |
//|              candlestick pattern.                                |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.03" // Incremented version for simplification
#property strict

//--- Input Parameters
input int      InpMagicNumber = 12345; // Magic number for EA's orders
input double   InpLotSize     = 0.01;   // Trading lot size
input int      InpStopLossTicks = 10;    // Stop Loss distance in ticks from OIO low/high
input int      InpTakeProfitTicks = 30;  // Take Profit distance in ticks from entry price (or average entry for 2 orders)
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M5; // Timeframe for OIO pattern detection

//--- OIO Structure Definition
struct OIOStructure
{
    datetime startTime;         datetime endTime;
    double   high;              double   low;
    double   midPoint;
    bool     isActive;
    long     buyLimitTicket;    long     sellLimitTicket;
    long     firstFilledOrderTicket;
    long     secondChaseOrderTicket;
    ENUM_ORDER_TYPE firstFilledOrderType;
    bool     isLongTrade;
    int      id;
    bool     takeProfitsAdjusted;
};
OIOStructure currentOIO;
MqlTick last_tick;

//+------------------------------------------------------------------+
string BoolToString(bool value){ return(value ? "true" : "false"); }
//+------------------------------------------------------------------+
int OnInit()
{
    ResetOIOStructure();
    if(InpLotSize <= 0) { Print("Error: Lot size (InpLotSize) must be greater than 0."); return(INIT_PARAMETERS_INCORRECT); }
    if(InpStopLossTicks <= 0) { Print("Error: Stop Loss ticks (InpStopLossTicks) must be greater than 0."); return(INIT_PARAMETERS_INCORRECT); }
    if(InpTakeProfitTicks <= 0) { Print("Error: Take Profit ticks (InpTakeProfitTicks) must be greater than 0."); return(INIT_PARAMETERS_INCORRECT); }
    if(InpMagicNumber <= 0) { Print("Error: Magic number (InpMagicNumber) must be greater than 0."); return(INIT_PARAMETERS_INCORRECT); }
    if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { Print("Error: Trading is not allowed in the terminal."); Alert("Trading is not allowed for OIO_Strategy.mq5!"); return(INIT_FAILED); }
    if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) { Print("Error: EA trading is not allowed."); Alert("Automated trading is not allowed for OIO_Strategy.mq5!"); return(INIT_FAILED); }
    Print("OIO_Strategy initialized successfully. Magic: ", InpMagicNumber, ", Lots: ", InpLotSize, ", TF: ", EnumToString(InpTimeframe));
    Print("SL Ticks: ", InpStopLossTicks, ", TP Ticks: ", InpTakeProfitTicks);
    return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("OIO_Strategy (Last OIO ID: ", currentOIO.id, ") is being deinitialized. Reason code: ", reason);
    if(currentOIO.id != 0) {
        string objectName = "OIO_Rect_" + (string)currentOIO.id;
        ObjectDelete(0, objectName);
    }
    Print("OIO_Strategy deinitialized.");
}
//+------------------------------------------------------------------+
void OnTick()
{
    Print("OnTick called.");
    SymbolInfoTick(_Symbol, last_tick);
    if(currentOIO.isActive){ ManageOrders(); return; }
    if(IsNewBar()){ Print("OnTick: New bar detected, calling UpdateOIOStructure."); UpdateOIOStructure(); }
}
//+------------------------------------------------------------------+
void OnTrade()
{
    if(!currentOIO.isActive) return;
    if(currentOIO.firstFilledOrderTicket == 0 && (currentOIO.buyLimitTicket != 0 || currentOIO.sellLimitTicket != 0)){ CheckLimitOrdersExecution(); }
    else if(currentOIO.firstFilledOrderTicket != 0 && currentOIO.secondChaseOrderTicket != 0 && !currentOIO.takeProfitsAdjusted){ CheckChaseOrderExecution(); }
    CheckTradeCycleEnd();
}
//+------------------------------------------------------------------+
void ManageOrders(){ if(!currentOIO.isActive) return; CheckTradeCycleEnd(); }
//+------------------------------------------------------------------+
void UpdateOIOStructure()
{
    MqlRates rates[];
    if(CopyRates(_Symbol, InpTimeframe, 0, 4, rates) < 4) { Print("UpdateOIOStructure: Failed to get rates for ", _Symbol, " ", EnumToString(InpTimeframe)); return; }
    PrintFormat("UpdateOIOStructure called for bar time: %s (rates[1].time)", TimeToString(rates[1].time));
    double h1=rates[3].high, l1=rates[3].low, h2=rates[2].high, l2=rates[2].low, h3=rates[1].high, l3=rates[1].low;
    bool c1=(h1>=h2 && h3>=h2), c2=(l1<=l2 && l3<=l2);
    PrintFormat("OIO Check for bar %s: c1=%s, c2=%s", TimeToString(rates[1].time), BoolToString(c1), BoolToString(c2));
    if(c1 && c2) {
        if(currentOIO.id==(int)rates[1].time && currentOIO.isActive) return;
        ResetOIOStructure();
        currentOIO.startTime=rates[3].time; currentOIO.endTime=rates[1].time+PeriodSeconds(InpTimeframe);
        currentOIO.high=MathMax(h1,h3); currentOIO.low=MathMin(l1,l3);
        currentOIO.midPoint=NormalizeDouble((currentOIO.high+currentOIO.low)/2.0,_Digits);
        currentOIO.id=(int)rates[1].time;
        Print("OIO Pattern Identified: ID ",currentOIO.id,", Time: ",TimeToString(currentOIO.startTime)," to ",TimeToString(rates[1].time));
        Print("OIO Details - H: ",DoubleToString(currentOIO.high,_Digits),", L: ",DoubleToString(currentOIO.low,_Digits),", M: ",DoubleToString(currentOIO.midPoint,_Digits));
        Print("OIO Conditions Met. Proceeding for OIO ID: ",currentOIO.id);
        DrawOIORectangle(); PlaceOIOOrders();
    } else {
         PrintFormat("OIO conditions not met for bar %s. c1=%s, c2=%s", TimeToString(rates[1].time), BoolToString(c1), BoolToString(c2));
    }
}
//+------------------------------------------------------------------+
void PlaceOIOOrders()
{
    if(currentOIO.isActive || currentOIO.buyLimitTicket!=0 || currentOIO.sellLimitTicket!=0) { Print("PlaceOIOOrders: OIO active/tickets exist."); return; }
    string sym=_Symbol; double ts=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE); int d=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS); double p=SymbolInfoDouble(sym,SYMBOL_POINT);
    // long stopsLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL); // Removed stopsLevel related code
    // PrintFormat("PlaceOIOOrders for ID %d: TickSize=%.*f, Point=%.*f", currentOIO.id, d, ts, d, p);
    if(ts==0){Print("Error: Tick size 0 for ",sym); return;}
    double buyE=NormalizeDouble(currentOIO.high+ts,d), buyTP=NormalizeDouble(buyE+InpTakeProfitTicks*ts,d), buySL=NormalizeDouble(currentOIO.low-ts,d);
    double sellE=NormalizeDouble(currentOIO.low-ts,d), sellTP=NormalizeDouble(sellE-InpTakeProfitTicks*ts,d), sellSL=NormalizeDouble(currentOIO.high+ts,d);
    PrintFormat("Buy Params: E=%.*f SL=%.*f TP=%.*f",d,buyE,d,buySL,d,buyTP);
    PrintFormat("Sell Params: E=%.*f SL=%.*f TP=%.*f",d,sellE,d,sellSL,d,sellTP);
    if(buySL>=buyE || buyTP<=buyE){PrintFormat("Invalid SL/TP Buy");ObjectDelete(0,"OIO_Rect_"+(string)currentOIO.id);return;}
    if(sellSL<=sellE || sellTP>=sellE){PrintFormat("Invalid SL/TP Sell");ObjectDelete(0,"OIO_Rect_"+(string)currentOIO.id);return;}
    long ticket=SendPendingOrder(ORDER_TYPE_BUY_LIMIT,buyE,buySL,buyTP,"OIO BuyL");
    if(ticket==0){Print("Fail OIO BuyL");ObjectDelete(0,"OIO_Rect_"+(string)currentOIO.id);return;} currentOIO.buyLimitTicket=ticket;
    ticket=SendPendingOrder(ORDER_TYPE_SELL_LIMIT,sellE,sellSL,sellTP,"OIO SellL");
    if(ticket==0){Print("Fail OIO SellL. Cancel BuyL.");CancelOrder(currentOIO.buyLimitTicket,"SellL fail");currentOIO.buyLimitTicket=0;ObjectDelete(0,"OIO_Rect_"+(string)currentOIO.id);return;}
    currentOIO.sellLimitTicket=ticket; currentOIO.isActive=true;
    Print("OIO orders placed. BuyL:",currentOIO.buyLimitTicket,", SellL:",currentOIO.sellLimitTicket,". ID:",currentOIO.id);
}
//+------------------------------------------------------------------+
long SendPendingOrder(ENUM_ORDER_TYPE type, double price, double sl, double tp, string comment)
{
    MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
    req.action=TRADE_ACTION_PENDING; req.magic=InpMagicNumber; req.symbol=_Symbol;
    req.volume=InpLotSize; req.price=price; req.sl=sl; req.tp=tp; req.type=type;
    req.type_filling=ORDER_FILLING_FOK; req.comment=comment+" ID "+(string)currentOIO.id;
    Print("Attempting: ",EnumToString(type)," P=",DoubleToString(price,_Digits)," SL=",DoubleToString(sl,_Digits)," TP=",DoubleToString(tp,_Digits)," C:",req.comment);
    if(!OrderSend(req,res)){Print("OrderSend FAIL '",req.comment,"'. OS Err:",GetLastError(),". Server RetCode:",res.retcode); return 0;}
    Print("OrderSend for '",req.comment,"' Resp: RetCode=",res.retcode," (",(string)res.retcode/*TradeRetcodeToString(res.retcode)*/,"), Comment='",res.comment,"', Ticket=",(long)res.order);
    if(res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_PLACED){Print("OK '",req.comment,"' Ticket:",(long)res.order);return (long)res.order;}
    else{Print("FAIL '",req.comment,"' Non-success code:",res.retcode);return 0;}
}
//+------------------------------------------------------------------+
bool CancelOrder(long ticket, string reason)
{
    if(ticket==0)return true; MqlTradeRequest req;MqlTradeResult res;ZeroMemory(req);ZeroMemory(res);
    req.action=TRADE_ACTION_REMOVE;req.order=ticket;
    Print("Cancel ",ticket," Reason:",reason);
    if(!OrderSend(req,res)){Print("Cancel FAIL OS Err (Order:",ticket,") Err:",GetLastError()," RetCode:",res.retcode,"-",res.comment);return false;}
    if(res.retcode==TRADE_RETCODE_DONE){Print("Cancel OK ",ticket," RetCode:",res.retcode);return true;}
    else{Print("Cancel RESP ",ticket," RetCode:",res.retcode,"-",res.comment);
        if(res.retcode==TRADE_RETCODE_INVALID_ORDER||res.retcode==TRADE_RETCODE_REJECT){Print("Order ",ticket," invalid/gone.");return true;}
        return false;}
}
//+------------------------------------------------------------------+
void CheckLimitOrdersExecution()
{
    if(!currentOIO.isActive||currentOIO.firstFilledOrderTicket!=0)return;
    long ft=0;ENUM_ORDER_TYPE fot=WRONG_VALUE;bool bf=false,sf=false;
    if(currentOIO.buyLimitTicket!=0 && PositionSelectByTicket(currentOIO.buyLimitTicket)){
        if(PositionGetInteger(POSITION_MAGIC)==InpMagicNumber && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY){
            ft=currentOIO.buyLimitTicket;fot=ORDER_TYPE_BUY;bf=true;Print("OIO BuyL(",ft,") filled P:",PositionGetDouble(POSITION_PRICE_OPEN));}}
    if(!bf && currentOIO.sellLimitTicket!=0 && PositionSelectByTicket(currentOIO.sellLimitTicket)){
         if(PositionGetInteger(POSITION_MAGIC)==InpMagicNumber && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL){
            ft=currentOIO.sellLimitTicket;fot=ORDER_TYPE_SELL;sf=true;Print("OIO SellL(",ft,") filled P:",PositionGetDouble(POSITION_PRICE_OPEN));}}
    if(bf||sf){
        currentOIO.firstFilledOrderTicket=ft;currentOIO.firstFilledOrderType=fot;currentOIO.isLongTrade=(fot==ORDER_TYPE_BUY);
        Print("First OIO filled: T:",ft,", Type:",EnumToString(fot),", Dir:",(currentOIO.isLongTrade?"L":"S"));
        if(bf){CancelOrder(currentOIO.sellLimitTicket,"Buy Filled");currentOIO.sellLimitTicket=0;}
        if(sf){CancelOrder(currentOIO.buyLimitTicket,"Sell Filled");currentOIO.buyLimitTicket=0;}
        PlaceChaseOrder();
    }else{
        if(currentOIO.buyLimitTicket!=0 && !OrderSelect(currentOIO.buyLimitTicket)){Print("BuyL ",currentOIO.buyLimitTicket," gone.");currentOIO.buyLimitTicket=0;}
        if(currentOIO.sellLimitTicket!=0 && !OrderSelect(currentOIO.sellLimitTicket)){Print("SellL ",currentOIO.sellLimitTicket," gone.");currentOIO.sellLimitTicket=0;}
        if(currentOIO.buyLimitTicket==0 && currentOIO.sellLimitTicket==0 && currentOIO.firstFilledOrderTicket==0){
            Print("Initial limits gone, no fill. OIO ID:",currentOIO.id," terminated."); ResetOIOStructure();}}
}
//+------------------------------------------------------------------+
void PlaceChaseOrder()
{
    if(!currentOIO.isActive||currentOIO.firstFilledOrderTicket==0||currentOIO.secondChaseOrderTicket!=0){Print("PlaceChase: Cond not met.");return;}
    double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);int d=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);/*double p=SymbolInfoDouble(_Symbol,SYMBOL_POINT);long slvl=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);*/
    //PrintFormat("PlaceChase for OIO ID %d: MidP=%.*f, StopsLvl=%d pts",currentOIO.id,d,currentOIO.midPoint,slvl);
    double eP=currentOIO.midPoint;double sl=0,tp=0;ENUM_ORDER_TYPE ot=WRONG_VALUE;
    if(!PositionSelectByTicket(currentOIO.firstFilledOrderTicket)){Print("PlaceChase: Fail select pos1 ",currentOIO.firstFilledOrderTicket);return;}
    double fSL=PositionGetDouble(POSITION_SL);
    if(currentOIO.isLongTrade){ot=ORDER_TYPE_BUY_LIMIT;sl=fSL;tp=NormalizeDouble(eP+InpTakeProfitTicks*ts,d);
        PrintFormat("ChaseBuyP: E=%.*f SL=%.*f TP=%.*f",d,eP,d,sl,d,tp);
        if(sl!=0 && sl>=eP){PrintFormat("ChaseBuy SL invalid");return;} if(tp<=eP){PrintFormat("ChaseBuy TP invalid");return;}
        /*if(slvl>0 && sl!=0 && MathAbs(eP-sl)<slvl*p){PrintFormat("ChaseBuy SL dist < StopsLvl");}*/}
    else{ot=ORDER_TYPE_SELL_LIMIT;sl=fSL;tp=NormalizeDouble(eP-InpTakeProfitTicks*ts,d);
        PrintFormat("ChaseSellP: E=%.*f SL=%.*f TP=%.*f",d,eP,d,sl,d,tp);
        if(sl!=0 && sl<=eP){PrintFormat("ChaseSell SL invalid");return;} if(tp>=eP){PrintFormat("ChaseSell TP invalid");return;}
        /*if(slvl>0 && sl!=0 && MathAbs(eP-sl)<slvl*p){PrintFormat("ChaseSell SL dist < StopsLvl");}*/}
    if(ot==ORDER_TYPE_BUY_LIMIT && eP > last_tick.ask-ts*2){Print("Warn: ChaseBuyL P ",DoubleToString(eP,d)," near Ask ",DoubleToString(last_tick.ask,d));}
    if(ot==ORDER_TYPE_SELL_LIMIT && eP < last_tick.bid+ts*2){Print("Warn: ChaseSellL P ",DoubleToString(eP,d)," near Bid ",DoubleToString(last_tick.bid,d));}
    long ticket=SendPendingOrder(ot,eP,sl,tp,"OIO Chase "+EnumToString(ot));
    if(ticket!=0){currentOIO.secondChaseOrderTicket=ticket;Print("OIO Chase OK. T:",ticket);}
    else{Print("Fail PlaceChase. T1:",currentOIO.firstFilledOrderTicket," proceeds.");currentOIO.secondChaseOrderTicket=0;}
}
//+------------------------------------------------------------------+
void CheckChaseOrderExecution()
{
    if(!currentOIO.isActive||currentOIO.firstFilledOrderTicket==0||currentOIO.secondChaseOrderTicket==0||currentOIO.takeProfitsAdjusted)return;
    if(PositionSelectByTicket(currentOIO.secondChaseOrderTicket)){
        if(PositionGetInteger(POSITION_MAGIC)==InpMagicNumber){
            Print("OIO Chase (OrigT:",currentOIO.secondChaseOrderTicket,") filled. P:",PositionGetDouble(POSITION_PRICE_OPEN)); AdjustTakeProfit();}}
    else if(!OrderSelect(currentOIO.secondChaseOrderTicket)){
         Print("OIO Chase (T:",currentOIO.secondChaseOrderTicket,") gone (not filled)."); currentOIO.secondChaseOrderTicket=0;}
}
//+------------------------------------------------------------------+
void AdjustTakeProfit()
{
    if(currentOIO.takeProfitsAdjusted)return;
    if(!currentOIO.isActive||currentOIO.firstFilledOrderTicket==0||currentOIO.secondChaseOrderTicket==0){Print("AdjustTP: Cond not met.");return;}
    if(!PositionSelectByTicket(currentOIO.firstFilledOrderTicket)){Print("AdjustTP: Fail select P1 ",currentOIO.firstFilledOrderTicket);return;}
    if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber){Print("AdjustTP: P1 ",currentOIO.firstFilledOrderTicket," magic mismatch.");return;}
    double p1=PositionGetDouble(POSITION_PRICE_OPEN),v1=PositionGetDouble(POSITION_VOLUME),sl1=PositionGetDouble(POSITION_SL);
    if(!PositionSelectByTicket(currentOIO.secondChaseOrderTicket)){Print("AdjustTP: Fail select P2 ",currentOIO.secondChaseOrderTicket);return;}
    if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber){Print("AdjustTP: P2 ",currentOIO.secondChaseOrderTicket," magic mismatch.");return;}
    double p2=PositionGetDouble(POSITION_PRICE_OPEN),v2=PositionGetDouble(POSITION_VOLUME),sl2=PositionGetDouble(POSITION_SL);
    if(v1<=0||v2<=0){Print("AdjustTP: Invalid vol. V1:",v1," V2:",v2);return;}
    double avgE=NormalizeDouble(((p1*v1)+(p2*v2))/(v1+v2),_Digits);
    double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
    double newTP=currentOIO.isLongTrade?NormalizeDouble(avgE+InpTakeProfitTicks*ts,_Digits):NormalizeDouble(avgE-InpTakeProfitTicks*ts,_Digits);
    PrintFormat("AdjustTP OIO ID %d: P1=%.*f,V1=%.2f; P2=%.*f,V2=%.2f. AvgE=%.*f. NewTP=%.*f",currentOIO.id,_Digits,p1,v1,_Digits,p2,v2,_Digits,avgE,_Digits,newTP);
    bool m1=ModifyPositionSLTP(currentOIO.firstFilledOrderTicket,sl1,newTP);
    bool m2=ModifyPositionSLTP(currentOIO.secondChaseOrderTicket,sl2,newTP);
    if(m1&&m2){Print("OK TP adjust for OIO to: ",DoubleToString(newTP,_Digits));currentOIO.takeProfitsAdjusted=true;}
    else{Print("ERR TP adjust OIO.");}
}
//+------------------------------------------------------------------+
bool ModifyPositionSLTP(long pID, double nSL, double nTP)
{
    if(!PositionSelectByTicket(pID)){Print("ModSLTP: Fail select pos origID:",pID);return false;}
    if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber){Print("ModSLTP: Pos(origID:",pID,") magic mismatch.");return false;}
    double cSL=NormalizeDouble(PositionGetDouble(POSITION_SL),_Digits),cTP=NormalizeDouble(PositionGetDouble(POSITION_TP),_Digits);
    nSL=NormalizeDouble(nSL,_Digits);nTP=NormalizeDouble(nTP,_Digits);
    if(cSL==nSL && cTP==nTP){Print("ModSLTP: Pos(origID:",pID,") SL/TP no change.");return true;}
    MqlTradeRequest req;MqlTradeResult res;ZeroMemory(req);ZeroMemory(res);
    req.action=TRADE_ACTION_SLTP;req.position=PositionGetInteger(POSITION_TICKET);
    req.symbol=_Symbol;req.sl=nSL;req.tp=nTP;
    Print("ModSLTP PosTicket:",req.position,"(OrigID:",pID,") NewSL:",DoubleToString(nSL,_Digits),", NewTP:",DoubleToString(nTP,_Digits));
    if(!OrderSend(req,res)){Print("ModSLTP OS FAIL PosTicket:",req.position," Err:",GetLastError()," RetCode:",res.retcode,"-",res.comment);return false;}
    if(res.retcode==TRADE_RETCODE_DONE){Print("ModSLTP OK PosTicket:",req.position," RetCode:",res.retcode);return true;}
    else{Print("ModSLTP RESP PosTicket:",req.position," RetCode:",res.retcode,"-",res.comment);return false;}
}
//+------------------------------------------------------------------+
void CheckTradeCycleEnd()
{
    if(!currentOIO.isActive)return;bool limAct=false;
    if(currentOIO.buyLimitTicket!=0 && OrderSelect(currentOIO.buyLimitTicket) && OrderGetInteger(ORDER_STATE)==ORDER_STATE_PLACED)limAct=true;
    if(currentOIO.sellLimitTicket!=0 && OrderSelect(currentOIO.sellLimitTicket) && OrderGetInteger(ORDER_STATE)==ORDER_STATE_PLACED)limAct=true;
    bool p1Act=false;
    if(currentOIO.firstFilledOrderTicket!=0 && PositionSelectByTicket(currentOIO.firstFilledOrderTicket) && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)p1Act=true;
    bool chaseAct=false;
    if(currentOIO.secondChaseOrderTicket!=0){
        if(OrderSelect(currentOIO.secondChaseOrderTicket) && OrderGetInteger(ORDER_STATE)==ORDER_STATE_PLACED && OrderGetInteger(ORDER_MAGIC)==InpMagicNumber)chaseAct=true;
        else if(PositionSelectByTicket(currentOIO.secondChaseOrderTicket) && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)chaseAct=true;}
    if(!limAct && !p1Act && !chaseAct){Print("OIO Cycle End ID:",currentOIO.id,". Reset.");ResetOIOStructure();}
}
//+------------------------------------------------------------------+
void DrawOIORectangle()
{
    string oN="OIO_Rect_"+(string)currentOIO.id; ObjectDelete(0,oN);
    if(!ObjectCreate(0,oN,OBJ_RECTANGLE,0,currentOIO.startTime,currentOIO.high,currentOIO.endTime,currentOIO.low)){Print("Fail create rect '",oN,"':",GetLastError());return;}
    ObjectSetInteger(0,oN,OBJPROP_COLOR,clrOrange);ObjectSetInteger(0,oN,OBJPROP_STYLE,STYLE_SOLID);
    ObjectSetInteger(0,oN,OBJPROP_WIDTH,1);ObjectSetInteger(0,oN,OBJPROP_BACK,true);
    ObjectSetString(0,oN,OBJPROP_TOOLTIP,"OIO ID: "+(string)currentOIO.id);ChartRedraw(0);
}
//+------------------------------------------------------------------+
void ResetOIOStructure()
{
    if(currentOIO.id!=0){ObjectDelete(0,"OIO_Rect_"+(string)currentOIO.id);}
    currentOIO.startTime=0;currentOIO.endTime=0;currentOIO.high=0.0;currentOIO.low=0.0;currentOIO.midPoint=0.0;
    currentOIO.isActive=false;currentOIO.buyLimitTicket=0;currentOIO.sellLimitTicket=0;
    currentOIO.firstFilledOrderTicket=0;currentOIO.secondChaseOrderTicket=0;
    currentOIO.firstFilledOrderType=WRONG_VALUE;currentOIO.isLongTrade=false;
    currentOIO.id=0;currentOIO.takeProfitsAdjusted=false;
}
//+------------------------------------------------------------------+
bool IsNewBar()
{
    static datetime lastBarTime=0;datetime curTime=(datetime)SeriesInfoInteger(_Symbol,InpTimeframe,SERIES_LASTBAR_DATE);
    if(lastBarTime<curTime){PrintFormat("IsNewBar: New. last=%s, new=%s",TimeToString(lastBarTime),TimeToString(curTime));lastBarTime=curTime;return(true);}
    return(false);
}
//+------------------------------------------------------------------+
// long GetStopsLevel() { return SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL); } // Temporarily removed

// string TradeRetcodeToString(int retcode) // Temporarily removed
// {
//    switch(retcode)
//      {
//       case TRADE_RETCODE_DONE:                    return("TRADE_RETCODE_DONE (Request accomplished)");
//       case TRADE_RETCODE_DONE_PARTIAL:            return("TRADE_RETCODE_DONE_PARTIAL (Request accomplished partially)");
//       case TRADE_RETCODE_PLACED:                  return("TRADE_RETCODE_PLACED (Order placed)");
//       // ... other cases from previous version, excluding TRADE_RETCODE_INVALID_ACCOUNT
//       default:                                    return("UNKNOWN_TRADE_RETCODE ("+(string)retcode+")");
//      }
// }
//+------------------------------------------------------------------+

[end of OIO_Strategy.mq5]

[end of OIO_Strategy.mq5]
