# 手动编译 KCC 内核模块（当一键脚本自动编译失败时使用）
#
#   1) 先把 liulilittle/kcc 源码克隆到 src/ ：
#        git clone https://github.com/liulilittle/kcc.git src
#   2) 确认源码里拥塞控制 .c 文件名，并修改下面的 MODULE 变量
#   3) make            # 编译
#   4) sudo make load  # 加载
#   5) sudo make install-cc  # 设为默认拥塞算法
#
# 说明：内核模块需对应当前运行内核的头文件（linux-headers / kernel-devel）。

MODULE ?= kcc
SRCDIR ?= src
KDIR   ?= /lib/modules/$(shell uname -r)/build
PWD    := $(shell pwd)

obj-m += $(MODULE).o

.PHONY: all clean load unload install-cc

all:
	$(MAKE) -C $(KDIR) M=$(PWD)/$(SRCDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD)/$(SRCDIR) clean

load:
	sudo insmod $(SRCDIR)/$(MODULE).ko || sudo modprobe $(MODULE)
	@echo "可用算法: $$(sysctl -n net.ipv4.tcp_available_congestion_control)"

unload:
	sudo rmmod $(MODULE)

install-cc:
	sudo sysctl -w net.core.default_qdisc=fq
	sudo sysctl -w net.ipv4.tcp_congestion_control=$(MODULE)
	@echo "当前算法: $$(sysctl -n net.ipv4.tcp_congestion_control)"
