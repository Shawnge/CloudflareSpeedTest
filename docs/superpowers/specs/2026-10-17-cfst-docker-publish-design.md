# CloudflareSpeedTest 容器化定时优选 + 结果发布 设计

日期：2026-10-17

## 1. 目的（为什么做）

`Shawnge/CloudflareSpeedTest`（XIU2/CloudflareSpeedTest 的 fork）目前只能手动跑、手动看结果。
目标是把「测速 → 挑出可用 IP → 生成 edgetunnel 能直接吃的列表 → 发布」这条链路装进
Docker Compose，在自有服务器上每天自动跑一次，免人工。

最终产物是一份纯文本，**由 edgetunnel 通过 GitHub raw 链接读取**，作为它的优选 IP 来源。

## 2. 目标 / 非目标 / 反目标

### 目标
- 一条 `docker compose up -d` 就能常驻运行，无需手工干预
- 每天定时执行一次测速
- 把 `result.csv` 转成 edgetunnel 需要的纯文本格式
- 把该文本推送到 `Shawnge/CloudflareSpeedTest` 的 `master` 分支
- 推送凭证与定时配置全部通过环境变量提供

### 非目标
- 不修改 cfst 的 Go 源码（保持可随时 merge 上游）
- 不做历史结果归档 / 时间序列对比
- 不做 Web 面板、通知（邮件/TG）等
- 不处理 IPv6 的特殊格式（若测速结果出现 IPv6，按同样格式原样输出，见 §9）

### 反目标（做出来算失败）
- **一次网络异常导致发布的列表被清空**，edgetunnel 手里从有好 IP 变成空列表
- token 出现在 git remote URL、reflog、日志或镜像层里
- 需要人工每天去看一眼才知道有没有在跑
- 容器内的结果文件与仓库工作区相互覆盖，导致 `git pull` 报错

## 3. 约束

- 运行环境：自有服务器，长期开机，已装 Docker + Docker Compose
- 频率：每天一次
- 目标区域：`HKG` `NRT` `SIN` `SJC` `LAX`，每个区域取延迟最低的 8 个（最多 40 行）
- 输出行格式：`${ip}#优选${区域}-${延时}m`
  例：`203.0.113.7#优选HKG-45.12m`
- 发布目标：`https://github.com/Shawnge/CloudflareSpeedTest`，分支 `master`，路径 `result/result.txt`（raw 链接给 edgetunnel 用）
- 消费方：edgetunnel，读 raw 链接，需要「当前最优」而不是历史累积

## 4. 现状与既有约束（实测）

| 事实 | 影响 |
|---|---|
| `Dockerfile` / `docker-compose.yml` / `entrypoint.sh` / `.dockerignore` 目前是**未提交的本地文件**（untracked） | 在它们基础上改，不重写 |
| 当前 remote 是上游 `XIU2/CloudflareSpeedTest` | 需改为 `https://github.com/Shawnge/CloudflareSpeedTest.git` |
| fork 的默认分支是 `master` | 推送分支取 `master` |
| `utils/csv.go` 的 CSV 列：`IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码` | 转换按列位置取值 |
| 地区码由测速响应的 `cf-ray`/`x-served-by` 头解析得到；**下载测速阶段也会补写**（仅当为空时），HTTPing 模式同样会写 | 不强制 `-httping`；但**必须保留下载测速**，否则全国区码都是 `N/A` |
| 取不到地区码时 CSV 写入 `N/A` | 该行丢弃 |
| 平均延迟列是毫秒、两位小数字符串（如 `45.12`） | 直接作为「延时」 |
| alpine:3.19 自带 busybox `crond`（`/usr/sbin/crond`）与 `crontab` | 定时无需额外安装 |
| alpine 的 busybox `sort` 支持 `-t`/`-k`/`-g`（已实测） | 转换可用 awk + sort 纯 shell 实现，无需 Go 改动 |
| 现有 `entrypoint.sh` 已实现 `--cron <表达式>`，默认输出 `/data/result.csv`，但**定时模式**下用的是带时间戳的 `/data/result_$(date +%Y%m%d_%H%M%S).csv` | 改造为环境变量驱动 + **固定** `-o /data/result.csv`（时间戳文件名会与下游的固定路径假设冲突，必须去掉） |
| `.gitignore` 已忽略 `*.csv` | 本地 CSV 不会被误提交；`result.txt` 另行处理（见 §5.5） |

## 5. 设计

### 5.1 总体流程

```
docker compose up -d
   └─ entrypoint.sh
        ├─ RUN_ON_START=1 → 立即执行一次 run_once
        └─ CRON_SCHEDULE 非空 → 安装 crontab，前台常驻 crond
                      │
   run_once ──────────┘
        ├─ 0. 清理：删除上一轮的 /data/result.csv 与 /data/result.txt
        ├─ 1. cfst 执行测速，产出 /data/result.csv（固定文件名）
        ├─ 2. 转换：result.csv → /data/result.txt（筛选/排序/取前 N）
        ├─ 3. 守卫：result.txt 为空 → 记录日志并放弃发布（不推送、不覆盖远端）
        └─ 4. 发布：GitHub Contents API PUT 到 repo:branch:path
```

**第 0 步「清理」是必须的，不是可选的。** 原因：`utils/csv.go` 的 `ExportCsv` 在结果为空时
会在 `os.Create` 之前直接 `return`，既不创建也不截断文件。若不先删除，一次失败（或 `-sl`
过滤后无结果）的运行会留下**上一轮的旧 CSV**，转换后得到一份非空的旧数据，空结果守卫永远不会
触发，就会把旧结果当成新结果重新发布——正好踩中 §2 的反目标。所以每轮开跑前先删干净，
让「没有新 CSV / 新 CSV 为空」都能被守卫拦住。

非定时模式（`CRON_SCHEDULE` 为空）时退化为「跑一次就退出」，便于手动调试；**只要
`GITHUB_TOKEN` 存在，单次运行同样会发布**（见 §5.7）。

### 5.2 转换规则（核心）

输入：`/data/result.csv`（Go `encoding/csv` 写出，无 BOM，逗号分隔，首行表头）

输出：`/data/result.txt`，UTF-8，LF，每行一条

规则，按顺序：
1. 跳过表头
2. 丢弃 `地区码` 为 `N/A` 或空的行
3. 只保留 `地区码 ∈ REGIONS`
4. 按 `地区码` 分组，组内按 `平均延迟` 数值升序
5. 每组取前 `TOP_N` 条
6. 按 `REGIONS` 中声明的**顺序**输出分组（不是字典序），可读性更符合预期
7. 行格式：`{ip}#优选{地区}-{平均延迟}m`
   - ip 取第 1 列原文
   - 地区取第 7 列
   - 平均延迟取第 5 列原文（两位小数），后接字面量 `m`
   - 期望形态：`203.0.113.7#优选HKG-45.12m`

参考实现（已在 alpine:3.19 实测可通过）：

```sh
LC_ALL=C awk -F',' -v R="$REGIONS" '
  BEGIN { n=split(R, r, ","); for (i=1;i<=n;i++) ok[r[i]]=1 }
  NR>1 && $7!="N/A" && $7!="" && ($7 in ok) { printf "%s\t%s\t%s\n", $7, $5, $1 }
' result.csv \
| LC_ALL=C sort -t"	" -k1,1 -k2,2g \
| LC_ALL=C awk -F'\t' -v R="$REGIONS" -v N="$TOP_N" '
    BEGIN { n=split(R, order, ",") }
    { c[$1]++; if (c[$1] <= N) buf[$1] = buf[$1] $0 "\n" }
    END { for (i=1;i<=n;i++) printf "%s", buf[order[i]] }
  ' \
| LC_ALL=C awk -F'\t' '{ printf "%s#优选%s-%sm\n", $3, $1, $2 }'
```

地区名数量可能少于 `TOP_N`（该地区没测出可用 IP）时：该地区无输出，不报错。
地区总数可能不足 5 个时同理。

### 5.3 空结果守卫（反目标防护）

`result.txt` 行数为 0 时：
- 记录 `WARN` 日志，说明原因（可能是网络异常 / 未开启下载测速 / 区域都不匹配）
- **不推送**，远端保持上一次的好结果
- 进程按成功处理（不退出常驻循环）

### 5.4 发布（GitHub Contents API）

为什么用 API 而不是 `git push`：token 只出现在单次 HTTP 请求头中，不会写进
`.git/config`（remote URL）、reflog、或任何镜像层 / 日志。且单个文件覆盖是 API 的天然用法。

步骤：
1. `GET /repos/{GITHUB_REPO}/contents/{RESULT_PATH}?ref={GITHUB_BRANCH}`
   - 200 → 取 `sha`（更新必填）
   - 404 → 无 `sha`（首次创建）
   - 401/403 → token 无效 / 权限不足，报错退出本次发布
2. `PUT /repos/{GITHUB_REPO}/contents/{RESULT_PATH}`
   - header：`Authorization: Bearer $GITHUB_TOKEN`、`Accept: application/vnd.github+json`
   - body：`{"message":..., "content":"<base64>", "branch":"<branch>", "sha":"<sha 若有>"}`
   - commit message：`chore: update result.txt (YYYY-MM-DD HH:MM:SS)`
3. 非 2xx → 记录响应内容到日志，本次发布失败（下一天重试）

依赖：镜像内需要 `curl` 与 `jq`（`apk add --no-cache curl jq`）。

参考实现（`publish.sh` 中的发布函数，已在 alpine:3.19 实测关键步骤）：

```sh
api="https://api.github.com/repos/$GITHUB_REPO/contents/$RESULT_PATH"

# 1) 取当前文件的 blob sha（不存在则拿不到，属正常）
sha=$(curl -fsS \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "$api?ref=$GITHUB_BRANCH" \
      | jq -r '.sha // empty' || true)

# 2) 组装 body：content 必须是 base64
payload=$(jq -n \
    --arg message "chore: update result.txt ($(date '+%F %T'))" \
    --arg content "$(base64 -w 0 "$txt")" \
    --arg branch  "$GITHUB_BRANCH" \
    --arg sha     "$sha" \
    '{message:$message, content:$content, branch:$branch}
     + (if $sha == "" then {} else {sha:$sha} end)')

# 3) 提交（无 sha = 创建，有 sha = 覆盖更新）
curl -fsS -X PUT \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -d "$payload" "$api"
```

实测结论（alpine:3.19 + busybox）：
- `curl` 可用；`base64 -w 0` 可直接产出单行 base64（无需 `tr -d '\n'`）
- `jq` 需 `apk add`，可用 `-n --arg` 安全构造 JSON（内容里出现 `#`、非 ASCII 中文都不会破坏 JSON）
- 对未创建过的 `result/result.txt` 请求 `?ref=master` 返回 **HTTP 404**（已确认），
  所以首次发布走「创建」分支，`sha` 为空；此后走「更新」分支
- `curl -fsS` 在 4xx/5xx 时以非 0 退出，便于直接判定失败
- 并发冲突（PUT 返回 409/422，通常是 sha 过期）时：重新 GET 一次 sha 再重试一次，仍失败则放弃本次

token 从未写入镜像或 `.git` 目录，只作为一次 HTTP 请求头存在。

发布用 `GITHUB_TOKEN` 的权限：fine-grained PAT，仅授权
`Shawnge/CloudflareSpeedTest` 一个仓库、`Contents: Read and write`。

### 5.5 目录布局：为什么新增 `./output`

现有 compose 把宿主 `./result` 挂到容器的 `/data`。若继续这样，容器生成的
`result.txt` 会同时存在于仓库工作区，而它又被提交到了远端 `master`，于是
下次 `git pull` 会因「本地未跟踪文件将被覆盖」而失败。

改为：
- compose 挂载 `./output:/data`，并把 `output/` 加入 `.gitignore`
- 容器内本地产物：`/data/result.csv`（本地存档，已被 `*.csv` 忽略）与 `/data/result.txt`
- 仓库内的发布路径是**另一个位置**：`result/result.txt`（只存在于远端与 commit 里，本地不影响工作区）

`result/` 目录保留在仓库中（当前为空）承接远端文件，本地不做挂载。

### 5.6 定时

- 触发源：环境变量 `CRON_SCHEDULE`（5 段标准 cron 表达式），默认 `0 4 * * *`
- 非空 → 写入 crontab，前台 `exec /usr/sbin/crond`（PID 1，容器常驻）
- 空 → 只跑一次然后退出
- **无论哪条路径，cfst 一律用固定输出 `/data/result.csv`**（不再使用带时间戳的文件名），
  否则下游 `publish.sh` 不知道该读哪个文件
- 时区：容器默认 UTC。需 `TZ` 环境变量（如 `Asia/Shanghai`）才能在期望的本地时间触发；`tzdata` 已在镜像中
- 每次 cron 执行的 stdout/stderr 追加到 `/data/cfst.log`，便于事后排查
- `restart: unless-stopped`：常驻模式下崩了要自动拉起

### 5.7 配置项（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `GITHUB_TOKEN` | 无（必填才发布） | fine-grained PAT，Contents 读写 |
| `GITHUB_REPO` | `Shawnge/CloudflareSpeedTest` | `owner/repo` |
| `GITHUB_BRANCH` | `master` | 目标分支 |
| `RESULT_PATH` | `result/result.txt` | 仓库内路径 |
| `REGIONS` | `HKG,NRT,SIN,SJC,LAX` | 保留的地区码，顺序即输出顺序 |
| `TOP_N` | `8` | 每区保留条数 |
| `CRON_SCHEDULE` | `0 4 * * *` | 为空则单次运行后退出 |
| `RUN_ON_START` | `1` | 启动时先跑一次 |
| `TZ` | `Asia/Shanghai` | 影响 cron 触发时间 |
| `CFST_ARGS` | 空 | 追加的 cfst 参数；与 `command:` 中的参数合并 |

cfst 的参数仍通过 compose 的 `command:` 传递（沿用现有 `["-tl","200","-sl","50","-dn","20"]`），
`entrypoint.sh` 在未显式给出 `-o` 时补 `/data/result.csv`。

发布是否发生只取决于两点：**转换后有内容**（见 §5.3）**且 `GITHUB_TOKEN` 非空**。
与「定时 / 单次」「启动即跑 / cron 触发」无关——单次运行带 token 也会发布。

`GITHUB_TOKEN` 的注入方式：宿主机根目录 `.env` 文件 + compose 的 `environment: GITHUB_TOKEN: ${GITHUB_TOKEN}`，
或等价的 `env_file:`。关键是 `.env` 必须同时加进 `.gitignore` 和 `.dockerignore`（见 §7）。

## 6. 改动清单

新增：
- `docs/superpowers/specs/2026-10-17-cfst-docker-publish-design.md`（本文档）
- `publish.sh`：转换 + 发布，可独立执行（`publish.sh <csv> <out.txt>`），便于脱离容器调试

修改：
- `entrypoint.sh`：改为环境变量驱动；保留 `$@` 透传 cfst；每轮先清理旧的 csv/txt；固定 `-o /data/result.csv`；启动即跑 / 定时循环；接上 `publish.sh`
- `Dockerfile`：`apk add curl jq`；拷贝 `publish.sh` 并 chmod
- `docker-compose.yml`：卷改 `./output:/data`；`environment:` 列出所有变量（token 走 `${GITHUB_TOKEN}`）；`restart: unless-stopped`
- `.gitignore`：加 `output/`、`.env`
- `.dockerignore`：加 `.env`、`output/`（当前没有排除 `.env`，而构建阶段是 `COPY . .`，会把 token 烤进构建层——与 §7 的安全承诺直接冲突，必须修）
- `README.md`：新增「Docker Compose 部署」一节，含 token 创建、edgetunnel 配置的 raw 链接、常见排查
- git remote：改为 `https://github.com/Shawnge/CloudflareSpeedTest.git`
- `result/`：保留空目录占位（`.gitkeep`），远端由推送产生 `result.txt`

**交付边界**：实现方只在本地工作区修改并完成验证，**不执行任何 `git commit` / `git push`**。
代码是否提交、何时提交到 fork 的 `master`，由仓库所有者自行决定并执行。

新增（本地、不提交）：`.env`（放 `GITHUB_TOKEN`）

## 7. 安全

- token 只经环境变量注入；`.env` 同时加入 `.gitignore` 和 `.dockerignore`
  （只加 `.gitignore` 不够：Dockerfile 构建阶段 `COPY . .` 会把 `.env` 复制进构建层与构建缓存）
- compose 里用 `${GITHUB_TOKEN}` 引用而非明文；日志中不打印 token
- curl 失败时只记录响应 body 与状态码
- token 权限最小化：单仓库 + Contents 读写

## 8. 失败模式与处理

| 情况 | 处理 |
|---|---|
| cfst 退出码非 0 | 不转换、不发布，日志报错 |
| CSV 中无匹配区域 / 全为 `N/A` | 空结果守卫，不发布 |
| 转换后为空 | 空结果守卫，不发布 |
| token 缺失 | 若 `CRON_SCHEDULE` 非空：视为配置错误，启动时直接报错退出；否则仅测速不发布 |
| token 无效 / 权限不足（401/403） | 记录日志，本次不发布，容器继续存活 |
| GitHub API 5xx / 网络不通 | 记录日志，本次不发布，容器继续存活 |
| 未开启下载测速（`-dd`） | 所有地区码为 `N/A`，被空结果守卫生效，日志给出提示 |

## 9. 已知取舍（实现者无需再确认）

- 延迟保留两位小数，与 CSV 一致
- 延时后缀 `m` 是字面量（毫秒标记）
- 全量覆盖，不做历史归档
- 输出按 `REGIONS` 声明顺序分组，组内按延迟升序；组间不跨区混合排序
- IPv6：若结果含 IPv6 地址，原样输出（不做方括号包裹等特殊处理）；若 edgetunnel 不接受，后续再改

## 10. 验收标准

1. `docker compose up -d --build` 成功；容器 `restart: unless-stopped` 下持续运行
2. 启动后立即产生 `/data/result.csv` 与 `/data/result.txt`（宿主 `./output/` 下可见）
3. `./output/result.txt` 内容满足：
   - 行数 ≤ `TOP_N × 5`
   - 每行匹配 `^[^#]+#优选(HKG|NRT|SIN|SJC|LAX)-[0-9]+\.[0-9]{2}m$`
   - 同一地区内延迟升序
   - 每个地区行数 ≤ `TOP_N`
4. `https://raw.githubusercontent.com/Shawnge/CloudflareSpeedTest/master/result/result.txt` 在发布后返回上述内容
   （raw 有约 5 分钟 CDN 缓存，验证时可拼 `?t=$(date +%s)` 绕过）
5. 空结果守卫有效：
   - 造一个空 CSV → `publish.sh` 不推送，日志出现空结果告警，远端文件不变
   - 模拟一次失败运行（让 cfst 产出 0 条结果、留下上一轮的 `result.csv`）→ 校验旧 CSV 已被
     第 0 步清理，守卫拦住，远端**仍是上一轮的好结果**，没有被旧数据覆盖重发
6. 日志中不出现 token 明文
7. `docker build` 后 `docker history` / 构建层中搜不到 token 字符串
8. 仓库工作区在多次运行 + `git pull` 后无冲突

## 11. 验收方式

验收按「本地验证 + 真实端到端」两段进行，真实端到端**使用仓库所有者提供的 PAT**：

- 本地验证（不依赖凭证）：转换规则、排序、前 N 截断、空结果守卫、旧 CSV 清理
- 真实端到端（需要 `GITHUB_TOKEN`）：
  1. 从宿主机 `.env` 注入 token，跑一次真实发布
  2. 确认 `master` 上出现 `result/result.txt` 的新 commit，内容符合 §10.3
  3. 确认 `raw.githubusercontent.com/.../master/result/result.txt` 返回该内容
  4. 用一个故意无效的 token 再跑一次，确认是「记录日志 + 不发布 + 容器存活」，而非崩溃
- 验收完成后，token 不会出现在任何被记录的产物中；若不希望长期保留，验收后作废并重新签发

实现方不代管 token 的长期存储：token 只写入本地 `.env`（已被 `.gitignore` / `.dockerignore` 排除）。
