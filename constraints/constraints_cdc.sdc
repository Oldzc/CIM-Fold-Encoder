# ------------------------------------------------------------------------------
#  constraints_cdc.sdc  --  sys_cdc (双时钟域系统) 的时序约束
#
#  两个时钟:
#    sys_clk  = 50 MHz  (20.000 ns)  UART 域 —— uart_recv/uart_send 的波特率
#                                    分频比是按 50 MHz 写死的, 必须跑这个频率
#    clk_150  = 150 MHz (6.667 ns)   编码器域 —— 对应需求 L19
#
#  关键的一条是 set_clock_groups -asynchronous:
#    两个域之间**不应该**做静态时序分析。它们之间的数据是靠
#    axis_async_fifo 里的格雷码指针 + 两级同步器传递的, 属于跨时钟域路径,
#    拿建立/保持时间去约束它没有意义（路径两端根本没有共同的时钟周期关系）。
#    如果不写这条, TimeQuest 会报一堆跨域路径的违例, 而那些"违例"既不是
#    真问题, 也会把真正的违例淹没掉。
#
#    这条约束的前提是: 跨域路径上确实只传格雷码指针, 而且每根都过了两级同步器。
#    axis_async_fifo 就是这么写的。
# ------------------------------------------------------------------------------

create_clock -name sys_clk -period 20.000 -waveform {0.000 10.000} [get_ports {sys_clk}]
create_clock -name clk_150 -period  6.667 -waveform {0.000  3.333} [get_ports {clk_150}]

derive_clock_uncertainty

# ---- 两个时钟域异步, 域间路径不做建立/保持分析 ------------------------------
set_clock_groups -asynchronous -group {sys_clk} -group {clk_150}

# ---- 异步串口输入 ------------------------------------------------------------
# uart_recv 内部本来就有两级同步器处理亚稳态。
set_false_path -from [get_ports {uart_rxd}]

# ---- 串口输出与调试标志 (50 MHz 域) -----------------------------------------
set_output_delay -clock sys_clk -max 5.000 [get_ports {uart_txd rx_overflow}]
set_output_delay -clock sys_clk -min 0.500 [get_ports {uart_txd rx_overflow}]
