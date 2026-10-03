--------------------------------------------------------------------------------
--  sys_full.vhd   ——  完整系统顶层 (串口进 -> 串口出)
--
--    uart_rxd ─> uart_recv ─> uart_to_axis ─> enc_axis ─> axis_to_uart ─> uart_send ─> uart_txd
--                 (字节)      (16bit 元素)    4:1 压缩      (字节)          串行
--
--    一次完整处理: PC 发 512 字节 (256 个 16 bit 元素)
--                 -> 编码压缩成 64 个元素
--                 -> 回传 128 字节
--
--  uart_recv / uart_send 直接引用原工程的文件, 未做任何修改。
--  原来的 uart_loop_1 / uart_loop_2 被 uart_to_axis / axis_to_uart 取代
--  （后者每字节发两遍、data_count/2 下标错位, 属于原设计的缺陷）。
--
--  ⚠ 时钟: uart_recv / uart_send 里的 CLK_FREQ = 50 MHz、UART_BPS = 115200
--    是写死的常量, 所以整个顶层必须跑 50 MHz。数据通路本身按 150 MHz 收敛
--    （实测 153.0 MHz), 50 MHz 下有约 3 倍余量。
--    要跑 150 MHz 需要 PLL 分两个时钟域 + 跨时钟域 FIFO, 见 README 4.5 节。
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity sys_full is
    Port (
        sys_clk     : in  STD_LOGIC;    -- 板上 50 MHz
        sys_rst_n   : in  STD_LOGIC;
        uart_rxd    : in  STD_LOGIC;
        uart_txd    : out STD_LOGIC;

        -- 上游 FIFO 溢出粘滞标志 (调试用)
        rx_overflow : out STD_LOGIC
    );
end entity sys_full;

architecture rtl of sys_full is

    -- 上游: 字节 -> 元素
    signal rx_done  : STD_LOGIC;
    signal rx_data  : STD_LOGIC_VECTOR(7 downto 0);
    signal e_tdata  : STD_LOGIC_VECTOR(15 downto 0);
    signal e_tvalid : STD_LOGIC;
    signal e_tready : STD_LOGIC;
    signal e_tlast  : STD_LOGIC;

    -- 下游: 元素 -> 字节
    signal o_tdata  : STD_LOGIC_VECTOR(15 downto 0);
    signal o_tvalid : STD_LOGIC;
    signal o_tready : STD_LOGIC;
    signal o_tlast  : STD_LOGIC;
    signal tx_data  : STD_LOGIC_VECTOR(7 downto 0);
    signal tx_en    : STD_LOGIC;
    signal tx_busy  : STD_LOGIC;

begin

    ----------------------------------------------------------------------------
    -- 串口接收 (原工程文件, 未修改)
    ----------------------------------------------------------------------------
    u_recv : entity work.uart_recv
        port map (
            sys_clk   => sys_clk,
            sys_rst_n => sys_rst_n,
            uart_rxd  => uart_rxd,
            uart_done => rx_done,
            uart_data => rx_data
        );

    ----------------------------------------------------------------------------
    -- 上游适配
    ----------------------------------------------------------------------------
    u_conv : entity work.uart_to_axis
        generic map (ELEM_W => 16, BLK_ELEMS => 64, BLK_NUM => 4, FIFO_DEPTH => 8)
        port map (
            clk           => sys_clk,
            rst_n         => sys_rst_n,
            rx_done       => rx_done,
            rx_data       => rx_data,
            m_axis_tdata  => e_tdata,
            m_axis_tvalid => e_tvalid,
            m_axis_tready => e_tready,
            m_axis_tlast  => e_tlast,
            overflow      => rx_overflow
        );

    ----------------------------------------------------------------------------
    -- 编码器
    ----------------------------------------------------------------------------
    u_enc : entity work.enc_axis
        generic map (ELEM_W => 16, BLK_ELEMS => 64, BLK_NUM => 4)
        port map (
            aclk          => sys_clk,
            aresetn       => sys_rst_n,
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
    -- 下游适配
    ----------------------------------------------------------------------------
    u_dconv : entity work.axis_to_uart
        generic map (ELEM_W => 16)
        port map (
            clk           => sys_clk,
            rst_n         => sys_rst_n,
            s_axis_tdata  => o_tdata,
            s_axis_tvalid => o_tvalid,
            s_axis_tready => o_tready,
            s_axis_tlast  => o_tlast,
            tx_data       => tx_data,
            tx_en         => tx_en,
            tx_busy       => tx_busy,
            elem_done     => open
        );

    ----------------------------------------------------------------------------
    -- 串口发送 (原工程文件, 未修改)
    ----------------------------------------------------------------------------
    u_send : entity work.uart_send
        port map (
            sys_clk      => sys_clk,
            sys_rst_n    => sys_rst_n,
            uart_en      => tx_en,
            uart_din     => tx_data,
            uart_tx_busy => tx_busy,
            uart_txd     => uart_txd
        );

end architecture rtl;
