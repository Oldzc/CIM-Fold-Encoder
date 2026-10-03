--------------------------------------------------------------------------------
--  axis_async_fifo.vhd  ——  跨时钟域的 AXI4-Stream 异步 FIFO
--
--  用途:
--    把 AXI4-Stream 从写时钟域搬到读时钟域。两边各自有独立的时钟和复位,
--    中间用经典的**格雷码指针 + 两级同步器**做跨时钟域传递
--    （Clifford Cummings 的标准结构）。
--
--    这样做的好处: 编码器数据通路可以跑 150 MHz, 而 uart_recv / uart_send
--    留在 50 MHz（它们的 CLK_FREQ 是写死的常量, 只能在 50 MHz 工作）。
--    两个域之间只在 FIFO 的指针上跨时钟, 而且是格雷码, 每次只变一位,
--    不会产生多比特同时跳变引起的亚稳态采样错误。
--
--  为什么不用普通 FIFO + 打两拍:
--    多比特的二进制指针同时跨时钟域, 采样时可能采到"半新半旧"的值,
--    指针会跳到一个完全错误的位置。格雷码相邻数值只差一位, 最多只错一位,
--    而这一位错误在空/满判断里是安全的（只会导致保守的满/空, 不会丢数据）。
--
--  结构:
--       s_aclk 域                          m_aclk 域
--    ┌──────────────┐                  ┌──────────────┐
--    │ wbin/wgray   │──wgray──>2FF────>│ 空判断        │
--    │ 满判断       │<──rgray──2FF─────│ rbin/rgray   │
--    │ 存储器写入    │                  │ 存储器读出    │
--    └──────────────┘                  └──────────────┘
--
--  复位:
--    两边共用一个 aresetn。同时复位两个指针 -> 必定是空。这是双时钟 FIFO
--    最常见的用法, 也避免了两个域复位先后到达时指针不一致的问题。
--    aresetn 是**异步复位**, 两个域各自在本地时钟上做释放同步。
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_async_fifo is
    Generic (
        WIDTH : positive := 16;     -- 数据位宽
        DEPTH : positive := 16      -- 深度, 须为 >= 4 的 2 的幂
    );
    Port (
        aresetn : in  STD_LOGIC;    -- 异步复位, 低有效, 两个域共用

        -- 写侧 (AXI4-Stream 从接口)
        s_aclk    : in  STD_LOGIC;
        s_tdata   : in  STD_LOGIC_VECTOR(WIDTH - 1 downto 0);
        s_tvalid  : in  STD_LOGIC;
        s_tready  : out STD_LOGIC;
        s_tlast   : in  STD_LOGIC;

        -- 读侧 (AXI4-Stream 主接口)
        m_aclk    : in  STD_LOGIC;
        m_tdata   : out STD_LOGIC_VECTOR(WIDTH - 1 downto 0);
        m_tvalid  : out STD_LOGIC;
        m_tready  : in  STD_LOGIC;
        m_tlast   : out STD_LOGIC
    );
end entity axis_async_fifo;

architecture rtl of axis_async_fifo is

    constant AW : integer := 4;     -- 由 DEPTH 决定, 见下面的断言
    constant PW : integer := AW + 1;  -- 指针多一位用于区分空/满

    -- 存储字: 最高位是 tlast, 低位是数据
    constant WW : integer := WIDTH + 1;
    type mem_t is array (0 to DEPTH - 1) of STD_LOGIC_VECTOR(WW - 1 downto 0);

    signal mem : mem_t;

    -- 写域
    signal wbin  : UNSIGNED(PW - 1 downto 0) := (others => '0');
    signal wgray : UNSIGNED(PW - 1 downto 0) := (others => '0');
    signal wfull : STD_LOGIC := '0';

    -- 读域
    signal rbin  : UNSIGNED(PW - 1 downto 0) := (others => '0');
    signal rgray : UNSIGNED(PW - 1 downto 0) := (others => '0');
    signal rempty : STD_LOGIC := '1';

    -- 指针跨时钟域同步
    signal wq1_rptr, wq2_rptr : UNSIGNED(PW - 1 downto 0) := (others => '0');
    signal rq1_wptr, rq2_wptr : UNSIGNED(PW - 1 downto 0) := (others => '0');

    -- 复位释放同步
    signal w_rst_sync : STD_LOGIC_VECTOR(1 downto 0) := (others => '0');
    signal r_rst_sync : STD_LOGIC_VECTOR(1 downto 0) := (others => '0');

    -- 读出的存储字（组合读出, 所以没有额外的读延迟）
    signal rd_word : STD_LOGIC_VECTOR(WW - 1 downto 0);

    function bin2gray (b : UNSIGNED) return UNSIGNED is
    begin
        return b xor SHIFT_RIGHT(b, 1);
    end function bin2gray;

    -- 满: 写格雷码等于"读格雷码最高两位取反"
    function is_full (wg : UNSIGNED(PW - 1 downto 0);
                      rg : UNSIGNED(PW - 1 downto 0)) return BOOLEAN is
        variable t : UNSIGNED(PW - 1 downto 0);
    begin
        t := (not rg(PW - 1 downto PW - 2)) & rg(PW - 3 downto 0);
        return wg = t;
    end function is_full;

begin

    -- 本模块的指针宽度按 DEPTH=16 写死, 换深度要同时改 AW
    -- （注: VHDL 字符串字面量只允许 ASCII, 所以断言消息用英文）
    assert DEPTH = 16
        report "axis_async_fifo: AW is hard-coded for DEPTH=16; change AW with DEPTH"
        severity failure;

    ----------------------------------------------------------------------------
    -- 复位释放同步: 异步置位, 各域本地同步释放
    ----------------------------------------------------------------------------
    process (s_aclk, aresetn)
    begin
        if aresetn = '0' then
            w_rst_sync <= (others => '0');
        elsif rising_edge(s_aclk) then
            w_rst_sync <= w_rst_sync(0) & '1';
        end if;
    end process;

    process (m_aclk, aresetn)
    begin
        if aresetn = '0' then
            r_rst_sync <= (others => '0');
        elsif rising_edge(m_aclk) then
            r_rst_sync <= r_rst_sync(0) & '1';
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 写侧
    ----------------------------------------------------------------------------
    process (s_aclk, aresetn)
        variable wbin_n  : UNSIGNED(PW - 1 downto 0);
        variable wgray_n : UNSIGNED(PW - 1 downto 0);
        variable inc     : BOOLEAN;
    begin
        if aresetn = '0' then
            wbin  <= (others => '0');
            wgray <= (others => '0');
            wfull <= '0';
            -- 显式复位存储器内容。
            -- 不加这一句的话, Quartus 会把 mem 推断成**双时钟 Block RAM**,
            -- 并警告 "read-during-write behavior of a dual-clock RAM is
            -- undefined and may not match the behavior of the original design"
            -- —— 也就是说仿真对、上板可能不对。块 RAM 的内容不支持异步复位,
            -- 所以加了复位之后布局器只能用触发器实现, 行为就和仿真一致了。
            -- 深度只有 16, 272 个触发器, 代价可以接受。
            mem   <= (others => (others => '0'));
        elsif rising_edge(s_aclk) then
            if w_rst_sync(1) = '0' then
                wbin  <= (others => '0');
                wgray <= (others => '0');
                wfull <= '0';
            else
                inc := (s_tvalid = '1') and (wfull = '0');

                if inc then
                    mem(TO_INTEGER(wbin(AW - 1 downto 0))) <= s_tlast & s_tdata;
                end if;

                wbin_n  := wbin;
                if inc then
                    wbin_n := wbin + 1;
                end if;
                wgray_n := bin2gray(wbin_n);

                wbin  <= wbin_n;
                wgray <= wgray_n;

                if is_full(wgray_n, wq2_rptr) then
                    wfull <= '1';
                else
                    wfull <= '0';
                end if;
            end if;
        end if;
    end process;

    -- 读指针同步到写域
    process (s_aclk, aresetn)
    begin
        if aresetn = '0' then
            wq1_rptr <= (others => '0');
            wq2_rptr <= (others => '0');
        elsif rising_edge(s_aclk) then
            wq1_rptr <= rgray;
            wq2_rptr <= wq1_rptr;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 读侧
    ----------------------------------------------------------------------------
    process (m_aclk, aresetn)
        variable rbin_n  : UNSIGNED(PW - 1 downto 0);
        variable rgray_n : UNSIGNED(PW - 1 downto 0);
    begin
        if aresetn = '0' then
            rbin   <= (others => '0');
            rgray  <= (others => '0');
            rempty <= '1';
        elsif rising_edge(m_aclk) then
            if r_rst_sync(1) = '0' then
                rbin   <= (others => '0');
                rgray  <= (others => '0');
                rempty <= '1';
            else
                rbin_n := rbin;
                if (m_tready = '1') and (rempty = '0') then
                    rbin_n := rbin + 1;
                end if;
                rgray_n := bin2gray(rbin_n);

                rbin  <= rbin_n;
                rgray <= rgray_n;

                if rgray_n = rq2_wptr then
                    rempty <= '1';
                else
                    rempty <= '0';
                end if;
            end if;
        end if;
    end process;

    -- 写指针同步到读域
    process (m_aclk, aresetn)
    begin
        if aresetn = '0' then
            rq1_wptr <= (others => '0');
            rq2_wptr <= (others => '0');
        elsif rising_edge(m_aclk) then
            rq1_wptr <= wgray;
            rq2_wptr <= rq1_wptr;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 组合读出（不额外增加一拍读延迟, AXI 握手才不用改）
    ----------------------------------------------------------------------------
    rd_word <= mem(TO_INTEGER(rbin(AW - 1 downto 0)));

    ----------------------------------------------------------------------------
    -- AXI4-Stream 两侧
    --
    -- 注意必须用复位释放同步标志把 tready / tvalid 按住。
    -- 复位释放要经过两级同步器（2 拍), 在这 2 拍里内部指针还处于复位状态、
    -- 不会真的写入, 但如果此时 s_tready 已经是 '1', 上游会以为握手成功而
    -- **把第一个字丢掉** —— 调试时就是这个现象: 发出的第一个字不见了,
    -- 后面所有数据整体错位一格。
    ----------------------------------------------------------------------------
    s_tready <= '0' when w_rst_sync(1) = '0' else (not wfull);
    m_tvalid <= '0' when r_rst_sync(1) = '0' else (not rempty);
    m_tdata  <= rd_word(WIDTH - 1 downto 0);
    m_tlast  <= rd_word(WIDTH);

end architecture rtl;
