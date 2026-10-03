# ------------------------------------------------------------------------------
#  constraints_sys.sdc  --  sys_top (完整输入链路) 的时序约束
#
#  对应「需求.txt」L19: 运行频率目标 150 MHz  ->  周期 6.667 ns
#
#  I/O 延迟口径与 constraints_axis.sdc 一致: 按片上互联建模, 各留 0.5 ns。
#  详见 constraints_axis.sdc 里的说明。
#
#  uart_rxd 是异步串口输入, 与时钟无关, 所以对它设 false_path ——
#  uart_recv 内部本来就有两级同步器处理亚稳态。
# ------------------------------------------------------------------------------

create_clock -name sys_clk -period 6.667 -waveform {0.000 3.333} [get_ports {sys_clk}]

derive_clock_uncertainty

# ---- 异步串口输入, 不做时序检查 ---------------------------------------------
set_false_path -from [get_ports {uart_rxd}]

# ---- 编码结果的 AXI4-Stream 主接口 ------------------------------------------
set_input_delay  -clock sys_clk -max 0.500 [get_ports {m_axis_tready}]
set_input_delay  -clock sys_clk -min 0.100 [get_ports {m_axis_tready}]
set_output_delay -clock sys_clk -max 0.500 [get_ports {m_axis_tdata[*] m_axis_tvalid m_axis_tlast rx_overflow}]
set_output_delay -clock sys_clk -min 0.100 [get_ports {m_axis_tdata[*] m_axis_tvalid m_axis_tlast rx_overflow}]

# ---- 复位 --------------------------------------------------------------------
# sys_rst_n 当同步复位用, 参与恢复/移除检查。
