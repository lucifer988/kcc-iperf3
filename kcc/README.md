# kcc —— 一键 KCC 内核拥塞控制 + iperf3 调优测速

> 借鉴 [liulilittle/kcc](https://github.com/liulilittle/kcc) 与 [lucifer988/iperf3](https://github.com/lucifer988/iperf3) 的"变形体"。
> 一条命令完成：安装依赖 → 拉取并编译 KCC 内核模块 → 双端内核调优 → iperf3 跑分对比，**目标是提高吞吐、降低 TCP 重传**。

## 这是什么

**KCC** 是 liulilittle 写的一个实验性 Linux 内核 TCP 拥塞控制模块：在 BBR 模型上加入卡尔曼滤波（Kalman Filter）做抗噪带宽估计，定位与 `bbr`、`bbrplus` 同类，本质是一种"更稳的 BBR 变种"。本仓库把它和 iperf3 测速封装成**一键脚本**：

- 自动识别发行版（Debian/Ubuntu/CentOS/RHEL/Arch/openSUSE）并装好编译依赖与 iperf3
- 运行时从官方仓库拉取 KCC 源码、按当前内核编译、加载，并**自动探测它注册的拥塞算法名**
- 写入 `sysctl` 调优（`fq` qdisc、加大收发缓冲、开启 MTU 探测/FastOpen 等）并设为默认拥塞算法
- 支持 `cubic / bbr / kcc` 三种算法**自动跑分对比**，直接打表给出吞吐与重传
- 编译失败时**自动回退 BBR**，保证脚本始终有调优效果；可选 DKMS 实现内核升级后自动重编

## 快速开始

> 需要 root；服务端、客户端两台机器都建议执行 `install`，**双端同时调优效果最佳**。

### 方式一：克隆后运行

```bash
git clone https://github.com/USER/kcc.git
cd kcc
sudo bash kcc.sh            # 进入交互菜单
# 或直接：
sudo bash kcc.sh install    # 一键安装 + 调优
```

### 方式二：远程一键（fork 后把 USER 换成你的用户名）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/USER/kcc/main/kcc.sh) install
```

## 用法

| 命令 | 作用 |
| --- | --- |
| `sudo bash kcc.sh install` | 一键：依赖 + 编译加载 KCC + 内核调优 |
| `sudo bash kcc.sh server` | 本机作为 iperf3 服务端（监听 5201） |
| `sudo bash kcc.sh client <对端IP>` | 本机作为客户端发起测试 |
| `sudo bash kcc.sh bench <对端IP>` | 基准对比：cubic vs bbr vs kcc |
| `sudo bash kcc.sh status` | 查看当前算法 / qdisc / 模块状态 |
| `sudo bash kcc.sh uninstall` | 卸载并还原内核参数 |

### 典型测速流程

```bash
# 服务端机器
sudo bash kcc.sh install
sudo bash kcc.sh server

# 客户端机器（另开一台）
sudo bash kcc.sh install
sudo bash kcc.sh bench 1.2.3.4     # 1.2.3.4 = 服务端公网 IP
```

输出示例：

```
算法              吞吐(Mbps)        重传次数
-------------------------------------------
cubic                 612.30          1843
bbr                   894.10           120
kcc                   951.70            41  ← KCC
-------------------------------------------
```

## 可调环境变量

```bash
KCC_REPO=...        # KCC 源码仓库地址（默认官方）
KCC_BRANCH=...      # 指定分支
IPERF_PORT=5201     # iperf3 端口
BENCH_TIME=15       # 每轮测试秒数
BENCH_PARALLEL=4    # 并发流数量
FALLBACK_CC=bbr     # KCC 不可用时的回退算法
```

例：`sudo IPERF_PORT=5300 BENCH_TIME=30 bash kcc.sh bench 1.2.3.4`

## 手动编译（自动编译失败时）

不同内核版本下，仓库里源码文件名/结构可能不同。一键脚本会自动定位含
`tcp_register_congestion_control` 的 `.c` 文件并现编；若仍失败，用根目录 `Makefile` 手动来：

```bash
git clone https://github.com/liulilittle/kcc.git src
# 按 src 里实际的拥塞控制源文件名修改 Makefile 顶部 MODULE 变量
make
sudo make load
sudo make install-cc
```

## 工作原理简述

1. **拥塞算法**决定 TCP 发多快、丢包后怎么退避。`cubic` 基于丢包，链路一抖就猛降速；BBR/KCC 基于"带宽×时延积"建模，KCC 又用卡尔曼滤波平滑带宽估计，**在高时延/有丢包的跨境链路上更能顶住吞吐、少触发重传**。
2. 脚本把内核默认 qdisc 设为 `fq`（BBR 系算法配套的公平队列/pacing），并加大 `tcp_rmem/tcp_wmem` 等缓冲，使大带宽时延积链路能跑满窗口。
3. `iperf3` 的 `Retr` 列即 TCP 重传次数，跑分表直接对比即可看出 KCC 是否降低了重传。

## 注意事项

- 需要安装与**当前运行内核匹配**的头文件（`linux-headers-$(uname -r)` / `kernel-devel`）。云厂商魔改内核可能缺头文件，需先补齐或换通用内核。
- KCC 为实验性模块；若与你的内核版本不兼容，脚本会自动回退 BBR，不会让你"装废"。
- 容器（OpenVZ/部分 LXC）通常**无法加载内核模块**，请在 KVM/独服上使用。
- 内核模块、`sysctl` 改动会影响整机网络栈，生产环境请先在测试机验证。

## 致谢与许可

- 内核模块源码：[liulilittle/kcc](https://github.com/liulilittle/kcc)（版权归原作者，遵循其许可）
- 测速思路：[lucifer988/iperf3](https://github.com/lucifer988/iperf3) 及 esnet/iperf
- 本仓库封装脚本以 MIT 许可发布，见 [LICENSE](./LICENSE)
