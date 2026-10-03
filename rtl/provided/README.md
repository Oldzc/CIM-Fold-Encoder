# rtl/provided/ —— 给定的串口模块

这两个文件是课程提供的 UART 收发模块，本设计**原样使用、一行未改**，
放在这里是为了让 `RTL_V2/` 自成一体（不依赖仓库里的其它目录）。

| 文件 | 实体 | 说明 |
|---|---|---|
| `uart_recv.vhd` | `uart_recv` | 串口接收：8N1，`uart_done` 是约 217 拍的宽脉冲，`uart_data` 为 8 bit |
| `uart_send.vhd` | `uart_send` | 串口发送：上升沿触发，`uart_tx_busy` 在触发后**第三拍**才拉高 |

两者都把 `CLK_FREQ = 50 MHz`、`UART_BPS = 115200` 写成常量，
分频比 `BPS_CNT = 434` 只在 50 MHz 下才能给出正确的波特率 —— 这也是
`sys_cdc` 必须把 UART 单独放在 50 MHz 时钟域的原因。

**使用注意**（在本设计里都已处理）：

- `uart_send` 是**上升沿触发**且 busy 有延迟，状态机不能写成「等 busy='0'
  就发下一个字节」，否则会把自己误判成空闲而连发。见 `axis_to_uart.vhd`。
- 两个模块内部都用 32 位 `integer` 做分频计数器，会把**单时钟**版本的整机
  Fmax 压在 134 MHz 左右；分到 50 MHz 域之后没有影响。
