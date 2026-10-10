#!/usr/bin/env bash
# 蓝绿升级 —— RDS 侧预检（只读，不做任何变更）
#
# 用法: ./01-preflight-rds.sh <instance-id> <target-version>
# 例:   ./01-preflight-rds.sh bgdemo-mysql847 8.4.11
#
# 为什么不只检查「当前版本是否等于某个常量」：
#   真正会让蓝绿创建失败或中途失败的是下面这几项，版本只是其中最弱的一条。
#   实测教训：
#     - backup-retention-period=0 → 蓝绿直接不可用（我们第一批实例因此全部重建）
#     - 存储余量不足 → green 恢复/升级中途失败
#       （500GB 那组只剩 62.79 GiB / 634 GiB，RDS 已发低存储告警）

cd "$(dirname "$0")"
. ./_common.sh

INST="${1:-}"; TARGET="${2:-}"
[ -n "${INST}" ] && [ -n "${TARGET}" ] || die "用法: $0 <instance-id> <target-version>"
require_cmd aws python3

step "RDS 侧预检：${INST} → ${TARGET}"
show_identity

# ---------- 基本信息 ----------
read -r STATUS CUR ENGINE CLASS ALLOC MULTIAZ RETENTION PGNAME <<<"$(
  aws rds describe-db-instances --db-instance-identifier "${INST}" \
    --query 'DBInstances[0].[DBInstanceStatus,EngineVersion,Engine,DBInstanceClass,AllocatedStorage,MultiAZ,BackupRetentionPeriod,DBParameterGroups[0].DBParameterGroupName]' \
    --output text 2>/dev/null)" || die "实例不存在或无权访问：${INST}"
[ -n "${STATUS:-}" ] || die "实例不存在或无权访问：${INST}"

info "引擎=${ENGINE} ${CUR}  规格=${CLASS}  存储=${ALLOC}GB  Multi-AZ=${MULTIAZ}  参数组=${PGNAME}"

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
m=int(40 + g*0.38*60/100*100/100*1)  # 固定开销 ~40min + 38min/100GB
m=int(40 + g*0.38)
print(m, m//60, m%60)")"
  info "已用数据约 ${USED_GB}GB → 准备时间预估 ≈ ${HH}h${MM}m（实测拟合：固定 ~40min + 38min/100GB）"
  info "若维护窗口为 02:00，蓝绿创建最晚应在前一日 $(python3 -c "
m=${MINS}+30
h=(2*60-m)%(24*60); print(f'{h//60:02d}:{h%60:02d}')") 启动（含 30 分钟缓冲）"
else
  warn "无法估算数据量，准备时间预估跳过"
fi

step "⑧ 已存在的蓝绿部署"
EXIST=$(aws rds describe-blue-green-deployments \
  --query "BlueGreenDeployments[?Source=='$(rds_q "${INST}" DBInstanceArn)'].[BlueGreenDeploymentIdentifier,Status]" \
  --output text 2>/dev/null)
if [ -z "${EXIST}" ]; then ok "无已存在的蓝绿部署"
else warn "已存在蓝绿部署：${EXIST}（02 脚本会复用而不是新建）"; fi

step "⑨ 参数组提示"
case "${PGNAME}" in
  default.*) info "使用默认参数组。若希望 green 用新参数组，须在创建蓝绿时指定 --target-db-parameter-group-name，切换后再改需额外重启" ;;
  *)         warn "使用自定义参数组 ${PGNAME} —— 请确认它与 ${TARGET} 兼容，否则 green 可能起不来" ;;
esac

summary
RC=$?
[ ${RC} -eq 0 ] && state_set "${INST}" TARGET_VERSION "${TARGET}"
exit ${RC}
