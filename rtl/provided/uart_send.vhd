library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity uart_send is
    Port ( sys_clk    : in  STD_LOGIC;
           sys_rst_n  : in  STD_LOGIC;
           uart_en    : in  STD_LOGIC;
           uart_din   : in  STD_LOGIC_VECTOR(7 downto 0);
           uart_tx_busy : out STD_LOGIC;
           uart_txd   : out STD_LOGIC
           
          
           );
end uart_send;

architecture Behavioral of uart_send is

    -- Parameter definitions
    constant CLK_FREQ  : integer := 50000000;
    constant UART_BPS  : integer := 115200;
    constant BPS_CNT   : integer := CLK_FREQ / UART_BPS;

    -- Signal declarations
    signal clk_cnt : integer := 0;
    signal tx_flag : STD_LOGIC := '0';
    signal tx_cnt  : integer := 0;
    signal tx_data : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal uart_en_d0, uart_en_d1 : STD_LOGIC := '0';

begin

    -- UART 发送控制过程
    process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            uart_en_d0 <= '0';
            uart_en_d1 <= '0';
        elsif rising_edge(sys_clk) then
            uart_en_d0 <= uart_en;
            uart_en_d1 <= uart_en_d0;
        end if;
    end process;

    -- 发送过程控制
    process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            tx_flag <= '0';
            tx_data <= (others => '0');
        elsif rising_edge(sys_clk) then
            if uart_en_d1 = '0' and uart_en_d0 = '1' then
                tx_flag <= '1';
                tx_data <= uart_din;
            elsif tx_cnt = 9 and clk_cnt = (BPS_CNT - (BPS_CNT / 16)) then
                tx_flag <= '0';
            end if;
        end if;
    end process;

    -- 时钟计数
    process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            clk_cnt <= 0;
        elsif rising_edge(sys_clk) then
            if tx_flag = '1' then
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

    -- 发送计数
    process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            tx_cnt <= 0;
        elsif rising_edge(sys_clk) then
            if tx_flag = '1' then
                if clk_cnt = BPS_CNT - 1 then
                    tx_cnt <= tx_cnt + 1;
                end if;
            else
                tx_cnt <= 0;
            end if;
        end if;
    end process;

    -- 给 uart 发送端口赋值
    process(sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            uart_txd <= '1';
        elsif rising_edge(sys_clk) then
            if tx_flag = '1' then
                case tx_cnt is
                    when 0 => uart_txd <= '0';     -- 起始位
                    when 1 => uart_txd <= tx_data(0);
                    when 2 => uart_txd <= tx_data(1);
                    when 3 => uart_txd <= tx_data(2);
                    when 4 => uart_txd <= tx_data(3);
                    when 5 => uart_txd <= tx_data(4);
                    when 6 => uart_txd <= tx_data(5);
                    when 7 => uart_txd <= tx_data(6);
                    when 8 => uart_txd <= tx_data(7);
                    when 9 => uart_txd <= '1';     -- 停止位
                    when others => null;
                end case;
            else
                uart_txd <= '1'; -- 空闲时为高电平
            end if;
        end if;
    end process;

    -- 发送忙状态标志
	uart_tx_busy <= tx_flag;


end Behavioral;
