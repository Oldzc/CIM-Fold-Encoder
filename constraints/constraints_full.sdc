# ------------------------------------------------------------------------------
#  constraints_full.sdc  --  sys_full (完整系统) 的时序约束
#
#  ============================================================================
#  为什么这个顶层约束 50 MHz 而不是需求里的 150 MHz
#  ============================================================================
#  需求 L19 的 150 MHz 是针对**数据通路**的。而 sys_full 这个顶层里包含
#  uart_recv / uart_send, 它们内部的
#        CLK_FREQ : integer := 50000000;
#        UART_BPS : integer := 115200;
#  是**写死的常量**, 分频比 BPS_CNT = 50000000/115200 = 434 只有在 50 MHz
#  时钟下才能得到正确的 115200 bps。换句话说, 150 MHz **不是这个顶层可以
#  工作的频率**, 拿它去约束只会得到一个没有物理意义的数字。
#
#  所以这里按它真实的 50 MHz 工作点约束; 150 MHz 的能力在 enc_axis 那一层
#  单独验证（实测 157.75 MHz, 见 README 4.4 节）。
#
#  实测: 本顶层在 150 MHz 约束下 Fmax = 134.39 MHz, 关键路径全部落在
#  **原版 uart_send 内部**（clk_cnt[9] -> tx_cnt[28], 数据延迟 7.342 ns）。
#  原因是 uart_send 里 clk_cnt / tx_cnt 用的是 32 位 integer, 比较器和
#  case 译码都是 32 位宽。这是原模块的固有写法, 不是新设计引入的。
#  50 MHz 下它的余量约 2.7 倍, 完全够用。
#
#  如果以后真的要让 UART 域也跑得更快, 把 uart_send 里两个 integer 收窄成
#        signal clk_cnt : integer range 0 to 511 := 0;
#        signal tx_cnt  : integer range 0 to 15  := 0;
#  即可（本次没有改动原文件）。
# ------------------------------------------------------------------------------

create_clock -name sys_clk -period 20.000 -waveform {0.000 10.000} [get_ports {sys_clk}]

derive_clock_uncertainty

# ---- 150 MHz 口径（数据通路能力, 见上面的说明）-----------------------------
# create_clock -name sys_clk -period 6.667 -waveform {0.000 3.333} [get_ports {sys_clk}]

# ---- 异步串口输入, 不做时序检查 ---------------------------------------------
# uart_recv 内部本来就有两级同步器处理亚稳态。
set_false_path -from [get_ports {uart_rxd}]

# ---- 串口输出与调试标志 ------------------------------------------------------
set_output_delay -clock sys_clk -max 5.000 [get_ports {uart_txd rx_overflow}]
set_output_delay -clock sys_clk -min 0.500 [get_ports {uart_txd rx_overflow}]

# ---- 复位 --------------------------------------------------------------------
# sys_rst_n 当同步复位用, 参与恢复/移除检查。
