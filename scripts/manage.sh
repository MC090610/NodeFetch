#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# NodeFetch Node Agent - Linux 运维脚本
#
# 用法：
#   ./scripts/manage.sh [start|stop|restart|status|logs|check] [aria2|node|all]
#
#   # 一键启动 aria2 + node-agent（顺序启动，健康检查）
#   ./scripts/manage.sh start
#   # 只启动 node-agent
#   ./scripts/manage.sh start node
#   # 停止全部
#   ./scripts/manage.sh stop
#   # 查状态
#   ./scripts/manage.sh status
#   # 看日志（-f 持续追）
#   ./scripts/manage.sh logs node
#   # 只做依赖/配置自检，不启动
#   ./scripts/manage.sh check
#
# 配置来源（优先级从高到低）：
#   1) 当前 shell 环境变量
#   2) 脚本所在目录/上层的 .env（若存在自动 source）
#   3) 本脚本里的默认值
#
# 进程与日志目录：
#   ${RUNTIME_DIR:-<SCRIPT_DIR>/../runtime}/
#       pids/{aria2,node-agent}.pid
#       logs/{aria2,node-agent}.log
#
# 经验教训（避免踩坑）：
#   - 不把 "端口监听" 作为存活的唯一依据，对 aria2 用 RPC /api/node/health 这类 HTTP 接口
#   - PID 文件定点管理，stop 时先校验 cmdline 关键词再 kill，避免误杀
#   - 虚拟环境里的 python 绝对路径启动，避免依赖 shell source activate 在后台失效
#   - 统一日志输出到独立文件，失败时自动打印最后 20 行摘要给诊断
#   - 兜底搜索 pid 的匹配：命令行必须包含入口脚本关键词，避免 kill 到 grep / 包装进程
# -----------------------------------------------------------------------------
set -euo pipefail

# ---------- 路径 & 基础变量 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 读 .env（如果有）—— 只读取赋值，不执行；但我们用简单的 set -a + source 就够
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env" || true
  set +a
fi

# 可覆盖的默认值
export RUNTIME_DIR="${RUNTIME_DIR:-${PROJECT_DIR}/runtime}"
PID_DIR="${RUNTIME_DIR}/pids"
LOG_DIR="${RUNTIME_DIR}/logs"
mkdir -p "${PID_DIR}" "${LOG_DIR}"

NODE_PORT="${NODE_PORT:-8000}"
NODE_HOST="${NODE_HOST:-0.0.0.0}"
NODE_WORKERS="${NODE_WORKERS:-1}"
NODE_APP_MODULE="${NODE_APP_MODULE:-main:app}"

# python 解释器：优先 venv；其次 python3；最后 python
if [[ -x "${PROJECT_DIR}/.venv/bin/python" ]]; then
  PYTHON_BIN="${PROJECT_DIR}/.venv/bin/python"
elif [[ -x "$(command -v python3 || true)" ]]; then
  PYTHON_BIN="$(command -v python3)"
else
  PYTHON_BIN="$(command -v python)"
fi

ARIA2_BIN="${ARIA2_BIN:-aria2c}"
ARIA2_RPC_HOST="${ARIA2_RPC_HOST:-127.0.0.1}"
ARIA2_RPC_PORT="${ARIA2_RPC_PORT:-6800}"
ARIA2_RPC_SECRET="${ARIA2_RPC_SECRET:-nodefetch_secret}"
# aria2 下载目录：优先用 NODE_DOWNLOAD_DIR；否则用 PROJECT_DIR/data/downloads
DOWNLOAD_DIR="${NODE_DOWNLOAD_DIR:-${PROJECT_DIR}/data/downloads}"
mkdir -p "${DOWNLOAD_DIR}"
ARIA2_DIR="${ARIA2_DIR:-${DOWNLOAD_DIR}}"
ARIA2_SESSION_FILE="${RUNTIME_DIR}/aria2.session"
touch "${ARIA2_SESSION_FILE}"

# 健康检查参数
WAIT_MAX="${WAIT_MAX:-20}"          # 单个服务最多等待秒数
WAIT_INTERVAL="${WAIT_INTERVAL:-1}" # 轮询间隔

# ---------- 彩色输出（无颜色自动降级） ----------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'; C_INFO=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RST=''; C_OK=''; C_ERR=''; C_WARN=''; C_INFO=''; C_BOLD=''
fi

log()  { printf '[%s] %s\n' "${C_INFO}*${C_RST}" "$*"; }
ok()   { printf '[%s] %s\n' "${C_OK}√${C_RST}" "$*"; }
warn() { printf '[%s] %s\n' "${C_WARN}!${C_RST}" "$*"; }
err()  { printf '[%s] %s\n' "${C_ERR}×${C_RST}" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- 服务声明（声明式清单，后面循环处理） ----------
# 每个服务: name / desc / pidfile / logfile / start_cmd / health_cmd
# 启动顺序：aria2 在前，node-agent 依赖 aria2 健康
declare -a SERVICE_ORDER=(aria2 node)

service_exists() {
  local n="$1" i
  for i in "${SERVICE_ORDER[@]}"; do [[ "$i" == "$n" ]] && return 0; done
  return 1
}

pid_file_of() {
  case "$1" in
    aria2)  echo "${PID_DIR}/aria2.pid" ;;
    node)   echo "${PID_DIR}/node-agent.pid" ;;
  esac
}

log_file_of() {
  case "$1" in
    aria2)  echo "${LOG_DIR}/aria2.log" ;;
    node)   echo "${LOG_DIR}/node-agent.log" ;;
  esac
}

# 用于兜底搜索进程：匹配这个关键词，避免误杀
cmdline_keyword_of() {
  case "$1" in
    aria2)  echo "--enable-rpc" ;;
    node)   echo "main:app" ;;
  esac
}

# ---------- 进程管理核心 ----------

# 从 pidfile 读，或返回空；同时会校验进程存在且 cmdline 匹配
read_valid_pid() {
  local svc="$1" pidfile pid keyword
  pidfile="$(pid_file_of "$svc")"
  keyword="$(cmdline_keyword_of "$svc")"
  [[ -f "$pidfile" ]] || return 1
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  # 进程存在 + 命令行匹配关键词
  if kill -0 "$pid" 2>/dev/null; then
    local cmd
    cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    if [[ -z "$keyword" || "$cmd" == *"$keyword"* ]]; then
      echo "$pid"
      return 0
    fi
  fi
  # 无效 pidfile 清掉
  rm -f "$pidfile"
  return 1
}

# 兜底搜索：pidfile 失效了，但进程还在（重启场景常见）
find_running_pid_by_keyword() {
  local svc="$1" keyword
  keyword="$(cmdline_keyword_of "$svc")"
  [[ -n "$keyword" ]] || return 1
  # -a：匹配全命令行；-x 不用；去掉 grep / pgrep 自己
  pgrep -a -f "$keyword" 2>/dev/null \
    | awk '{print $1}' \
    | head -n 1
}

is_running() {
  local svc="$1" pid
  pid="$(read_valid_pid "$svc" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    echo "$pid"
    return 0
  fi
  pid="$(find_running_pid_by_keyword "$svc" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  # 顺手补写 pidfile（下轮就不用兜底搜了）
  echo "$pid" > "$(pid_file_of "$svc")"
  echo "$pid"
}

# 分级 kill：TERM 等 WAIT_MAX/2，不行再 KILL
kill_pid_gently() {
  local pid="$1" svc="${2:-svc}" waited=0
  local soft_timeout=$(( WAIT_MAX / 2 ))
  [[ -n "$pid" ]] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
  log "正在停止 $svc (PID=$pid) [SIGTERM]"
  kill -TERM "$pid" 2>/dev/null || true
  while (( waited < soft_timeout )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      ok "$svc (PID=$pid) 已优雅退出"
      return 0
    fi
    sleep "$WAIT_INTERVAL"
    waited=$(( waited + WAIT_INTERVAL ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "$svc (PID=$pid) 未在 ${soft_timeout}s 内退出，发送 SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
  fi
}

# ---------- 启动命令 ----------
build_aria2_start_cmd() {
  # 输出完整命令（数组）；bash 里用 eval-safe 拼接即可
  printf '"%s" ' \
    "$ARIA2_BIN" \
    --enable-rpc \
    --rpc-listen-all \
    --rpc-listen-port="$ARIA2_RPC_PORT" \
    --rpc-secret="$ARIA2_RPC_SECRET" \
    --rpc-allow-origin-all \
    --dir="$ARIA2_DIR" \
    --input-file="$ARIA2_SESSION_FILE" \
    --save-session="$ARIA2_SESSION_FILE" \
    --save-session-interval=60 \
    --max-concurrent-downloads=5 \
    --continue \
    --log-level=notice \
    --file-allocation=none \
    --disable-ipv6=false
}

build_node_start_cmd() {
  # 统一把常用变量写进环境，确保 uvicorn 启动时 uvicorn 进程的 env 有
  printf 'env NODE_PORT="%s" NODE_HOST="%s" DOWNLOAD_DIR="%s" NODE_DOWNLOAD_DIR="%s" ARIA2_RPC_URL="%s" ARIA2_RPC_SECRET="%s" "%s" -m uvicorn "%s" --host "%s" --port "%s" --workers "%s" ' \
    "$NODE_PORT" \
    "$NODE_HOST" \
    "$DOWNLOAD_DIR" \
    "$DOWNLOAD_DIR" \
    "http://${ARIA2_RPC_HOST}:${ARIA2_RPC_PORT}/rpc" \
    "$ARIA2_RPC_SECRET" \
    "$PYTHON_BIN" \
    "$NODE_APP_MODULE" \
    "$NODE_HOST" \
    "$NODE_PORT" \
    "$NODE_WORKERS"
}

start_service() {
  local svc="$1" pidfile logfile pid cmd rc waited=0 healthy=0
  service_exists "$svc" || die "未知服务: $svc"
  pidfile="$(pid_file_of "$svc")"
  logfile="$(log_file_of "$svc")"

  pid="$(is_running "$svc" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    ok "$svc 已在运行（PID=$pid）→ 跳过启动"
    return 0
  fi

  log "启动 $svc ..."
  case "$svc" in
    aria2) cmd="$(build_aria2_start_cmd)" ;;
    node)  cmd="$(build_node_start_cmd)" ;;
  esac

  # 后台启动，统一把 stdout/stderr 写到 logfile；PID=$! 直接写入 pidfile
  # 注意：用 nohup 让它能脱离 shell，即使 ssh 断了也继续跑
  # shellcheck disable=SC2086
  (
    cd "$PROJECT_DIR"
    if [[ "$svc" == "node" ]]; then
      # node 应用：确保 .env 被 pydantic-settings 发现
      # 用 env -C 的兼容性不好，直接 cd 到位即可
      exec nohup bash -lc "${cmd}" >>"$logfile" 2>&1 </dev/null
    else
      exec nohup bash -lc "${cmd}" >>"$logfile" 2>&1 </dev/null
    fi
  ) &
  # 上面后台子进程是个 bash wrapper，但内部 exec 过 nohup... 会替换成目标进程；
  # 实际上为了稳定，我们稍微等 1s，再用关键词查找真实 PID 写入 pidfile
  sleep 1
  local real_pid
  real_pid="$(find_running_pid_by_keyword "$svc" 2>/dev/null || true)"
  if [[ -n "$real_pid" ]]; then
    echo "$real_pid" > "$pidfile"
    pid="$real_pid"
  else
    # 兜底：$! 的那个 pid；大概率是 nohup/bash，但总比没强
    pid="$!"
    echo "$pid" > "$pidfile"
  fi

  # 健康检查
  while (( waited < WAIT_MAX )); do
    if health_check "$svc" >/dev/null 2>&1; then
      healthy=1
      break
    fi
    # 若进程死了：提前终止
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep "$WAIT_INTERVAL"
    waited=$(( waited + WAIT_INTERVAL ))
  done

  if (( healthy )); then
    ok "$svc 启动成功（PID=$(cat "$pidfile" || echo unknown)，等待 ${waited}s 后健康）"
    return 0
  fi

  err "$svc 启动失败（${WAITED:-$waited}s 未通过健康检查）"
  echo "  ├─ 日志位置：${C_BOLD}${logfile}${C_RST}"
  echo "  └─ 最后 20 行："
  tail -n 20 "$logfile" 2>/dev/null | sed 's/^/     | /' || echo "     | (无日志)"
  # 失败清理：确保不会残留
  local dpid
  dpid="$(read_valid_pid "$svc" 2>/dev/null || true)"
  [[ -n "$dpid" ]] && kill_pid_gently "$dpid" "$svc"
  rm -f "$pidfile"
  return 2
}

# ---------- 健康检查（可插拔策略） ----------
health_check() {
  local svc="$1"
  case "$svc" in
    aria2)
      # Aria2 RPC HTTP 连通性：向 endpoint 发一个空 POST。
      # 正确 aria2 会返回 200 OK（哪怕没有认证信息），错误时 401。只要 HTTP 连通就算活。
      local url="http://${ARIA2_RPC_HOST}:${ARIA2_RPC_PORT}/jsonrpc"
      local http_code
      http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 2 \
        -X POST "$url" -d '{"jsonrpc":"2.0","method":"aria2.getGlobalStat","id":"health"}' 2>/dev/null || echo 000)"
      # 200 OK 或 401 Unauthorized 都算 RPC 在监听
      [[ "$http_code" == "200" || "$http_code" == "401" ]]
      ;;
    node)
      # Node Agent 自带 /api/node/health
      local url="http://127.0.0.1:${NODE_PORT}/api/node/health"
      local http_code
      http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "$url" 2>/dev/null || echo 000)"
      [[ "$http_code" == "200" ]]
      ;;
    *) return 1 ;;
  esac
}

# ---------- stop / status ----------
stop_service() {
  local svc="$1" pid
  service_exists "$svc" || die "未知服务: $svc"
  pid="$(is_running "$svc" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    ok "$svc 未运行"
    # 清理旧 pidfile
    rm -f "$(pid_file_of "$svc")"
    return 0
  fi
  kill_pid_gently "$pid" "$svc"
  rm -f "$(pid_file_of "$svc")"
}

status_service() {
  local svc="$1" pidfile pid running_text healthy_text
  service_exists "$svc" || die "未知服务: $svc"
  pidfile="$(pid_file_of "$svc")"
  pid="$(is_running "$svc" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    running_text="${C_OK}RUNNING${C_RST} (PID=$pid)"
    if health_check "$svc" >/dev/null 2>&1; then
      healthy_text="${C_OK}HEALTHY${C_RST}"
    else
      healthy_text="${C_WARN}UNHEALTHY${C_RST}"
    fi
  else
    running_text="${C_ERR}STOPPED${C_RST}"
    healthy_text="-"
  fi
  printf '  %-11s running=%-36s health=%-22s log=%s\n' \
    "${C_BOLD}${svc}${C_RST}" \
    "$running_text" \
    "$healthy_text" \
    "$(log_file_of "$svc")"
}

# ---------- 依赖自检 ----------
check_deps() {
  local any_fail=0
  log "检查系统依赖..."

  if command -v aria2c >/dev/null 2>&1; then
    ok "aria2c: $(aria2c --version | head -n 1)"
  else
    err "aria2c 未安装。请执行：sudo apt install -y aria2  # 或 sudo yum install aria2"
    any_fail=1
  fi

  if command -v curl >/dev/null 2>&1; then
    ok "curl: $(curl --version | head -n 1 | cut -d' ' -f1-2)"
  else
    err "curl 未安装。请执行：sudo apt install -y curl"
    any_fail=1
  fi

  if [[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    local ver
    ver="$("$PYTHON_BIN" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null || echo unknown)"
    ok "python: $PYTHON_BIN ($ver)"
  else
    err "未找到可用的 python。可在 ${PROJECT_DIR} 里创建 .venv：python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
    any_fail=1
  fi

  log "检查 Python 依赖..."
  if [[ -n "$PYTHON_BIN" ]] && "$PYTHON_BIN" -c 'import fastapi, uvicorn, sqlalchemy, aiosqlite, pydantic_settings, httpx' 2>/dev/null; then
    ok "核心 pip 依赖已就绪（fastapi/uvicorn/sqlalchemy/aiosqlite/pydantic_settings/httpx）"
  else
    warn "pip 依赖未齐全。执行：${PYTHON_BIN:-python3} -m pip install -r ${PROJECT_DIR}/requirements.txt"
    any_fail=1
  fi

  log "检查目录与写入..."
  if [[ -w "$DOWNLOAD_DIR" ]]; then
    ok "download dir writable: $DOWNLOAD_DIR"
  else
    mkdir -p "$DOWNLOAD_DIR" 2>/dev/null && ok "created & writable: $DOWNLOAD_DIR" || {
      err "无法写入 download dir: $DOWNLOAD_DIR"; any_fail=1; }
  fi
  if mkdir -p "$RUNTIME_DIR" && [[ -w "$RUNTIME_DIR" ]]; then
    ok "runtime dir writable: $RUNTIME_DIR"
  else
    err "无法写入 runtime dir: $RUNTIME_DIR"; any_fail=1
  fi

  if (( any_fail )); then
    err "检查失败：请解决上面的问题后再启动。"
    return 1
  fi
  ok "全部依赖就绪 ✅"
}

# ---------- 子命令 ----------
usage() {
  cat <<EOF
${C_BOLD}NodeFetch Node Agent 启动脚本${C_RST}
用法：
  $0 ${C_BOLD}start${C_RST}   [aria2|node|all]   启动（默认 all，按顺序启动）
  $0 ${C_BOLD}stop${C_RST}    [aria2|node|all]   停止（分级 SIGTERM → SIGKILL）
  $0 ${C_BOLD}restart${C_RST} [aria2|node|all]   重启
  $0 ${C_BOLD}status${C_RST}  [aria2|node|all]   查看运行 + 健康状态
  $0 ${C_BOLD}logs${C_RST}    [aria2|node] [-f]  查看日志（-f 追更）
  $0 ${C_BOLD}check${C_RST}                      依赖/目录/权限自检，不启动
EOF
}

targets_from_arg() {
  local t="${1:-all}"
  case "$t" in
    all)    echo "${SERVICE_ORDER[@]}" ;;
    aria2)  echo "aria2" ;;
    node)   echo "node" ;;
    *)      die "不认识的服务: $t (支持: aria2|node|all)" ;;
  esac
}

cmd_start()   { local t; for t in $(targets_from_arg "${1:-all}"); do start_service "$t" || exit $?; done; }
cmd_stop()    { local t; for t in $(targets_from_arg "${1:-all}"); do stop_service  "$t"; done; }
cmd_restart() { cmd_stop "${1:-all}"; sleep 1; cmd_start "${1:-all}"; }
cmd_status()  { echo "=== NodeFetch runtime: ${RUNTIME_DIR} ==="
                local t; for t in $(targets_from_arg "${1:-all}"); do status_service "$t"; done; }
cmd_logs() {
  local svc="${1:-node}" follow=0
  [[ "${2:-}" == "-f" || "${1:-}" == "-f" ]] && follow=1
  [[ "$svc" == "-f" ]] && svc="node"
  service_exists "$svc" || die "不认识的服务: $svc"
  local lf
  lf="$(log_file_of "$svc")"
  touch "$lf"
  if (( follow )); then
    exec tail -F "$lf"
  else
    exec tail -n 100 "$lf"
  fi
}

cmd_check() { check_deps; }

main() {
  local sub="${1:-start}"
  case "$sub" in
    start)   shift; cmd_start   "${1:-all}" ;;
    stop)    shift; cmd_stop    "${1:-all}" ;;
    restart) shift; cmd_restart "${1:-all}" ;;
    status)  shift; cmd_status  "${1:-all}" ;;
    logs)    shift; cmd_logs    "${1:-node}" "${2:-}" ;;
    check)   cmd_check ;;
    -h|--help|help) usage ;;
    *)         err "未知子命令：$sub"; usage >&2; exit 2 ;;
  esac
}

main "$@"
