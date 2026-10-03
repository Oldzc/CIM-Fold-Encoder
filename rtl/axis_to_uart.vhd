--------------------------------------------------------------------------------
--  axis_to_uart.vhd   ——  AXI4-Stream 元素流 -> UART 发送字节
--
--  作用:
--    接在 enc_axis 的主接口后面, 把 16 bit 元素拆成字节, 逐个交给原有的
--    uart_send 发出去。替换掉原来那个 uart_loop_2 —— 后者有两个问题:
--      * data_reg((8*(data_count/2+1)-1) downto 8*(data_count/2)) 里的 /2
--        让 0..127 的计数映射到 0..63 的下标, 每个字节被发了两遍;
--      * 它在两个进程里分别更新 data_count 和 temp_data, 存在竞争。
--
--  字节顺序（与上游 uart_to_axis 对称）:
--      element[k] 先发**低 8 位**, 再发高 8 位。
--      即 element[k] = { byte[2k+1], byte[2k] }, 与 PC 端发过来时的约定一致,
--      所以整条回路是"发什么收什么"。
--      要改顺序, 只要把 bi 的递增改成递减即可。
--
--  与 uart_send 的握手:
--      uart_send 是**上升沿触发**的（uart_en_d1='0' and uart_en_d0='1'）,
--      所以 tx_en 必须是单拍脉冲; 而 uart_tx_busy 要等到触发后的第三拍才拉高。
--      状态机因此分成"发脉冲 -> 等 busy 起 -> 等 busy 落"三步。
--      如果只写"等 busy='0' 就发下一个", 脉冲刚发出去那拍 busy 还是 0,
--      会立刻误判成空闲而多发/漏发。
--
--  速率:
--      115200 bps 下一个字节 10 位约 86.8 us (50 MHz 下 4340 拍),
--      一帧 128 字节约 11.1 ms。下游远比上游慢, 所以不需要输出 FIFO ——
--      tready 大部分时间拉低, 由 AXI 反压把上游按住即可。
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_to_uart is
    Generic (
        ELEM_W : positive := 16      -- 元素位宽, 须为 8 的整数倍
    );
    Port (
        clk           : in  STD_LOGIC;
        rst_n         : in  STD_LOGIC;

        -- AXI4-Stream 从接口（接 enc_axis 的主接口）
        s_axis_tdata  : in  STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
        s_axis_tvalid : in  STD_LOGIC;
        s_axis_tready : out STD_LOGIC;
        s_axis_tlast  : in  STD_LOGIC;

        -- 到 uart_send
        tx_data       : out STD_LOGIC_VECTOR(7 downto 0);
        tx_en         : out STD_LOGIC;      -- 单拍脉冲, 上升沿触发 uart_send
        tx_busy       : in  STD_LOGIC;

        -- 每发完一个元素拉高一拍（调试/计数用）
        elem_done     : out STD_LOGIC
    );
end entity axis_to_uart;

architecture rtl of axis_to_uart is

    constant BPE : integer := ELEM_W / 8;   -- 每元素字节数 (16 bit -> 2)

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

    type state_t is (S_ACCEPT, S_LOAD, S_WAIT_BUSY, S_WAIT_DONE);

    signal state  : state_t;

    signal elem   : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0) := (others => '0');
    signal bi     : UNSIGNED(log2c(BPE) - 1 downto 0) := (others => '0');
    signal done_r : STD_LOGIC := '0';

    signal tx_d   : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal tx_e   : STD_LOGIC := '0';

begin

    ----------------------------------------------------------------------------
    -- 状态机
    --
    --   S_ACCEPT      tready=1, 等一个 AXI 拍
    --   S_LOAD        发 tx_en 单拍脉冲（busy 必须为 0）
    --   S_WAIT_BUSY   等 uart_send 把 busy 拉起来
    --   S_WAIT_DONE   等 busy 落下去 -> 该发下一个字节了
    ----------------------------------------------------------------------------
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            state  <= S_ACCEPT;
            elem   <= (others => '0');
            bi     <= (others => '0');
            done_r <= '0';
            tx_d   <= (others => '0');
            tx_e   <= '0';
        elsif rising_edge(clk) then

            tx_e   <= '0';       -- 默认拉低, 保证 tx_en 是单拍脉冲
            done_r <= '0';

            case state is

                ------------------------------------------------------------
                -- 接收一个 AXI 元素
                ------------------------------------------------------------
                when S_ACCEPT =>
                    if s_axis_tvalid = '1' then
                        elem  <= s_axis_tdata;
                        bi    <= (others => '0');
                        state <= S_LOAD;
                    end if;

                ------------------------------------------------------------
                -- 发一个字节的触发脉冲
                ------------------------------------------------------------
                when S_LOAD =>
                    if tx_busy = '0' then
                        tx_d  <= elem(TO_INTEGER(bi)*8 + 7 downto TO_INTEGER(bi)*8);
                        tx_e  <= '1';
                        state <= S_WAIT_BUSY;
                    end if;

                ------------------------------------------------------------
                -- 等 busy 起来（uart_send 是上升沿触发, 要三拍才见到 busy）
                ------------------------------------------------------------
                when S_WAIT_BUSY =>
                    if tx_busy = '1' then
                        state <= S_WAIT_DONE;
                    end if;

                ------------------------------------------------------------
                -- 等 busy 落下
                ------------------------------------------------------------
                when S_WAIT_DONE =>
                    if tx_busy = '0' then
                        if bi = TO_UNSIGNED(BPE - 1, log2c(BPE)) then
                            done_r <= '1';       -- 一个元素的字节都发完了
                            state  <= S_ACCEPT;
                        else
                            bi    <= bi + 1;
                            state <= S_LOAD;
                        end if;
                    end if;
                end case;

        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 端口
    --
    -- s_axis_tlast 目前不参与控制（本模块负责把帧内所有元素发完,
    -- 是否帧尾由 tready 自然反压决定）。保留端口是为了接口完整,
    -- 也给以后"帧尾插标志字节"留位置。
    ----------------------------------------------------------------------------
    s_axis_tready <= '1' when state = S_ACCEPT else '0';
    tx_data       <= tx_d;
    tx_en         <= tx_e;
    elem_done     <= done_r;

end architecture rtl;
