# CIM-Fold-Encoder · 基于存内计算的高效编码器

> **CIM-Fold-Encoder** — A 4:1 compression encoder for 4096-bit vectors that exceed a
> single compute-in-memory cell, folded at the storage unit's write port.
> VHDL · Altera Cyclone IV E · AXI4-Stream · 150 MHz

**4:1 压缩编码器**：256 个 16 bit 元素（4096 bit）分成
4 个子块，在存储单元内就地折叠，输出 64 个 16 bit 元素（1024 bit）。
编码器数据通路运行在 150 MHz，输出接口为 AXI4-Stream。

本设计的关键在于**不驻留原始输入**：元素到达时就在存储单元的写入口完成折叠，
因此不需要 4096 bit 的输入阵列 —— 编码器本体（`enc_axis`）只占
Cyclone IV E EP4CE10 的 **30%**，含 UART 的双时钟域完整系统（`sys_cdc`）占 **42%**。

| | |
|---|---|
| 器件 | Altera Cyclone IV E **EP4CE10F17C8**（10,320 逻辑单元） |
| 工具 | Quartus II 9.1 SP2 / ModelSim SE-64 10.4 |
| 最终形态 | `sys_cdc`（双时钟域完整系统） |
| 面积 | **4,383 LE = 42%**（≤ 60%） |
| 频率 | 编码器域 **164.20 MHz**（≥ 150 MHz） |
| 功耗 | **113.41 mW**（< 1.5 W） |
| 验证 | 9 个自校验 testbench 全部 0 错误 + 等价性证明 + 布局后门级时序仿真 |

> 这是简明索引。完整的推导过程、逐阶段调试记录与失败尝试见
> [`docs/工程记录.md`](docs/工程记录.md)。

---

## 一、仓库结构

```
RTL_V2/
├── README.md                    本文件（简明索引）
├── .gitignore                   排除 Quartus / ModelSim 的编译产物
├── rtl/                         可综合 RTL
│   ├── enc_fold.vhd                 写入即折叠核心（实际使用）
│   ├── enc_axis.vhd                 AXI4-Stream 顶层（需求 L16）
│   ├── uart_to_axis.vhd             上游适配：串口字节 -> 16 bit 元素
│   ├── axis_to_uart.vhd             下游适配：16 bit 元素 -> 串口字节
│   ├── axis_async_fifo.vhd          跨时钟域异步 FIFO（格雷码指针）
│   ├── sys_top.vhd                  输入链路顶层
│   ├── sys_full.vhd                 完整系统顶层（单时钟 50 MHz）
│   ├── sys_cdc.vhd                  双时钟域完整系统   <- 最终形态
│   ├── parallel_conv_encoder.vhd    参考实现：4096 bit 并行阵列
│   │                                （供 enc_v2 工程与等价性测试使用）
│   ├── enc_top.vhd                  综合测量外壳（非交付物）
│   └── provided/                    **给定的串口模块，原样使用、未改动**
│       ├── uart_recv.vhd
│       ├── uart_send.vhd
│       └── README.md
├── sim/                         11 个 testbench + 独立 Python 参考模型
├── constraints/                 5 个 SDC（每个工程一份）
├── quartus/                     每个工程独占一个目录，各自带 db/
│   ├── enc_v2/  enc_axis/  sys_top/  sys_full/  sys_cdc/
│   └── enc_axis/postfit/            门级网表 + 两套 SDF（可重新生成）
├── scripts/                     工具脚本 + 报告生成脚本
└── docs/
    ├── 基于存内计算的高效编码器设计_设计报告.docx    ★ 可提交的设计报告
    ├── 工程记录.md                  完整工程记录（全部推导与调试过程）
    └── fit_seed_sensitivity.txt     布局种子敏感性数据
```

**本目录自成一体**：编译与仿真需要的源码全部在这里（含给定的两个串口模块），
直接复制 `RTL_V2/` 一个文件夹即可使用，不依赖任何外部目录。

**每个 Quartus 工程独占一个目录是有意为之。** 多个工程共用一个目录、共用
`db/`，会让布局器**复用陈旧的增量编译结果**——拿旧网表出报告，而且不报错。
详见 5.4 节。

---

## 二、设计说明

### 2.1 核心思想：写入即折叠

朴素实现需要一块 4096 bit 的驻留输入阵列，等 256 个元素收齐再变换。这在
EP4CE10 上不可行：4096 个输入触发器 + 3072 个运算触发器 = 7169 个，
**在加任何逻辑之前就占到器件的 69%**，已突破 60% 的面积上限。

本设计不驻留原始输入，而是让每个存储单元一边接收元素、一边就地折叠。
每个单元只需持有 32 个**折叠后**的元素（512 bit），四个单元共 2048 bit。

### 2.2 数据通路

```
256 元素 × 16 bit
      │
      ▼   按 4 个子块依次写入（每块 64 元素）
┌─────────────────────────────────────┐
│  存储单元 i（i = 0..3）              │
│  512 bit 移位寄存器                  │
│   前半段 32 拍：整体右移，装载        │
│   后半段 32 拍：最低元素异或后喂回    │
│   -> 单元内折叠，得 32 个中间结果     │
└─────────────────────────────────────┘
      │   4 个单元 × 32 个 = 128 个中间结果
      ▼   跨单元累加（阶段 2）
   64 元素 × 16 bit  ->  AXI4-Stream
```

折叠关系（GF(2) 上的异或线性变换）：

```
out[j] = in[base+m] ^ in[base+m+32] ^ in[base+64+m] ^ in[base+64+m+32]
         其中 base = (j / 32) * 128,  m = j mod 32,  j = 0..63
```

### 2.3 两次下移能正好抵消

设四个元素 x0..x3 依次到来，m 表示它在半块内的位置（0..31）：

- **前半段（ph=0，32 拍）**——纯右移：结束后 `M[m] = x_m`
- **后半段（ph=1，32 拍）**——取出最低元素、异或、喂回最高位：结束后
  `M[m] = x_m ^ x_(m+32)`

即每个单元按下标 m 独立折叠。这一等价关系由 `tb_equivalence.vhd` 做了
**逐位证明**：与结构完全不同的 `parallel_conv_encoder` 并列仿真 30 帧，
输出**0 处差异**。

---

## 三、需求符合性

| 行号 | 要求 | 实现 | 实测 |
|---|---|---|---|
| L9 | 输入 256 元素 × 16 bit | 4 单元 × 64 元素 | 4096 bit/帧 |
| L10 | 单元容量 ≤ 64 元素 | 每单元 32 个折叠后元素 | 32 ≤ 64 |
| L12 | 分 4 子块 × 64 元素 | `BLK_NUM=4, BLK_ELEMS=64` | 4 × 64 |
| L13 | 子块中间结果 + 外部整合 | 单元内折叠 + 跨单元累加 | 等价性 0 差异 |
| L14 | 压缩为 64 元素 | 4 个输入元素异或 | 4 : 1 |
| L16 | AXI4-Stream，16 bit/元素 | `enc_axis.vhd` | 40 引脚 |
| L19 | 150 MHz | 双时钟域，编码器域 150 MHz | **164.20 MHz** |
| L20 | ≥ 2000 向量/秒 | 每帧约 320 拍 | **46.9 万向量/秒** |
| L21 | 面积 ≤ 60% | 无驻留输入阵列 | **4,383 LE = 42%** |
| L22 | 动态功耗 < 1.5 W | — | **113.41 mW** |

---

## 四、实测结果

### 4.1 功能验证

9 个自校验 testbench，全部从交付文件重新编译运行：

| # | testbench | 验证内容 | 结果 |
|---|---|---|---|
| 1 | `tb_parallel_conv_encoder` | 编码器本体：定向 + 随机 + 背靠背 | 1104 组向量，0 错误 |
| 2 | `tb_equivalence` | `enc_fold` 与参考实现逐位等价 | 30 帧，0 差异 |
| 3 | `tb_enc_axis` | AXI4-Stream 握手、随机反压、`tlast` | 20 帧 1280 拍，0 错误 |
| 4 | `tb_uart_axis_chain` | 上游整链：字节级整帧 + 反压 | 3 帧 192 拍，0 错误 |
| 5 | `tb_uart_to_axis` | 接真实 `uart_recv` 的位级联调 | 2 元素，0 错误 |
| 6 | `tb_axis_to_uart` | 解码真实 `uart_txd` 波形 | 128 字节，0 错误 |
| 7 | `tb_system_loop` | 整系统端到端（单时钟 50 MHz） | 512 字节进 → 128 字节出，0 错误 |
| 8 | `tb_axis_async_fifo` | 异步 FIFO 双时钟压测 | 400 字，0 错误 |
| 9 | `tb_sys_cdc` | 双时钟域整系统，两侧真实串口波形 | 512 字节进 → 128 字节出，0 错误 |

第 9 项最完整：输入侧从 `uart_rxd` 引脚一位一位地灌（起始位 + 8 数据位 +
停止位，位宽 434 个 50 MHz 时钟），输出侧对 `uart_txd` 做起始位检测与位中点
采样，两个时钟完全独立（20 ns 与 6.667 ns）。

另外用 `ref_model.py`（独立 Python 参考模型）对仿真转储的 1104 组向量做
第三方交叉验证，排除「testbench 与 DUT 犯同一个错」。

### 4.2 硬件面积

| 工程 | 顶层 | 逻辑单元 | 占比 | 寄存器 | 引脚 |
|---|---|---|---|---|---|
| `enc_axis` | AXI4-Stream 顶层 | 3,132 | 30% | 3,103 | 40 |
| `sys_top` | 输入链路 | 3,515 | 34% | 3,351 | 23 |
| `sys_full` | 完整系统（单时钟） | 3,667 | 36% | 3,455 | 5 |
| **`sys_cdc`** | **双时钟域完整系统** | **4,383** | **42%** | 4,065 | 6 |
| `enc_v2` | 并行阵列参考实现 | 7,284 | 71% | 7,169 | 3 |

### 4.3 时序与吞吐率

| 工程 | 时钟域 | 约束 | 实测 Fmax | 建立余量 |
|---|---|---|---|---|
| `enc_axis` | aclk | 150 MHz | 161.52 MHz | +0.485 ns |
| `sys_top` | sys_clk | 150 MHz | 158.30 MHz | 正 |
| **`sys_cdc`** | **clk_150（编码器）** | 150 MHz | **164.20 MHz** | +0.500 ns |
| `sys_cdc` | sys_clk（UART） | 50 MHz | 82.26 MHz | 充足 |
| `sys_full` | sys_clk | 50 MHz | 84.65 MHz | 充足 |

`enc_axis` 在 **6 个布局种子上全部通过** 150 MHz（161.16 ~ 161.76 MHz），
`enc_axis.qsf` 已固定 `FITTER_EFFORT "STANDARD FIT"` 与 `SEED 2` 以便复现。

**吞吐率必须分两层说，否则结论会过于乐观：**

- **编码器 + AXI4-Stream 层**（需求 L16 指定的那一层）：每帧 256 个输入拍 +
  64 个输出拍 ≈ 320 拍，握手之间没有空泡，150 MHz 下约 **46.9 万向量/秒**，
  是需求 2000 的 **234 倍**。
- **通过 UART 的端到端**：115200 bps、8N1 每字节 10 bit，即 11520 字节/秒；
  一帧输入 512 字节，所以只能支撑 **约 22.5 向量/秒**。

L20 是针对「存内计算阵列 + AXI4-Stream」这一层提的，在这一层完全满足。
而 115200 bps 的串口**在物理上不可能**喂出 2000 向量/秒（那需要 8.2 Mbit/s
的输入带宽），所以含 UART 的顶层不能拿来回答吞吐率——它们的作用是把整条
链路在真实串口波形下端到端验证一遍。要真正达到 2000 向量/秒的端到端吞吐，
前级必须换成 AXI4-Stream DMA 或并行接口，而 `enc_axis` 已经就绪。

### 4.4 功耗

| 工程 | 总功耗 | 核心动态 | 核心静态 | I/O |
|---|---|---|---|---|
| `enc_axis` | 111.65 mW | 39.69 mW | — | — |
| **`sys_cdc`** | **113.41 mW** | 56.64 mW | 46.5 mW | 10.2 mW |
| `sys_full` | 73.56 mW | 17.34 mW | — | — |
| `enc_v2` | 173.61 mW | 116.94 mW | 46.56 mW | 10.11 mW |

全部远低于 1.5 W，`sys_cdc` 的核心动态功耗仅 56.64 mW，留有 26 倍余量。
PowerPlay 的估计置信度为 **Low**（向量无关估计）——命令行的 VCD 输入已经
找对写法但该版本读取器匹配不上信号，需在 GUI 中补上，详见工程记录。

### 4.5 布局后门级时序仿真

没有开发板时最接近「真的能跑」的验证：对布局布线后的门级网表仿真，
用 SDF 反标真实门延时与互连延时。两种工艺角分开跑：

| 检查项 | 工艺角 | 结果 |
|---|---|---|
| 建立时间 | Slow 1200mV 85C（max 延时） | 1 帧 64 拍，0 错误 |
| 保持时间 | Fast 1200mV 0C（min 延时） | 1 帧 64 拍，0 错误 |

---

## 五、关键工程决策

以下五点都是实际踩过才总结出来的，完整过程见 `docs/工程记录.md`。

### 5.1 复位必须用异步（Cyclone IV 的 IO 单元只有异步清零）

为了让 AXI 输出直驱引脚，需要把输出寄存器打包进 IO 单元。但布局器报
`Can't pack node m_data_r[0..15] to I/O pin`——因为 **Cyclone IV 的 IOE
输出寄存器只有异步清零、没有同步清零**。改成异步复位后警告归零，
Fmax 从 113 MHz 跳到 130 MHz。

### 5.2 存储器要显式复位，否则会被推断成双时钟 Block RAM

FIFO 的存储器数组如果**不复位**，Quartus 会把它推断成双时钟 Block RAM
并警告 `read-during-write behavior ... is undefined`——典型的
**「仿真对、上板可能不对」**。加一句 `mem <= (others => (others => '0'))`
即可强制用触发器实现，行为与仿真一致。

### 5.3 复位释放窗口里 `tready` 会说谎

复位释放要过两级同步器（2 拍），这 2 拍内指针还在复位、不会真写入；
但 `s_tready` 已经是 `'1'`，上游会以为握手成功而**把第一个字丢掉**。
现象很迷惑人：收到的字数只差 1，但数据从第 0 个就全错。修法是用复位释放
同步标志把两侧按住：

```vhdl
s_tready <= '0' when w_rst_sync(1) = '0' else (not wfull);
m_tvalid <= '0' when r_rst_sync(1) = '0' else (not rempty);
```

### 5.4 每个 Quartus 工程必须独占目录

收尾复核时发现 `enc_axis` 换布局种子 Fmax 会在 144~156 MHz 之间摆动，
曾误判为「设计卡在 150 MHz 线上」。**这个判断是错的。**

真相：五个工程原先共用一个目录、共用 `db/`，布局器**复用了陈旧的增量编译
结果**。铁证是——把 `enc_fold` 重构之后重跑种子扫描，**六个种子的数字和
重构前一模一样，连小数位都不差**；真实的重新布局不可能这么巧。

搬进独立目录后重扫，六个种子全部通过：

| 工程组织 | 逻辑单元 | Fmax 范围 | 通过率 |
|---|---|---|---|
| 共用一个目录、共用 db | 3,518 ~ 3,574 | 143.97 ~ 155.79 MHz | 3 / 6 |
| **各自独立目录、独立 db** | **3,132 ~ 3,140** | **161.16 ~ 161.76 MHz** | **6 / 6** |

**差 396 个逻辑单元、约 6 MHz。** 这类错误比编译失败危险得多：它不报错，
只是悄悄基于旧网表出结果。

### 5.5 跨时钟域用格雷码指针，不用二进制指针

`uart_recv` / `uart_send` 的 `CLK_FREQ = 50 MHz`、`UART_BPS = 115200` 是
写死的常量，分频比只在 50 MHz 下正确；而编码器按 150 MHz 收敛。两者不能
共用时钟，只能在中间做 CDC。

```
┌──────────── 50 MHz 域 ────────────┐   ┌──── 150 MHz 域 ────┐
uart_rxd ─> uart_recv ─> uart_to_axis ─>│FIFO│─> enc_axis ─>│FIFO│─>
                                        └────┘              └────┘
  ─> axis_to_uart ─> uart_send ─> uart_txd      (回到 50 MHz 域)
```

CDC 由通用模块 `axis_async_fifo.vhd` 完成，采用**格雷码指针 + 两级同步器**：
灰码相邻数值只差一位，跨时钟采样最多错一位，而这个错误在空/满判断里是安全的；
直接同步多比特二进制指针则会采到「半新半旧」的值，指针跳到完全错误的位置。

时序约束里必须写 `set_clock_groups -asynchronous`——两个域之间没有共同的
周期关系，不做静态时序分析，否则会报一堆跨域假违例把真违例淹没。

---

## 六、如何复现

### 6.1 工具的两个路径限制（先知道，否则会静默失败）

1. **ModelSim 10.4 处理不了含中文的路径**（报 `sqlite3_open ... unable to
   open database file`）——要先把源文件复制到纯 ASCII 目录再编译。
2. **Quartus 的 `project_open` 不认中文绝对路径**（报 `Project does not
   exist or has illegal name characters`）——`quartus_sta -t <脚本>` 必须
   **先 cd 到工程目录**再用相对路径指脚本。

### 6.2 全部 9 个仿真

```bat
set RTL=<RTL_V2 的路径>
mkdir D:\sim_enc
copy "%RTL%\rtl\*.vhd"            D:\sim_enc\
copy "%RTL%\rtl\provided\*.vhd"   D:\sim_enc\
copy "%RTL%\sim\tb_*.vhd"         D:\sim_enc\
copy "%RTL%\sim\ref_model.py"     D:\sim_enc\
cd /d D:\sim_enc
vlib work
vcom -93 -work work parallel_conv_encoder.vhd enc_fold.vhd enc_axis.vhd
vcom -93 -work work uart_to_axis.vhd axis_to_uart.vhd axis_async_fifo.vhd
vcom -93 -work work uart_recv.vhd uart_send.vhd
vcom -93 -work work sys_cdc.vhd sys_full.vhd sys_top.vhd enc_top.vhd
vcom -93 -work work tb_*.vhd

vsim -c -do "run 25 us;  quit -f" work.tb_parallel_conv_encoder
vsim -c -do "run 400 us; quit -f" work.tb_equivalence
vsim -c -do "run 60 us;  quit -f" work.tb_enc_axis
vsim -c -do "run 900 us; quit -f" work.tb_uart_axis_chain
vsim -c -do "run 1 ms;   quit -f" work.tb_uart_to_axis
vsim -c -do "run 13 ms;  quit -f" work.tb_axis_to_uart
vsim -c -do "run 15 ms;  quit -f" work.tb_system_loop
vsim -c -do "run 60 us;  quit -f" work.tb_axis_async_fifo
vsim -c -do "run 75 ms;  quit -f" work.tb_sys_cdc
```

必须用 `run <时间>` 而不是 `run -all`——testbench 里的时钟自由振荡，
`run -all` 永远不会返回。

### 6.3 五个 Quartus 工程

每个工程在自己的目录里按名字执行（以 `enc_axis` 为例，其余换名字即可）：

```bat
cd RTL_V2\quartus\enc_axis
quartus_map enc_axis
quartus_fit enc_axis
quartus_asm enc_axis
quartus_sta enc_axis
quartus_pow enc_axis
```

工程对应：`enc_v2`（并行阵列参考）、`enc_axis`（AXI 顶层）、`sys_top`
（输入链路）、`sys_full`（完整系统，单时钟）、`sys_cdc`（双时钟域）。

> `quartus_pow` 要求 Assembler 已成功跑过；重新 fit 过要先补一次
> `quartus_asm`，否则报 "requires a successful run of the Assembler"。

### 6.4 门级时序仿真

```bat
cd RTL_V2\quartus\enc_axis
quartus_eda --simulation --tool=modelsim --format=vhdl ^
            --output_directory=postfit enc_axis
```

再把 `postfit\` 下的网表与两套 SDF、`sim\tb_enc_axis_postfit.vhd`、
`scripts\run_postfit_sim.do` 复制到 ASCII 目录执行该脚本（文件清单写在脚本开头）。

---

## 七、已知限制

| # | 限制 | 说明 |
|---|---|---|
| 1 | **上板 PLL 未包含在 RTL 中** | `sys_cdc` 把 `clk_150` 当引脚输入以便仿真。真实板子需用 MegaWizard 生成 50→150 MHz 的 PLL（multiply by 3, divide by 1, 补偿 CLK0），把 `c0` 接内部时钟、`locked` 与复位相与即可 |
| 2 | **功耗置信度为 Low** | 需按仿真活动数据（VCD）计算；命令行写法已找对但该版本 VCD 读取器匹配不上信号，只能在 GUI 中补 |
| 3 | **仓库路径含中文** | ModelSim 无法在中文路径下建库；Quartus `project_open` 不认中文绝对路径。规避方法见 6.1 |
| 4 | **复用的 UART 模块用 32 位计数器** | `uart_send` / `uart_recv` 的 `clk_cnt` / `tx_cnt` 是 32 位 `integer`，把单时钟整机能力压在 134 MHz；分域之后无影响 |
| 5 | **UART 前端无法支撑 2000 向量/秒** | 见 4.3。需换 AXI4-Stream DMA 前级；`enc_axis` 已就绪 |
| 6 | **未做动态长度的运行时配置** | 需求 L29 的可选扩展。当前 `ELEM_W` / `BLK_ELEMS` / `BLK_NUM` 已全部泛型化，改为运行时可配置需增加配置寄存器 |
