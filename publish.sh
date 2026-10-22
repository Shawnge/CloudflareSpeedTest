#!/bin/sh
# 把 cfst 的 result.csv 转成 edgetunnel 能直接吃的优选 IP 文本，并发布到 GitHub 仓库。
#
#   publish.sh convert <csv> <out.txt>    只做转换，不联网
#   publish.sh push    <txt>              只做发布
#   publish.sh all     <csv> <out.txt>    先转换再发布（结果为空则跳过发布）
#
# 环境变量（默认值见下）：
#   REGIONS          保留的地区码，逗号分隔，顺序即输出顺序；
#                    条数由 cfst 的 -dn 控制，这里不再截断
#   GITHUB_TOKEN     发布用的 token（为空则只测速不发布）
#   GITHUB_REPO      目标仓库 owner/repo
#   GITHUB_BRANCH    目标分支
#   RESULT_PATH      结果文件在仓库内的路径
#   GITHUB_API_BASE  API 根地址（仅测试用，指向假地址即可离线验证失败路径）
#   PUBLISH_DRY_RUN  1 = 只打印将要提交的内容，不发任何请求（仅测试用）
#
# 安全：token 只经 Authorization 请求头传递，绝不打印、绝不写入文件、绝不进命令行参数。
set -eu

: "${REGIONS:=HKG,NRT,SIN,SJC,LAX}"
: "${GITHUB_TOKEN:=}"
: "${GITHUB_REPO:=Shawnge/CloudflareSpeedTest}"
: "${GITHUB_BRANCH:=master}"
: "${RESULT_PATH:=result/result.txt}"
: "${GITHUB_API_BASE:=https://api.github.com}"
: "${PUBLISH_DRY_RUN:=0}"

TAB=$(printf '\t')
CURL_TIMEOUTS='--connect-timeout 10 --max-time 60'

usage() {
    echo "用法: publish.sh $1" >&2
    exit 2
}

fail() {
    echo "[publish] 发布失败: $1" >&2
    return 1
}

# 机场三字码 -> 国家/地区旗帜。未列出的地区不加 emoji。
region_flag() {
    case "$1" in
    HKG) printf '🇭🇰' ;;
    NRT|HND|KIX|ITM|NGO|FUK|CTS|OKA) printf '🇯🇵' ;;
    SIN) printf '🇸🇬' ;;
    SJC|LAX|SFO|SEA|PDX|DEN|DFW|ORD|ATL|MIA|IAD|EWR|JFK|BOS|PHX|LAS|MSP|DTW|PHL|CLT|AUS|SAN|SLC|HNL|ANC) printf '🇺🇸' ;;
    YYZ|YVR|YUL|YYC|YOW) printf '🇨🇦' ;;
    MEX) printf '🇲🇽' ;;
    GRU|GIG) printf '🇧🇷' ;;
    EZE) printf '🇦🇷' ;;
    SCL) printf '🇨🇱' ;;
    BOG) printf '🇨🇴' ;;
    LIM) printf '🇵🇪' ;;
    LHR|LGW|MAN|EDI) printf '🇬🇧' ;;
    CDG|MRS) printf '🇫🇷' ;;
    FRA|MUC|BER|DUS) printf '🇩🇪' ;;
    AMS) printf '🇳🇱' ;;
    BRU) printf '🇧🇪' ;;
    ZRH|GVA) printf '🇨🇭' ;;
    VIE) printf '🇦🇹' ;;
    FCO|MXP) printf '🇮🇹' ;;
    MAD|BCN) printf '🇪🇸' ;;
    LIS) printf '🇵🇹' ;;
    DUB) printf '🇮🇪' ;;
    CPH) printf '🇩🇰' ;;
    ARN) printf '🇸🇪' ;;
    OSL) printf '🇳🇴' ;;
    HEL) printf '🇫🇮' ;;
    WAW) printf '🇵🇱' ;;
    PRG) printf '🇨🇿' ;;
    OTP) printf '🇷🇴' ;;
    ATH) printf '🇬🇷' ;;
    IST) printf '🇹🇷' ;;
    DME|SVO|LED) printf '🇷🇺' ;;
    KBP) printf '🇺🇦' ;;
    TLV) printf '🇮🇱' ;;
    DXB|AUH) printf '🇦🇪' ;;
    RUH|JED) printf '🇸🇦' ;;
    DOH) printf '🇶🇦' ;;
    KWI) printf '🇰🇼' ;;
    BOM|DEL|BLR|MAA|HYD) printf '🇮🇳' ;;
    KHI) printf '🇵🇰' ;;
    DAC) printf '🇧🇩' ;;
    CMB) printf '🇱🇰' ;;
    PEK|PVG|CAN|SZX|CTU|CKG|WUH|XIY|HGH|NKG|TAO|TSN|CSX|KMG|XMN) printf '🇨🇳' ;;
    MFM) printf '🇲🇴' ;;
    TPE|KHH) printf '🇹🇼' ;;
    ICN|GMP|PUS) printf '🇰🇷' ;;
    KUL) printf '🇲🇾' ;;
    BKK|DMK) printf '🇹🇭' ;;
    SGN|HAN) printf '🇻🇳' ;;
    PNH) printf '🇰🇭' ;;
    MNL|CEB) printf '🇵🇭' ;;
    CGK|DPS) printf '🇮🇩' ;;
    SYD|MEL|BNE|PER|ADL) printf '🇦🇺' ;;
    AKL|CHC) printf '🇳🇿' ;;
    JNB|CPT) printf '🇿🇦' ;;
    CAI) printf '🇪🇬' ;;
    CMN) printf '🇲🇦' ;;
    LOS) printf '🇳🇬' ;;
    NBO) printf '🇰🇪' ;;
    ADD) printf '🇪🇹' ;;
    MRU) printf '🇲🇺' ;;
    RUN) printf '🇷🇪' ;;
    MLE) printf '🇲🇻' ;;
    *) return 0 ;;
    esac
}

# convert <csv> <out.txt>
#
# 三件必须做对的事（改动前先读 tests/run_tests.sh）：
#   1. 每条记录先剥掉行尾 \r，否则从 Windows 拿到的 CSV 地区码会是 "HKG\r"，匹配不上任何地区
#   2. 只做「逗号分隔 + 按列取值」，不做完整 CSV 解析 —— IP/地区码/数字都不含逗号或引号
#   3. sort 用 -g（数值比较）；-t 必须传真实 TAB 字符，busybox sort 不认字面量 \t
convert() {
    csv=$1
    out=$2

    # 显式报「读不到 CSV」，否则 awk 的报错会被后面 sort/awk 管道冲掉，
    # 最终只看到一句「转换结果为空」。而 cfst 在结果为空时**根本不创建** result.csv，
    # 所以这条是真实会发生的路径，不是理论情况。
    if [ ! -r "$csv" ]; then
        echo "[publish] WARN 读不到 CSV（${csv}）——cfst 在结果为空时不会创建该文件" >&2
        : >"$out"
        return 0
    fi

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
        | LC_ALL=C sort -t"$TAB" -k2,2g \
        | LC_ALL=C awk -F"$TAB" -v R="$REGIONS" '
            BEGIN { n = split(R, order, ",") }
            { buf[$1] = buf[$1] $0 "\n" }
            END { for (i = 1; i <= n; i++) printf "%s", buf[order[i]] }
        ' \
        | while IFS="$TAB" read -r region delay ip; do
            flag=$(region_flag "$region")
            if [ -n "$flag" ]; then
                printf '%s %s#优选%s-%sms\n' "$flag" "$ip" "$region" "$delay"
            else
                printf '%s#优选%s-%sms\n' "$ip" "$region" "$delay"
            fi
        done >"$out"

    if [ ! -s "$out" ]; then
        echo "[publish] WARN 转换结果为空（没有匹配的地区，或地区码全是 N/A）" >&2
    fi
}

# 组装 Contents API 的 body。<sha> 为空表示「新建文件」。
# content 必须是 base64；base64 的输出在 BSD 上会折行，故一律 tr 掉换行。
build_payload() { # <txt> <sha 或空>
    base=$(jq -c -n \
        --arg m "chore: update result.txt ($(date '+%F %T'))" \
        --arg c "$(base64 <"$1" | tr -d '\n')" \
        --arg b "$GITHUB_BRANCH" \
        '{message: $m, content: $c, branch: $b}')
    if [ -n "$2" ]; then
        printf '%s' "$base" | jq -c --arg s "$2" '. + {sha: $s}'
    else
        printf '%s' "$base"
    fi
}

# 拆出 curl 的响应：最后一行是 http_code，其余是 body
resp_code() { printf '%s' "$1" | tail -n1; }
resp_body() { printf '%s' "$1" | sed '$d'; }

# 读取现有文件的 blob sha。输出空串表示文件还不存在（走创建）。
fetch_sha() {
    resp=$(curl -sS $CURL_TIMEOUTS -w '\n%{http_code}' \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "$url?ref=$GITHUB_BRANCH" 2>/dev/null || true)
    code=$(resp_code "$resp")
    body=$(resp_body "$resp")
    case "$code" in
    200) printf '%s' "$body" | jq -r '.sha // empty' ;;
    404) : ;;
    000 | '') fail "无法连接 $GITHUB_API_BASE" ;;
    *) fail "读取现有文件失败: HTTP $code $(printf '%.500s' "$body")" ;;
    esac
}

# push <txt>
push() {
    txt=$1
    url="$GITHUB_API_BASE/repos/$GITHUB_REPO/contents/$RESULT_PATH"

    # 守卫 1：结果为空 -> 绝不推送，保住远端上一版的好结果
    if [ ! -s "$txt" ]; then
        echo "[publish] WARN 结果为空，跳过发布" >&2
        return 0
    fi

    # 守卫 2：没有 token -> 只测速不发布
    if [ -z "$GITHUB_TOKEN" ]; then
        echo "[publish] WARN 未配置 GITHUB_TOKEN，跳过发布" >&2
        return 0
    fi

    if [ "$PUBLISH_DRY_RUN" = "1" ]; then
        echo "[publish] DRY-RUN：不会发出任何请求"
        echo "[publish] 目标 PUT $url"
        echo "[publish] body $(build_payload "$txt" "")"
        return 0
    fi

    sha=$(fetch_sha)
    if [ -n "$sha" ]; then
        echo "[publish] 目标已存在，将覆盖更新（sha=${sha}）"
    else
        echo "[publish] 目标不存在，将新建"
    fi

    # PUT。409/422 通常是 sha 过期（例如同时在网页上改过），重取一次 sha 再试一次。
    attempt=1
    while :; do
        payload=$(build_payload "$txt" "$sha")
        resp=$(curl -sS $CURL_TIMEOUTS -X PUT -w '\n%{http_code}' \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -d "$payload" "$url" 2>/dev/null || true)
        code=$(resp_code "$resp")
        body=$(resp_body "$resp")

        case "$code" in
        2*)
            echo "[publish] 已发布到 $GITHUB_REPO@$GITHUB_BRANCH:$RESULT_PATH"
            return 0
            ;;
        409 | 422)
            if [ "$attempt" -eq 1 ]; then
                echo "[publish] sha 过期，重新读取后重试一次" >&2
                sha=$(fetch_sha)
                attempt=2
                continue
            fi
            fail "HTTP $code $(printf '%.500s' "$body")"
            ;;
        *)
            fail "HTTP $code $(printf '%.500s' "$body")"
            ;;
        esac
    done
}

case "${1:-}" in
convert)
    [ $# -eq 3 ] || usage "convert <csv> <out.txt>"
    convert "$2" "$3"
    ;;
push)
    [ $# -eq 2 ] || usage "push <txt>"
    push "$2"
    ;;
all)
    [ $# -eq 3 ] || usage "all <csv> <out.txt>"
    convert "$2" "$3"
    push "$3"
    ;;
*) usage "{convert|push|all} ..." ;;
esac
