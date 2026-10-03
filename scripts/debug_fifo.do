# ------------------------------------------------------------------------------
#  debug_fifo.do —— 跟踪前若干次读写, 找出多读的原因
# ------------------------------------------------------------------------------

vlib work
vmap work work
vcom -93 -work work axis_async_fifo.vhd
vcom -93 -work work tb_axis_async_fifo.vhd

# 只跑 20 个字, 方便逐条看
vsim -c -gN_WORDS=20 work.tb_axis_async_fifo

when -fast {/tb_axis_async_fifo/s_tvalid == '1' && /tb_axis_async_fifo/s_tready == '1'} {
    echo "WRITE  t=[expr {$now/1000.0}]ns data=[examine -radix unsigned /tb_axis_async_fifo/s_tdata] wbin=[examine -radix unsigned /tb_axis_async_fifo/dut/wbin] wgray=[examine -radix unsigned /tb_axis_async_fifo/dut/wgray] wq2_rptr=[examine -radix unsigned /tb_axis_async_fifo/dut/wq2_rptr]"
}

when -fast {/tb_axis_async_fifo/m_tvalid == '1' && /tb_axis_async_fifo/m_tready == '1'} {
    echo "READ   t=[expr {$now/1000.0}]ns data=[examine -radix unsigned /tb_axis_async_fifo/m_tdata] rbin=[examine -radix unsigned /tb_axis_async_fifo/dut/rbin] rgray=[examine -radix unsigned /tb_axis_async_fifo/dut/rgray] rq2_wptr=[examine -radix unsigned /tb_axis_async_fifo/dut/rq2_wptr] rempty=[examine /tb_axis_async_fifo/dut/rempty]"
}

run 8 us
quit -f
