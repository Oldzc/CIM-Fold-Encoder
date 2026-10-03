--------------------------------------------------------------------------------
--  enc_fold.vhd   —— 写入即折叠（write-and-fold）的编码核心
--
--  和 parallel_conv_encoder 的关系:
--    两者实现**完全相同的数学函数**, 只是微架构不同。
--      parallel_conv_encoder : 先把 4096 bit 全部存进寄存器阵列, 再用两级
--                              流水做「块内折叠 + 跨块累加」。
--      enc_fold              : 元素流式到达时, 在存储单元的**写入口**直接
--                              折叠, 不保存原始 4096 bit。
--    等价性由 tb_equivalence.vhd 逐位证明, ref_model.py 参考模型也直接复用。
--
--  折叠算法:
--    全局元素下标 k = 0..BLK_NUM*BLK_ELEMS-1
--      单元号  i = k / BLK_ELEMS
--      单元内  p = k mod BLK_ELEMS,  前半段 ph = (p >= BLK_ELEMS/2)
--    原始定义   mid_i[m] = mem_i[m] xor mem_i[m + BLK_ELEMS/2]     m = 0..31
--
--  实现方式（关键）:
--    访问模式是**严格顺序**的, 所以折叠阵列根本不需要"可寻址"。
--    每个存储单元用一个 BLK_ELEMS/2 元素的移位寄存器 acc(i) 就够了:
--
--      前半段 (ph=0): acc_i <= in_elem & acc_i(高 31 个元素)      -- 直接装载
--      后半段 (ph=1): acc_i <= (acc_i 最低元素 xor in_elem)
--                             & acc_i(高 31 个元素)               -- 异或折叠
--
--    后半段每拍取 acc_i 的最低元素与到来的元素异或, 结果从最高位喂回,
--    于是 fold_i(m) 最终落在 acc_i 的第 (31-m) 个元素位置（顺序是反的,
--    输出级按同样规则反着取即可）。
--
--  为什么不用"128 深度的可寻址阵列":
--    那样会综合出一个 128:1 读多路选择器（4 级 LUT）加 128 路写译码,
--    实测关键路径 12.1 ns, 150 MHz 根本收不了。
--    改成移位寄存器后关键路径只有「4:1 选择 + 1 级异或」= 2 级 LUT。
--
--  面积对比 (EP4CE10F17C8, 10320 LE):
--    parallel_conv_encoder : 输入阵列 4096 + mid 2048 + dout 1024 = 7168 个寄存器
--    enc_fold              : 4 个单元 x 512 bit                = 2048 个寄存器
--
--  自初始化特性:
--    每个单元的前半段会把 acc_i 整体重新装载一遍, 因此**不需要复位、
--    也不需要帧间清零**, 上一帧的残留会被完全覆盖。只有"帧不完整"才会
--    留下脏数据, 而下一个完整帧会自愈。
--
--  输入约定:
--    元素必须**按 k = 0,1,2,... 的顺序**到达; 一帧 IN_ELEMS 个。
--    in_valid 是单拍脉冲, 与 clk 同步。
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity enc_fold is
    Generic (
        ELEM_W    : positive := 16;   -- 元素位宽
        BLK_ELEMS : positive := 64;   -- 每个存储单元容纳的元素数 (须为偶数)
        BLK_NUM   : positive := 4     -- 存储单元个数
    );
    Port (
        clk        : in  STD_LOGIC;
        rst_n      : in  STD_LOGIC;

        -- 流式元素输入 (每拍一个元素, 必须按序)
        in_elem    : in  STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
        in_valid   : in  STD_LOGIC;
        -- 本拍是帧的最后一拍 (AXI tlast)。正常帧长为 IN_ELEMS,
        -- 这里额外接受上游提前收帧, 避免上游协议出错时下游死等。
        frame_last : in  STD_LOGIC;

        -- 一帧折叠完成后拉高一拍。注意 out_data 是**组合输出**,
        -- 只在 fold_done 为高的那一拍有效, 下游必须当拍锁存。
        fold_done  : out STD_LOGIC;
        out_data   : out STD_LOGIC_VECTOR(BLK_ELEMS*ELEM_W - 1 downto 0)
    );
end entity enc_fold;

architecture rtl of enc_fold is

    constant IN_ELEMS : integer := BLK_NUM * BLK_ELEMS;   -- 256
    constant HALF     : integer := BLK_ELEMS / 2;         -- 32
    constant CNT_W    : integer := 8;                     -- 容纳 IN_ELEMS 的位数
    constant UW       : integer := HALF * ELEM_W;         -- 一个单元 512 bit

    -- 每个存储单元一个 UW 位的移位寄存器
    type acc_t is array (0 to BLK_NUM - 1) of STD_LOGIC_VECTOR(UW - 1 downto 0);

    signal acc    : acc_t;
    signal cnt    : UNSIGNED(CNT_W - 1 downto 0) := (others => '0');
    signal done_r : STD_LOGIC := '0';

    -- 当前正在写入的单元 (cnt 每 64 拍换一个单元)
    signal ui     : integer range 0 to BLK_NUM - 1;
    -- 单元内前半段 / 后半段
    signal ph     : STD_LOGIC;

begin

    ui <= TO_INTEGER(cnt(CNT_W - 1 downto 6));
    ph <= cnt(5);

    ----------------------------------------------------------------------------
    -- 写入即折叠（每个存储单元一套独立的移位逻辑）
    --
    -- 这里刻意**不**用"4:1 多路选择读出当前单元、算完再写回"的写法。
    -- 那种写法会在数据通路上引入一个 2048 bit 宽的 4:1 多路选择器:
    --     acc -> 4:1 mux -> xor -> acc
    -- 每个输出位都要从相隔 512 位的 4 个来源里选, 布线很长。实测关键路径
    -- 6.7 ns 左右, 150 MHz 下余量在 ±0.3 ns 之间摇摆 —— 跑 6 个布局种子,
    -- 3 个过 3 个不过, 设计点非常脆弱。
    --
    -- 改成每个单元各自算自己的下一拍值以后, 单元选择只出现在**写使能**上:
    --     acc(i) -> xor -> acc(i)        (数据通路只有 1 级 LUT)
    --     ui = i                         (使能, 1 级比较)
    -- 所有跨单元的布线都消失了。
    ----------------------------------------------------------------------------
    gen_fold : for i in 0 to BLK_NUM - 1 generate

        -- 本单元下一拍的值
        signal nxt_i : STD_LOGIC_VECTOR(UW - 1 downto 0);

    begin

        -- 前半段: 新元素从最高位进, 整体下移              -> 装载 mem_i[m]
        -- 后半段: 最低元素与到来元素异或后进最高位        -> 完成 mem_i[m]^mem_i[m+32]
        nxt_i <= in_elem & acc(i)(UW - 1 downto ELEM_W)
                     when ph = '0' else
                 (acc(i)(ELEM_W - 1 downto 0) xor in_elem)
                     & acc(i)(UW - 1 downto ELEM_W);

        process (clk, rst_n)
        begin
            if rst_n = '0' then
                acc(i) <= (others => '0');
            elsif rising_edge(clk) then
                if (in_valid = '1') and (ui = i) then
                    acc(i) <= nxt_i;
                end if;
            end if;
        end process;

    end generate gen_fold;

    ----------------------------------------------------------------------------
    -- 帧结束标志: 最后一个元素写入后的下一拍拉高
    ----------------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                done_r <= '0';
            elsif (in_valid = '1') and
                  ((cnt = TO_UNSIGNED(IN_ELEMS - 1, CNT_W))
                   or (frame_last = '1')) then
                done_r <= '1';
            else
                done_r <= '0';
            end if;
        end if;
    end process;

    fold_done <= done_r;

    ----------------------------------------------------------------------------
    -- 元素计数
    ----------------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                cnt <= (others => '0');
            elsif in_valid = '1' then
                cnt <= cnt + 1;      -- 8 位, 到 256 自然回绕
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 阶段2: 跨单元累加
    --   前半段是"整体下移装载", 后半段是"最低位异或后从最高位喂回",
    --   两次下移抵消, 所以 fold_i(m) 最终就落在 acc(i) 的第 m 个元素位置。
    --   （用 4 元素小例子逐拍推过: 装载后 e_q = in[q]; 折叠后 e_q = in[q]^in[q+4]。）
    --   out[m]    = fold_0[m] xor fold_1[m]      m = 0..31
    --   out[32+m] = fold_2[m] xor fold_3[m]      m = 0..31
    --   m 是 generate 常量, 切片下标静态, 只有纯连线和 1 级异或。
    ----------------------------------------------------------------------------
    gen_out : for m in 0 to HALF - 1 generate
        out_data((m + 1)*ELEM_W - 1 downto m*ELEM_W)
            <= acc(0)(m*ELEM_W + ELEM_W - 1 downto m*ELEM_W)
               xor
               acc(1)(m*ELEM_W + ELEM_W - 1 downto m*ELEM_W);
        out_data((HALF + m + 1)*ELEM_W - 1 downto (HALF + m)*ELEM_W)
            <= acc(2)(m*ELEM_W + ELEM_W - 1 downto m*ELEM_W)
               xor
               acc(3)(m*ELEM_W + ELEM_W - 1 downto m*ELEM_W);
    end generate gen_out;

end architecture rtl;
