# cake-fairshare

> 一台 100M 的节点，1 人在线就给他 100M，5 人在线各 20M，10 人在线各 10M —— 自动跟随在线人数变化，不需要在面板里给任何人写死速度。

<p>
  <img alt="platform" src="https://img.shields.io/badge/platform-Debian%2012%20%7C%20Ubuntu%2022.04%2B-brightgreen">
  <img alt="kernel" src="https://img.shields.io/badge/kernel-4.19%2B-blue">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-black">
</p>

基于 Linux 内核 CAKE 队列的 per-host 公平调度，把整机带宽按**当前在线客户端**平均分配。入口/出口双向整形，单人开几十条连接也抢不走别人那一份。

---

## 它解决什么问题

XrayR 这类后端在面板未设限时**不做任何带宽分配**，`SpeedLimit=0` 的连接上不挂限速器，数据包直接交给内核。此时谁抢到多少，取决于三件与"人"无关的事：

1. 内核 qdisc（Debian 内核默认 `pfifo_fast`，很多镜像改成 `fq_codel`/`fq`）
2. 每个客户端开了多少条 TCP 流
3. 各端的拥塞控制算法

结果是 **按流竞争，不是按人分配**。一台 100M 节点上 5 个人在线，实测常见分布是 `52 / 21 / 13 / 8 / 6`（开 16 线程下载的人拿一半），而不是每人 20。

在面板里给每个用户写死速度能解决"防抢占"，但解决不了"人少时浪费、人多时不够"——那需要一个会自己算的分配器。这就是本项目做的事。

## 效果对比

以 100M 节点、95mbit 整形为例：

| 在线人数 | 未整形（按流竞争） | cake-fairshare |
|:---:|---|---|
| 1 | 单流可跑满 100M | 95M 全给 |
| 2 | 各自单流约 50M；一方多线程则可能 80 : 20 | 各 ≈ 47M |
| 5 | 均值 20M，实测 6 ~ 52M，随谁在下载而变 | 各 ≈ 19M |
| 10 | 均值 10M，队列堆积，延迟从 20ms 涨到 200ms+ | 各 ≈ 9.5M，延迟基本不变 |

份额是**上限而非固定值**：3 人在线时每个人都能 burst 到 30M，空闲带宽不会被浪费。

## 原理

只有两件事，都作用在网卡上，与面板和账号体系无关：

```bash
# 出口：服务器 -> 客户端，按「目的 IP」公平（每个客户端一份）
tc qdisc replace dev eth0 root cake bandwidth 95mbit dual-dsthost

# 入口：客户端 -> 服务器，按「源 IP」公平（经 ifb 中转）
tc qdisc replace dev eth0 handle ffff: ingress
tc filter  add    dev eth0 parent ffff: protocol all u32 \
          match u32 0 0 action mirred egress redirect dev ifb0
tc qdisc replace dev ifb0 root cake bandwidth 95mbit dual-srchost
```

`final` 效果 = CAKE 的 deficit 整形器 + host 隔离：同一 IP 无论开多少流，总量不超过自己那一份；没人用满时自动释放给其他人。

## 快速开始

```bash
# 一键安装 + 一键配置（推荐）
bash <(curl -fsSL https://raw.githubusercontent.com/hankepeng/cake-fairshare/main/install.sh)
sudo cake-fairshare init
```

`init` 会做四件事：按默认参数生成配置、跑一次环境预检、立即启用整形、设置开机自启。全程无交互。

默认参数就是**为境外代理节点准备的**：

| 项 | 默认值 | 说明 |
|---|---|---|
| 网卡 | 默认路由那块 | 无需指定，多网卡机器才需要手选 |
| 带宽 | `190mbit` | 对应 200M 峰值套餐（95% 留余量） |
| 方向 | `both` | 上下行都整形 |
| 入口参数 | `ack-filter` | 压缩上行纯 ACK，跨国链路提升有效吞吐 |

其他套餐直接传参：

```bash
sudo cake-fairshare init 95mbit     # 100M 峰值套餐
sudo cake-fairshare init 28mbit     # 30M 峰值套餐
sudo cake-fairshare init 475mbit    # 500M 峰值套餐
```

想改**默认值本身**（比如你所有机器都是 100M），改脚本头部两行即可，之后 `init` 不带参数就是你的标准：

```bash
DEF_RATE="95mbit"
DEF_CAKE_OPTS_INGRESS="ack-filter"
```

需要更细的控制（指定网卡、只限下行、自定义 cake 参数）时再走交互菜单：

```bash
sudo cake-fairshare      # 1 自检 → 2 启用 → 6 自启
```

手动安装：

```bash
git clone https://github.com/hankepeng/cake-fairshare.git
cd cake-fairshare
sudo install -m 0755 cake-fairshare.sh /usr/local/sbin/cake-fairshare
sudo cake-fairshare init
```

## 交互菜单

```
  CAKE 公平带宽分配 v2.4.0   Debian GNU/Linux 12 (bookworm)
------------------------------------------------------------
  状态：○ 未启用      网卡 eth0   带宽 95mbit   方向 both
------------------------------------------------------------
  1) 环境自检（系统 / 内核 / 网卡 / qdisc / BBR / cake 支持）
  2) 启用或重新配置整形
  3) 查看当前状态快照
  4) 实时流量监控
  5) 停止整形并恢复原始 qdisc
  6) 开机自启（安装 / 移除 / 查看）
  7) 调整带宽
  8) IPv6 与多 IP 用户说明（进阶）
  9) 高级参数（cake 选项 / 上下行分别限速）
 10) 采样日志与现场诊断
  0) 退出
```

- **启用前会打印将要执行的 tc 命令**，确认后才落地；执行失败会清理状态记录，不留半成品。
- 第 `4` 项每 2 秒刷新一次整机上下行实速与 qdisc 的 `backlog`/`overlimits`，压没压得住一眼看得出。
- 第 `9` 项可追加 cake 原生参数，最常用的是 `ack-filter`：跨国链路的上行有大量纯 ACK 小包，压掉它们等于免费抬高有效吞吐，且**不改变限速值**。

## 命令行

```bash
cake-fairshare                  # 交互菜单
cake-fairshare apply            # 按配置启用（无交互，systemd 使用）
cake-fairshare stop             # 撤销整形，恢复启用前的 qdisc
cake-fairshare status           # 快照
cake-fairshare monitor [网卡]   # 实时监控
cake-fairshare log              # 采样一次（供 timer 调用）
cake-fairshare report [N]       # 查看最近 N 条采样
cake-fairshare check            # 现场诊断：判断是自身占满还是链路问题
cake-fairshare preflight        # 只检查环境冲突，不做任何改动
cake-fairshare init [带宽]      # 用默认参数一键配置 + 启用 + 开机自启
```

## 环境预检与自动清理

新机器上往往已经躺着别的限速脚本（`wondershaper`、各种一键 htb 脚本）。它们和 cake 抢同一个根队列，开机时谁后跑谁生效，出问题时极难归因。菜单第 2 项在启用前会先做一次预检：

```bash
cake-fairshare preflight    # 只检查，不改动任何东西
```

检查项：

- 根队列不是 cake（`htb`/`tbf`/`hfsc`/`netem`…）
- 残留的 `ifb` 设备挂着别的队列
- **已启用、且会执行 tc 命令的 systemd 服务**——注意 unit 文件本身通常不含 tc 命令，真正的命令在 `ExecStart` 指向的脚本里，所以预检会顺着 `ExecStart` 去 grep
- `/etc/rc.local` 与 root 的 crontab 里的 tc 命令

发现冲突时会问你一句，同意后自动 `systemctl disable --now` 对应服务、删掉残留 ifb，并把停用过的服务名记到 `/etc/cake-fairshare/disabled-units`，方便随时恢复：

```bash
systemctl enable --now <被停用的服务名>
```

## 采样日志与诊断

带宽跑不满时，最难的是判断"是自己占满了"还是"上游/平台限速"。菜单第 10 项装一个每分钟采样一次的 timer，把答案留成数据：

```bash
cake-fairshare          # 第 10 项 → 1 开启
cake-fairshare report   # 事后回看
cake-fairshare check    # 事发时现场判断
```

日志是 CSV，一行一分钟：

```
2026-11-04 05:00:37,0.01,0.01,64389,1,55,6
    时间            下行   上行  出口超限 丢弃 入口超限 连接数
```

`check` 会做三件事：1 秒实测当前上下行、与整形上限对比算占用率、列出连接数最多的对端 IP，然后直接给结论——

| 占用率 | 结论 |
|---|---|
| ≥ 85% | 链路已饱和，测速偏低是自己在占用，正常 |
| 40~85% | 部分占用，看连接是否分散 |
| < 40% | 本机空闲却慢 → 问题在上游链路、跨境路由或平台限速 |

有了这条基线，下次再遇到"只有 1-3M"，先 `check` 一眼就能定性，不用靠回忆。

日志超过 30000 行会自动裁到 20000 行（约 20 天），不用配 logrotate。

## 文件位置

| 路径 | 用途 |
|---|---|
| `/usr/local/sbin/cake-fairshare` | 程序本体 |
| `/etc/cake-fairshare/config` | 网卡 / 带宽 / 方向 / 高级参数 |
| `/etc/cake-fairshare/state.<网卡>` | 启用前的 qdisc 与 ifb 名，用于精确回滚 |
| `/etc/systemd/system/cake-fairshare.service` | 开机自启单元（菜单第 6 项生成） |
| `/etc/systemd/system/cake-fairshare-log.{service,timer}` | 采样定时器（菜单第 10 项生成） |
| `/var/log/cake-fairshare.log` | apply / stop / 失败原因 |
| `/var/log/cake-fairshare-sample.log` | 每分钟采样 CSV |
| `/var/lib/cake-fairshare/last` | 上次采样的计数器基线 |

配置文件各字段：

```bash
IFACES="eth0"              # 网卡，多块用空格分隔
RATE="160mbit"             # 基准带宽，上下行都用它
MODE="both"                # both = 双向整形；down = 只整形出口
RATE_EGRESS=""             # 留空跟随 RATE；填写则单独覆盖出口
RATE_INGRESS=""            # 留空跟随 RATE；填写则单独覆盖入口
CAKE_OPTS=""               # 追加到两个方向的 cake 参数，如 "rtt 70ms overhead 38"
CAKE_OPTS_INGRESS=""       # 只追加到入口，如 "ack-filter"
```

改完执行 `sudo cake-fairshare apply` 生效，或直接用菜单第 9 项改。

**关于 `ack-filter`**：它只压缩 TCP 的纯 ACK 包，不改变整形带宽，适合客户端与节点之间有较大 RTT 的场景（例如国内连境外节点）。上行方向收益最明显，所以一般放在 `CAKE_OPTS_INGRESS`。若链路上有异常或需要排查丢包，先把它去掉再测。

## 回滚

```bash
sudo cake-fairshare     # 第 6 项 → 2 移除自启；第 5 项 → 停止整形
rm -rf /etc/cake-fairshare
```

`stop` 不是简单粗暴地删根队列，而是按 state 文件把你**启用前的那个 qdisc 挂回去**——原本跑 `fq` 的机器会精确回到 `fq`。

## 常见问题

**带宽应该填多少？** 实测值的 95% 左右。填满甚至超过实际链路时，队列不成为瓶颈，整形形同虚设。

**已经开了 BBR + fq，会冲突吗？** 不会。BBR 决定发多快，CAKE 决定怎么排队，两者不同层。内核 4.13 起 BBR 可自行 pacing，把 root qdisc 从 `fq` 换成 `cake` 不影响 BBR 工作。建议保留 `net.core.default_qdisc=fq` 作为兜底（tc 规则没生效时会回落，比 `pfifo_fast` 好）。

**同时有 IPv4 和 IPv6 呢？** tc 工作在 IP 层之下，v4/v6 共用同一个 qdisc，一定生效。但公平单位是 IP 而不是账号：一个用户双栈同时连接会被算成两个 host，拿两份份额。菜单第 8 项给了按前缀归并的方案。

**看到 `mq` 就以为挂不上？** 多队列网卡（virtio 常见）的根队列通常是 `mq`，但 `tc qdisc replace dev eth0 root cake` **是允许的**，它会整体替换掉 mq 及其叶子队列。只有在极老的内核上被拒时，才需要 `ethtool -L eth0 combined 1`（先 `ethtool -l eth0` 记下原值以便回滚）。

**和面板限速是什么关系？** 不冲突，串联后取较小值：`实际速度 = min(套餐档位, 总带宽 / 在线人数)`。CAKE 负责兜底公平，面板限速负责区分套餐。

**真的生效了吗？**

```bash
tc -s qdisc show dev eth0     # 应出现 cake ... bandwidth 95Mbit dual-dsthost
tc -s qdisc show dev ifb0
# overlimits / drops 持续增长 = 正在压制；backlog 长期堆满 = 带宽设高了
```

## 兼容性

| 系统 | 说明 |
|---|---|
| Debian 12 / Ubuntu 22.04+ | 内核自带 `sch_cake`，开箱可用 |
| Debian 11 / Ubuntu 20.04 | 内核 ≥ 4.19 同样支持（CAKE 自 4.19 进入上游） |
| RHEL / Rocky / Alma 9 | 需 `dnf install iproute iproute-tc`，`sch_cake` 在 `kernel-modules` 中 |
| 高于 2 Gbps | 单队列 CAKE 受 qdisc 锁限制，建议改用 `fq_codel` + 应用层限速，或等待 `cake_mq` |

## License

[MIT](LICENSE)

---

<details>
<summary>English</summary>

**cake-fairshare** shares a node's total bandwidth equally among currently online clients, using Linux `tc` CAKE queueing with per-host isolation — no panel-side per-user speed limits required. On a 100 Mbit node: 1 client gets ~100 Mbit, 5 clients get ~20 Mbit each, and a single client with 50 concurrent flows still cannot take more than its share.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hankepeng/cake-fairshare/main/install.sh)
sudo cake-fairshare
```

Requires Linux ≥ 4.19 with `sch_cake` (Debian 12 / Ubuntu 22.04+ ship it). MIT licensed.
</details>
