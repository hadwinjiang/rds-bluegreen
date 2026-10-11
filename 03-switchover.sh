#!/usr/bin/env bash
# 蓝绿升级 —— 执行切换
#
# 用法: ./03-switchover.sh <instance-id> [--apply] [--timeout 300] [--force]
#
# 这个脚本刻意做得「哑」：先调 02-gate.sh，闸门不过就退出；过了就一条命令切换。
# 不做任何判断、不做任何重试、不在循环里等人决策。
# 切换窗口只有 10 秒量级（实测三组 9.8~10.5 秒），这里的复杂度就是风险。
#
# --force 跳过闸门（仅用于演练/排障，生产不要用）

cd "$(dirname "$0")"
. ./_common.sh
parse_apply_flag "$@"

INST="${1:-}"
[ -n "${INST}" ] || die "用法: $0 <instance-id> [--apply] [--timeout 300] [--force]"

TIMEOUT=300; FORCE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="${2:-300}"; shift 2 ;;
    --force)   FORCE=true; shift ;;
    *) shift ;;
  esac
done

BG_ID=$(state_get "${INST}" BG_ID)
[ -n "${BG_ID}" ] || die "状态文件里没有 BG_ID，请先跑 01-prepare.sh --apply"

step "切换前闸门复查"
if [ "${FORCE}" = "true" ]; then
  warn "--force：跳过闸门检查（生产环境不应使用）"
else
  if ! ./02-gate.sh "${INST}"; then
    die "闸门未通过，拒绝切换。请修复后重试。"
  fi
fi

BLUE_VER=$(rds_q "${INST}" EngineVersion)
GREEN_ID=$(state_get "${INST}" GREEN_ID)
TARGET=$(state_get "${INST}" TARGET_VERSION)

step "即将切换"
log "  蓝绿部署 : ${BG_ID}"
log "  blue     : ${INST} (${BLUE_VER})"
log "  green    : ${GREEN_ID} (${TARGET})"
log "  超时      : ${TIMEOUT}s"
log ""
log "  切换后端点改名：green → ${INST}，旧 blue → ${INST}-old1"
log "  应用无需改连接串，但必须已收紧 JVM DNS 缓存 TTL（networkaddress.cache.ttl，建议 ≤5s）"
log ""
log "  预期：AWS 报告写停机 ~1 秒；应用实测停机 7~14 秒（差值为 DNS 传播 + 连接池重建）"

if [ "${APPLY}" != "true" ]; then
  printf '\n  %sDRY-RUN%s 将执行：\n' "${_c_yel}" "${_c_off}"
  log "    aws rds switchover-blue-green-deployment \\"
  log "      --blue-green-deployment-identifier ${BG_ID} --switchover-timeout ${TIMEOUT}"
  log ""
  log "  确认后加 --apply 真正切换。"
  exit 0
fi

T0=$(date -u +%s)
step "$(date -u '+%H:%M:%S') 下发切换"
OUT=$(aws rds switchover-blue-green-deployment \
        --blue-green-deployment-identifier "${BG_ID}" \
        --switchover-timeout "${TIMEOUT}" \
        --query 'BlueGreenDeployment.Status' --output text 2>&1) || {
  log "${OUT}"
  die "切换下发失败。若报 InvalidBlueGreenDeploymentStateFault，说明 green 实例尚未 available —— 重跑 02-gate.sh 确认。"
}
ok "已下发，状态=${OUT}"

step "等待切换完成"
# RDS 在超时后会取消切换并回到 AVAILABLE —— 必须把这条路径当失败处理，不能当成功
DEADLINE=$(( T0 + TIMEOUT + 120 ))
while :; do
  ST=$(bg_q "${BG_ID}" Status)
  NOW=$(date -u +%s)
  printf '  %s  status=%s  (%ds)\n' "$(date -u '+%H:%M:%S')" "${ST}" "$((NOW-T0))"
  case "${ST}" in
    SWITCHOVER_COMPLETED)
      ok "切换完成，耗时 $((NOW-T0))s（含控制面状态滞后与轮询开销，非业务停机）"
      state_set "${INST}" SWITCHED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      break ;;
    SWITCHOVER_FAILED)
      die "切换失败（状态 SWITCHOVER_FAILED）。blue 仍在服务，未发生变更。请查 RDS 事件。" ;;
    AVAILABLE)
      # 下发后又回到 AVAILABLE ⇒ 超时被取消
      if [ $((NOW-T0)) -gt 30 ]; then
        die "切换已被取消（超时 ${TIMEOUT}s 内未能完成，状态回到 AVAILABLE）。blue 仍在服务。可排查复制延迟或长事务后重试。"
      fi ;;
  esac
  [ "${NOW}" -gt "${DEADLINE}" ] && die "等待超过 $((TIMEOUT+120))s 仍未完成，请人工介入排查"
  sleep 5
done

step "切换后的 RDS 事件（AWS 口径停机）"
aws rds describe-events --source-identifier "${INST}" --source-type db-instance --duration 10 \
  --query 'Events[].[Date,Message]' --output text 2>/dev/null | grep -iE 'switchover|downtime' || true

# ---------- 切换后自查清单 ----------
# 刻意只给「怎么查」和「什么情况该回滚」，不自动判定 ——
# 判定需要应用侧埋点与业务上下文，脚本拿不到，硬编码阈值只会误报。
step "切换后请人工确认"
OLD="${INST}-old1"
EP=$(rds_q "${INST}" Endpoint.Address)
OLD_EP=$(rds_q "${OLD}" Endpoint.Address 2>/dev/null)

log "  ① 端点已指向新实例（DNS 是否传播完）"
log "     mysql -h ${EP} -u <user> -p -e 'SELECT VERSION();'"
log "     期望 ${TARGET:-<目标版本>}；若仍是旧版本，说明客户端 DNS 缓存未过期"
log ""
log "  ② 应用错误率是否回落到基线"
log "     看监控里 5xx 曲线。蓝绿本身会有 7~14 秒 503，关键是「现在还在错吗」"
log "     出现 500（而非 503）= 真缺陷，按错误契约应立即回滚"
log ""
log "  ③ 写入确实恢复了（零错误也可能是零流量）"
log ""
log "  回滚资产：${OLD}（$(rds_q "${OLD}" EngineVersion 2>/dev/null || echo '?')，状态 $(rds_q "${OLD}" DBInstanceStatus 2>/dev/null || echo '?')）"
log ""
step "需要回滚时"
log "  蓝绿切换后不能用 switchover 回切，只能手工把流量指回 old1："
log "    1. 最快：把应用连接串指向 ${OLD} 的端点"
log "       ${OLD_EP:-<old1 端点>}"
log "    2. 或：重命名实例（会有一次停机）"
log "       aws rds modify-db-instance --db-instance-identifier ${INST} --new-db-instance-identifier ${INST}-bad --apply-immediately"
log "       aws rds modify-db-instance --db-instance-identifier ${OLD} --new-db-instance-identifier ${INST} --apply-immediately"
log ""
info "确认稳定（建议 ≥1 小时）后执行：./04-cleanup-old.sh ${INST}"
info "  ← ${OLD} 是唯一回滚资产，且持续计费：既不能忘记删，也不能太早删"
