# 构建阶段：使用官方 Go 镜像编译
FROM golang:1.22-alpine AS builder

# 构建期代理：docker pull 走的是 Docker 守护进程的代理，但下面 RUN 里的 go build
# 是构建容器内的独立进程，**不会**继承守护进程的代理，必须在这里显式透传。
# 这里刻意用自定义参数名（BUILD_*）而不是 HTTP_PROXY 这类 Docker 预定义参数名，
# 这样代理只在本构建阶段生效，不会波及运行阶段的 apk add 等（保持原有行为不变）。
# 注意：容器的 127.0.0.1 是容器自己，这里要填「容器能访问到宿主机代理」的地址，
# 例如 docker0 网关 http://172.17.0.1:7890 或宿主机内网 IP —— 不要填 127.0.0.1。
ARG BUILD_HTTP_PROXY
ARG BUILD_HTTPS_PROXY
ARG BUILD_NO_PROXY
ENV HTTP_PROXY=${BUILD_HTTP_PROXY} \
    HTTPS_PROXY=${BUILD_HTTPS_PROXY} \
    NO_PROXY=${BUILD_NO_PROXY}

# 依赖下载源，可用 --build-arg GOPROXY=... 覆盖：
#   默认走国内镜像（国内直连即可用），失败再回退 direct；
#   若想强制「直连 GitHub 并走上面的代理」，传 GOPROXY=direct。
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=${GOPROXY}

WORKDIR /app
COPY . .

# 使用 CGO 禁用静态编译，减小最终镜像体积
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o cfst .

# 运行阶段：使用 Alpine 最小化镜像
FROM alpine:3.19

# 安装 ca-certificates（HTTPS 下载测速需）与 tzdata（cron 时区）；
# curl + jq 供 publish.sh 调 GitHub Contents API 使用
RUN apk add --no-cache ca-certificates tzdata curl jq

WORKDIR /opt/cfst

# 复制编译好的二进制、IP 段数据文件、入口脚本与发布脚本
COPY --from=builder /app/cfst /opt/cfst/
COPY --from=builder /app/ip.txt /app/ipv6.txt /opt/cfst/
COPY entrypoint.sh publish.sh /opt/cfst/
RUN chmod +x /opt/cfst/entrypoint.sh /opt/cfst/publish.sh

# 挂载目录：通过卷挂载将结果文件写到容器外
VOLUME ["/data"]

# 将结果文件输出到 /data/result.csv，方便通过卷挂载获取
WORKDIR /data

# 使用 entrypoint.sh 作为入口，支持定时循环模式
ENTRYPOINT ["sh", "/opt/cfst/entrypoint.sh"]
