# kcc-iperf3

KCC/BBR 内核网络调优 + iperf3 测速脚本。

## 安装

脚本在仓库的 `kcc-iperf3/` 子目录里。

```bash
git clone https://github.com/lucifer988/kcc-iperf3.git
cd kcc-iperf3/kcc-iperf3
sudo bash kcc.sh install
```

也可以用安装入口：

```bash
sudo bash install.sh
```

不想 clone，直接远程执行：

```bash
curl -fsSL https://raw.githubusercontent.com/lucifer988/kcc-iperf3/main/kcc-iperf3/kcc.sh | sudo bash -s -- install
```

服务端和客户端都建议执行一次 `install`。

## 测速

服务端机器执行：

```bash
sudo bash kcc.sh server
```

默认监听 TCP `5201`。云服务器安全组和本机防火墙需要放行这个端口。

客户端机器执行：

```bash
sudo bash kcc.sh bench <服务端IP>
```

只跑一次普通测试：

```bash
sudo bash kcc.sh client <服务端IP>
```

示例：

```bash
sudo bash kcc.sh bench 1.2.3.4
```

## 常用命令

| 命令                                | 作用                                |
| --------------------------------- | --------------------------------- |
| `sudo bash kcc.sh install`        | 安装依赖、编译/加载 KCC、写入内核调优参数           |
| `sudo bash kcc.sh server`         | 启动 iperf3 服务端，默认监听 `5201`         |
| `sudo bash kcc.sh client <服务端IP>` | 发起一次 iperf3 测试                    |
| `sudo bash kcc.sh bench <服务端IP>`  | 对比 `cubic` / `bbr` / `kcc` 的吞吐和重传 |
| `bash kcc.sh status`              | 查看当前拥塞算法、可用算法、qdisc、模块状态          |
| `sudo bash kcc.sh uninstall`      | 卸载 KCC，并恢复为 `cubic`               |
| `bash kcc.sh help`                | 查看帮助                              |
| `bash kcc.sh version`             | 查看脚本版本                            |

不带参数运行会进入交互菜单：

```bash
sudo bash kcc.sh
```

## 自定义参数

自定义端口：

```bash
sudo IPERF_PORT=5300 bash kcc.sh server
sudo IPERF_PORT=5300 bash kcc.sh bench <服务端IP>
```

自定义测试时长、并发流、预热跳过时间：

```bash
sudo BENCH_TIME=30 BENCH_PARALLEL=8 BENCH_OMIT=5 bash kcc.sh bench <服务端IP>
```

服务端绑定指定网卡 IP：

```bash
sudo IPERF_BIND=10.0.0.2 bash kcc.sh server
```

显示 KCC 编译细节：

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
| `KCC_DEBUG`      |                                        空 | 显示编译日志          |
| `NO_COLOR`       |                                        空 | 关闭彩色输出          |

## 查看状态

```bash
bash kcc.sh status
```

主要看这几项：

```text
当前算法
可用算法
默认 qdisc
KCC 模块
iperf3
```

如果 `可用算法` 里没有 `kcc`，说明 KCC 没有成功注册，脚本会使用 `bbr` 回退。

## 卸载

```bash
sudo bash kcc.sh uninstall
```

或者：

```bash
sudo bash uninstall.sh
```

卸载会恢复拥塞算法为 `cubic`，删除脚本写入的 sysctl 配置和 KCC 模块加载配置。

## 自动安装失败时手动编译

只在 `sudo bash kcc.sh install` 编译失败时使用。

```bash
cd kcc-iperf3/kcc-iperf3
git clone https://github.com/liulilittle/kcc.git src
```

查看 `src/` 里的实际 `.c` 文件名，然后修改 `Makefile` 顶部的 `MODULE`：

```makefile
MODULE ?= kcc
```

编译并加载：

```bash
make
sudo make load
sudo make install-cc
```

清理编译产物：

```bash
make clean
```

卸载手动加载的模块：

```bash
sudo make unload
```

## 使用要求

* 需要 Linux。
* `install` / `server` / `bench` / `uninstall` 建议用 root 执行。
* 服务端和客户端都建议跑一次 `install`。
* 服务端需要放行 TCP `5201`，自定义端口时放行对应端口。
* 容器环境通常不能加载内核模块；KCC 不可用时会回退到 `bbr`。
