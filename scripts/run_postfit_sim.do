# ------------------------------------------------------------------------------
#  run_postfit_sim.do  ——  布局后门级时序仿真 (post-fit timing simulation)
#
#  用途: 手边没有开发板时, 这是最接近"真的能跑"的验证 —— 仿的是 Quartus
#        实际布局布线之后的门级网表, 并且用 SDF 反标了真实的门延时和互连延时。
#
#  前提: 在 RTL_V2/quartus/enc_axis 目录下已经跑完 map / fit / asm / sta,
#        并生成过门级网表:
#            cd RTL_V2/quartus/enc_axis
#            quartus_eda --simulation --tool=modelsim --format=vhdl \
#                        --output_directory=postfit enc_axis
#
#  用法: 本脚本按**裸文件名**引用工程文件, 所以要先把下面 3 个文件复制到
#        一个纯 ASCII 的临时目录, 再在那里执行 (ModelSim 处理不了中文路径):
#            RTL_V2/quartus/enc_axis/postfit/enc_axis.vho
#            RTL_V2/quartus/enc_axis/postfit/enc_axis_vhd.sdo
#            RTL_V2/quartus/enc_axis/postfit/enc_axis_min_1200mv_0c_vhd_fast.sdo
#            RTL_V2/sim/tb_enc_axis_postfit.vhd
#            RTL_V2/scripts/run_postfit_sim.do
#            cd <那个临时目录>
#            vsim -c -do run_postfit_sim.do
#
#  注意两种角要分开跑, 这是 Altera 的标准做法:
#        setup 检查 -> 慢角 (max 延时) -> enc_axis_vhd.sdo
#        hold  检查 -> 快角 (min 延时) -> enc_axis_min_1200mv_0c_vhd_fast.sdo
#    用 max 延时去查 hold 会得到一堆假报错 (DFFEAS HOLD VIOLATION ON ENA),
#    因为 hold 的最坏情况是"数据/使能最快、时钟最慢", 正好是 max 角的反面。
# ------------------------------------------------------------------------------

# ---- 编译 Quartus 仿真库 -----------------------------------------------------
# 顺序不能颠倒: cycloneive_components 依赖 cycloneive_atoms 里的 cycloneive_atom_pack
vlib altera
vmap altera altera
vcom -93 -work altera {d:/quartus/altera/91sp2/quartus/eda/sim_lib/altera_primitives_components.vhd}
vcom -93 -work altera {d:/quartus/altera/91sp2/quartus/eda/sim_lib/altera_primitives.vhd}

vlib cycloneive
vmap cycloneive cycloneive
vcom -93 -work cycloneive {d:/quartus/altera/91sp2/quartus/eda/sim_lib/cycloneive_atoms.vhd}
vcom -93 -work cycloneive {d:/quartus/altera/91sp2/quartus/eda/sim_lib/cycloneive_components.vhd}

# ---- 编译门级网表和 testbench ------------------------------------------------
vlib work
vmap work work
vcom -93 -work work enc_axis.vho
vcom -93 -work work tb_enc_axis_postfit.vhd

# ---- setup 检查: 慢角 --------------------------------------------------------
echo "=========== setup 检查 (慢角 / max 延时) ==========="
vsim -c -t 1ps -sdfmax /tb_enc_axis_postfit/dut=enc_axis_vhd.sdo \
     -do "run 6 us; quit -f" work.tb_enc_axis_postfit

# ---- hold 检查: 快角 ---------------------------------------------------------
echo "=========== hold 检查 (快角 / min 延时) ==========="
vsim -c -t 1ps -sdfmin /tb_enc_axis_postfit/dut=enc_axis_min_1200mv_0c_vhd_fast.sdo \
     -do "run 6 us; quit -f" work.tb_enc_axis_postfit
