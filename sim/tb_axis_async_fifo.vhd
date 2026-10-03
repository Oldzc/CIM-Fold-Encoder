--------------------------------------------------------------------------------
--  tb_axis_async_fifo.vhd  ——  异步 FIFO 的双时钟验证
--
--  两个时钟完全独立, 而且刻意选成"**写快读慢**":
--      wclk = 6.667 ns (150 MHz)   写侧快
--      mclk = 20    ns ( 50 MHz)   读侧慢
--  这样 FIFO 会长期处于接近满的状态, 正好压测满判断和反压路径。
--  （真实系统里两个方向都会出现: 上游 50->150 写慢读快, 下游 150->50 写快读慢。）
--
--  检查内容:
--    * 400 个字, 逐个核对数值和顺序（丢字、重字、乱序都会被抓到）
--    * tlast 必须每 8 个字出现一次, 且位置正确
--    * 读侧随机反压（约 25% 时钟拉低 m_tready）
--    * 结果: 收到的字数与发出的完全一致
--
--  运行:
--      vcom -93 axis_async_fifo.vhd tb_axis_async_fifo.vhd
--      vsim -c -do "run 60 us; quit -f" work.tb_axis_async_fifo
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_axis_async_fifo is
    Generic (
        WIDTH    : positive := 16;
        N_WORDS  : positive := 400;
        PKT_LEN  : positive := 8       -- 每 8 个字一个 packet, 第 8 个带 tlast
    );
end entity tb_axis_async_fifo;

architecture sim of tb_axis_async_fifo is

    constant WCLK_PERIOD : time := 6.667 ns;   -- 写侧 150 MHz
    constant MCLK_PERIOD : time := 20 ns;      -- 读侧  50 MHz

    signal aresetn : STD_LOGIC := '0';

    signal wclk    : STD_LOGIC := '0';
    signal s_tdata : STD_LOGIC_VECTOR(WIDTH - 1 downto 0) := (others => '0');
    signal s_tvalid: STD_LOGIC := '0';
    signal s_tready: STD_LOGIC;
    signal s_tlast : STD_LOGIC := '0';

    signal mclk    : STD_LOGIC := '0';
    signal m_tdata : STD_LOGIC_VECTOR(WIDTH - 1 downto 0);
    signal m_tvalid: STD_LOGIC;
    signal m_tready: STD_LOGIC := '0';
    signal m_tlast : STD_LOGIC;

    signal n_sent : integer := 0;
    signal n_recv : integer := 0;
    signal n_err  : integer := 0;

begin

    wclk <= not wclk after WCLK_PERIOD / 2;
    mclk <= not mclk after MCLK_PERIOD / 2;

    ----------------------------------------------------------------------------
    -- DUT
    ----------------------------------------------------------------------------
    dut : entity work.axis_async_fifo
        generic map (WIDTH => WIDTH, DEPTH => 16)
        port map (
            aresetn   => aresetn,
            s_aclk    => wclk,
            s_tdata   => s_tdata,
            s_tvalid  => s_tvalid,
            s_tready  => s_tready,
            s_tlast   => s_tlast,
            m_aclk    => mclk,
            m_tdata   => m_tdata,
            m_tvalid  => m_tvalid,
            m_tready  => m_tready,
            m_tlast   => m_tlast
        );

    ----------------------------------------------------------------------------
    -- 写侧: 连着灌 N_WORDS 个字, 每个字的值就是它的序号
    ----------------------------------------------------------------------------
    wr_proc : process
        variable gap : integer;
        variable s   : STD_LOGIC_VECTOR(31 downto 0) := X"ACE1BEEF";
    begin
        aresetn  <= '0';
        s_tvalid <= '0';
        s_tlast  <= '0';
        s_tdata  <= (others => '0');
        for i in 0 to 7 loop
            wait until rising_edge(wclk);
        end loop;
        aresetn <= '1';
        wait until rising_edge(wclk);

        for i in 0 to N_WORDS - 1 loop
            wait until falling_edge(wclk);
            s_tdata  <= STD_LOGIC_VECTOR(TO_UNSIGNED(i mod 65536, WIDTH));
            s_tvalid <= '1';
            if (i mod PKT_LEN) = (PKT_LEN - 1) then
                s_tlast <= '1';
            else
                s_tlast <= '0';
            end if;

            -- 等被接收
            loop
                wait until rising_edge(wclk);
                exit when s_tready = '1';
            end loop;

            -- 必须**立刻**撤销 tvalid。
            -- 如果留着不撤, 后面的空隙循环里 tready 仍可能为高,
            -- FIFO 会在下一拍把同一个字再写一遍 —— 结果就是收到的字比发的多。
            -- （真实 AXI 主机也要遵守这一点: 传输完成后要么换新数据, 要么撤 tvalid。）
            s_tvalid <= '0';
            s_tlast  <= '0';
            n_sent <= i + 1;

            -- 随机空隙, 让满/空来回切换
            s := s(30 downto 0) & (s(31) xor s(21) xor s(1) xor s(0));
            if s(3 downto 0) = "0000" then
                gap := 5;
            else
                gap := 0;
            end if;
            for k in 0 to gap loop
                wait until rising_edge(wclk);
            end loop;
        end loop;

        wait until falling_edge(wclk);
        s_tvalid <= '0';
        s_tlast  <= '0';

        -- 等读侧把剩下的取完（读侧慢, 要给够时间）
        for i in 0 to 400 loop
            wait until rising_edge(wclk);
        end loop;

        if (n_err = 0) and (n_recv = N_WORDS) and (n_sent = N_WORDS) then
            report "=== ASYNC FIFO OK: " & integer'image(n_recv)
                & " words across two clocks, 0 errors ===" severity note;
        else
            report "=== ASYNC FIFO FAILED: sent=" & integer'image(n_sent)
                & " recv=" & integer'image(n_recv)
                & " errors=" & integer'image(n_err) & " ===" severity failure;
        end if;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- 读侧反压: 独立时钟上的伪随机 tready
    ----------------------------------------------------------------------------
    bp_proc : process (mclk)
        variable s : STD_LOGIC_VECTOR(31 downto 0) := X"5A5A1234";
    begin
        if rising_edge(mclk) then
            if aresetn = '0' then
                m_tready <= '0';
            else
                s := s(30 downto 0) & (s(31) xor s(21) xor s(1) xor s(0));
                if s(1 downto 0) = "00" then
                    m_tready <= '0';
                else
                    m_tready <= '1';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 读侧检查: 数值、顺序、tlast 位置
    ----------------------------------------------------------------------------
    chk_proc : process (mclk)
        variable exp_d : STD_LOGIC_VECTOR(WIDTH - 1 downto 0);
        variable exp_l : STD_LOGIC;
    begin
        if rising_edge(mclk) then
            if aresetn = '0' then
                n_recv <= 0;
                n_err  <= 0;
            elsif m_tvalid = '1' and m_tready = '1' then
                exp_d := STD_LOGIC_VECTOR(TO_UNSIGNED(n_recv mod 65536, WIDTH));
                if (n_recv mod PKT_LEN) = (PKT_LEN - 1) then
                    exp_l := '1';
                else
                    exp_l := '0';
                end if;

                if m_tdata /= exp_d then
                    n_err <= n_err + 1;
                    if n_err < 5 then
                        report "DATA MISMATCH at word " & integer'image(n_recv)
                            severity error;
                    end if;
                end if;

                if m_tlast /= exp_l then
                    n_err <= n_err + 1;
                    if n_err < 8 then
                        report "TLAST MISMATCH at word " & integer'image(n_recv)
                            severity error;
                    end if;
                end if;

                n_recv <= n_recv + 1;
            end if;
        end if;
    end process;

end architecture sim;
