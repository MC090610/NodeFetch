#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# NodeFetch Node Agent - Linux 运维脚本
#
# 用法：
#   ./scripts/manage.sh [start|stop|restart|status|logs|check] [aria2|node|all]
#
#   ./scripts/manage.sh start            # aria2 → node，带健康检查
#   ./scripts/manage.sh start node       # 只启动 node-agent
#   ./scripts/manage.sh stop             # 先 node 后 aria2
#   ./scripts/manage.sh status
#   ./scripts/manage.sh logs node -f
#   ./scripts/manage.sh check            # 依赖/配置自检，不启动
#
# 配置优先级：当前环境变量 > 项目根 .env > 本脚本默认值
# 键名与 config.py / .env.example 对齐：
#   API_HOST API_PORT DOWNLOAD_DIR STORAGE_LIMIT_GB TTL_MINUTES
#   ARIA2_RPC_URL ARIA2_RPC_SECRET CONCURRENT_LIMIT NODE_ID ...
#
# 进程与日志：
#   ${RUNTIME_DIR:-<PROJECT>/runtime}/
#       pids/{aria2,node-agent}.pid
#       logs/{aria2,node-agent}.log
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${PROJECT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env" || true
  set +a
fi

# 旧脚本曾把键名写错（NODE_PORT / NODE_DOWNLOAD_DIR / NODE_TTL_SECONDS 等）。
# 这里只做读取兼容，新写入一律走 config.py 的名字。
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
: "${NODE_ID:=dev-local-01}"
: "${NODE_WORKERS:=1}"
: "${NODE_APP_MODULE:=main:app}"

export RUNTIME_DIR="${RUNTIME_DIR:-${PROJECT_DIR}/runtime}"
PID_DIR="${RUNTIME_DIR}/pids"
LOG_DIR="${RUNTIME_DIR}/logs"
mkdir -p "${PID_DIR}" "${LOG_DIR}" "${DOWNLOAD_DIR}"

ARIA2_BIN="${ARIA2_BIN:-aria2c}"
ARIA2_RPC_HOST="${ARIA2_RPC_HOST:-127.0.0.1}"
ARIA2_RPC_PORT="${ARIA2_RPC_PORT:-6800}"
ARIA2_RPC_SECRET="${ARIA2_RPC_SECRET:-}"
ARIA2_RPC_URL="${ARIA2_RPC_URL:-http://${ARIA2_RPC_HOST}:${ARIA2_RPC_PORT}/rpc}"
ARIA2_DIR="${ARIA2_DIR:-${DOWNLOAD_DIR}}"
ARIA2_SESSION_FILE="${RUNTIME_DIR}/aria2.session"
touch "${ARIA2_SESSION_FILE}"

WAIT_MAX="${WAIT_MAX:-20}"
WAIT_INTERVAL="${WAIT_INTERVAL:-1}"

if [[ -x "${PROJECT_DIR}/.venv/bin/python" ]]; then
  PYTHON_BIN="${PROJECT_DIR}/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python)"
else
  PYTHON_BIN=""
fi

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

# 启动顺序：aria2 → node；停止顺序反过来。
declare -a START_ORDER=(aria2 node)
declare -a STOP_ORDER=(node aria2)

service_exists() {
  local n="$1" i
  for i in "${START_ORDER[@]}"; do [[ "$i" == "$n" ]] && return 0; done
  return 1
}

pid_file_of() {
  case "$1" in
    aria2) echo "${PID_DIR}/aria2.pid" ;;
    node)  echo "${PID_DIR}/node-agent.pid" ;;
    *)     return 1 ;;
  esac
}

log_file_of() {
  case "$1" in
    aria2) echo "${LOG_DIR}/aria2.log" ;;
    node)  echo "${LOG_DIR}/node-agent.log" ;;
    *)     return 1 ;;
  esac
}

# 命令行匹配尽量绑到本项目的路径/端口，避免误杀别的 aria2 / uvicorn。
cmdline_keyword_of() {
  case "$1" in
    aria2) printf '%s' "--save-session=${ARIA2_SESSION_FILE}" ;;
    node)  printf '%s' "uvicorn ${NODE_APP_MODULE} --host ${API_HOST} --port ${API_PORT}" ;;
    *)     return 1 ;;
  esac
}

read_valid_pid() {
  local svc="$1" pidfile pid keyword cmd
  pidfile="$(pid_file_of "$svc")"
  keyword="$(cmdline_keyword_of "$svc")"
  [[ -f "$pidfile" ]] || return 1
  pid="$(tr -d ' \t\r\n' < "$pidfile" 2>/dev/null || true)"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || { rm -f "$pidfile"; return 1; }
  if kill -0 "$pid" 2>/dev/null; then
    cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    if [[ -z "$keyword" || "$cmd" == *"$keyword"* ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  fi
  rm -f "$pidfile"
  return 1
}

find_running_pid_by_keyword() {
  local keyword
  keyword="$(cmdline_keyword_of "$1")"
  [[ -n "$keyword" ]] || return 1
  # 不用 pgrep -f：关键词里有路径/参数，ps+awk 更可控，也不会匹配到本脚本。
  ps -ax -o pid=,args= 2>/dev/null \
    | awk -v k="$keyword" 'index($0, k) { print $1; exit }'
}

is_running() {
  local svc="$1" pid
  pid="$(read_valid_pid "$svc" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    printf '%s\n' "$pid"
    return 0
  fi
  pid="$(find_running_pid_by_keyword "$svc" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  printf '%s\n' "$pid" > "$(pid_file_of "$svc")"
  printf '%s\n' "$pid"
}

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

health_check() {
  local svc="$1" http_code
  case "$svc" in
    aria2)
      local url="http://${ARIA2_RPC_HOST}:${ARIA2_RPC_PORT}/jsonrpc"
      local payload
      if [[ -n "$ARIA2_RPC_SECRET" ]]; then
        payload="{\"jsonrpc\":\"2.0\",\"method\":\"aria2.getGlobalStat\",\"id\":\"health\",\"params\":[\"token:${ARIA2_RPC_SECRET}\"]}"
      else
        payload='{"jsonrpc":"2.0","method":"aria2.getGlobalStat","id":"health"}'
      fi
      http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        -X POST "$url" -d "$payload" 2>/dev/null || echo 000)"
      # 200 = RPC 正常；401 = 端口在听但密钥不对（仍算进程活着，check 里会单独警告）
      [[ "$http_code" == "200" || "$http_code" == "401" ]]
      ;;
    node)
      local health_host="$API_HOST"
      if [[ "$health_host" == "0.0.0.0" || "$health_host" == "::" || "$health_host" == "*" ]]; then
        health_host="127.0.0.1"
      fi
      http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
        "http://${health_host}:${API_PORT}/api/node/health" 2>/dev/null || echo 000)"
      [[ "$http_code" == "200" ]]
      ;;
    *) return 1 ;;
  esac
}

start_service() {
  local svc="$1" pidfile logfile pid waited=0 healthy=0
  service_exists "$svc" || die "未知服务: $svc"
  pidfile="$(pid_file_of "$svc")"
  logfile="$(log_file_of "$svc")"

  pid="$(is_running "$svc" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    ok "$svc 已在运行（PID=$pid）→ 跳过启动"
    return 0
  fi

  if [[ "$svc" == "node" && -z "$PYTHON_BIN" ]]; then
    die "未找到 python。请先创建 venv：python3 -m venv ${PROJECT_DIR}/.venv && ${PROJECT_DIR}/.venv/bin/pip install -r ${PROJECT_DIR}/requirements.txt"
  fi
  if [[ "$svc" == "aria2" ]] && ! command -v "$ARIA2_BIN" >/dev/null 2>&1; then
    die "未找到 ${ARIA2_BIN}。请先安装 aria2。"
  fi
  if [[ "$svc" == "aria2" && -z "$ARIA2_RPC_SECRET" ]]; then
    warn "ARIA2_RPC_SECRET 为空，aria2 RPC 无密钥。请在 .env 中设置。"
  fi

  log "启动 $svc ..."
  mkdir -p "$DOWNLOAD_DIR" "$ARIA2_DIR"
  : > "$logfile"

  # 直接 nohup 目标进程（bash 的 nohup 是 builtin），不要 bash -l：login shell 会把 cwd 切回家目录。
  (
    cd "$PROJECT_DIR"
    case "$svc" in
      aria2)
        exec "$ARIA2_BIN" \
          --enable-rpc \
          --rpc-listen-all=false \
          --rpc-listen-port="$ARIA2_RPC_PORT" \
          --rpc-secret="$ARIA2_RPC_SECRET" \
          --dir="$ARIA2_DIR" \
          --input-file="$ARIA2_SESSION_FILE" \
          --save-session="$ARIA2_SESSION_FILE" \
          --save-session-interval=60 \
          --max-concurrent-downloads="$CONCURRENT_LIMIT" \
          --continue \
          --log-level=notice \
          --file-allocation=none
        ;;
      node)
        # 子进程继承已 source 的 .env；这里再显式覆盖计算值，避免旧键名干扰。
        export API_HOST API_PORT DOWNLOAD_DIR STORAGE_LIMIT_GB TTL_MINUTES
        export MAX_FILE_SIZE_GB CONCURRENT_LIMIT NODE_ID
        export ARIA2_RPC_URL ARIA2_RPC_SECRET
        exec "$PYTHON_BIN" -m uvicorn "$NODE_APP_MODULE" \
          --host "$API_HOST" \
          --port "$API_PORT" \
          --workers "$NODE_WORKERS"
        ;;
    esac
  ) >>"$logfile" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$pidfile"

  while (( waited < WAIT_MAX )); do
    if health_check "$svc" >/dev/null 2>&1; then
      healthy=1
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep "$WAIT_INTERVAL"
    waited=$(( waited + WAIT_INTERVAL ))
  done

  if (( healthy )); then
    ok "$svc 启动成功（PID=$pid，等待 ${waited}s 后健康）"
    return 0
  fi

  err "$svc 启动失败（${waited}s 未通过健康检查）"
  echo "  ├─ 日志位置：${C_BOLD}${logfile}${C_RST}"
  echo "  └─ 最后 20 行："
  tail -n 20 "$logfile" 2>/dev/null | sed 's/^/     | /' || echo "     | (无日志)"
  kill_pid_gently "$pid" "$svc" || true
  rm -f "$pidfile"
  return 2
}

stop_service() {
  local svc="$1" pid
  service_exists "$svc" || die "未知服务: $svc"
  pid="$(is_running "$svc" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    ok "$svc 未运行"
    rm -f "$(pid_file_of "$svc")"
    return 0
  fi
  kill_pid_gently "$pid" "$svc"
  rm -f "$(pid_file_of "$svc")"
}

status_service() {
  local svc="$1" pid running_text healthy_text
  service_exists "$svc" || die "未知服务: $svc"
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

check_deps() {
  local any_fail=0
  log "检查系统依赖..."

  if command -v aria2c >/dev/null 2>&1; then
    ok "aria2c: $(aria2c --version 2>/dev/null | head -n 1)"
  else
    err "aria2c 未安装。Debian/Ubuntu: sudo apt install -y aria2"
    any_fail=1
  fi

  if command -v curl >/dev/null 2>&1; then
    ok "curl: $(curl --version | head -n 1 | cut -d' ' -f1-2)"
  else
    err "curl 未安装。Debian/Ubuntu: sudo apt install -y curl"
    any_fail=1
  fi

  if [[ -n "$PYTHON_BIN" ]] && { [[ -x "$PYTHON_BIN" ]] || command -v "$PYTHON_BIN" >/dev/null 2>&1; }; then
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

  log "检查配置键名（config.py）..."
  if [[ -f "${PROJECT_DIR}/.env" ]]; then
    if grep -qE '^NODE_PORT=|^NODE_HOST=|^NODE_DOWNLOAD_DIR=|^NODE_TTL_SECONDS=|^NODE_STORAGE_LIMIT_GB=' "${PROJECT_DIR}/.env" 2>/dev/null; then
      warn ".env 里还有旧键名（NODE_PORT / NODE_DOWNLOAD_DIR / NODE_TTL_SECONDS 等）。脚本会兼容读取，但 Python 只会认 API_PORT / DOWNLOAD_DIR / TTL_MINUTES / STORAGE_LIMIT_GB。请运行安装向导重新生成，或手动改名。"
    else
      ok ".env 键名与 config.py 对齐"
    fi
  else
    warn "没有 ${PROJECT_DIR}/.env ，将使用默认值。建议从 .env.example 复制一份。"
  fi
  if [[ -z "$ARIA2_RPC_SECRET" ]]; then
    warn "ARIA2_RPC_SECRET 未设置"
    any_fail=1
  else
    ok "ARIA2_RPC_SECRET 已设置"
  fi

  log "检查目录与写入..."
  if mkdir -p "$DOWNLOAD_DIR" && [[ -w "$DOWNLOAD_DIR" ]]; then
    ok "download dir writable: $DOWNLOAD_DIR"
  else
    err "无法写入 download dir: $DOWNLOAD_DIR"; any_fail=1
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
  ok "全部依赖就绪"
}

usage() {
  cat <<EOF
${C_BOLD}NodeFetch Node Agent 启动脚本${C_RST}
用法：
  $0 ${C_BOLD}start${C_RST}   [aria2|node|all]   启动（默认 all：先 aria2 后 node）
  $0 ${C_BOLD}stop${C_RST}    [aria2|node|all]   停止（默认 all：先 node 后 aria2）
  $0 ${C_BOLD}restart${C_RST} [aria2|node|all]   重启
  $0 ${C_BOLD}status${C_RST}  [aria2|node|all]   查看运行 + 健康状态
  $0 ${C_BOLD}logs${C_RST}    [aria2|node] [-f]  查看日志（-f 追更）
  $0 ${C_BOLD}check${C_RST}                      依赖/目录/配置自检，不启动
EOF
}

order_for() {
  local action="$1" target="${2:-all}"
  case "$target" in
    all)
      if [[ "$action" == "stop" ]]; then
        printf '%s\n' "${STOP_ORDER[@]}"
      else
        printf '%s\n' "${START_ORDER[@]}"
      fi
      ;;
    aria2|node) printf '%s\n' "$target" ;;
    *) die "不认识的服务: $target (支持: aria2|node|all)" ;;
  esac
}

cmd_start() {
  local t
  for t in $(order_for start "${1:-all}"); do
    start_service "$t" || exit $?
  done
}

cmd_stop() {
  local t
  for t in $(order_for stop "${1:-all}"); do
    stop_service "$t"
  done
}

cmd_restart() {
  cmd_stop "${1:-all}"
  sleep 1
  cmd_start "${1:-all}"
}

cmd_status() {
  echo "=== NodeFetch runtime: ${RUNTIME_DIR} ==="
  local t
  for t in $(order_for start "${1:-all}"); do
    status_service "$t"
  done
}

cmd_logs() {
  local svc="node" follow=0 arg
  for arg in "$@"; do
    case "$arg" in
      -f|--follow) follow=1 ;;
      aria2|node) svc="$arg" ;;
      "" ) ;;
      *) die "logs 用法: $0 logs [aria2|node] [-f]" ;;
    esac
  done
  service_exists "$svc" || die "不认识的服务: $svc"
  local lf
  lf="$(log_file_of "$svc")"
  mkdir -p "$(dirname "$lf")"
  touch "$lf"
  if (( follow )); then
    tail -F "$lf" || true
  else
    tail -n 100 "$lf" || true
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
    logs)    shift; cmd_logs    "$@" ;;
    check)   cmd_check ;;
    -h|--help|help) usage ;;
    *)         err "未知子命令：$sub"; usage >&2; exit 2 ;;
  esac
}

main "$@"
