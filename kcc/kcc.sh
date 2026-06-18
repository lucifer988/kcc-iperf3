#!/usr/bin/env bash
#
# kcc.sh —— 一键安装 KCC（卡尔曼滤波 BBR 变种）内核拥塞控制 + iperf3 调优测速
#
# 项目灵感来源：
#   - liulilittle/kcc   (Linux 内核 TCP 拥塞控制模块 / BBR + Kalman Filter)
#   - lucifer988/iperf3 (iperf3 一键测速脚本)
#
# 用法：
#   sudo bash kcc.sh                 # 进入交互菜单
#   sudo bash kcc.sh install         # 一键安装：依赖 + 编译加载 KCC + 内核调优
#   sudo bash kcc.sh server          # 作为 iperf3 服务端运行
#   sudo bash kcc.sh client <对端IP> # 作为 iperf3 客户端跑测试
#   sudo bash kcc.sh bench <对端IP>  # 基准对比：cubic vs bbr vs kcc
#   sudo bash kcc.sh status          # 查看当前拥塞算法 / qdisc / 模块状态
#   sudo bash kcc.sh uninstall       # 卸载并还原内核参数
#
# 远程一键（在你 fork 后替换 USER/REPO）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/kcc/main/kcc.sh) install
#
set -euo pipefail

# ------------------------------------------------------------------ 配置区 ----
KCC_REPO="${KCC_REPO:-https://github.com/liulilittle/kcc.git}"   # KCC 源码仓库
KCC_BRANCH="${KCC_BRANCH:-}"                                     # 可选指定分支
WORK_DIR="${WORK_DIR:-/usr/local/src/kcc}"                       # 源码编译目录
SYSCTL_FILE="/etc/sysctl.d/99-kcc.conf"
MODLOAD_FILE="/etc/modules-load.d/kcc.conf"
FALLBACK_CC="bbr"                                                # KCC 编译失败时回退算法
IPERF_PORT="${IPERF_PORT:-5201}"
BENCH_TIME="${BENCH_TIME:-15}"                                   # 每轮测试秒数
BENCH_PARALLEL="${BENCH_PARALLEL:-4}"                            # 并发流数量

# ------------------------------------------------------------------ 工具函数 --
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
log()  { echo "${BLU}[*]${RST} $*"; }
ok()   { echo "${GRN}[✓]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*"; }
err()  { echo "${RED}[✗]${RST} $*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo bash $0 $*"
}

have() { command -v "$1" >/dev/null 2>&1; }

# 检测发行版与包管理器
detect_os() {
  if [ -r /etc/os-release ]; then . /etc/os-release; OS_ID="${ID:-unknown}"; else OS_ID="unknown"; fi
  if   have apt-get; then PM="apt";  
  elif have dnf;     then PM="dnf";  
  elif have yum;     then PM="yum";  
  elif have pacman;  then PM="pacman";
  elif have zypper;  then PM="zypper";
  else PM="unknown"; fi
}

pkg_install() {
  case "$PM" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)    dnf install -y "$@" ;;
    yum)    yum install -y "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    zypper) zypper --non-interactive install "$@" ;;
    *)      die "无法识别包管理器，请手动安装：$*" ;;
  esac
}

# 安装编译依赖 + iperf3
install_deps() {
  log "安装编译依赖与 iperf3 ..."
  local headers="linux-headers-$(uname -r)"
  case "$PM" in
    apt)    pkg_install build-essential gcc make git iperf3 dkms curl "$headers" \
              || pkg_install build-essential gcc make git iperf3 dkms curl linux-headers-generic ;;
    dnf|yum)
            pkg_install gcc make git iperf3 dkms curl "kernel-devel-$(uname -r)" elfutils-libelf-devel \
              || pkg_install gcc make git iperf3 dkms curl kernel-devel elfutils-libelf-devel ;;
    pacman) pkg_install base-devel git iperf3 dkms curl linux-headers ;;
    zypper) pkg_install gcc make git iperf3 dkms curl kernel-default-devel ;;
    *)      die "请手动安装：gcc make git iperf3 dkms 以及对应内核头文件" ;;
  esac
  ok "依赖安装完成"
}

# ------------------------------------------------------------- 编译加载 KCC --
# 拉取（或更新）KCC 源码
fetch_source() {
  if [ -d "$WORK_DIR/.git" ]; then
    log "更新 KCC 源码：$WORK_DIR"
    git -C "$WORK_DIR" pull --ff-only || warn "更新失败，沿用现有源码"
  else
    log "克隆 KCC 源码：$KCC_REPO"
    rm -rf "$WORK_DIR"
    if [ -n "$KCC_BRANCH" ]; then
      git clone --depth 1 -b "$KCC_BRANCH" "$KCC_REPO" "$WORK_DIR"
    else
      git clone --depth 1 "$KCC_REPO" "$WORK_DIR"
    fi
  fi
}

# 在源码树中找到拥塞控制的 .c 源文件（含 tcp_register_congestion_control 调用）
find_cc_source() {
  local f
  f="$(grep -rlsE 'tcp_register_congestion_control' "$WORK_DIR" --include='*.c' 2>/dev/null | head -n1 || true)"
  [ -z "$f" ] && f="$(find "$WORK_DIR" -maxdepth 3 -name '*.c' | grep -iE 'kcc|bbr|cong' | head -n1 || true)"
  echo "$f"
}

# 编译内核模块
build_module() {
  local kdir="/lib/modules/$(uname -r)/build"
  [ -d "$kdir" ] || die "找不到内核头文件目录 $kdir，请确认已安装 linux-headers / kernel-devel"

  log "编译 KCC 内核模块 ..."
  # 1) 仓库自带 Makefile 时优先使用
  if [ -f "$WORK_DIR/Makefile" ] && grep -qiE 'obj-m|modules' "$WORK_DIR/Makefile"; then
    if make -C "$kdir" M="$WORK_DIR" modules 2>/dev/null || make -C "$WORK_DIR" 2>/dev/null; then
      :
    fi
  fi

  # 2) 若未产出 .ko，则自动定位源文件并生成 Makefile 现编
  if ! find "$WORK_DIR" -name '*.ko' | grep -q .; then
    local src; src="$(find_cc_source)"
    [ -z "$src" ] && die "未能在仓库中定位拥塞控制源文件，请检查仓库结构后用 make 手动编译"
    local dir base; dir="$(dirname "$src")"; base="$(basename "${src%.c}")"
    log "使用源文件：$src"
    printf 'obj-m += %s.o\n' "$base" > "$dir/Makefile.kcc"
    make -C "$kdir" M="$dir" -f "$dir/Makefile.kcc" modules \
      || make -C "$kdir" M="$dir" obj-m="${base}.o" modules
  fi

  KO_PATH="$(find "$WORK_DIR" -name '*.ko' | head -n1)"
  [ -n "$KO_PATH" ] || die "编译未产出 .ko 模块"
  KO_NAME="$(basename "${KO_PATH%.ko}")"
  ok "编译成功：$KO_PATH (模块名 $KO_NAME)"
}

# 安装模块到系统并加载，自动探测注册的拥塞算法名
load_module() {
  local moddir="/lib/modules/$(uname -r)/kernel/net/ipv4"
  mkdir -p "$moddir"
  install -m 0644 "$KO_PATH" "$moddir/"
  depmod -a

  local before after
  before="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '')"
  modprobe "$KO_NAME" 2>/dev/null || insmod "$KO_PATH" 2>/dev/null || true
  after="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '')"

  # 对比前后新增的算法名即为 KCC 注册名
  CC_NAME="$(comm -13 <(echo "$before" | tr ' ' '\n' | sort -u) \
                       <(echo "$after"  | tr ' ' '\n' | sort -u) | head -n1)"
  [ -z "$CC_NAME" ] && CC_NAME="kcc"

  if echo "$after" | grep -qw "$CC_NAME"; then
    ok "KCC 模块已加载，注册拥塞算法：${BLD}$CC_NAME${RST}"
    echo "$KO_NAME" > "$MODLOAD_FILE"
  else
    warn "KCC 未能注册到内核（内核版本可能不兼容），将回退到 ${FALLBACK_CC}"
    CC_NAME="$FALLBACK_CC"
    modprobe tcp_bbr 2>/dev/null || true
  fi
}

# 尝试用 DKMS 实现内核升级后自动重编（best-effort，失败不影响）
setup_dkms() {
  have dkms || return 0
  local ver="1.0"
  local dst="/usr/src/${KO_NAME}-${ver}"
  rm -rf "$dst"; mkdir -p "$dst"
  cp -r "$WORK_DIR"/. "$dst"/ 2>/dev/null || true
  cat > "$dst/dkms.conf" <<EOF
PACKAGE_NAME="$KO_NAME"
PACKAGE_VERSION="$ver"
BUILT_MODULE_NAME[0]="$KO_NAME"
DEST_MODULE_LOCATION[0]="/kernel/net/ipv4"
AUTOINSTALL="yes"
MAKE[0]="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/${KO_NAME}/${ver}/build modules"
CLEAN="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/${KO_NAME}/${ver}/build clean"
EOF
  if dkms add -m "$KO_NAME" -v "$ver" 2>/dev/null \
     && dkms build -m "$KO_NAME" -v "$ver" 2>/dev/null \
     && dkms install -m "$KO_NAME" -v "$ver" 2>/dev/null; then
    ok "DKMS 注册成功，内核升级后将自动重编 $KO_NAME"
  else
    warn "DKMS 注册失败（不影响当前使用），内核升级后可重跑本脚本 install"
  fi
}

# ----------------------------------------------------------------- 内核调优 --
# 应用 sysctl 调优 + 设定拥塞算法（双端均应执行）
apply_tuning() {
  local cc="${1:-$CC_NAME}"
  log "应用内核网络调优，拥塞算法 = $cc，qdisc = fq ..."
  cat > "$SYSCTL_FILE" <<EOF
# ===== KCC 网络调优（高吞吐 / 低重传） =====
net.core.default_qdisc            = fq
net.ipv4.tcp_congestion_control   = $cc

# 收发缓冲区上限（提升大带宽时延积链路吞吐）
net.core.rmem_max                 = 67108864
net.core.wmem_max                 = 67108864
net.core.netdev_max_backlog       = 250000
net.core.somaxconn                = 8192

net.ipv4.tcp_rmem                 = 4096 87380 67108864
net.ipv4.tcp_wmem                 = 4096 65536 67108864
net.ipv4.tcp_mtu_probing          = 1
net.ipv4.tcp_window_scaling       = 1
net.ipv4.tcp_sack                 = 1
net.ipv4.tcp_fastopen             = 3
net.ipv4.tcp_slow_start_after_idle= 0
net.ipv4.tcp_notsent_lowat        = 16384
net.ipv4.tcp_no_metrics_save      = 1
EOF
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

  # 校验是否真正生效，否则回退
  local now; now="$(sysctl -n net.ipv4.tcp_congestion_control)"
  if [ "$now" != "$cc" ]; then
    warn "拥塞算法 $cc 未生效（当前 $now），回退到 $FALLBACK_CC"
    sysctl -w net.ipv4.tcp_congestion_control="$FALLBACK_CC" >/dev/null 2>&1 || true
    sed -i "s/^net.ipv4.tcp_congestion_control.*/net.ipv4.tcp_congestion_control   = $FALLBACK_CC/" "$SYSCTL_FILE"
  fi
  ok "调优完成，当前拥塞算法：${BLD}$(sysctl -n net.ipv4.tcp_congestion_control)${RST}"
}

# ------------------------------------------------------------------- 测速 ----
# 解析 iperf3 JSON，输出 "吞吐(Mbps) 重传次数"
parse_iperf() {
  local json="$1"
  if have python3; then
    python3 - "$json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
s=d.get("end",{}).get("sum_sent",d.get("end",{}).get("sum",{}))
bps=s.get("bits_per_second",0)
retr=s.get("retransmits",0)
print("%.2f %s" % (bps/1e6, retr if retr is not None else 0))
PY
  else
    local bps retr
    bps="$(grep -oE '"bits_per_second":[0-9.]+' "$json" | tail -n1 | cut -d: -f2)"
    retr="$(grep -oE '"retransmits":[0-9]+' "$json" | tail -n1 | cut -d: -f2)"
    awk -v b="${bps:-0}" -v r="${retr:-0}" 'BEGIN{printf "%.2f %s\n", b/1e6, r}'
  fi
}

run_server() {
  need_root
  have iperf3 || { detect_os; install_deps; }
  log "启动 iperf3 服务端，端口 $IPERF_PORT（Ctrl+C 退出）"
  warn "提示：服务端也建议先执行 install 完成内核调优，双端同时调优效果最佳"
  exec iperf3 -s -p "$IPERF_PORT"
}

run_client() {
  local ip="$1"; local cc="${2:-}"
  have iperf3 || { detect_os; install_deps; }
  [ -n "$ip" ] || die "请提供对端 IP：sudo bash $0 client <对端IP>"
  local extra=""; [ -n "$cc" ] && extra="-C $cc"
  log "向 $ip:$IPERF_PORT 发起测试（${BENCH_TIME}s，并发 ${BENCH_PARALLEL} 流）${cc:+，算法=$cc}"
  iperf3 -c "$ip" -p "$IPERF_PORT" -t "$BENCH_TIME" -P "$BENCH_PARALLEL" $extra
}

# 基准对比：分别用 cubic / bbr / kcc 测一轮并打表
benchmark() {
  need_root
  local ip="$1"
  [ -n "$ip" ] || die "请提供对端 IP：sudo bash $0 bench <对端IP>"
  have iperf3 || { detect_os; install_deps; }

  local avail; avail="$(sysctl -n net.ipv4.tcp_available_congestion_control)"
  local algos=() a
  for a in cubic "$FALLBACK_CC" "${CC_NAME:-kcc}"; do
    echo "$avail" | grep -qw "$a" && ! printf '%s\n' "${algos[@]:-}" | grep -qx "$a" && algos+=("$a")
  done
  [ "${#algos[@]}" -gt 0 ] || algos=(cubic)

  log "对端 $ip —— 基准对比开始（每个算法 ${BENCH_TIME}s × ${BENCH_PARALLEL} 流）"
  printf '\n%-12s %16s %12s\n' "算法" "吞吐(Mbps)" "重传次数"
  printf -- '-------------------------------------------\n'
  local tmp base_thr=""
  for a in "${algos[@]}"; do
    tmp="$(mktemp)"
    if iperf3 -c "$ip" -p "$IPERF_PORT" -t "$BENCH_TIME" -P "$BENCH_PARALLEL" -C "$a" -J >"$tmp" 2>/dev/null; then
      read -r thr retr < <(parse_iperf "$tmp")
      local mark=""
      [ "$a" = "${CC_NAME:-kcc}" ] && mark="${GRN}  ← KCC${RST}"
      printf '%-12s %16s %12s%s\n' "$a" "$thr" "$retr" "$mark"
    else
      printf '%-12s %16s %12s\n' "$a" "失败" "-"
    fi
    rm -f "$tmp"; sleep 2
  done
  printf -- '-------------------------------------------\n'
  echo "${YLW}注：重传越低、吞吐越高越好。KCC 在高丢包/高时延链路上的优势通常更明显。${RST}"
}

# ------------------------------------------------------------------ 状态/卸载 -
show_status() {
  detect_os
  echo "${BLD}===== KCC / 内核网络状态 =====${RST}"
  echo "内核版本   : $(uname -r)"
  echo "当前算法   : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo "可用算法   : $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
  echo "默认 qdisc : $(sysctl -n net.core.default_qdisc 2>/dev/null)"
  echo -n "KCC 模块   : "
  if lsmod | grep -qiE 'kcc'; then ok "已加载 ($(lsmod | grep -i kcc | awk '{print $1}' | head -n1))"
  else warn "未加载"; fi
  echo -n "iperf3     : "; have iperf3 && iperf3 --version 2>/dev/null | head -n1 || echo "未安装"
}

uninstall() {
  need_root
  log "卸载 KCC 并还原内核参数 ..."
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  for m in $(lsmod | awk '/kcc/{print $1}'); do rmmod "$m" 2>/dev/null || true; done
  have dkms && dkms remove -m "${KO_NAME:-kcc}" -v 1.0 --all 2>/dev/null || true
  rm -f "$SYSCTL_FILE" "$MODLOAD_FILE"
  find /lib/modules/"$(uname -r)"/kernel/net/ipv4 -iname '*kcc*' -delete 2>/dev/null || true
  depmod -a 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  ok "已卸载并还原（拥塞算法恢复 cubic）。源码目录 $WORK_DIR 保留，可手动删除。"
}

# 完整一键安装流程
do_install() {
  need_root install
  detect_os
  log "检测到系统：${OS_ID} / 包管理器：${PM} / 内核：$(uname -r)"
  install_deps
  fetch_source
  if build_module; then
    load_module
    setup_dkms
  else
    warn "KCC 编译失败，回退到 $FALLBACK_CC 以保证仍有调优效果"
    CC_NAME="$FALLBACK_CC"
    modprobe tcp_bbr 2>/dev/null || true
  fi
  apply_tuning "$CC_NAME"
  echo
  ok "${BLD}安装完成！${RST}"
  echo "下一步："
  echo "  · 在【服务端】机器执行：  sudo bash $0 server"
  echo "  · 在【客户端】机器执行：  sudo bash $0 bench <服务端IP>"
  echo "  · 务必在双端都执行 install，双端内核同时调优效果最佳。"
}

# ------------------------------------------------------------------- 菜单 ----
menu() {
  detect_os
  CC_NAME="${CC_NAME:-kcc}"
  while true; do
    echo
    echo "${BLD}========= KCC 一键内核调优 / iperf3 测速 =========${RST}"
    echo " 1) 一键安装（依赖 + 编译加载 KCC + 双端调优）"
    echo " 2) 作为 iperf3 服务端运行"
    echo " 3) 作为 iperf3 客户端测试"
    echo " 4) 基准对比 cubic / bbr / kcc"
    echo " 5) 查看状态"
    echo " 6) 卸载还原"
    echo " 0) 退出"
    echo "=================================================="
    read -rp "请选择: " c
    case "$c" in
      1) do_install ;;
      2) run_server ;;
      3) read -rp "对端 IP: " ip; run_client "$ip" ;;
      4) read -rp "对端 IP: " ip; benchmark "$ip" ;;
      5) show_status ;;
      6) uninstall ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ------------------------------------------------------------------- 入口 ----
main() {
  local cmd="${1:-menu}"; shift || true
  case "$cmd" in
    install)   do_install ;;
    server)    run_server ;;
    client)    run_client "${1:-}" "${2:-}" ;;
    bench)     CC_NAME="${CC_NAME:-kcc}"; benchmark "${1:-}" ;;
    status)    show_status ;;
    uninstall) uninstall ;;
    menu|"")   menu ;;
    *)         die "未知命令：$cmd（可用：install/server/client/bench/status/uninstall）" ;;
  esac
}
main "$@"
