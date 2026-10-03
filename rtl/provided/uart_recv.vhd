library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity uart_recv is
    Port ( sys_clk   : in  STD_LOGIC;
           sys_rst_n : in  STD_LOGIC;
           uart_rxd  : in  STD_LOGIC;
           uart_done : out STD_LOGIC;
           uart_data : out STD_LOGIC_VECTOR(7 downto 0)

           );
end uart_recv;

architecture Behavioral of uart_recv is

    -- Parameter definitions
    constant CLK_FREQ  : integer := 50000000;  -- 系统时钟频率
    constant UART_BPS  : integer := 115200;    -- 串口波特率
    constant BPS_CNT   : integer := CLK_FREQ / UART_BPS;

    -- Signal declarations
    signal uart_rxd_d0, uart_rxd_d1 : STD_LOGIC := '0';
    signal clk_cnt : integer := 0;
    signal rx_flag : STD_LOGIC := '0';
    signal rx_cnt  : integer := 0;
    signal rxdata  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

begin

    -- 捕获接收端口下降沿
    process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            uart_rxd_d0 <= '0';
            uart_rxd_d1 <= '0';
        elsif rising_edge(sys_clk) then
            uart_rxd_d0 <= uart_rxd;
            uart_rxd_d1 <= uart_rxd_d0;
        end if;
    end process;

    -- 接收控制过程
    process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            rx_flag <= '0';
        elsif rising_edge(sys_clk) then
            if uart_rxd_d1 = '1' and uart_rxd_d0 = '0' then
                rx_flag <= '1';  -- 起始位检测
            elsif rx_cnt = 9 and clk_cnt = (BPS_CNT / 2) then
                rx_flag <= '0';  -- 停止位检测
            end if;
        end if;
    end process;

    -- 时钟计数
    process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            clk_cnt <= 0;
        elsif rising_edge(sys_clk) then
            if rx_flag = '1' then
                if clk_cnt < BPS_CNT - 1 then
                    clk_cnt <= clk_cnt + 1;
                else
                    clk_cnt <= 0;
                end if;
            else
                clk_cnt <= 0;
            end if;
        end if;
    end process;

    -- 数据接收计数
    process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            rx_cnt <= 0;
        elsif rising_edge(sys_clk) then
            if rx_flag = '1' then
                if clk_cnt = BPS_CNT - 1 then
                    rx_cnt <= rx_cnt + 1;
                end if;
            else
                rx_cnt <= 0;
            end if;
        end if;
    end process;

    -- 接收数据寄存
    process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            rxdata <= (others => '0');
        elsif rising_edge(sys_clk) then
            if rx_flag = '1' and clk_cnt = (BPS_CNT / 2) then
                case rx_cnt is
                    when 1 => rxdata(0) <= uart_rxd_d1;
                    when 2 => rxdata(1) <= uart_rxd_d1;
                    when 3 => rxdata(2) <= uart_rxd_d1;
                    when 4 => rxdata(3) <= uart_rxd_d1;
                    when 5 => rxdata(4) <= uart_rxd_d1;
                    when 6 => rxdata(5) <= uart_rxd_d1;
                    when 7 => rxdata(6) <= uart_rxd_d1;
                    when 8 => rxdata(7) <= uart_rxd_d1;
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    -- 接收完成标志
    process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            uart_data <= (others => '0');
            uart_done <= '0';
        elsif rising_edge(sys_clk) then
            if rx_cnt = 9 then
                uart_data <= rxdata;
                uart_done <= '1';
            else
                uart_done <= '0';
            end if;
        end if;
    end process;

end Behavioral;
