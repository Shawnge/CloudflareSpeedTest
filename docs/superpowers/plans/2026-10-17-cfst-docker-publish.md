# CloudflareSpeedTest 容器化定时优选 + 结果发布 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让这份 fork 用 `docker compose up -d` 常驻运行，每天自动测速一次，把结果转成 `ip#优选区域-延时m` 文本并推送到 `Shawnge/CloudflareSpeedTest` 的 `master`，供 edgetunnel 读取。

**Architecture:** 不动 Go 源码。新增一个纯 shell 的 `publish.sh`，把「CSV→txt 转换」和「GitHub Contents API 发布」做成两个可独立执行、可离线测试的子命令；改造 `entrypoint.sh` 为环境变量驱动，负责每轮清理、调用 cfst、串联 `publish.sh`，并由容器内 busybox `crond` 常驻定时。

**Tech Stack:** POSIX sh / busybox（alpine:3.19）、awk + sort、curl + jq、Docker Compose、GitHub Contents REST API。

**Spec:** `docs/superpowers/specs/2026-10-17-cfst-docker-publish-design.md`

## Global Constraints

- 只用 POSIX `sh`（`/bin/sh`），**不得依赖 bash**；目标环境是 alpine:3.19 + busybox
- **不修改任何 Go 源码**（保持可随时 merge 上游 XIU2）
- 输出行格式精确为 `{ip}#优选{地区}-{平均延迟}m`，例：`203.0.113.7#优选HKG-45.12m`
- 平均延迟取 CSV 原文字符串（两位小数）；`m` 是字面量；地区必须是 `REGIONS` 成员
- 数据目录固定 `/data`（`DATA_DIR` 可覆盖）；CSV 固定 `/data/result.csv`，txt 固定 `/data/result.txt`
- 一切外部配置走环境变量，名称与默认值见 spec §5.7
- 日志中文，错误写 stderr；`publish.sh` 的日志统一加 `[publish]` 前缀
- **`sort -t` 必须传真实 TAB 字符**：写 `T=$(printf '\t')` 后用 `-t"$T"`。busybox `sort` 不认字面量 `-t"\t"`（实测报 `bad -t parameter`）
- `sort` 用 `-k2,2g`（general numeric），数值比较，勿用字符串排序
- 转换只做「逗号分隔 + 按列取值」，不做完整 CSV 解析。依据：IP、地区码、数字都不含逗号/引号，Go `encoding/csv` 不会给它们加引号（spec §9 已知取舍）
- **不执行 `git push`**。每个任务末尾的 `git commit` 只是本地检查点，便于按任务回退；提交范围不得包含 `.env` 或任何 token
- 每轮开跑前必须删除旧的 `result.csv` / `result.txt`（spec §5.1，反目标防护）
- 本计划在 spec §5.7 之外**新增 4 个仅用于可测试性的变量**：`DATA_DIR`、`CFST_BIN`（默认值下与 spec 行为完全一致）、`GITHUB_API_BASE`、`PUBLISH_DRY_RUN`（默认 `0`，默认值下与 spec 行为完全一致）。它们不进 README 的常规配置表
- 前置改动**已完成**，本计划只需验证：`.env`（含占位 token，已被忽略）、`.gitignore` 加 `.env`+`output/`、`.dockerignore` 加 `.env`+`output`

## Review Focus

最可能悄悄咬到使用者、且 spec 没逐条点名的几类输入，各自的测试放在拥有该代码的任务里：

1. **CSV 带 CRLF**（在 Windows 上跑 cfst 生成的 csv，或文件被 Windows 编辑器碰过）→ 地区码变成 `HKG\r`，匹配不上任何区域，**静默输出空文件**。预期行为：正常出结果。→ Task 1 `test_crlf_input`
2. **结果为空**（网络异常、无匹配区域、误开 `-dd`）→ 预期：绝不推送、绝不清空远端。→ Task 2 `test_push_skips_when_empty`
3. **延迟跨数量级**（`9.90` / `10.10` / `100.50`）→ 预期：按数值升序，字符串排序会错。→ Task 1 `test_numeric_delay_sort`
4. **某区域不足 `TOP_N`，或某区域一条都没有** → 预期：不报错，其余区域照常输出。→ Task 1 `test_top_n_truncation_and_order`
5. **出现非 IATA 的地区码**（`US`、小写 `hkg`、空值）→ 预期：安全丢弃，脚本不崩。→ Task 1 `test_non_iata_colo_dropped`
6. **上游失败运行留下上一轮的旧 `result.csv`** → 预期：第 0 步清理掉，绝不用旧数据覆盖远端。→ Task 3 `test_stale_csv_cleaned`

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `publish.sh`（新建） | 唯一的新逻辑文件。子命令 `convert`（纯转换，不联网）/ `push`（只发布）/ `all`（先转后发） |
| `tests/run_tests.sh`（新建） | 全部 shell 测试。POSIX sh，macOS 与 alpine 均可跑 |
| `entrypoint.sh`（改） | 环境变量驱动、每轮清理、`run_once`、cron 常驻 |
| `Dockerfile`（改） | 装 `curl jq`，拷入 `publish.sh` |
| `docker-compose.yml`（改） | 卷 `/data` 改指 `./output`、环境变量、`restart: unless-stopped` |
| `.gitignore` / `.dockerignore`（改） | 排除 `.env`、`output/`（**已完成**） |
| `result/.gitkeep`（新建） | 占位远端发布目录 |
| `README.md`（改） | 新增「Docker Compose 部署」一节 |
| git remote（改） | 指向 `Shawnge/CloudflareSpeedTest` |

拆分理由：转换与发布是两件可独立失败的事（转换纯计算、发布要联网），分开才能离线测试转换；`entrypoint.sh` 只做编排，不含业务规则。

---

### Task 1: `publish.sh convert` — CSV 转 edgetunnel 文本

**Files:**
- Create: `publish.sh`
- Create: `tests/run_tests.sh`

**Interfaces:**
- Consumes: 无
- Produces:
  - CLI：`sh publish.sh convert <csv 路径> <输出 txt 路径>`
    - 始终写出 `<输出 txt 路径>`（结果为空时写 0 字节文件）
    - 即使结果为空也返回退出码 0
  - 读环境变量：`REGIONS`（默认 `HKG,NRT,SIN,SJC,LAX`）、`TOP_N`（默认 `8`）
  - 测试框架：`sh tests/run_tests.sh`，逐行打印 `PASS <name>` / `FAIL <name> — <原因>`，末尾打印 `<n> passed, <m> failed`，全部通过才返回 0

- [ ] **Step 1: 写测试框架与失败的测试**

建立 `tests/run_tests.sh`，骨架：

```sh
#!/bin/sh
# 在 macOS 与 alpine:3.19 上均可运行（POSIX sh）
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "$2"; }
assert_eq() { # name actual expected
  if [ "$2" = "$3" ]; then ok "$1"
  else bad "$1" "expected [$(printf '%s' "$3")] got [$(printf '%s' "$2")]"; fi; }
convert() { # <csv> <out>
  sh "$REPO/publish.sh" convert "$1" "$2" 2>"$TMP/err"
}
```

`set -u` 下所有用例的临时文件一律建在 `$TMP` 下，每个用例用独立子目录，避免串味。

再写 7 个用例。每个用例的 fixture 与期望输出如下（表头统一为
`IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码`）：

- `test_basic_filter_and_format` — `REGIONS=HKG,NRT,SIN,SJC,LAX`、`TOP_N=8`。CSV 数据行：`1.1.1.1,...,45.12,...,HKG`、`2.2.2.2,...,52.30,...,NRT`、`3.3.3.3,...,33.10,...,AMS`、`4.4.4.4,...,11.00,...,N/A`、`5.5.5.5,...,60.00,...,SIN`。期望输出恰好三行，且顺序为：

```
1.1.1.1#优选HKG-45.12m
2.2.2.2#优选NRT-52.30m
5.5.5.5#优选SIN-60.00m
```

- `test_top_n_truncation_and_order` — `REGIONS=HKG`、`TOP_N=2`。HKG 延迟依次 `50.00 20.00 30.00 40.00`。期望两行：`20.00` 的那条在前、`30.00` 的在后。
- `test_region_output_order` — `REGIONS=SIN,HKG`。CSV 里 HKG 那行写在 SIN 那行**之前**。期望输出 SIN 行在前、HKG 行在后（跟随 `REGIONS` 声明顺序，不是 CSV 顺序，也不是字典序）。
- `test_numeric_delay_sort` — `REGIONS=HKG`、`TOP_N=8`。延迟依次 `100.50 9.90 10.10`。期望输出顺序为 `9.90`、`10.10`、`100.50`。
- `test_empty_result_writes_empty_file` — 全部数据行地区码为 `N/A`。期望：输出文件存在，且大小为 0。
- `test_crlf_input` — 用 `printf` 写一个行尾为 `\r\n` 的 CSV，单行 HKG／延迟 `45.12`。期望输出仍是 `1.1.1.1#优选HKG-45.12m`（证明 `\r` 被剥掉）。
- `test_non_iata_colo_dropped` — 数据行地区码依次为 `US`、`hkg`（小写）、`N/A`、空字符串、`HKG`。期望：只输出那一条 HKG 行，脚本退出码 0 不崩。

断言方式：把输出文件内容整段取出来（`cat`）与期望字符串用 `assert_eq` 比较；空结果用例用 `wc -c < 文件` 比较。

- [ ] **Step 2: 跑测试，确认失败**

Run: `sh tests/run_tests.sh`
Expected: 7 个用例全 `FAIL`（`publish.sh` 还不存在），退出码非 0。

- [ ] **Step 3: 实现 `publish.sh` 的 `convert`、默认值与分发骨架**

`publish.sh` 结构：

```sh
#!/bin/sh
set -eu
# 默认值
: "${REGIONS:=HKG,NRT,SIN,SJC,LAX}"
: "${TOP_N:=8}"

convert() { ... }   # <csv> <out>
push()    { ... }   # Task 2
case "${1:-}" in
  convert) convert "$2" "$3" ;;
  push)    push "$2" ;;
  all)     convert "$2" "$3"; push "$3" ;;
  *) echo "用法: publish.sh {convert|push|all} ..." >&2; exit 2 ;;
esac
```

`convert` 的算法见 spec §5.2 的参考实现，但**必须做两处偏离**：
1. 第一段 awk 在取字段前先剥掉行尾 `\r`（否则 `test_crlf_input` 会失败）
2. `sort -t` 用 `T=$(printf '\t')` 传真实 TAB（否则 busybox 报错）

`convert` 把最终文本写进 `<out>`；写完后若文件为空，向 stderr 打一条 `[publish] WARN 转换结果为空`（不改变退出码 0）。

- [ ] **Step 4: 跑测试，确认通过**

Run: `sh tests/run_tests.sh`
Expected: 7 个用例全 `PASS`，末行 `7 passed, 0 failed`，退出码 0。

- [ ] **Step 5: 在容器里再跑一遍（目标环境是 busybox）**

Run:
```sh
docker run --rm -v "$PWD:/w" -w /w alpine:3.19 sh tests/run_tests.sh
```
Expected: 同样 7 个 `PASS`。若有差异，按 alpine 的行为修，不按 macOS 的行为修。

- [ ] **Step 6: 本地提交**

```bash
git add publish.sh tests/run_tests.sh
git commit -m "feat(publish): 新增 CSV 到 edgetunnel 文本的转换"
```

---

### Task 2: `publish.sh push` — GitHub Contents API 发布 + 空结果守卫

**Files:**
- Modify: `publish.sh`
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Consumes: Task 1 的 `push()` 占位、`tests/run_tests.sh` 的断言函数
- Produces:
  - CLI：`sh publish.sh push <txt 路径>`、`sh publish.sh all <csv 路径> <out txt 路径>`
  - `push` 语义：txt 不存在或为 0 字节 → 打 `[publish] WARN 结果为空，跳过发布` 到 stderr，**退出码 0**；其余情况发布成功退出 0，失败退出 1
  - 读环境变量：`GITHUB_TOKEN`、`GITHUB_REPO`（默认 `Shawnge/CloudflareSpeedTest`）、`GITHUB_BRANCH`（默认 `master`）、`RESULT_PATH`（默认 `result/result.txt`）、`GITHUB_API_BASE`（默认 `https://api.github.com`）、`PUBLISH_DRY_RUN`（默认 `0`）
  - `GITHUB_API_BASE` 与 `PUBLISH_DRY_RUN` 存在的理由：让发布路径可离线测试，不必碰真实仓库

- [ ] **Step 1: 写三个失败的测试**

在 `tests/run_tests.sh` 追加：

- `test_push_skips_when_empty` — 造一个 0 字节 txt；`GITHUB_TOKEN=dummy`、`PUBLISH_DRY_RUN=1`、`GITHUB_API_BASE=http://127.0.0.1:1`。期望：退出码 0，且 stderr 含 `结果为空`。
- `test_push_reports_error_on_unreachable_api` — 造一个非空 txt；`GITHUB_TOKEN=dummy`、`PUBLISH_DRY_RUN=0`、`GITHUB_API_BASE=http://127.0.0.1:1`。期望：退出码**非 0**，stderr 含 `发布失败`。这条同时证明了失败时是「记日志 + 返回失败」而不是崩溃或静默。
- `test_dry_run_makes_no_request` — 非空 txt；`PUBLISH_DRY_RUN=1`、`GITHUB_API_BASE=http://127.0.0.1:1`（一个拒绝连接的地址）。期望：退出码 **0**（地址不可达却成功，说明根本没发请求），且 stdout 含 `"branch":"master"` 与 `"content":"`。

- [ ] **Step 2: 跑测试，确认失败**

Run: `sh tests/run_tests.sh`
Expected: 新增的 3 个 `FAIL`；Task 1 的 7 个仍 `PASS`。

- [ ] **Step 3: 实现 `push()`**

按 spec §5.4 的参考实现落地，要点：
1. **先守卫**：`[ -s "$txt" ]` 为假 → `WARN 结果为空，跳过发布` + `return 0`
2. `GITHUB_TOKEN` 为空 → `WARN 未配置 GITHUB_TOKEN，跳过发布` + `return 0`（与 spec §8 一致：单次运行时「仅测速不发布」）
3. `PUBLISH_DRY_RUN=1` → 不做任何网络请求；把 `GITHUB_API_BASE`、目标 URL、将要提交的 JSON（含 base64 content、branch、sha 或 `create` 标记）打进 stdout，`return 0`
4. 取 sha：`GET "$GITHUB_API_BASE/repos/$GITHUB_REPO/contents/$RESULT_PATH?ref=$GITHUB_BRANCH"`，用 `jq -r '.sha // empty'`，失败或 404 都当「创建」。curl 一律带 `--connect-timeout 10 --max-time 60`
5. 组 JSON：`jq -n --arg ...`，有 sha 才加 `sha` 字段；commit message 形如 `chore: update result.txt (2026-10-17 04:00:12)`
6. `PUT` 成功后打 `[publish] 已发布到 $GITHUB_REPO@$GITHUB_BRANCH:$RESULT_PATH`，`return 0`
7. 任何非 2xx → stderr 打 `[publish] 发布失败: HTTP <code> <body 前 500 字符>`，`return 1`
8. 409/422（sha 过期）→ 重新取一次 sha 重试一次，仍失败走第 7 条

**安全要点**（spec §7）：token 只经 `Authorization: Bearer` 请求头传递；不得把它写进任何变量名会输出到日志的位置，不得 `set -x`。测试断言里也不打印 token。

- [ ] **Step 4: 跑测试，确认通过**

Run: `sh tests/run_tests.sh`
Expected: 10 个用例全 `PASS`。

- [ ] **Step 5: 在容器里再跑一遍**

Run: `docker run --rm -v "$PWD:/w" -w /w alpine:3.19 sh tests/run_tests.sh`
Expected: 同样 10 个 `PASS`（`jq`/`curl` 在 alpine 基础镜像里没有，Step 3 的实现应只在真正要发请求时才需要它们；若测试因缺命令失败，改用 `docker run --rm -v "$PWD:/w" -w /w alpine:3.19 sh -c 'apk add --no-cache curl jq >/dev/null && sh tests/run_tests.sh'`）

- [ ] **Step 6: 本地提交**

```bash
git add publish.sh tests/run_tests.sh
git commit -m "feat(publish): 通过 Contents API 发布结果，含空结果守卫与 dry-run"
```

---

### Task 3: `entrypoint.sh` — 每轮清理、串联转换与发布

**Files:**
- Modify: `entrypoint.sh`
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Consumes: `publish.sh` 的 `all` 子命令
- Produces:
  - 环境变量：`DATA_DIR`（默认 `/data`）、`CFST_BIN`（默认 `/opt/cfst/cfst`）、`CRON_SCHEDULE`（默认 `0 4 * * *`）、`RUN_ON_START`（默认 `1`）、`CFST_ARGS`（默认空）
  - `DATA_DIR` 与 `CFST_BIN` 可覆盖，供测试注入假 cfst
  - 行为：cfst 参数 = `CFST_ARGS` + `$@` + 未显式给 `-o` 时补 `-o "$DATA_DIR/result.csv"`；`run_once` 先清理旧 csv/txt，再跑 cfst，再 `publish.sh all`
  - 另支持 `sh entrypoint.sh --once`：只执行一次 `run_once` 后退出，供 crontab 调用（也是 `RUN_ON_START` 复用的同一条路径）
  - 退出码：`run_once` 返回 cfst 的退出码；单次模式下 entrypoint 以该码退出；cfst 非 0 时不转换不发布

- [ ] **Step 1: 写两个失败的测试**

在 `tests/run_tests.sh` 追加（这两个用例要造一个假 cfst）：

- `test_entrypoint_single_run_produces_txt` — `DATA_DIR=$TMP/d`；`CFST_BIN` 指向一个假脚本，它把 Task 1 那份 fixture CSV 写到 `$DATA_DIR/result.csv` 并退出 0；`CRON_SCHEDULE=`（空）；不设 `GITHUB_TOKEN`。期望：退出码 0，`$DATA_DIR/result.txt` 内容等于 Task 1 `test_basic_filter_and_format` 的三行期望值。
- `test_stale_csv_cleaned` — 测试前先在 `$DATA_DIR` 放好一份**旧的** `result.csv` 与 `result.txt`；`CFST_BIN` 指向一个直接 `exit 1` 且**不写任何文件**的假脚本。期望：退出码非 0，且运行后 `$DATA_DIR/result.csv` 与 `$DATA_DIR/result.txt` **都不存在**（证明第 0 步清理生效、旧数据没有被拿去发布）。

假 cfst 脚本由测试用例内联生成（`cat > "$TMP/fake-cfst" <<'EOF' ... EOF` + `chmod +x`），不要新增会进仓库的 fixture 文件。

- [ ] **Step 2: 跑测试，确认失败**

Run: `sh tests/run_tests.sh`
Expected: 新增 2 个 `FAIL`；已有 10 个仍 `PASS`。

- [ ] **Step 3: 改造 `entrypoint.sh`**

保留它现在的两个可取之处：`$@` 透传给 cfst、未显式给 `-o` 时补默认输出路径。改动：

1. 删掉 `--cron <表达式>` 的参数解析，定时改由 `CRON_SCHEDULE` 环境变量驱动（spec §5.6）
2. `cd` 到 cfst 所在目录（`ip.txt`/`ipv6.txt` 在那里），但**输出用绝对路径** `$DATA_DIR/result.csv`
3. 新增 `run_once()`：① `rm -f "$DATA_DIR/result.csv" "$DATA_DIR/result.txt"`（**必须在跑 cfst 之前**，理由见 spec §5.1）② 跑 cfst，记下退出码 ③ 退出码为 0 时执行 `sh /opt/cfst/publish.sh all "$DATA_DIR/result.csv" "$DATA_DIR/result.txt"`，否则打错误日志跳过 ④ `return` cfst 的退出码
4. 无 `CRON_SCHEDULE`：`RUN_ON_START` 为 1 就跑一次，然后以 `run_once` 的退出码退出
5. 有 `CRON_SCHEDULE` 时分三条支路：
   - **`RUN_ON_START` 为 1** → 先跑一次 `run_once`；失败只记日志，**不退出**（否则容器会因一次网络抖动而反复重启）
   - **安装 crontab**：命令行用 `--once` 自调用，即 `<表达式> sh /opt/cfst/entrypoint.sh --once <原有 cfst 参数> >> $DATA_DIR/cfst.log 2>&1`。
     **关键**：busybox `crond` 是 daemon，**不继承容器环境变量**（只给任务最小环境）。所以命令行必须把所需变量显式前置，例如
     `GITHUB_TOKEN=$GITHUB_TOKEN DATA_DIR=$DATA_DIR REGIONS=$REGIONS TOP_N=$TOP_N GITHUB_REPO=$GITHUB_REPO ... sh /opt/cfst/entrypoint.sh --once`。
     漏掉 `GITHUB_TOKEN` 的症状是「每天静默跳过发布」，Task 5 Step 4 专门查这个
   - **`exec /usr/sbin/crond -f`** 前台常驻（busybox crond 的 `-f` 即前台，同时保证 PID 1 是 crond，容器不会退出）
6. `GITHUB_TOKEN` 为空且 `CRON_SCHEDULE` 非空 → 按 spec §8 视为配置错误，启动时打印错误并以非 0 退出。**注意**：这条与本任务 `test_entrypoint_single_run_produces_txt`（不设 token 且 `CRON_SCHEDULE` 为空）不冲突，别把校验条件写成「token 为空就退出」

时区：cron 触发时刻依赖 `TZ`，由 compose 注入（Task 4），entrypoint 不做处理。

- [ ] **Step 4: 跑测试，确认通过**

Run: `sh tests/run_tests.sh`
Expected: 12 个用例全 `PASS`。

- [ ] **Step 5: 在容器里再跑一遍**

Run: `docker run --rm -v "$PWD:/w" -w /w alpine:3.19 sh tests/run_tests.sh`
Expected: 同样 12 个 `PASS`。

- [ ] **Step 6: 本地提交**

```bash
git add entrypoint.sh tests/run_tests.sh
git commit -m "feat(entrypoint): 环境变量驱动、每轮清理、串联发布"
```

---

### Task 4: 镜像与 compose —— 装依赖、接环境变量、换卷

**Files:**
- Modify: `Dockerfile`
- Modify: `docker-compose.yml`
- Modify: `tests/run_tests.sh`
- 已改、本任务只需验证：`.gitignore`（已加 `.env`、`output/`）、`.dockerignore`（已加 `.env`、`output`）

**Interfaces:**
- Consumes: Task 1–3 的所有脚本与环境变量
- Produces: 镜像内 `/opt/cfst/publish.sh` 可执行；compose 服务名 `cfst`，卷 `./output:/data`，`restart: unless-stopped`

- [ ] **Step 1: 写两个失败的测试**

- `test_image_has_runtime_deps` — 构建最终镜像（`docker build -t cfst:test .`），然后 `docker run --rm cfst:test sh -c 'command -v curl && command -v jq && command -v crond && test -x /opt/cfst/publish.sh'`。期望：退出码 0。
- `test_builder_stage_has_no_env_file` — `docker build --target builder -t cfst-builder:test .`，然后 `docker run --rm cfst-builder:test sh -c 'test ! -e /app/.env'`。期望：退出码 0（证明 `.dockerignore` 真的把 `.env` 挡在了构建上下文之外，token 不会进构建层与缓存）。若本机 `.env` 尚不存在，先 `touch .env` 再造一次，确保测的是忽略规则而不是「文件本来就没有」。

把这两条做成 `tests/run_tests.sh` 里的可跳过用例：检测到 `docker` 不存在时打 `SKIP` 而非 `FAIL`（这样 Task 1–3 在没装 Docker 的机器上也能跑）。

- [ ] **Step 2: 跑测试，确认失败**

Run: `sh tests/run_tests.sh`
Expected: 两个新用例 `FAIL`（镜像里还没有 curl/jq/publish.sh）。

- [ ] **Step 3: 改 `Dockerfile` 与 `docker-compose.yml`**

`Dockerfile`：
- 运行阶段 `apk add --no-cache ca-certificates tzdata curl jq`
- `COPY publish.sh /opt/cfst/publish.sh` 并 `chmod +x`
- 其余保持现状（多阶段构建、`CGO_ENABLED=0`、`VOLUME ["/data"]`、`ENTRYPOINT ["sh", "/opt/cfst/entrypoint.sh"]`）

`docker-compose.yml`：
- `volumes: - ./output:/data`（替换原来的 `./result:/data`）
- `restart: unless-stopped`（原来是 `no`；定时模式下容器要常驻）
- `environment:` 逐项列出 spec §5.7 的变量，token 写 `GITHUB_TOKEN: ${GITHUB_TOKEN}`，其余用 `${X:-默认值}` 形式给出默认值
- `command:` 保持 `["-tl", "200", "-sl", "50", "-dn", "20"]`，并保留注释说明常用参数
- 手工验证一次 compose 能解析：`docker compose config` 退出码 0，且输出里能搜到 `GITHUB_TOKEN` 与 `unless-stopped`

- [ ] **Step 4: 跑测试，确认通过**

Run: `sh tests/run_tests.sh`
Expected: 全部 `PASS`（Docker 缺失时这两个用例显示 `SKIP`）。

- [ ] **Step 5: 本地提交**

```bash
git add Dockerfile docker-compose.yml tests/run_tests.sh
git commit -m "build: 镜像装 curl/jq，compose 接环境变量并改卷与重启策略"
```

---

### Task 5: 容器端到端（真实测速，暂不发布）

**Files:** 无代码改动；本任务只做验证，发现的缺陷回到对应任务修。

**Interfaces:**
- Consumes: Task 1–4 的全部产物
- Produces: 宿主 `./output/result.csv` 与 `./output/result.txt`；可复用的 `PUBLISH_DRY_RUN=1` 配置写法

- [ ] **Step 1: 以 dry-run 启动，确保本轮不会写远端**

临时在 `.env` 里加 `PUBLISH_DRY_RUN=1`（或 `docker compose run -e` 覆盖），然后 `docker compose up -d --build`。

- [ ] **Step 2: 等待首轮测速结束**

Run: `docker compose logs -f cfst`（等到出现发布或跳过发布的日志），或轮询 `./output/result.txt` 出现。真实测速（`-tl 200 -sl 50 -dn 20`）需要几分钟到十几分钟。

- [ ] **Step 3: 校验宿主产物**

把每行拆成「地区 延迟」再做检查（`#优选` 前是 IP，`-` 后是延迟，结尾 `m`）：

```sh
# 1) 总行数
wc -l output/result.txt                                    # 期望 ≤ 40

# 2) 行格式：不符合规范的行数必须为 0
grep -vcE '^[^#]+#优选(HKG|NRT|SIN|SJC|LAX)-[0-9]+\.[0-9]{2}m$' output/result.txt

# 3) 提取「地区 延迟」到临时文件（后面几条检查都基于它）
awk -F'#优选' '{split($2,a,"-"); d=a[2]; sub(/m$/,"",d); print a[1], d}' \
  output/result.txt > /tmp/rt

# 4) 每个地区行数 ≤ 8，且只出现这 5 个地区
awk '{print $1}' /tmp/rt | sort | uniq -c

# 5) 同一地区内延迟升序（顺序不对时 sort -c 会非 0 退出）
sort -c -k1,1 -k2,2n /tmp/rt && echo "组内升序 OK"
```

Expected: 行数 ≤ 40；第 2 条输出 `0`；第 4 条每行计数 ≤ 8 且地区集合 ⊆ `{HKG,NRT,SIN,SJC,LAX}`；第 5 条打印 `组内升序 OK`。

> 宿主检查用 `-n` 而不是 `-g`：macOS 自带的 BSD `sort` 没有 `-g`，`publish.sh` 内部跑在 busybox 上才用 `-g`。对两位小数的延迟，两者结果一致。

- [ ] **Step 4: 校验定时与常驻**

Run:
```sh
docker compose exec cfst crontab -l
docker compose exec cfst cat /proc/1/comm      # 期望 crond
docker compose ps                              # 期望 running
```
Expected: crontab 里能看到 `CRON_SCHEDULE` 对应的行，且命令里带着转换/发布所需的全部环境变量（busybox crond 不继承 shell 变量，这里最容易漏）。

- [ ] **Step 5: 校验日志里没有 token**

Run:
```sh
tok=$(grep '^GITHUB_TOKEN=' .env | cut -d= -f2-)
echo "命中次数: $(grep -c -F "$tok" output/cfst.log 2>/dev/null || true)"
docker inspect cfst --format '{{json .Config.Env}}' | tr ',' '\n' | grep -c -F "$tok"
docker inspect cfst --format '{{json .Config.Cmd}}' | grep -c -F "$tok" || echo "0（命令行里没有）"
```
Expected: 日志命中 `0`；`Config.Env` 命中 `1`（这是 compose 的正常注入，可接受）；**`Config.Cmd` 命中 `0`** —— token 不能出现在命令行参数里。测完 `unset tok`。

---

### Task 6: 真实发布到 GitHub（会写远端 master）

**Files:** 无代码改动；验证用。

**Interfaces:**
- Consumes: Task 5 的真实测速产物、`.env` 里的真 token
- Produces: `master` 上的 `result/result.txt` 新 commit

- [ ] **Step 1: 确认写入授权**

这是本计划里**唯一会修改远端仓库**的步骤。确认 `.env` 里的 token 是 fine-grained、只授权 `Shawnge/CloudflareSpeedTest`、`Contents: Read and write`（spec §5.4）。

- [ ] **Step 2: 关掉 dry-run 并重跑一次真实发布**

从 `.env` 移除 `PUBLISH_DRY_RUN`，`docker compose up -d --force-recreate`，等首轮跑完。

- [ ] **Step 3: 校验远端 commit**

Run:
```sh
set -a; . ./.env; set +a
curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
  "https://api.github.com/repos/$GITHUB_REPO/contents/$RESULT_PATH?ref=$GITHUB_BRANCH" \
  | jq -r '.sha, .size, .commit.message'
```
Expected: 有 `sha`、`size` 等于本地 `result.txt` 的字节数、message 形如 `chore: update result.txt (...)`。

- [ ] **Step 4: 校验 raw 内容（edgetunnel 真正读的地址）**

Run:
```sh
diff <(curl -s "https://raw.githubusercontent.com/Shawnge/CloudflareSpeedTest/master/result/result.txt?t=$(date +%s)") output/result.txt && echo "raw 与本地一致"
```
Expected: 无差异。raw 有约 5 分钟 CDN 缓存，`?t=` 参数用于绕过。

- [ ] **Step 5: 校验无效 token 时的行为**

Run:
```sh
docker compose exec -e GITHUB_TOKEN=invalid_token cfst sh -c 'cd /data && sh /opt/cfst/publish.sh push /data/result.txt; echo "exit=$?"'
```
Expected: `exit=1`，stderr 里有 `发布失败: HTTP 401`；远端文件**未被改动**（用 Step 3 的 `sha` 比对，应完全相同）；容器仍在运行（`docker compose ps` 为 running）。这条同时覆盖 spec §8 的「401/403 → 记日志、不发布、容器存活」与验收 §10.5。

---

### Task 7: 文档、占位目录与 remote

**Files:**
- Create: `result/.gitkeep`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1–6 已确定的环境变量名与默认值
- Produces: 使用者可照着部署的文档

- [ ] **Step 1: 建占位目录**

`mkdir -p result && touch result/.gitkeep`（本地不挂载 `result/`，它只承接远端文件）

- [ ] **Step 2: 在 `README.md` 新增「Docker Compose 部署」一节**

必须覆盖：
1. 前提：装好 Docker + Compose；在 `Shawnge/CloudflareSpeedTest` 上创建一个 fine-grained PAT，权限只要 `Contents: Read and write`（写清「不需要 Actions / Workflows / Administration」）
2. `cp .env` 说明：把 `GITHUB_TOKEN` 替换成真值；列出 spec §5.7 的全部环境变量与默认值
3. `docker compose up -d --build`；`docker compose logs -f`；产物在 `./output/`
4. 给 edgetunnel 填的 raw 地址：`https://raw.githubusercontent.com/Shawnge/CloudflareSpeedTest/master/result/result.txt`
5. 排查表：token 过期（日志 401，换 token 重启即可，容器不会死）／结果为空（日志 `结果为空，跳过发布`，远端保持上一版）／地区码全是 `N/A`（说明没跑下载测速，检查 `command:` 里有没有 `-dd`）／定时没触发（检查 `TZ`）
6. 本地测试怎么跑：`sh tests/run_tests.sh`

- [ ] **Step 3: 改 remote**

```bash
git remote set-url origin https://github.com/Shawnge/CloudflareSpeedTest.git
git remote -v
```
Expected: fetch/push 都指向 `Shawnge/CloudflareSpeedTest`。

- [ ] **Step 4: 本地提交**

```bash
git add result/.gitkeep README.md
git commit -m "docs: 补充 Docker Compose 部署说明，新增 result 占位目录"
```

- [ ] **Step 5: 交回使用者**

**不要 `git push`。** 把当前分支留在这里，由使用者自己决定何时推到 fork 的 `master`。

---

## 完成标准

全部任务完成后，下列每条都能指出对应的验证记录：

1. `sh tests/run_tests.sh` 在 macOS 与 alpine:19 全绿（Docker 缺失时仅镜像相关用例 `SKIP`）
2. `docker compose up -d --build` 后容器常驻，`/proc/1/comm` 为 `crond`
3. `./output/result.txt` 满足 spec §10.3（行数、正则、组内升序、每区 ≤ `TOP_N`）
4. `master` 上 `result/result.txt` 的 raw 内容与本地一致
5. 空结果与无效 token 两种情况下，远端都保持上一版好结果，且容器存活
6. 日志与构建层中都搜不到 token
7. 仓库工作区在多次运行 + `git pull` 后无冲突（`./output` 不在仓库内、`result.txt` 不被本地生成）
