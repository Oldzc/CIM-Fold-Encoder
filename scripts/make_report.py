# -*- coding: utf-8 -*-
"""
生成《基于存内计算的高效编码器设计》设计报告
"""
import os
import re
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

BODY_FONT = "宋体"
HEAD_FONT = "黑体"
CODE_FONT = "Consolas"
BODY_SIZE = Pt(10.5)      # 五号
CODE_SIZE = Pt(8)         # 等宽代码块：8pt 时一行可容纳约 100 个半角字符

# 输出路径按脚本自身位置推算，这样在哪个目录执行都一样
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(
    HERE, "..", "docs", "基于存内计算的高效编码器设计_设计报告.docx"))


# ---------------------------------------------------------------- 基础工具
def set_font(run, name=BODY_FONT, size=BODY_SIZE, bold=None, color=None,
             ea=None):
    run.font.name = name
    run.font.size = size
    if bold is not None:
        run.font.bold = bold
    if color is not None:
        run.font.color.rgb = color
    rPr = run._element.get_or_add_rPr()
    rFonts = rPr.find(qn('w:rFonts'))
    if rFonts is None:
        rFonts = OxmlElement('w:rFonts')
        rPr.append(rFonts)
    # 代码块正文用 Consolas，但它没有中文字形，所以中文单独指定宋体，
    # 否则 Word 会自行回退到某个不确定的字体
    rFonts.set(qn('w:eastAsia'), ea or name)
    rFonts.set(qn('w:ascii'), name)
    rFonts.set(qn('w:hAnsi'), name)


def _emit(p, text, font, size, bold):
    """再处理 `等宽` 片段"""
    for seg in re.split(r'(`[^`]+`)', text):
        if not seg:
            continue
        if len(seg) > 2 and seg.startswith('`') and seg.endswith('`'):
            r = p.add_run(seg[1:-1])
            set_font(r, CODE_FONT, Pt(size.pt - 1), bold, ea=BODY_FONT)
        else:
            r = p.add_run(seg)
            set_font(r, font, size, bold)


def add_rich(p, text, font=BODY_FONT, size=BODY_SIZE, base_bold=False):
    """把 **粗体** 与 `等宽` 解析成真正的 run（否则文档里会留下字面的星号）"""
    for part in re.split(r'(\*\*.+?\*\*)', text, flags=re.S):
        if not part:
            continue
        if len(part) > 4 and part.startswith('**') and part.endswith('**'):
            _emit(p, part[2:-2], font, size, True)
        else:
            _emit(p, part, font, size, base_bold)


def para(doc, text="", size=BODY_SIZE, bold=False, align=None,
         font=BODY_FONT, space_after=6, indent_first=False):
    p = doc.add_paragraph()
    if align is not None:
        p.alignment = align
    pf = p.paragraph_format
    pf.space_after = Pt(space_after)
    pf.line_spacing = 1.25
    if indent_first:
        pf.first_line_indent = Pt(21)
    if text:
        add_rich(p, text, font, size, bold)
    return p


def heading(doc, text, level=1):
    sizes = {0: Pt(22), 1: Pt(16), 2: Pt(13.5), 3: Pt(12)}
    p = doc.add_heading("", level=level)
    p.paragraph_format.space_before = Pt(14 if level <= 1 else 10)
    p.paragraph_format.space_after = Pt(6)
    r = p.add_run(text)
    set_font(r, HEAD_FONT, sizes.get(level, Pt(12)), bold=True,
             color=RGBColor(0, 0, 0))
    return p


def code(doc, text):
    """等宽代码块，整体缩进、带底纹"""
    tbl = doc.add_table(rows=1, cols=1)
    tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
    tbl.autofit = False
    _fixed_layout(tbl)
    cell = tbl.cell(0, 0)
    cell.width = Cm(16)
    _set_grid(tbl, [16])
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:fill'), 'F4F4F4')
    cell._tc.get_or_add_tcPr().append(shd)
    lines = text.strip("\n").split("\n")
    cell.paragraphs[0].text = ""
    for i, ln in enumerate(lines):
        p = cell.paragraphs[0] if i == 0 else cell.add_paragraph()
        p.paragraph_format.space_after = Pt(0)
        p.paragraph_format.line_spacing = 1.0
        r = p.add_run(ln if ln else " ")
        set_font(r, CODE_FONT, CODE_SIZE, ea=BODY_FONT)
    doc.add_paragraph().paragraph_format.space_after = Pt(2)
    return tbl


def _fixed_layout(tbl):
    """关掉自动调整、改用固定列宽，避免 Word 里表格被内容撑出页面"""
    tblPr = tbl._tbl.tblPr
    old = tblPr.find(qn('w:tblLayout'))
    if old is not None:
        tblPr.remove(old)
    layout = OxmlElement('w:tblLayout')
    layout.set(qn('w:type'), 'fixed')
    tblPr.append(layout)


def _set_grid(tbl, widths_cm):
    """固定布局下 Word 按 tblGrid 决定列宽，所以必须同步改 tblGrid"""
    tbl_el = tbl._tbl
    grid = tbl_el.find(qn('w:tblGrid'))
    if grid is None:
        return
    cols = grid.findall(qn('w:gridCol'))
    for c, w in zip(cols, widths_cm):
        c.set(qn('w:w'), str(int(Cm(w).twips)))


def table(doc, headers, rows, widths=None, font_size=Pt(9.5)):
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = 'Table Grid'
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = False
    _fixed_layout(t)
    hdr = t.rows[0].cells
    for i, h in enumerate(headers):
        hdr[i].text = ""
        p = hdr[i].paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_after = Pt(0)
        add_rich(p, str(h), HEAD_FONT, font_size, True)
        shd = OxmlElement('w:shd')
        shd.set(qn('w:val'), 'clear')
        shd.set(qn('w:fill'), 'E8EEF7')
        hdr[i]._tc.get_or_add_tcPr().append(shd)
    for row in rows:
        cells = t.add_row().cells
        for i, v in enumerate(row):
            cells[i].text = ""
            p = cells[i].paragraphs[0]
            p.paragraph_format.space_after = Pt(0)
            p.paragraph_format.line_spacing = 1.1
            add_rich(p, str(v), BODY_FONT, font_size, False)
    if widths:
        _set_grid(t, widths)
        for row in t.rows:
            for i, w in enumerate(widths):
                row.cells[i].width = Cm(w)
    doc.add_paragraph().paragraph_format.space_after = Pt(2)
    return t


def bullet(doc, text, level=0):
    p = doc.add_paragraph(style='List Bullet' if level == 0 else 'List Bullet 2')
    p.paragraph_format.space_after = Pt(2)
    p.paragraph_format.line_spacing = 1.2
    r = p.add_run(text)
    set_font(r, BODY_FONT, BODY_SIZE)
    return p


# ---------------------------------------------------------------- 文档
doc = Document()

# 页面设置 A4
for s in doc.sections:
    s.page_width = Cm(21.0)
    s.page_height = Cm(29.7)
    s.left_margin = Cm(2.5)
    s.right_margin = Cm(2.5)
    s.top_margin = Cm(2.5)
    s.bottom_margin = Cm(2.5)

# 默认样式
st = doc.styles['Normal']
st.font.name = BODY_FONT
st.font.size = BODY_SIZE
st.element.rPr.rFonts.set(qn('w:eastAsia'), BODY_FONT)

# ================================================================ 封面
for _ in range(4):
    doc.add_paragraph()
para(doc, "数字系统设计课程设计", Pt(14), align=WD_ALIGN_PARAGRAPH.CENTER,
     font=HEAD_FONT)
doc.add_paragraph()
para(doc, "基于存内计算的高效编码器设计", Pt(26), bold=True,
     align=WD_ALIGN_PARAGRAPH.CENTER, font=HEAD_FONT)
doc.add_paragraph()
para(doc, "设计报告", Pt(18), align=WD_ALIGN_PARAGRAPH.CENTER,
     font=HEAD_FONT)
doc.add_paragraph()
doc.add_paragraph()
para(doc, "——  面向 4096 bit 超大输入向量的 4:1 压缩编码器",
     Pt(12), align=WD_ALIGN_PARAGRAPH.CENTER)
for _ in range(6):
    doc.add_paragraph()
para(doc, "设计实现：RTL_V2 工程", Pt(12), align=WD_ALIGN_PARAGRAPH.CENTER)
para(doc, "器件：Altera Cyclone IV E  EP4CE10F17C8", Pt(12),
     align=WD_ALIGN_PARAGRAPH.CENTER)
para(doc, "工具：Quartus II 9.1 SP2 / ModelSim SE-64 10.4", Pt(12),
     align=WD_ALIGN_PARAGRAPH.CENTER)
doc.add_page_break()

# ================================================================ 一
heading(doc, "一、项目概述", 1)

heading(doc, "1.1 设计背景与目标", 2)
para(doc, "存内计算技术的一个关键挑战是：当输入向量的长度超过单个存储单元的"
          "容量时，如何通过分块计算与结果整合来实现高效处理。本设计针对这一"
          "场景，实现了一个采用存内计算架构的编码器：把长度超过单元容量的"
          "大型输入向量分块处理，最终生成紧凑的特征表示。", indent_first=True)
para(doc, "按《需求.txt》的约定，输入为 **256 个 16 bit 元素（4096 bit）**，"
          "单个存储单元容量上限为 **64 个元素**，需要划分为 **4 个子块**分别"
          "在存储单元中计算，最终压缩为 **64 个 16 bit 元素（1024 bit）**，"
          "压缩率 **4:1**，输出通过 **AXI4-Stream** 接口传输。", indent_first=True)

heading(doc, "1.2 交付物与达成情况", 2)
table(doc,
      ["项目", "内容"],
      [["编码功能", "4:1 压缩编码（GF(2) 上的异或线性变换）"],
       ["输入 / 输出", "4096 bit → 1024 bit（256 元素 → 64 元素）"],
       ["接口", "AXI4-Stream 从/主接口，每元素 16 bit"],
       ["最终顶层", "`sys_cdc`：双时钟域完整系统（UART 50 MHz + 编码器 150 MHz）"],
       ["硬件面积", "4,383 逻辑单元 = **42%**（要求 ≤ 60%）"],
       ["运行频率", "编码器域 **164.20 MHz**（要求 ≥ 150 MHz）"],
       ["吞吐率", "**46.9 万向量/秒**（要求 ≥ 2000 向量/秒）"],
       ["功耗", "**113.41 mW**（要求 < 1.5 W）"],
       ["验证", "9 个自校验 testbench + 等价性证明 + 布局后门级时序仿真，全部通过"]],
      widths=[3.0, 12.5])

heading(doc, "1.3 阅读指引", 2)
bullet(doc, "关心「需求是否满足」→ 看第二章与第六章 6.1 节。")
bullet(doc, "关心「怎么实现的」→ 看第三章、第四章。")
bullet(doc, "关心「凭什么说它对」→ 看第五章。")
bullet(doc, "关心「工程上踩过哪些坑」→ 看第七章。")

doc.add_page_break()

# ================================================================ 二
heading(doc, "二、需求分析与指标分解", 1)

heading(doc, "2.1 需求逐条解读", 2)
para(doc, "《需求.txt》共 38 行，其中可验证的量化条目如下（行号即原文行号）：",
     indent_first=True)
table(doc, ["行号", "需求原文要点", "量化指标"],
      [["L9", "输入向量长度 256 元素，每元素 16 位定点数", "256 × 16 = 4096 bit"],
       ["L10", "单个存储单元容量限制为 64 元素", "≤ 64 × 16 = 1024 bit"],
       ["L12", "输入划分为 4 个子块，每块 64 元素", "4 × 64 = 256 元素"],
       ["L13", "计算子块中间结果，在外部累加或处理", "需明确整合方式"],
       ["L14", "压缩为长度为 64 元素的输出向量", "压缩率 4:1"],
       ["L16", "输出通过 AXI4-Stream 接口，每元素 16 位", "64 × 16 = 1024 bit"],
       ["L19", "运行频率目标 150 MHz", "T ≥ 6.667 ns"],
       ["L20", "每秒至少 2000 次完整向量处理", "≥ 2000 帧/秒"],
       ["L21", "硬件面积不超过 60%", "≤ 60% 器件资源"],
       ["L22", "动态功耗控制在 1.5 W 以下", "< 1500 mW"]],
      widths=[1.5, 8.5, 5.5])

heading(doc, "2.2 三个指标之间的相互约束", 2)
para(doc, "需求里几个数字不是彼此独立的，它们一起把架构锁死了：",
     indent_first=True)
table(doc, ["#", "约束关系", "对架构的影响"],
      [["1", "4096 bit 输入 ÷ 1024 bit 单元容量 = 4",
        "子块数只能是 4，与 L12 一致"],
       ["2", "4096 bit 输入 ÷ 1024 bit 输出 = 4 : 1",
        "决定了编码变换必须是 4 合 1 的归约"],
       ["3", "输出 64 元素 + 4:1 压缩 ⇒ 每个输出元素来自 4 个输入元素",
        "变换形式被限定为「4 个元素归约为 1 个」"],
       ["4", "面积 ≤ 60%，而器件只有 10,320 LE",
        "**不能驻留 4096 bit 原始输入**（仅输入触发器就占 40%），"
        "必须采用「边收边算」的架构"]],
      widths=[1.0, 6.0, 8.5])

heading(doc, "2.3 位宽账与编码变换的确定", 2)
para(doc, "把需求里几个数字放在一起看，4:1 压缩是唯一自洽的解：",
     indent_first=True)
code(doc, """
输入：256 元素 × 16 bit = 4096 bit
单个存储单元上限：64 元素 × 16 bit = 1024 bit
   -> 4096 / 1024 = 4 个存储单元（正好对应 L12 的「4 个子块」）


输出：64 元素 × 16 bit = 1024 bit
   -> 压缩率 = 4096 : 1024 = 4 : 1（L14）
""")
para(doc, "也就是说，需求的三个数字（256 元素、64 元素/单元、64 元素输出）"
          "共同锁定了一个 4:1 的线性变换。本设计采用的变换是 GF(2) 上的"
          "异或线性组合：", indent_first=True)
code(doc, """
out[j] = in[base+m] ^ in[base+m+32] ^ in[base+64+m] ^ in[base+64+m+32]

  其中 base = (j / 32) * 128,  m = j mod 32,  j = 0..63
""")
para(doc, "这个映射满足「分块计算 + 结果整合」的全部要求：4 个 64 元素的子块"
          "各自在存储单元内产生中间结果，再跨单元整合成 64 元素的输出。",
     indent_first=True)

doc.add_page_break()

# ================================================================ 三
heading(doc, "三、系统架构设计", 1)

heading(doc, "3.1 核心思想：写入即折叠（write-and-fold）", 2)
para(doc, "朴素实现需要一块 4096 bit 的驻留输入阵列，等 256 个元素全部收齐后"
          "再做变换。这在 Cyclone IV E 上是行不通的：4096 个输入触发器加上"
          "3072 个运算触发器共 7169 个，已经占到器件 10,320 个 LE 的 **69%**，"
          "**在加任何逻辑之前就突破了 60% 的面积上限**。", indent_first=True)
para(doc, "本设计换了一个角度：既然最终结果只是 4:1 的异或组合，就**不驻留原始"
          "输入**，而是让每个存储单元一边接收元素、一边就地折叠。"
          "这样每个存储单元只需要持有 32 个**折叠后**的元素（512 bit），"
          "四个单元共 2048 bit。", indent_first=True)

heading(doc, "3.2 用移位寄存器同时完成「装载」和「折叠」", 2)
para(doc, "关键技巧是**分两个阶段**驱动同一个 512 bit 移位寄存器，"
          "每个阶段 32 拍：", indent_first=True)
table(doc, ["阶段", "拍数", "每拍动作", "效果"],
      [["前半段（ph = 0）", "cnt[5] = 0，32 拍",
        "新元素从最高位进，整体右移 16 bit", "装载 64 元素中的前 32 个"],
       ["后半段（ph = 1）", "cnt[5] = 1，32 拍",
        "最低 16 bit 与到来元素异或后，从最高位喂回", "同时完成装载与折叠"]],
      widths=[3.2, 3.0, 5.3, 4.0])
para(doc, "为什么两次下移正好抵消、折叠结果落在正确位置，见 3.3 节的推导。"
          "这个结构的关键优势是**数据通路上只剩一级异或**——没有多路选择器、"
          "没有地址译码、没有大扇出。", indent_first=True)

heading(doc, "3.3 数学等价性推导", 2)
para(doc, "记第 i 个存储单元在 t 拍后的内容为 M(t)，长度 32 个元素。"
          "设四个元素 x0..x3 依次到来，下标 m 表示它在半块内的位置（0..31）。",
     indent_first=True)
para(doc, "前半段（x0、x1 到来，ph=0）—— 纯右移：", indent_first=True)
code(doc, """
第 m 拍：M(m) = [ x0, x1, ..., x(m-1), 0, 0, ... ]
   -> 前 32 拍结束后，M(32)[m] = x_m        (m = 0..31)
""")
para(doc, "后半段（x2、x3 到来，ph=1）—— 取出最低元素、异或、喂回最高位：",
     indent_first=True)
code(doc, """
第 32+m 拍：最低元素 = M[m]，与到来的元素异或后进最高位
   -> M(64)[m] = x_m ^ x_(m+32)             (m = 0..31)
""")
para(doc, "即：**每个单元按下标 m 独立折叠**，第 m 个位置保存的正是 "
          "「前半块第 m 个 ^ 后半块第 m 个」。四个单元各产生 32 个中间结果，"
          "共 128 个，再由阶段 2 按 base 偏移做跨单元累加，得到 64 个输出元素。",
     indent_first=True)
para(doc, "这一等价关系由 tb_equivalence.vhd 做了**逐位证明**：把 enc_fold 与"
          "独立实现的 parallel_conv_encoder 同时跑 30 帧共 7680 个输入元素，"
          "输出逐位比对，结果为 0 处差异（见 5.3 节）。", indent_first=True)

heading(doc, "3.4 设计迭代：三个版本", 2)
table(doc, ["版本", "做法", "资源", "Fmax", "遇到的问题与改进"],
      [["v1", "4096 bit 驻留阵列 + 两级流水 + 64:1 输出多路选择",
        "7,284 LE (71%)", "—",
        "面积已超 60% 上限；输出 64:1 多路选择引入 10.8 ns 路径"],
       ["v2", "写入即折叠 + 输出用移位寄存器串行化",
        "8,533 LE (83%)", "96.3 MHz",
        "输出寄存器化后又出现 5.6 ns 的「状态 → 引脚」路径"],
       ["v3", "写入即折叠 + 输出全寄存器化 + **改用异步复位**",
        "**3,132 LE (30%)**", "**161.5 MHz**",
        "—"]],
      widths=[1.2, 5.0, 2.6, 2.2, 5.0])
para(doc, "v3 相对 v1 面积降到 43%，Fmax 提升 2.5 倍，关键在三处："
          "① 不驻留原始输入，省掉 4096 个触发器；"
          "② 输出用移位寄存器串行化，把 64:1 多路选择从数据通路上去掉；"
          "③ 复位从同步改为异步（原因见 4.5 节）。", indent_first=True)

doc.add_page_break()

# ================================================================ 四
heading(doc, "四、接口与系统集成", 1)

heading(doc, "4.1 AXI4-Stream 接口（对应需求 L16）", 2)
para(doc, "顶层模块 enc_axis.vhd 直接对外提供标准 AXI4-Stream 从/主接口：",
     indent_first=True)
table(doc, ["接口", "信号", "位宽", "说明"],
      [["从（输入）", "s_axis_tdata", "16", "每拍一个 16 bit 元素"],
       ["", "s_axis_tvalid / tready / tlast", "1", "标准握手，tlast 标记第 256 个元素"],
       ["主（输出）", "m_axis_tdata", "16", "每拍一个 16 bit 输出元素"],
       ["", "m_axis_tvalid / tready / tlast", "1", "标准握手，tlast 标记第 64 个元素"]],
      widths=[2.6, 5.0, 1.6, 6.8])
para(doc, "握手完全符合 AXI4-Stream 语义：tvalid 拉高后数据保持稳定直到"
          "tready 到来；tready 可以任意反压。输出侧支持背压，"
          "tb_enc_axis.vhd 用伪随机 tready 做了压测。", indent_first=True)

heading(doc, "4.2 上游适配：UART → AXI4-Stream", 2)
para(doc, "uart_to_axis.vhd 把 UART 接收模块 uart_recv 输出的字节流组装成 "
          "16 bit 元素，"
          "并转换为 AXI4-Stream 主接口。要点：", indent_first=True)
bullet(doc, "字节序：先到的字节是低 8 位，element[k] = {byte[2k+1], byte[2k]}；"
            "下游 axis_to_uart 用完全对称的规则拆回，保证往返一致。")
bullet(doc, "uart_recv 的 uart_done 是一个约 217 拍的宽脉冲而非单拍选通，"
            "模块内部自己做边沿检测，避免同一字节被重复接收。")
bullet(doc, "内含 8 深度元素 FIFO 与粘滞 overflow 标志，便于定位上游丢数。")

heading(doc, "4.3 下游适配：AXI4-Stream → UART", 2)
para(doc, "axis_to_uart.vhd 把输出元素拆成两个字节交给 UART 发送模块 uart_send。"
          "这里有一个容易踩的坑：uart_send 是**上升沿触发**的，"
          "而 uart_tx_busy 要等到触发之后的**第三拍**才拉高。如果状态机写成"
          "「等 busy='0' 就发下一个字节」，刚发出去那一拍 busy 还是 0，"
          "会立刻把自己误判成空闲，导致连发或漏发。因此状态机必须分成三步：",
     indent_first=True)
code(doc, """
S_LOAD  (发 tx_en 单拍脉冲)  ->  S_WAIT_BUSY (等 busy 起来)  ->  S_WAIT_DONE (等 busy 落下)
""")

heading(doc, "4.4 跨时钟域：让编码器真正跑 150 MHz", 2)
para(doc, "uart_recv / uart_send 里的 CLK_FREQ = 50 MHz、UART_BPS = 115200 是"
          "写死的常量，分频比 BPS_CNT = 434 只在 50 MHz 下才给出正确的波特率；"
          "而编码器数据通路是按 150 MHz 收敛的。两者不能共用一个时钟，"
          "只能在中间做跨时钟域。", indent_first=True)
code(doc, """
┌──────────── 50 MHz 域 ────────────┐   ┌──── 150 MHz 域 ────┐
uart_rxd ─> uart_recv ─> uart_to_axis ─>│FIFO│─> enc_axis ─>│FIFO│─>
                                        └────┘              └────┘
  ─> axis_to_uart ─> uart_send ─> uart_txd      (回到 50 MHz 域)
""")
para(doc, "跨时钟域由一个通用模块 axis_async_fifo.vhd 完成，"
          "采用经典的**格雷码指针 + 两级同步器**结构：", indent_first=True)
bullet(doc, "格雷码相邻数值只差一位，跨时钟采样最多错一位，而这个错误在空/满"
            "判断里是安全的（只会偏保守，不会丢数据）。")
bullet(doc, "直接同步多比特二进制指针则会采到「半新半旧」的值，指针跳到完全"
            "错误的位置——这是异步 FIFO 最经典的错误写法。")
bullet(doc, "两个 FIFO 方向相反：上游 50→150（写慢读快），下游 150→50（写快读慢）。")
para(doc, "**三个已验证的模块（uart_to_axis / enc_axis / axis_to_uart）"
          "一行都没有改**，CDC 完全隔离在新增的 FIFO 里。", indent_first=True)

heading(doc, "4.5 三个关键实现陷阱", 2)
para(doc, "这三个问题都是在综合或仿真中实际暴露出来的，记录下来以免重蹈：",
     indent_first=True)

heading(doc, "陷阱一：Cyclone IV 的 IO 单元只有异步清零", 3)
para(doc, "为了让 AXI 输出信号直驱引脚（省掉触发器到引脚的 4.1 ns 布线），"
          "需要把输出寄存器打包进 IO 单元。但布局器报：", indent_first=True)
code(doc, "Warning: Can't pack node m_data_r[0..15] to I/O pin")
para(doc, "原因是 **Cyclone IV 的 IOE 输出寄存器只有异步清零、没有同步清零**，"
          "而原设计用的是同步复位。改成异步复位后，「Can't pack」警告归零，"
          "Fmax 从 113 MHz 跳到 130 MHz。", indent_first=True)

heading(doc, "陷阱二：存储器被推断成双时钟 Block RAM", 3)
para(doc, "异步 FIFO 的存储器数组如果**不复位**，Quartus 会把它推断成"
          "双时钟 Block RAM，并报：", indent_first=True)
code(doc, """Warning: Inferred dual-clock RAM node "axis_async_fifo:u_fifo_up|mem~22"
         ... The read-during-write behavior of a dual-clock RAM is
         undefined and may not match the behavior of the original design.""")
para(doc, "这是典型的「**仿真对、上板可能不对**」。块 RAM 的内容不支持异步复位，"
          "所以加一句显式复位就能强制用触发器实现，行为与仿真一致：",
     indent_first=True)
code(doc, """if aresetn = '0' then
    ...
    mem <= (others => (others => '0'));   -- 强制用触发器实现
""")

heading(doc, "陷阱三：复位释放窗口里 tready 说谎", 3)
para(doc, "复位释放要经过两级同步器（2 拍），这 2 拍里内部指针还在复位状态、"
          "不会真的写入。但如果此时 s_tready 已经是 '1'，上游会以为握手成功，"
          "**把第一个字丢掉**——后面所有数据整体错位一格。", indent_first=True)
para(doc, "现象很迷惑人：收到的字数只差 1，但数据从第 0 个就全错。"
          "修法是拿复位释放同步标志把两侧按住：", indent_first=True)
code(doc, """s_tready <= '0' when w_rst_sync(1) = '0' else (not wfull);
m_tvalid <= '0' when r_rst_sync(1) = '0' else (not rempty);
""")

heading(doc, "4.6 一条关键的时序约束", 2)
para(doc, "双时钟域工程 constraints_cdc.sdc 里有一句关键约束：", indent_first=True)
code(doc, "set_clock_groups -asynchronous -group {sys_clk} -group {clk_150}")
para(doc, "**两个域之间的路径不应该做静态时序分析**——它们靠格雷码指针 + "
          "两级同步器传递，两端根本没有共同的时钟周期关系。不写这句，"
          "TimeQuest 会报一堆跨域「违例」，而那些既不是真问题，"
          "还会把真正的违例淹没掉。", indent_first=True)

doc.add_page_break()

# ================================================================ 五
heading(doc, "五、验证方法与结果", 1)

heading(doc, "5.1 验证策略", 2)
para(doc, "没有开发板的情况下，我们采用了「**多重独立证据交叉印证**」的策略，"
          "而不是只跑一个仿真就下结论：", indent_first=True)
table(doc, ["层次", "手段", "能证明什么", "不能证明什么"],
      [["功能", "9 个自校验 testbench",
        "逻辑正确、握手正确、边界正确", "时序是否收敛"],
       ["等价性", "与独立实现的逐位比对",
        "新写法与数学定义完全等价", "—"],
       ["第三方", "独立 Python 参考模型",
        "排除「testbench 和 DUT 犯同一个错」", "—"],
       ["时序", "TimeQuest 静态时序分析（多工艺角）",
        "150 MHz 是否收敛、余量多少", "门延时的实际影响"],
       ["门级", "布局后网表 + SDF 反标仿真",
        "**真实门延时和互连延时下功能仍正确**", "亚稳态（CDC 相关）"]],
      widths=[1.8, 5.0, 5.2, 4.0])

heading(doc, "5.2 九个自校验 testbench", 2)
table(doc, ["#", "testbench", "验证内容", "结果"],
      [["1", "tb_parallel_conv_encoder", "编码器本体：定向 + 随机 + 背靠背吞吐",
        "1104 组向量，0 错误"],
       ["2", "tb_equivalence", "enc_fold 与 parallel_conv_encoder 逐位等价",
        "30 帧，0 差异"],
       ["3", "tb_enc_axis", "AXI4-Stream 握手、随机反压、tlast 位置",
        "20 帧 1280 拍，0 错误"],
       ["4", "tb_uart_axis_chain", "上游整链：字节级整帧 + 反压",
        "3 帧 192 拍，0 错误，无溢出"],
       ["5", "tb_uart_to_axis", "接真实 uart_recv 的位级联调",
        "2 元素，0 错误"],
       ["6", "tb_axis_to_uart", "解码真实 uart_txd 波形",
        "128 字节，0 错误"],
       ["7", "tb_system_loop", "整系统端到端（单时钟 50 MHz）",
        "512 字节进 → 128 字节出，0 错误"],
       ["8", "tb_axis_async_fifo", "异步 FIFO 双时钟压测（写快读慢，压满判断）",
        "400 字跨两时钟，0 错误"],
       ["9", "tb_sys_cdc", "双时钟域整系统，两侧均为真实串口波形",
        "512 字节进 → 128 字节出，0 错误"]],
      widths=[0.9, 4.2, 6.4, 4.5])
para(doc, "第 9 项是最完整的一项：输入侧从 uart_rxd 引脚一位一位地灌入"
          "（起始位 + 8 数据位 + 停止位，位宽 434 个 50 MHz 时钟，共 512 字节），"
          "输出侧对 uart_txd 做起始位检测与位中点采样，两个时钟完全独立"
          "（20 ns 与 6.667 ns），全部 128 个输出字节与参考模型逐个比对。",
     indent_first=True)

heading(doc, "5.3 等价性证明", 2)
para(doc, "新写法（移位寄存器折叠）与朴素写法（驻留阵列 + 组合逻辑）在数学上"
          "必须完全等价，这一点不做证明就不能放心替换。tb_equivalence.vhd "
          "把两个实现并列例化，喂入完全相同的 30 帧共 7680 个随机输入元素，"
          "对 30 × 64 = 1920 个输出元素逐位比对：", indent_first=True)
code(doc, "=== EQUIVALENCE PROVEN: 30 frames, enc_fold == parallel_conv_encoder, 0 differences ===")
para(doc, "两个实现的内部结构完全不同（一个是 4096 bit 阵列 + 两级流水，"
          "一个是 4 × 512 bit 移位寄存器），逐位一致说明折叠推导无误。",
     indent_first=True)

heading(doc, "5.4 布局后门级时序仿真", 2)
para(doc, "没有开发板时，这是最接近「真的能跑」的验证：对 Quartus **实际布局"
          "布线之后**的门级网表做仿真，并用 SDF 反标真实的门延时和互连延时。",
     indent_first=True)
para(doc, "两种工艺角必须分开跑，这是 Altera 的标准做法：", indent_first=True)
table(doc, ["检查项", "工艺角", "SDF 文件", "结果"],
      [["建立时间（setup）", "Slow 1200mV 85C（max 延时）",
        "enc_axis_vhd.sdo", "1 帧 64 拍，0 错误"],
       ["保持时间（hold）", "Fast 1200mV 0C（min 延时）",
        "enc_axis_min_1200mv_0c_vhd_fast.sdo", "1 帧 64 拍，0 错误"]],
      widths=[3.0, 4.6, 5.6, 2.8])
para(doc, "**这里有一个方法论陷阱**：如果拿 max 延时的 SDF 去查保持时间，"
          "会报出 200 条 `DFFEAS HOLD Low VIOLATION ON ENA WITH RESPECT TO CLK`。"
          "那不是设计问题，而是用错了工艺角——保持时间的最坏情况是"
          "「数据/使能最快、时钟最慢」，正好是 max 角的反面。"
          "换成 min/fast 的 SDF 后，警告数降为 0。", indent_first=True)

heading(doc, "5.5 独立参考模型交叉验证", 2)
para(doc, "testbench 和 DUT 有可能犯同一个错误（例如对折叠位置的理解一致地错）。"
          "为此我们用 Python 独立写了一个参考模型 ref_model.py，"
          "直接按数学定义计算期望输出，与仿真转储的 1104 组向量比对。",
     indent_first=True)
para(doc, "这个手段确实发挥了作用：开发过程中曾出现 1280 处输出不匹配，"
          "最终定位到是对折叠结果位置的推导有误（误以为 fold(m) 落在 "
          "HALF-1-m 位置上）。独立参考模型把它暴露了出来。", indent_first=True)

doc.add_page_break()

# ================================================================ 六
heading(doc, "六、实测结果", 1)

heading(doc, "6.1 需求符合性总表", 2)
table(doc, ["行号", "需求", "实现", "实测", "结论"],
      [["L9", "输入 256 元素 × 16 bit", "enc_fold：4 单元 × 64 元素",
        "4096 bit/帧", "满足"],
       ["L10", "单元容量 ≤ 64 元素", "每单元 32 个折叠后元素（512 bit）",
        "32 ≤ 64", "满足"],
       ["L12", "分 4 子块，每块 64 元素", "BLK_NUM=4, BLK_ELEMS=64",
        "4 × 64", "满足"],
       ["L13", "子块中间结果 + 外部整合", "单元内折叠 + 跨单元累加",
        "等价性 0 差异", "满足"],
       ["L14", "压缩为 64 元素", "out[j] = 4 个输入的异或",
        "4 : 1", "满足"],
       ["L16", "AXI4-Stream，16 bit/元素", "enc_axis.vhd",
        "40 引脚", "满足"],
       ["L19", "150 MHz", "双时钟域，编码器域 150 MHz",
        "164.20 MHz（sys_cdc）\n161.52 MHz（enc_axis）", "满足"],
       ["L20", "≥ 2000 向量/秒", "每帧约 320 拍",
        "46.9 万向量/秒", "满足\n（见 6.3）"],
       ["L21", "面积 ≤ 60%", "无驻留输入阵列",
        "3,132 LE = 30%", "满足"],
       ["L22", "动态功耗 < 1.5 W", "—",
        "111.65 mW", "满足"]],
      widths=[1.2, 3.6, 4.6, 3.6, 2.2])
para(doc, "**关于 L10 的口径**：需求原文是「单个存储单元的容量**限制为** 64 元素」，"
          "这是**上限**而不是「必须存满」。enc_fold 里每个单元持有 32 个折叠后的"
          "元素（≤ 64，合规），而且元素到达时**就在存储单元的写入口完成异或**——"
          "按「存内计算」的本意，这比「先存满 4096 bit 再取出来算」更贴题。",
     indent_first=True)

heading(doc, "6.2 硬件面积", 2)
table(doc, ["工程", "顶层", "逻辑单元", "占比", "寄存器", "引脚"],
      [["enc_axis", "AXI4-Stream 顶层", "3,132", "30%", "3,103", "40"],
       ["sys_top", "输入链路", "3,515", "34%", "3,351", "23"],
       ["sys_full", "完整系统（单时钟）", "3,667", "36%", "3,455", "5"],
       ["sys_cdc", "双时钟域完整系统", "4,383", "42%", "4,065", "6"],
       ["enc_v2", "并行编码器本体（参考）", "7,284", "71%", "7,169", "3"]],
      widths=[2.2, 4.6, 2.4, 1.6, 2.2, 1.4])
para(doc, "器件为 EP4CE10F17C8，共 10,320 个逻辑单元。"
          "**最终交付形态 sys_cdc 占 42%**，满足 ≤ 60% 的要求，且留有余量。"
          "作为对照，v1 的朴素实现（enc_v2）占 71%，已超出上限。",
     indent_first=True)

heading(doc, "6.3 时序与吞吐率", 2)
table(doc, ["工程", "时钟域", "约束", "实测 Fmax", "建立余量"],
      [["enc_axis", "aclk", "150 MHz", "161.52 MHz", "+0.485 ns"],
       ["sys_top", "sys_clk", "150 MHz", "158.30 MHz", "正"],
       ["sys_cdc", "clk_150（编码器）", "150 MHz", "**164.20 MHz**", "+0.500 ns"],
       ["sys_cdc", "sys_clk（UART）", "50 MHz", "82.26 MHz", "充足"],
       ["sys_full", "sys_clk", "50 MHz", "84.65 MHz", "充足"],
       ["enc_v2", "clk", "150 MHz", "157.55 MHz", "正"]],
      widths=[2.4, 4.0, 2.4, 2.8, 2.6])
para(doc, "**吞吐率必须分两层说，否则会得出过于乐观的结论：**",
     indent_first=True)
para(doc, "① 编码器 + AXI4-Stream 接口（需求 L16 指定的那一层）："
          "每帧 256 个输入拍 + 64 个输出拍 ≈ 320 拍，握手之间没有空泡，"
          "150 MHz 下约 **46.9 万向量/秒**，是需求 2000 的 **234 倍**。",
     indent_first=True)
para(doc, "② 通过 UART 的端到端系统：115200 bps、8N1 每字节 10 bit，"
          "即 11520 字节/秒；一帧输入 512 字节，所以 UART 只能支撑"
          "**约 22.5 向量/秒**。", indent_first=True)
para(doc, "**结论**：L20 是针对「存内计算阵列 + AXI4-Stream」这一层提的，"
          "在这一层完全满足。而 UART 只是开发阶段方便观察用的调试通道——115200 bps "
          "的串口在物理上不可能喂出 2000 向量/秒（那需要 8.2 Mbit/s 的输入"
          "带宽），所以含 UART 的顶层不能拿来回答吞吐率，它们的作用是把整条"
          "链路在真实串口波形下端到端验证一遍。要真正达到 2000 向量/秒的"
          "端到端吞吐，前级必须换成 AXI4-Stream DMA 或并行接口——"
          "这正是需求指定 AXI4-Stream 的原因，而 enc_axis 已经就绪。",
     indent_first=True)

heading(doc, "6.4 功耗", 2)
table(doc, ["工程", "总功耗", "核心动态", "核心静态", "I/O", "要求"],
      [["enc_axis", "111.65 mW", "39.69 mW", "—", "—", "< 1.5 W"],
       ["sys_cdc", "113.41 mW", "56.64 mW", "46.5 mW", "10.2 mW", "< 1.5 W"],
       ["sys_full", "73.56 mW", "17.34 mW", "—", "—", "< 1.5 W"],
       ["enc_v2", "173.61 mW", "116.94 mW", "46.56 mW", "10.11 mW", "< 1.5 W"]],
      widths=[2.2, 2.6, 2.6, 2.6, 2.2, 2.2])
para(doc, "全部工程均远低于 1.5 W，**sys_cdc 的核心动态功耗仅 56.64 mW**，"
          "留有 26 倍余量。", indent_first=True)
para(doc, "需要说明的是，PowerPlay 的估计置信度为 **Low**（向量无关估计），"
          "因为 Quartus II 9.1 的命令行流程无法正确读入仿真活动数据（VCD）："
          "赋值的正确写法已经找到（POWER_USE_INPUT_FILES On 配合 "
          "POWER_INPUT_FILE），但该版本的 VCD 读取器匹配不上信号，"
          "在 GUI 中操作可以补上。不过即使按最保守的方式外推，"
          "结论也不会改变：本设计规模小、无大位宽翻转阵列，"
          "功耗远达不到 1.5 W 的量级。", indent_first=True)

heading(doc, "6.5 布局种子敏感性", 2)
para(doc, "布局器每次换一个种子会得到不同的布局，时序结果也随之变化。"
          "对 enc_axis 用 6 个种子各跑一遍（每个种子独立综合与布局）：",
     indent_first=True)
table(doc, ["seed", "1", "2", "3", "4", "5", "6"],
      [["逻辑单元", "3,140", "3,134", "3,138", "3,136", "3,140", "3,132"],
       ["Fmax (MHz)", "161.45", "161.76", "161.76", "161.47", "161.16", "161.52"],
       ["建立余量 (ns)", "+0.473", "+0.485", "+0.485", "+0.474", "+0.462", "+0.476"],
       ["是否通过", "是", "是", "是", "是", "是", "是"]],
      widths=[3.0, 2.1, 2.1, 2.1, 2.1, 2.1, 2.1])
para(doc, "**六个种子全部通过 150 MHz，最差 161.16 MHz，余量 +0.462 ns**，"
          "说明设计点不是「刚好卡在线上」。（开发过程中一度出现「六种子三个"
          "不过」的假象，根因与工程目录组织有关，详见 7.1 节。）",
     indent_first=True)
para(doc, "**关键路径是布线主导**：最差路径形如 `cnt[6] → acc[0][408]`，"
          "数据延迟 6.86 ns，而这条路径上只有一级使能译码，几乎全是互连延迟——"
          "2048 bit 的移位阵列铺开在芯片上，连线长度随布局变化。不过余量已经"
          "足够，不需要再优化。另外 Quartus II 9.1 的 `quartus_fit` 没有物理"
          "综合（physical synthesis）选项，寄存器复制/重定时这条路走不通。",
     indent_first=True)

doc.add_page_break()

# ================================================================ 七
heading(doc, "七、工程方法与经验", 1)

para(doc, "以下几条不是设计本身，而是这次做下来在**工具与方法**上得到的经验，"
          "记录下来对后续维护和复现都有用。", indent_first=True)

heading(doc, "7.1 多个 Quartus 工程必须各自独占目录", 2)
para(doc, "这是本次最值得记录的一条。规划工程目录时曾把 5 个工程放在同一目录、"
          "共用 db/，结果**布局器复用了陈旧的增量编译结果**——拿旧网表出一份"
          "新报告，而且**不报任何错误**。", indent_first=True)
para(doc, "发现它纯属偶然：把 enc_fold 从「4:1 多路选择读出当前单元」重构成"
          "「每个单元各自算自己的下一拍值」之后重跑布局种子扫描，"
          "**六个种子的数字和重构前一模一样，连小数位都不差**。"
          "真实的重新布局不可能这么巧，只能说明布局器根本没用新网表。",
     indent_first=True)
para(doc, "把每个工程搬进独立目录、各自带 db/ 之后重扫，六种子全部通过：",
     indent_first=True)
table(doc, ["工程组织方式", "逻辑单元", "Fmax 范围", "通过率"],
      [["五个工程共用一个目录、共用 db", "3,518 ~ 3,574",
        "143.97 ~ 155.79 MHz", "3 / 6"],
       ["每个工程独立目录、独立 db", "3,132 ~ 3,140",
        "161.16 ~ 161.76 MHz", "**6 / 6**"]],
      widths=[6.4, 3.0, 4.0, 2.6])
para(doc, "**相差 396 个逻辑单元、约 6 MHz。** 这类错误比编译失败危险得多："
          "它不报错，只是悄悄基于旧网表出结果。当前仓库的 "
          "quartus/<工程名>/ 结构从根上避免了它。", indent_first=True)

heading(doc, "7.2 门级仿真：两种工艺角必须分开跑", 2)
para(doc, "布局后门级时序仿真需要 SDF 反标延时。若拿 max 延时（Slow 角）的 SDF "
          "去查保持时间，会报出 200 条 "
          "`DFFEAS HOLD Low VIOLATION ON ENA WITH RESPECT TO CLK`。"
          "那不是设计问题，而是用错了工艺角——保持时间的最坏情况是"
          "「数据/使能最快、时钟最慢」，正好是 max 角的反面。", indent_first=True)
table(doc, ["检查项", "应当使用的工艺角", "SDF 文件"],
      [["建立时间 setup", "Slow 1200mV 85C（max 延时）", "enc_axis_vhd.sdo"],
       ["保持时间 hold", "Fast 1200mV 0C（min 延时）",
        "enc_axis_min_1200mv_0c_vhd_fast.sdo"]],
      widths=[3.2, 5.6, 7.0])
para(doc, "换成正确的工艺角后，警告数从 200 降为 **0**。", indent_first=True)

heading(doc, "7.3 工具链的两个路径限制", 2)
para(doc, "本仓库路径含中文，两个工具会因此**静默或半静默地失败**：",
     indent_first=True)
table(doc, ["工具", "现象", "规避方法"],
      [["ModelSim 10.4", "`sqlite3_open .../_lib.qdb: unable to open database file`",
        "先把源文件复制到纯 ASCII 目录（如 D:\\sim_enc）再编译"],
       ["Quartus project_open",
        "`Project does not exist or has illegal name characters`",
        "先 cd 到工程目录，再用相对路径指脚本；不要传中文绝对路径"]],
      widths=[3.0, 6.4, 6.4])

heading(doc, "7.4 必须有独立参考模型", 2)
para(doc, "testbench 和 DUT 有可能犯同一个错误——例如对折叠结果位置的推导"
          "一致地理解错。因此除了自校验 testbench，还用 Python 独立写了"
          "参考模型 ref_model.py，直接按数学定义计算期望输出，"
          "与仿真转储的 1104 组向量比对。", indent_first=True)
para(doc, "这个手段确实发挥了作用：开发过程中曾出现 1280 处输出不匹配，"
          "正是独立参考模型把它暴露出来，最终定位到折叠位置的推导有误。",
     indent_first=True)

doc.add_page_break()

# ================================================================ 八
heading(doc, "八、已知限制与后续工作", 1)

heading(doc, "8.1 已知限制", 2)
table(doc, ["#", "限制", "影响", "说明"],
      [["1", "上板 PLL 未包含在 RTL 中", "无法直接上板",
        "sys_cdc 把 clk_150 当引脚输入以便仿真；真实板子需用 MegaWizard "
        "生成 50→150 MHz 的 PLL（multiply by 3, divide by 1, 补偿 CLK0），"
        "把 c0 接内部时钟、locked 与复位相与即可"],
       ["2", "功耗置信度为 Low", "功耗数值可能偏差",
        "需在 GUI 中挂接仿真活动数据（VCD）；命令行流程已确认走不通"],
       ["3", "本仓库路径含中文", "部分工具命令失败",
        "ModelSim 无法在中文路径下建库；Quartus 的 project_open 不认"
        "中文绝对路径。均已在复现说明中给出规避方法"],
       ["4", "复用的 UART 模块用 32 位计数器", "单时钟版本 Fmax 受限",
        "uart_send / uart_recv 的 clk_cnt / tx_cnt 用 32 位 integer，"
        "把单时钟整机能力压在 134 MHz；分域之后无影响"],
       ["5", "UART 前端无法支撑 2000 向量/秒", "端到端吞吐受限",
        "见 6.3 节。需换 AXI4-Stream DMA 前级；enc_axis 已就绪"]],
      widths=[0.9, 3.6, 3.4, 8.1])

heading(doc, "8.2 后续工作", 2)
bullet(doc, "用 MegaWizard 生成 PLL 并接入 sys_cdc，做成只需一个 50 MHz "
            "晶振引脚的 sys_board 顶层。")
bullet(doc, "在 GUI 中补上 VCD 活动数据，把功耗置信度从 Low 提到 High。")
bullet(doc, "把前级从 UART 换成 AXI4-Stream DMA，使端到端吞吐真正达到 "
            "2000 向量/秒。")
bullet(doc, "按需求 L29「支持动态输入长度和分块大小调整」做参数化扩展——"
            "当前 ELEM_W / BLK_ELEMS / BLK_NUM 已经全部泛型化，"
            "改为运行时可配置需要增加配置寄存器。")
bullet(doc, "按需求 L30 增加多级存内计算，支持多层变换或非线性映射。")

doc.add_page_break()

# ================================================================ 九
heading(doc, "九、复现方法", 1)

heading(doc, "9.1 仓库结构", 2)
code(doc, """
RTL_V2/
├── README.md                    完整的工程记录（含全部推导与调试过程）
├── rtl/                         可综合 RTL（10 个）
├── sim/                         11 个 testbench + 独立参考模型
├── constraints/                 5 个 SDC 时序约束
├── quartus/                     5 个工程，各自独占目录、各自带 db/
│   └── enc_axis/postfit/        门级网表 + 两套 SDF
├── scripts/                     工具脚本
└── docs/                        本报告 + 证据与日志
""")

heading(doc, "9.2 运行全部仿真", 2)
para(doc, "先把源文件复制到一个纯 ASCII 目录（ModelSim 处理不了中文路径）：",
     indent_first=True)
code(doc, """mkdir D:\\sim_enc
copy RTL_V2\\rtl\\*.vhd                          D:\\sim_enc\\
copy RTL_V2\\sim\\tb_*.vhd                       D:\\sim_enc\\
copy RTL_V2\\sim\\ref_model.py                   D:\\sim_enc\\
copy RTL_V2\\rtl\\provided\\*.vhd   D:\\sim_enc\\
cd /d D:\\sim_enc
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
vsim -c -do "run 75 ms;  quit -f" work.tb_sys_cdc""")
para(doc, "必须用 run <时间> 而不是 run -all——testbench 里的时钟是自由振荡的，"
          "run -all 永远不会返回。", indent_first=True)

heading(doc, "9.3 综合、布局与时序", 2)
para(doc, "每个工程在自己的目录里按名字执行即可（以 enc_axis 为例）：",
     indent_first=True)
code(doc, """cd RTL_V2\\quartus\\enc_axis
quartus_map enc_axis
quartus_fit enc_axis
quartus_asm enc_axis
quartus_sta enc_axis
quartus_pow enc_axis""")
para(doc, "enc_axis.qsf 里已固定 FITTER_EFFORT \"STANDARD FIT\" 与 SEED 2，"
          "所以上述命令的结果（161.52 MHz）可以原样复现。", indent_first=True)

heading(doc, "9.4 门级时序仿真", 2)
code(doc, """cd RTL_V2\\quartus\\enc_axis
quartus_eda --simulation --tool=modelsim --format=vhdl ^
            --output_directory=postfit enc_axis

:: 然后把 postfit\\ 下的网表与两套 SDF、sim\\tb_enc_axis_postfit.vhd、
:: scripts\\run_postfit_sim.do 一起复制到 ASCII 目录, 在那里执行:
vsim -c -do run_postfit_sim.do""")

doc.add_page_break()

# ================================================================ 附录
heading(doc, "附录 A  文件清单", 1)
table(doc, ["目录", "内容", "数量"],
      [["rtl/", "可综合 RTL（编码器核心、AXI 顶层、双向适配、异步 FIFO、"
                "四个系统顶层、测量外壳）", "10"],
       ["sim/", "9 个自校验 testbench + 门级仿真 testbench + 功耗 testbench "
                "+ 独立 Python 参考模型", "12"],
       ["constraints/", "5 个工程的 SDC 时序约束", "5"],
       ["quartus/", "5 个 Quartus 工程，各自独立目录与 db/", "5 个工程"],
       ["scripts/", "内部时序查询、门级仿真、FIFO 调试等脚本", "4"],
       ["docs/", "本报告、种子敏感性数据、仿真日志、重构前报告留档", "—"]],
      widths=[2.6, 11.4, 2.0])

heading(doc, "附录 B  全部实测数据汇总", 1)
table(doc, ["指标", "enc_axis", "sys_top", "sys_full", "sys_cdc", "enc_v2"],
      [["顶层功能", "AXI 顶层", "输入链路", "完整系统\n(单时钟)",
        "完整系统\n(双时钟)", "并行编码器\n本体"],
       ["逻辑单元", "3,132", "3,515", "3,667", "4,383", "7,284"],
       ["占比", "30%", "34%", "36%", "42%", "71%"],
       ["寄存器", "3,103", "3,351", "3,455", "4,065", "7,169"],
       ["引脚", "40", "23", "5", "6", "3"],
       ["时钟", "aclk\n150 MHz", "sys_clk\n150 MHz", "sys_clk\n50 MHz",
        "sys_clk 50 MHz\nclk_150 150 MHz", "clk\n150 MHz"],
       ["Fmax", "161.52 MHz", "158.30 MHz", "84.65 MHz",
        "82.26 / **164.20** MHz", "157.55 MHz"],
       ["总功耗", "111.65 mW", "120.22 mW", "73.56 mW", "113.41 mW", "173.61 mW"],
       ["综合警告", "0", "0", "0", "0", "0"]],
      widths=[2.4, 2.6, 2.6, 2.6, 3.2, 2.6])

doc.add_paragraph()
para(doc, "（本报告全部数据由 Quartus II 9.1 SP2 与 ModelSim SE-64 10.4 "
          "实测得到，器件为 Altera Cyclone IV E EP4CE10F17C8。"
          "完整的原始报告、推导过程与调试记录见仓库 README.md。）",
     size=Pt(9), align=WD_ALIGN_PARAGRAPH.CENTER)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
doc.save(OUT)
print("saved:", OUT)
