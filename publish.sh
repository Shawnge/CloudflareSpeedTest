#!/bin/sh
# 把 cfst 的 result.csv 转成 edgetunnel 能直接吃的优选 IP 文本，并发布到 GitHub 仓库。
#
#   publish.sh convert <csv> <out.txt>    只做转换，不联网
#   publish.sh push    <txt>              只做发布
#   publish.sh all     <csv> <out.txt>    先转换再发布（结果为空则跳过发布）
#
# 环境变量（默认值见下）：
#   REGIONS          保留的地区码，逗号分隔，顺序即输出顺序
#   TOP_N            每个地区保留延迟最低的条数
set -eu

: "${REGIONS:=HKG,NRT,SIN,SJC,LAX}"
: "${TOP_N:=8}"

TAB=$(printf '\t')

# convert <csv> <out.txt>
#
# 三件必须做对的事（改动前先读 tests/run_tests.sh）：
#   1. 每条记录先剥掉行尾 \r，否则从 Windows 拿到的 CSV 地区码会是 "HKG\r"，匹配不上任何地区
#   2. 只做「逗号分隔 + 按列取值」，不做完整 CSV 解析 —— IP/地区码/数字都不含逗号或引号
#   3. sort 用 -g（数值比较）；-t 必须传真实 TAB 字符，busybox sort 不认字面量 \t
convert() {
    csv=$1
    out=$2

    LC_ALL=C awk -F, -v R="$REGIONS" '
        BEGIN { n = split(R, r, ","); for (i = 1; i <= n; i++) allow[r[i]] = 1 }
        {
            sub(/\r$/, "")
            if (FNR == 1) next
            if ($7 == "" || $7 == "N/A") next
            if (!($7 in allow)) next
            printf "%s\t%s\t%s\n", $7, $5, $1
        }
    ' "$csv" \
        | LC_ALL=C sort -t"$TAB" -k1,1 -k2,2g \
        | LC_ALL=C awk -F"$TAB" -v R="$REGIONS" -v N="$TOP_N" '
            BEGIN { n = split(R, order, ",") }
            { c[$1]++; if (c[$1] <= N) buf[$1] = buf[$1] $0 "\n" }
            END { for (i = 1; i <= n; i++) printf "%s", buf[order[i]] }
        ' \
        | LC_ALL=C awk -F"$TAB" '{ printf "%s#优选%s-%sm\n", $3, $1, $2 }' \
        >"$out"

    if [ ! -s "$out" ]; then
        echo "[publish] WARN 转换结果为空（没有匹配的地区，或地区码全是 N/A）" >&2
    fi
}

case "${1:-}" in
convert)
    [ $# -eq 3 ] || {
        echo "用法: publish.sh convert <csv> <out.txt>" >&2
        exit 2
    }
    convert "$2" "$3"
    ;;
*)
    echo "用法: publish.sh {convert|push|all} ..." >&2
    exit 2
    ;;
esac
