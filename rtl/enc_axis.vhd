--------------------------------------------------------------------------------
--  enc_axis.vhd   ——  AXI4-Stream 顶层 (写入即折叠 + 全寄存器化输出)
--
--  对应「需求.txt」:
--    L16  输出数据通过 AXI4-Stream 接口传输, 每个输出元素为 16 位定点数
--
--  接口:
--    s_axis_*  从接口, 16 bit/拍, 一帧 256 拍 (tlast 在第 256 拍)
--              256 个元素 x 16 bit = 4096 bit, 与需求 L9 一致
--    m_axis_*  主接口, 16 bit/拍, 一帧 64 拍 (tlast 在第 64 拍)
--              64 个元素 x 16 bit = 1024 bit, 与需求 L14 一致
--
--  数据通路:
--    s_axis ──> enc_fold ──(fold_done 当拍锁存)──> obuf ──> m_data_r ──> m_axis
--              4 个存储单元, 每个 32 个折叠元素 = 2048 bit
--
--  三个版本的演进 (都记录在 README 4.4 节):
--    v1  4096 bit 输入阵列 + 并行编码器 + 64:1 输出多路选择
--        -> 8533 LE (83%), 关键路径是那个多路选择, 数据延迟 10.8 ns
--    v2  换成输出移位寄存器
--        -> 同样 83%, 但关键路径变成"控制信号到输出引脚" 5.6 ns, 仍是布线拥塞
--    v3  写入即折叠 + 输出全寄存器化 (本文件)
--        -> 3559 LE (34%), 控制输出直接由触发器驱动, 可被布局器放进 IO 单元
--
--  为什么输出要寄存器化:
--    直接写 `m_axis_tvalid <= '1' when state = S_SEND else '0'` 时, 一个
--    state 译码到引脚实测要 5.1 ns, `rd_cnt = 63` 比较器到引脚要 5.6 ns,
--    150 MHz 下余量 -3.7 ns。改成触发器直驱引脚后, 这些路径会被放进 IO 单元,
--    片内只剩"触发器到触发器"的短路径。
--    AXI4-Stream 本来就允许 tvalid/tready/tdata/tlast 是寄存器输出。
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity enc_axis is
    Generic (
        ELEM_W    : positive := 16;   -- 元素位宽
        BLK_ELEMS : positive := 64;   -- 每个存储单元的元素容量
        BLK_NUM   : positive := 4     -- 存储单元个数
    );
    Port (
        aclk          : in  STD_LOGIC;
        aresetn       : in  STD_LOGIC;

        -- AXI4-Stream 从接口 (输入向量 256 元素)
        s_axis_tdata  : in  STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
        s_axis_tvalid : in  STD_LOGIC;
        s_axis_tready : out STD_LOGIC;
        s_axis_tlast  : in  STD_LOGIC;

        -- AXI4-Stream 主接口 (压缩后的 64 元素特征向量)
        m_axis_tdata  : out STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
        m_axis_tvalid : out STD_LOGIC;
        m_axis_tready : in  STD_LOGIC;
        m_axis_tlast  : out STD_LOGIC
    );
end entity enc_axis;

architecture rtl of enc_axis is

    constant IN_ELEMS  : integer := BLK_NUM * BLK_ELEMS;   -- 256
    constant OUT_W     : integer := BLK_ELEMS * ELEM_W;    -- 1024
    constant OUT_ELEMS : integer := BLK_ELEMS;             -- 64

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

    type state_t is (S_LOAD, S_WAIT, S_SEND);

    signal state  : state_t;
    signal wr_cnt : UNSIGNED(log2c(IN_ELEMS)  - 1 downto 0) := (others => '0');
    signal rd_cnt : UNSIGNED(log2c(OUT_ELEMS) - 1 downto 0) := (others => '0');

    -- 直接驱动引脚的展示寄存器 (可被布局器放进 IO 单元)
    signal s_ready_r : STD_LOGIC := '1';
    signal m_valid_r : STD_LOGIC := '0';
    signal m_last_r  : STD_LOGIC := '0';
    signal m_data_r  : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0) := (others => '0');

    -- 输出串行化移位寄存器
    signal obuf      : STD_LOGIC_VECTOR(OUT_W - 1 downto 0);

    -- 本拍实际发生的传输
    signal in_fire   : STD_LOGIC;
    signal out_fire  : STD_LOGIC;

    -- enc_fold 接口
    signal fold_done : STD_LOGIC;
    signal fold_out  : STD_LOGIC_VECTOR(OUT_W - 1 downto 0);

begin

    ----------------------------------------------------------------------------
    -- 编码核心: 元素到达即在存储单元写入口折叠, 不保存原始输入
    ----------------------------------------------------------------------------
    u_fold : entity work.enc_fold
        generic map (
            ELEM_W     => ELEM_W,
            BLK_ELEMS  => BLK_ELEMS,
            BLK_NUM    => BLK_NUM
        )
        port map (
            clk        => aclk,
            rst_n      => aresetn,
            in_elem    => s_axis_tdata,
            in_valid   => in_fire,
            frame_last => s_axis_tlast,
            fold_done  => fold_done,
            out_data   => fold_out
        );

    ----------------------------------------------------------------------------
    -- 握手: 两个方向都用寄存器输出的有效/就绪信号
    ----------------------------------------------------------------------------
    in_fire  <= s_ready_r and s_axis_tvalid;
    out_fire <= m_valid_r and m_axis_tready;

    ----------------------------------------------------------------------------
    -- 主控状态机 (输出全部寄存器化)
    --
    -- 复位用**异步**低有效: Cyclone IV 的 IO 单元输出寄存器带异步清零 (aclr),
    -- 但没有同步清零。原来用同步复位时, 布局器报
    --     "Can't pack node m_data_r[0..15] to I/O pin"
    -- 于是 16 位数据寄存器留在片内, 触发器到引脚要走 4.1 ns 布线, 150 MHz
    -- 下余量 -2.2 ns。改成异步复位后这几个寄存器才能被放进 IO 单元。
    ----------------------------------------------------------------------------
    process (aclk, aresetn)
    begin
        if aresetn = '0' then
                state     <= S_LOAD;
                s_ready_r <= '1';
                m_valid_r <= '0';
                m_last_r  <= '0';
                m_data_r  <= (others => '0');
                obuf      <= (others => '0');
                wr_cnt    <= (others => '0');
                rd_cnt    <= (others => '0');
        elsif rising_edge(aclk) then

                ------------------------------------------------------------
                -- 输入侧: 逐拍接收, 直接送进折叠阵列
                ------------------------------------------------------------
                if (state = S_LOAD) and (in_fire = '1') then
                    if (s_axis_tlast = '1') or (wr_cnt = IN_ELEMS - 1) then
                        wr_cnt    <= (others => '0');
                        s_ready_r <= '0';        -- 本帧收满, 暂停接收
                        state     <= S_WAIT;
                    else
                        wr_cnt <= wr_cnt + 1;
                    end if;
                end if;

                ------------------------------------------------------------
                -- 折叠完成: 当拍把组合输出锁存进展示寄存器
                ------------------------------------------------------------
                if (state = S_WAIT) and (fold_done = '1') then
                    obuf      <= fold_out;
                    m_data_r  <= fold_out(ELEM_W - 1 downto 0);
                    m_valid_r <= '1';
                    m_last_r  <= '0';            -- 只有 1 个元素时才会是最后一拍
                    rd_cnt    <= (others => '0');
                    state     <= S_SEND;
                end if;

                ------------------------------------------------------------
                -- 输出侧: 受下游 tready 反压, 每次成功传输推进一步
                ------------------------------------------------------------
                if (state = S_SEND) and (out_fire = '1') then
                    if rd_cnt = OUT_ELEMS - 1 then
                        m_valid_r <= '0';
                        m_last_r  <= '0';
                        rd_cnt    <= (others => '0');
                        s_ready_r <= '1';        -- 本帧发完, 重新接收
                        state     <= S_LOAD;
                    else
                        -- 右移 16 位: 低位丢弃, 高位补 0。
                        -- 不能写成 obuf(OUT_W-1 downto ELEM_W) &
                        -- (ELEM_W-1 downto 0 => '0'), 那是左移。
                        obuf     <= (OUT_W - 1 downto OUT_W - ELEM_W => '0')
                                    & obuf(OUT_W - 1 downto ELEM_W);
                        -- 下一拍要展示的元素: 移位前的第 2 个元素
                        m_data_r <= obuf(2*ELEM_W - 1 downto ELEM_W);
                        if rd_cnt = OUT_ELEMS - 2 then
                            m_last_r <= '1';
                        else
                            m_last_r <= '0';
                        end if;
                        rd_cnt   <= rd_cnt + 1;
                    end if;
                end if;

            end if;
    end process;

    ----------------------------------------------------------------------------
    -- 引脚输出: 全部直连触发器, 组合逻辑为零
    ----------------------------------------------------------------------------
    s_axis_tready <= s_ready_r;
    m_axis_tvalid <= m_valid_r;
    m_axis_tlast  <= m_last_r;
    m_axis_tdata  <= m_data_r;

end architecture rtl;
