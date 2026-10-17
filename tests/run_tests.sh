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
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
