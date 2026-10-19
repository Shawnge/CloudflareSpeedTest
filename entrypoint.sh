#!/bin/sh
# cfst 容器入口。
#
# 两种工作模式：
#   有 CRON_SCHEDULE  -> 可选先跑一轮，然后前台常驻 crond，按表达式反复执行
#   无 CRON_SCHEDULE  -> 跑一轮就退出（便于手工/本地调试）
#
# 也支持 `entrypoint.sh --once <cfst 参数...>`：只跑一轮后退出，crontab 里用它自调用。
#
# 环境变量：
#   DATA_DIR       结果目录（默认 /data）
#   CFST_BIN       cfst 可执行文件（默认 /opt/cfst/cfst）
#   PUBLISH_SH     发布脚本（默认与 CFST_BIN 同目录的 publish.sh）
#   CRON_SCHEDULE  5 段 cron 表达式；默认为每天 4 点；置为空串表示单次运行
#   RUN_ON_START   1 = 启动时先跑一轮（默认 1）
#   CFST_ARGS      追加给 cfst 的参数（命令行的参数也会被追加）
#   CFST_URL       非空时作为 -url 传给 cfst，覆盖它的内置测速地址
#                  （内置的 https://cf.xiu2.xyz/url 在部分网络会返回 403，
#                   后果是所有下载速度 0.00、地区码全是 N/A、结果为空）
#   CFST_TL        平均延迟上限(ms)，非空时作为 -tl 传给 cfst
#   CFST_DN        普通模式的下载测速数量；地区配额模式由 TOP_N 决定
#   CFST_SL        下载速度下限(MB/s)，非空时作为 -sl 传给 cfst；想关掉就设成空值
#   REGIONS        测速和发布保留的地区码，逗号分隔；通过 HTTPing 提前筛选
#   TOP_N          每个地区独立获取的合格 IP 数量（默认 8），候选不足时保留实际数量
#   其余（GITHUB_*、TZ 等）原样透传给 publish.sh
set -eu

: "${DATA_DIR:=/data}"
: "${CFST_BIN:=/opt/cfst/cfst}"
: "${PUBLISH_SH:=$(dirname "$CFST_BIN")/publish.sh}"
# 注意用 - 而不是 := —— 空串是「不要定时、单次运行」的合法取值，不能被默认值顶掉
CRON_SCHEDULE=${CRON_SCHEDULE-0 4 * * *}
: "${RUN_ON_START:=1}"
: "${CFST_ARGS:=}"
: "${CFST_URL:=}"
# 这三个留空 = 不传对应参数。CFST_SL 是由 compose 给了默认值 20 的（速度门槛）；
# 线路达不到那个速度时 cfst 会输出 0 条结果、连 result.csv 都不创建，
# 于是每天静默不发布，所以这一项想关掉就显式设成空值。
: "${CFST_TL:=}"
: "${CFST_DN:=}"
: "${CFST_SL:=}"
REGIONS=$(printf '%s' "${REGIONS-}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
: "${REGIONS:=HKG,NRT,SIN,SJC,LAX}"
: "${TOP_N:=8}"
export REGIONS TOP_N

CFST_DIR=$(dirname "$CFST_BIN")
RESULT_CSV="$DATA_DIR/result.csv"
RESULT_TXT="$DATA_DIR/result.txt"

# 解析自己的参数：吃掉 --once，其余全部原样转交 cfst
ONCE=0
ARGS=""
for arg in "$@"; do
    case "$arg" in
    --once) ONCE=1 ;;
    *) ARGS="$ARGS $arg" ;;
    esac
done
ARGS="$CFST_ARGS$ARGS"

# 未显式指定 -url 时用 CFST_URL 覆盖 cfst 的内置测速地址。
# 两个 -url 会让 cfst 静默取后者，所以命令行已给出时这里就不再追加。
if [ -n "$CFST_URL" ]; then
    case " $ARGS " in
    *' -url '*) : ;;
    *) ARGS="$ARGS -url $CFST_URL" ;;
    esac
fi

# 三个测速阈值同样可以用环境变量给（等价于 -tl/-dn/-sl）。留空 = 不传。
# 参数里已经写了该选项时不再追加，并以显式参数为准 —— 与 -url 同一套约定，
# 保住 `docker compose run --rm cfst -tl 500` 这种一次性试参数的用法；
# 但两处都写了不同值时必须告警，否则「在 .env 里改了值却不生效」会完全无声。
# <flag> <环境变量名> <值>
add_cfst_opt() {
    opt_flag=$1
    opt_name=$2
    opt_val=$3
    [ -n "$opt_val" ] || return 0
    case " $ARGS " in
    *" $opt_flag "* | *" $opt_flag="*)
        echo "[entrypoint] WARN 参数里已经有 ${opt_flag}，忽略 ${opt_name}=${opt_val}（以显式参数为准）" >&2
        ;;
    *) ARGS="$ARGS $opt_flag $opt_val" ;;
    esac
}

add_cfst_opt -tl CFST_TL "$CFST_TL"
add_cfst_opt -dn CFST_DN "$CFST_DN"
add_cfst_opt -sl CFST_SL "$CFST_SL"

# 地区码来自 HTTP 响应头，必须先按地区筛选，再应用下载测速数量上限。
case " $ARGS " in
*' -httping '* | *' -httping='*) : ;;
*) ARGS="$ARGS -httping" ;;
esac
add_cfst_opt -cfcolo REGIONS "$REGIONS"
add_cfst_opt -dn-per-colo TOP_N "$TOP_N"

# 未显式指定 -o 时补上固定输出路径。
# 必须是固定名（不能用时间戳），因为下游 publish.sh 只认 $DATA_DIR/result.csv。
case " $ARGS " in
*' -o '*) : ;;
*) ARGS="$ARGS -o $RESULT_CSV" ;;
esac

# 解析出本脚本自身的绝对路径，crontab 里自调用要用
SELF=$0
case "$SELF" in
/*) : ;;
*) SELF="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")" ;;
esac

# 跑一轮：清理 -> cfst -> 转换并发布
#
# 第 0 步的清理不是可选的：cfst 在结果为空时会直接返回，既不创建也不截断 result.csv，
# 于是上一轮的旧 CSV 会原地留着，被当成新数据重新发布，正好踩中「用旧数据覆盖远端」这个反目标。
run_once() {
    mkdir -p "$DATA_DIR"
    rm -f "$RESULT_CSV" "$RESULT_TXT"

    rc=0
    # 在 cfst 所在目录执行，ip.txt / ipv6.txt 在那里
    (cd "$CFST_DIR" && "$CFST_BIN" $ARGS) || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo "[entrypoint] cfst 退出码 ${rc}，跳过转换与发布" >&2
        return "$rc"
    fi

    if ! sh "$PUBLISH_SH" all "$RESULT_CSV" "$RESULT_TXT"; then
        echo "[entrypoint] 发布阶段失败（cfst 本身成功）" >&2
        return 1
    fi
    return 0
}

# --once：单轮自调用，crontab 用的就是这条
if [ "$ONCE" -eq 1 ]; then
    run_once
    exit $?
fi

# 单次模式
if [ -z "$CRON_SCHEDULE" ]; then
    rc=0
    if [ "$RUN_ON_START" = "1" ]; then
        run_once || rc=$?
    fi
    exit "$rc"
fi

# ---------------- 定时模式 ----------------

# 定时模式下没有 token 等于「每天静默什么都不做」，按配置错误处理
if [ -z "${GITHUB_TOKEN-}" ]; then
    echo "[entrypoint] 错误: 已设置 CRON_SCHEDULE 但 GITHUB_TOKEN 为空，无法发布" >&2
    exit 1
fi

n=$(printf '%s' "$CRON_SCHEDULE" | wc -w | tr -d ' ')
if [ "$n" -ne 5 ]; then
    echo "[entrypoint] 错误: CRON_SCHEDULE 必须是 5 段，实际 $n 段: '$CRON_SCHEDULE'" >&2
    exit 1
fi

# RUN_ON_START=0 时也要先建目录，否则 cron 在重定向日志时就会失败。
mkdir -p "$DATA_DIR"

if [ "$RUN_ON_START" = "1" ]; then
    rc=0
    run_once || rc=$?
    if [ "$rc" -ne 0 ]; then
        # 首轮失败不能让容器退出，否则一次网络抖动就会触发无限重启
        echo "[entrypoint] 启动首轮失败（退出码 ${rc}），继续等待定时任务" >&2
    fi
fi

# crond 是 daemon，只给任务最小环境，**不继承容器的环境变量**。
# 所以必须把所需变量显式前置到 crontab 命令行里；漏掉 GITHUB_TOKEN 就会每天静默跳过发布。
cron_prefix=""
add_env() { # <变量名>
    eval "val=\${$1-}"
    case "$val" in
    *"'"*)
        echo "[entrypoint] 错误: $1 含有单引号，无法安全写入 crontab" >&2
        exit 1
        ;;
    esac
    if [ -n "$val" ]; then
        cron_prefix="$cron_prefix $1='$val'"
    fi
}
for name in DATA_DIR CFST_BIN PUBLISH_SH REGIONS TOP_N GITHUB_TOKEN GITHUB_REPO \
    GITHUB_BRANCH RESULT_PATH GITHUB_API_BASE PUBLISH_DRY_RUN CFST_URL TZ; do
    add_env "$name"
done

CRON_LINE="$CRON_SCHEDULE$cron_prefix sh $SELF --once$ARGS >> $DATA_DIR/cfst.log 2>&1"
printf '%s\n' "$CRON_LINE" | crontab - || {
    echo "[entrypoint] 错误: 无法安装 crontab" >&2
    exit 1
}

echo "[entrypoint] 定时模式启动，时区 ${TZ:-UTC}"
# 回显 crontab 时必须把 token 打码，否则日志里就有了明文 token（spec §7 禁止）
echo "[entrypoint] crontab: $(printf '%s' "$CRON_LINE" | sed "s|GITHUB_TOKEN='[^']*'|GITHUB_TOKEN='***'|")"

exec /usr/sbin/crond -f
