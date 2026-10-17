#!/bin/sh
# publish.sh 的测试。POSIX sh，在 macOS 与 alpine:3.19（busybox）上均可运行。
# 用法：sh tests/run_tests.sh
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s — %s\n' "$1" "$2"; }
assert_eq() { # <name> <actual> <expected>
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        bad "$1" "expected [$(printf '%s' "$3")] got [$(printf '%s' "$2")]"
    fi
}
assert_contains() { # <name> <haystack> <needle>
    case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1" "未包含 [$3]，实际: [$(printf '%s' "$2")]" ;;
    esac
}

# 调用 publish.sh convert。REGIONS/TOP_N 用 env 显式传入，避免用例之间互相串味。
# 传空串时 publish.sh 内部的 ${VAR:=默认值} 会补上默认值。
convert() { # <csv> <out> [REGIONS] [TOP_N]
    env REGIONS="${3:-}" TOP_N="${4:-}" \
        sh "$REPO/publish.sh" convert "$1" "$2" 2>"$TMP/err"
}

HEADER='IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码'
fixture() { printf '%s\n' "$HEADER" >"$1"; }
row() { # <csv> <ip> <平均延迟> <地区码>
    printf '%s,4,4,0.00,%s,10.00,%s\n' "$2" "$3" "$4" >>"$1"
}
newdir() { mkdir -p "$TMP/$1"; printf '%s' "$TMP/$1"; }

# 调用 publish.sh push。所有变量都显式经 env 传入，避免用例之间串味，也避免测试脚本自身被污染。
# <txt> <token> <dry_run> <api_base> [branch] [repo] [path]
# stdout -> $TMP/out，stderr -> $TMP/err
push() {
    env GITHUB_TOKEN="$2" \
        PUBLISH_DRY_RUN="$3" \
        GITHUB_API_BASE="$4" \
        GITHUB_BRANCH="${5:-master}" \
        GITHUB_REPO="${6:-Shawnge/CloudflareSpeedTest}" \
        RESULT_PATH="${7:-result/result.txt}" \
        sh "$REPO/publish.sh" push "$1" >"$TMP/out" 2>"$TMP/err"
}

# 运行 entrypoint.sh。显式清空 GITHUB_TOKEN，保证这两个用例不联网、不发布。
# <data_dir> <cfst_bin> <cron_schedule> <run_on_start> [额外参数...]
entrypoint_run() {
    d=$1
    b=$2
    c=$3
    r=$4
    shift 4
    env DATA_DIR="$d" \
        CFST_BIN="$b" \
        PUBLISH_SH="$REPO/publish.sh" \
        CRON_SCHEDULE="$c" \
        RUN_ON_START="$r" \
        GITHUB_TOKEN= \
        sh "$REPO/entrypoint.sh" "$@" >"$TMP/ep_out" 2>"$TMP/ep_err"
}

# ---------------------------------------------------------------------------
# 过滤 + 格式：只保留 REGIONS 成员，N/A 与无关地区丢弃，按 REGIONS 顺序输出
d=$(newdir basic)
fixture "$d/in.csv"
row "$d/in.csv" 1.1.1.1 45.12 HKG
row "$d/in.csv" 2.2.2.2 52.30 NRT
row "$d/in.csv" 3.3.3.3 33.10 AMS      # 不在名单里
row "$d/in.csv" 4.4.4.4 11.00 N/A      # 拿不到地区码
row "$d/in.csv" 5.5.5.5 60.00 SIN
convert "$d/in.csv" "$d/out.txt" "HKG,NRT,SIN,SJC,LAX" "8"
expected='1.1.1.1#优选HKG-45.12m
2.2.2.2#优选NRT-52.30m
5.5.5.5#优选SIN-60.00m'
assert_eq test_basic_filter_and_format "$(cat "$d/out.txt")" "$expected"

# ---------------------------------------------------------------------------
# 每区截断到 TOP_N，且截断的是「延迟最小的 N 个」
d=$(newdir topn)
fixture "$d/in.csv"
row "$d/in.csv" 1.1.1.1 50.00 HKG
row "$d/in.csv" 2.2.2.2 20.00 HKG
row "$d/in.csv" 3.3.3.3 30.00 HKG
row "$d/in.csv" 4.4.4.4 40.00 HKG
convert "$d/in.csv" "$d/out.txt" "HKG" "2"
expected='2.2.2.2#优选HKG-20.00m
3.3.3.3#优选HKG-30.00m'
assert_eq test_top_n_truncation_and_order "$(cat "$d/out.txt")" "$expected"

# ---------------------------------------------------------------------------
# 输出顺序跟随 REGIONS 声明顺序，不是 CSV 顺序、也不是字典序
d=$(newdir order)
fixture "$d/in.csv"
row "$d/in.csv" 1.1.1.1 20.00 HKG      # CSV 里 HKG 在前
row "$d/in.csv" 2.2.2.2 30.00 SIN
convert "$d/in.csv" "$d/out.txt" "SIN,HKG" ""
expected='2.2.2.2#优选SIN-30.00m
1.1.1.1#优选HKG-20.00m'
assert_eq test_region_output_order "$(cat "$d/out.txt")" "$expected"

# ---------------------------------------------------------------------------
# 延迟按数值排序，不是字符串排序（字符串会把 100.50 排在 9.90 前面）
d=$(newdir num)
fixture "$d/in.csv"
row "$d/in.csv" 1.1.1.1 100.50 HKG
row "$d/in.csv" 2.2.2.2 9.90 HKG
row "$d/in.csv" 3.3.3.3 10.10 HKG
convert "$d/in.csv" "$d/out.txt" "HKG" "8"
expected='2.2.2.2#优选HKG-9.90m
3.3.3.3#优选HKG-10.10m
1.1.1.1#优选HKG-100.50m'
assert_eq test_numeric_delay_sort "$(cat "$d/out.txt")" "$expected"

# ---------------------------------------------------------------------------
# 空结果：输出文件必须存在且为 0 字节（下游 push 据此判定「结果为空」）
d=$(newdir empty)
fixture "$d/in.csv"
row "$d/in.csv" 1.1.1.1 45.12 N/A
row "$d/in.csv" 2.2.2.2 52.30 N/A
convert "$d/in.csv" "$d/out.txt" "" ""
assert_eq test_empty_result_writes_empty_file "$(wc -c <"$d/out.txt" | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
# CRLF 输入：地区码会变成 "HKG\r"，必须先剥掉 \r 才能匹配
d=$(newdir crlf)
printf '%s\r\n' "$HEADER" >"$d/in.csv"
printf '1.1.1.1,4,4,0.00,45.12,10.00,HKG\r\n' >>"$d/in.csv"
convert "$d/in.csv" "$d/out.txt" "" ""
assert_eq test_crlf_input "$(cat "$d/out.txt")" '1.1.1.1#优选HKG-45.12m'

# ---------------------------------------------------------------------------
# 非 IATA / 大小写不符 / 空的地区码：安全丢弃，不崩
d=$(newdir odd)
fixture "$d/in.csv"
row "$d/in.csv" 1.1.1.1 11.00 US       # 国家码，不是机场码
row "$d/in.csv" 2.2.2.2 22.00 hkg      # 小写
row "$d/in.csv" 3.3.3.3 33.00 N/A
row "$d/in.csv" 4.4.4.4 44.00 ""       # 空
row "$d/in.csv" 5.5.5.5 55.00 HKG      # 唯一有效
rc=0
convert "$d/in.csv" "$d/out.txt" "" "" || rc=$?
assert_eq test_non_iata_colo_dropped "$(cat "$d/out.txt")" '5.5.5.5#优选HKG-55.00m'
assert_eq test_non_iata_colo_dropped_exit_code "$rc" "0"

# ---------------------------------------------------------------------------
# 空结果守卫：0 字节 -> 警告 + 退出 0，绝不发请求
# （用一个拒绝连接的 api_base，若真发了请求就不可能还是 0）
d=$(newdir pushempty)
: >"$d/empty.txt"
rc=0
push "$d/empty.txt" dummy 1 http://127.0.0.1:1 || rc=$?
assert_eq test_push_skips_when_empty_exit_code "$rc" "0"
assert_contains test_push_skips_when_empty_warns "$(cat "$TMP/err")" "结果为空"

# ---------------------------------------------------------------------------
# API 不可达：记日志 + 返回失败（绝不静默、绝不崩）
d=$(newdir pushfail)
printf '1.1.1.1#优选HKG-45.12m\n' >"$d/x.txt"
rc=0
push "$d/x.txt" dummy 0 http://127.0.0.1:1 || rc=$?
assert_eq test_push_reports_error_on_unreachable_api "$rc" "1"
assert_contains test_push_reports_error_on_unreachable_api_log "$(cat "$TMP/err")" "发布失败"

# ---------------------------------------------------------------------------
# dry-run：地址不可达却退出 0，证明根本没发请求；同时要把将要提交的 JSON 打出来
d=$(newdir dryrun)
printf '1.1.1.1#优选HKG-45.12m\n' >"$d/x.txt"
rc=0
push "$d/x.txt" dummy 1 http://127.0.0.1:1 || rc=$?
assert_eq test_dry_run_exit_code "$rc" "0"
assert_contains test_dry_run_prints_branch "$(cat "$TMP/out")" '"branch":"master"'
assert_contains test_dry_run_prints_content "$(cat "$TMP/out")" '"content":"'

# ---------------------------------------------------------------------------
# entrypoint：单次运行，假 cfst 按 -o 写 CSV，entrypoint 负责转换出 txt
# fixture 内联在本用例里（不跨任务共享），含一个不在 REGIONS 里的地区
d=$(newdir ep)
mkdir -p "$d"
cat >"$TMP/fake-cfst-ok" <<'FAKEEOF'
#!/bin/sh
# 模拟 cfst：解析 -o，把结果写到那里。若调用方没传 -o，就落到当前目录（用例会失败）。
out="result.csv"
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
    esac
done
{
    printf 'IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码\n'
    printf '1.1.1.1,4,4,0.00,45.12,10.00,HKG\n'
    printf '2.2.2.2,4,4,0.00,52.30,10.00,NRT\n'
    printf '3.3.3.3,4,4,0.00,33.10,10.00,AMS\n'
} >"$out"
FAKEEOF
chmod +x "$TMP/fake-cfst-ok"
rc=0
entrypoint_run "$d" "$TMP/fake-cfst-ok" "" "1" || rc=$?
assert_eq test_entrypoint_single_run_exit_code "$rc" "0"
expected='1.1.1.1#优选HKG-45.12m
2.2.2.2#优选NRT-52.30m'
assert_eq test_entrypoint_single_run_produces_txt "$(cat "$d/result.txt" 2>/dev/null)" "$expected"

# ---------------------------------------------------------------------------
# entrypoint：cfst 失败时，必须先把上一轮的旧 csv/txt 清掉，且绝不用旧数据发布
d=$(newdir epstale)
mkdir -p "$d"
printf '旧csv数据\n' >"$d/result.csv"
printf '旧txt结果\n' >"$d/result.txt"
cat >"$TMP/fake-cfst-fail" <<'FAKEEOF'
#!/bin/sh
# 留个痕迹，证明 entrypoint 真的把 cfst 跑起来了（否则下面的退出码断言会因为
# 「shell 在别处失败」而碰巧变绿，那样的绿没有任何信息量）
: >"${DATA_DIR:-.}/fake-cfst-ran"
exit 1
FAKEEOF
chmod +x "$TMP/fake-cfst-fail"
rc=0
entrypoint_run "$d" "$TMP/fake-cfst-fail" "" "1" || rc=$?
assert_eq test_stale_csv_cleaned_fake_cfst_invoked \
    "$([ -e "$d/fake-cfst-ran" ] && echo 跑了 || echo 没跑)" "跑了"
assert_eq test_stale_csv_cleaned_exit_code "$rc" "1"
assert_eq test_stale_csv_cleaned_csv \
    "$([ -e "$d/result.csv" ] && echo 还在 || echo 已清理)" "已清理"
assert_eq test_stale_csv_cleaned_txt \
    "$([ -e "$d/result.txt" ] && echo 还在 || echo 已清理)" "已清理"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
