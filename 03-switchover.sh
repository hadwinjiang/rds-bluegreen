#!/usr/bin/env bash
# 蓝绿升级 —— 执行切换
#
# 用法: ./03-switchover.sh <instance-id> [--apply] [--timeout 300] [--force] [--skip-restart-old] [--reboot-gap 60]
#
# 这个脚本刻意做得「哑」：先调 02-gate.sh，闸门不过就退出；过了就一条命令切换。
# 不做任何判断、不做任何重试、不在循环里等人决策。
# 切换窗口只有 10 秒量级（实测三组 9.8~10.5 秒），这里的复杂度就是风险。
#
# --force 跳过闸门（仅用于演练/排障，生产不要用）
#
# --skip-restart-old 切换后不重启旧 blue（默认会重启）
# 为什么默认要重启旧 blue：切换后旧实例被改名成 <inst>-old1，但仍然 available，
# 仍然接受连接。DNS 缓存未过期的客户端会继续连在旧实例上读写 —— 写到那里的数据
# 不会回到新实例，是静默的数据分叉。重启旧实例会强制断开这些残留连接，
# 迫使应用重新解析 DNS 并连到新实例。旧实例重启后仍然可用，回滚资产不受影响。
#
# 为什么重启两次（--reboot-gap 控制间隔，默认 60s）：
# 一次重启只断开当下的连接。重连逻辑健壮、且 DNS 缓存还没过期的客户端会立刻连回旧实例，
# 继续往那里写 —— 数据分叉的窗口没关掉。隔一分钟再重启一次，这些「反复连回来的」
# 客户端会被第二次掐断，而此时 DNS TTL（建议 ≤5s）早已过期，重新解析就会落到新实例。
#
# 为什么不用 stop：stop 能彻底断掉连接，但实测从下发到 stopped 需要 ~574s（9.5 分钟，
# 主要耗在最终快照），而且 rebooting 期间下发会被拒绝 —— 太慢，不适合放在切换窗口里。
# 旧实例的计费与回收交给 04-cleanup-old.sh。

cd "$(dirname "$0")"
. ./_common.sh
parse_apply_flag "$@"

INST="${1:-}"
[ -n "${INST}" ] || die "用法: $0 <instance-id> [--apply] [--timeout 300] [--force] [--skip-restart-old] [--reboot-gap 60]"

TIMEOUT=300; FORCE=false; RESTART_OLD=true; REBOOT_GAP=60
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)          TIMEOUT="${2:-300}"; shift 2 ;;
    --reboot-gap)       REBOOT_GAP="${2:-60}"; shift 2 ;;
    --force)            FORCE=true; shift ;;
    --skip-restart-old) RESTART_OLD=false; shift ;;
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
  if [ "${RESTART_OLD}" = "true" ]; then
    log "    aws rds reboot-db-instance --db-instance-identifier ${INST}-old1   # 第 1 次：断开残留连接"
    log "    sleep ${REBOOT_GAP}"
    log "    aws rds reboot-db-instance --db-instance-identifier ${INST}-old1   # 第 2 次：掐断又连回来的客户端"
  else
    log "    （--skip-restart-old：切换后不重启旧 blue）"
  fi
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

OLD="${INST}-old1"

# ---------- 重启旧 blue 两次，逼应用重连 ----------
# 放在自查清单之前：先切断残留连接，再让人去看监控，否则看到的指标里混着旧实例的流量。
#
# 两次重启、间隔 ${REBOOT_GAP}s：第一次断开切换瞬间还连在旧实例上的连接；
# 第二次掐断那些「断了又立刻连回来」的客户端 —— 此时 DNS TTL 已过期，重连会落到新实例。
#
# 实测（db.t3.large / Multi-AZ）：reboot 下发到回到 available ~153s，
# 重启本体只有 ~11s，其余是 PI、参数组等收尾动作。所以第二次重启通常要等第一次收尾完。
reboot_old() {  # reboot_old <第几次>
  local n="$1" out r0 now st
  st=$(rds_q "${OLD}" DBInstanceStatus)
  if [ -z "${st}" ] || [ "${st}" = "None" ]; then
    warn "找不到实例 ${OLD}，跳过第 ${n} 次重启。请人工确认旧 blue 的实际名字"
    return 1
  fi
  # rebooting 期间下发会被拒绝 —— 先等回 available 再下发，而不是硬撞一次
  if [ "${st}" != "available" ]; then
    info "${OLD} 当前 ${st}，等它回到 available 再下发第 ${n} 次重启"
    r0=$(date -u +%s)
    while [ "${st}" != "available" ]; do
      now=$(date -u +%s)
      if [ $((now-r0)) -gt 600 ]; then
        warn "${OLD} 600s 内未回到 available（当前 ${st}），放弃第 ${n} 次重启。可稍后手工执行："
        log "     aws rds reboot-db-instance --db-instance-identifier ${OLD}"
        return 1
      fi
      sleep 10
      st=$(rds_q "${OLD}" DBInstanceStatus)
      printf '  %s  %s=%s  (%ds)\n' "$(date -u '+%H:%M:%S')" "${OLD}" "${st}" "$((now-r0))"
    done
  fi
  out=$(aws rds reboot-db-instance --db-instance-identifier "${OLD}" \
          --query 'DBInstance.DBInstanceStatus' --output text 2>&1) || {
    log "${out}"
    warn "第 ${n} 次重启下发失败。残留连接可能还在旧实例上，请人工重启：aws rds reboot-db-instance --db-instance-identifier ${OLD}"
    return 1
  }
  ok "第 ${n} 次重启已下发，状态=${out}"
  state_set "${INST}" "OLD_REBOOT${n}_AT" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  return 0
}

wait_old_available() {
  local r0 now st
  r0=$(date -u +%s)
  # 只等回到 available，不做失败判定 —— 旧实例已不在服务路径上，
  # 它起不来只影响回滚能力，不影响当前业务，交给人判断。
  while :; do
    st=$(rds_q "${OLD}" DBInstanceStatus)
    now=$(date -u +%s)
    printf '  %s  %s=%s  (%ds)\n' "$(date -u '+%H:%M:%S')" "${OLD}" "${st}" "$((now-r0))"
    [ "${st}" = "available" ] && [ $((now-r0)) -gt 20 ] && { ok "${OLD} 已回到 available，回滚资产完好"; return 0; }
    if [ $((now-r0)) -gt 600 ]; then
      warn "${OLD} 600s 内未回到 available（当前 ${st}）。不影响当前业务，但回滚能力待确认"
      return 1
    fi
    sleep 10
  done
}

step "重启旧 blue（${OLD}）—— 两次，间隔 ${REBOOT_GAP}s"
if [ "${RESTART_OLD}" != "true" ]; then
  warn "--skip-restart-old：跳过。DNS 缓存未过期的客户端可能仍在旧实例上读写（数据分叉风险）"
else
  if reboot_old 1; then
    log ""
    info "等待 ${REBOOT_GAP}s 后再重启一次（给残留客户端一个重连的机会，然后掐断它）"
    sleep "${REBOOT_GAP}"
    log ""
    reboot_old 2 || true
  fi
  log ""
  info "等待 ${OLD} 回到 available"
  wait_old_available || true
fi

# ---------- 切换后自查清单 ----------
# 刻意只给「怎么查」和「什么情况该回滚」，不自动判定 ——
# 判定需要应用侧埋点与业务上下文，脚本拿不到，硬编码阈值只会误报。
step "切换后请人工确认"
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
