--------------------------------------------------------------------------------
--  sys_top.vhd   ——  完整输入链路顶层
--
--  串口字节 -> uart_recv -> uart_to_axis -> enc_axis -> AXI4-Stream 输出
--
--      uart_rxd ──> uart_recv ──(rx_done/rx_data)──> uart_to_axis
--                                                        │ AXI4-Stream 256×16b
--                                                        ▼
--                                                    enc_axis ──> m_axis 64×16b
--
--  uart_recv 取自给定的串口模块（rtl/provided/uart_recv.vhd），未做任何修改。
--
--  ⚠ 时钟域说明:
--    uart_recv 里的 CLK_FREQ = 50 MHz、UART_BPS = 115200 是**写死的常量**,
--    波特率分频比 BPS_CNT = 50000000/115200 = 434, 只有在 50 MHz 时钟下才正确。
--    而本设计的数据通路是按 150 MHz 收敛的。两者不能共用同一个 150 MHz 时钟:
--
--      方案一: 整体跑 50 MHz —— UART 正确, 编码器能力仍有富余（50 < 158.30）
--      方案二: 用 PLL 分两路, UART 域 50 MHz、编码器域 150 MHz,
--              两者之间用 uart_to_axis 里的元素级 FIFO 做跨时钟域隔离
--              （目前 FIFO 是单时钟的, 要跨时钟域还需加格雷码指针或握手）
--
--    本次只做到方案一的程度, 方案二属于后续工作, 已在 README 里记明。
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity sys_top is
    Port (
        sys_clk       : in  STD_LOGIC;                          -- 板上 50 MHz
        sys_rst_n     : in  STD_LOGIC;
        uart_rxd      : in  STD_LOGIC;

        -- 编码结果 (AXI4-Stream 主接口)
        m_axis_tdata  : out STD_LOGIC_VECTOR(15 downto 0);
        m_axis_tvalid : out STD_LOGIC;
        m_axis_tready : in  STD_LOGIC;
        m_axis_tlast  : out STD_LOGIC;

        -- 上游 FIFO 溢出粘滞标志 (调试用)
        rx_overflow   : out STD_LOGIC
    );
end entity sys_top;

architecture rtl of sys_top is

    signal rx_done  : STD_LOGIC;
    signal rx_data  : STD_LOGIC_VECTOR(7 downto 0);

    signal e_tdata  : STD_LOGIC_VECTOR(15 downto 0);
    signal e_tvalid : STD_LOGIC;
    signal e_tready : STD_LOGIC;
    signal e_tlast  : STD_LOGIC;

begin

    ----------------------------------------------------------------------------
    -- 原工程的串口接收模块, 未修改
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
    -- 上游适配: 字节 -> 16 bit 元素 AXI4-Stream
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
            m_axis_tdata  => m_axis_tdata,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready,
            m_axis_tlast  => m_axis_tlast
        );

end architecture rtl;
