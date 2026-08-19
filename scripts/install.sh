#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# NodeFetch Node Agent - Linux TUI 一键安装 & 运维向导
#
#   bash <(curl -fsSL https://xxx/install.sh)   # 或者
#   chmod +x scripts/install.sh && scripts/install.sh
#
# 特色：
#   • 主菜单驱动：Install Wizard / Start/Stop/Restart / Status / Logs / Tools / Uninstall
#   • 自动检测发行版：apt(Debian/Ubuntu) · dnf(Fedora/RHEL) · yum(CentOS) · pacman(Arch) · brew(macOS)
#   • 安装全幂等：已装的系统包/venv/依赖/配置全部跳过
#   • 强制 venv 安装：绝不把 Python 依赖写到系统 Python / --system
#   • 统一 runtime 目录：<PROJECT>/runtime/{pids,logs,aria2.session}
#   • 支持 PIP_MIRROR=tuna / aliyun / 自定义
#   • 健康检查不绑定端口：aria2 走 JSON-RPC HTTP，node 走 /api/node/health
#   • 安装失败：把最后 30 行日志摘要打到屏幕；每一步都可回主菜单重试
# -----------------------------------------------------------------------------
set -euo pipefail

# ---------- 基础路径 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNTIME_DIR="${RUNTIME_DIR:-${PROJECT_DIR}/runtime}"
ENV_FILE="${PROJECT_DIR}/.env"
PID_DIR="${RUNTIME_DIR}/pids"
LOG_DIR="${RUNTIME_DIR}/logs"
SESSION_FILE="${RUNTIME_DIR}/aria2.session"
mkdir -p "$PID_DIR" "$LOG_DIR"
touch "$SESSION_FILE"

# 读已有 .env（安装第二步生成后，后续菜单都能读到配置）
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE" || true
  set +a
fi

# ---------- 输出 TUI 风格 ----------
if [[ -t 1 ]]; then
  R=$'\033[0m'; B=$'\033[1m'; U=$'\033[4m'
  FG=$'\033[38;5;255m'; BG_BLUE=$'\033[48;5;17m'; BG_GREEN=$'\033[48;5;22m'
  BG_GRAY=$'\033[48;5;235m'; FG_GREEN=$'\033[38;5;46m'; FG_RED=$'\033[38;5;196m'
  FG_YELLOW=$'\033[38;5;226m'; FG_CYAN=$'\033[38;5;51m'; FG_DIM=$'\033[38;5;243m'
else
  R=''; B=''; U=''; FG=''; BG_BLUE=''; BG_GREEN=''; BG_GRAY=''
  FG_GREEN=''; FG_RED=''; FG_YELLOW=''; FG_CYAN=''; FG_DIM=''
fi

tcols() {
  local c
  c="$(tput cols 2>/dev/null || echo 100)"
  # 限制宽度，避免超大屏幕下标题过于分散
  (( c > 110 )) && c=110
  echo "$c"
}

bar()  { local w=$(tcols); printf '%*s\n' "$w" '' | tr ' ' '─'; }
boldbar() { local w=$(tcols); printf '%*s\n' "$w" '' | tr ' ' '═'; }

section_title() {
  local w=$(tcols) t="$*" pad
  pad=$(( (w - ${#t} - 2) / 2 ))
  printf '%s' "${BG_BLUE}${B}${FG}"
  printf '%*s' "$pad" ''; printf ' %s ' "$t"; printf '%*s' "$(( w - pad - ${#t} - 2 ))" ''
  printf '%s\n' "$R"
}

banner() {
  local w=$(tcols)
  boldbar
  printf '  %s %s%s  %s%sNode Agent%s  -  %sTUI Installer & Manager%s\n' \
    "${B}${FG_YELLOW}◆${R}" \
    "${B}${FG_CYAN}NodeFetch${R}" \
    "${FG_DIM}│${R}" \
    "${B}${FG_GREEN}" "$R" \
    "${FG_DIM}" "$R"
  printf '  %s project: %s%s%s  runtime: %s%s%s\n' \
    "${FG_DIM}·${R}" "${B}" "${PROJECT_DIR}" "${R}" \
    "${B}" "${RUNTIME_DIR}" "${R}"
  boldbar
}

# 彩色 check/x/warn/info
ok()   { printf '  %s%s OK%s  %s\n'  "${B}${FG_GREEN}"  '✓' "$R" "$*"; }
warn() { printf '  %s%s WRN%s %s\n'  "${B}${FG_YELLOW}" '!' "$R" "$*"; }
err()  { printf '  %s%s ERR%s %s\n'  "${B}${FG_RED}"   '✗' "$R" "$*"; }
info() { printf '  %s%s INF%s %s\n'  "${B}${FG_CYAN}"  '·' "$R" "$*"; }

step() {
  local n="$1"; shift
  printf '\n  %s[STEP %s] %s%s%s\n' "${B}${FG_CYAN}" "$n" "${B}" "$*" "$R"
  bar
}

press_enter() {
  local prompt="${1:-按 Enter 回到主菜单...}"
  printf '\n  %s' "$prompt"
  local _
  read -r _ || true
}

# ---------- 用户交互工具 ----------
ask() {
  # ask <label> <default>
  local label="$1" def="$2" val
  printf '  %s %s%s%s %s[%s]%s: ' \
    "${FG_CYAN}?${R}" "${B}" "$label" "${R}" \
    "${FG_DIM}" "$def" "$R"
  read -r val || true
  if [[ -z "$val" ]]; then printf '%s' "$def"; else printf '%s' "$val"; fi
}
ask_yesno() {
  local label="$1" def="${2:-Y}" hint
  case "$def" in
    Y|y) hint="[Y/n]" ;;
    N|n) hint="[y/N]" ;;
  esac
  local ans
  while true; do
    printf '  %s %s%s%s %s: ' "${FG_CYAN}?${R}" "${B}" "$label" "$hint" "$R"
    read -r ans || true
    ans="${ans:-$def}"
    case "$ans" in
      Y|y|Yes|yes) return 0 ;;
      N|n|No|no)   return 1 ;;
    esac
  done
}

# 列表菜单：choices 数组，返回选中的索引（0-based）
menu() {
  local title="$1" i=0 choice_lines
  shift
  local -a items=( "$@" )
  local -a desc=()
  # 每项可能用 "label|hint" 格式
  local w=$(tcols)
  printf '\n  %s%s%s\n' "${B}" "$title" "$R"
  for line in "${items[@]}"; do
    if [[ "$line" == *'|'* ]]; then
      desc+=("${line#*|}")
      line="${line%%|*}"
    else
      desc+=("")
    fi
    items[$i]="$line"
    if [[ -n "${desc[$i]}" ]]; then
      printf '    %s%2d%s %-30s %s%s%s\n' \
        "${B}${FG_YELLOW}" "$(( i+1 ))" "$R" \
        "$line" "${FG_DIM}" "${desc[$i]}" "$R"
    else
      printf '    %s%2d%s %s\n' "${B}${FG_YELLOW}" "$(( i+1 ))" "$R" "$line"
    fi
    i=$(( i+1 ))
  done
  local sel
  while true; do
    printf '  %s请选择序号 %s[1-%d]%s: ' "${FG_CYAN}>${R}" "${FG_DIM}" "$i" "$R"
    read -r sel || true
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )); then
      echo "$(( sel - 1 ))"
      return 0
    fi
  done
}

# ---------- 系统 & 工具检测 ----------
detect_distro() {
  local os="unknown" pkg="" sudo_cmd=""
  if command -v sw_vers >/dev/null 2>&1; then
    os="macos"
    pkg="brew"
  elif command -v apt-get >/dev/null 2>&1; then
    os="debian"
    pkg="apt"
  elif command -v dnf >/dev/null 2>&1; then
    os="fedora"
    pkg="dnf"
  elif command -v yum >/dev/null 2>&1; then
    os="centos"
    pkg="yum"
  elif command -v pacman >/dev/null 2>&1; then
    os="arch"
    pkg="pacman"
  fi
  if sudo -n true 2>/dev/null; then sudo_cmd="sudo -n"; else sudo_cmd="sudo"; fi
  echo "$os|$pkg|$sudo_cmd"
}

# 系统依赖按包管理器
SYS_DEBS=(aria2 curl ca-certificates git python3 python3-pip python3-venv)
SYS_RPMS=(aria2 curl ca-certificates git python3 python3-pip)
SYS_ARCH=(aria2 curl ca-certificates git python)
SYS_BREW=(aria2 curl ca-certificates git python)

install_system_packages() {
  step "1/6" "检测发行版并安装系统级依赖（aria2 / curl / python3 / git 等）"
  local info os pkg sudo_cmd
  info="$(detect_distro)"
  os="${info%%|*}"; info="${info#*|}"
  pkg="${info%%|*}"; sudo_cmd="${info#*|}"

  local -a all_missing=() pkg_cmd=()
  case "$pkg" in
    apt)
      info "发行版: Debian/Ubuntu (apt)"
      for p in "${SYS_DEBS[@]}"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then all_missing+=("$p"); fi
      done
      pkg_cmd=("${sudo_cmd}" apt-get install -y --no-install-recommends)
      ;;
    dnf)
      info "发行版: Fedora/RHEL (dnf)"
      for p in "${SYS_RPMS[@]}"; do
        if ! rpm -q "$p" >/dev/null 2>&1; then all_missing+=("$p"); fi
      done
      pkg_cmd=("${sudo_cmd}" dnf install -y)
      # RHEL9 python3-venv 是独立包；pip 也可能需要单独装
      for extra in python3-virtualenv python3-pip; do
        if ! dnf list installed "$extra" >/dev/null 2>&1; then all_missing+=("$extra"); fi
      done
      ;;
    yum)
      info "发行版: CentOS (yum)"
      for p in "${SYS_RPMS[@]}"; do
        if ! rpm -q "$p" >/dev/null 2>&1; then all_missing+=("$p"); fi
      done
      pkg_cmd=("${sudo_cmd}" yum install -y)
      ;;
    pacman)
      info "发行版: Arch (pacman)"
      for p in "${SYS_ARCH[@]}"; do
        if ! pacman -Qq "$p" >/dev/null 2>&1; then all_missing+=("$p"); fi
      done
      pkg_cmd=("${sudo_cmd}" pacman -Sy --noconfirm)
      ;;
    brew)
      info "系统: macOS (Homebrew)"
      for p in "${SYS_BREW[@]}"; do
        if ! brew list --versions "$p" >/dev/null 2>&1; then all_missing+=("$p"); fi
      done
      pkg_cmd=(brew install)
      ;;
    *)
      warn "未能识别包管理器。请手动安装：aria2、curl、git、python3（含 venv + pip）、ca-certificates"
      return 0
      ;;
  esac

  if (( ${#all_missing[@]} == 0 )); then
    ok "系统包全部已就绪，无需安装"
    return 0
  fi

  info "缺少的包：${all_missing[*]}"
  if ask_yesno "安装这些系统包（需要 sudo 或密码提示）？" Y; then
    if [[ "$pkg" == "apt" ]]; then
      info "apt-get update（用于刷新源索引，可能需要 sudo 密码）..."
      "${sudo_cmd}" apt-get update -y >/dev/null 2>&1 || warn "apt update 失败，继续尝试安装"
    fi
    echo
    info "执行：${pkg_cmd[*]} ${all_missing[*]}"
    set +e
    "${pkg_cmd[@]}" "${all_missing[@]}"
    local rc=$?
    set -e
    if (( rc == 0 )); then ok "系统依赖安装成功"; else err "系统包安装退出码=$rc，稍后可重试"; return 1; fi
  else
    warn "用户跳过系统包安装。下一步可能失败。"
  fi
}

# ---------- venv ----------
PYTHON_BIN=""
VENV_DIR="${VENV_DIR:-${PROJECT_DIR}/.venv}"

ensure_python_bin() {
  if [[ -x "${VENV_DIR}/bin/python" ]]; then
    PYTHON_BIN="${VENV_DIR}/bin/python"
  elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
  else
    PYTHON_BIN=""
  fi
}

create_or_reuse_venv() {
  step "2/6" "创建 Python 虚拟环境（绝不把依赖装到系统 Python）"
  ensure_python_bin
  if [[ -x "${VENV_DIR}/bin/python" ]]; then
    ok "已存在 venv：${VENV_DIR}（重用，跳过创建）"
    PYTHON_BIN="${VENV_DIR}/bin/python"
    return 0
  fi
  # 选创建 venv 用的 python
  local py=""
  if   command -v python3 >/dev/null 2>&1; then py="python3"
  elif command -v python  >/dev/null 2>&1; then py="python"
  else err "未找到 python3/python，先执行步骤 1 或手动装"; return 1; fi

  info "使用：$py -m venv $VENV_DIR"
  set +e
  "$py" -m venv "$VENV_DIR"
  local rc=$?
  set -e
  if (( rc != 0 )) || [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    err "创建 venv 失败。Ubuntu/Debian 请先装 python3-venv：sudo apt install python3-venv"
    return 1
  fi
  PYTHON_BIN="${VENV_DIR}/bin/python"
  # 升级 pip（pip 过老可能装不了新的包）
  info "升级 venv 内的 pip/setuptools/wheel..."
  "$PYTHON_BIN" -m pip install --quiet --upgrade pip setuptools wheel >/dev/null 2>&1 || true
  ok "venv 创建成功：${VENV_DIR}"
}

# ---------- pip install ----------
PIP_REQUIREMENTS="${PROJECT_DIR}/requirements.txt"

install_pip_deps() {
  step "3/6" "安装 Python 依赖（fastapi / uvicorn / sqlalchemy / httpx 等）"
  create_or_reuse_venv >/dev/null || true
  if [[ ! -x "$PYTHON_BIN" ]]; then err "venv python 不可用，先执行步骤 2"; return 1; fi
  if [[ ! -f "$PIP_REQUIREMENTS" ]]; then err "缺失：${PIP_REQUIREMENTS}"; return 1; fi

  # 快速检查是否全齐（import 关键模块），省得重装花时间
  if "$PYTHON_BIN" -c 'import fastapi, uvicorn, sqlalchemy, aiosqlite, pydantic_settings, httpx' >/dev/null 2>&1; then
    ok "核心 pip 依赖已齐全，跳过 pip install（如想强制升级，选菜单里的 Upgrade deps）"
    return 0
  fi

  # 镜像选择
  local pip_args=()
  case "${PIP_MIRROR:-ask}" in
    tuna)   pip_args+=(-i https://pypi.tuna.tsinghua.edu.cn/simple) ;;
    aliyun) pip_args+=(-i https://mirrors.aliyun.com/pypi/simple/) ;;
    pypi)   ;;
    ask|"")
      local m
      m="$(menu "选择 PyPI 镜像（网络国内建议清华，海外用 PyPI）" \
        "TUNA 清华镜像|推荐国内" \
        "Aliyun 镜像|阿里云" \
        "官方 PyPI|默认/海外" )"
      case "$m" in
        0) pip_args+=(-i https://pypi.tuna.tsinghua.edu.cn/simple); export PIP_MIRROR=tuna ;;
        1) pip_args+=(-i https://mirrors.aliyun.com/pypi/simple/); export PIP_MIRROR=aliyun ;;
        *) export PIP_MIRROR=pypi ;;
      esac
      ;;
  esac

  info "执行：${PYTHON_BIN} -m pip install ${pip_args[*]:-} -r ${PIP_REQUIREMENTS}"
  set +e
  "$PYTHON_BIN" -m pip install --quiet "${pip_args[@]}" -r "$PIP_REQUIREMENTS"
  local rc=$?
  set -e
  if (( rc != 0 )); then
    err "pip install 失败（退出码=$rc）。日志摘要："
    # 重新跑一遍不带 --quiet，输出到 log 让用户看
    local plog="${LOG_DIR}/pip-install.log"
    warn "重试 verbose 模式并写入 $plog ..."
    "$PYTHON_BIN" -m pip install "${pip_args[@]}" -r "$PIP_REQUIREMENTS" >"$plog" 2>&1 || true
    tail -n 30 "$plog" | sed 's/^/     | /'
    return 1
  fi
  ok "pip 依赖安装成功"
}

# ---------- 生成 .env ----------
# 默认值与 Agent.md/.env.example 一致
generate_env() {
  step "4/6" "生成项目配置（${ENV_FILE}）— 已存在的键不会被覆盖，可单独改"
  create_or_reuse_venv >/dev/null || true

  # 交互采集：每次都显示当前值作为默认（.env 已存在时 source 过变量）
  local node_port aria2_port aria2_secret dl_dir ttl quota_gb node_id node_token center_url
  node_port="$(ask "Node 监听端口（NODE_PORT）"                     "${NODE_PORT:-8000}")"
  aria2_port="$(ask "Aria2 RPC 端口（ARIA2_RPC_PORT）"               "${ARIA2_RPC_PORT:-6800}")"
  aria2_secret="$(ask "Aria2 RPC 密钥（ARIA2_RPC_SECRET）"           "${ARIA2_RPC_SECRET:-nodefetch_secret}")"
  dl_dir="$(ask     "下载文件目录（NODE_DOWNLOAD_DIR）"              "${NODE_DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}")"
  ttl="$(ask        "任务存活 TTL 秒（过期删除，NODE_TTL_SECONDS）"   "${NODE_TTL_SECONDS:-86400}")"
  quota_gb="$(ask   "存储配额 GB（NODE_STORAGE_LIMIT_GB）"           "${NODE_STORAGE_LIMIT_GB:-10}")"
  node_id="$(ask    "本节点 ID（NODE_ID，英文/数字/-_）"              "${NODE_ID:-node-01}")"
  node_token="$(ask "本节点 Token（NODE_TOKEN，向中心注册用，无中心可留空）" "${NODE_TOKEN:-}")"
  center_url="$(ask "中心 URL（CENTER_URL，无中心可留空）"            "${CENTER_URL:-}")"

  mkdir -p "$dl_dir"
  if [[ ! -f "$ENV_FILE" ]]; then touch "$ENV_FILE"; fi

  # 写 .env 的小工具：存在就替换；不存在就追加
  upsert_env() {
    local key="$1" val="$2"
    # 转义 sed 替换里的特殊字符：\ / &
    local v_esc
    v_esc="$(printf '%s' "$val" | sed 's/[\/&]/\\&/g')"
    if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
      sed -i -E "s|^${key}=.*|${key}=${v_esc}|" "$ENV_FILE"
    else
      printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
    fi
  }
  upsert_env NODE_PORT              "$node_port"
  upsert_env ARIA2_RPC_PORT         "$aria2_port"
  upsert_env ARIA2_RPC_SECRET       "$aria2_secret"
  upsert_env NODE_DOWNLOAD_DIR      "$dl_dir"
  upsert_env NODE_TTL_SECONDS       "$ttl"
  upsert_env NODE_STORAGE_LIMIT_GB  "$quota_gb"
  upsert_env NODE_ID                "$node_id"
  upsert_env NODE_TOKEN             "$node_token"
  upsert_env CENTER_URL             "$center_url"
  # 下面两项也固定下来方便脚本：
  upsert_env NODE_HOST              "${NODE_HOST:-0.0.0.0}"
  upsert_env ARIA2_RPC_URL          "http://127.0.0.1:${aria2_port}/rpc"

  ok "配置写入完成：${ENV_FILE}"
  info "当前生效值（可以直接编辑此文件）："
  sed 's/^/     | /' "$ENV_FILE"
  # source 后让后续步骤读到最新值
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE" || true
  set +a
}

# ---------- 进程/服务模块（与 manage.sh 类似，保持独立） ----------
# 服务列表
declare -a SERVICES=(aria2 node)

pid_file() { case "$1" in aria2) echo "$PID_DIR/aria2.pid";; node) echo "$PID_DIR/node-agent.pid";; esac; }
log_file() { case "$1" in aria2) echo "$LOG_DIR/aria2.log";;   node) echo "$LOG_DIR/node-agent.log";; esac; }
svc_keyword() { case "$1" in aria2) echo "--enable-rpc";;       node) echo "main:app";; esac; }

valid_pid() {
  local s="$1" pf pid kw cmd
  pf="$(pid_file "$s")"; kw="$(svc_keyword "$s")"
  [[ -f "$pf" ]] || return 1
  pid="$(cat "$pf" 2>/dev/null || true)"; [[ -n "$pid" ]] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    if [[ -z "$kw" || "$cmd" == *"$kw"* ]]; then echo "$pid"; return 0; fi
  fi
  rm -f "$pf"; return 1
}
find_pid_by_keyword() {
  local kw
  kw="$(svc_keyword "$1")"
  [[ -n "$kw" ]] || return 1
  pgrep -a -f "$kw" 2>/dev/null | awk 'NR==1{print $1}' || true
}
is_running() {
  local s="$1" p
  p="$(valid_pid "$s" 2>/dev/null || true)"
  if [[ -n "$p" ]]; then echo "$p"; return 0; fi
  p="$(find_pid_by_keyword "$s" 2>/dev/null || true)"
  [[ -n "$p" ]] || return 1
  echo "$p" > "$(pid_file "$s")"
  echo "$p"
}

# 健康检查（2 种策略，都不是单靠端口）
health_check() {
  local s="$1" code
  case "$s" in
    aria2)
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        -X POST "http://127.0.0.1:${ARIA2_RPC_PORT:-6800}/jsonrpc" \
        -d '{"jsonrpc":"2.0","method":"aria2.getGlobalStat","id":"ping"}' 2>/dev/null || echo 000)"
      [[ "$code" == "200" || "$code" == "401" ]]
      ;;
    node)
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        "http://127.0.0.1:${NODE_PORT:-8000}/api/node/health" 2>/dev/null || echo 000)"
      [[ "$code" == "200" ]]
      ;;
  esac
}

gentle_kill() {
  local pid="$1" s="${2:-svc}" w=0 soft=$(( ${WAIT_MAX:-20} / 2 ))
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || return 0
  info "停止 $s (PID=$pid) → SIGTERM"
  kill -TERM "$pid" 2>/dev/null || true
  while (( w < soft )); do
    kill -0 "$pid" 2>/dev/null || { ok "$s (PID=$pid) 已退出"; return 0; }
    sleep 1; w=$((w+1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "超时 → SIGKILL $pid"
    kill -KILL "$pid" 2>/dev/null || true; sleep 1
  fi
}

wait_healthy() {
  local s="$1" pid="$2" waited=0 max="${WAIT_MAX:-20}"
  while (( waited < max )); do
    if health_check "$s" >/dev/null 2>&1; then return 0; fi
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 1; waited=$((waited+1))
  done
  return 2
}

start_one() {
  local s="$1" pid cmd logf pidf
  service_exists() { for x in "${SERVICES[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
  service_exists "$s" || { err "未知服务 $s"; return 1; }
  logf="$(log_file "$s")"; pidf="$(pid_file "$s")"
  pid="$(is_running "$s" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then ok "$s 已运行（PID=$pid），跳过"; return 0; fi

  info "启动 $s..."
  mkdir -p "${NODE_DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}"

  case "$s" in
    aria2)
      local d="${ARIA2_DIR:-${NODE_DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}}"
      mkdir -p "$d"
      ( cd "$PROJECT_DIR"
        exec nohup aria2c \
          --enable-rpc --rpc-listen-all \
          --rpc-listen-port="${ARIA2_RPC_PORT:-6800}" \
          --rpc-secret="${ARIA2_RPC_SECRET:-nodefetch_secret}" \
          --rpc-allow-origin-all \
          --dir="$d" \
          --input-file="$SESSION_FILE" --save-session="$SESSION_FILE" \
          --save-session-interval=60 \
          --max-concurrent-downloads=5 --continue --log-level=notice \
          --file-allocation=none >>"$logf" 2>&1 </dev/null ) &
      ;;
    node)
      # 用 venv python 绝对路径启动，避免 shell source 失效
      create_or_reuse_venv >/dev/null || true
      if [[ ! -x "$PYTHON_BIN" ]]; then err "Python venv 不可用，先执行步骤 2/3"; return 1; fi
      ( cd "$PROJECT_DIR"
        exec env \
          NODE_PORT="${NODE_PORT:-8000}" \
          NODE_HOST="${NODE_HOST:-0.0.0.0}" \
          NODE_DOWNLOAD_DIR="${NODE_DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}" \
          DOWNLOAD_DIR="${NODE_DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}" \
          ARIA2_RPC_URL="http://127.0.0.1:${ARIA2_RPC_PORT:-6800}/rpc" \
          ARIA2_RPC_SECRET="${ARIA2_RPC_SECRET:-nodefetch_secret}" \
          NODE_TTL_SECONDS="${NODE_TTL_SECONDS:-86400}" \
          NODE_STORAGE_LIMIT_GB="${NODE_STORAGE_LIMIT_GB:-10}" \
          NODE_ID="${NODE_ID:-node-01}" \
          NODE_TOKEN="${NODE_TOKEN:-}" \
          CENTER_URL="${CENTER_URL:-}" \
          nohup "$PYTHON_BIN" -m uvicorn main:app \
            --host "${NODE_HOST:-0.0.0.0}" --port "${NODE_PORT:-8000}" \
            --workers 1 >>"$logf" 2>&1 </dev/null ) &
      ;;
  esac
  sleep 1
  local real_pid
  real_pid="$(find_pid_by_keyword "$s" 2>/dev/null || true)"
  if [[ -z "$real_pid" ]]; then
    # 兜底：$! 是 nohup，再等一下看看关键词进程出来没
    sleep 1
    real_pid="$(find_pid_by_keyword "$s" 2>/dev/null || echo $!)"
  fi
  echo "$real_pid" > "$pidf"

  set +e
  wait_healthy "$s" "$real_pid"
  local rc=$?
  set -e
  case "$rc" in
    0) ok "$s 启动成功（PID=$real_pid，健康检查通过）"; return 0 ;;
    1) err "$s 启动失败：进程很快退出。日志（最后 30 行）:" ;;
    2) err "$s 启动超时（${WAIT_MAX:-20}s 未健康）。可能还在初始化，也可能失败。日志（最后 30 行）:" ;;
  esac
  tail -n 30 "$logf" 2>/dev/null | sed 's/^/     | /' || echo "     | (无日志)"
  gentle_kill "$real_pid" "$s" 2>/dev/null || true
  rm -f "$pidf"
  return 1
}

stop_one() {
  local s="$1" pid
  pid="$(is_running "$s" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then ok "$s 未运行"; rm -f "$(pid_file "$s")"; return 0; fi
  gentle_kill "$pid" "$s"
  rm -f "$(pid_file "$s")"
}

# ---------- 主流程子函数 ----------
wizard_install() {
  section_title "Node Agent 分步安装向导（幂等，可反复运行）"
  install_system_packages || { warn "可在解决系统包问题后重新进入向导"; press_enter; return; }
  create_or_reuse_venv  || { press_enter; return; }
  install_pip_deps      || { press_enter; return; }
  generate_env          || { press_enter; return; }
  step "5/6" "启动服务（aria2 → node），健康检查"
  start_one aria2 || { press_enter; return; }
  start_one node  || { press_enter; return; }
  step "6/6" "安装完成 → 验证接口"
  verify_endpoints || true
  printf '\n  %s 安装完成！下一步可从主菜单进入 Status / Logs / Tools 。\n' "${FG_GREEN}✔${R}"
  press_enter
}

verify_endpoints() {
  info "验证 aria2 RPC..."
  if health_check aria2; then ok "aria2 RPC 可达"; else err "aria2 RPC 不可达"; fi
  info "验证 Node Agent /api/node/health..."
  if health_check node; then
    ok "Node health 200"
    local body
    body="$(curl -sS --max-time 3 "http://127.0.0.1:${NODE_PORT:-8000}/api/node/health" 2>/dev/null || echo '{}')"
    info "返回摘要：$(printf '%s' "$body" | tr -d '\n' | cut -c 1-200)"
  else
    err "Node /api/node/health 未 200"
    return 1
  fi
}

# ---------- 主菜单 ----------
menu_install()   { wizard_install; }
menu_start()     { section_title "启动服务"; start_one aria2 || true; start_one node || true; press_enter; }
menu_stop()      { section_title "停止服务"; stop_one node; stop_one aria2; press_enter; }
menu_restart()   { section_title "重启服务"; stop_one node; stop_one aria2; sleep 1; start_one aria2 || true; start_one node || true; press_enter; }
menu_status() {
  section_title "服务状态"
  local s pid run hc
  for s in "${SERVICES[@]}"; do
    pid="$(is_running "$s" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      run="${FG_GREEN}RUNNING${R} (PID=$pid)"
      if health_check "$s" >/dev/null 2>&1; then hc="${FG_GREEN}HEALTHY${R}"; else hc="${FG_YELLOW}UNHEALTHY${R}"; fi
    else
      run="${FG_RED}STOPPED${R}"; hc="${FG_DIM}—${R}"
    fi
    printf '  %-8s %-32s health=%-22s log=%s\n' "${B}$s${R}" "$run" "$hc" "$(log_file "$s")"
  done
  printf '  %s runtime=%s  .env=%s  download=%s\n' \
    "${FG_DIM}·${R}" "${RUNTIME_DIR}" "${ENV_FILE}" \
    "${NODE_DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}"
  press_enter
}
menu_logs() {
  local s_idx s follow
  s_idx="$(menu "查看哪个服务的日志？" "node-agent|Node API" "aria2|下载器")"
  case "$s_idx" in
    0) s="node" ;;
    1) s="aria2" ;;
  esac
  if ask_yesno "使用 tail -F 持续追更？（退出：Ctrl+C）" Y; then
    info "按 Ctrl+C 返回菜单"
    sleep 1
    exec < /dev/tty tail -F "$(log_file "$s")"
  else
    tail -n 100 "$(log_file "$s")" 2>/dev/null | sed 's/^/  | /' || true
    press_enter
  fi
}
menu_tools() {
  while true; do
    section_title "工具菜单"
    local sel
    sel="$(menu "请选择" \
      "创建测试任务|POST /api/tasks example.com" \
      "列出所有任务|GET /api/tasks?limit=10" \
      "清理 runtime|清空 logs/pids（停止后再运行）" \
      "升级 pip 依赖|venv pip install -U -r requirements" \
      "运行 pytest|跑全部 40 条测试" \
      "返回主菜单" )"
    case "$sel" in
      0) section_title "创建测试任务"
         local body
         body="$(curl -sS --max-time 5 -X POST "http://127.0.0.1:${NODE_PORT:-8000}/api/tasks" \
           -H 'Content-Type: application/json' \
           -d '{"source_url":"https://www.example.com/","filename":"example.html"}' 2>/dev/null || echo '{}')"
         info "响应：$(printf '%s' "$body" | cut -c 1-400)" ;;
      1) section_title "列出任务（limit=10）"
         curl -sS --max-time 5 "http://127.0.0.1:${NODE_PORT:-8000}/api/tasks?limit=10" 2>/dev/null | \
           "$(ensure_python_bin; echo "$PYTHON_BIN")" -m json.tool 2>/dev/null | sed 's/^/  | /' || true ;;
      2) if ask_yesno "会清空 runtime 下所有日志/PID。确定？" N; then
           rm -f "$PID_DIR"/*.pid "$LOG_DIR"/*.log "$SESSION_FILE"
           ok "已清理"
         fi ;;
      3) create_or_reuse_venv >/dev/null || true
         if [[ -x "$PYTHON_BIN" ]]; then
           info "升级 pip 依赖..."
           "$PYTHON_BIN" -m pip install -U -r "$PIP_REQUIREMENTS" 2>&1 | tail -n 10 | sed 's/^/  | /'
           ok "完成"
         fi ;;
      4) create_or_reuse_venv >/dev/null || true
         if [[ -x "$PYTHON_BIN" ]]; then
           info "运行 pytest（可能要 10~30s）..."
           ( cd "$PROJECT_DIR" && "$PYTHON_BIN" -m pytest tests/ 2>&1 | tail -n 15 | sed 's/^/  | /' || true )
         fi ;;
      5) return ;;
    esac
    press_enter
  done
}

menu_uninstall() {
  section_title "卸载 / 清空"
  local sel
  sel="$(menu "选择范围（不可恢复）" \
    "仅停止服务并清理 PID/日志" \
    "以上 + 删除 venv/.venv" \
    "以上 + 删除下载目录 data/downloads" \
    "取消返回" )"
  case "$sel" in
    3) return ;;
  esac
  if ask_yesno "确认执行？" N; then
    stop_one node; stop_one aria2
    rm -rf "$RUNTIME_DIR"
    ok "runtime 已清理"
    if (( sel >= 1 )); then
      if [[ -d "$VENV_DIR" ]] && ask_yesno "删除 venv：$VENV_DIR ?" N; then
        rm -rf "$VENV_DIR"; ok "venv 已删除"
      fi
    fi
    if (( sel >= 2 )); then
      local d="${NODE_DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}"
      if [[ -d "$d" ]] && ask_yesno "删除下载目录：$d ?" N; then
        rm -rf "$d"; ok "下载目录已删除"
      fi
    fi
  fi
  press_enter
}

main_loop() {
  while true; do
    clear 2>/dev/null || true
    banner
    local sel
    sel="$(menu "Node Agent 主菜单" \
      "安装向导 Install Wizard|6 步搞定：系统包→venv→pip→.env→启动→验证（幂等）" \
      "启动 Start|aria2 + node 顺序启动（健康检查）" \
      "停止 Stop|分级 SIGTERM→SIGKILL" \
      "重启 Restart|stop + start" \
      "状态 Status|运行状态 + 健康检查 + 日志路径" \
      "日志 Logs|node/aria2，可选 tail -F" \
      "工具 Tools|创建任务 / 列任务 / 升级 / pytest / 清理" \
      "卸载 Uninstall|分级删除：runtime/venv/下载目录" \
      "退出 Quit")"
    case "$sel" in
      0) menu_install ;;
      1) menu_start ;;
      2) menu_stop ;;
      3) menu_restart ;;
      4) menu_status ;;
      5) menu_logs ;;
      6) menu_tools ;;
      7) menu_uninstall ;;
      8) clear 2>/dev/null || true; echo "Bye."; exit 0 ;;
    esac
  done
}

# 如指定了子命令（scripts/install.sh install / start / ...），等价于直接触发；否则进入主菜单
if [[ $# -gt 0 ]]; then
  case "$1" in
    install|wizard) wizard_install ;;
    start)  menu_start  ;;
    stop)   menu_stop   ;;
    restart) menu_restart ;;
    status) menu_status ;;
    logs)   shift;
            s="${1:-node}"
            case "$s" in node|aria2) ;; *) s="node";; esac
            if [[ "${2:-}" == "-f" ]]; then exec < /dev/tty tail -F "$(log_file "$s")"; else tail -n 100 "$(log_file "$s")"; fi ;;
    check)  install_system_packages; create_or_reuse_venv; install_pip_deps ;;
    *)      echo "用法: $0 [install|start|stop|restart|status|logs [node|aria2] [-f]|check]" ;;
  esac
else
  main_loop
fi
