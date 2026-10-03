--------------------------------------------------------------------------------
--  tb_axis_to_uart.vhd  ——  下游链路验证 (AXI4-Stream 元素 -> 串口字节)
--
--  被测链路:
--     AXI4-Stream 64 拍 x 16 bit  ->  axis_to_uart  ->  uart_send  ->  uart_txd
--     期望: 128 个字节, element[k] 先发低字节再发高字节
--
--  testbench 里写了一个简化版串口接收器, 直接对**真实的 uart_txd 波形**做
--  起始位检测 + 位中点采样, 再把收到的字节与 gen_elem 逐个比对。
--  这样验证的是真正的串行时序, 而不是内部握手信号。
--
--  ⚠ 时钟必须是 20 ns: uart_send 里的 CLK_FREQ = 50 MHz、UART_BPS = 115200
--    写死, BPS_CNT = 434 只在 50 MHz 下正确。
--
--  运行:
--      vcom -93 axis_to_uart.vhd uart_send.vhd tb_axis_to_uart.vhd
--      vsim -c -do "run 13 ms; quit -f" work.tb_axis_to_uart
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_axis_to_uart is
end entity tb_axis_to_uart;

architecture sim of tb_axis_to_uart is

    constant ELEM_W     : integer := 16;
    constant OUT_ELEMS  : integer := 64;      -- 一帧 64 个元素
    constant N_BYTES    : integer := 128;     -- 64 x 2
    constant CLK_PERIOD : time    := 20 ns;   -- 50 MHz, 必须与 uart_send 一致
    constant BPS_CNT    : integer := 434;     -- 50000000 / 115200

    signal clk      : STD_LOGIC := '0';
    signal rst_n    : STD_LOGIC := '0';

    signal s_tdata  : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0) := (others => '0');
    signal s_tvalid : STD_LOGIC := '0';
    signal s_tready : STD_LOGIC;
    signal s_tlast  : STD_LOGIC := '0';

    signal tx_data  : STD_LOGIC_VECTOR(7 downto 0);
    signal tx_en    : STD_LOGIC;
    signal tx_busy  : STD_LOGIC;
    signal uart_txd : STD_LOGIC;

    signal bytes_ok  : integer := 0;
    signal n_err     : integer := 0;

    ----------------------------------------------------------------------------
    -- 数据源: 与其它 testbench 相同的确定性生成器
    ----------------------------------------------------------------------------
    function gen_elem (k : integer) return STD_LOGIC_VECTOR is
        variable s : STD_LOGIC_VECTOR(31 downto 0);
        variable v : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    begin
        s := STD_LOGIC_VECTOR(TO_UNSIGNED(k * 4051 + 12345, 32));
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
    -- 被测: AXI4-Stream -> 字节
    ----------------------------------------------------------------------------
    u_conv : entity work.axis_to_uart
        generic map (ELEM_W => ELEM_W)
        port map (
            clk           => clk,
            rst_n         => rst_n,
            s_axis_tdata  => s_tdata,
            s_axis_tvalid => s_tvalid,
            s_axis_tready => s_tready,
            s_axis_tlast  => s_tlast,
            tx_data       => tx_data,
            tx_en         => tx_en,
            tx_busy       => tx_busy,
            elem_done     => open
        );

    ----------------------------------------------------------------------------
    -- 原来的串口发送模块, 未修改
    ----------------------------------------------------------------------------
    u_send : entity work.uart_send
        port map (
            sys_clk      => clk,
            sys_rst_n    => rst_n,
            uart_en      => tx_en,
            uart_din     => tx_data,
            uart_tx_busy => tx_busy,
            uart_txd     => uart_txd
        );

    ----------------------------------------------------------------------------
    -- 激励: 连续灌 64 拍 (AXI 会自然反压, 因为串口慢)
    ----------------------------------------------------------------------------
    send_proc : process
    begin
        rst_n    <= '0';
        s_tvalid <= '0';
        s_tlast  <= '0';
        s_tdata  <= (others => '0');
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);

        for j in 0 to OUT_ELEMS - 1 loop
            wait until falling_edge(clk);
            s_tdata  <= gen_elem(j);
            s_tvalid <= '1';
            if j = OUT_ELEMS - 1 then
                s_tlast <= '1';
            else
                s_tlast <= '0';
            end if;
            loop
                wait until rising_edge(clk);
                exit when s_tready = '1';
            end loop;
        end loop;

        wait until falling_edge(clk);
        s_tvalid <= '0';
        s_tlast  <= '0';

        -- 等最后几个字节发完
        for i in 0 to 20 * BPS_CNT loop
            wait until rising_edge(clk);
        end loop;

        if (n_err = 0) and (bytes_ok = N_BYTES) then
            report "=== AXIS->UART OK: " & integer'image(bytes_ok)
                & " bytes decoded from real uart_txd, 0 errors ===" severity note;
        else
            report "=== AXIS->UART FAILED: bytes=" & integer'image(bytes_ok)
                & " expected=" & integer'image(N_BYTES)
                & " errors=" & integer'image(n_err) & " ===" severity failure;
        end if;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- 简化版串口接收器: 对真实 uart_txd 做起始位检测 + 位中点采样
    --
    --   状态 0 空闲  : 见到 txd='0' 认为起始位开始
    --   状态 1 起始位: 数半个位周期, 到起始位中点
    --   状态 2 数据位: 每个位周期采一次, 共 8 次 (LSB 先)
    --   状态 3 停止位: 再数半个位周期就回空闲
    --                  （uart_send 的停止位被截短到 BPS_CNT-BPS_CNT/16,
    --                    所以必须在中点就撤, 否则会错过下一个起始位)
    ----------------------------------------------------------------------------
    rx_proc : process (clk)
        variable st      : integer := 0;
        variable cnt     : integer := 0;
        variable bidx    : integer := 0;
        variable sh      : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
        variable nbytes  : integer := 0;
        variable exp     : STD_LOGIC_VECTOR(7 downto 0);
        variable k       : integer;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                st       := 0;
                cnt      := 0;
                bidx     := 0;
                nbytes   := 0;
                bytes_ok <= 0;
                n_err    <= 0;
            else
                case st is

                    when 0 =>                       -- 空闲, 等起始位
                        if uart_txd = '0' then
                            st  := 1;
                            cnt := 0;
                        end if;

                    when 1 =>                       -- 数半个位周期
                        if cnt = BPS_CNT/2 - 1 then
                            st   := 2;
                            cnt  := 0;
                            bidx := 0;
                        else
                            cnt := cnt + 1;
                        end if;

                    when 2 =>                       -- 8 个数据位
                        if cnt = BPS_CNT - 1 then
                            cnt       := 0;
                            sh(bidx)  := uart_txd;
                            if bidx = 7 then
                                st := 3;
                            else
                                bidx := bidx + 1;
                            end if;
                        else
                            cnt := cnt + 1;
                        end if;

                    when others =>                  -- 停止位中点
                        if cnt = BPS_CNT/2 - 1 then
                            cnt := 0;
                            st  := 0;

                            -- 与期望比对: 偶数序号是低字节, 奇数序号是高字节
                            k   := nbytes / 2;
                            if (nbytes mod 2) = 0 then
                                exp := gen_elem(k)(7 downto 0);
                            else
                                exp := gen_elem(k)(ELEM_W - 1 downto ELEM_W - 8);
                            end if;

                            if sh /= exp then
                                n_err <= n_err + 1;
                                if n_err < 5 then
                                    report "BYTE MISMATCH at index "
                                        & integer'image(nbytes)
                                        & " (element " & integer'image(k) & ")"
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
