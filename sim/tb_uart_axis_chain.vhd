--------------------------------------------------------------------------------
--  tb_uart_axis_chain.vhd  ——  上游链路整链验证
--
--  被测链路:
--     串口字节 (rx_done / rx_data)
--        -> uart_to_axis  (装配成 16 bit 元素, AXI4-Stream 主接口)
--        -> enc_axis      (256 拍 x 16 bit -> 64 拍 x 16 bit, 4:1 压缩)
--
--  刻意模拟的两件真实情况:
--    1. rx_done 是**宽脉冲**（uart_recv 的 uart_done 在停止位期间一直为高,
--       约 BPS_CNT/2 ≈ 217 拍), 不是单拍。上游适配层必须自己取上升沿。
--    2. 下游 m_axis_tready 随机拉低（约 6% 时钟）, 制造反压。
--
--  检查内容:
--    * 最终 64 个输出元素逐个与独立参考模型比对
--    * 每帧第 64 拍 tlast 必须为高, 其余拍必须为低
--    * uart_to_axis 的 overflow 粘滞标志必须始终为 0
--
--  运行:
--      vcom -93 enc_fold.vhd enc_axis.vhd uart_to_axis.vhd tb_uart_axis_chain.vhd
--      vsim -c -do "run 900 us; quit -f" work.tb_uart_axis_chain
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_uart_axis_chain is
end entity tb_uart_axis_chain;

architecture sim of tb_uart_axis_chain is

    constant ELEM_W     : integer := 16;
    constant BLK_ELEMS  : integer := 64;
    constant BLK_NUM    : integer := 4;
    constant IN_ELEMS   : integer := BLK_NUM * BLK_ELEMS;   -- 256
    constant OUT_ELEMS  : integer := BLK_ELEMS;             -- 64
    constant N_FRAMES   : integer := 3;
    constant CLK_PERIOD : time    := 6.667 ns;              -- 150 MHz
    constant BYTE_GAP   : integer := 40;                    -- 字节间空隙(拍)

    signal clk     : STD_LOGIC := '0';
    signal rst_n   : STD_LOGIC := '0';

    -- 模拟 uart_recv 的输出
    signal rx_done : STD_LOGIC := '0';
    signal rx_data : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

    -- uart_to_axis -> enc_axis
    signal e_tdata  : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    signal e_tvalid : STD_LOGIC;
    signal e_tready : STD_LOGIC;
    signal e_tlast  : STD_LOGIC;
    signal overflow : STD_LOGIC;

    -- enc_axis -> 检查器
    signal o_tdata  : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    signal o_tvalid : STD_LOGIC;
    signal o_tready : STD_LOGIC := '0';
    signal o_tlast  : STD_LOGIC;

    signal frames_seen : integer := 0;
    signal n_beats     : integer := 0;
    signal n_err       : integer := 0;

    ----------------------------------------------------------------------------
    -- 与其它 testbench 相同的确定性数据源
    ----------------------------------------------------------------------------
    function gen_elem (f : integer; k : integer) return STD_LOGIC_VECTOR is
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

    function exp_elem (f : integer; j : integer) return STD_LOGIC_VECTOR is
        variable pr   : integer;
        variable m    : integer;
        variable base : integer;
    begin
        pr   := j / (BLK_ELEMS / 2);
        m    := j mod (BLK_ELEMS / 2);
        base := pr * 2 * BLK_ELEMS;
        return gen_elem(f, base + m)
               xor gen_elem(f, base + m + BLK_ELEMS/2)
               xor gen_elem(f, base + BLK_ELEMS + m)
               xor gen_elem(f, base + BLK_ELEMS + m + BLK_ELEMS/2);
    end function exp_elem;

begin

    clk <= not clk after CLK_PERIOD / 2;

    ----------------------------------------------------------------------------
    -- 上游适配层
    ----------------------------------------------------------------------------
    u_conv : entity work.uart_to_axis
        generic map (ELEM_W => ELEM_W, BLK_ELEMS => BLK_ELEMS,
                     BLK_NUM => BLK_NUM, FIFO_DEPTH => 8)
        port map (
            clk           => clk,
            rst_n         => rst_n,
            rx_done       => rx_done,
            rx_data       => rx_data,
            m_axis_tdata  => e_tdata,
            m_axis_tvalid => e_tvalid,
            m_axis_tready => e_tready,
            m_axis_tlast  => e_tlast,
            overflow      => overflow
        );

    ----------------------------------------------------------------------------
    -- 编码器
    ----------------------------------------------------------------------------
    u_enc : entity work.enc_axis
        generic map (ELEM_W => ELEM_W, BLK_ELEMS => BLK_ELEMS, BLK_NUM => BLK_NUM)
        port map (
            aclk          => clk,
            aresetn       => rst_n,
            s_axis_tdata  => e_tdata,
            s_axis_tvalid => e_tvalid,
            s_axis_tready => e_tready,
            s_axis_tlast  => e_tlast,
            m_axis_tdata  => o_tdata,
            m_axis_tvalid => o_tvalid,
            m_axis_tready => o_tready,
            m_axis_tlast  => o_tlast
        );

    ----------------------------------------------------------------------------
    -- 激励: 按字节灌入, rx_done 用宽脉冲模拟 uart_recv
    ----------------------------------------------------------------------------
    send_proc : process
        variable el : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    begin
        rst_n   <= '0';
        rx_done <= '0';
        rx_data <= (others => '0');
        for i in 0 to 7 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);

        for f in 0 to N_FRAMES - 1 loop
            for k in 0 to IN_ELEMS - 1 loop
                el := gen_elem(f, k);

                -- 先发低字节（元素 bit 7:0）
                wait until falling_edge(clk);
                rx_data <= el(7 downto 0);
                rx_done <= '1';
                for i in 0 to 19 loop wait until rising_edge(clk); end loop;
                wait until falling_edge(clk);
                rx_done <= '0';
                for i in 0 to BYTE_GAP - 1 loop wait until rising_edge(clk); end loop;

                -- 再发高字节（元素 bit 15:8）
                wait until falling_edge(clk);
                rx_data <= el(15 downto 8);
                rx_done <= '1';
                for i in 0 to 19 loop wait until rising_edge(clk); end loop;
                wait until falling_edge(clk);
                rx_done <= '0';
                for i in 0 to BYTE_GAP - 1 loop wait until rising_edge(clk); end loop;
            end loop;
        end loop;

        -- 等最后几帧发完
        for i in 0 to 1500 loop
            wait until rising_edge(clk);
        end loop;

        if (n_err = 0) and (frames_seen = N_FRAMES) and (overflow = '0') then
            report "=== CHAIN OK: " & integer'image(frames_seen)
                & " frames, " & integer'image(n_beats)
                & " beats, 0 errors, no overflow ===" severity note;
        else
            report "=== CHAIN FAILED: frames=" & integer'image(frames_seen)
                & " beats=" & integer'image(n_beats)
                & " errors=" & integer'image(n_err)
                & " overflow=" & STD_LOGIC'image(overflow) & " ===" severity failure;
        end if;

        wait;
    end process;

    ----------------------------------------------------------------------------
    -- 下游反压
    ----------------------------------------------------------------------------
    bp_proc : process (clk)
        variable s : STD_LOGIC_VECTOR(31 downto 0) := X"12345678";
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                o_tready <= '0';
            else
                s := s(30 downto 0) & (s(31) xor s(21) xor s(1) xor s(0));
                if s(3 downto 0) = "0000" then
                    o_tready <= '0';
                else
                    o_tready <= '1';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 输出检查
    ----------------------------------------------------------------------------
    check_proc : process (clk)
        variable j   : integer := 0;
        variable f   : integer := 0;
        variable exp : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                j           := 0;
                f           := 0;
                frames_seen <= 0;
                n_beats     <= 0;
                n_err       <= 0;
            elsif o_tvalid = '1' and o_tready = '1' then
                exp := exp_elem(f, j);

                if o_tdata /= exp then
                    n_err <= n_err + 1;
                    if n_err < 5 then
                        report "DATA MISMATCH frame " & integer'image(f)
                            & " elem " & integer'image(j) severity error;
                    end if;
                end if;

                if (j = OUT_ELEMS - 1) and (o_tlast /= '1') then
                    n_err <= n_err + 1;
                    report "tlast missing at frame " & integer'image(f)
                        severity error;
                elsif (j /= OUT_ELEMS - 1) and (o_tlast = '1') then
                    n_err <= n_err + 1;
                    report "tlast asserted early at frame " & integer'image(f)
                        & " elem " & integer'image(j) severity error;
                end if;

                n_beats <= n_beats + 1;

                if j = OUT_ELEMS - 1 then
                    j           := 0;
                    f           := f + 1;
                    frames_seen <= frames_seen + 1;
                else
                    j := j + 1;
                end if;
            end if;
        end if;
    end process;

end architecture sim;
