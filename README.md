# oio
oio sclap system

## 策略概述

这是一个基于MT5平台的OIO（Outside-Inside-Outside）交易策略。OIO结构由连续的三根K线组成，具有特定的价格关系模式。

## OIO结构定义

OIO结构满足以下条件：
- 第1根和第3根K线的最高价都大于等于第2根K线的最高价
- 第1根和第3根K线的最低价都小于等于第2根K线的最低价
- 第2根K线被第1根和第3根K线完全包含

## 策略逻辑

### 1. OIO结构识别
- 实时监控K线数据
- 当检测到OIO结构时，计算其高点、低点和中点
- 在图表上用橙色矩形标记OIO结构

### 2. 订单设置
当第三根K线收盘后，自动设置两张限价单：

**多单：**
- 开仓价：OIO高点 + 1个tick
- 止盈：开仓价 + 3个ticks
- 止损：OIO低点 - 1个tick

**空单：**
- 开仓价：OIO低点 - 1个tick
- 止盈：开仓价 - 3个ticks
- 止损：OIO高点 + 1个tick

### 3. 订单管理
- 当其中一单触发时，自动取消另一单
- 如果多单被触发，在OIO中点设置第二张多单
- 如果空单被触发，在OIO中点设置第二张空单
- 若第二张订单触发，两张订单的止盈价格调整为两单的平均成本价 ± 3个ticks

### 4. 交易结束条件
- 第一张订单立即止盈
- 第一张订单未止盈，且价格回到OIO中点并触发第二张订单，两者订单皆止盈或止损则视为交易结束

## 代码结构说明

### 主要变量
```cpp
struct OIOStructure {
    datetime startTime;         // OIO开始时间
    datetime endTime;           // OIO结束时间
    double high;               // OIO高点
    double low;                // OIO低点
    double midPoint;           // OIO中点
    bool isActive;             // OIO是否激活
    ulong firstOrderTicket;    // 第一张订单号
    ulong secondOrderTicket;   // 第二张订单号
    bool isLong;               // 是否为多头方向
};
```

### 主要函数

#### `OnInit()`
- 初始化交易参数
- 设置魔术数字和交易设置
- 重置OIO结构

#### `OnTick()`
- 检查新K线
- 更新OIO结构
- 处理订单状态

#### `UpdateOIOStructure()`
- 获取最近三根K线的数据
- 检查OIO结构条件
- 计算OIO的高点、低点和中点

#### `PlaceOIOOrders()`
- 设置多单和空单
- 计算止盈止损价格
- 记录订单号

#### `HandleFirstOrderFilled()`
- 处理第一张订单被触发的情况
- 取消对立订单
- 设置第二张订单

#### `AdjustTakeProfit()`
- 计算平均成本价
- 调整止盈价格

## 参数设置

- **魔术数字 (InpMagicNumber)**: 用于识别策略订单的唯一标识
- **交易手数 (InpLotSize)**: 每次交易的手数
- **止损tick数 (InpStopLossTicks)**: 止损距离的tick数
- **止盈tick数 (InpTakeProfitTicks)**: 止盈距离的tick数
- **时间周期 (InpTimeframe)**: 使用的K线周期（M5或M3）

## 安装和使用

1. 将 `OIO_Strategy.mq5` 文件复制到MT5的 `MQL5/Experts` 目录
2. 在MT5中编译EA
3. 将EA拖拽到ES（标普500期货）图表上
4. 设置参数并启用自动交易

## 注意事项

1. **风险控制**: 请确保账户有足够的保证金
2. **回测**: 建议先在模拟账户中测试
3. **参数调整**: 根据市场情况调整止盈止损参数
4. **监控**: 定期检查策略运行状态

## 代码特点

- 详细的注释说明
- 模块化设计
- 错误处理机制
- 完整的订单管理
- 可视化标记功能
