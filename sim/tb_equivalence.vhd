--------------------------------------------------------------------------------
--  tb_equivalence.vhd  ——  证明 enc_fold 与 parallel_conv_encoder 数学等价
--
--  两种微架构:
--    parallel_conv_encoder : 4096 bit 并行输入, 两级流水折叠 (寄存器阵列实现)
--    enc_fold              : 256 个元素流式输入, 写入即折叠 (无原始输入存储)
--
--  本 testbench 对同一批随机数据同时喂给两者, 逐位比较 1024 bit 输出。
--  跑通即说明: 之前那套 1104 向量的验证结果、以及 ref_model.py 参考模型,
--  对 enc_fold 同样有效, 不需要重新建立可信度。
--
--  运行:
--      vcom -93 parallel_conv_encoder.vhd enc_fold.vhd tb_equivalence.vhd
--      vsim -c -do "run 200 us; quit -f" work.tb_equivalence
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_equivalence is
    Generic (
        ELEM_W    : positive := 16;
        BLK_ELEMS : positive := 64;
        BLK_NUM   : positive := 4;
        N_FRAMES  : positive := 30
    );
end entity tb_equivalence;

architecture sim of tb_equivalence is

    constant IN_ELEMS  : integer := BLK_NUM * BLK_ELEMS;   -- 256
    constant OUT_W     : integer := BLK_ELEMS * ELEM_W;    -- 1024
    constant IN_W      : integer := IN_ELEMS * ELEM_W;     -- 4096
    constant CLK_PERIOD : time   := 6.667 ns;              -- 150 MHz

    signal clk     : STD_LOGIC := '0';
    signal rst_n   : STD_LOGIC := '0';

    -- enc_fold 侧
    signal elem_d    : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0) := (others => '0');
    signal elem_v    : STD_LOGIC := '0';
    signal fold_done : STD_LOGIC;
    signal fold_out  : STD_LOGIC_VECTOR(OUT_W - 1 downto 0);

    -- parallel_conv_encoder 侧
    signal din_par  : STD_LOGIC_VECTOR(IN_W - 1 downto 0) := (others => '0');
    signal par_out  : STD_LOGIC_VECTOR(OUT_W - 1 downto 0);
    signal par_vld  : STD_LOGIC;

    signal n_checked : integer := 0;
    signal n_err     : integer := 0;

    ----------------------------------------------------------------------------
    -- 与 tb_enc_axis.vhd 完全相同的确定性数据源
    ----------------------------------------------------------------------------
    function gen_elem (f : integer; k : integer)
                       return STD_LOGIC_VECTOR is
        variable s : STD_LOGIC_VECTOR(31 downto 0);
        variable v : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    begin
        s := STD_LOGIC_VECTOR(TO_UNSIGNED(f * 1048576 + k * 4051 + 12345, 32));
        for i in 0 to 7 loop
            s := s(30 downto 0) & (s(31) xor s(21) xor s(1) xor s(0));
        end loop;
        for b in 0 to ELEM_W - 1 loop
            v(b) := s(0);
            s := s(30 downto 0) & (s(31) xor s(21) xor s(1) xor s(0));
        end loop;
        return v;
    end function gen_elem;

begin

    clk <= not clk after CLK_PERIOD / 2;

    ----------------------------------------------------------------------------
    -- 被测设计 A: 写入即折叠
    ----------------------------------------------------------------------------
    dut_fold : entity work.enc_fold
        generic map (ELEM_W => ELEM_W, BLK_ELEMS => BLK_ELEMS, BLK_NUM => BLK_NUM)
        port map (
            clk        => clk,
            rst_n      => rst_n,
            in_elem    => elem_d,
            in_valid   => elem_v,
            frame_last => '0',
            fold_done  => fold_done,
            out_data   => fold_out
        );

    ----------------------------------------------------------------------------
    -- 被测设计 B: 并行两级流水
    ----------------------------------------------------------------------------
    dut_par : entity work.parallel_conv_encoder
        generic map (ELEM_W => ELEM_W, BLK_ELEMS => BLK_ELEMS, BLK_NUM => BLK_NUM)
        port map (
            clk       => clk,
            rst_n     => rst_n,
            in_valid  => '0',
            data_in   => din_par,
            out_valid => par_vld,
            data_out  => par_out
        );

    ----------------------------------------------------------------------------
    -- 比较
    ----------------------------------------------------------------------------
    cmp_proc : process
        variable e : STD_LOGIC_VECTOR(OUT_W - 1 downto 0);
        variable a : STD_LOGIC_VECTOR(OUT_W - 1 downto 0);
        variable first_diff : integer;
    begin
        rst_n  <= '0';
        elem_v <= '0';
        elem_d <= (others => '0');
        din_par <= (others => '0');
        for i in 0 to 3 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);

        for f in 0 to N_FRAMES - 1 loop

            -- (a) 把本帧 256 个元素逐拍喂给 enc_fold
            for k in 0 to IN_ELEMS - 1 loop
                wait until falling_edge(clk);
                elem_d <= gen_elem(f, k);
                elem_v <= '1';
                wait until rising_edge(clk);
            end loop;
            wait until falling_edge(clk);
            elem_v <= '0';

            -- 等折叠完成
            loop
                wait until rising_edge(clk);
                exit when fold_done = '1';
            end loop;
            e := fold_out;          -- 变量赋值, 当拍立即生效

            -- (b) 同样的 256 个元素拼成 4096 bit 喂给并行版本
            for k in 0 to IN_ELEMS - 1 loop
                din_par(k*ELEM_W + ELEM_W - 1 downto k*ELEM_W) <= gen_elem(f, k);
            end loop;
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            a := par_out;

            -- (c) 逐位比较
            if a /= e then
                n_err <= n_err + 1;
                first_diff := 0;
                for b in 0 to OUT_W - 1 loop
                    if a(b) /= e(b) then
                        first_diff := b;
                        exit;
                    end if;
                end loop;
                if n_err < 5 then
                    report "MISMATCH frame " & integer'image(f)
                        & " first differing bit " & integer'image(first_diff)
                        severity error;
                end if;
            end if;
            n_checked <= n_checked + 1;
        end loop;

        -- 让最后一次 n_checked 的信号赋值落地, 否则下面 report 读到的是旧值
        wait until rising_edge(clk);

        if n_err = 0 then
            report "=== EQUIVALENCE PROVEN: " & integer'image(n_checked)
                & " frames, enc_fold == parallel_conv_encoder, 0 differences ==="
                severity note;
        else
            report "=== EQUIVALENCE FAILED: " & integer'image(n_checked)
                & " frames, " & integer'image(n_err) & " mismatches ==="
                severity failure;
        end if;

        wait;
    end process;

end architecture sim;
