# 构建阶段：使用官方 Go 镜像编译
FROM golang:1.22-alpine AS builder

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
