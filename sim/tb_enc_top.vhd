--------------------------------------------------------------------------------
--  tb_enc_top.vhd —— 只为给 PowerPlay 产生 VCD 活动数据的极简 testbench
--
--  注意: 这不是功能验证的 testbench (功能验证见 tb_parallel_conv_encoder.vhd),
--        它只负责把 enc_top 跑起来并转储信号翻转情况, 供功耗分析使用。
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tb_enc_top is
end entity tb_enc_top;

architecture sim of tb_enc_top is

    constant CLK_PERIOD : time := 6.667 ns;   -- 150 MHz

    signal clk    : STD_LOGIC := '0';
    signal rst_n  : STD_LOGIC := '0';
    signal ovalid : STD_LOGIC;
    signal dout   : STD_LOGIC_VECTOR(1023 downto 0);

begin

    clk <= not clk after CLK_PERIOD / 2;

    uut : entity work.enc_top
        port map (
            clk      => clk,
            rst_n    => rst_n,
            ovalid   => ovalid,
            data_out => dout
        );

    stim : process
    begin
        rst_n <= '0';
        wait for 100 ns;
        rst_n <= '1';
        wait for 6.6 us;      -- 约 1000 个时钟周期
        report "VCD activity window complete" severity note;
        wait;
    end process;

end architecture sim;
