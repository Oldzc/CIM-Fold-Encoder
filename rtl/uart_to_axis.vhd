--------------------------------------------------------------------------------
--  uart_to_axis.vhd   ——  UART 接收字节 -> AXI4-Stream 元素流
--
--  作用:
--    接在 uart_recv 后面, 把逐字节到达的串口数据装配成 16 bit 元素, 再以
--    AXI4-Stream 主接口送出, 直接对接 enc_axis 的从接口。
--
--    原有的 uart_loop_1 只拼 256 bit (32 字节), 与现在 4096 bit
--    (256 元素 x 16 bit = 512 字节) 的输入规格对不上, 所以整条上游链路要换。
--
--  字节 -> 元素的约定（与原 uart_loop_1 保持一致）:
--    先到的字节放在元素的**低 8 位**。即
--        element[k] = { byte[2k+1], byte[2k] }
--    一帧 512 个字节 -> 256 个元素, 第 256 个元素上 tlast 拉高。
--    改动这个约定只要改 asm_next 那一处即可。
--
--  关于 rx_done:
--    uart_recv 的 uart_done 不是单拍脉冲 —— 它在 rx_cnt = 9 (停止位) 时拉高,
--    一直保持到 rx_flag 清零, 大约 BPS_CNT/2 ≈ 217 个时钟。
--    所以本模块内部做上升沿检测, 可以直接接 uart_recv 的 uart_done。
--
--  速率匹配:
--    115200 bps 下一个字节约 86.8 us, 也就是 50 MHz 下约 4340 个时钟才来
--    一个字节; 而下游 enc_axis 一帧只占约 320 拍。两者的速率差三个数量级,
--    所以元素级 FIFO 深度取 8 已经绰绰有余。真的溢出会置 overflow 粘滞标志,
--    不会被静默丢掉。
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_to_axis is
    Generic (
        ELEM_W     : positive := 16;   -- 元素位宽, 须为 8 的整数倍
        BLK_ELEMS  : positive := 64;   -- 每个存储单元的元素容量
        BLK_NUM    : positive := 4;    -- 存储单元个数
        FIFO_DEPTH : positive := 8     -- 元素级 FIFO 深度, 须为 2 的幂
    );
    Port (
        clk           : in  STD_LOGIC;
        rst_n         : in  STD_LOGIC;

        -- 来自 uart_recv。rx_done 是电平信号（停止位期间为高），
        -- 内部取上升沿; rx_data 在 rx_done 有效期间保持稳定。
        rx_done       : in  STD_LOGIC;
        rx_data       : in  STD_LOGIC_VECTOR(7 downto 0);

        -- AXI4-Stream 主接口（直接接 enc_axis 的从接口）
        m_axis_tdata  : out STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
        m_axis_tvalid : out STD_LOGIC;
        m_axis_tready : in  STD_LOGIC;
        m_axis_tlast  : out STD_LOGIC;

        -- 粘滞溢出标志: FIFO 满时仍收到字节则置位, 需要复位才会清
        overflow      : out STD_LOGIC
    );
end entity uart_to_axis;

architecture rtl of uart_to_axis is

    constant BPE      : integer := ELEM_W / 8;              -- 每元素字节数
    constant IN_ELEMS : integer := BLK_NUM * BLK_ELEMS;     -- 256 个元素/帧
    constant PW       : integer := 3;                       -- log2(FIFO_DEPTH)

    function log2c (n : positive) return positive is
        variable m : integer := 1;
        variable r : integer := 0;
    begin
        while m < n loop
            m := m * 2;
            r := r + 1;
        end loop;
        return r;
    end function log2c;

    -- 字节装配
    signal asm      : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0) := (others => '0');
    signal asm_next : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    signal asm_cnt  : UNSIGNED(log2c(BPE) - 1 downto 0) := (others => '0');

    -- rx_done 上升沿检测
    signal rx_d0, rx_d1 : STD_LOGIC := '0';
    signal byte_stb     : STD_LOGIC;

    -- 元素级 FIFO
    type fifo_t is array (0 to FIFO_DEPTH - 1) of STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    signal fifo   : fifo_t;
    signal wr_p   : UNSIGNED(PW - 1 downto 0) := (others => '0');
    signal rd_p   : UNSIGNED(PW - 1 downto 0) := (others => '0');
    signal cnt    : UNSIGNED(PW downto 0) := (others => '0');   -- 多一位便于判满

    signal wr_en  : STD_LOGIC;
    signal rd_en  : STD_LOGIC;
    signal full   : STD_LOGIC;
    signal empty  : STD_LOGIC;

    -- 帧内已发出的元素数（用于 tlast）
    signal tx_cnt : UNSIGNED(log2c(IN_ELEMS) - 1 downto 0) := (others => '0');

begin

    ----------------------------------------------------------------------------
    -- rx_done 上升沿检测（uart_done 是宽脉冲, 不是单拍）
    ----------------------------------------------------------------------------
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            rx_d0 <= '0';
            rx_d1 <= '0';
        elsif rising_edge(clk) then
            rx_d0 <= rx_done;
            rx_d1 <= rx_d0;
        end if;
    end process;

    byte_stb <= rx_d0 and (not rx_d1);

    ----------------------------------------------------------------------------
    -- 字节装配成元素
    --   用组合方式算出"插入当前字节之后"的完整元素, 这样推入 FIFO 的
    --   就是包含本字节的正确值（信号赋值是非阻塞的, 直接读 asm 会缺一个字节）。
    ----------------------------------------------------------------------------
    process (asm, asm_cnt, rx_data)
        variable t : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    begin
        t := asm;
        t(TO_INTEGER(asm_cnt)*8 + 7 downto TO_INTEGER(asm_cnt)*8) := rx_data;
        asm_next <= t;
    end process;

    -- 注意: 这里是 std_logic 与 boolean 的比较结果, 必须用 when/else 包起来,
    -- 不能直接写 byte_stb and (asm_cnt = ...)。
    wr_en <= '1' when (byte_stb = '1')
                      and (asm_cnt = TO_UNSIGNED(BPE - 1, log2c(BPE)))
             else '0';
    full  <= '1' when cnt = TO_UNSIGNED(FIFO_DEPTH, PW + 1) else '0';
    empty <= '1' when cnt = 0 else '0';

    -- 复位用异步: 与 enc_axis 保持一致的理由 —— Cyclone IV 的 IO 单元输出
    -- 寄存器只有异步清零, overflow 这个直驱引脚的寄存器用同步复位时会报
    -- "Can't pack node overflow to I/O pin", 触发器到引脚要走 3.67 ns 布线。
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            asm      <= (others => '0');
            asm_cnt  <= (others => '0');
            wr_p     <= (others => '0');
            overflow <= '0';
        elsif rising_edge(clk) then
            if byte_stb = '1' then
                asm     <= asm_next;
                asm_cnt <= asm_cnt + 1;      -- BPE 是 2 的幂, 自然回绕
                if wr_en = '1' then
                    if full = '1' then
                        overflow <= '1';     -- 丢了就置标志, 不静默
                    else
                        fifo(TO_INTEGER(wr_p)) <= asm_next;
                        wr_p <= wr_p + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 读侧: AXI4-Stream 主接口
    ----------------------------------------------------------------------------
    rd_en <= (not empty) and m_axis_tready;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            rd_p   <= (others => '0');
            cnt    <= (others => '0');
            tx_cnt <= (others => '0');
        elsif rising_edge(clk) then
            -- 写指针推进时同步更新计数
            if (wr_en = '1') and (full = '0') then
                cnt <= cnt + 1;
            end if;
            if rd_en = '1' then
                rd_p   <= rd_p + 1;
                cnt    <= cnt - 1;
                tx_cnt <= tx_cnt + 1;    -- 到 IN_ELEMS 自然回绕
            end if;
        end if;
    end process;

    m_axis_tdata  <= fifo(TO_INTEGER(rd_p));
    m_axis_tvalid <= not empty;
    m_axis_tlast  <= '1' when tx_cnt = TO_UNSIGNED(IN_ELEMS - 1, log2c(IN_ELEMS))
                     else '0';

end architecture rtl;
