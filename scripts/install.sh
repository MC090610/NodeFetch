#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# NodeFetch Node Agent - Linux TUI 一键安装 & 运维向导
#
#   chmod +x scripts/install.sh && scripts/install.sh
#
# 进程启停全部委托 scripts/manage.sh，避免两套逻辑分叉。
# 本文件只负责：发行版检测、venv/pip、.env 生成、TUI 菜单。
#
# 交互输出一律走 /dev/tty（或 stderr），stdout 只给 menu/ask 的返回值。
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANAGE_SH="${SCRIPT_DIR}/manage.sh"
RUNTIME_DIR="${RUNTIME_DIR:-${PROJECT_DIR}/runtime}"
ENV_FILE="${PROJECT_DIR}/.env"
PID_DIR="${RUNTIME_DIR}/pids"
LOG_DIR="${RUNTIME_DIR}/logs"
SESSION_FILE="${RUNTIME_DIR}/aria2.session"
VENV_DIR="${VENV_DIR:-${PROJECT_DIR}/.venv}"
PIP_REQUIREMENTS="${PROJECT_DIR}/requirements.txt"
PYTHON_BIN=""

mkdir -p "$PID_DIR" "$LOG_DIR"
touch "$SESSION_FILE"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE" || true
  set +a
fi

# 旧键名 → config.py 键名（只读兼容）
: "${API_PORT:=${NODE_PORT:-8000}}"
: "${API_HOST:=${NODE_HOST:-0.0.0.0}}"
: "${DOWNLOAD_DIR:=${NODE_DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}}"
: "${STORAGE_LIMIT_GB:=${NODE_STORAGE_LIMIT_GB:-40}}"
if [[ -z "${TTL_MINUTES:-}" ]]; then
  if [[ -n "${NODE_TTL_SECONDS:-}" ]]; then
    TTL_MINUTES=$(( NODE_TTL_SECONDS / 60 ))
    (( TTL_MINUTES < 1 )) && TTL_MINUTES=1
  else
    TTL_MINUTES=60
  fi
fi
: "${CONCURRENT_LIMIT:=2}"
: "${MAX_FILE_SIZE_GB:=10}"
: "${ARIA2_RPC_PORT:=6800}"
: "${NODE_ID:=node-01}"

# 交互输出目标：有 tty 就用它，这样 $(menu) / $(ask) 不会把界面吃掉。
if [[ -w /dev/tty ]]; then
  UI_OUT=/dev/tty
else
  UI_OUT=/dev/stderr
fi
ui() { printf '%s' "$*" >"$UI_OUT"; }
uiln() { printf '%s\n' "$*" >"$UI_OUT"; }

if [[ -t 1 || -w /dev/tty ]]; then
  R=$'\033[0m'; B=$'\033[1m'
  FG=$'\033[38;5;255m'; BG_BLUE=$'\033[48;5;17m'
  FG_GREEN=$'\033[38;5;46m'; FG_RED=$'\033[38;5;196m'
  FG_YELLOW=$'\033[38;5;226m'; FG_CYAN=$'\033[38;5;51m'; FG_DIM=$'\033[38;5;243m'
else
  R=''; B=''; FG=''; BG_BLUE=''
  FG_GREEN=''; FG_RED=''; FG_YELLOW=''; FG_CYAN=''; FG_DIM=''
fi

tcols() {
  local c
  c="$(tput cols 2>/dev/null || echo 100)"
  (( c > 110 )) && c=110
  echo "$c"
}

bar() {
  local w
  w="$(tcols)"
  printf '%*s\n' "$w" '' | tr ' ' '─' >"$UI_OUT"
}
boldbar() {
  local w
  w="$(tcols)"
  printf '%*s\n' "$w" '' | tr ' ' '═' >"$UI_OUT"
}

section_title() {
  local w t pad
  w="$(tcols)"; t="$*"
  pad=$(( (w - ${#t} - 2) / 2 ))
  (( pad < 0 )) && pad=0
  printf '%s' "${BG_BLUE}${B}${FG}" >"$UI_OUT"
  printf '%*s' "$pad" '' >"$UI_OUT"
  printf ' %s ' "$t" >"$UI_OUT"
  printf '%*s' "$(( w - pad - ${#t} - 2 ))" '' >"$UI_OUT"
  printf '%s\n' "$R" >"$UI_OUT"
}

banner() {
  boldbar
  printf '  %s %s%s  %sNode Agent%s  -  %sTUI Installer & Manager%s\n' \
    "${B}${FG_YELLOW}◆${R}" \
    "${B}${FG_CYAN}NodeFetch${R}" \
    "${FG_DIM}│${R}" \
    "${B}${FG_GREEN}" "${R}" \
    "${FG_DIM}" "${R}" >"$UI_OUT"
  printf '  %s project: %s%s%s  runtime: %s%s%s\n' \
    "${FG_DIM}·${R}" "${B}" "${PROJECT_DIR}" "${R}" \
    "${B}" "${RUNTIME_DIR}" "${R}" >"$UI_OUT"
  boldbar
}

ok()   { printf '  %s%s OK%s  %s\n'  "${B}${FG_GREEN}"  '✓' "$R" "$*" >"$UI_OUT"; }
warn() { printf '  %s%s WRN%s %s\n'  "${B}${FG_YELLOW}" '!' "$R" "$*" >"$UI_OUT"; }
err()  { printf '  %s%s ERR%s %s\n'  "${B}${FG_RED}"   '✗' "$R" "$*" >"$UI_OUT"; }
info() { printf '  %s%s INF%s %s\n'  "${B}${FG_CYAN}"  '·' "$R" "$*" >"$UI_OUT"; }

step() {
  local n="$1"; shift
  printf '\n  %s[STEP %s] %s%s%s\n' "${B}${FG_CYAN}" "$n" "${B}" "$*" "$R" >"$UI_OUT"
  bar
}

# 从终端读一行到 stdout。不用 nameref / mapfile，兼容 macOS 自带的 bash 3.2。
read_ui_line() {
  local line=""
  if [[ "$UI_OUT" == /dev/tty ]]; then
    IFS= read -r line < /dev/tty || true
  else
    IFS= read -r line || true
  fi
  printf '%s' "$line"
}

press_enter() {
  local prompt="${1:-按 Enter 回到主菜单...}"
  printf '\n  %s' "$prompt" >"$UI_OUT"
  read_ui_line >/dev/null
}

ask() {
  local label="$1" def="$2" val
  printf '  %s %s%s%s %s[%s]%s: ' \
    "${FG_CYAN}?${R}" "${B}" "$label" "${R}" \
    "${FG_DIM}" "$def" "$R" >"$UI_OUT"
  val="$(read_ui_line)"
  if [[ -z "$val" ]]; then printf '%s' "$def"; else printf '%s' "$val"; fi
}

ask_yesno() {
  local label="$1" def="${2:-Y}" hint ans
  case "$def" in
    Y|y) hint="[Y/n]" ;;
    N|n) hint="[y/N]" ;;
  esac
  while true; do
    printf '  %s %s%s%s %s: ' "${FG_CYAN}?${R}" "${B}" "$label" "$hint" "$R" >"$UI_OUT"
    ans="$(read_ui_line)"
    ans="${ans:-$def}"
    case "$ans" in
      Y|y|Yes|yes) return 0 ;;
      N|n|No|no)   return 1 ;;
    esac
  done
}

# 界面 → UI_OUT；选中的 0-based 索引 → stdout（供 sel="$(menu ...)"）
menu() {
  local title="$1"
  shift
  local -a items=( "$@" )
  local -a desc=()
  local i=0 line
  printf '\n  %s%s%s\n' "${B}" "$title" "$R" >"$UI_OUT"
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
        "$line" "${FG_DIM}" "${desc[$i]}" "$R" >"$UI_OUT"
    else
      printf '    %s%2d%s %s\n' "${B}${FG_YELLOW}" "$(( i+1 ))" "$R" "$line" >"$UI_OUT"
    fi
    i=$(( i+1 ))
  done
  local sel
  while true; do
    printf '  %s请选择序号 %s[1-%d]%s: ' "${FG_CYAN}>${R}" "${FG_DIM}" "$i" "$R" >"$UI_OUT"
    sel="$(read_ui_line)"
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )); then
      printf '%s\n' "$(( sel - 1 ))"
      return 0
    fi
  done
}

manage() {
  bash "$MANAGE_SH" "$@"
}

api_base() {
  local host="${API_HOST:-127.0.0.1}"
  local port="${API_PORT:-8000}"
  if [[ "$host" == "0.0.0.0" || "$host" == "::" || "$host" == "*" ]]; then
    host="127.0.0.1"
  fi
  printf 'http://%s:%s' "$host" "$port"
}

json_get() {
  # json_get <json> <key> — 只要顶层字符串/数字字段
  local json="$1" key="$2"
  ensure_python_bin
  if [[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]]; then
    printf '%s' "$json" | "$PYTHON_BIN" -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print("" if v is None else v)' "$key" 2>/dev/null || true
  else
    printf '%s' "$json" | sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
  fi
}

create_smoke_task() {
  section_title "创建测试任务"
  # 用真实小文件，而不是网站首页（example.com 只是 HTML，不能验证下载闭环）
  local url="https://proof.ovh.net/files/1Mb.dat"
  local fname="1Mb.dat"
  local base http body tmp task_id status i
  base="$(api_base)"
  tmp="$(mktemp)"
  info "POST ${base}/api/tasks"
  info "source_url=${url}"
  http="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 25 \
    -X POST "${base}/api/tasks" \
    -H 'Content-Type: application/json' \
    -d "{\"source_url\":\"${url}\",\"filename\":\"${fname}\"}" 2>/dev/null || echo 000)"
  body="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"
  info "HTTP ${http}"
  info "响应：$(printf '%s' "$body" | tr -d '\n' | cut -c 1-400)"
  if [[ "$http" != "201" ]]; then
    err "创建失败（期望 HTTP 201）。若是 403 PRIVATE_IP_BLOCKED，看 SecurityAgent；连不上则先 Start。"
    return 0
  fi
  task_id="$(json_get "$body" id)"
  if [[ -z "$task_id" ]]; then
    warn "响应里没有 task id，跳过轮询"
    return 0
  fi
  info "轮询任务 ${task_id}（最多 ~20s，看 queued → downloading → completed）..."
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 2
    body="$(curl -sS --max-time 5 "${base}/api/tasks/${task_id}" 2>/dev/null || true)"
    status="$(json_get "$body" status)"
    info "  [$i] status=${status:-unknown}"
    case "$status" in
      completed)
        ok "测试任务完成"
        info "$(printf '%s' "$body" | tr -d '\n' | cut -c 1-400)"
        return 0
        ;;
      failed|expired)
        err "测试任务失败：$(printf '%s' "$body" | tr -d '\n' | cut -c 1-400)"
        return 0
        ;;
    esac
  done
  warn "20s 内未完成（1MB 在海外节点通常很快）。可用「列出所有任务」再查。"
}

log_file() {
  case "$1" in
    aria2) echo "$LOG_DIR/aria2.log" ;;
    node)  echo "$LOG_DIR/node-agent.log" ;;
    *)     echo "$LOG_DIR/$1.log" ;;
  esac
}

# ---------- 系统包 ----------
detect_distro() {
  local os="unknown" pkg=""
  if command -v sw_vers >/dev/null 2>&1; then
    os="macos"; pkg="brew"
  elif command -v apt-get >/dev/null 2>&1; then
    os="debian"; pkg="apt"
  elif command -v dnf >/dev/null 2>&1; then
    os="fedora"; pkg="dnf"
  elif command -v yum >/dev/null 2>&1; then
    os="centos"; pkg="yum"
  elif command -v pacman >/dev/null 2>&1; then
    os="arch"; pkg="pacman"
  fi
  printf '%s|%s\n' "$os" "$pkg"
}

# 把 sudo 拆成真正的命令 + 参数，避免 "sudo -n" 被当成一个命令名。
run_root() {
  if [[ "$(id -u 2>/dev/null || echo 1)" == "0" ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
      sudo -n "$@"
    else
      sudo "$@"
    fi
  else
    "$@"
  fi
}

SYS_DEBS=(aria2 curl ca-certificates git python3 python3-pip python3-venv)
SYS_RPMS=(aria2 curl ca-certificates git python3 python3-pip)
SYS_ARCH=(aria2 curl ca-certificates git python)
SYS_BREW=(aria2 curl ca-certificates git python)

install_system_packages() {
  step "1/6" "检测发行版并安装系统级依赖（aria2 / curl / python3 / git 等）"
  local info os pkg
  info="$(detect_distro)"
  os="${info%%|*}"; pkg="${info#*|}"

  local -a all_missing=()
  case "$pkg" in
    apt)  info "发行版: Debian/Ubuntu (apt)" ;;
    dnf)  info "发行版: Fedora/RHEL (dnf)" ;;
    yum)  info "发行版: CentOS (yum)" ;;
    pacman) info "发行版: Arch (pacman)" ;;
    brew) info "系统: macOS (Homebrew)" ;;
    *)
      warn "未能识别包管理器。请手动安装：aria2、curl、git、python3（含 venv + pip）、ca-certificates"
      return 0
      ;;
  esac

  case "$pkg" in
    apt)
      for p in "${SYS_DEBS[@]}"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then all_missing+=("$p"); fi
      done
      ;;
    dnf|yum)
      for p in "${SYS_RPMS[@]}"; do
        if ! rpm -q "$p" >/dev/null 2>&1; then all_missing+=("$p"); fi
      done
      ;;
    pacman)
      for p in "${SYS_ARCH[@]}"; do
        if ! pacman -Qq "$p" >/dev/null 2>&1; then all_missing+=("$p"); fi
      done
      ;;
    brew)
      for p in "${SYS_BREW[@]}"; do
        if ! brew list --versions "$p" >/dev/null 2>&1; then all_missing+=("$p"); fi
      done
      ;;
  esac

  if (( ${#all_missing[@]} == 0 )); then
    ok "系统包全部已就绪，无需安装"
    return 0
  fi

  info "缺少的包：${all_missing[*]}"
  if ask_yesno "安装这些系统包（需要 sudo 或密码提示）？" Y; then
    local rc=0
    set +e
    case "$pkg" in
      apt)
        info "apt-get update（用于刷新源索引，可能需要 sudo 密码）..."
        run_root apt-get update -y >/dev/null 2>&1 || warn "apt update 失败，继续尝试安装"
        info "执行：apt-get install ${all_missing[*]}"
        run_root apt-get install -y --no-install-recommends "${all_missing[@]}"
        rc=$?
        ;;
      dnf)
        info "执行：dnf install ${all_missing[*]}"
        run_root dnf install -y "${all_missing[@]}"
        rc=$?
        ;;
      yum)
        info "执行：yum install ${all_missing[*]}"
        run_root yum install -y "${all_missing[@]}"
        rc=$?
        ;;
      pacman)
        info "执行：pacman -Sy ${all_missing[*]}"
        run_root pacman -Sy --noconfirm "${all_missing[@]}"
        rc=$?
        ;;
      brew)
        info "执行：brew install ${all_missing[*]}"
        brew install "${all_missing[@]}"
        rc=$?
        ;;
    esac
    set -e
    if (( rc == 0 )); then ok "系统依赖安装成功"; else err "系统包安装退出码=$rc，稍后可重试"; return 1; fi
  else
    warn "用户跳过系统包安装。下一步可能失败。"
  fi
}

# ---------- venv / pip ----------
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
  if [[ -x "${VENV_DIR}/bin/python" ]]; then
    ok "已存在 venv：${VENV_DIR}（重用，跳过创建）"
    PYTHON_BIN="${VENV_DIR}/bin/python"
    return 0
  fi
  local py=""
  if command -v python3 >/dev/null 2>&1; then py="python3"
  elif command -v python >/dev/null 2>&1; then py="python"
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
  info "升级 venv 内的 pip/setuptools/wheel..."
  "$PYTHON_BIN" -m pip install --quiet --upgrade pip setuptools wheel >/dev/null 2>&1 || true
  ok "venv 创建成功：${VENV_DIR}"
}

install_pip_deps() {
  step "3/6" "安装 Python 依赖（fastapi / uvicorn / sqlalchemy / httpx 等）"
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    create_or_reuse_venv || return 1
  fi
  PYTHON_BIN="${VENV_DIR}/bin/python"
  if [[ ! -x "$PYTHON_BIN" ]]; then err "venv python 不可用，先执行步骤 2"; return 1; fi
  if [[ ! -f "$PIP_REQUIREMENTS" ]]; then err "缺失：${PIP_REQUIREMENTS}"; return 1; fi

  if "$PYTHON_BIN" -c 'import fastapi, uvicorn, sqlalchemy, aiosqlite, pydantic_settings, httpx' >/dev/null 2>&1; then
    ok "核心 pip 依赖已齐全，跳过 pip install（如想强制升级，选菜单里的 Upgrade deps）"
    return 0
  fi

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
    local plog="${LOG_DIR}/pip-install.log"
    warn "重试 verbose 模式并写入 $plog ..."
    set +e
    "$PYTHON_BIN" -m pip install "${pip_args[@]}" -r "$PIP_REQUIREMENTS" >"$plog" 2>&1
    set -e
    tail -n 30 "$plog" | sed 's/^/     | /' >"$UI_OUT"
    return 1
  fi
  ok "pip 依赖安装成功"
}

# ---------- .env ----------
upsert_env() {
  local key="$1" val="$2" tmp v_esc
  tmp="$(mktemp)"
  if [[ -f "$ENV_FILE" ]]; then
    grep -vE "^${key}=" "$ENV_FILE" >"$tmp" || true
  else
    : >"$tmp"
  fi
  v_esc="$(printf '%s' "$val" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '%s="%s"\n' "$key" "$v_esc" >>"$tmp"
  mv "$tmp" "$ENV_FILE"
}

remove_env_key() {
  local key="$1" tmp
  [[ -f "$ENV_FILE" ]] || return 0
  tmp="$(mktemp)"
  grep -vE "^${key}=" "$ENV_FILE" >"$tmp" || true
  mv "$tmp" "$ENV_FILE"
}

generate_env() {
  step "4/6" "生成项目配置（${ENV_FILE}）— 键名与 config.py 对齐"
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    create_or_reuse_venv || true
  fi

  local api_port api_host aria2_port aria2_secret dl_dir ttl quota_gb max_gb conc node_id node_token center_url
  api_port="$(ask    "Node 监听端口（API_PORT）"                         "${API_PORT:-8000}")"
  api_host="$(ask    "Node 监听地址（API_HOST，VPS 用 0.0.0.0）"          "${API_HOST:-0.0.0.0}")"
  aria2_port="$(ask  "Aria2 RPC 端口（ARIA2_RPC_PORT）"                   "${ARIA2_RPC_PORT:-6800}")"
  aria2_secret="$(ask "Aria2 RPC 密钥（ARIA2_RPC_SECRET）"                "${ARIA2_RPC_SECRET:-nodefetch_secret}")"
  dl_dir="$(ask      "下载文件目录（DOWNLOAD_DIR）"                       "${DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}")"
  ttl="$(ask         "任务存活 TTL 分钟（TTL_MINUTES，生产建议 60）"       "${TTL_MINUTES:-60}")"
  quota_gb="$(ask    "存储配额 GB（STORAGE_LIMIT_GB）"                    "${STORAGE_LIMIT_GB:-40}")"
  max_gb="$(ask      "单文件上限 GB（MAX_FILE_SIZE_GB）"                  "${MAX_FILE_SIZE_GB:-10}")"
  conc="$(ask        "并发下载槽位（CONCURRENT_LIMIT）"                   "${CONCURRENT_LIMIT:-2}")"
  node_id="$(ask     "本节点 ID（NODE_ID，英文/数字/-_）"                  "${NODE_ID:-node-01}")"
  node_token="$(ask  "本节点 Token（NODE_TOKEN，向中心注册用，无中心可留空）" "${NODE_TOKEN:-}")"
  center_url="$(ask  "中心 URL（CENTER_URL，无中心可留空）"                "${CENTER_URL:-}")"

  mkdir -p "$dl_dir"
  [[ -f "$ENV_FILE" ]] || touch "$ENV_FILE"

  upsert_env API_PORT            "$api_port"
  upsert_env API_HOST            "$api_host"
  upsert_env ARIA2_RPC_PORT      "$aria2_port"
  upsert_env ARIA2_RPC_SECRET    "$aria2_secret"
  upsert_env ARIA2_RPC_URL       "http://127.0.0.1:${aria2_port}/rpc"
  upsert_env DOWNLOAD_DIR        "$dl_dir"
  upsert_env TTL_MINUTES         "$ttl"
  upsert_env STORAGE_LIMIT_GB    "$quota_gb"
  upsert_env MAX_FILE_SIZE_GB    "$max_gb"
  upsert_env CONCURRENT_LIMIT    "$conc"
  upsert_env NODE_ID             "$node_id"
  upsert_env NODE_TOKEN          "$node_token"
  upsert_env CENTER_URL          "$center_url"

  # 清掉旧脚本写过、Python 又不认的键，避免以后再踩坑
  local old
  for old in NODE_PORT NODE_HOST NODE_DOWNLOAD_DIR NODE_TTL_SECONDS NODE_STORAGE_LIMIT_GB; do
    remove_env_key "$old"
  done

  ok "配置写入完成：${ENV_FILE}"
  info "当前生效值（可以直接编辑此文件）："
  sed 's/^/     | /' "$ENV_FILE" >"$UI_OUT"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE" || true
  set +a
}

verify_endpoints() {
  info "验证 aria2 RPC..."
  local code payload
  if [[ -n "${ARIA2_RPC_SECRET:-}" ]]; then
    payload="{\"jsonrpc\":\"2.0\",\"method\":\"aria2.getGlobalStat\",\"id\":\"ping\",\"params\":[\"token:${ARIA2_RPC_SECRET}\"]}"
  else
    payload='{"jsonrpc":"2.0","method":"aria2.getGlobalStat","id":"ping"}'
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
    -X POST "http://127.0.0.1:${ARIA2_RPC_PORT:-6800}/jsonrpc" \
    -d "$payload" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then ok "aria2 RPC 可达"; else err "aria2 RPC 不可达 (HTTP $code)"; fi

  info "验证 Node Agent /api/node/health..."
  local health_host="${API_HOST:-127.0.0.1}"
  if [[ "$health_host" == "0.0.0.0" || "$health_host" == "::" || "$health_host" == "*" ]]; then
    health_host="127.0.0.1"
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
    "http://${health_host}:${API_PORT:-8000}/api/node/health" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    ok "Node health 200"
    local body
    body="$(curl -sS --max-time 3 "http://${health_host}:${API_PORT:-8000}/api/node/health" 2>/dev/null || echo '{}')"
    info "返回摘要：$(printf '%s' "$body" | tr -d '\n' | cut -c 1-200)"
  else
    err "Node /api/node/health 未 200 (HTTP $code)"
    return 1
  fi
}

wizard_install() {
  section_title "Node Agent 分步安装向导（幂等，可反复运行）"
  install_system_packages || { warn "可在解决系统包问题后重新进入向导"; press_enter; return; }
  create_or_reuse_venv  || { press_enter; return; }
  install_pip_deps      || { press_enter; return; }
  generate_env          || { press_enter; return; }
  step "5/6" "启动服务（aria2 → node），健康检查"
  manage start || { press_enter; return; }
  step "6/6" "安装完成 → 验证接口"
  verify_endpoints || true
  printf '\n  %s 安装完成！下一步可从主菜单进入 Status / Logs / Tools 。\n' "${FG_GREEN}✔${R}" >"$UI_OUT"
  press_enter
}

# ---------- 菜单 ----------
menu_install() { wizard_install; }

menu_start() {
  section_title "启动服务"
  manage start || true
  press_enter
}

menu_stop() {
  section_title "停止服务"
  manage stop || true
  press_enter
}

menu_restart() {
  section_title "重启服务"
  manage restart || true
  press_enter
}

menu_status() {
  section_title "服务状态"
  manage status || true
  printf '  %s runtime=%s  .env=%s  download=%s\n' \
    "${FG_DIM}·${R}" "${RUNTIME_DIR}" "${ENV_FILE}" \
    "${DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}" >"$UI_OUT"
  press_enter
}

menu_logs() {
  local s_idx s
  s_idx="$(menu "查看哪个服务的日志？" "node-agent|Node API" "aria2|下载器")"
  case "$s_idx" in
    0) s="node" ;;
    1) s="aria2" ;;
    *) return ;;
  esac
  local lf
  lf="$(log_file "$s")"
  mkdir -p "$(dirname "$lf")"
  touch "$lf"
  if ask_yesno "使用 tail -F 持续追更？（退出：Ctrl+C 返回菜单）" Y; then
    info "按 Ctrl+C 返回菜单"
    sleep 1
    set +e
    trap ':' INT
    tail -F "$lf" || true
    trap - INT
    set -e
  else
    tail -n 100 "$lf" 2>/dev/null | sed 's/^/  | /' >"$UI_OUT" || true
    press_enter
  fi
}

menu_tools() {
  while true; do
    section_title "工具菜单"
    local sel
    sel="$(menu "请选择" \
      "创建测试任务|POST 1MB 文件并轮询到 completed" \
      "列出所有任务|GET /api/tasks?limit=10" \
      "清理 runtime|清空 logs/pids（停止后再运行）" \
      "升级 pip 依赖|venv pip install -U -r requirements" \
      "运行 pytest|跑全部测试" \
      "返回主菜单" )"
    case "$sel" in
      0) create_smoke_task ;;
      1)
        section_title "列出任务（limit=10）"
        ensure_python_bin
        if [[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]]; then
          curl -sS --max-time 5 "$(api_base)/api/tasks?limit=10" 2>/dev/null \
            | "$PYTHON_BIN" -m json.tool 2>/dev/null \
            | sed 's/^/  | /' >"$UI_OUT" || true
        else
          curl -sS --max-time 5 "$(api_base)/api/tasks?limit=10" 2>/dev/null \
            | sed 's/^/  | /' >"$UI_OUT" || true
        fi
        ;;
      2)
        if ask_yesno "会清空 runtime 下所有日志/PID。确定？" N; then
          rm -f "$PID_DIR"/*.pid "$LOG_DIR"/*.log "$SESSION_FILE"
          ok "已清理"
        fi
        ;;
      3)
        if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
          create_or_reuse_venv || true
        fi
        PYTHON_BIN="${VENV_DIR}/bin/python"
        if [[ -x "$PYTHON_BIN" ]]; then
          info "升级 pip 依赖..."
          "$PYTHON_BIN" -m pip install -U -r "$PIP_REQUIREMENTS" 2>&1 | tail -n 10 | sed 's/^/  | /' >"$UI_OUT"
          ok "完成"
        else
          err "venv 不可用"
        fi
        ;;
      4)
        if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
          create_or_reuse_venv || true
        fi
        PYTHON_BIN="${VENV_DIR}/bin/python"
        if [[ -x "$PYTHON_BIN" ]]; then
          info "运行 pytest（可能要 10~30s）..."
          ( cd "$PROJECT_DIR" && "$PYTHON_BIN" -m pytest tests/ 2>&1 | tail -n 15 | sed 's/^/  | /' >"$UI_OUT" || true )
        else
          err "venv 不可用"
        fi
        ;;
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
    manage stop || true
    rm -rf "$RUNTIME_DIR"
    ok "runtime 已清理"
    if (( sel >= 1 )); then
      if [[ -d "$VENV_DIR" ]] && ask_yesno "删除 venv：$VENV_DIR ?" N; then
        rm -rf "$VENV_DIR"; ok "venv 已删除"
      fi
    fi
    if (( sel >= 2 )); then
      local d="${DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}"
      if [[ -d "$d" ]] && ask_yesno "删除下载目录：$d ?" N; then
        rm -rf "$d"; ok "下载目录已删除"
      fi
    fi
  fi
  press_enter
}

main_loop() {
  while true; do
    if [[ "$UI_OUT" == /dev/tty ]]; then
      clear > /dev/tty 2>/dev/null || true
    else
      clear 2>/dev/null || true
    fi
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
      8) if [[ "$UI_OUT" == /dev/tty ]]; then clear > /dev/tty 2>/dev/null || true; else clear 2>/dev/null || true; fi
         echo "Bye."; exit 0 ;;
    esac
  done
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    install|wizard) wizard_install ;;
    start|stop|restart|status|check)
      manage "$@"
      ;;
    logs)
      shift
      manage logs "$@"
      ;;
    -h|--help|help)
      echo "用法: $0                    # 进入 TUI 菜单"
      echo "      $0 install            # 运行安装向导"
      echo "      $0 start|stop|restart|status|check"
      echo "      $0 logs [node|aria2] [-f]"
      ;;
    *)
      echo "用法: $0 [install|start|stop|restart|status|logs [node|aria2] [-f]|check]" >&2
      exit 2
      ;;
  esac
else
  main_loop
fi
