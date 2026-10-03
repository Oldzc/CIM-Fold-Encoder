--------------------------------------------------------------------------------
--  tb_parallel_conv_encoder.vhd   (V2 自校验 testbench)
--
--  验证内容:
--    1. 定向向量: 全 0 / 全 1 / 交替 / 递增
--    2. 随机向量: LFSR 生成的 N_RANDOM 个向量, 逐拍背靠背连续灌入
--    3. 每一个输出都与 testbench 内独立写法的参考模型逐位比对
--    4. 把 (输入, DUT 输出) 以二进制文本形式转储到 vectors.txt,
--       供 ref_model.py 做第三方交叉验证
--    5. 背靠背吞吐测试: 连续 1000 拍给 in_valid
--
--  注: VHDL 字符串字面量只允许 ASCII, 因此 report 消息用英文;
--      注释里的中文不受影响。
--
--  运行 (ModelSim):
--      vlib work
--      vcom -93 parallel_conv_encoder.vhd tb_parallel_conv_encoder.vhd
--      vsim -c -do "run -all; quit -f" work.tb_parallel_conv_encoder
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_parallel_conv_encoder is
    Generic (
        ELEM_W    : positive := 16;   -- 元素位宽
        BLK_ELEMS : positive := 64;   -- 每个存储单元的元素数
        BLK_NUM   : positive := 4;    -- 存储单元个数
        N_RANDOM  : positive := 100   -- 随机向量个数
    );
end entity tb_parallel_conv_encoder;

architecture behavior of tb_parallel_conv_encoder is

    constant IN_W  : integer := BLK_NUM * BLK_ELEMS * ELEM_W;   -- 4096
    constant OUT_W : integer := BLK_ELEMS * ELEM_W;             -- 1024
    constant NHALF : integer := BLK_ELEMS / 2;                  -- 32
    constant NELEM : integer := BLK_NUM * BLK_ELEMS;            -- 256

    constant CLK_PERIOD : time := 6.667 ns;   -- 150 MHz

    signal clk       : STD_LOGIC := '0';
    signal rst_n     : STD_LOGIC := '0';
    signal in_valid  : STD_LOGIC := '0';
    signal data_in   : STD_LOGIC_VECTOR(IN_W - 1 downto 0)  := (others => '0');
    signal out_valid : STD_LOGIC;
    signal data_out  : STD_LOGIC_VECTOR(OUT_W - 1 downto 0);

    -- 与 DUT 流水线对齐的输入历史
    signal hist_v  : STD_LOGIC_VECTOR(IN_W - 1 downto 0) := (others => '0');
    signal hist_v2 : STD_LOGIC_VECTOR(IN_W - 1 downto 0) := (others => '0');
    signal hist_e  : STD_LOGIC := '0';
    signal hist_e2 : STD_LOGIC := '0';

    signal n_checked : integer := 0;
    signal n_errors  : integer := 0;

    -- 转储文件
    file dump_f : text open write_mode is "vectors.txt";

    ----------------------------------------------------------------------------
    -- 参考模型 (与 DUT 的写法完全不同, 用于交叉检查)
    --
    --   DUT  : 单元内折叠 64->32, 再相邻单元逐元素累加
    --   参考 : 直接在 256 个元素的平坦数组上做 4 选 1 抽取异或
    --            out[j] = in[base+m] ^ in[base+m+32] ^ in[base+64+m] ^ in[base+96+m]
    --            其中 pr = j/32, m = j mod 32, base = pr*128
    --   两者是同一个线性变换的两种等价写法。
    ----------------------------------------------------------------------------
    function ref_model(d : STD_LOGIC_VECTOR(IN_W - 1 downto 0))
                       return STD_LOGIC_VECTOR is
        variable r    : STD_LOGIC_VECTOR(OUT_W - 1 downto 0);
        variable pr   : integer;
        variable m    : integer;
        variable base : integer;
    begin
        for j in 0 to BLK_ELEMS - 1 loop
            pr   := j / NHALF;
            m    := j mod NHALF;
            base := pr * 2 * BLK_ELEMS;
            r((j + 1)*ELEM_W - 1 downto j*ELEM_W) :=
                  d((base + m + 1)*ELEM_W - 1 downto (base + m)*ELEM_W)
              xor d((base + m + NHALF + 1)*ELEM_W - 1 downto (base + m + NHALF)*ELEM_W)
              xor d((base + BLK_ELEMS + m + 1)*ELEM_W - 1 downto (base + BLK_ELEMS + m)*ELEM_W)
              xor d((base + BLK_ELEMS + m + NHALF + 1)*ELEM_W - 1
                                                         downto (base + BLK_ELEMS + m + NHALF)*ELEM_W);
        end loop;
        return r;
    end function;

    ----------------------------------------------------------------------------
    -- 测试向量生成
    --   n = 0 : 全 0
    --   n = 1 : 全 1
    --   n = 2 : 元素交替 0xFFFF / 0x0000
    --   n = 3 : 元素 k = k
    --   n >= 4: 以 n 为种子的 32 位 LFSR 产生 4096 个伪随机比特
    ----------------------------------------------------------------------------
    function gen_vec(n : integer) return STD_LOGIC_VECTOR is
        variable v : STD_LOGIC_VECTOR(IN_W - 1 downto 0);
        variable s : STD_LOGIC_VECTOR(31 downto 0);
        variable k : integer;
    begin
        case n is
            when 0 =>
                v := (others => '0');
            when 1 =>
                v := (others => '1');
            when 2 =>
                for k in 0 to NELEM - 1 loop
                    if (k mod 2) = 0 then
                        v((k + 1)*ELEM_W - 1 downto k*ELEM_W) := (others => '1');
                    else
                        v((k + 1)*ELEM_W - 1 downto k*ELEM_W) := (others => '0');
                    end if;
                end loop;
            when 3 =>
                for k in 0 to NELEM - 1 loop
                    v((k + 1)*ELEM_W - 1 downto k*ELEM_W) :=
                        STD_LOGIC_VECTOR(TO_UNSIGNED(k mod 65536, ELEM_W));
                end loop;
            when others =>
                s := STD_LOGIC_VECTOR(TO_UNSIGNED(n + 1, 32));
                for k in 0 to IN_W - 1 loop
                    v(k) := s(0);
                    s := s(30 downto 0) & (s(31) xor s(21) xor s(1) xor s(0));
                end loop;
        end case;
        return v;
    end function;

begin

    ----------------------------------------------------------------------------
    -- 时钟
    ----------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2;

    ----------------------------------------------------------------------------
    -- DUT
    ----------------------------------------------------------------------------
    uut : entity work.parallel_conv_encoder
        generic map (
            ELEM_W    => ELEM_W,
            BLK_ELEMS => BLK_ELEMS,
            BLK_NUM   => BLK_NUM
        )
        port map (
            clk       => clk,
            rst_n     => rst_n,
            in_valid  => in_valid,
            data_in   => data_in,
            out_valid => out_valid,
            data_out  => data_out
        );

    ----------------------------------------------------------------------------
    -- 输入历史 (与 DUT 的两级流水对齐)
    ----------------------------------------------------------------------------
    hist_proc : process (clk)
    begin
        if rising_edge(clk) then
            hist_v  <= data_in;
            hist_v2 <= hist_v;
            hist_e  <= in_valid;
            hist_e2 <= hist_e;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 自校验: 输出应等于两拍之前那一拍输入经参考模型算出的结果
    ----------------------------------------------------------------------------
    check_proc : process (clk)
        variable l   : line;
        variable exp : STD_LOGIC_VECTOR(OUT_W - 1 downto 0);
    begin
        if rising_edge(clk) then
            if hist_e2 = '1' then
                exp := ref_model(hist_v2);
                if data_out /= exp then
                    n_errors <= n_errors + 1;
                    report "MISMATCH at check #" & integer'image(n_checked)
                        severity error;
                end if;
                if out_valid /= '1' then
                    n_errors <= n_errors + 1;
                    report "out_valid low at check #" & integer'image(n_checked)
                        severity error;
                end if;
                n_checked <= n_checked + 1;

                -- 转储: 输入行 + DUT 实际输出行 (二进制, MSB 在前)
                write(l, string'("IN  "));
                write(l, hist_v2);
                writeline(dump_f, l);

                write(l, string'("OUT "));
                write(l, data_out);
                writeline(dump_f, l);
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 激励
    ----------------------------------------------------------------------------
    stim_proc : process
        variable v : STD_LOGIC_VECTOR(IN_W - 1 downto 0);
    begin
        -- 复位
        rst_n    <= '0';
        in_valid <= '0';
        data_in  <= (others => '0');
        for k in 0 to 3 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);

        report "--- directed vectors ---" severity note;
        for n in 0 to 3 loop
            v := gen_vec(n);
            wait until falling_edge(clk);
            data_in  <= v;
            in_valid <= '1';
            wait until rising_edge(clk);
            in_valid <= '0';
            for k in 0 to 3 loop
                wait until rising_edge(clk);
            end loop;
        end loop;

        report "--- random vectors, back-to-back ---" severity note;
        for n in 4 to 4 + N_RANDOM - 1 loop
            v := gen_vec(n);
            wait until falling_edge(clk);
            data_in  <= v;
            in_valid <= '1';
        end loop;
        wait until falling_edge(clk);
        in_valid <= '0';
        for k in 0 to 4 loop
            wait until rising_edge(clk);
        end loop;

        report "--- back-to-back throughput test (1000 beats) ---" severity note;
        for n in 0 to 999 loop
            wait until falling_edge(clk);
            data_in  <= gen_vec(4 + (n mod N_RANDOM));
            in_valid <= '1';
        end loop;
        wait until falling_edge(clk);
        in_valid <= '0';
        for k in 0 to 4 loop
            wait until rising_edge(clk);
        end loop;

        -- 结论
        if n_errors = 0 then
            report "=== ALL TESTS PASSED: " & integer'image(n_checked)
                & " vectors checked, 0 errors ===" severity note;
        else
            report "=== FAILED: " & integer'image(n_checked) & " vectors checked, "
                & integer'image(n_errors) & " errors ===" severity failure;
        end if;

        wait;
    end process;

end architecture behavior;
