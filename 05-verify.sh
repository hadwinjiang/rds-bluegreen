#!/usr/bin/env bash
# 蓝绿升级 —— 切换后验证与回滚判定
#
# 用法: ./05-verify.sh <instance-id> [--window 60] [--auto-rollback]
#       环境变量：DB_USER / DB_PASSWORD(_FILE) 用于版本核对
#                APP_STATS_URL           用于读应用错误计数器
#
# 回滚判据刻意写成确定性阈值 —— 不让任何模型/人在 60 秒窗口里临场判断。

# 脚本内部会 cd 到自身目录，先把可能的相对路径转成绝对路径
if [ -n "${DB_PASSWORD_FILE:-}" ] && [ -f "${DB_PASSWORD_FILE}" ]; then
  DB_PASSWORD_FILE=$(cd "$(dirname "${DB_PASSWORD_FILE}")" && pwd)/$(basename "${DB_PASSWORD_FILE}")
  export DB_PASSWORD_FILE
fi
cd "$(dirname "$0")"
. ./_common.sh

INST="${1:-}"
[ -n "${INST}" ] || die "用法: $0 <instance-id> [--window 60] [--auto-rollback]"
WINDOW=60; AUTORB=false
while [ $# -gt 0 ]; do
  case "$1" in
    --window) WINDOW="${2:-60}"; shift 2 ;;
    --auto-rollback) AUTORB=true; shift ;;
    *) shift ;;
  esac
done

TARGET=$(state_get "${INST}" TARGET_VERSION)
BG_ID=$(state_get "${INST}" BG_ID)

step "切换后验证：${INST}（观察窗口 ${WINDOW}s）"

ROLLBACK=0
rb() { printf '  %sROLLBACK%s %s\n' "${_c_red}" "${_c_off}" "$*"; ROLLBACK=1; }

# ---------- ① 端点指向的版本 ----------
step "① 端点版本核对"
EP=$(rds_q "${INST}" Endpoint.Address)
AWSVER=$(rds_q "${INST}" EngineVersion)
info "端点 ${EP}  RDS 报告版本 ${AWSVER}"
if [ -n "${TARGET}" ] && [ "${AWSVER}" != "${TARGET}" ]; then
  rb "RDS 报告版本 ${AWSVER} ≠ 目标 ${TARGET}"
else
  ok "RDS 报告版本符合预期"
fi

# 从应用视角再查一次（证明 DNS 已经指向新实例）
if [ -z "${DB_PASSWORD:-}" ] && [ -n "${DB_PASSWORD_FILE:-}" ] && [ -f "${DB_PASSWORD_FILE}" ]; then
  DB_PASSWORD=$(cat "${DB_PASSWORD_FILE}")
fi
if [ -n "${DB_PASSWORD:-}" ] && command -v mysql >/dev/null 2>&1; then
  SQLVER=$(mysql -h "${EP}" -u "${DB_USER:-admin}" -p"${DB_PASSWORD}" -N -s --connect-timeout=5 \
            -e 'SELECT VERSION();' 2>/dev/null)
  if [ -z "${SQLVER:-}" ]; then
    rb "无法连接端点查询版本 —— 可能 DNS 尚未传播或实例不可用"
  elif [ -n "${TARGET}" ] && [ "${SQLVER%%-*}" != "${TARGET}" ]; then
    rb "SELECT VERSION()=${SQLVER} ≠ 目标 ${TARGET} —— DNS 可能仍指向旧实例（检查 JVM DNS TTL）"
  else
    ok "SELECT VERSION()=${SQLVER}（DNS 已指向新实例）"
  fi
else
  warn "未提供 DB 凭证，跳过 SELECT VERSION() 核对（这一项能直接证明 DNS 已切换，建议补上）"
fi

# ---------- ② 应用侧错误计数 ----------
step "② 应用侧错误（观察 ${WINDOW}s）"
if [ -n "${APP_STATS_URL:-}" ]; then
  snap() { curl -s --max-time 5 "${APP_STATS_URL}" 2>/dev/null; }
  S0=$(snap)
  if [ -z "${S0}" ]; then
    warn "无法读取 ${APP_STATS_URL}"
  else
    g() { printf '%s' "$1" | python3 -c "import sys,json;print(json.load(sys.stdin)['counters'].get('$2',0))" 2>/dev/null || echo 0; }
    log "  起点: 503db=$(g "${S0}" errDbUnavailable) 503busy=$(g "${S0}" errOverloaded) 500=$(g "${S0}" errUnexpected) ok=$(g "${S0}" writeOk)"
    sleep "${WINDOW}"
    S1=$(snap)
    D503=$(( $(g "${S1}" errDbUnavailable) - $(g "${S0}" errDbUnavailable) ))
    DBUSY=$(( $(g "${S1}" errOverloaded)   - $(g "${S0}" errOverloaded) ))
    D500=$(( $(g "${S1}" errUnexpected)    - $(g "${S0}" errUnexpected) ))
    DOK=$((  $(g "${S1}" writeOk)          - $(g "${S0}" writeOk) ))
    DEG=$(printf '%s' "${S1}" | python3 -c "import sys,json;print(json.load(sys.stdin)['counters'].get('observedDegradedSeconds',0))" 2>/dev/null || echo 0)
    log "  ${WINDOW}s 增量: ok=+${DOK}  503db=+${D503}  503busy=+${DBUSY}  500=+${D500}"
    info "应用记录的降级窗口 observedDegradedSeconds=${DEG}（预期 7~21 秒）"

    [ "${D500}" -gt 0 ]  && rb "出现 ${D500} 个未分类 500 —— 按约定 500 表示真缺陷" || ok "无 500"
    [ "${D503}" -gt 0 ]  && rb "观察窗口内仍有 ${D503} 个 503，错误率未回落到基线" || ok "503 已回落到 0"
    [ "${DOK}"  -le 0 ]  && rb "观察窗口内写入成功数没有增长 —— 应用可能仍连不上数据库" || ok "写入已恢复（+${DOK}）"
    if python3 -c "import sys;sys.exit(0 if float('${DEG}')>60 else 1)" 2>/dev/null; then
      warn "降级窗口 ${DEG}s > 60s，远超预期的 7~21 秒 —— 检查 JVM DNS 缓存 TTL"
    fi
  fi
else
  warn "未设置 APP_STATS_URL，跳过应用侧验证 —— 这是最关键的一组判据，强烈建议接入"
fi

# ---------- ③ 回滚资产 ----------
step "③ 回滚资产"
OLD="${INST}-old1"
OST=$(rds_q "${OLD}" DBInstanceStatus)
if [ -n "${OST:-}" ] && [ "${OST}" != "None" ]; then
  OVER=$(rds_q "${OLD}" EngineVersion)
  ok "${OLD} 存在（${OVER}，状态 ${OST}）—— 回滚资产可用"
  warn "${OLD} 持续计费。确认稳定后用 06-cleanup-old.sh 删除（该步骤刻意不自动化）"
else
  warn "未找到 ${OLD} —— 无回滚资产。若需回滚只能从备份恢复"
fi

# ---------- 结论 ----------
log ""
printf '%s\n' "----------------------------------------"
if [ "${ROLLBACK}" -gt 0 ]; then
  printf '%s结论：触发回滚条件%s\n' "${_c_red}" "${_c_off}"
  log ""
  log "回滚方式（蓝绿切换后不能用 switchover 回切，需手工把流量指回 old1）："
  log "  1. 最快：把应用连接串指向 ${OLD} 的端点"
  log "     $(rds_q "${OLD}" Endpoint.Address 2>/dev/null || echo '<old1 端点>')"
  log "  2. 或：重命名实例（会有一次停机）"
  log "     aws rds modify-db-instance --db-instance-identifier ${INST} --new-db-instance-identifier ${INST}-bad --apply-immediately"
  log "     aws rds modify-db-instance --db-instance-identifier ${OLD} --new-db-instance-identifier ${INST} --apply-immediately"
  log ""
  if [ "${AUTORB}" = "true" ]; then
    warn "--auto-rollback 已指定，但回滚涉及改应用连接串或重命名实例，脚本不代为执行 —— 请按上面步骤人工处理"
  fi
  exit 1
else
  printf '%s结论：切换成功，各项验证通过%s\n' "${_c_grn}" "${_c_off}"
  log ""
  log "后续：观察一段时间（建议 ≥1 小时）后执行 ./06-cleanup-old.sh ${INST}"
  exit 0
fi
