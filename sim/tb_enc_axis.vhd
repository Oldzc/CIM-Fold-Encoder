--------------------------------------------------------------------------------
--  tb_enc_axis.vhd  ——  enc_axis 的自校验 testbench
--
--  验证内容:
--    1. AXI4-Stream 握手: tvalid/tready/tlast 时序是否符合协议
--    2. 数据正确性: 输出 64 个元素逐个与独立参考模型比对
--    3. 反压: m_axis_tready 随机拉低, 检查数据不丢不乱
--    4. 连续多帧 (20 帧), 检查帧边界与 tlast
--
--  参考模型 (与 RTL 结构无关的平坦写法):
--    输入 256 个元素 in[0..255], 输出 64 个元素 out[0..63]
--      out[j] = in[base+m] ^ in[base+m+32] ^ in[base+64+m] ^ in[base+96+m]
--      其中 pr = j/32, m = j mod 32, base = pr*128
--
--  运行:
--      vcom -93 parallel_conv_encoder.vhd enc_axis.vhd tb_enc_axis.vhd
--      vsim -c -do "run 60 us; quit -f" work.tb_enc_axis
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_enc_axis is
end entity tb_enc_axis;

architecture sim of tb_enc_axis is

    constant ELEM_W     : integer := 16;
    constant BLK_ELEMS  : integer := 64;
    constant BLK_NUM    : integer := 4;
    constant IN_ELEMS   : integer := BLK_NUM * BLK_ELEMS;   -- 256
    constant OUT_ELEMS  : integer := BLK_ELEMS;             -- 64
    constant N_FRAMES   : integer := 20;
    constant CLK_PERIOD : time    := 6.667 ns;              -- 150 MHz

    signal aclk    : STD_LOGIC := '0';
    signal aresetn : STD_LOGIC := '0';

    signal s_tdata  : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0) := (others => '0');
    signal s_tvalid : STD_LOGIC := '0';
    signal s_tready : STD_LOGIC;
    signal s_tlast  : STD_LOGIC := '0';

    signal m_tdata  : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    signal m_tvalid : STD_LOGIC;
    signal m_tready : STD_LOGIC := '0';
    signal m_tlast  : STD_LOGIC;

    signal frames_seen : integer := 0;
    signal n_beats     : integer := 0;
    signal n_err       : integer := 0;

    ----------------------------------------------------------------------------
    -- 确定性数据源: 第 f 帧的第 k 个元素
    ----------------------------------------------------------------------------
    function gen_elem (f : integer; k : integer)
                       return STD_LOGIC_VECTOR is
        variable s : STD_LOGIC_VECTOR(31 downto 0);
        variable v : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    begin
        s := STD_LOGIC_VECTOR(TO_UNSIGNED(f * 1048576 + k * 4051 + 12345, 32));
        for i in 0 to 7 loop
            s := s(30 downto 0) & (s(31) xor s(21) xor s(1) xor s(0));
        end loop;
        for b in 0 to ELEM_W - 1 loop
            v(b) := s(0);
            s := s(30 downto 0) & (s(31) xor s(21) xor s(1) xor s(0));
        end loop;
        return v;
    end function gen_elem;

    ----------------------------------------------------------------------------
    -- 参考模型: 第 f 帧的第 j 个输出元素
    ----------------------------------------------------------------------------
    function exp_elem (f : integer; j : integer)
                       return STD_LOGIC_VECTOR is
        variable pr   : integer;
        variable m    : integer;
        variable base : integer;
        variable r    : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    begin
        pr   := j / (BLK_ELEMS / 2);
        m    := j mod (BLK_ELEMS / 2);
        base := pr * 2 * BLK_ELEMS;
        r := gen_elem(f, base + m)
             xor gen_elem(f, base + m + BLK_ELEMS/2)
             xor gen_elem(f, base + BLK_ELEMS + m)
             xor gen_elem(f, base + BLK_ELEMS + m + BLK_ELEMS/2);
        return r;
    end function exp_elem;

begin

    aclk <= not aclk after CLK_PERIOD / 2;

    ----------------------------------------------------------------------------
    -- DUT
    ----------------------------------------------------------------------------
    dut : entity work.enc_axis
        generic map (
            ELEM_W    => ELEM_W,
            BLK_ELEMS => BLK_ELEMS,
            BLK_NUM   => BLK_NUM
        )
        port map (
            aclk          => aclk,
            aresetn       => aresetn,
            s_axis_tdata  => s_tdata,
            s_axis_tvalid => s_tvalid,
            s_axis_tready => s_tready,
            s_axis_tlast  => s_tlast,
            m_axis_tdata  => m_tdata,
            m_axis_tvalid => m_tvalid,
            m_axis_tready => m_tready,
            m_axis_tlast  => m_tlast
        );

    ----------------------------------------------------------------------------
    -- 激励: 连续发送 N_FRAMES 帧, 每帧 256 拍, 第 256 拍 tlast
    --       帧与帧之间 tvalid 一直保持高, 考验背靠背能力
    ----------------------------------------------------------------------------
    send_proc : process
    begin
        aresetn <= '0';
        s_tvalid <= '0';
        s_tlast  <= '0';
        s_tdata  <= (others => '0');
        for i in 0 to 3 loop
            wait until rising_edge(aclk);
        end loop;
        aresetn <= '1';
        wait until rising_edge(aclk);

        for f in 0 to N_FRAMES - 1 loop
            for k in 0 to IN_ELEMS - 1 loop
                wait until falling_edge(aclk);
                s_tdata  <= gen_elem(f, k);
                s_tvalid <= '1';
                if k = IN_ELEMS - 1 then
                    s_tlast <= '1';
                else
                    s_tlast <= '0';
                end if;
                -- 等到本拍被接收
                loop
                    wait until rising_edge(aclk);
                    exit when s_tready = '1';
                end loop;
            end loop;
        end loop;

        wait until falling_edge(aclk);
        s_tvalid <= '0';
        s_tlast  <= '0';

        -- 等待输出全部发完
        for i in 0 to 200 loop
            wait until rising_edge(aclk);
        end loop;

        if n_err = 0 and frames_seen = N_FRAMES then
            report "=== ALL TESTS PASSED: " & integer'image(frames_seen)
                & " frames, " & integer'image(n_beats)
                & " output beats, 0 errors ===" severity note;
        else
            report "=== FAILED: frames=" & integer'image(frames_seen)
                & " beats=" & integer'image(n_beats)
                & " errors=" & integer'image(n_err) & " ===" severity failure;
        end if;

        wait;
    end process;

    ----------------------------------------------------------------------------
    -- 输出侧反压: 约 6% 的时钟把 m_axis_tready 拉低
    ----------------------------------------------------------------------------
    bp_proc : process (aclk)
        variable s : STD_LOGIC_VECTOR(31 downto 0) := X"12345678";
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                m_tready <= '0';
            else
                s := s(30 downto 0) & (s(31) xor s(21) xor s(1) xor s(0));
                if s(3 downto 0) = "0000" then
                    m_tready <= '0';
                else
                    m_tready <= '1';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- 接收侧检查: 每次成功握手 (tvalid & tready) 比对一次
    ----------------------------------------------------------------------------
    check_proc : process (aclk)
        variable j : integer := 0;   -- 本帧已收到的元素号
        variable f : integer := 0;   -- 帧号
        variable exp : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                j           := 0;
                f           := 0;
                frames_seen <= 0;
                n_beats     <= 0;
                n_err       <= 0;
            elsif m_tvalid = '1' and m_tready = '1' then
                exp := exp_elem(f, j);

                if m_tdata /= exp then
                    n_err <= n_err + 1;
                    -- 只打印前几条, 避免一个系统性错误刷屏几千行
                    if n_err < 5 then
                        report "DATA MISMATCH frame " & integer'image(f)
                            & " elem " & integer'image(j) severity error;
                    end if;
                end if;

                -- tlast 只允许出现在本帧最后一个元素上
                if (j = OUT_ELEMS - 1) and (m_tlast /= '1') then
                    n_err <= n_err + 1;
                    report "tlast missing at frame " & integer'image(f)
                        severity error;
                elsif (j /= OUT_ELEMS - 1) and (m_tlast = '1') then
                    n_err <= n_err + 1;
                    report "tlast asserted early at frame " & integer'image(f)
                        & " elem " & integer'image(j) severity error;
                end if;

                n_beats <= n_beats + 1;

                if j = OUT_ELEMS - 1 then
                    j           := 0;
                    f           := f + 1;
                    frames_seen <= frames_seen + 1;
                else
                    j := j + 1;
                end if;
            end if;
        end if;
    end process;

end architecture sim;
