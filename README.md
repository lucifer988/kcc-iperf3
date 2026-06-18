# kcc-iperf3 —— 一键 KCC 内核拥塞控制 + iperf3 调优测速

一条命令完成：装依赖 → 拉取并编译 [liulilittle/kcc](https://github.com/liulilittle/kcc) 内核模块 → 双端内核调优 → `iperf3` 跑分对比。**目标是提高吞吐、降低 TCP 重传。** 编译失败会自动回退到 BBR，保证脚本始终有调优效果。

测速封装思路借鉴 [lucifer988/iperf3](https://github.com/lucifer988/iperf3) 与 [esnet/iperf](https://github.com/esnet/iperf)。

---

## ⚠️ 先看这里：能不能跑通

- **测速 / 调优部分（server / client / bench / status / uninstall）**：成熟稳定，装好 `iperf3` 即可用。
- **KCC 内核模块部分**：上游 `liulilittle/kcc` 是**实验性**项目，能否在你的内核上编出标准 `.ko` 并注册成可用拥塞算法，取决于上游结构与你的内核版本，**不保证一定成功**。
- 所以脚本的设计是：**KCC 装不上 → 自动回退 BBR，并照常应用内核调优**。也就是说，最坏情况你得到的是一套"BBR + 高吞吐 sysctl 调优 + iperf3 跑分工具"，依然有用，不会把机器"装废"。
- 想看 KCC 到底有没有装上，跑 `sudo bash kcc.sh status` 看"当前算法/可用算法"即可。

---

## 安装与使用（教程）

> 需要 root；服务端、客户端两台机器都建议执行 `install`，**双端同时调优效果最佳**。

### 1. 获取脚本

```bash
git clone https://github.com/lucifer988/kcc-iperf3.git
cd kcc-iperf3
```

或远程一键安装（无需 clone）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lucifer988/kcc-iperf3/main/kcc.sh) install
```

### 2. 两台机器各跑一次安装

```bash
sudo bash kcc.sh install
```

它会自动：识别发行版装好依赖与 `iperf3` → 拉源码按当前内核编译加载 KCC（失败回退 BBR）→ 写入 `sysctl` 调优并设为默认拥塞算法。

### 3. 测速

```bash
# 服务端机器
sudo bash kcc.sh server          # 监听 5201，记得放行入站 TCP 5201

# 客户端机器（另一台）
sudo bash kcc.sh bench 1.2.3.4   # 1.2.3.4 = 服务端 IP
```

输出示例：

```
算法              吞吐(Mbps)        重传
------------------------------------
cubic                 612.30        1843
bbr                   894.10         120
kcc                   951.70          41  ← KCC
------------------------------------
```

> 跑分跳过前 3 秒预热（`-O`），避免慢启动干扰对比；可用 `BENCH_OMIT` 调整。

---

## 命令一览

| 命令 | 作用 |
| --- | --- |
| `sudo bash kcc.sh install` | 一键：依赖 + 编译加载 KCC + 内核调优 |
| `sudo bash kcc.sh server` | 本机作为 iperf3 服务端（监听 5201） |
| `sudo bash kcc.sh client <对端IP>` | 本机作为客户端发起一次测试 |
| `sudo bash kcc.sh bench <对端IP>` | 基准对比 cubic / bbr / kcc |
| `sudo bash kcc.sh status` | 查看当前算法 / qdisc / 模块状态 |
| `sudo bash kcc.sh uninstall` | 卸载并还原内核参数（恢复 cubic） |
| `bash kcc.sh help` | 查看帮助 |

不带参数运行 `sudo bash kcc.sh` 进入交互菜单。

---

## 可调环境变量

```bash
KCC_REPO=...        # KCC 源码仓库地址（默认官方）
KCC_BRANCH=...      # 指定分支
WORK_DIR=...        # 源码编译目录（默认 /usr/local/src/kcc）
FALLBACK_CC=bbr     # KCC 不可用时的回退算法
IPERF_PORT=5201     # iperf3 端口
IPERF_BIND=...      # 服务端绑定地址（多网卡时指定）
BENCH_TIME=15       # 每轮测试秒数
BENCH_PARALLEL=4    # 并发流数量
BENCH_OMIT=3        # 跑分预热跳过秒数
KCC_DEBUG=1         # 显示内核模块编译细节（排错用）
NO_COLOR=1          # 关闭彩色输出
```

例：`sudo IPERF_PORT=5300 BENCH_TIME=30 bash kcc.sh bench 1.2.3.4`

---

## 手动编译（自动编译失败时）

不同内核下源码文件名/结构可能不同。脚本会自动定位含 `tcp_register_congestion_control` 的 `.c` 文件现编；若仍失败，用根目录 `Makefile` 手动来：

```bash
git clone https://github.com/liulilittle/kcc.git src
# 按 src 里实际的拥塞控制源文件名修改 Makefile 顶部 MODULE 变量
make
sudo make load
sudo make install-cc
```

排错建议：先 `KCC_DEBUG=1 sudo bash kcc.sh install` 看完整编译报错。

---

## 工作原理（简述）

1. **拥塞算法**决定 TCP 发多快、丢包后怎么退避。`cubic` 基于丢包，链路一抖就猛降速；BBR/KCC 基于"带宽×时延积"建模，KCC 进一步用卡尔曼滤波平滑带宽估计，**在高时延/有丢包的跨境链路上更能顶住吞吐、少触发重传**。
2. 脚本把默认 qdisc 设为 `fq`（BBR 系算法配套的 pacing 队列），并加大 `tcp_rmem/tcp_wmem` 等缓冲，让大带宽时延积链路能跑满窗口。
3. `iperf3` 的 `Retr` 列即 TCP 重传次数，跑分表直接对比即可看出 KCC 是否真的降低了重传。

---

## 注意事项

- 需要安装与**当前运行内核匹配**的头文件（`linux-headers-$(uname -r)` / `kernel-devel`）。云厂商魔改内核可能缺头文件，需先补齐或换通用内核。
- 容器（OpenVZ / 多数 LXC）通常**无法加载内核模块**，KCC 会回退 BBR，请在 KVM / 独服上使用以获得完整效果。
- 内核模块、`sysctl` 改动会影响整机网络栈，**生产环境请先在测试机验证**；`uninstall` 可一键还原。
- 远程一键用了 `curl | bash`，介意供应链风险可先下载 `kcc.sh` 审阅再执行。

---

## 致谢与许可

- 内核模块源码：[liulilittle/kcc](https://github.com/liulilittle/kcc)（版权与许可归原作者，运行时拉取并按其许可使用）
- 测速思路：[lucifer988/iperf3](https://github.com/lucifer988/iperf3) 及 [esnet/iperf](https://github.com/esnet/iperf)
- 本仓库封装脚本以 MIT 许可发布，见 [LICENSE](./LICENSE)
