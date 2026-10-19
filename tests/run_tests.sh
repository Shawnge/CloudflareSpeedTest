#!/bin/sh
# publish.sh 的测试。POSIX sh，在 macOS 与 alpine:3.19（busybox）上均可运行。
# 用法：sh tests/run_tests.sh
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
# 后台假服务器若还活着也要收掉，否则用例失败时会留下孤儿进程占着端口
cleanup() {
    [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
    [ -n "${CRON_CONTAINER:-}" ] && docker rm -fv "$CRON_CONTAINER" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
SKIPPED=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s — %s\n' "$1" "$2"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf 'SKIP %s — %s\n' "$1" "$2"; }
have_docker() { command -v docker >/dev/null 2>&1; }
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
assert_not_contains() { # <name> <haystack> <needle>
    case "$2" in
    *"$3"*) bad "$1" "不应包含 [$3]，实际: [$(printf '%s' "$2")]" ;;
    *) ok "$1" ;;
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

have_python() { command -v python3 >/dev/null 2>&1; }

# 起一个假的 GitHub Contents API（只实现 publish.sh 用到的那两条路由），
# 用来真实走通「创建」与「已存在→带 sha 更新」两条路径 —— 后者是上线后每天都会走的路径，
# 也是唯一能复现「变量紧跟非 ASCII 字符」在 bash 3.2 下崩掉的地方。
# <mode: create|update>；端口 -> $TMP/mock_port，收到的 PUT body -> $TMP/mock_put.json
mock_gh_start() {
    rm -f "$TMP/mock_port" "$TMP/mock_put.json"
    cat >"$TMP/mock_gh.py" <<'PYEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

mode, portfile, putfile = sys.argv[1], sys.argv[2], sys.argv[3]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if mode == "update":
            self._send(200, {"sha": "deadbeefcafe0000"})
        else:
            self._send(404, {"message": "Not Found"})

    def do_PUT(self):
        n = int(self.headers.get("Content-Length", 0))
        with open(putfile, "wb") as f:
            f.write(self.rfile.read(n))
        self._send(201, {"commit": {"sha": "cafebabe0000"}})


srv = HTTPServer(("127.0.0.1", 0), H)
with open(portfile, "w") as f:
    f.write(str(srv.server_port))
srv.serve_forever()
PYEOF
    python3 "$TMP/mock_gh.py" "$1" "$TMP/mock_port" "$TMP/mock_put.json" &
    MOCK_PID=$!
    i=0
    while [ ! -s "$TMP/mock_port" ] && [ "$i" -lt 40 ]; do
        sleep 0.25
        i=$((i + 1))
    done
}

mock_gh_stop() {
    [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
    wait "${MOCK_PID:-}" 2>/dev/null
    MOCK_PID=
}

# 运行 entrypoint.sh。显式清空 GITHUB_TOKEN，保证这些用例不联网、不发布。
# <data_dir> <cfst_bin> <cron_schedule> <run_on_start> <cfst_url> [额外参数...]
entrypoint_run() {
    d=$1
    b=$2
    c=$3
    r=$4
    u=$5
    shift 5
    entrypoint_run_cfst_env "$d" "$b" "$c" "$r" "$u" "" "" "" "$@"
}

# 同上，但显式给出 CFST_TL/CFST_DN/CFST_SL。
# 用参数而不是 `CFST_TL=150 entrypoint_run ...` 前缀：POSIX 对「函数调用前缀赋值」
# 是否持久规定不一（bash 会留下、dash/ash 会还原），会串味到后续用例。
# <data_dir> <cfst_bin> <cron_schedule> <run_on_start> <cfst_url> <CFST_TL> <CFST_DN> <CFST_SL> [额外参数...]
entrypoint_run_cfst_env() {
    d=$1
    b=$2
    c=$3
    r=$4
    u=$5
    tl=$6
    dn=$7
    sl=$8
    shift 8
    env DATA_DIR="$d" \
        CFST_BIN="$b" \
        PUBLISH_SH="$REPO/publish.sh" \
        CRON_SCHEDULE="$c" \
        RUN_ON_START="$r" \
        CFST_URL="$u" \
        CFST_TL="$tl" \
        CFST_DN="$dn" \
        CFST_SL="$sl" \
        CFST_ARGS= \
        REGIONS=HKG,NRT,SIN,SJC,LAX \
        TOP_N=8 \
        GITHUB_TOKEN= \
        sh "$REPO/entrypoint.sh" "$@" >"$TMP/ep_out" 2>"$TMP/ep_err"
}

# 假 cfst：把收到的参数原样记到 $DATA_DIR/cfst-args.txt，并写一份最小 CSV
make_args_recording_cfst() {
    cat >"$TMP/fake-cfst-args" <<'FAKEEOF'
#!/bin/sh
# 必须在解析之前记录：下面的 while/shift 会把位置参数吃光，之后再 $* 就是空的了
printf '%s\n' "$*" >"${DATA_DIR:-.}/cfst-args.txt"
out=result.csv
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
    esac
done
{
    printf 'IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码\n'
    printf '1.1.1.1,4,4,0.00,45.12,10.00,HKG\n'
} >"$out"
FAKEEOF
    chmod +x "$TMP/fake-cfst-args"
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
# CSV 文件不存在：cfst 在「结果为空」时**根本不创建** result.csv（真实会发生的路径）。
# 必须给出一句能对上号的警告，而不是让 awk 的报错被管道冲掉、只剩「转换结果为空」。
d=$(newdir csvmissing)
rc=0
convert "$d/nope.csv" "$d/out.txt" || rc=$?
assert_eq test_convert_missing_csv_exit_code "$rc" "0"
assert_contains test_convert_missing_csv_warns "$(cat "$TMP/err")" "读不到 CSV"
assert_eq test_convert_missing_csv_output_empty \
    "$([ -s "$d/out.txt" ] && echo nonempty || echo empty)" "empty"

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
# 源码卫生：变量名不许紧跟非 ASCII 字节（例如 「（sha=$sha）」）。
# bash 3.2（macOS 的 /bin/sh）会把随后的全角字符当成变量名的一部分，在 set -u 下
# 报 unbound variable 并中止整个脚本；busybox ash 与 dash 不会，所以这个坑只在
# 「脱离容器直接跑 publish.sh」（spec §6 明确支持的调试方式）时才现形。
assert_eq test_no_variable_adjacent_to_non_ascii \
    "$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$REPO/publish.sh" "$REPO/entrypoint.sh" 2>/dev/null | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
# push 的两条成功路径（用假 API，真发 HTTP）
if have_python; then
    # 创建：远端 404 -> 不带 sha 的 PUT
    d=$(newdir pushcreate)
    printf '1.1.1.1#优选HKG-45.12m\n' >"$d/x.txt"
    mock_gh_start create
    rc=0
    push "$d/x.txt" tok 0 "http://127.0.0.1:$(cat "$TMP/mock_port")" || rc=$?
    mock_gh_stop
    assert_eq test_push_create_exit_code "$rc" "0"
    assert_contains test_push_create_announces_new "$(cat "$TMP/out")" "目标不存在，将新建"
    assert_contains test_push_create_confirms "$(cat "$TMP/out")" "已发布到"
    assert_eq test_push_create_payload_has_no_sha \
        "$(jq -r 'has("sha")' "$TMP/mock_put.json" 2>/dev/null)" "false"
    assert_eq test_push_create_payload_branch \
        "$(jq -r '.branch' "$TMP/mock_put.json" 2>/dev/null)" "master"

    # 更新：远端 200 带 sha -> PUT 必须原样带上该 sha，且内容要能解回
    d=$(newdir pushupdate)
    printf '2.2.2.2#优选NRT-52.30m\n' >"$d/x.txt"
    mock_gh_start update
    rc=0
    push "$d/x.txt" tok 0 "http://127.0.0.1:$(cat "$TMP/mock_port")" || rc=$?
    mock_gh_stop
    assert_eq test_push_update_exit_code "$rc" "0"
    assert_contains test_push_update_announces_sha \
        "$(cat "$TMP/out")" "目标已存在，将覆盖更新（sha=deadbeefcafe0000）"
    assert_eq test_push_update_payload_sha \
        "$(jq -r '.sha' "$TMP/mock_put.json" 2>/dev/null)" "deadbeefcafe0000"
    assert_eq test_push_update_content_roundtrip \
        "$(jq -r '.content' "$TMP/mock_put.json" 2>/dev/null | base64 -d 2>/dev/null)" "2.2.2.2#优选NRT-52.30m"
else
    skip test_push_create_exit_code "本机没有 python3"
    skip test_push_update_exit_code "本机没有 python3"
fi

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
entrypoint_run "$d" "$TMP/fake-cfst-ok" "" "1" "" || rc=$?
assert_eq test_entrypoint_single_run_exit_code "$rc" "0"
expected='1.1.1.1#优选HKG-45.12m
2.2.2.2#优选NRT-52.30m'
assert_eq test_entrypoint_single_run_produces_txt "$(cat "$d/result.txt" 2>/dev/null)" "$expected"

# REGIONS 必须在测速阶段生效，不能只从全区测速的前几个结果里过滤。
d=$(newdir epregions)
make_args_recording_cfst
rc=0
env DATA_DIR="$d" CFST_BIN="$TMP/fake-cfst-args" PUBLISH_SH="$REPO/publish.sh" \
    CRON_SCHEDULE= CFST_ARGS= GITHUB_TOKEN= REGIONS=' nrt , sin ' TOP_N=3 \
    sh "$REPO/entrypoint.sh" >"$TMP/ep_out" 2>"$TMP/ep_err" || rc=$?
assert_eq test_regions_exit_code "$rc" "0"
args=$(cat "$d/cfst-args.txt" 2>/dev/null)
assert_contains test_regions_enable_httping "$args" "-httping"
assert_contains test_regions_filter_before_download "$args" "-cfcolo NRT,SIN"
assert_contains test_regions_use_independent_quota "$args" "-dn-per-colo 3"

rc=0
env DATA_DIR="$d" CFST_BIN="$TMP/fake-cfst-args" PUBLISH_SH="$REPO/publish.sh" \
    CRON_SCHEDULE= CFST_ARGS= GITHUB_TOKEN= REGIONS=NRT,SIN \
    sh "$REPO/entrypoint.sh" -httping -cfcolo=NRT >"$TMP/ep_out" 2>"$TMP/ep_err" || rc=$?
args=$(cat "$d/cfst-args.txt" 2>/dev/null)
assert_eq test_regions_explicit_override_exit_code "$rc" "0"
assert_contains test_regions_explicit_override "$args" "-cfcolo=NRT"
assert_not_contains test_regions_explicit_not_duplicated "$args" "-cfcolo NRT,SIN"
assert_contains test_regions_explicit_override_warns "$(cat "$TMP/ep_err")" "REGIONS"

# 未设置 CRON_SCHEDULE 应进入默认定时模式，并执行 token 校验。
rc=0
env -u CRON_SCHEDULE RUN_ON_START=0 GITHUB_TOKEN= \
    sh "$REPO/entrypoint.sh" >"$TMP/ep_out" 2>"$TMP/ep_err" || rc=$?
assert_eq test_unset_cron_exit_code "$rc" "1"
assert_contains test_unset_cron_uses_scheduled_mode "$(cat "$TMP/ep_err")" "GITHUB_TOKEN"
assert_not_contains test_unset_cron_has_no_unbound_variable "$(cat "$TMP/ep_err")" "unbound variable"

# compose 的显式空值必须保留，否则 CFST_SL= 仍会加上速度门槛。
if have_docker; then
    limits=$(env CFST_TL= CFST_DN= CFST_SL= docker compose -f "$REPO/docker-compose.yml" \
        config --format json | jq -r '.services.cfst.environment | [.CFST_TL, .CFST_DN, .CFST_SL] | join("|")')
    assert_eq test_compose_preserves_empty_limits "$limits" "||"
fi

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
entrypoint_run "$d" "$TMP/fake-cfst-fail" "" "1" "" || rc=$?
assert_eq test_stale_csv_cleaned_fake_cfst_invoked \
    "$([ -e "$d/fake-cfst-ran" ] && echo 跑了 || echo 没跑)" "跑了"
assert_eq test_stale_csv_cleaned_exit_code "$rc" "1"
assert_eq test_stale_csv_cleaned_csv \
    "$([ -e "$d/result.csv" ] && echo 还在 || echo 已清理)" "已清理"
assert_eq test_stale_csv_cleaned_txt \
    "$([ -e "$d/result.txt" ] && echo 还在 || echo 已清理)" "已清理"

# ---------------------------------------------------------------------------
# CFST_URL：非空时必须作为 -url 传给 cfst（这是绕开 cf.xiu2.xyz 403 的正规开关）
d=$(newdir epurl)
mkdir -p "$d"
make_args_recording_cfst
rc=0
entrypoint_run "$d" "$TMP/fake-cfst-args" "" "1" "https://example.test/probe?bytes=1000" || rc=$?
assert_eq test_entrypoint_passes_url_exit_code "$rc" "0"
assert_contains test_entrypoint_passes_url \
    "$(cat "$d/cfst-args.txt" 2>/dev/null)" "-url https://example.test/probe?bytes=1000"

# ---------------------------------------------------------------------------
# 命令行已显式给了 -url 时，CFST_URL 不得再追加一个（两个 -url 会让 cfst 静默取后者）
d=$(newdir epurl2)
mkdir -p "$d"
make_args_recording_cfst
rc=0
entrypoint_run "$d" "$TMP/fake-cfst-args" "" "1" "https://should.not.win/probe" \
    -url "https://explicit.win/probe" || rc=$?
assert_eq test_entrypoint_url_not_duplicated \
    "$(grep -o -- '-url' "$d/cfst-args.txt" 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_contains test_entrypoint_url_explicit_wins \
    "$(cat "$d/cfst-args.txt" 2>/dev/null)" "-url https://explicit.win/probe"

# ---------------------------------------------------------------------------
# CFST_TL / CFST_DN / CFST_SL：三个测速阈值可由环境变量注入，等价于 -tl/-dn/-sl
d=$(newdir cfstenv)
mkdir -p "$d"
make_args_recording_cfst
rc=0
entrypoint_run_cfst_env "$d" "$TMP/fake-cfst-args" "" "1" "" "150" "30" "5" || rc=$?
args=$(cat "$d/cfst-args.txt" 2>/dev/null)
assert_eq test_cfst_env_exit_code "$rc" "0"
assert_contains test_cfst_tl_env_passed "$args" "-tl 150"
assert_contains test_cfst_dn_env_passed "$args" "-dn 30"
assert_contains test_cfst_sl_env_passed "$args" "-sl 5"

# ---------------------------------------------------------------------------
# 留空 = 完全不传该参数。CFST_SL 默认就该是空的：本方案按延迟筛选，不需要速度门槛，
# 而 -sl 高于实际带宽时 cfst 会输出 0 条结果、连 result.csv 都不创建。
d=$(newdir cfstenvempty)
mkdir -p "$d"
make_args_recording_cfst
rc=0
entrypoint_run_cfst_env "$d" "$TMP/fake-cfst-args" "" "1" "" "" "" "" || rc=$?
args=$(cat "$d/cfst-args.txt" 2>/dev/null)
assert_eq test_cfst_env_empty_exit_code "$rc" "0"
assert_not_contains test_cfst_tl_empty_not_passed "$args" "-tl"
assert_not_contains test_cfst_dn_empty_not_passed " $args " " -dn "
assert_not_contains test_cfst_sl_empty_not_passed "$args" "-sl"

# ---------------------------------------------------------------------------
# 环境变量与命令行撞车：以命令行为准（沿用 CFST_URL 的既有约定，保住
# `docker compose run --rm cfst -tl 500` 这种一次性试参数的用法），但必须告警，
# 否则在 .env 里改了值却不生效，会变成无声的困惑。
d=$(newdir cfstenvwin)
mkdir -p "$d"
make_args_recording_cfst
rc=0
entrypoint_run_cfst_env "$d" "$TMP/fake-cfst-args" "" "1" "" "150" "30" "5" -tl 300 || rc=$?
args=$(cat "$d/cfst-args.txt" 2>/dev/null)
assert_eq test_cfst_env_command_line_wins_exit_code "$rc" "0"
assert_contains test_cfst_env_command_line_wins "$args" "-tl 300"
assert_not_contains test_cfst_env_command_line_env_not_applied "$args" "-tl 150"
assert_contains test_cfst_env_command_line_wins_warns "$(cat "$TMP/ep_err")" "WARN"
assert_contains test_cfst_env_command_line_wins_warns_name "$(cat "$TMP/ep_err")" "CFST_TL"

# 使用镜像内真实的 BusyBox crond，验证自定义表达式、首次定时执行和地区透传。
test_scheduled_run() {
    d=$(newdir epcron)
    cat >"$d/fake-cfst" <<'FAKEEOF'
#!/bin/sh
printf '%s\n' "$*" >"$DATA_DIR/cfst-args.txt"
printf 'IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码\n' >"$DATA_DIR/result.csv"
printf '1.1.1.1,4,4,0.00,10.00,30.00,HKG\n2.2.2.2,4,4,0.00,20.00,30.00,NRT\n3.3.3.3,4,4,0.00,30.00,30.00,SIN\n' >>"$DATA_DIR/result.csv"
FAKEEOF
    chmod +x "$d/fake-cfst"
    CRON_CONTAINER="cfst-cron-test-$$"
    rc=0
    docker run -d --name "$CRON_CONTAINER" \
        -v "$d:/fixtures:ro" -e DATA_DIR=/scheduled/results \
        -e CFST_BIN=/fixtures/fake-cfst -e PUBLISH_SH=/opt/cfst/publish.sh \
        -e RUN_ON_START=0 -e GITHUB_TOKEN=test-token -e PUBLISH_DRY_RUN=1 \
        -e REGIONS=NRT,SIN -e TOP_N=1 -e TZ=Asia/Shanghai \
        cfst:test >"$TMP/cron-start" 2>"$TMP/cron-err" || rc=$?
    assert_eq test_cron_container_starts "$rc" "0"
    [ "$rc" -eq 0 ] || return
    sleep 1
    line=$(docker exec "$CRON_CONTAINER" crontab -l 2>/dev/null)
    assert_contains test_cron_default_schedule "$line" "0 4 * * * "
    assert_eq test_cron_creates_output_dir \
        "$(docker exec "$CRON_CONTAINER" sh -c 'test -d /scheduled/results && echo yes')" "yes"
    assert_eq test_cron_run_on_start_disabled \
        "$(docker exec "$CRON_CONTAINER" sh -c 'test ! -e /scheduled/results/cfst-args.txt && echo yes')" "yes"
    docker rm -fv "$CRON_CONTAINER" >/dev/null 2>&1

    docker run -d --name "$CRON_CONTAINER" \
        -v "$d:/fixtures:ro" -e DATA_DIR=/scheduled/results \
        -e CFST_BIN=/fixtures/fake-cfst -e PUBLISH_SH=/opt/cfst/publish.sh \
        -e 'CRON_SCHEDULE=* * * * *' -e RUN_ON_START=0 \
        -e GITHUB_TOKEN=test-token -e PUBLISH_DRY_RUN=1 \
        -e REGIONS=NRT,SIN -e TOP_N=1 -e TZ=Asia/Shanghai \
        cfst:test >"$TMP/cron-start" 2>"$TMP/cron-err"
    sleep 1
    line=$(docker exec "$CRON_CONTAINER" crontab -l 2>/dev/null)
    assert_contains test_cron_custom_schedule "$line" "* * * * * "
    rc=0
    docker exec "$CRON_CONTAINER" sh -c '
        i=0
        until [ -s /scheduled/results/result.txt ]; do
            i=$((i + 1))
            [ "$i" -lt 70 ] || exit 1
            sleep 1
        done' || rc=$?
    assert_eq test_cron_really_executes "$rc" "0"
    args=$(docker exec "$CRON_CONTAINER" cat /scheduled/results/cfst-args.txt 2>/dev/null)
    assert_contains test_cron_passes_regions "$args" "-cfcolo NRT,SIN"
    assert_contains test_cron_enables_httping "$args" "-httping"
    assert_contains test_cron_passes_per_region_quota "$args" "-dn-per-colo 1"
    expected='2.2.2.2#优选NRT-20.00m
3.3.3.3#优选SIN-30.00m'
    assert_eq test_cron_publishes_only_regions \
        "$(docker exec "$CRON_CONTAINER" cat /scheduled/results/result.txt 2>/dev/null)" "$expected"
    assert_contains test_cron_dry_run_publish \
        "$(docker exec "$CRON_CONTAINER" cat /scheduled/results/cfst.log 2>/dev/null)" "DRY-RUN"
    docker rm -fv "$CRON_CONTAINER" >/dev/null 2>&1
    CRON_CONTAINER=
}

# ---------------------------------------------------------------------------
# 镜像：运行阶段必须带 curl / jq / crond，且有可执行的 publish.sh
# 用 --entrypoint sh 覆盖镜像的 ENTRYPOINT，否则命令会被 entrypoint.sh 吃掉
if have_docker; then
    if docker build -q -t cfst:test . >"$TMP/build.log" 2>&1; then
        rc=0
        docker run --rm --entrypoint sh cfst:test \
            -c 'command -v curl && command -v jq && command -v crond && test -x /opt/cfst/publish.sh' \
            >"$TMP/it.log" 2>&1 || rc=$?
        assert_eq test_image_has_runtime_deps "$rc" "0"
        test_scheduled_run
    else
        bad test_image_has_runtime_deps "镜像构建失败: $(tail -3 "$TMP/build.log" | tr '\n' ' ')"
    fi
else
    skip test_image_has_runtime_deps "本机没有 docker"
fi

# ---------------------------------------------------------------------------
# 构建阶段必须看不到 .env（.dockerignore 真的挡住了 token，不进构建层与缓存）
if have_docker; then
    created_env=0
    if [ ! -e "$REPO/.env" ]; then
        touch "$REPO/.env" # 造一个假的，确保测的是忽略规则而不是「文件本来就没有」
        created_env=1
    fi
    if docker build -q --target builder -t cfst-builder:test . >"$TMP/build2.log" 2>&1; then
        rc=0
        docker run --rm --entrypoint sh cfst-builder:test -c 'test ! -e /app/.env' >/dev/null 2>&1 || rc=$?
        assert_eq test_builder_stage_has_no_env_file "$rc" "0"
        rc=0
        docker run --rm --entrypoint go cfst-builder:test test ./... >"$TMP/go-test.log" 2>&1 || rc=$?
        if [ "$rc" -eq 0 ]; then
            ok test_go_download_quotas
        else
            bad test_go_download_quotas "$(tail -15 "$TMP/go-test.log")"
        fi
    else
        bad test_builder_stage_has_no_env_file "构建阶段镜像失败: $(tail -3 "$TMP/build2.log" | tr '\n' ' ')"
    fi
    [ "$created_env" -eq 1 ] && rm -f "$REPO/.env"
else
    skip test_builder_stage_has_no_env_file "本机没有 docker"
    skip test_go_download_quotas "本机没有 docker"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIPPED"
[ "$FAIL" -eq 0 ]
