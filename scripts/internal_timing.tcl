# ------------------------------------------------------------------------------
#  internal_timing.tcl —— 单独查询 parallel_conv_encoder 内部
#  寄存器到寄存器路径的时序余量（排除输出引脚路径）
#
#  用法:  **必须先 cd 到工程目录**, 再带上脚本路径执行:
#             cd RTL_V2/quartus/enc_v2
#             quartus_sta -t ../../scripts/internal_timing.tcl
#
#         不能写成 project_open <绝对路径>: 本仓库路径里有中文,
#         Quartus 会报 "Project does not exist or has illegal name characters"。
# ------------------------------------------------------------------------------

project_open enc_v2
create_timing_netlist
read_sdc
update_timing_netlist

puts ""
puts "############ 阶段1: din 寄存器 -> mid 寄存器 ############"
report_timing -setup -npaths 3 \
    -to [get_keepers {parallel_conv_encoder:uut|mid[*]}] \
    -detail summary

puts ""
puts "############ 阶段2: mid 寄存器 -> dout 寄存器 ############"
report_timing -setup -npaths 3 \
    -from [get_keepers {parallel_conv_encoder:uut|mid[*]}] \
    -to   [get_keepers {parallel_conv_encoder:uut|dout[*]}] \
    -detail summary

puts ""
puts "############ DUT 内部全部寄存器到寄存器路径 ############"
report_timing -setup -npaths 5 \
    -from [get_keepers {parallel_conv_encoder:uut|*}] \
    -to   [get_keepers {parallel_conv_encoder:uut|*}] \
    -detail summary

project_close
