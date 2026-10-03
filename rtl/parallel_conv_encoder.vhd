--------------------------------------------------------------------------------
--  parallel_conv_encoder.vhd   (V2)
--  基于存内计算的高效编码器 —— 分块计算 + 外部整合
--
--  对应「需求.txt」:
--    L9   输入向量长度 256 元素 x 16 bit = 4096 bit   (BLK_NUM*BLK_ELEMS*ELEM_W)
--    L10  单个存储单元 64 元素 x 16 bit  = 1024 bit   (BLK_ELEMS*ELEM_W)
--    L12  划分为 4 个子块, 每块 64 个元素 (BLK_NUM=4, BLK_ELEMS=64)
--    L13  每个子块先算中间结果, 再在外部整合
--    L14  压缩为 64 元素输出 = 1024 bit              (BLK_ELEMS*ELEM_W)
--
--  数据通路:
--    存储阵列   4 个存储单元, 单元 i 存放元素 mem(i)(0..63)
--
--    阶段1 (块内折叠 / 存内计算)
--        每个存储单元内部把 64 个元素折叠成 32 个元素:
--            mid_i[m] = mem_i[m] xor mem_i[m + 32]      m = 0..31
--
--    阶段2 (外部跨单元整合)
--        相邻两个存储单元的中间结果逐元素累加:
--            out[m]    = mid_0[m] xor mid_1[m]          m = 0..31
--            out[32+m] = mid_2[m] xor mid_3[m]          m = 0..31
--
--    压缩率 = (4*64) : 64 = 4 : 1        (4096 bit -> 1024 bit)
--
--  实现要点:
--    * 两级流水, 无组合环路, 无锁存器 (原版在 combine 进程推断出 512 个锁存器)
--    * 每个输入位只被一个 LUT 使用, 扇出为 1, 布线压力极小
--    * 同步复位, 便于 150 MHz 时序收敛
--    * 上游需用寄存器驱动 data_in (本模块不含输入寄存器, 以节省 4096 个触发器)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity parallel_conv_encoder is
    Generic (
        ELEM_W    : positive := 16;   -- 单个元素的位宽
        BLK_ELEMS : positive := 64;   -- 单个存储单元的元素容量 (须为偶数)
        BLK_NUM   : positive := 4     -- 存储单元 (子块) 个数 (须为偶数)
    );
    Port (
        clk       : in  STD_LOGIC;    -- 系统时钟
        rst_n     : in  STD_LOGIC;    -- 同步复位, 低电平有效
        in_valid  : in  STD_LOGIC;    -- 输入向量有效 (可与 clk 同拍连续给)
        data_in   : in  STD_LOGIC_VECTOR(BLK_NUM*BLK_ELEMS*ELEM_W - 1 downto 0);
        out_valid : out STD_LOGIC;    -- 输出向量有效 (比 in_valid 晚 2 拍)
        data_out  : out STD_LOGIC_VECTOR(BLK_ELEMS*ELEM_W - 1 downto 0)
    );
end entity parallel_conv_encoder;

architecture Behavioral of parallel_conv_encoder is

    --------------------------------------------------------------------
    -- 由泛型导出的常量
    --------------------------------------------------------------------
    constant IN_W  : integer := BLK_NUM  * BLK_ELEMS * ELEM_W;  -- 4096
    constant OUT_W : integer := BLK_ELEMS * ELEM_W;             -- 1024
    constant HALF  : integer := BLK_ELEMS / 2;                  -- 32
    constant NPAIR : integer := BLK_NUM / 2;                    -- 2

    subtype elem_t is STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);

    -- 一个存储单元: BLK_ELEMS 个元素
    type unit_t is array (0 to BLK_ELEMS - 1) of elem_t;
    -- 全部存储单元
    type mem_t  is array (0 to BLK_NUM - 1) of unit_t;

    -- 一个子块的中间结果: HALF 个元素
    type half_t is array (0 to HALF - 1) of elem_t;
    -- 全部子块的中间结果
    type mid_t  is array (0 to BLK_NUM - 1) of half_t;

    --------------------------------------------------------------------
    -- 信号
    --------------------------------------------------------------------
    -- 存储阵列视图: 只是 data_in 的重新分组连线, 不产生任何寄存器
    signal mem      : mem_t;

    -- 阶段1 输出寄存器 (BLK_NUM * HALF 个元素)
    signal mid      : mid_t;

    -- 阶段2 输出寄存器
    signal dout     : STD_LOGIC_VECTOR(OUT_W - 1 downto 0);

    -- 有效标志流水线 (与数据同深度)
    signal vld_pipe : STD_LOGIC_VECTOR(1 downto 0);

begin

    --------------------------------------------------------------------
    -- 存储阵列视图
    --   把输入向量按 BLK_ELEMS 个元素一组, 切成 BLK_NUM 个存储单元。
    --   BLK_NUM*BLK_ELEMS*ELEM_W = 4*64*16 = 4096 bit
    --------------------------------------------------------------------
    gen_mem : for i in 0 to BLK_NUM - 1 generate
        gen_ele : for k in 0 to BLK_ELEMS - 1 generate
            mem(i)(k) <= data_in(((i*BLK_ELEMS + k + 1)*ELEM_W - 1)
                                 downto ((i*BLK_ELEMS + k)*ELEM_W));
        end generate gen_ele;
    end generate gen_mem;

    --------------------------------------------------------------------
    -- 阶段1: 块内折叠 (存内计算)
    --   每个存储单元独立地把 BLK_ELEMS 个元素折叠成 HALF 个元素。
    --   每个输出位 = 同一单元内相隔 HALF 的两个元素之异或,
    --   综合成一级 LUT2, 且每个输入位只被一个 LUT 使用。
    --------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                mid <= (others => (others => (others => '0')));
            else
                for i in 0 to BLK_NUM - 1 loop
                    for m in 0 to HALF - 1 loop
                        mid(i)(m) <= mem(i)(m) xor mem(i)(m + HALF);
                    end loop;
                end loop;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- 阶段2: 外部跨单元整合
    --   第 pr 对存储单元的中间结果逐元素累加, 得到输出的第 pr 段。
    --------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                dout     <= (others => '0');
                vld_pipe <= (others => '0');
            else
                for pr in 0 to NPAIR - 1 loop
                    for m in 0 to HALF - 1 loop
                        dout(((pr*HALF + m + 1)*ELEM_W - 1) downto ((pr*HALF + m)*ELEM_W))
                            <= mid(2*pr)(m) xor mid(2*pr + 1)(m);
                    end loop;
                end loop;
                vld_pipe <= vld_pipe(0) & in_valid;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- 输出
    --------------------------------------------------------------------
    data_out  <= dout;
    out_valid <= vld_pipe(1);

end architecture Behavioral;
