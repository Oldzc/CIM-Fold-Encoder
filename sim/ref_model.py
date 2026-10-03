#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
独立性交叉验证: 用 Python 重新实现「需求.txt」要求的 4096 -> 1024 压缩变换,
读取 ModelSim 仿真转储的 vectors.txt, 逐位比对 DUT 的实际输出。

参考模型(与 VHDL 的写法刻意不同):
    输入 256 个 16 bit 元素  in[0..255]      (共 4096 bit)
    输出  64 个 16 bit 元素  out[0..63]      (共 1024 bit)

    4 个存储单元, 单元 i 持有 in[i*64 .. i*64+63]
      阶段1  单元内折叠   mid_i[m] = in[i*64+m] ^ in[i*64+m+32]      m=0..31
      阶段2  跨单元累加   out[m]    = mid_0[m] ^ mid_1[m]            m=0..31
                          out[32+m] = mid_2[m] ^ mid_3[m]            m=0..31

用法:
    python ref_model.py vectors.txt
"""

import sys

ELEM_W = 16
BLK_ELEMS = 64
BLK_NUM = 4
IN_ELEMS = BLK_NUM * BLK_ELEMS      # 256
OUT_ELEMS = BLK_ELEMS               # 64
IN_W = IN_ELEMS * ELEM_W            # 4096
OUT_W = OUT_ELEMS * ELEM_W          # 1024


def bits_to_elems(s, n, w=ELEM_W):
    """MSB-first 的二进制串 -> 整数列表"""
    return [int(s[i * w:(i + 1) * w], 2) for i in range(n)]


def ref_model(bits):
    """输入 4096 位二进制串, 返回 1024 位二进制串"""
    assert len(bits) == IN_W, "输入长度应为 %d, 实际 %d" % (IN_W, len(bits))
    x = bits_to_elems(bits, IN_ELEMS)

    # 阶段1: 块内折叠
    mid = [[x[i * BLK_ELEMS + m] ^ x[i * BLK_ELEMS + m + BLK_ELEMS // 2]
            for m in range(BLK_ELEMS // 2)] for i in range(BLK_NUM)]

    # 阶段2: 外部跨单元累加
    out = []
    for pr in range(BLK_NUM // 2):
        for m in range(BLK_ELEMS // 2):
            out.append(mid[2 * pr][m] ^ mid[2 * pr + 1][m])
    assert len(out) == OUT_ELEMS

    return ''.join(format(v, '0%db' % ELEM_W) for v in out)


def flat_model(bits):
    """等价但写法完全不同的第三种实现: 平坦数组上的 4 选 1 抽取异或"""
    x = bits_to_elems(bits, IN_ELEMS)
    out = []
    for j in range(OUT_ELEMS):
        pr, m = divmod(j, BLK_ELEMS // 2)
        base = pr * 2 * BLK_ELEMS
        out.append(x[base + m] ^ x[base + m + 32] ^
                   x[base + 64 + m] ^ x[base + 96 + m])
    return ''.join(format(v, '0%db' % ELEM_W) for v in out)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'vectors.txt'
    with open(path, 'r') as f:
        raw = [ln.strip() for ln in f if ln.strip()]

    if len(raw) % 2 != 0:
        print("!! vectors.txt 行数不是偶数, 文件可能被截断")
        return 2

    n_vec = len(raw) // 2
    n_bad = 0
    first_bad = None

    for k in range(n_vec):
        tag_i, s_in = raw[2 * k].split(None, 1)
        tag_o, s_out = raw[2 * k + 1].split(None, 1)
        assert tag_i == 'IN' and tag_o == 'OUT', "格式错误 @%d" % k

        exp = ref_model(s_in)
        flat = flat_model(s_in)
        if exp != flat:
            print("!! 两个参考模型自身不一致 @%d (说明参考模型写错了)" % k)
            return 3
        if s_out != exp:
            n_bad += 1
            if first_bad is None:
                diff = [b for b in range(OUT_W) if s_out[b] != exp[b]]
                first_bad = (k, len(diff), diff[:8])
        # 顺带检查长度
        if len(s_in) != IN_W or len(s_out) != OUT_W:
            print("!! 位宽错误 @%d: in=%d out=%d" % (k, len(s_in), len(s_out)))
            return 4

    print("=" * 66)
    print("向量总数            : %d" % n_vec)
    print("输入位宽            : %d bit = %d 元素 x %d bit" % (IN_W, IN_ELEMS, ELEM_W))
    print("输出位宽            : %d bit = %d 元素 x %d bit" % (OUT_W, OUT_ELEMS, ELEM_W))
    print("压缩率              : %d : 1" % (IN_W // OUT_W))
    print("与 DUT 输出不一致的 : %d" % n_bad)
    if first_bad:
        print("首个不一致: 第 %d 个向量, %d 位不同, 位置 %s"
              % (first_bad[0], first_bad[1], first_bad[2]))
    print("=" * 66)
    print("RESULT: " + ("PASS" if n_bad == 0 else "FAIL"))
    return 0 if n_bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
