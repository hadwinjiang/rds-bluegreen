#!/usr/bin/env bash
# 蓝绿升级 —— 执行切换
#
# 用法: ./04-switchover.sh <instance-id> [--apply] [--timeout 300] [--force]
#
# 这个脚本刻意做得「哑」：先调 03-gate.sh，闸门不过就退出；过了就一条命令切换。
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
[ -n "${BG_ID}" ] || die "状态文件里没有 BG_ID，请先跑 02-create-bluegreen.sh"

step "切换前闸门复查"
if [ "${FORCE}" = "true" ]; then
  warn "--force：跳过闸门检查（生产环境不应使用）"
else
  if ! ./03-gate.sh "${INST}" "${LAGCHECK_FLAG:-}"; then
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
log "  应用无需改连接串，但必须已收紧 JVM DNS 缓存 TTL（见 00-preflight-app.sh）"
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
  die "切换下发失败。若报 InvalidBlueGreenDeploymentStateFault，说明 green 实例尚未 available —— 重跑 03-gate.sh 确认。"
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
      ok "切换完成，耗时 $((NOW-T0))s（含闸门与轮询开销）"
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

log ""
info "下一步（立刻执行，用于验证与回滚判定）：./05-verify.sh ${INST}"
info "确认稳定后再执行：./06-cleanup-old.sh ${INST}   ← ${INST}-old1 是唯一回滚资产，且持续计费"
