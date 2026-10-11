#!/usr/bin/env bash
# 蓝绿升级 —— 切换闸门（只读，只输出 PASS/FAIL，绝不执行切换）
#
# 用法: ./02-gate.sh <instance-id>
#
# 退出码：0=可以切换  1=还不能切换
#
# ⚠️ 为什么闸门不能只看同步延迟 —— 实测踩过的坑：
#      蓝绿部署状态 = AVAILABLE      ← 看起来可以切了
#      green 实例状态 = modifying    ← 但实例自己还没好
#      → switchover 直接报 InvalidBlueGreenDeploymentStateFault
#    所以「部署 AVAILABLE」≠「可以切换」，必须逐项查到实例级。

cd "$(dirname "$0")"
. ./_common.sh

INST="${1:-}"
[ -n "${INST}" ] || die "用法: $0 <instance-id>"

BG_ID=$(state_get "${INST}" BG_ID)
TARGET=$(state_get "${INST}" TARGET_VERSION)
[ -n "${BG_ID}" ] || die "状态文件里没有 BG_ID，请先跑 01-prepare.sh --apply（状态文件：$(state_file "${INST}")）"

step "切换闸门：${INST} / ${BG_ID}"
[ -n "${TARGET}" ] && info "目标版本：${TARGET}"

# ---------- 闸门 ① 部署状态 ----------
step "① 蓝绿部署状态"
ST=$(bg_q "${BG_ID}" Status)
case "${ST}" in
  AVAILABLE)             ok "Status=AVAILABLE" ;;
  PROVISIONING)          blocker "Status=PROVISIONING —— 仍在准备中，继续等待" ;;
  SWITCHOVER_COMPLETED)  warn "Status=SWITCHOVER_COMPLETED —— 已经切换过了，无需再切" ;;
  SWITCHOVER_IN_PROGRESS) blocker "Status=SWITCHOVER_IN_PROGRESS —— 切换正在进行" ;;
  *)                     blocker "Status=${ST} —— 非预期状态" ;;
esac

# ---------- 闸门 ② 三个 Task ----------
step "② 准备任务（三项必须全部 COMPLETED）"
TASKS=$(aws rds describe-blue-green-deployments --blue-green-deployment-identifier "${BG_ID}" \
  --query 'BlueGreenDeployments[0].Tasks[].[Name,Status]' --output text 2>/dev/null)
if [ -z "${TASKS}" ]; then
  warn "拿不到 Tasks 列表"
else
  while read -r N S; do
    [ -z "${N:-}" ] && continue
    if [ "${S}" = "COMPLETED" ]; then ok "${N}=${S}"; else blocker "${N}=${S}（未完成）"; fi
  done <<<"${TASKS}"
fi

# ---------- 闸门 ③ green 实例自身状态（最容易漏的一条）----------
step "③ green 实例状态"
GREEN=$(aws rds describe-blue-green-deployments --blue-green-deployment-identifier "${BG_ID}" \
  --query 'BlueGreenDeployments[0].SwitchoverDetails[0].TargetMember' --output text 2>/dev/null)
GREEN_ID="${GREEN##*:}"
if [ -z "${GREEN_ID}" ] || [ "${GREEN_ID}" = "None" ]; then
  blocker "拿不到 green 实例标识（准备可能尚未进行到创建副本）"
else
  state_set "${INST}" GREEN_ID "${GREEN_ID}"
  GST=$(rds_q "${GREEN_ID}" DBInstanceStatus)
  GVER=$(rds_q "${GREEN_ID}" EngineVersion)
  GCLS=$(rds_q "${GREEN_ID}" DBInstanceClass)
  info "green=${GREEN_ID}  规格=${GCLS}"
  if [ "${GST}" = "available" ]; then
    ok "green 实例状态 available"
  else
    blocker "green 实例状态=${GST}（必须 available，否则 switchover 会报 InvalidBlueGreenDeploymentStateFault）"
  fi

  # ---------- 闸门 ④ green 版本 ----------
  step "④ green 引擎版本"
  if [ -n "${TARGET}" ]; then
    if [ "${GVER}" = "${TARGET}" ]; then ok "green=${GVER} = 目标版本"
    else blocker "green=${GVER} ≠ 目标 ${TARGET}"; fi
  else
    info "green=${GVER}（状态文件无目标版本，跳过比对）"
  fi

  # 规格一致性提醒
  BLUE_CLS=$(rds_q "${INST}" DBInstanceClass)
  [ "${GCLS}" = "${BLUE_CLS}" ] && ok "blue/green 规格一致（${BLUE_CLS}）" \
    || warn "blue=${BLUE_CLS} 与 green=${GCLS} 规格不同 —— 切换同时会变更规格，请确认是有意的"
fi

# ---------- 闸门 ⑤ SwitchoverDetails ----------
step "⑤ 切换就绪标记"
SD=$(aws rds describe-blue-green-deployments --blue-green-deployment-identifier "${BG_ID}" \
  --query 'BlueGreenDeployments[0].SwitchoverDetails[].Status' --output text 2>/dev/null)
if [ -z "${SD}" ]; then warn "拿不到 SwitchoverDetails"
else
  BAD=$(printf '%s\n' ${SD} | grep -vx 'AVAILABLE' || true)
  [ -z "${BAD}" ] && ok "SwitchoverDetails 全部 AVAILABLE" \
    || blocker "SwitchoverDetails 存在非 AVAILABLE：${SD}"
fi

# ---------- 闸门 ⑥ 同步延迟 ----------
step "⑥ 同步延迟"
# CloudWatch ReplicaLag，粒度 60 秒，零依赖。
#
# 为什么够用：RDS 的 switchover 本身会先把 blue 置为只读、等 green 追平，追不平就超时取消
# （见 03-switchover.sh 对 AVAILABLE 回落的处理），所以「不丢写入」由 AWS 保证，
# 这道闸门的作用是提前发现「延迟大到切换很可能超时」，不需要毫秒级精度。
if [ -n "${GREEN_ID:-}" ] && [ "${GREEN_ID}" != "None" ]; then
  LAG=$(aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag \
    --dimensions Name=DBInstanceIdentifier,Value="${GREEN_ID}" \
    --start-time "$(date -u -v-15M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '15 min ago' '+%Y-%m-%dT%H:%M:%SZ')" \
    --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --period 60 --statistics Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[-1].Maximum' --output text 2>/dev/null)
  if [ -z "${LAG:-}" ] || [ "${LAG}" = "None" ]; then
    warn "拿不到 ReplicaLag 指标（green 可能刚创建，指标还没上报）—— 等一个采样周期后重跑"
  else
    LAGI=$(printf '%.0f' "${LAG}" 2>/dev/null || echo 999)
    if [ "${LAGI}" -le 5 ]; then ok "ReplicaLag=${LAGI}s（CloudWatch，粒度 60s）"
    else blocker "ReplicaLag=${LAGI}s 过大 —— 切换很可能因追不平而超时被取消"; fi
  fi
fi

# ---------- 闸门 ⑦ 选项组一致性 ----------
#
# 为什么要在切换前查：create-blue-green-deployment 没有指定选项组的参数，
# 所以 01 只能检查、不能强制。跨大版本时 green 会被套上默认选项组 ——
# 这是最后一道能发现它的关口，切换后 blue 已改名 -old1。
step "⑦ 选项组一致性"
if [ -n "${GREEN_ID:-}" ] && [ "${GREEN_ID}" != "None" ]; then
  BLUE_OG=$(rds_q "${INST}" 'OptionGroupMemberships[0].OptionGroupName')
  GREEN_OG=$(rds_q "${GREEN_ID}" 'OptionGroupMemberships[0].OptionGroupName')
  GREEN_OG_SYNC=$(rds_q "${GREEN_ID}" 'OptionGroupMemberships[0].Status')
  info "blue=${BLUE_OG}  green=${GREEN_OG}（状态 ${GREEN_OG_SYNC}）"

  if [ "${BLUE_OG}" = "${GREEN_OG}" ]; then
    ok "blue/green 选项组一致"
  else
    # 名字不同不必然是问题（跨大版本时本来就该是不同的两个组），
    # 但必须确认 green 上的选项集合与 blue 等价 —— 默认组通常是空的。
    BLUE_OPTS=$(aws rds describe-option-groups --option-group-name "${BLUE_OG}" \
      --query 'OptionGroupsList[0].Options[].OptionName' --output text 2>/dev/null | tr '\t' ' ')
    GREEN_OPTS=$(aws rds describe-option-groups --option-group-name "${GREEN_OG}" \
      --query 'OptionGroupsList[0].Options[].OptionName' --output text 2>/dev/null | tr '\t' ' ')
    if [ "${BLUE_OPTS}" = "${GREEN_OPTS}" ]; then
      warn "选项组名不同（${BLUE_OG} → ${GREEN_OG}），但选项集合一致（${BLUE_OPTS:-无}）"
      warn "  → 选项「设置值」未逐项比对，跨大版本时请人工复核"
    else
      blocker "green 丢了 blue 的选项：blue=[${BLUE_OPTS:-无}] green=[${GREEN_OPTS:-无}]"
      log "    切换前修复：aws rds modify-db-instance --db-instance-identifier ${GREEN_ID} \\"
      log "                  --option-group-name <目标大版本的选项组> --apply-immediately"
      log "    等 green 回到 available 且选项组 in-sync 后重跑本闸门"
    fi
  fi

  [ "${GREEN_OG_SYNC}" = "in-sync" ] || blocker "green 选项组状态 ${GREEN_OG_SYNC}（非 in-sync）"
fi

# ---------- 闸门 ⑧ 应用容错是否真的在工作 ----------
step "⑧ 应用容错自检（可选）"
if [ -n "${APP_STATS_URL:-}" ]; then
  BC=$(curl -s --max-time 5 "${APP_STATS_URL}" 2>/dev/null \
       | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["circuitBreakers"]["dbWrite"]["bufferedCalls"])' 2>/dev/null)
  if [ -z "${BC:-}" ]; then warn "无法从 ${APP_STATS_URL} 读取熔断器指标"
  elif [ "${BC}" -gt 0 ] 2>/dev/null; then ok "熔断器 bufferedCalls=${BC}（>0，容错注解确实生效）"
  else blocker "熔断器 bufferedCalls=0 —— Resilience4j 注解未生效（最常见原因是 Spring AOP 自调用），此时切换无容错保护"; fi
else
  info "未设置 APP_STATS_URL，跳过。强烈建议设置 —— 这是唯一能证明容错注解真生效的检查"
fi

log ""
summary
RC=$?
if [ ${RC} -eq 0 ]; then
  log ""
  log "下一步：./03-switchover.sh ${INST} --apply"
fi
exit ${RC}
