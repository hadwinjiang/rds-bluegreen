#!/usr/bin/env bash
# 蓝绿升级 —— 预检 + 创建蓝绿环境（一步完成）
#
# 用法: ./01-prepare.sh <instance-id> <target-version> [--apply]
#                      [--target-class <class>] [--target-pg <parameter-group>]
#                      [--auto-target-pg]
#
# 默认 dry-run：跑完 9 项预检，打印将执行的创建命令，不做任何变更。
# 加 --apply 才真正创建蓝绿环境。
#
# 预检有阻断项时拒绝创建 —— 即使加了 --apply。所以不存在「预检没过就建了」这条路径。
#
# 可重入：若该实例已存在未切换的蓝绿部署，复用它而不是新建。
#
# 创建阶段对业务零影响（实测全程 blue 正常服务），但耗时很长
# （实测 113GB→1h52m，206GB→3h10m，496GB→4h24m，约 38min/100GB），
# 因为 green = 对 blue 做快照 → 恢复 → gp3 惰性填充 → 升级引擎 → 配置备份。
#
# 为什么预检不只看「当前版本是否等于某个常量」：
#   真正会让蓝绿创建失败或中途失败的是下面这几项，版本只是其中最弱的一条。
#   实测教训：
#     - backup-retention-period=0 → 蓝绿直接不可用（我们第一批实例因此全部重建）
#     - 存储余量不足 → green 恢复/升级中途失败
#       （500GB 那组只剩 62.79 GiB / 634 GiB，RDS 已发低存储告警）

cd "$(dirname "$0")"
. ./_common.sh
parse_apply_flag "$@"

INST="${1:-}"; TARGET="${2:-}"
[ -n "${INST}" ] && [ -n "${TARGET}" ] \
  || die "用法: $0 <instance-id> <target-version> [--apply] [--target-class C] [--target-pg P] [--auto-target-pg]"

TCLASS=""; TPG=""; AUTO_PG=false
while [ $# -gt 0 ]; do
  case "$1" in
    --target-class)   TCLASS="${2:-}"; shift 2 ;;
    --target-pg)      TPG="${2:-}";    shift 2 ;;
    --auto-target-pg) AUTO_PG=true;    shift ;;
    *) shift ;;
  esac
done

require_cmd aws python3

step "蓝绿准备：${INST} → ${TARGET}"
show_identity

# ---------- 基本信息 ----------
read -r STATUS CUR ENGINE CLASS ALLOC MULTIAZ RETENTION PGNAME OGNAME <<<"$(
  aws rds describe-db-instances --db-instance-identifier "${INST}" \
    --query 'DBInstances[0].[DBInstanceStatus,EngineVersion,Engine,DBInstanceClass,AllocatedStorage,MultiAZ,BackupRetentionPeriod,DBParameterGroups[0].DBParameterGroupName,OptionGroupMemberships[0].OptionGroupName]' \
    --output text 2>/dev/null)" || die "实例不存在或无权访问：${INST}"
[ -n "${STATUS:-}" ] || die "实例不存在或无权访问：${INST}"

ARN=$(rds_q "${INST}" DBInstanceArn)
info "引擎=${ENGINE} ${CUR}  规格=${CLASS}  存储=${ALLOC}GB  Multi-AZ=${MULTIAZ}"
info "参数组=${PGNAME}  选项组=${OGNAME}"
info "blue ARN: ${ARN}"

# ==================== 预检 ====================

step "① 实例状态"
if [ "${STATUS}" = "available" ]; then ok "状态 available"
else blocker "状态为 ${STATUS}，必须是 available 才能创建蓝绿"; fi

step "② 待生效的修改（pending-modified-values）"
PENDING=$(aws rds describe-db-instances --db-instance-identifier "${INST}" \
  --query 'DBInstances[0].PendingModifiedValues' --output json 2>/dev/null | tr -d ' \n')
case "${PENDING:-}" in
  '{}'|'null'|'') ok "无待生效修改" ;;
  *)              blocker "存在待生效修改，会与蓝绿冲突，请先等其完成：${PENDING}" ;;
esac

step "③ 自动备份（蓝绿的硬前提）"
if [ "${RETENTION}" -ge 1 ] 2>/dev/null; then
  ok "backup-retention-period=${RETENTION}（≥1，binlog 已启用）"
else
  blocker "backup-retention-period=${RETENTION} —— 蓝绿要求 ≥1，否则 binlog 未启用、蓝绿不可用"
  info "修复：aws rds modify-db-instance --db-instance-identifier ${INST} --backup-retention-period 1 --apply-immediately"
fi

step "④ 目标版本是否为合法升级路径"
VALID=$(aws rds describe-db-engine-versions --engine "${ENGINE}" --engine-version "${CUR}" \
  --query 'DBEngineVersions[0].ValidUpgradeTarget[].EngineVersion' --output text 2>/dev/null)
if [ -z "${VALID}" ]; then
  warn "无法获取 ${CUR} 的合法升级目标列表，跳过该项检查"
elif printf '%s\n' ${VALID} | grep -qx "${TARGET}"; then
  ok "${CUR} → ${TARGET} 是合法升级路径"
else
  blocker "${TARGET} 不在 ${CUR} 的合法升级目标中。可选：$(echo ${VALID} | tr ' ' ',')"
fi

step "⑤ binlog_format（仅 MySQL < 8.4 需要）"
# MySQL 8.4 已移除 binlog_format 参数（ROW 是唯一格式），所以 8.4+ 不必检查。
# 覆盖 5.7 / 8.0 的通用方案必须查这一项，不能一刀切。
MAJOR=$(echo "${CUR}" | cut -d. -f1-2)
if python3 -c "import sys;sys.exit(0 if tuple(map(int,'${MAJOR}'.split('.')))>=(8,4) else 1)"; then
  ok "MySQL ${MAJOR} 已移除 binlog_format，无需检查"
else
  BF=$(aws rds describe-db-parameters --db-parameter-group-name "${PGNAME}" \
        --query 'Parameters[?ParameterName==`binlog_format`].ParameterValue' --output text 2>/dev/null)
  case "${BF:-}" in
    ROW|MIXED|STATEMENT) ok "binlog_format=${BF}" ;;
    "") warn "参数组未显式设置 binlog_format（默认参数组无法修改），若蓝绿创建失败请改用自定义参数组并设为 ROW" ;;
    *)  blocker "binlog_format=${BF} 不受支持，蓝绿要求 ROW/MIXED/STATEMENT" ;;
  esac
fi

step "⑥ 存储余量"
FREE_BYTES=$(aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value="${INST}" \
  --start-time "$(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '30 min ago' '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 300 --statistics Minimum \
  --query 'sort_by(Datapoints,&Timestamp)[-1].Minimum' --output text 2>/dev/null)
if [ -z "${FREE_BYTES:-}" ] || [ "${FREE_BYTES}" = "None" ]; then
  warn "拿不到 FreeStorageSpace 指标（实例可能刚创建），请手工确认存储余量"
else
  read -r FREE_GB PCT <<<"$(python3 -c "
f=${FREE_BYTES}/1024**3; a=${ALLOC}
print(f'{f:.1f} {100*f/a:.0f}')")"
  info "空闲 ${FREE_GB}GB / 分配 ${ALLOC}GB（${PCT}%）"
  if   [ "${PCT}" -lt 10 ]; then blocker "空闲存储仅 ${PCT}%。RDS 在空闲 < 1GB 时会为防数据损坏直接停库；green 恢复与升级都需要余量"
  elif [ "${PCT}" -lt 20 ]; then warn "空闲存储 ${PCT}%，建议先扩容再做蓝绿"
  else ok "存储余量充足（${PCT}%）"; fi
fi

step "⑦ 数据量与准备时间预估"
# 实测拟合：蓝绿准备（创建 → green 可切换）约 38 分钟 / 100GB
#   113GB → 1h52m    206GB → 3h10m    496GB → 4h24m
USED_GB=$(python3 -c "
try:
    f=${FREE_BYTES}/1024**3
    print(f'{${ALLOC} - f:.0f}')
except Exception:
    print('')" 2>/dev/null)
if [ -n "${USED_GB:-}" ]; then
  read -r MINS HH MM <<<"$(python3 -c "
g=max(float('${USED_GB}'),1.0)
m=int(40 + g*0.38)  # 固定开销 ~40min + 38min/100GB
print(m, m//60, m%60)")"
  info "已用数据约 ${USED_GB}GB → 准备时间预估 ≈ ${HH}h${MM}m（实测拟合：固定 ~40min + 38min/100GB）"
  info "若维护窗口为 02:00，本脚本最晚应在前一日 $(python3 -c "
m=${MINS}+30
h=(2*60-m)%(24*60); print(f'{h//60:02d}:{h%60:02d}')") 启动（含 30 分钟缓冲）"
else
  warn "无法估算数据量，准备时间预估跳过"
fi

step "⑧ 已存在的蓝绿部署"
# 只看未切换完成的 —— 历史上切换完成的记录不影响本次，不该报警
EXIST_ID=$(aws rds describe-blue-green-deployments \
  --query "BlueGreenDeployments[?Source=='${ARN}' && Status!='SWITCHOVER_COMPLETED' && Status!='DELETING'].BlueGreenDeploymentIdentifier" \
  --output text 2>/dev/null | awk '{print $1}')
if [ -z "${EXIST_ID}" ]; then
  ok "无进行中的蓝绿部署"
else
  info "已存在蓝绿部署 ${EXIST_ID}（状态 $(bg_q "${EXIST_ID}" Status)）—— 本次复用，不新建"
fi

# ---------- ⑨ 参数组：既是检查项，也决定 green 用哪个 ----------
#
# AWS 行为：不传 --target-db-parameter-group-name 时，green 继承 blue 的参数组。
# 但继承只在「同一参数组族」内成立。大版本升级（如 mysql8.0 → mysql8.4）族会变，
# blue 的参数组对 green 非法，RDS 会给 green 套上 default.<新族> ——
# 所有自定义参数（字符集、时区、max_connections、慢查询阈值……）静默丢失，
# 切换后才发现，而那时 blue 已经改名成 -old1 了。
#
# 所以这里：同族 → 把 blue 的参数组显式传过去；跨族 → 阻断，要求操作员明确选择。
step "⑨ 参数组"

pg_family() {  # pg_family <parameter-group-name>
  aws rds describe-db-parameter-groups --db-parameter-group-name "$1" \
    --query 'DBParameterGroups[0].DBParameterGroupFamily' --output text 2>/dev/null
}

BLUE_PG="${PGNAME}"
BLUE_FAM=$(pg_family "${BLUE_PG}")
TARGET_FAM=$(aws rds describe-db-engine-versions --engine "${ENGINE}" --engine-version "${TARGET}" \
  --query 'DBEngineVersions[0].DBParameterGroupFamily' --output text 2>/dev/null)
[ -n "${TARGET_FAM}" ] && [ "${TARGET_FAM}" != "None" ] \
  || die "查不到 ${ENGINE} ${TARGET} 的参数组族 —— 目标版本可能不存在于本区域"
info "blue 参数组 ${BLUE_PG}（族 ${BLUE_FAM}）→ 目标版本族 ${TARGET_FAM}"

# 实例必须与参数组同步，否则 AWS 拒绝创建蓝绿
PG_SYNC=$(rds_q "${INST}" 'DBParameterGroups[0].ParameterApplyStatus')
if [ "${PG_SYNC}" = "in-sync" ]; then
  ok "参数组状态 in-sync"
else
  blocker "参数组状态为 ${PG_SYNC}（非 in-sync）—— 蓝绿要求实例与参数组同步，需先重启 ${INST}"
fi

# PG_MODE 只记录决策，实际派生动作留到闸门之后，避免「预检没过但已经建了参数组」
PG_MODE=reuse
if [ -n "${TPG}" ]; then
  TPG_FAM=$(pg_family "${TPG}")
  if [ -z "${TPG_FAM}" ] || [ "${TPG_FAM}" = "None" ]; then
    blocker "--target-pg 指定的参数组不存在：${TPG}"
  elif [ "${TPG_FAM}" != "${TARGET_FAM}" ]; then
    blocker "参数组 ${TPG} 属于族 ${TPG_FAM}，与目标版本 ${TARGET} 的族 ${TARGET_FAM} 不符"
  else
    PG_MODE=explicit
    ok "green 参数组：${TPG}（操作员指定，族匹配）"
  fi
elif [ "${BLUE_FAM}" = "${TARGET_FAM}" ]; then
  # 同族（小版本升级）—— 显式传 blue 的参数组。
  # 效果与隐式继承一致，但写进命令行后 dry-run 看得见、事后可审计。
  TPG="${BLUE_PG}"
  case "${BLUE_PG}" in
    default.*) warn "blue 用的是默认参数组 ${BLUE_PG}，green 沿用。生产实例通常应有自定义参数组" ;;
    *)         ok "green 参数组：${TPG}（与 blue 一致，同族 ${TARGET_FAM}，已显式指定）" ;;
  esac
elif [ "${AUTO_PG}" = "true" ]; then
  TPG=$(printf '%s-%s' "${BLUE_PG}" "$(printf '%s' "${TARGET_FAM}" | tr -c 'a-zA-Z0-9' '-' | tr -s '-')" | cut -c1-255)
  PG_MODE=derive
  warn "跨参数组族升级（${BLUE_FAM} → ${TARGET_FAM}），--auto-target-pg 已指定：将派生 ${TPG}"
  warn "自动派生的参数组必须人工复核后再切换 —— 大版本间参数语义可能变化，不只是增删"
else
  blocker "跨参数组族升级：blue 的 ${BLUE_PG}（族 ${BLUE_FAM}）对 ${TARGET}（族 ${TARGET_FAM}）非法"
  log "    若不指定 green 的参数组，RDS 会套上 default.${TARGET_FAM}，blue 上所有自定义参数静默丢失，"
  log "    且切换后 blue 已改名为 ${INST}-old1。二选一："
  log "      1) 自己建好目标族参数组并复核： $0 ${INST} ${TARGET} --target-pg <你的参数组> --apply"
  log "      2) 从 ${BLUE_PG} 自动派生再复核： $0 ${INST} ${TARGET} --auto-target-pg"
fi

# ---------- ⑩ 选项组（option group）----------
#
# 和参数组同一类问题，但 create-blue-green-deployment **没有** --target-option-group
# 这种参数（CLI 只提供 parameter group / instance class / 存储 这几项），
# 所以脚本无法像参数组那样显式指定 —— 只能检查 + 告知。
#
# 选项组绑定「引擎 + 大版本」。同大版本内（8.4.7 → 8.4.11）blue 的选项组对 green 依然合法，
# green 继承它；跨大版本（8.0 → 8.4）blue 的选项组非法，RDS 只能给 green 套 default，
# MARIADB_AUDIT_PLUGIN 等选项连带其设置一起丢失，而且没有创建时的补救手段。
step "⑩ 选项组"

OG_IS_DEFAULT=false
case "${OGNAME}" in default:*|default.*|""|None) OG_IS_DEFAULT=true ;; esac

if [ "${OG_IS_DEFAULT}" = "true" ]; then
  ok "blue 使用默认选项组（${OGNAME:-无}）—— green 沿用默认，无需处理"
else
  OG_MEV=$(aws rds describe-option-groups --option-group-name "${OGNAME}" \
    --query 'OptionGroupsList[0].MajorEngineVersion' --output text 2>/dev/null)
  OG_OPTS=$(aws rds describe-option-groups --option-group-name "${OGNAME}" \
    --query 'OptionGroupsList[0].Options[].OptionName' --output text 2>/dev/null)
  # 目标版本的大版本号：mysql 用 major.minor（8.0 / 8.4），与选项组的 MajorEngineVersion 对齐
  TGT_MEV=$(echo "${TARGET}" | cut -d. -f1-2)
  info "blue 选项组 ${OGNAME}（大版本 ${OG_MEV}，选项：${OG_OPTS:-无}）→ 目标大版本 ${TGT_MEV}"

  OG_SYNC=$(rds_q "${INST}" 'OptionGroupMemberships[0].Status')
  if [ "${OG_SYNC}" = "in-sync" ]; then
    ok "选项组状态 in-sync"
  else
    blocker "选项组状态为 ${OG_SYNC}（非 in-sync）—— 先让它生效再做蓝绿"
  fi

  if [ "${OG_MEV}" = "${TGT_MEV}" ]; then
    ok "同大版本，green 将继承 ${OGNAME}（选项与设置一并保留）"
  else
    blocker "跨大版本升级：选项组 ${OGNAME}（${OG_MEV}）对 ${TARGET}（${TGT_MEV}）非法"
    log "    create-blue-green-deployment 没有指定选项组的参数，RDS 会给 green 套默认选项组，"
    log "    ${OG_OPTS:-自定义选项} 连带设置一起丢失，且无法在创建时补救。正确做法："
    log "      1) 先建 ${TGT_MEV} 的选项组，把同样的选项和设置配好："
    log "         aws rds create-option-group --option-group-name <new-og> \\"
    log "           --engine-name ${ENGINE} --major-engine-version ${TGT_MEV} --option-group-description '...'"
    log "      2) 本脚本创建蓝绿后、切换前，把 green 改到新选项组并等它 in-sync："
    log "         aws rds modify-db-instance --db-instance-identifier <green-id> \\"
    log "           --option-group-name <new-og> --apply-immediately"
    log "      3) 重跑 02-gate.sh 确认 green 仍 available，再切换"
  fi
fi

# ==================== 闸门：预检不过就到此为止 ====================
log ""
if ! summary; then
  log ""
  die "预检未通过，拒绝创建蓝绿环境。修掉上面的阻断项后重跑。"
fi

state_set "${INST}" TARGET_VERSION "${TARGET}"
state_set "${INST}" BLUE_ARN "${ARN}"
state_set "${INST}" BLUE_PG "${BLUE_PG}"
state_set "${INST}" BLUE_OG "${OGNAME}"

# ==================== 创建 ====================

# 自动派生目标族参数组：从 blue 搬运所有被显式改过的参数（Source=user）
create_target_pg_from_blue() {
  local newpg="$1" fam="$2"
  if ! aws rds describe-db-parameter-groups --db-parameter-group-name "${newpg}" >/dev/null 2>&1; then
    mutate_quiet "创建参数组 ${newpg}（族 ${fam}）" \
      aws rds create-db-parameter-group --db-parameter-group-name "${newpg}" \
        --db-parameter-group-family "${fam}" \
        --description "green PG for ${INST} ${TARGET}, derived from ${BLUE_PG}" \
      || die "创建参数组 ${newpg} 失败"
  else
    info "参数组 ${newpg} 已存在，复用（可重入）"
  fi

  local userparams
  userparams=$(aws rds describe-db-parameters --db-parameter-group-name "${BLUE_PG}" --source user \
    --query 'Parameters[].[ParameterName,ParameterValue,ApplyMethod]' --output text 2>/dev/null)
  if [ -z "${userparams}" ]; then
    info "blue 参数组没有自定义参数，${newpg} 保持目标族默认值"
    return 0
  fi

  # 目标族里可改的参数名清单 —— 跨大版本时有参数被移除（如 8.4 移除了 innodb_log_file_size）
  local modifiable
  modifiable=$(aws rds describe-engine-default-parameters --db-parameter-group-family "${fam}" \
    --query 'EngineDefaults.Parameters[?IsModifiable==`true`].ParameterName' --output text 2>/dev/null | tr '\t' '\n')

  local args="" n=0 skipped=""
  while IFS=$'\t' read -r pname pvalue pmethod; do
    [ -n "${pname}" ] || continue
    if ! printf '%s\n' "${modifiable}" | grep -qx "${pname}"; then
      skipped="${skipped} ${pname}"
      continue
    fi
    [ "${pmethod}" = "None" ] && pmethod="pending-reboot"
    args="${args} ParameterName=${pname},ParameterValue=${pvalue},ApplyMethod=${pmethod}"
    n=$((n+1))
  done <<EOF
${userparams}
EOF

  if [ -n "${skipped}" ]; then
    warn "以下参数在族 ${fam} 中不存在或不可改，已跳过：${skipped# }"
    warn "  → 若其中有业务依赖项，必须人工确认 ${TARGET} 下的等价配置"
  fi
  [ "${n}" -eq 0 ] && { info "没有可搬运的参数"; return 0; }

  # modify-db-parameter-group 单次上限 20 个
  local batch="" c=0 p
  for p in ${args}; do
    batch="${batch} ${p}"; c=$((c+1))
    if [ "${c}" -ge 20 ]; then
      mutate_quiet "写入 ${c} 个参数到 ${newpg}" \
        aws rds modify-db-parameter-group --db-parameter-group-name "${newpg}" \
          --parameters ${batch} || die "写参数到 ${newpg} 失败"
      batch=""; c=0
    fi
  done
  if [ "${c}" -gt 0 ]; then
    mutate_quiet "写入 ${c} 个参数到 ${newpg}" \
      aws rds modify-db-parameter-group --db-parameter-group-name "${newpg}" \
        --parameters ${batch} || die "写参数到 ${newpg} 失败"
  fi
  if [ "${APPLY}" = "true" ]; then
    ok "已从 ${BLUE_PG} 搬运 ${n} 个自定义参数到 ${newpg}"
  else
    info "将从 ${BLUE_PG} 搬运 ${n} 个自定义参数到 ${newpg}（dry-run，未写入）"
  fi
}

if [ -n "${EXIST_ID}" ]; then
  # ---------- 可重入：复用现成的 ----------
  step "复用已有蓝绿部署"
  ok "${EXIST_ID}（状态 $(bg_q "${EXIST_ID}" Status)），不新建"
  state_set "${INST}" BG_ID "${EXIST_ID}"

  # 复用时本次算出的 TPG 不会生效 —— 报告 green 实际挂的参数组
  GREEN_ARN=$(bg_q "${EXIST_ID}" 'Target')
  GREEN_ID=$(printf '%s' "${GREEN_ARN}" | awk -F: '{print $NF}')
  if [ -n "${GREEN_ID}" ] && [ "${GREEN_ID}" != "None" ]; then
    GREEN_PG=$(rds_q "${GREEN_ID}" 'DBParameterGroups[0].DBParameterGroupName')
    if [ -n "${GREEN_PG}" ] && [ "${GREEN_PG}" != "None" ]; then
      if [ "${GREEN_PG}" = "${TPG}" ]; then
        ok "green ${GREEN_ID} 参数组：${GREEN_PG}（与本次决策一致）"
      else
        warn "green ${GREEN_ID} 参数组为 ${GREEN_PG}，与本次决策的 ${TPG} 不一致"
        warn "  → 已有蓝绿环境是用别的参数创建的。要换参数组，需 modify-db-instance 改 green 并重启，或删掉蓝绿环境重建"
      fi
    fi
  fi
  state_set "${INST}" TARGET_PG "${TPG}"
else
  step "创建蓝绿环境"
  [ "${PG_MODE}" = "derive" ] && create_target_pg_from_blue "${TPG}" "${TARGET_FAM}"

  # 命名约束：[a-zA-Z](?:-?[a-zA-Z0-9]+)* —— 必须字母开头、不得有连续横线、不得以横线结尾
  SAFE=$(printf '%s' "${INST}" | tr -c 'a-zA-Z0-9' '-' | tr -s '-' | sed 's/^-*//; s/-*$//' | cut -c1-40 | sed 's/-*$//')
  NAME="bg-${SAFE}-$(date -u +%m%d%H%M)"
  CMD=(aws rds create-blue-green-deployment
       --blue-green-deployment-name "${NAME}"
       --source "${ARN}"
       --target-engine-version "${TARGET}"
       --target-db-parameter-group-name "${TPG}")
  [ -n "${TCLASS}" ] && CMD+=(--target-db-instance-class "${TCLASS}")
  [ -z "${TCLASS}" ] && info "未指定 --target-class：green 将继承 blue 的实例规格（${CLASS}）"

  if [ "${APPLY}" != "true" ]; then
    printf '\n  %sDRY-RUN%s 将执行：\n          %s\n' "${_c_yel}" "${_c_off}" "${CMD[*]}"
    log ""
    log "预检已通过。确认无误后加 --apply 真正创建。"
    exit 0
  fi

  if ! OUT=$("${CMD[@]}" --query 'BlueGreenDeployment.[BlueGreenDeploymentIdentifier,Status]' --output text 2>&1); then
    log "${OUT}"
    die "创建失败。常见原因：名称不合规 / green 参数组非法 / 实例刚发生变更。错误信息见上。"
  fi
  BG_ID=$(echo "${OUT}" | awk '{print $1}')
  ok "已创建：${BG_ID}（状态 $(echo "${OUT}" | awk '{print $2}')）"
  state_set "${INST}" BG_ID "${BG_ID}"
  state_set "${INST}" TARGET_PG "${TPG}"
fi

log ""
info "状态已写入：$(state_file "${INST}")"
info "下一步：用 02-gate.sh 轮询闸门。准备完成前不要尝试切换。"
log ""
log "  watch -n 60 ./02-gate.sh ${INST}"
