#!/usr/bin/env bash
# 蓝绿升级脚本组的公共库。所有脚本 source 它。
#
# 设计原则：
#   1. 判断与执行分离 —— gate 脚本只输出 PASS/FAIL，不做任何变更
#   2. 全部可重入 —— 重复执行不产生副作用（02 不会创建出第二套蓝绿环境）
#   3. 状态通过文件传递 —— 不依赖操作员复制粘贴 deployment id
#   4. 变更操作默认 dry-run，需显式 --apply

set -uo pipefail

: "${AWS_DEFAULT_REGION:=us-west-2}"
export AWS_DEFAULT_REGION

BG_STATE_DIR="${BG_STATE_DIR:-${HOME}/.rds-bluegreen}"
mkdir -p "${BG_STATE_DIR}"

# ---------- 输出 ----------
_c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_yel=$'\033[33m'; _c_cyn=$'\033[36m'; _c_off=$'\033[0m'
[ -t 1 ] || { _c_red=; _c_grn=; _c_yel=; _c_cyn=; _c_off=; }

FINDINGS_BLOCKER=0
FINDINGS_WARN=0

log()      { printf '%s\n' "$*"; }
step()     { printf '\n%s== %s ==%s\n' "${_c_cyn}" "$*" "${_c_off}"; }
ok()       { printf '  %sPASS%s  %s\n' "${_c_grn}" "${_c_off}" "$*"; }
blocker()  { printf '  %sBLOCK%s %s\n' "${_c_red}" "${_c_off}" "$*"; FINDINGS_BLOCKER=$((FINDINGS_BLOCKER+1)); }
warn()     { printf '  %sWARN%s  %s\n' "${_c_yel}" "${_c_off}" "$*"; FINDINGS_WARN=$((FINDINGS_WARN+1)); }
info()     { printf '  INFO  %s\n' "$*"; }
die()      { printf '\n%sERROR%s %s\n' "${_c_red}" "${_c_off}" "$*" >&2; exit 1; }

summary() {
  printf '\n----------------------------------------\n'
  if [ "${FINDINGS_BLOCKER}" -gt 0 ]; then
    printf '%s结论：NO-GO%s  （阻断项 %d，警告 %d）\n' "${_c_red}" "${_c_off}" "${FINDINGS_BLOCKER}" "${FINDINGS_WARN}"
    return 1
  fi
  if [ "${FINDINGS_WARN}" -gt 0 ]; then
    printf '%s结论：GO（有警告）%s  （警告 %d）\n' "${_c_yel}" "${_c_off}" "${FINDINGS_WARN}"
  else
    printf '%s结论：GO%s  全部检查通过\n' "${_c_grn}" "${_c_off}"
  fi
  return 0
}

# ---------- 状态文件 ----------
state_file() { echo "${BG_STATE_DIR}/$1.env"; }

state_set() {   # state_set <instance> <KEY> <VALUE>
  local f; f=$(state_file "$1"); shift
  local k="$1" v="$2"
  touch "${f}"
  grep -v "^${k}=" "${f}" > "${f}.tmp" 2>/dev/null || true
  printf '%s=%s\n' "${k}" "${v}" >> "${f}.tmp"
  mv "${f}.tmp" "${f}"
}

state_get() {   # state_get <instance> <KEY>  → 空串表示未设置
  local f; f=$(state_file "$1")
  [ -f "${f}" ] || return 0
  sed -n "s/^$2=//p" "${f}" | tail -1
}

# ---------- AWS 辅助 ----------
rds_q() {  # rds_q <instance-id> <jmespath>  —— 查单实例字段
  aws rds describe-db-instances --db-instance-identifier "$1" \
    --query "DBInstances[0].$2" --output text 2>/dev/null
}

bg_q() {   # bg_q <bg-id> <jmespath>
  aws rds describe-blue-green-deployments --blue-green-deployment-identifier "$1" \
    --query "BlueGreenDeployments[0].$2" --output text 2>/dev/null
}

require_cmd() {
  for c in "$@"; do command -v "${c}" >/dev/null 2>&1 || die "缺少命令：${c}"; done
}

# 确认当前凭证能用，并提示身份（避免在错误账号上操作）
show_identity() {
  local who
  who=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null) \
    || die "AWS 凭证不可用"
  info "身份：${who}"
  info "区域：${AWS_DEFAULT_REGION}"
}

# 变更操作的统一入口：默认只打印不执行
APPLY="${APPLY:-false}"
mutate() {  # mutate <描述> <命令...>
  local desc="$1"; shift
  if [ "${APPLY}" = "true" ]; then
    info "执行：${desc}"
    "$@"
  else
    printf '  %sDRY-RUN%s 将执行：%s\n' "${_c_yel}" "${_c_off}" "${desc}"
    printf '          %s\n' "$*"
    return 0
  fi
}

parse_apply_flag() {  # 从参数里摘出 --apply
  for a in "$@"; do [ "${a}" = "--apply" ] && APPLY=true; done
  export APPLY
}
