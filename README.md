# kcc-iperf3

KCC/BBR 网络调优 + iperf3 测速脚本。

脚本会尝试安装 KCC。
如果 KCC 编译或加载失败，会自动回退到 BBR。
最终是否真的启用了 KCC，以 `status` 输出为准。

## 目录位置

本仓库的脚本不在根目录，实际位置是：

```bash
kcc-iperf3/kcc.sh
```

所以 clone 后要进入子目录：

```bash
git clone https://github.com/lucifer988/kcc-iperf3.git
cd kcc-iperf3/kcc-iperf3
```

## 安装

服务端和客户端都建议执行一次：

```bash
sudo bash kcc.sh install
```

也可以直接用远程命令安装：

```bash
curl -fsSL https://raw.githubusercontent.com/lucifer988/kcc-iperf3/main/kcc-iperf3/kcc.sh | sudo bash -s -- install
```

安装完成后查看当前状态：

```bash
bash kcc.sh status
```

看这两项：

```text
当前算法
可用算法
```

如果 `可用算法` 里有 `kcc`，说明 KCC 可用。
如果没有 `kcc`，脚本会使用 BBR 回退。

## 测速

服务端执行：

```bash
sudo bash kcc.sh server
```

默认监听 TCP `5201`。
云服务器安全组和系统防火墙都要放行 TCP `5201`。

客户端执行：

```bash
sudo bash kcc.sh bench <服务端IP>
```

示例：

```bash
sudo bash kcc.sh bench 1.2.3.4
```

只跑一次普通 iperf3 测试：

```bash
sudo bash kcc.sh client <服务端IP>
```

## 常用命令

| 命令                                | 作用                                |
| --------------------------------- | --------------------------------- |
| `sudo bash kcc.sh install`        | 安装依赖，尝试编译/加载 KCC，写入网络调优参数         |
| `sudo bash kcc.sh server`         | 启动 iperf3 服务端，默认监听 `5201`         |
| `sudo bash kcc.sh client <服务端IP>` | 发起一次 iperf3 测试                    |
| `sudo bash kcc.sh bench <服务端IP>`  | 对比 `cubic` / `bbr` / `kcc` 的吞吐和重传 |
| `bash kcc.sh status`              | 查看当前拥塞算法、可用算法、qdisc、模块状态          |
| `sudo bash kcc.sh uninstall`      | 卸载并还原配置                           |
| `bash kcc.sh help`                | 查看帮助                              |
| `bash kcc.sh version`             | 查看版本                              |

不带参数运行会进入交互菜单：

```bash
sudo bash kcc.sh
```

## 自定义参数

自定义 iperf3 端口：

```bash
sudo IPERF_PORT=5300 bash kcc.sh server
sudo IPERF_PORT=5300 bash kcc.sh bench <服务端IP>
```

自定义测试时间、并发数、预热跳过时间：

```bash
sudo BENCH_TIME=30 BENCH_PARALLEL=8 BENCH_OMIT=5 bash kcc.sh bench <服务端IP>
```

服务端绑定指定 IP：

```bash
sudo IPERF_BIND=10.0.0.2 bash kcc.sh server
```

显示 KCC 编译日志：

```bash
sudo KCC_DEBUG=1 bash kcc.sh install
```

关闭彩色输出：

```bash
NO_COLOR=1 bash kcc.sh status
```

## 环境变量

| 变量               |                                      默认值 | 作用              |
| ---------------- | ---------------------------------------: | --------------- |
| `KCC_REPO`       | `https://github.com/liulilittle/kcc.git` | KCC 源码仓库        |
| `KCC_BRANCH`     |                                        空 | 指定 KCC 分支       |
| `WORK_DIR`       |                     `/usr/local/src/kcc` | KCC 源码目录        |
| `FALLBACK_CC`    |                                    `bbr` | KCC 不可用时回退的拥塞算法 |
| `IPERF_PORT`     |                                   `5201` | iperf3 端口       |
| `IPERF_BIND`     |                                        空 | iperf3 服务端绑定地址  |
| `BENCH_TIME`     |                                     `15` | 每轮测试秒数          |
| `BENCH_PARALLEL` |                                      `4` | 并发流数量           |
| `BENCH_OMIT`     |                                      `3` | 跳过前几秒预热         |
| `KCC_DEBUG`      |                                        空 | 显示 KCC 编译日志     |
| `NO_COLOR`       |                                        空 | 关闭彩色输出          |

## KCC 没有生效怎么办

先看状态：

```bash
bash kcc.sh status
```

如果 `可用算法` 里没有 `kcc`，说明 KCC 模块没有成功注册。常见原因：

```text
1. 当前内核缺少 headers / kernel-devel
2. 云厂商内核不兼容
3. 容器环境不能加载内核模块
4. Secure Boot 拒绝加载第三方内核模块
5. 上游 KCC 源码不兼容当前内核
```

这种情况下脚本会回退到 BBR，不影响 iperf3 测速和基础网络调优。

## 手动编译排错

只有在 `sudo bash kcc.sh install` 失败时才需要看这里。

进入脚本目录：

```bash
cd kcc-iperf3/kcc-iperf3
```

克隆 KCC 源码：

```bash
git clone https://github.com/liulilittle/kcc.git src
```

先查看源码里实际的模块文件名：

```bash
ls src/*.c
```

如果源码文件是 `tcp_kcc.c`，手动编译用：

```bash
make MODULE=tcp_kcc
sudo make MODULE=tcp_kcc load
```

然后设置拥塞算法为 `kcc`：

```bash
sudo sysctl -w net.core.default_qdisc=fq
sudo sysctl -w net.ipv4.tcp_congestion_control=kcc
```

确认是否生效：

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.ipv4.tcp_available_congestion_control
```

注意：
`tcp_kcc` 是内核模块名。
`kcc` 是 TCP 拥塞算法名。
这两个不是同一个东西。

## 卸载

```bash
sudo bash kcc.sh uninstall
```

或者：

```bash
sudo bash uninstall.sh
```

卸载后再查看：

```bash
bash kcc.sh status
```

## 使用要求

* Linux 系统
* root 权限
* 服务端放行 TCP `5201`
* 服务端和客户端都建议执行 `install`
* KCC 是否可用取决于当前内核环境
* 容器环境通常不能加载 KCC 内核模块，可能只会回退到 BBR
