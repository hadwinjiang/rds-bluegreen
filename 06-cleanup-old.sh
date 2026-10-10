#!/usr/bin/env bash
# 蓝绿升级 —— 清理旧 blue（-old1）与蓝绿部署记录
#
# 用法: ./06-cleanup-old.sh <instance-id> [--apply]
#
# ⚠️ 这一步刻意不进流水线、刻意要求交互确认。
#    ${INST}-old1 是切换后【唯一】的回滚资产 —— 删早了就没有退路，
#    只能从备份恢复（耗时以小时计）。
#    但它也在持续计费（实例 + 存储），所以不能忘记删。
#    建议：确认业务稳定 ≥1 小时、且已完成一轮完整业务验证后再执行。

cd "$(dirname "$0")"
. ./_common.sh
parse_apply_flag "$@"

INST="${1:-}"
[ -n "${INST}" ] || die "用法: $0 <instance-id> [--apply]"
OLD="${INST}-old1"
BG_ID=$(state_get "${INST}" BG_ID)
SWITCHED=$(state_get "${INST}" SWITCHED_AT)

step "清理：${OLD}"
show_identity

OST=$(rds_q "${OLD}" DBInstanceStatus)
if [ -z "${OST:-}" ] || [ "${OST}" = "None" ]; then
  ok "${OLD} 不存在，无需清理"
else
  OVER=$(rds_q "${OLD}" EngineVersion)
  OCLS=$(rds_q "${OLD}" DBInstanceClass)
  OALLOC=$(rds_q "${OLD}" AllocatedStorage)
  log "  实例   : ${OLD}"
  log "  版本   : ${OVER}（切换前的旧版本）"
  log "  规格   : ${OCLS} / ${OALLOC}GB"
  log "  状态   : ${OST}"
  [ -n "${SWITCHED}" ] && log "  切换于 : ${SWITCHED}"
fi

# 新实例健康性复查 —— 旧 blue 删除前最后一道保险
step "删除前复查新实例健康状况"
NST=$(rds_q "${INST}" DBInstanceStatus)
NVER=$(rds_q "${INST}" EngineVersion)
if [ "${NST}" = "available" ]; then ok "${INST} 状态 available（版本 ${NVER}）"
else blocker "${INST} 状态为 ${NST} —— 新实例不健康，绝对不要删除回滚资产"; fi

if [ "${FINDINGS_BLOCKER}" -gt 0 ]; then
  summary; exit 1
fi

log ""
printf '%s这一步不可逆：删除后无法再回滚到 %s%s\n' "${_c_yel}" "${OVER}" "${_c_off}"

if [ "${APPLY}" != "true" ]; then
  log ""
  printf '  %sDRY-RUN%s 将执行：\n' "${_c_yel}" "${_c_off}"
  [ -n "${BG_ID}" ] && log "    aws rds delete-blue-green-deployment --blue-green-deployment-identifier ${BG_ID}"
  log "    aws rds delete-db-instance --db-instance-identifier ${OLD} --skip-final-snapshot --delete-automated-backups"
  log ""
  log "  确认业务已稳定运行足够长时间后，加 --apply 执行。"
  exit 0
fi

# 交互确认（即使 --apply 也要确认，因为不可逆）
if [ -t 0 ]; then
  printf '\n请输入实例名确认删除（%s）： ' "${OLD}"
  read -r CONFIRM
  [ "${CONFIRM}" = "${OLD}" ] || die "输入不匹配，已取消"
else
  [ "${BG_FORCE_NONINTERACTIVE:-false}" = "true" ] \
    || die "非交互环境。如确需跳过确认，设置 BG_FORCE_NONINTERACTIVE=true"
fi

if [ -n "${BG_ID}" ]; then
  step "删除蓝绿部署记录（不影响实例）"
  aws rds delete-blue-green-deployment --blue-green-deployment-identifier "${BG_ID}" \
    --query 'BlueGreenDeployment.Status' --output text 2>&1 | sed 's/^/  /' || true
  sleep 20
fi

if [ -n "${OST:-}" ] && [ "${OST}" != "None" ]; then
  step "删除旧实例 ${OLD}"
  aws rds delete-db-instance --db-instance-identifier "${OLD}" \
    --skip-final-snapshot --delete-automated-backups \
    --query 'DBInstance.DBInstanceStatus' --output text 2>&1 | sed 's/^/  /'
  ok "已下发删除"
fi

log ""
info "注意：RDS 的 automated 快照无法手工删除，会随 backup-retention-period 自动过期。"
info "次日用 aws rds describe-db-snapshots 确认已清零。"
log ""
ok "清理完成。状态文件：$(state_file "${INST}")（可手工删除）"
