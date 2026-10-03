# ------------------------------------------------------------------------------
#  constraints_axis.sdc  --  enc_axis (AXI4-Stream 顶层) 的时序约束
#
#  对应「需求.txt」L19: 运行频率目标 150 MHz  ->  周期 6.667 ns
#
#  ---------------------------------------------------------------------------
#  关于 I/O 延迟怎么取（这一条对结果影响很大，所以写清楚）
#  ---------------------------------------------------------------------------
#  本设计是一个**单个模块**。它在真实系统里的 AXI4-Stream 对端是同一颗芯片
#  内部的其它模块（互联、DMA、缓冲），不是另一颗芯片。所以默认按**片上互联**
#  建模，输入/输出各留 0.5 ns 走线余量。
#
#  如果按"送到片外器件"建模（各留 2 ns），实测 Fmax 会从 161 MHz 掉到
#  130.02 MHz —— 因为 TimeQuest 会把约 2.7 ns 的片内时钟树插入延迟算成
#  负的 clock skew，再叠加 2 ns 的片外预算，150 MHz 就收不住了。
#  那 2 ns 是系统级假设（板级走线 + 对端器件建立时间），不是本设计的能力上限。
#  需要更保守的评估时，把下面 OFFCHIP 那两行取消注释、把 ONCHIP 注释掉。
#
#  两种配置的实测结果都记录在 README 4.4 节。
# ------------------------------------------------------------------------------

# ---- 主时钟: 150 MHz, 占空比 50% --------------------------------------------
create_clock -name aclk -period 6.667 -waveform {0.000 3.333} [get_ports {aclk}]

derive_clock_uncertainty

# ---- ONCHIP: 片上互联建模（默认）--------------------------------------------
set_input_delay  -clock aclk -max 0.500 [get_ports {s_axis_tdata[*] s_axis_tvalid s_axis_tlast m_axis_tready}]
set_input_delay  -clock aclk -min 0.100 [get_ports {s_axis_tdata[*] s_axis_tvalid s_axis_tlast m_axis_tready}]
set_output_delay -clock aclk -max 0.500 [get_ports {s_axis_tready m_axis_tdata[*] m_axis_tvalid m_axis_tlast}]
set_output_delay -clock aclk -min 0.100 [get_ports {s_axis_tready m_axis_tdata[*] m_axis_tvalid m_axis_tlast}]

# ---- OFFCHIP: 片外器件建模（保守，各留 2 ns）--------------------------------
# set_input_delay  -clock aclk -max 2.000 [get_ports {s_axis_tdata[*] s_axis_tvalid s_axis_tlast m_axis_tready}]
# set_input_delay  -clock aclk -min 0.500 [get_ports {s_axis_tdata[*] s_axis_tvalid s_axis_tlast m_axis_tready}]
# set_output_delay -clock aclk -max 2.000 [get_ports {s_axis_tready m_axis_tdata[*] m_axis_tvalid m_axis_tlast}]
# set_output_delay -clock aclk -min 0.500 [get_ports {s_axis_tready m_axis_tdata[*] m_axis_tvalid m_axis_tlast}]
