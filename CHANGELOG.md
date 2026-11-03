# Changelog

## v2.6.1 — 2026-11-04

定版前的代码审计（shellcheck 0 error / 0 warning + 人工逻辑审查 + 端到端回归）。

### 修复

- **`monitor` 的 Ctrl-C 会污染后续操作**：trap 里用 `return 0`，退出监控后 trap 仍留在进程里，回到菜单再按 Ctrl-C 会报 `can only return from a function`，且菜单不会退出。改用标志位 + `trap - INT`。
- **`1gbit` 配置的百分比全错**：`unit_num` 只取数字，"1gbit" 被算成 1 Mbps，`check` / `health` 的占用率会除以 1，显示成几千 %。现在识别 `g` 单位并乘 1000。
- **未配置时采样单元每分钟被判失败**：`sample_once` 无配置时返回 1，systemd 把 `cake-fairshare-log.service` 记成 failed。改为静默返回 0。
- **配置目录不存在时写入报错**：`cleanup_conflicts` 可能早于 `save_conf` 执行，往不存在的 `/etc/cake-fairshare/` 追加 `disabled-units` 会打印 "No such file or directory"。两处补 `mkdir -p`。
- 健康报告在样本不足 2 条时打印空白区间，改为友好提示。

### 定版验证

- `shellcheck -S warning`：0 error / 0 warning
- 连续 3 次 `apply`：cake qdisc 恒为 2 个、ifb 恒为 1 个（无泄漏）
- `systemctl restart`：退出码 0，队列完整重建
- 删除整个 `/etc/cake-fairshare` 后用一行命令重装：配置、队列、服务、采样全部恢复
- 子命令耗时：status 17ms / preflight 1.0s / check 1.0s / health 160ms / report 11ms / log 42ms

## v2.6.0 — 2026-11-04

### 新增

- **带宽健康报告**（菜单第 11 项 / `cake-fairshare health`）：把「每分钟用量采样」与「历史测速记录」拼成一份可以直接看懂的报告，最后一行给白话结论。
  - 逐小时汇总：样本数、连接峰值、下行峰值、上下行均值
  - 异常判定：某小时「连接数 ≥ 3 但峰值跑不过上限 20%」才标记 —— 避免"没人用"被误报成限速
  - 历史测速：低于历史峰值 30% 的记录标黄，并区分"下行偏低 / 上行偏低 / 都偏低"
  - 峰值高于整形上限时自动说明"该时段整形被临时关闭过"，避免看起来像数据错误
- 测速记录目录可用 `SPEEDTEST_DIR` 覆盖（默认 `/root/speedtest_history`）。

### 修复

- 健康报告里浮点数用 `[ -gt ]` 比较导致整个测速区块被静默跳过。

## v2.5.0 — 2026-11-04

### 新增

- **安装脚本默认自动配置**：`bash <(curl ...)/install.sh` 一条命令完成「安装 → 写配置 → 预检 → 启用 → 开机自启」，不再需要分两步。
- **`--clean`**：`install.sh --clean` 或 `cake-fairshare init --clean`，自动停用机器上会抢根队列的其它限速服务并清理残留设备，适合批量部署完全脚本化。
- `install.sh` 支持参数：`[带宽]`、`--clean`、`--no-init`。
- 已有配置的机器重复执行安装脚本时**不覆盖配置**，只做 apply，可直接当升级命令用。

## v2.4.0 — 2026-11-04

### 新增

- **`cake-fairshare init [带宽]`**：一键部署。自动用默认路由网卡、写入配置、跑环境预检、立即启用、设置开机自启，全程无交互。
- **默认参数面向境外代理节点**：`DEF_RATE="190mbit"`（对应 200M 峰值套餐的 95%）、`DEF_CAKE_OPTS_INGRESS="ack-filter"`、方向 `both`。改脚本头部两行即可变成你自己的标准。
- 交互菜单第 2 项：网卡默认值改为**默认路由那块**（原来是列表第一项，多网卡机器容易选错）；带宽默认值跟随 `DEF_RATE`；首次启用时询问是否开启 ack-filter。
- 服务安装逻辑抽成 `install_service()`，菜单与 `init` 共用。

### 说明

`init` 会把 `RATE_EGRESS` / `RATE_INGRESS` 留空（跟随 `RATE`），这样菜单第 7 项改带宽能直接生效，不会像之前那样被单独设置的值盖住。

## v2.3.0 — 2026-11-04

### 新增

- **`cake-fairshare preflight`**：只读环境预检。检测非 cake 根队列、挂着别的队列的残留 `ifb`、**会抢根队列的已启用服务**、`/etc/rc.local` 与 crontab 里的 tc 命令。
  关键点：unit 文件本身通常不含 tc 命令，真正的命令在 `ExecStart` 指向的脚本里，所以预检会顺着 ExecStart 解析目标文件再 grep——只看 unit 文件会漏掉全部冲突。
- **菜单第 2 项启用前自动预检**：发现冲突时列出清单，确认后自动 `systemctl disable --now` 并清理残留设备，把停用的服务名记入 `/etc/cake-fairshare/disabled-units`，方便一条命令恢复。
- 菜单第 1 项（自检）现在包含预检。

### 修复

- **多网卡误删**：回收历史 `ifb` 时会把另一块网卡正在使用的那只也删掉。现在会跳过其他已配置网卡记录在 state 里的设备。
- `save_conf` 在 `set -u` 下、变量未初始化时会直接报错退出。
- `cake_mq` 检测结果显示"不可用"容易被误读成故障，实际本工具不依赖它，改为标注"可选"。
- 非终端环境（管道调用、cron）下 `draw_menu` 的 `clear` 会打印 `TERM environment variable not set`。
- 启用成功提示与菜单头显示的是基准带宽而非实际的上下行值。
- 预检里"历史限速脚本"的判定加了 tc 命令检查，避免把纯菜单脚本也列进来。

## v2.2.1 — 2026-11-04

### 修复

- **重启后整形失效（严重）**：`stop` 或冷启动后，多队列网卡的根队列会回到内核默认的 `mq`。v2.0–v2.2.0 一见 `mq` 就直接放弃并提示 `ethtool -L`，导致 `systemctl start` / 开机自启全部失败、节点处于**完全不整形**状态。
  实测（Debian 12 / 内核 6.1）`tc qdisc replace dev ens5 root cake ...` 在 `mq` 上是允许的，会整体替换 mq 及其叶子队列。现在改为直接尝试，只有真被拒绝时才给出降队列的建议。
- `stop` 时若原队列是 `mq`，不再尝试 `replace ... root mq`，改为清空并交给内核自动恢复。

> 这个 bug 不会在"首次启用"时暴露（那时根队列还挂着上一套 htb/fq），只有重启或 stop→start 才会踩到，属于典型的"测试路径缺失"。

## v2.2.0 — 2026-11-04

### 新增

- **采样日志**：菜单第 10 项安装 systemd timer，每分钟把上下行实速、qdisc 超限/丢弃计数、连接数追加到 `/var/log/cake-fairshare-sample.log`（CSV），超过 30000 行自动裁剪。
- **`cake-fairshare report [N]`**：按表格回看最近 N 条采样，附最小值/平均值/最大值。
- **`cake-fairshare check`**：现场诊断。1 秒实测上下行 → 与整形上限对比算占用率 → 列出连接数最多的对端 IP → 直接给出"自身占满 / 链路空闲"的结论，用于区分平台限速与自身流量。
- 新增 `log` 子命令（供 timer 调用）。

### 修复

- 菜单在标准输入结束时（管道调用、Ctrl-D）会死循环的问题，现在直接退出。

## v2.1.0 — 2026-11-04

### 新增

- `CAKE_OPTS` / `CAKE_OPTS_INGRESS`：向 cake 命令行透传原生参数，例如 `ack-filter`（压缩上行纯 ACK）、`rtt 70ms`、`overhead 38`、`wash`。入口与出口可分别设置。
- `RATE_EGRESS` / `RATE_INGRESS`：上下行分别限速，留空则跟随 `RATE`。适用于上下行不对称的链路。
- 菜单第 9 项「高级参数」，可直接编辑上述四项并立即应用；输入 `-` 清空。
- `menu_rate` 在检测到单独的上/下行带宽时给出提示，避免误以为改了基准值就生效。

### 说明

- 参数非法时 `tc qdisc replace` 会失败，原有队列保持不变，不会把网卡打成半整形状态。

## v2.0.1 — 2026-11-04

### 修复

- **重复 apply 会遗留 ifb 设备**：旧实现每次只删除状态文件里记录的那一个 ifb，反复应用或在菜单里改带宽后会堆出 `ifb1/ifb2/ifb3…` 一排孤儿设备。现在会先拆除 ingress，再回收所有根队列为 `cake` 的历史 ifb，只保留一个。
- **重复 apply 会把原始 qdisc 覆盖成 `cake`**：导致 `stop` 时无法回到启用前的队列（会尝试"恢复 cake"）。原始值现在只在首次记录，后续 apply 不再覆盖。
- **`stop` 对分层队列处理不当**：原队列是 `htb`/`tbf` 时，旧实现会尝试重建一个空的 htb（没有类，等于废队列）。现在改为清空根队列并提示用原工具恢复，避免制造 half-broken 状态。

## v2.0.0 — 2026-11-04

首个公开版本。

### 新增

- 交互式菜单：环境自检、启用/停止整形、状态快照、实时监控、调整带宽、开机自启
- 自动生成 systemd 单元，提供 `apply` / `stop` 无交互入口，便于开机自愈
- 启用前记录原始 qdisc，停止时精确恢复（例如原来的 `fq` 不会被换成 `pfifo_fast`）
- 多队列网卡（`mq`）识别：优先使用 `cake_mq`，不支持时给出可回滚的处置建议
- 双栈网卡批量应用（v4/v6 分属不同网卡时一次配完）
- IPv6 与多 IP 用户的份额偏差说明，以及基于 `nft mark → tc fw → classid` 的归并方案
- 全部操作写入 `/var/log/cake-fairshare.log`

### 变更

- 由单文件 `up/down` 脚本重构为常驻运维工具，配置文件独立于脚本
