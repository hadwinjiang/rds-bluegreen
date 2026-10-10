#!/usr/bin/env bash
# 蓝绿升级 —— 创建蓝绿环境（可重入）
#
# 用法: ./02-create-bluegreen.sh <instance-id> <target-version> [--apply]
#                               [--target-class <class>] [--target-pg <parameter-group>]
#
# 默认 dry-run，只打印将执行什么。加 --apply 才真正创建。
#
# 可重入：若该实例已存在未切换的蓝绿部署，复用它而不是新建。
#
# 这一步对业务零影响 —— 实测三组全程 blue 正常服务，应用无感。
# 耗时很长（实测 113GB→1h52m，206GB→3h10m，496GB→4h24m，约 38min/100GB），
# 因为 green = 对 blue 做快照 → 恢复 → gp3 惰性填充 → 升级引擎 → 配置备份。

cd "$(dirname "$0")"
. ./_common.sh
parse_apply_flag "$@"

INST="${1:-}"; TARGET="${2:-}"
[ -n "${INST}" ] && [ -n "${TARGET}" ] || die "用法: $0 <instance-id> <target-version> [--apply] [--target-class C] [--target-pg P]"

TCLASS=""; TPG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target-class) TCLASS="${2:-}"; shift 2 ;;
    --target-pg)    TPG="${2:-}";    shift 2 ;;
    *) shift ;;
  esac
done

require_cmd aws
step "创建蓝绿环境：${INST} → ${TARGET}"
show_identity

ARN=$(rds_q "${INST}" DBInstanceArn)
[ -n "${ARN}" ] && [ "${ARN}" != "None" ] || die "实例不存在：${INST}"
info "blue ARN: ${ARN}"

# ---------- 可重入：先看有没有现成的 ----------
EXIST_ID=$(aws rds describe-blue-green-deployments \
  --query "BlueGreenDeployments[?Source=='${ARN}' && Status!='SWITCHOVER_COMPLETED' && Status!='DELETING'].BlueGreenDeploymentIdentifier" \
  --output text 2>/dev/null | awk '{print $1}')

if [ -n "${EXIST_ID}" ]; then
  ST=$(bg_q "${EXIST_ID}" Status)
  ok "已存在蓝绿部署 ${EXIST_ID}（状态 ${ST}），复用，不新建"
  state_set "${INST}" BG_ID "${EXIST_ID}"
else
  # 命名约束：[a-zA-Z](?:-?[a-zA-Z0-9]+)* —— 必须字母开头、不得有连续横线、不得以横线结尾
  SAFE=$(printf '%s' "${INST}" | tr -c 'a-zA-Z0-9' '-' | tr -s '-' | sed 's/^-*//; s/-*$//' | cut -c1-40 | sed 's/-*$//')
  NAME="bg-${SAFE}-$(date -u +%m%d%H%M)"
  CMD=(aws rds create-blue-green-deployment
       --blue-green-deployment-name "${NAME}"
       --source "${ARN}"
       --target-engine-version "${TARGET}")
  [ -n "${TCLASS}" ] && CMD+=(--target-db-instance-class "${TCLASS}")
  [ -n "${TPG}" ]    && CMD+=(--target-db-parameter-group-name "${TPG}")

  if [ -z "${TPG}" ]; then
    info "未指定 --target-pg：green 将继承 blue 的参数组。切换后再改参数组需要额外一次重启"
  fi
  if [ -z "${TCLASS}" ]; then
    info "未指定 --target-class：green 将继承 blue 的实例规格"
  fi

  if [ "${APPLY}" != "true" ]; then
    printf '  %sDRY-RUN%s 将执行：\n          %s\n' "${_c_yel}" "${_c_off}" "${CMD[*]}"
    log ""
    log "确认无误后加 --apply 真正创建。"
    exit 0
  fi

  if ! OUT=$("${CMD[@]}" --query 'BlueGreenDeployment.[BlueGreenDeploymentIdentifier,Status]' --output text 2>&1); then
    log "${OUT}"
    die "创建失败。常见原因：backup-retention-period=0 / 目标版本非法 / 存在 pending 修改 / 名称不合规。先跑 01-preflight-rds.sh 排查。"
  fi
  BG_ID=$(echo "${OUT}" | awk '{print $1}')
  ok "已创建：${BG_ID}（状态 $(echo "${OUT}" | awk '{print $2}')）"
  state_set "${INST}" BG_ID "${BG_ID}"
  EXIST_ID="${BG_ID}"
fi

state_set "${INST}" TARGET_VERSION "${TARGET}"
state_set "${INST}" BLUE_ARN "${ARN}"

log ""
info "状态已写入：$(state_file "${INST}")"
info "下一步：用 03-gate.sh 轮询闸门。准备完成前不要尝试切换。"
log ""
log "  watch -n 60 ./03-gate.sh ${INST}"
