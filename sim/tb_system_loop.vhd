--------------------------------------------------------------------------------
--  tb_system_loop.vhd  ——  整系统端到端验证 (字节进 -> 字节出)
--
--  完整链路:
--     串口字节 ──> uart_to_axis ──> enc_axis ──> axis_to_uart ──> uart_send ──> 串口波形
--        (byte)      16bit元素      4:1压缩        字节拆分        串行
--
--  输入 512 字节 (256 个元素 x 16 bit) -> 输出 128 字节 (64 个元素 x 16 bit)。
--  输出侧对**真实的 uart_txd 波形**做起始位检测 + 位中点采样, 再与独立参考模型
--  exp_elem 逐个比对 —— 也就是完整地验证了"PC 发什么、编码器算得对不对、
--  PC 收回来的是什么"。
--
--  输入侧用字节级激励（宽 rx_done 脉冲）而不是位级, 因为 512 字节在 50 MHz 下
--  要 222 万拍; 位级时序已由 tb_uart_to_axis.vhd 单独验证过。
--
--  ⚠ 时钟必须 20 ns: uart_recv / uart_send 里的 CLK_FREQ = 50 MHz、BPS = 115200
--    是写死的常量。
--
--  运行:
--      vcom -93 enc_fold.vhd enc_axis.vhd uart_to_axis.vhd axis_to_uart.vhd \
--              uart_send.vhd tb_system_loop.vhd
--      vsim -c -do "run 15 ms; quit -f" work.tb_system_loop
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_system_loop is
end entity tb_system_loop;

architecture sim of tb_system_loop is

    constant ELEM_W     : integer := 16;
    constant BLK_ELEMS  : integer := 64;
    constant BLK_NUM    : integer := 4;
    constant IN_ELEMS   : integer := BLK_NUM * BLK_ELEMS;   -- 256
    constant OUT_ELEMS  : integer := BLK_ELEMS;             -- 64
    constant CLK_PERIOD : time    := 20 ns;                 -- 50 MHz
    constant BPS_CNT    : integer := 434;
    constant BYTE_GAP   : integer := 40;                    -- 输入字节间隔(拍)

    signal clk      : STD_LOGIC := '0';
    signal rst_n    : STD_LOGIC := '0';

    -- 模拟 uart_recv 的输出
    signal rx_done  : STD_LOGIC := '0';
    signal rx_data  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

    -- uart_to_axis -> enc_axis
    signal e_tdata  : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    signal e_tvalid : STD_LOGIC;
    signal e_tready : STD_LOGIC;
    signal e_tlast  : STD_LOGIC;
    signal overflow : STD_LOGIC;

    -- enc_axis -> axis_to_uart
    signal o_tdata  : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    signal o_tvalid : STD_LOGIC;
    signal o_tready : STD_LOGIC;
    signal o_tlast  : STD_LOGIC;

    -- axis_to_uart -> uart_send
    signal tx_data  : STD_LOGIC_VECTOR(7 downto 0);
    signal tx_en    : STD_LOGIC;
    signal tx_busy  : STD_LOGIC;
    signal uart_txd : STD_LOGIC;

    signal bytes_ok : integer := 0;
    signal n_err    : integer := 0;

    ----------------------------------------------------------------------------
    -- 参考模型（与其它 testbench 一致）
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
        -- 必须显式声明成有约束的变量再返回: 直接 return 一串 xor 的结果,
        -- 函数返回类型是无限定的, 综合/仿真器可能把方向的解析成 to,
        -- 之后对返回值切片就会报
        --   "Slice range direction (downto) does not match slice prefix (to)"
        variable r    : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    begin
        pr   := j / (BLK_ELEMS / 2);
        m    := j mod (BLK_ELEMS / 2);
        base := pr * 2 * BLK_ELEMS;
        r := gen_elem(f, base + m)
             xor gen_elem(f, base + m + BLK_ELEMS/2)
             xor gen_elem(f, base + BLK_ELEMS + m)
             xor gen_elem(f, base + BLK_ELEMS + m + BLK_ELEMS/2);
        return r;
    end function exp_elem;

begin

    clk <= not clk after CLK_PERIOD / 2;

    ----------------------------------------------------------------------------
    -- 上游: 字节 -> 元素
    ----------------------------------------------------------------------------
    u_conv : entity work.uart_to_axis
        generic map (ELEM_W => ELEM_W, BLK_ELEMS => BLK_ELEMS,
                     BLK_NUM => BLK_NUM, FIFO_DEPTH => 8)
        port map (
            clk => clk, rst_n => rst_n,
            rx_done => rx_done, rx_data => rx_data,
            m_axis_tdata => e_tdata, m_axis_tvalid => e_tvalid,
            m_axis_tready => e_tready, m_axis_tlast => e_tlast,
            overflow => overflow
        );

    ----------------------------------------------------------------------------
    -- 编码器
    ----------------------------------------------------------------------------
    u_enc : entity work.enc_axis
        generic map (ELEM_W => ELEM_W, BLK_ELEMS => BLK_ELEMS, BLK_NUM => BLK_NUM)
        port map (
            aclk => clk, aresetn => rst_n,
            s_axis_tdata => e_tdata, s_axis_tvalid => e_tvalid,
            s_axis_tready => e_tready, s_axis_tlast => e_tlast,
            m_axis_tdata => o_tdata, m_axis_tvalid => o_tvalid,
            m_axis_tready => o_tready, m_axis_tlast => o_tlast
        );

    ----------------------------------------------------------------------------
    -- 下游: 元素 -> 字节
    ----------------------------------------------------------------------------
    u_dconv : entity work.axis_to_uart
        generic map (ELEM_W => ELEM_W)
        port map (
            clk => clk, rst_n => rst_n,
            s_axis_tdata => o_tdata, s_axis_tvalid => o_tvalid,
            s_axis_tready => o_tready, s_axis_tlast => o_tlast,
            tx_data => tx_data, tx_en => tx_en, tx_busy => tx_busy,
            elem_done => open
        );

    ----------------------------------------------------------------------------
    -- 原来的串口发送模块, 未修改
    ----------------------------------------------------------------------------
    u_send : entity work.uart_send
        port map (
            sys_clk => clk, sys_rst_n => rst_n,
            uart_en => tx_en, uart_din => tx_data,
            uart_tx_busy => tx_busy, uart_txd => uart_txd
        );

    ----------------------------------------------------------------------------
    -- 输入激励: 一帧 512 字节, rx_done 用宽脉冲
    ----------------------------------------------------------------------------
    send_proc : process
        variable el : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    begin
        rst_n   <= '0';
        rx_done <= '0';
        rx_data <= (others => '0');
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);

        for k in 0 to IN_ELEMS - 1 loop
            el := gen_elem(0, k);

            wait until falling_edge(clk);
            rx_data <= el(7 downto 0);
            rx_done <= '1';
            for i in 0 to 19 loop wait until rising_edge(clk); end loop;
            wait until falling_edge(clk);
            rx_done <= '0';
            for i in 0 to BYTE_GAP - 1 loop wait until rising_edge(clk); end loop;

            wait until falling_edge(clk);
            rx_data <= el(15 downto 8);
            rx_done <= '1';
            for i in 0 to 19 loop wait until rising_edge(clk); end loop;
            wait until falling_edge(clk);
            rx_done <= '0';
            for i in 0 to BYTE_GAP - 1 loop wait until rising_edge(clk); end loop;
        end loop;

        -- 等 128 个字节全部发完
        for i in 0 to 135 * 10 * BPS_CNT loop
            wait until rising_edge(clk);
        end loop;

        if (n_err = 0) and (bytes_ok = 2 * OUT_ELEMS) and (overflow = '0') then
            report "=== SYSTEM LOOP OK: 512 bytes in -> 128 bytes out, "
                & integer'image(bytes_ok)
                & " bytes checked against reference, 0 errors ===" severity note;
        else
            report "=== SYSTEM LOOP FAILED: bytes=" & integer'image(bytes_ok)
                & " expected=" & integer'image(2 * OUT_ELEMS)
                & " errors=" & integer'image(n_err)
                & " overflow=" & STD_LOGIC'image(overflow) & "====" severity failure;
        end if;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- 输出侧简化串口接收器（与 tb_axis_to_uart 相同）
    ----------------------------------------------------------------------------
    rx_proc : process (clk)
        variable st     : integer := 0;
        variable cnt    : integer := 0;
        variable bidx   : integer := 0;
        variable sh     : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
        variable nbytes : integer := 0;
        variable exp    : STD_LOGIC_VECTOR(7 downto 0);
        variable full   : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
        variable k      : integer;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                st := 0; cnt := 0; bidx := 0; nbytes := 0;
                bytes_ok <= 0; n_err <= 0;
            else
                case st is
                    when 0 =>
                        if uart_txd = '0' then
                            st := 1; cnt := 0;
                        end if;
                    when 1 =>
                        if cnt = BPS_CNT/2 - 1 then
                            st := 2; cnt := 0; bidx := 0;
                        else
                            cnt := cnt + 1;
                        end if;
                    when 2 =>
                        if cnt = BPS_CNT - 1 then
                            cnt := 0;
                            sh(bidx) := uart_txd;
                            if bidx = 7 then st := 3; else bidx := bidx + 1; end if;
                        else
                            cnt := cnt + 1;
                        end if;
                    when others =>
                        if cnt = BPS_CNT/2 - 1 then
                            cnt := 0; st := 0;

                            k := nbytes / 2;
                            full := exp_elem(0, k);
                            if (nbytes mod 2) = 0 then
                                exp := full(7 downto 0);
                            else
                                exp := full(ELEM_W - 1 downto ELEM_W - 8);
                            end if;

                            if sh /= exp then
                                n_err <= n_err + 1;
                                if n_err < 5 then
                                    report "BYTE MISMATCH at index "
                                        & integer'image(nbytes)
                                        & " (output element " & integer'image(k) & ")"
                                        severity error;
                                end if;
                            end if;

                            nbytes   := nbytes + 1;
                            bytes_ok <= nbytes;
                        else
                            cnt := cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture sim;
