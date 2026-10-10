# RDS MySQL 蓝绿升级脚本组

操作员速查。完整方案与实测依据见 `../../客户建议-RDS蓝绿自动化升级方案.md`。

## 设计约定

| 约定 | 说明 |
|---|---|
| **默认 dry-run** | 变更类脚本（`02` / `04` / `06`）必须显式加 `--apply` |
| **闸门只读** | `03-gate.sh` 绝不执行变更，只输出 PASS/FAIL，退出码 0=可切换 1=不可切换 |
| **全部可重入** | 重复执行无副作用；`02` 会复用已有蓝绿环境 |
| **状态文件传递** | `~/.rds-bluegreen/<instance>.env`（可用 `BG_STATE_DIR` 覆盖） |
| **不可逆操作需确认** | `06` 要求输入实例名；非交互环境直接拒绝 |

## 完整流程

```bash
export AWS_DEFAULT_REGION=us-west-2
INST=my-mysql-prod   # 填写原 DB identifier
TARGET=8.4.11

./01-preflight-rds.sh $INST $TARGET           # 注意输出的「最晚启动时刻」

./02-create-bluegreen.sh $INST $TARGET            # dry-run
./02-create-bluegreen.sh $INST $TARGET --apply

watch -n 60 "./03-gate.sh $INST"      # 等到 GO，可能数小时
./03-gate.sh $INST                     # 检查切换准备

./04-switchover.sh $INST                          # dry-run
./04-switchover.sh $INST --apply --timeout 300    # 挑业务低谷

./05-verify.sh $INST --window 60
# 观察 ≥1 小时后
./06-cleanup-old.sh $INST --apply
```

## 脚本说明

| 脚本 | 读/写 | 作用 |
|---|---|---|
| `_common.sh` | — | 公共库：日志、状态文件、dry-run 包装 |
| `00-preflight-app.sh` | 只读 | 应用侧 10 项检查：DNS TTL、探针分组、JDBC/Hikari、Bulkhead 标定、retry 忽略项、AOP 自调用、`@Retry`/`@Transactional` 顺序、catch-all、503 契约 |
| `01-preflight-rds.sh` | 只读 | RDS 侧 9 项：状态、pending 修改、`backup-retention-period`、合法升级目标、`binlog_format`（仅 <8.4）、存储余量、准备时间预估、已有蓝绿、参数组 |
| `02-create-bluegreen.sh` | **写** | 创建蓝绿。`--target-class` / `--target-pg` 可选 |
| `03-gate.sh` | 只读 | 六项闸门 + 可选心跳延迟 + 可选应用自检 |
| `04-switchover.sh` | **写** | 先调 `03`，不过则拒绝；超时被取消会当失败处理 |
| `05-verify.sh` | 只读 | 版本核对、错误率增量、回滚资产；给出回滚步骤 |
| `06-cleanup-old.sh` | **写** | 删除 `-old1` 与蓝绿记录 |

## 环境变量

| 变量 | 用途 |
|---|---|
| `AWS_DEFAULT_REGION` | 默认 `us-west-2` |
| `BG_STATE_DIR` | 状态文件目录，默认 `~/.rds-bluegreen` |
| `APP_STATS_URL` | 应用容错自检（闸门⑦）与切换后错误率判读 |
| `BG_FORCE_NONINTERACTIVE` | `06` 在非交互环境跳过确认（慎用） |

## runner 放哪里

闸门的心跳检查与应用自检要求 runner **同时**具备 AWS API 访问、数据库网络可达、应用端点可达。
**应放在 VPC 内并绑定 instance profile。**

权限分离建议：`00`/`01`/`03`/`05` 用 ReadOnly 凭证；`02`/`04`/`06` 用独立的最小权限角色。

## 依赖

`aws` CLI、`python3`、`mysql` 客户端（仅 `--lag-check` 需要）。

## 已知限制

- `04` 之后**不能**用 `switchover` 回切；回滚方式见 `05-verify.sh` 的输出或主文档第九节。
- `-old1` 实例持续计费，但它是唯一回滚资产 —— 所以 `06` 刻意不进流水线。
- RDS 的 automated 快照无法手工删除，随 `backup-retention-period` 自动过期。