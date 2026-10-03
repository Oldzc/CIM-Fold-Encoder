--------------------------------------------------------------------------------
--  tb_uart_to_axis.vhd  ——  与真实 uart_recv 的位级联调
--
--  tb_uart_axis_chain.vhd 里我是**模拟** uart_recv 的输出（自己造 rx_done 宽脉冲），
--  这个 testbench 换成**真的** uart_recv，从 uart_rxd 引脚一位一位地灌串行数据,
--  验证上游适配层与真实接收模块的时序确实对得上。
--
--  只发 4 个字节（2 个元素）, 因为完整一帧 512 字节在 50 MHz 下要 444 万拍,
--  仿真太慢; 整帧行为由 tb_uart_axis_chain.vhd 覆盖。这里专门解决一个问题:
--  uart_done 的真实宽度和它与 uart_data 的对齐关系。
--
--  发送的字节: 0x11 0x22 0x33 0x44
--  期望元素:   element0 = 0x2211, element1 = 0x4433   (先到的是低字节)
--
--  运行:
--      vcom -93 uart_recv.vhd uart_to_axis.vhd tb_uart_to_axis.vhd
--      vsim -c -do "run 300 us; quit -f" work.tb_uart_to_axis
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_uart_to_axis is
end entity tb_uart_to_axis;

architecture sim of tb_uart_to_axis is

    -- uart_recv 里的 CLK_FREQ = 50 MHz, UART_BPS = 115200
    -- 所以 BPS_CNT = 50000000/115200 = 434
    constant CLK_PERIOD : time    := 20 ns;    -- 50 MHz, 必须与 uart_recv 一致
    constant BIT_TIME   : time    := 434 * CLK_PERIOD;
    constant N_BYTES    : integer := 4;

    signal clk      : STD_LOGIC := '0';
    signal rst_n    : STD_LOGIC := '0';
    signal uart_rxd : STD_LOGIC := '1';        -- 空闲为高
    signal rx_done  : STD_LOGIC;
    signal rx_data  : STD_LOGIC_VECTOR(7 downto 0);

    signal e_tdata  : STD_LOGIC_VECTOR(15 downto 0);
    signal e_tvalid : STD_LOGIC;
    signal e_tready : STD_LOGIC := '1';        -- 一直就绪, 只看装配对不对
    signal e_tlast  : STD_LOGIC;
    signal overflow : STD_LOGIC;

    signal n_beats : integer := 0;
    signal n_err   : integer := 0;

    type byte_arr_t is array (0 to N_BYTES - 1) of STD_LOGIC_VECTOR(7 downto 0);
    constant TX_BYTES : byte_arr_t := (X"11", X"22", X"33", X"44");

begin

    clk <= not clk after CLK_PERIOD / 2;

    ----------------------------------------------------------------------------
    -- 真实的串口接收模块（原工程里的, 未做任何修改）
    ----------------------------------------------------------------------------
    u_recv : entity work.uart_recv
        port map (
            sys_clk   => clk,
            sys_rst_n => rst_n,
            uart_rxd  => uart_rxd,
            uart_done => rx_done,
            uart_data => rx_data
        );

    ----------------------------------------------------------------------------
    -- 被测的上游适配层
    ----------------------------------------------------------------------------
    u_conv : entity work.uart_to_axis
        generic map (ELEM_W => 16, BLK_ELEMS => 64, BLK_NUM => 4, FIFO_DEPTH => 8)
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
    -- 位级串行激励: 起始位 + 8 位数据(LSB 先) + 停止位
    ----------------------------------------------------------------------------
    send_proc : process
        variable b : STD_LOGIC_VECTOR(7 downto 0);
    begin
        rst_n    <= '0';
        uart_rxd <= '1';
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait for 5 * CLK_PERIOD;

        for n in 0 to N_BYTES - 1 loop
            b := TX_BYTES(n);

            uart_rxd <= '0';                    -- 起始位
            wait for BIT_TIME;

            for i in 0 to 7 loop                -- 数据位, LSB 在前
                uart_rxd <= b(i);
                wait for BIT_TIME;
            end loop;

            uart_rxd <= '1';                    -- 停止位
            wait for BIT_TIME;
            wait for 2 * BIT_TIME;              -- 字节之间留点空隙
        end loop;

        wait for 20 * BIT_TIME;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- 检查装配结果
    ----------------------------------------------------------------------------
    check_proc : process (clk)
        variable n : integer := 0;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                n       := 0;
                n_beats <= 0;
                n_err   <= 0;
            elsif e_tvalid = '1' and e_tready = '1' then
                n := n + 1;
                n_beats <= n;

                case n is
                    when 1 =>
                        if e_tdata /= X"2211" then
                            n_err <= n_err + 1;
                            report "element 0 wrong: expected 2211" severity error;
                        end if;
                    when 2 =>
                        if e_tdata /= X"4433" then
                            n_err <= n_err + 1;
                            report "element 1 wrong: expected 4433" severity error;
                        end if;
                    when others =>
                        null;
                end case;

                -- 帧没满 256 个元素, 不应出现 tlast
                if e_tlast = '1' then
                    n_err <= n_err + 1;
                    report "tlast asserted too early (only " & integer'image(n)
                        & " elements)" severity error;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 收尾判定
    ----------------------------------------------------------------------------
    finish_proc : process
    begin
        -- 4 个字节约需 60 个位时间, 这里等到 80 个位时间再判定
        wait for 80 * BIT_TIME;
        if (n_err = 0) and (n_beats = N_BYTES / 2) and (overflow = '0') then
            report "=== UART->AXIS OK: " & integer'image(n_beats)
                & " elements assembled from real uart_recv, 0 errors ==="
                severity note;
        else
            report "=== UART->AXIS FAILED: beats=" & integer'image(n_beats)
                & " errors=" & integer'image(n_err)
                & " overflow=" & STD_LOGIC'image(overflow) & " ===" severity failure;
        end if;
        wait;
    end process;

end architecture sim;
