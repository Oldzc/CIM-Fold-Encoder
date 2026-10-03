--------------------------------------------------------------------------------
--  sys_cdc.vhd   ——  双时钟域完整系统 (UART 50 MHz + 编码器 150 MHz)
--
--    ┌────────────── 50 MHz 域 ──────────────┐   ┌──── 150 MHz 域 ────┐
--    uart_rxd ─> uart_recv ─> uart_to_axis ─>│FIFO│─> enc_axis ─>│FIFO│─>
--                                            └────┘              └────┘
--      ─> axis_to_uart ─> uart_send ─> uart_txd          (回到 50 MHz 域)
--
--  为什么必须分两个域:
--    uart_recv / uart_send 里的 CLK_FREQ = 50 MHz、UART_BPS = 115200 是写死的,
--    分频比 BPS_CNT = 434 只在 50 MHz 下才能给出正确的 115200 bps。
--    而编码器数据通路按 150 MHz 收敛（实测 157.75 MHz）。
--    两者不能共用一个时钟, 只能在中间做跨时钟域。
--
--  跨时钟域怎么做的:
--    两个方向各用一个 axis_async_fifo —— 经典的**格雷码指针 + 两级同步器**
--    异步 FIFO。灰码相邻数值只差一位, 跨时钟采样最多错一位, 而这个错误在
--    空/满判断里是安全的（只会偏保守, 不会丢数据）。
--    直接同步多比特二进制指针则会采到"半新半旧"的值, 指针跳到完全错误的位置。
--
--    ⚠ 三个已被验证的模块 (uart_to_axis / enc_axis / axis_to_uart) 一行都没改,
--      CDC 完全隔离在 axis_async_fifo 里。
--
--  复位: 全设计都用异步复位, 同一个 sys_rst_n 送进两个域。
--        两个 FIFO 的指针同时清零 -> 必定是空, 不会出现两域复位先后不一致。
--
--  上板时 clk_150 用 PLL 从 sys_clk 倍频得到（见 pll_50_to_150.vhd / sys_board.vhd）。
--  仿真时直接给两个独立时钟即可, 两个时钟的相位关系不影响正确性。
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity sys_cdc is
    Port (
        sys_clk     : in  STD_LOGIC;    -- 50 MHz, UART 域
        clk_150     : in  STD_LOGIC;    -- 150 MHz, 编码器域 (上板由 PLL 产生)
        sys_rst_n   : in  STD_LOGIC;

        uart_rxd    : in  STD_LOGIC;
        uart_txd    : out STD_LOGIC;

        rx_overflow : out STD_LOGIC      -- 上游 FIFO 溢出粘滞标志 (调试)
    );
end entity sys_cdc;

architecture rtl of sys_cdc is

    ----------------------------------------------------------------
    -- 50 MHz 域: 串口接收 -> 元素
    ----------------------------------------------------------------
    signal rx_done   : STD_LOGIC;
    signal rx_data   : STD_LOGIC_VECTOR(7 downto 0);

    signal a_tdata   : STD_LOGIC_VECTOR(15 downto 0);
    signal a_tvalid  : STD_LOGIC;
    signal a_tready  : STD_LOGIC;
    signal a_tlast   : STD_LOGIC;

    ----------------------------------------------------------------
    -- 跨时钟域: 50 MHz -> 150 MHz
    ----------------------------------------------------------------
    signal b_tdata   : STD_LOGIC_VECTOR(15 downto 0);
    signal b_tvalid  : STD_LOGIC;
    signal b_tready  : STD_LOGIC;
    signal b_tlast   : STD_LOGIC;

    ----------------------------------------------------------------
    -- 150 MHz 域: 编码器
    ----------------------------------------------------------------
    signal c_tdata   : STD_LOGIC_VECTOR(15 downto 0);
    signal c_tvalid  : STD_LOGIC;
    signal c_tready  : STD_LOGIC;
    signal c_tlast   : STD_LOGIC;

    ----------------------------------------------------------------
    -- 跨时钟域: 150 MHz -> 50 MHz
    ----------------------------------------------------------------
    signal d_tdata   : STD_LOGIC_VECTOR(15 downto 0);
    signal d_tvalid  : STD_LOGIC;
    signal d_tready  : STD_LOGIC;
    signal d_tlast   : STD_LOGIC;

    ----------------------------------------------------------------
    -- 50 MHz 域: 元素 -> 串口发送
    ----------------------------------------------------------------
    signal tx_data   : STD_LOGIC_VECTOR(7 downto 0);
    signal tx_en     : STD_LOGIC;
    signal tx_busy   : STD_LOGIC;

begin

    ----------------------------------------------------------------
    -- 串口接收 (原工程文件, 未修改) —— 50 MHz
    ----------------------------------------------------------------
    u_recv : entity work.uart_recv
        port map (
            sys_clk   => sys_clk,
            sys_rst_n => sys_rst_n,
            uart_rxd  => uart_rxd,
            uart_done => rx_done,
            uart_data => rx_data
        );

    ----------------------------------------------------------------
    -- 字节 -> 16bit 元素 —— 50 MHz
    ----------------------------------------------------------------
    u_conv : entity work.uart_to_axis
        generic map (ELEM_W => 16, BLK_ELEMS => 64, BLK_NUM => 4, FIFO_DEPTH => 8)
        port map (
            clk => sys_clk, rst_n => sys_rst_n,
            rx_done => rx_done, rx_data => rx_data,
            m_axis_tdata => a_tdata, m_axis_tvalid => a_tvalid,
            m_axis_tready => a_tready, m_axis_tlast => a_tlast,
            overflow => rx_overflow
        );

    ----------------------------------------------------------------
    -- CDC #1: 50 MHz -> 150 MHz
    ----------------------------------------------------------------
    u_fifo_up : entity work.axis_async_fifo
        generic map (WIDTH => 16, DEPTH => 16)
        port map (
            aresetn   => sys_rst_n,
            s_aclk    => sys_clk,
            s_tdata   => a_tdata,
            s_tvalid  => a_tvalid,
            s_tready  => a_tready,
            s_tlast   => a_tlast,
            m_aclk    => clk_150,
            m_tdata   => b_tdata,
            m_tvalid  => b_tvalid,
            m_tready  => b_tready,
            m_tlast   => b_tlast
        );

    ----------------------------------------------------------------
    -- 编码器 —— 150 MHz
    ----------------------------------------------------------------
    u_enc : entity work.enc_axis
        generic map (ELEM_W => 16, BLK_ELEMS => 64, BLK_NUM => 4)
        port map (
            aclk => clk_150, aresetn => sys_rst_n,
            s_axis_tdata => b_tdata, s_axis_tvalid => b_tvalid,
            s_axis_tready => b_tready, s_axis_tlast => b_tlast,
            m_axis_tdata => c_tdata, m_axis_tvalid => c_tvalid,
            m_axis_tready => c_tready, m_axis_tlast => c_tlast
        );

    ----------------------------------------------------------------
    -- CDC #2: 150 MHz -> 50 MHz
    ----------------------------------------------------------------
    u_fifo_dn : entity work.axis_async_fifo
        generic map (WIDTH => 16, DEPTH => 16)
        port map (
            aresetn   => sys_rst_n,
            s_aclk    => clk_150,
            s_tdata   => c_tdata,
            s_tvalid  => c_tvalid,
            s_tready  => c_tready,
            s_tlast   => c_tlast,
            m_aclk    => sys_clk,
            m_tdata   => d_tdata,
            m_tvalid  => d_tvalid,
            m_tready  => d_tready,
            m_tlast   => d_tlast
        );

    ----------------------------------------------------------------
    -- 元素 -> 字节 —— 50 MHz
    ----------------------------------------------------------------
    u_dconv : entity work.axis_to_uart
        generic map (ELEM_W => 16)
        port map (
            clk => sys_clk, rst_n => sys_rst_n,
            s_axis_tdata => d_tdata, s_axis_tvalid => d_tvalid,
            s_axis_tready => d_tready, s_axis_tlast => d_tlast,
            tx_data => tx_data, tx_en => tx_en, tx_busy => tx_busy,
            elem_done => open
        );

    ----------------------------------------------------------------
    -- 串口发送 (原工程文件, 未修改) —— 50 MHz
    ----------------------------------------------------------------
    u_send : entity work.uart_send
        port map (
            sys_clk => sys_clk, sys_rst_n => sys_rst_n,
            uart_en => tx_en, uart_din => tx_data,
            uart_tx_busy => tx_busy, uart_txd => uart_txd
        );

end architecture rtl;
