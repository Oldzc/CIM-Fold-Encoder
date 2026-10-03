# ------------------------------------------------------------------------------
#  constraints.sdc  ——  基于存内计算的高效编码器 (V2)
#
#  对应「需求.txt」L19: 运行频率目标 150 MHz
#      150 MHz  ->  周期 = 1/150e6 = 6.667 ns
#
#  用法:
#    在 Quartus 里 Assignments -> Settings -> TimeQuest Timing Analyzer
#    添加本文件为 SDC 约束; 或在 .qsf 中:
#        set_global_assignment -name SDC_FILE constraints.sdc
#
#  说明: 原工程 (testfinal) 完全没有时序约束, TimeQuest 因此自动用
#        create_clock -period 1.000  (即 1000 MHz) 去推算, 报出来的
#        Slack = -6.334 ns 是相对这个虚构时钟的, 没有实际意义。
#        本文件把真实目标频率写进去, 之后的 Slack / Fmax 才可信。
# ------------------------------------------------------------------------------

# ---- 主时钟: 150 MHz, 占空比 50% --------------------------------------------
create_clock -name clk -period 6.667 -waveform {0.000 3.333} [get_ports {clk}]

# ---- 自动推导时钟不确定度 (jitter / 偏斜) -----------------------------------
derive_clock_uncertainty

# ---- 输入延迟 ----------------------------------------------------------------
# data_in 由上游寄存器驱动, 建模为 2 ns 的片外/布线延迟。
# 若上游模块与本模块在同一器件内, 可改为 set_input_delay -clock clk 1.0
set_input_delay -clock clk -max 2.000 [get_ports {data_in[*]}]
set_input_delay -clock clk -min 0.500 [get_ports {data_in[*]}]
set_input_delay -clock clk -max 2.000 [get_ports {in_valid}]
set_input_delay -clock clk -min 0.500 [get_ports {in_valid}]

# ---- 输出延迟 ----------------------------------------------------------------
# data_out 送到下游寄存器, 同样留 2 ns 余量。
set_output_delay -clock clk -max 2.000 [get_ports {data_out[*]}]
set_output_delay -clock clk -min 0.500 [get_ports {data_out[*]}]
set_output_delay -clock clk -max 2.000 [get_ports {out_valid}]
set_output_delay -clock clk -min 0.500 [get_ports {out_valid}]

# ---- 复位 --------------------------------------------------------------------
# rst_n 为同步复位, 参与恢复/移除时间检查, 不做 false_path 处理。
