--------------------------------------------------------------------------------
--  enc_top.vhd   —— 综合 / 面积 / 时序测量用外壳
--
--  目的:
--    parallel_conv_encoder 有 4096 bit 输入 + 1024 bit 输出, 直接作为顶层
--    会要求 5120 个引脚, 而 EP4CE10F17C8 只有 180 个引脚, 布局布线必然失败。
--    原工程是靠 BDF 顶层把宽总线藏在片内解决的, 这里用等效的 VHDL 外壳。
--
--  外壳构成:
--    * din : 4096 位输入保持寄存器, 模拟上游的接收缓冲
--            (等价于原工程里 uart_loop_1 的 encode_data 寄存器),
--            由 4096 位 LFSR 自反馈驱动, 保证 4096 个输入位互相独立。
--            这一点很关键: 若用短 LFSR 加连线展开, 输入位之间会存在
--            函数相关性, Quartus 会把函数相同的 mid 寄存器合并掉,
--            测出来的面积会严重偏小。
--    * data_out : 1024 位输出, 在 qsf 里整体声明为 VIRTUAL_PIN。
--            虚拟引脚不占用物理引脚, 但能阻止 Quartus 优化掉未被观察到的
--            逻辑, 从而完整保留数据通路。
--
--  因此:
--    parallel_conv_encoder 本体的资源占用看 map.rpt 里的
--    "Analysis & Synthesis Resource Utilization by Entity" 表中
--    |parallel_conv_encoder:uut 那一行 (din 的 4096 个寄存器属于外壳, 应扣除)。
--
--  引脚: clk / rst_n (输入), ovalid (输出), 共 3 个物理引脚。
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity enc_top is
    Port (
        clk      : in  STD_LOGIC;                              -- PIN_M2
        rst_n    : in  STD_LOGIC;                              -- PIN_M1
        ovalid   : out STD_LOGIC;                              -- PIN_M7
        data_out : out STD_LOGIC_VECTOR(1023 downto 0)         -- VIRTUAL_PIN
    );
end entity enc_top;

architecture rtl of enc_top is

    -- 4096 位输入保持寄存器 (外壳, 不属于被测设计)
    signal din  : STD_LOGIC_VECTOR(4095 downto 0);

    -- DUT 输出
    signal dout : STD_LOGIC_VECTOR(1023 downto 0);

begin

    ----------------------------------------------------------------------------
    -- 4096 位自反馈 LFSR, 模拟上游把一整个输入向量打进保持寄存器
    ----------------------------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                din    <= (others => '0');
                din(0) <= '1';                 -- 非零种子
            else
                din <= din(4094 downto 0)
                       & (din(4095) xor din(21) xor din(1) xor din(0));
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 待测设计
    ----------------------------------------------------------------------------
    uut : entity work.parallel_conv_encoder
        generic map (
            ELEM_W    => 16,
            BLK_ELEMS => 64,
            BLK_NUM   => 4
        )
        port map (
            clk       => clk,
            rst_n     => rst_n,
            in_valid  => din(0),      -- 用动态信号, 避免被常量折叠
            data_in   => din,
            out_valid => ovalid,
            data_out  => dout
        );

    ----------------------------------------------------------------------------
    -- 引到端口, 由 qsf 声明为虚拟引脚, 从而完整保留 1024 位数据通路
    ----------------------------------------------------------------------------
    data_out <= dout;

end architecture rtl;
