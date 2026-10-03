--------------------------------------------------------------------------------
--  tb_enc_axis_postfit.vhd  ——  布局后门级时序仿真的 testbench
--
--  和 tb_enc_axis.vhd 功能相同, 但帧数少很多 —— 门级仿真带完整 SDF 延时,
--  比 RTL 慢一两个数量级, 跑上千帧不现实。
--
--  用法:
--      1) 先用 Quartus 生成门级网表 (已生成, 见 postfit_sim/):
--             quartus_eda --simulation --tool=modelsim --format=vhdl \
--                         --output_directory=postfit_sim enc_axis
--      2) ModelSim:
--             vsim -c -sdfmax /tb_enc_axis_postfit/dut=enc_axis_vhd.sdo \
--                  -do "run 30 us; quit -f" work.tb_enc_axis_postfit
--
--  网表的实体名和端口与 RTL 完全一致（Quartus 生成的 enc_axis.vho 里
--  ENTITY enc_axis 的端口一模一样), 所以这个 testbench 不用改就能绑上去。
--  testbench 本身用 `entity work.enc_axis`, 编译时让 work 库里放的是 .vho
--  而不是 RTL 即可。
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_enc_axis_postfit is
    Generic (
        ELEM_W    : positive := 16;
        BLK_ELEMS : positive := 64;
        BLK_NUM   : positive := 4;
        N_FRAMES  : positive := 1
    );
end entity tb_enc_axis_postfit;

architecture sim of tb_enc_axis_postfit is

    constant IN_ELEMS  : integer := BLK_NUM * BLK_ELEMS;   -- 256
    constant OUT_ELEMS : integer := BLK_ELEMS;             -- 64
    constant CLK_PERIOD : time   := 6.667 ns;              -- 150 MHz

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

    function gen_elem (f : integer; k : integer) return STD_LOGIC_VECTOR is
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

    function exp_elem (f : integer; j : integer) return STD_LOGIC_VECTOR is
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
    -- 绑定到 work.enc_axis —— 编译时放入的是 Quartus 门级网表 enc_axis.vho
    ----------------------------------------------------------------------------
    dut : entity work.enc_axis
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
    -- 激励
    ----------------------------------------------------------------------------
    send_proc : process
    begin
        aresetn  <= '0';
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
                loop
                    wait until rising_edge(aclk);
                    exit when s_tready = '1';
                end loop;
            end loop;
        end loop;

        wait until falling_edge(aclk);
        s_tvalid <= '0';
        s_tlast  <= '0';

        -- 门级仿真带完整 SDF 延时。尾部必须留够: 编码器还要走
        -- S_WAIT(1 拍) + S_SEND(64 拍, 受 m_tready 反压会略多于 64),
        -- 之前只留 50 拍, 结果只收到 47 个输出元素就报错了。
        for i in 0 to 250 loop
            wait until rising_edge(aclk);
        end loop;

        if (n_err = 0) and (frames_seen = N_FRAMES) then
            report "=== POST-FIT SIM OK: " & integer'image(frames_seen)
                & " frames, " & integer'image(n_beats)
                & " beats, 0 errors ===" severity note;
        else
            report "=== POST-FIT SIM FAILED: frames=" & integer'image(frames_seen)
                & " beats=" & integer'image(n_beats)
                & " errors=" & integer'image(n_err) & " ===" severity failure;
        end if;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- 反压
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
    -- 检查
    ----------------------------------------------------------------------------
    check_proc : process (aclk)
        variable j   : integer := 0;
        variable f   : integer := 0;
        variable exp : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                j := 0; f := 0;
                frames_seen <= 0; n_beats <= 0; n_err <= 0;
            elsif m_tvalid = '1' and m_tready = '1' then
                exp := exp_elem(f, j);
                if m_tdata /= exp then
                    n_err <= n_err + 1;
                    if n_err < 5 then
                        report "DATA MISMATCH frame " & integer'image(f)
                            & " elem " & integer'image(j) severity error;
                    end if;
                end if;
                if (j = OUT_ELEMS - 1) and (m_tlast /= '1') then
                    n_err <= n_err + 1;
                    report "tlast missing at frame " & integer'image(f)
                        severity error;
                end if;
                n_beats <= n_beats + 1;
                if j = OUT_ELEMS - 1 then
                    j := 0; f := f + 1;
                    frames_seen <= frames_seen + 1;
                else
                    j := j + 1;
                end if;
            end if;
        end if;
    end process;

end architecture sim;
