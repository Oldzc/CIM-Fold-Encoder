--------------------------------------------------------------------------------
--  tb_sys_cdc.vhd  ——  双时钟域完整系统端到端验证
--
--  被测: sys_cdc (两个时钟域 + 两个异步 FIFO)
--
--    uart_rxd(位级) ─> uart_recv ─> uart_to_axis ─>FIFO─> enc_axis ─>FIFO─>
--                    ─> axis_to_uart ─> uart_send ─> uart_txd(位级)
--      50 MHz 域 ─────────────────────────────┘  └── 150 MHz 域 ──┘
--
--  两侧都是**真实的串口波形**, 不是内部信号:
--    * 输入侧从 uart_rxd 引脚一位一位地灌: 起始位 + 8 数据位(LSB 先) + 停止位,
--      位宽 434 个 50 MHz 时钟, 共 512 个字节 (256 个 16bit 元素)
--    * 输出侧对 uart_txd 做起始位检测 + 位中点采样, 共 128 个字节
--    * 每个字节与独立参考模型 exp_elem 逐个比对
--
--  两个时钟完全独立: 20 ns (50 MHz) 和 6.667 ns (150 MHz), 相位无关。
--
--  运行:
--      vcom -93 enc_fold.vhd enc_axis.vhd uart_to_axis.vhd axis_to_uart.vhd \
--              axis_async_fifo.vhd uart_recv.vhd uart_send.vhd \
--              sys_cdc.vhd tb_sys_cdc.vhd
--      vsim -c -do "run 75 ms; quit -f" work.tb_sys_cdc
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_sys_cdc is
end entity tb_sys_cdc;

architecture sim of tb_sys_cdc is

    constant ELEM_W    : integer := 16;
    constant BLK_ELEMS : integer := 64;
    constant BLK_NUM   : integer := 4;
    constant IN_ELEMS  : integer := BLK_NUM * BLK_ELEMS;   -- 256
    constant OUT_ELEMS : integer := BLK_ELEMS;             -- 64
    constant N_BYTES   : integer := 2 * OUT_ELEMS;         -- 128

    constant CLK50_PERIOD : time    := 20 ns;              -- 50 MHz (UART 域)
    constant CLK150_PERIOD: time    := 6.667 ns;           -- 150 MHz (编码器域)
    constant BPS_CNT      : integer := 434;                -- 50000000/115200
    constant BIT_TIME     : time    := BPS_CNT * CLK50_PERIOD;

    signal sys_clk   : STD_LOGIC := '0';
    signal clk_150   : STD_LOGIC := '0';
    signal sys_rst_n : STD_LOGIC := '0';

    signal uart_rxd  : STD_LOGIC := '1';   -- 空闲为高
    signal uart_txd  : STD_LOGIC;
    signal overflow  : STD_LOGIC;

    signal bytes_ok : integer := 0;
    signal n_err    : integer := 0;

    ----------------------------------------------------------------------------
    -- 与其它 testbench 相同的参考模型
    ----------------------------------------------------------------------------
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

    ----------------------------------------------------------------------------
    -- 两个独立时钟
    ----------------------------------------------------------------------------
    sys_clk <= not sys_clk after CLK50_PERIOD  / 2;
    clk_150 <= not clk_150 after CLK150_PERIOD / 2;

    ----------------------------------------------------------------------------
    -- 被测: 双时钟域系统
    ----------------------------------------------------------------------------
    dut : entity work.sys_cdc
        port map (
            sys_clk     => sys_clk,
            clk_150     => clk_150,
            sys_rst_n   => sys_rst_n,
            uart_rxd    => uart_rxd,
            uart_txd    => uart_txd,
            rx_overflow => overflow
        );

    ----------------------------------------------------------------------------
    -- 输入: 位级串行灌 512 个字节
    ----------------------------------------------------------------------------
    send_proc : process
        variable el : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
        variable b  : STD_LOGIC_VECTOR(7 downto 0);
    begin
        sys_rst_n <= '0';
        uart_rxd  <= '1';
        for i in 0 to 9 loop
            wait until rising_edge(sys_clk);
        end loop;
        sys_rst_n <= '1';
        wait until rising_edge(sys_clk);

        for k in 0 to IN_ELEMS - 1 loop
            el := gen_elem(0, k);
            for half in 0 to 1 loop
                if half = 0 then
                    b := el(7 downto 0);          -- 先发低字节
                else
                    b := el(ELEM_W - 1 downto ELEM_W - 8);
                end if;

                uart_rxd <= '0';                  -- 起始位
                wait for BIT_TIME;
                for i in 0 to 7 loop              -- 数据位 LSB 先
                    uart_rxd <= b(i);
                    wait for BIT_TIME;
                end loop;
                uart_rxd <= '1';                  -- 停止位
                wait for BIT_TIME;
                wait for BIT_TIME;                -- 字节间留一点空隙
            end loop;
        end loop;

        uart_rxd <= '1';
        -- 等输出侧把 128 个字节发完 (128 x 10 x 434 个 20ns 时钟 ≈ 11.1 ms)
        wait for 16 ms;

        if (n_err = 0) and (bytes_ok = N_BYTES) and (overflow = '0') then
            report "=== CDC SYSTEM OK: 512 bytes in -> " & integer'image(bytes_ok)
                & " bytes out across two clock domains, 0 errors ===" severity note;
        else
            report "=== CDC SYSTEM FAILED: bytes=" & integer'image(bytes_ok)
                & " expected=" & integer'image(N_BYTES)
                & " errors=" & integer'image(n_err)
                & " overflow=" & STD_LOGIC'image(overflow) & " ===" severity failure;
        end if;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- 输出: 对真实 uart_txd 做起始位检测 + 位中点采样
    --   (uart_send 的停止位被截短到 BPS_CNT-BPS_CNT/16, 所以停止位只数半个周期)
    ----------------------------------------------------------------------------
    rx_proc : process (sys_clk)
        variable st     : integer := 0;
        variable cnt    : integer := 0;
        variable bidx   : integer := 0;
        variable sh     : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
        variable nbytes : integer := 0;
        variable exp    : STD_LOGIC_VECTOR(7 downto 0);
        variable full   : STD_LOGIC_VECTOR(ELEM_W - 1 downto 0);
        variable k      : integer;
    begin
        if rising_edge(sys_clk) then
            if sys_rst_n = '0' then
                st := 0; cnt := 0; bidx := 0; nbytes := 0;
                bytes_ok <= 0; n_err <= 0;
            else
                case st is
                    when 0 =>
                        if uart_txd = '0' then
                            st := 1; cnt := 0;
                        end if;
                    when 1 =>
                        if cnt = BPS_CNT/2 - 1 then
                            st := 2; cnt := 0; bidx := 0;
                        else
                            cnt := cnt + 1;
                        end if;
                    when 2 =>
                        if cnt = BPS_CNT - 1 then
                            cnt := 0;
                            sh(bidx) := uart_txd;
                            if bidx = 7 then st := 3; else bidx := bidx + 1; end if;
                        else
                            cnt := cnt + 1;
                        end if;
                    when others =>
                        if cnt = BPS_CNT/2 - 1 then
                            cnt := 0; st := 0;

                            k    := nbytes / 2;
                            full := exp_elem(0, k);
                            if (nbytes mod 2) = 0 then
                                exp := full(7 downto 0);
                            else
                                exp := full(ELEM_W - 1 downto ELEM_W - 8);
                            end if;

                            if sh /= exp then
                                n_err <= n_err + 1;
                                if n_err < 5 then
                                    report "BYTE MISMATCH at index "
                                        & integer'image(nbytes)
                                        & " (output element " & integer'image(k) & ")"
                                        severity error;
                                end if;
                            end if;

                            nbytes   := nbytes + 1;
                            bytes_ok <= nbytes;
                        else
                            cnt := cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture sim;
