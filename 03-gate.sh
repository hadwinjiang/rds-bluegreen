#!/usr/bin/env bash
# 蓝绿升级 —— 切换闸门（只读，只输出 PASS/FAIL，绝不执行切换）
#
# 用法: ./03-gate.sh <instance-id> [--lag-check]
#       --lag-check 额外用心跳表精确测同步延迟（需要 mysql 客户端与 DB 凭证）
#                   环境变量：DB_USER（默认 admin）、DB_PASSWORD 或 DB_PASSWORD_FILE
#
# 退出码：0=可以切换  1=还不能切换
#
# ⚠️ 为什么闸门不能只看同步延迟 —— 实测踩过的坑：
#      蓝绿部署状态 = AVAILABLE      ← 看起来可以切了
#      green 实例状态 = modifying    ← 但实例自己还没好
#      → switchover 直接报 InvalidBlueGreenDeploymentStateFault
#    所以「部署 AVAILABLE」≠「可以切换」，必须逐项查到实例级。

# 脚本内部会 cd 到自身目录，先把可能的相对路径转成绝对路径
if [ -n "${DB_PASSWORD_FILE:-}" ] && [ -f "${DB_PASSWORD_FILE}" ]; then
  DB_PASSWORD_FILE=$(cd "$(dirname "${DB_PASSWORD_FILE}")" && pwd)/$(basename "${DB_PASSWORD_FILE}")
  export DB_PASSWORD_FILE
fi
cd "$(dirname "$0")"
. ./_common.sh

INST="${1:-}"
[ -n "${INST}" ] || die "用法: $0 <instance-id> [--lag-check]"
LAGCHECK=false
for a in "$@"; do [ "${a}" = "--lag-check" ] && LAGCHECK=true; done

BG_ID=$(state_get "${INST}" BG_ID)
TARGET=$(state_get "${INST}" TARGET_VERSION)
[ -n "${BG_ID}" ] || die "状态文件里没有 BG_ID，请先跑 02-create-bluegreen.sh（状态文件：$(state_file "${INST}")）"

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
# 粗筛：CloudWatch ReplicaLag（粒度 60 秒，做闸门偏粗，但零依赖）
if [ -n "${GREEN_ID:-}" ] && [ "${GREEN_ID}" != "None" ]; then
  LAG=$(aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag \
    --dimensions Name=DBInstanceIdentifier,Value="${GREEN_ID}" \
    --start-time "$(date -u -v-15M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '15 min ago' '+%Y-%m-%dT%H:%M:%SZ')" \
    --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --period 60 --statistics Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[-1].Maximum' --output text 2>/dev/null)
  if [ -z "${LAG:-}" ] || [ "${LAG}" = "None" ]; then
    warn "拿不到 ReplicaLag 指标 —— 建议加 --lag-check 用心跳表精确测量"
  else
    LAGI=$(printf '%.0f' "${LAG}" 2>/dev/null || echo 999)
    if [ "${LAGI}" -le 5 ]; then ok "ReplicaLag=${LAGI}s（CloudWatch，粒度 60s）"
    else blocker "ReplicaLag=${LAGI}s 过大，切换会丢失未同步的写入"; fi
  fi
fi

# 精判：心跳表（粒度毫秒，推荐做最终闸门）
if [ "${LAGCHECK}" = "true" ]; then
  step "⑥b 心跳表精确延迟"
  require_cmd mysql python3
  DB_USER="${DB_USER:-admin}"
  if [ -z "${DB_PASSWORD:-}" ] && [ -n "${DB_PASSWORD_FILE:-}" ] && [ -f "${DB_PASSWORD_FILE}" ]; then
    DB_PASSWORD=$(cat "${DB_PASSWORD_FILE}")
  fi
  if [ -z "${DB_PASSWORD:-}" ]; then
    warn "未提供 DB_PASSWORD / DB_PASSWORD_FILE，跳过心跳检查"
  else
    BEP=$(rds_q "${INST}" Endpoint.Address)
    GEP=$(rds_q "${GREEN_ID}" Endpoint.Address)
    M() { mysql -h "$1" -u "${DB_USER}" -p"${DB_PASSWORD}" -N -s --connect-timeout=5 2>/dev/null; }
    # 在 blue 上写心跳（green 是只读副本，会同步过去）
    echo "CREATE DATABASE IF NOT EXISTS _bgops;
          CREATE TABLE IF NOT EXISTS _bgops.heartbeat (id INT PRIMARY KEY, ts DATETIME(3));
          REPLACE INTO _bgops.heartbeat VALUES (1, NOW(3));" | M "${BEP}" >/dev/null
    sleep 2
    BT=$(echo "SELECT UNIX_TIMESTAMP(ts) FROM _bgops.heartbeat WHERE id=1;" | M "${BEP}")
    GT=$(echo "SELECT UNIX_TIMESTAMP(ts) FROM _bgops.heartbeat WHERE id=1;" | M "${GEP}")
    if [ -z "${BT:-}" ] || [ -z "${GT:-}" ]; then
      warn "心跳读取失败（blue=${BT:-空} green=${GT:-空}），可能是网络不可达或 green 尚未同步该表"
    else
      D=$(python3 -c "print(f'{abs(float('${BT}')-float('${GT}')):.3f}')")
      if python3 -c "import sys;sys.exit(0 if float('${D}')<=1.0 else 1)"; then
        ok "心跳延迟 ${D}s（≤1s）"
      else
        blocker "心跳延迟 ${D}s 过大"
      fi
    fi
  fi
else
  info "未启用 --lag-check。CloudWatch ReplicaLag 粒度 60 秒，做最终闸门偏粗；正式切换前建议启用"
fi

# ---------- 闸门 ⑦ 应用容错是否真的在工作 ----------
step "⑦ 应用容错自检（可选）"
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
  log "下一步：./04-switchover.sh ${INST} --apply"
fi
exit ${RC}
