# RDS MySQL 蓝绿升级脚本组

操作员速查。完整方案与实测依据见 `../../客户建议-RDS蓝绿自动化升级方案.md`。

## 设计约定

| 约定 | 说明 |
|---|---|
| **默认 dry-run** | 变更类脚本（`01` / `03` / `04`）必须显式加 `--apply` |
| **预检与创建同进同出** | `01` 预检不过就拒绝创建，即使加了 `--apply` |
| **闸门只读** | `02-gate.sh` 绝不执行变更，只输出 PASS/FAIL，退出码 0=可切换 1=不可切换 |
| **全部可重入** | 重复执行无副作用；`01` 会复用已有蓝绿环境 |
| **状态文件传递** | `~/.rds-bluegreen/<instance>.env`（可用 `BG_STATE_DIR` 覆盖） |
| **不可逆操作需确认** | `04` 要求输入实例名；非交互环境直接拒绝 |

## 完整流程

```bash
export AWS_DEFAULT_REGION=us-west-2
INST=my-mysql-prod
TARGET=8.4.11

# ① 预检 + 创建蓝绿（先 dry-run 看预检结论和将执行的命令）
./01-prepare.sh $INST $TARGET
./01-prepare.sh $INST $TARGET --apply

# ② 轮询闸门，等到 GO（可能数小时，对业务零影响）
watch -n 60 "./02-gate.sh $INST"

# ③ 挑业务低谷切换（闸门不过会直接拒绝）
./03-switchover.sh $INST
./03-switchover.sh $INST --apply --timeout 300

# ④ 观察 ≥1 小时后清理旧实例
#    切换后的自查清单与回滚步骤由 03 在末尾直接打印
./04-cleanup-old.sh $INST --apply
```

## 多实例批量

`01-prepare.sh` 不交互、不读 stdin、状态各自写 `<instance>.env`，所以多个实例直接并发跑即可，
不需要额外的批处理脚本：

```bash
export AWS_DEFAULT_REGION=us-west-2
mkdir -p logs

for i in db-a db-b db-c; do
  nohup ./01-prepare.sh "$i" 8.4.11 --apply > "logs/01-prepare-$i.log" 2>&1 &
  disown
done
```

查看进度：

```bash
tail -f logs/01-prepare-db-a.log             # 跟单个
grep -H '结论：' logs/01-prepare-*.log        # 全部结论
grep -l '结论：NO-GO' logs/01-prepare-*.log   # 哪些预检没过
```

注意事项：

| 项 | 说明 |
|---|---|
| **`2>&1` 必须有** | `die` 走 stderr，漏了它预检失败的原因就丢了 |
| **每个实例一份日志** | 共用一个文件时并发输出会交错，事后读不出来 |
| **先 dry-run 一遍** | 去掉 `--apply` 跑完确认 9 项预检与参数组决策，再加 `--apply` |
| **并发数 4–6** | `CreateBlueGreenDeployment` 和 `describe-*` 有 API 限流，同账号同时建太多套还会互抢快照与存储配额。跑完一批再下一批 |
| **`disown`** | `nohup` 只挡 SIGHUP；zsh 关窗口时可能直接杀进程组 |
| **关掉睡眠** | 01 要跑 1–4 小时，笔记本休眠期间 AWS API 调用会断。`caffeinate -d` 开着 |

日志里不会有颜色乱码 —— `_common.sh` 的 `[ -t 1 ] ||` 在非终端时自动关掉了 ANSI 码。

### 批量跑 `02-gate.sh`

02 只读、可反复轮询，同样直接并发跑。每个实例一份日志 `logs/02-gate-<实例>.log`，
和 01 的 `logs/01-prepare-<实例>.log` 前缀不同，不会互相覆盖；重跑覆盖上一轮同名日志即可
—— 02 看的就是「现在能不能切」，只留最新一轮。

```bash
export AWS_DEFAULT_REGION=us-west-2
mkdir -p logs

for i in db-a db-b db-c; do
  nohup ./02-gate.sh "$i" > "logs/02-gate-$i.log" 2>&1 &
  disown
done
```

判定只看日志里有没有 `下一步：./03-switchover.sh` —— 这行只在闸门全过时才打印。
不要 grep `结论：`：02 在 `die` 路径（例如状态文件里没有 BG_ID）会直接退出，
日志里只有 `ERROR` 一行，根本到不了打印结论的地方。

```bash
grep -l '下一步：./03-switchover.sh' logs/02-gate-*.log   # 哪些过了
grep -L '下一步：./03-switchover.sh' logs/02-gate-*.log   # 哪些没过
grep -nE 'BLOCK|ERROR' logs/02-gate-db-a.log              # 某个实例卡在哪一项
```

`disown` 之后拿不到作业状态，所以 grep 前确认日志都写完了（每个实例几十秒）：
日志末尾有 `结论：` 或 `ERROR` 就是跑完了。

### 批量跑 `03-switchover.sh`（**仅限测试环境**）

测试集群多的时候逐个切太慢，而测试环境没有业务流量，并发切换的代价不存在。
03 不交互、不读 stdin，所以和 01 / 02 一样直接并发跑：

```bash
export AWS_DEFAULT_REGION=us-west-2
mkdir -p logs

for i in db-a db-b db-c; do
  nohup ./03-switchover.sh "$i" --apply --timeout 300 > "logs/03-switchover-$i.log" 2>&1 &
  disown
done
```

每个实例约 4–5 分钟（切换 ~40–70s + `--reboot-delay` 60s + 旧 blue 回 available ~60s），
并发跑总耗时就是最慢的那一个。判定看退出路径：

```bash
grep -l 'PASS.*切换完成' logs/03-switchover-*.log   # 哪些切成功了
grep -L 'PASS.*切换完成' logs/03-switchover-*.log   # 哪些没切成
grep -nE 'ERROR|BLOCK' logs/03-switchover-*.log     # 失败的卡在哪一步
```

03 会先自己调 `02-gate.sh`，闸门不过就 `die`，不会造成任何变更 ——
所以这个循环甩出去是安全的，没准备好的实例只会在日志里留一条 `ERROR`。

**生产环境不要这么跑。** 并发切换意味着多个业务同时进入 DNS 窗口，出问题无法分辨
影响面；生产按业务低谷逐个切，每切完一个看完 03 末尾的自查清单和监控再动下一个。

### 哪些阶段不要批量

| 阶段 | 批量 | 理由 |
|---|---|---|
| `01-prepare` | **可以并发** | 对业务零影响，单实例 1–4 小时，串行不可接受 |
| `02-gate` | **可以并发** | 只读。和 01 同样的 `nohup ... &` 并发跑，定时轮询看谁到了 GO（见上节）|
| `03-switchover` | **测试可并发／生产不要** | 测试环境没有业务流量，并发切换无代价（见上节）。生产是唯一有业务影响的时刻：并发意味着多个业务同时进入 DNS 窗口，出问题无法分辨影响面，必须按清单逐个切、每个单独确认 |
| `04-cleanup-old` | **不要** | 删掉的是唯一回滚资产，刻意不进流水线（见下文「已知限制」） |

## 脚本说明

| 脚本 | 读/写 | 作用 |
|---|---|---|
| `_common.sh` | — | 公共库：日志、状态文件、dry-run 包装 |
| `01-prepare.sh` | **写** | 9 项预检 + 创建蓝绿。预检 NO-GO 则拒绝创建。`--target-class` / `--target-pg` / `--auto-target-pg` 可选 |
| `02-gate.sh` | 只读 | 七项切换闸门 |
| `03-switchover.sh` | **写** | 先调 `02`，不过则拒绝；超时被取消会当失败处理。切换成功后等 60s（`--reboot-delay`）再重启旧 blue（`-old1`）一次，断开 DNS 缓存未过期期间仍连在旧实例上的残留连接，再打印自查清单与回滚步骤（`--skip-restart-old` 可关掉）|
| `04-cleanup-old.sh` | **写** | 删除 `-old1` 与蓝绿记录 |

### `01-prepare.sh` 的 9 项预检

状态、pending 修改、`backup-retention-period`、合法升级目标、`binlog_format`（仅 <8.4）、
存储余量、准备时间预估与「最晚启动时刻」、已有蓝绿部署、参数组（族匹配 + in-sync）。

### `02-gate.sh` 的七项闸门

部署状态、三个准备任务、green 实例状态、green 引擎版本与规格、`SwitchoverDetails`、
同步延迟（CloudWatch `ReplicaLag`）、应用容错自检（设了 `APP_STATS_URL` 才跑）。

为什么闸门不能只看同步延迟 —— 实测踩过的坑：部署状态已是 `AVAILABLE`，
但 green 实例自己还在 `modifying`，`switchover` 直接报
`InvalidBlueGreenDeploymentStateFault`。所以必须逐项查到实例级。

## green 的参数组

`01` 永远把 `--target-db-parameter-group-name` 显式写进 `create-blue-green-deployment`，
不依赖 AWS 的隐式继承。决策分四种情况：

| blue 参数组 vs 目标版本 | 行为 |
|---|---|
| **同族**（小版本升级，如 `mysql8.4` → 8.4.11） | 显式沿用 blue 的参数组。效果与隐式继承一致，但 dry-run 看得见、事后可审计。blue 用的是 `default.*` 时额外告警 |
| **跨族**（大版本升级，如 `mysql8.0` → 8.4.x） | **阻断**，退出码 1 |
| 跨族 + `--target-pg <PG>` | 校验该 PG 的族与目标版本一致，不一致则拒绝 |
| 跨族 + `--auto-target-pg` | 自动建 `<blue-pg>-<目标族>`，搬运 blue 上所有 `Source=user` 的参数；目标族里不存在/不可改的参数逐个列出告警并跳过。可重入。**派生结果必须人工复核后再切换** |

为什么跨族要阻断：blue 的参数组对 green 非法，若不指定，RDS 会给 green 套上
`default.<目标族>` —— 字符集、时区、`max_connections`、慢查询阈值等自定义参数**静默丢失**。
而发现问题时切换已完成，blue 已改名为 `<instance>-old1`。

`--auto-target-pg` 只搬运参数**名值对**，不理解语义。大版本间同名参数的默认值、
取值范围、生效方式都可能变（不只是增删），所以它输出的参数组是复核起点，不是结论。

## 环境变量

| 变量 | 用途 |
|---|---|
| `AWS_DEFAULT_REGION` | 默认 `us-west-2` |
| `BG_STATE_DIR` | 状态文件目录，默认 `~/.rds-bluegreen` |
| `APP_STATS_URL` | 应用容错自检（闸门⑦） |
| `BG_FORCE_NONINTERACTIVE` | `04` 在非交互环境跳过确认（慎用） |

## runner 放哪里

闸门⑦的应用自检要求 runner 能访问应用端点，其余只需 AWS API。
**建议放在 VPC 内并绑定 instance profile。**

权限分离建议：`02` 用 ReadOnly 凭证；`01`/`03`/`04` 用独立的最小权限角色。

## 依赖

`aws` CLI、`python3`。脚本本身不连数据库，不需要 DB 凭证。

## 已知限制

- `03` 之后**不能**用 `switchover` 回切；回滚方式由 `03` 末尾直接打印，也见主文档第九节。
- 切换后的验证**不自动判定**。早期有过一个 `04-verify.sh` 做阈值判定，已移除 ——
  它要求应用侧埋点（`/api/stats` 计数器）才能工作，而「错误率是否回落」「写入是否恢复」
  本来就该看现成的监控。硬编码阈值在 DNS 传播窗口内还会误报回滚。
  `03` 改为打印自查清单 + 回滚命令，判定交给人。
- `-old1` 实例持续计费，但它是唯一回滚资产 —— 所以 `04` 刻意不进流水线。
- RDS 的 automated 快照无法手工删除，随 `backup-retention-period` 自动过期。
- 同步延迟闸门用 CloudWatch `ReplicaLag`，粒度 60 秒。不丢写入由 AWS 的
  switchover 本身保证（追不平会超时取消），这道闸门只用于提前发现「延迟大到很可能超时」。
