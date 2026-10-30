#!/bin/sh
# ============================================================================
#  Hysteria 2 服务端部署脚本
#  适用：Alpine 容器 / 无 systemd / 64MB 内存硬限制 / 只有 UDP 能出去
#  不编译，直接取官方静态二进制（多镜像回退），生成 64MB 档位配置与守护脚本
#
#  sh install.sh -h
# ============================================================================
set -eu

APP_DIR=${APP_DIR:-/opt/hysteria}
VERSION=${HY_VERSION:-2.13.0}
PORT=443
SNI=hy2.local
HOST=""
PASSWORD=""
OBFS_PASSWORD=""
CERT_SRC=""
KEY_SRC=""
USE_OBFS=1
BINARY_SRC=""
FORCE=0
DO_START=0

say()  { printf '==> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }
die()  { printf '### %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: sh install.sh [选项]

  -p, --port N            UDP 监听端口（默认 443）
      --host HOST         客户端连接用的地址（默认尝试自动探测公网 IP）
      --password P        hy2 认证密码（默认随机生成）
      --obfs-password P   salamander 混淆密码（默认随机生成）
      --sni NAME          TLS SNI / 自签证书 CN（默认 hy2.local）
      --no-obfs           关闭 salamander 混淆（默认开启）
      --cert FILE         使用已有证书（需同时给 --key）
      --key FILE          使用已有私钥
      --binary FILE       用本地二进制，跳过下载（网络不通时用这个）
      --force             覆盖已有配置（旧配置备份为 config.yaml.bak.<时间戳>）
      --start             安装完立刻启动
      --version V         指定 hysteria 版本（默认 2.13.0）
  -h, --help              显示帮助

环境变量：APP_DIR（安装目录，默认 /opt/hysteria）、HY_VERSION
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--port)          PORT=${2:?"--port 需要值"}; shift 2 ;;
        --host)             HOST=${2:?"--host 需要值"}; shift 2 ;;
        --password)         PASSWORD=${2:?"--password 需要值"}; shift 2 ;;
        --obfs-password)    OBFS_PASSWORD=${2:?"--obfs-password 需要值"}; shift 2 ;;
        --sni)              SNI=${2:?"--sni 需要值"}; shift 2 ;;
        --cert)             CERT_SRC=${2:?"--cert 需要值"}; shift 2 ;;
        --key)              KEY_SRC=${2:?"--key 需要值"}; shift 2 ;;
        --binary)           BINARY_SRC=${2:?"--binary 需要值"}; shift 2 ;;
        --version)          VERSION=${2:?"--version 需要值"}; shift 2 ;;
        --no-obfs)          USE_OBFS=0; shift ;;
        --force)            FORCE=1; shift ;;
        --start)            DO_START=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  die "未知参数: $1（用 -h 看帮助）" ;;
    esac
done

[ -n "$CERT_SRC" ] && [ -z "$KEY_SRC" ] && die "--cert 必须配 --key"
[ -n "$KEY_SRC" ] && [ -z "$CERT_SRC" ] && die "--key 必须配 --cert"

# ---------------------------------------------------------------- 1. 环境检查
say "1/6 环境检查"

[ "$(id -u)" -eq 0 ] || warn "不是 root：监听 ${PORT}/udp 或写 $APP_DIR 可能失败"

case "$(uname -m)" in
    x86_64|amd64)       ARCH=amd64 ;;
    aarch64|arm64)      ARCH=arm64 ;;
    armv7l|armv7|armhf) ARCH=arm ;;
    armv6l|armv5l)      ARCH=armv5 ;;
    i386|i486|i586|i686) ARCH=386 ;;
    riscv64)            ARCH=riscv64 ;;
    loongarch64|loong64) ARCH=loong64 ;;
    mips*)              ARCH=mipsle ;;
    s390x)              ARCH=s390x ;;
    *)                  die "不支持的架构: $(uname -m)" ;;
esac

mem_limit() {
    if [ -r /sys/fs/cgroup/memory.max ]; then
        cat /sys/fs/cgroup/memory.max
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        cat /sys/fs/cgroup/memory/memory.limit_in_bytes
    else
        awk '/^MemTotal:/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo unknown
    fi
}
MEM=$(mem_limit)
case "$MEM" in
    ''|unknown|max|*[!0-9]*) MEMTXT="未检测到（未设 cgroup 上限）" ;;
    *) if [ "$MEM" -ge 536870912 ]; then
           MEMTXT="≥512 MiB"
       else
           MEMTXT="$((MEM / 1048576)) MiB"
       fi ;;
esac
say "架构 ${ARCH} / 版本 ${VERSION} / 内存上限 ${MEMTXT}"

# ---------------------------------------------------------------- 2. 取二进制
say "2/6 准备二进制"

mkdir -p "$APP_DIR" "$APP_DIR/certs"

fetch() {   # fetch <url> <outfile>
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 600 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$2" "$1"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl >/dev/null 2>&1 || return 1
        curl -fsSL --connect-timeout 10 --max-time 600 -o "$2" "$1"
    else
        return 1
    fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

ASSET="hysteria-linux-$ARCH"
TMP=$(mktemp -d 2>/dev/null || echo "/tmp/hy2.$$")
mkdir -p "$TMP"

if [ -n "$BINARY_SRC" ]; then
    [ -f "$BINARY_SRC" ] || die "找不到 $BINARY_SRC"
    cp -f "$BINARY_SRC" "$APP_DIR/hysteria"
    say "使用本地二进制: $BINARY_SRC"
else
    # 直连优先，然后走常见的 GitHub 加速前缀
    MIRRORS="https://github.com
https://ghfast.top/https://github.com
https://gh-proxy.com/https://github.com
https://ghproxy.net/https://github.com
https://gh.llkk.cc/https://github.com
https://hub.gitmirror.com/https://github.com"

    got=0
    for m in $MIRRORS; do
        url="$m/HyNetworks/hysteria/releases/download/app/v$VERSION/$ASSET"
        say "下载: $url"
        if fetch "$url" "$TMP/$ASSET" && [ -s "$TMP/$ASSET" ]; then
            size=$(wc -c < "$TMP/$ASSET")
            if [ "$size" -gt 5000000 ]; then
                got=1
                break
            fi
            warn "文件只有 $size 字节，多半是错误页，换下一个源"
        fi
        rm -f "$TMP/$ASSET"
    done
    [ "$got" -eq 1 ] || die "所有源都下载失败。请在能上网的机器上取 $ASSET 后用 --binary 传进来"

    # 校验（拿不到 hashes.txt 就跳过，不阻塞部署）
    if fetch "https://github.com/HyNetworks/hysteria/releases/download/app/v$VERSION/hashes.txt" \
            "$TMP/hashes.txt" 2>/dev/null; then
        want=$(awk -v a="$ASSET" '{n=$2; sub(/^\*/,"",n); if (n==a) {print $1; exit}}' "$TMP/hashes.txt")
        if [ -n "$want" ]; then
            actual=$(sha256_of "$TMP/$ASSET")
            [ "$want" = "$actual" ] || die "sha256 不匹配（期望 ${want}，实际 ${actual}），文件可能被中间人改过"
            say "sha256 校验通过"
        fi
    else
        warn "拿不到 hashes.txt，跳过校验"
    fi

    install -m 0755 "$TMP/$ASSET" "$APP_DIR/hysteria"
fi

chmod 0755 "$APP_DIR/hysteria"
rm -rf "$TMP"
"$APP_DIR/hysteria" version >/dev/null 2>&1 \
    || die "二进制跑不起来（架构不匹配？）试试: $APP_DIR/hysteria version"

# ---------------------------------------------------------------- 3. 证书
say "3/6 准备证书"

SELF_SIGNED=0
if [ -n "$CERT_SRC" ]; then
    cp -f "$CERT_SRC" "$APP_DIR/certs/cert.pem"
    cp -f "$KEY_SRC"  "$APP_DIR/certs/key.pem"
    rm -f "$APP_DIR/certs/selfsigned"
    say "使用已有证书: $CERT_SRC"
elif [ -f "$APP_DIR/certs/cert.pem" ] && [ -f "$APP_DIR/certs/key.pem" ] && [ "$FORCE" -eq 0 ]; then
    # 只有我们生成的自签证书才加 sniGuard: disable
    [ -f "$APP_DIR/certs/selfsigned" ] && SELF_SIGNED=1
    say "复用已有证书"
else
    command -v openssl >/dev/null 2>&1 || {
        command -v apk >/dev/null 2>&1 && apk add --no-cache openssl >/dev/null 2>&1
    }
    command -v openssl >/dev/null 2>&1 || die "没有 openssl，无法自签证书；请用 --cert/--key 提供"

    SELF_SIGNED=1
    # ECDSA P-256：比 Ed25519 兼容性好（部分客户端 Chrome 指纹不支持 Ed25519）
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$APP_DIR/certs/key.pem" -out "$APP_DIR/certs/cert.pem" \
        -days 3650 -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1 \
        || die "自签证书失败（openssl 太老？）"
    chmod 0600 "$APP_DIR/certs/key.pem"
    : > "$APP_DIR/certs/selfsigned"
    say "已生成自签证书（CN=${SNI}，10 年）"
fi

PIN=$(openssl x509 -in "$APP_DIR/certs/cert.pem" -noout -fingerprint -sha256 2>/dev/null \
      | awk -F= '{print $2}' | tr -d ':' || true)

# ---------------------------------------------------------------- 4. 配置
say "4/6 生成服务端配置"

[ -n "$PASSWORD" ]      || PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
[ -n "$OBFS_PASSWORD" ] || OBFS_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)

if [ -f "$APP_DIR/config.yaml" ] && [ "$FORCE" -eq 0 ]; then
    warn "config.yaml 已存在，跳过生成（覆盖请加 --force，会先备份）"
    KEPT=1
else
    KEPT=0
    [ -f "$APP_DIR/config.yaml" ] && cp -f "$APP_DIR/config.yaml" "$APP_DIR/config.yaml.bak.$(date +%s)"

    cat > "$APP_DIR/config.yaml" <<EOF
# Hysteria 2 服务端配置 —— install.sh 生成于 $(date '+%F %T')
# 内存档位: 64MB（QUIC 窗口压到 1MB/2.5MB）
listen: :$PORT

tls:
  cert: $APP_DIR/certs/cert.pem
  key: $APP_DIR/certs/key.pem
EOF

    if [ "$SELF_SIGNED" -eq 1 ]; then
        cat >> "$APP_DIR/config.yaml" <<'EOF'
  # 自签证书：不校验客户端带来的 SNI；客户端用 pinSHA256 或 insecure
  sniGuard: disable
EOF
    fi

    cat >> "$APP_DIR/config.yaml" <<EOF

auth:
  type: password
  password: $PASSWORD
EOF

    if [ "$USE_OBFS" -eq 1 ]; then
        cat >> "$APP_DIR/config.yaml" <<EOF

# 混淆：整个 QUIC 包被随机化，SNI 和 QUIC 指纹都不可见。
# 客户端 obfs-password 不一致时表现为"超时、连不上"
obfs:
  type: salamander
  salamander:
    password: $OBFS_PASSWORD
EOF
    fi

    cat >> "$APP_DIR/config.yaml" <<'EOF'

# 不做 Brutal 带宽协商，统一走 BBR 保守档：避免客户端谎报带宽把缓冲顶爆
ignoreClientBandwidth: true
congestion:
  type: bbr
  bbrProfile: conservative

# 内存关键项。默认是 stream 8MB / conn 20MB，64MB 容器几个连接就 OOM。
# 窗口 = 单连接内存上限，调小就是拿速度上限换内存。比例保持 2:5。
quic:
  initStreamReceiveWindow: 1048576   # 1 MiB
  maxStreamReceiveWindow: 1048576
  initConnReceiveWindow: 2621440     # 2.5 MiB
  maxConnReceiveWindow: 2621440
  maxIdleTimeout: 30s
  maxIncomingStreams: 64
  disableStatelessReset: true

udpIdleTimeout: 60s

# 不用 proxy 模式（会额外起一个 HTTP 客户端）；开了 obfs 后外部本来就碰不到这段
masquerade:
  type: string
  string:
    content: "It works!"
    statusCode: 200
EOF
    chmod 0644 "$APP_DIR/config.yaml"
    say "已写入 $APP_DIR/config.yaml（密码随机生成）"
fi

# ---------------------------------------------------------------- 5. 守护脚本
say "5/6 生成进程管理脚本"

cat > "$APP_DIR/run.sh" <<'RUNSH'
#!/bin/sh
# Hysteria 2 进程管理（无 systemd 场景）
#   run.sh run      前台运行（容器 entrypoint 用）
#   run.sh start    后台启动，崩溃自动拉起
#   run.sh stop | restart | status | log | show | check
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN="$DIR/hysteria"
CONF="$DIR/config.yaml"
PIDFILE="$DIR/hysteria.pid"
CHILDFILE="$DIR/hysteria.child"
LOGFILE="$DIR/hysteria.log"
LOGMAX=5242880

# 64MB 档位：Go 堆软上限 32MiB、GC 更积极、单核。
# 想放宽就改这里：GOMEMLIMIT=40MiB / GOGC=100 / GOMAXPROCS=2
export GOMEMLIMIT=${GOMEMLIMIT:-32MiB}
export GOGC=${GOGC:-50}
export GOMAXPROCS=${GOMAXPROCS:-1}
export GODEBUG=${GODEBUG:-madvdontneed=1}
export HYSTERIA_DISABLE_UPDATE_CHECK=1
export HYSTERIA_LOG_LEVEL=${HYSTERIA_LOG_LEVEL:-info}

rotate() {
    if [ -f "$LOGFILE" ]; then
        size=$(wc -c < "$LOGFILE")
        [ "$size" -gt "$LOGMAX" ] && mv -f "$LOGFILE" "$LOGFILE.1"
    fi
}

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

guard() {
    fast=0
    while :; do
        t0=$(date +%s)
        "$BIN" server -c "$CONF" &
        child=$!
        echo "$child" > "$CHILDFILE"
        wait "$child"
        rc=$?
        echo "[run.sh] hysteria 退出 rc=$rc ($(date '+%F %T'))" >&2
        if [ $(( $(date +%s) - t0 )) -lt 5 ]; then
            fast=$((fast + 1))
            if [ "$fast" -ge 3 ]; then
                echo "[run.sh] 连续 3 次启动即退出，判定为配置/端口错误，不再重启" >&2
                break
            fi
        else
            fast=0
        fi
        sleep 3
    done
    rm -f "$CHILDFILE"
}

case "${1:-}" in
    run)
        rotate
        echo $$ > "$PIDFILE"
        trap 'rm -f "$PIDFILE" "$CHILDFILE"; exit 0' INT TERM HUP
        guard
        rm -f "$PIDFILE" "$CHILDFILE"
        ;;
    start)
        if running; then
            echo "已在运行 (pid $(cat "$PIDFILE"))"
            exit 0
        fi
        rotate
        rm -f "$PIDFILE"
        # setsid：脱离当前会话，SSH 断开时不会被 SIGHUP 带走
        if command -v setsid >/dev/null 2>&1; then
            nohup setsid "$0" run >>"$LOGFILE" 2>&1 &
        else
            nohup "$0" run >>"$LOGFILE" 2>&1 &
        fi
        # 守护进程自己把 pid 写进 pidfile，这里等它落盘
        i=0
        while [ $i -lt 6 ] && [ ! -s "$PIDFILE" ]; do sleep 1; i=$((i + 1)); done
        if running; then
            echo "已启动 (pid $(cat "$PIDFILE"))，日志: $LOGFILE"
        else
            echo "启动失败，最近日志:" >&2
            tail -n 20 "$LOGFILE" >&2
            rm -f "$PIDFILE"
            exit 1
        fi
        ;;
    stop)
        # 先记住子进程，守护进程退出时会清理这两个文件
        child=""
        [ -f "$CHILDFILE" ] && child=$(cat "$CHILDFILE")
        if running; then kill "$(cat "$PIDFILE")" 2>/dev/null; fi
        sleep 1
        if [ -n "$child" ]; then
            kill "$child" 2>/dev/null
            sleep 1
            kill -9 "$child" 2>/dev/null
        fi
        rm -f "$PIDFILE" "$CHILDFILE"
        echo "已停止"
        ;;
    restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;
    status)
        if running; then
            child=$(cat "$CHILDFILE" 2>/dev/null || echo "")
            echo "运行中: supervisor pid=$(cat "$PIDFILE") hysteria pid=${child:-?}"
            if [ -n "$child" ] && [ -r "/proc/$child/status" ]; then
                awk '/VmRSS|Threads/ {print "  " $0}' "/proc/$child/status"
            elif [ -n "$child" ]; then
                ps -o rss= -p "$child" 2>/dev/null | awk '{printf "  RSS: %.1f MiB\n", $1 / 1024}'
            fi
            if [ -r /sys/fs/cgroup/memory.max ]; then
                echo "  cgroup 限制: $(cat /sys/fs/cgroup/memory.max) 字节"
            elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
                echo "  cgroup 限制: $(cat /sys/fs/cgroup/memory/memory.limit_in_bytes) 字节"
            fi
        else
            echo "未运行"
            exit 3
        fi
        ;;
    log)
        tail -n 50 -f "$LOGFILE"
        ;;
    show)
        echo "--- client.yaml ---"
        cat "$DIR/client.yaml" 2>/dev/null || echo "(没有生成, 重跑 install.sh)"
        echo
        echo "--- hysteria2:// 链接 ---"
        cat "$DIR/client-uri.txt" 2>/dev/null || true
        echo
        echo "--- 证书 pinSHA256 ---"
        openssl x509 -in "$DIR/certs/cert.pem" -noout -fingerprint -sha256 2>/dev/null | awk -F= '{print $2}'
        ;;
    check)
        # check 会真实绑定端口，服务在跑时必然冲突，先提醒再执行
        if running; then
            echo "服务正在运行，check 需要绑定同一个端口，必然冲突。先 run.sh stop 再 check。" >&2
            exit 1
        fi
        "$BIN" server -c "$CONF" &
        p=$!
        sleep 3
        if kill -0 "$p" 2>/dev/null; then
            echo "配置 OK：服务已成功启动（3 秒后关闭）"
            kill "$p" 2>/dev/null
            wait "$p" 2>/dev/null
        else
            echo "配置有问题，见上面的报错" >&2
            exit 1
        fi
        ;;
    *)
        echo "用法: $0 {run|start|stop|restart|status|log|show|check}" >&2
        exit 2
        ;;
esac
RUNSH

chmod 0755 "$APP_DIR/run.sh"

# ---------------------------------------------------------------- 6. 客户端配置
say "6/6 生成客户端配置"

if [ -z "$HOST" ]; then
    HOST=$(fetch https://api.ipify.org - 2>/dev/null || fetch https://ipv4.icanhazip.com - 2>/dev/null || true)
    HOST=$(printf '%s' "$HOST" | tr -d ' \r\n')
    case "$HOST" in
        ""|*[!0-9a-fA-F:.]*) HOST="YOUR_SERVER_IP" ;;
    esac
    [ "$HOST" = "YOUR_SERVER_IP" ] && warn "没探测到公网 IP，客户端配置里请把 YOUR_SERVER_IP 换成服务器地址（或用 --host 指定）"
fi

# 复用了旧配置时，把值读回来，保证 client.yaml / 链接和服务端一致
CRED_SHOW=1
if [ "$KEPT" -eq 1 ]; then
    _p=$(awk '/^listen:/{s=$0; sub(/^[^:]*:/,"",s); gsub(/[^0-9]/,"",s); print s; exit}' "$APP_DIR/config.yaml" 2>/dev/null || true)
    _a=$(awk '/^auth:/{f=1;next} /^[^ #]/{f=0} f&&/^[[:space:]]+password:/{print $2; exit}' "$APP_DIR/config.yaml" 2>/dev/null || true)
    _o=$(awk '/^obfs:/{f=1;next} /^[^ #]/{f=0} f&&/^[[:space:]]+password:/{print $2; exit}' "$APP_DIR/config.yaml" 2>/dev/null || true)
    [ -n "$_p" ] && PORT=$_p
    if [ -n "$_a" ]; then PASSWORD=$_a; else CRED_SHOW=0; fi
    if [ -n "$_o" ]; then USE_OBFS=1; OBFS_PASSWORD=$_o; else USE_OBFS=0; fi
fi

cat > "$APP_DIR/client.yaml" <<EOF
server: $HOST:$PORT
auth: $PASSWORD
tls:
  sni: $SNI
  insecure: true          # 自签证书；客户端支持 pinSHA256 的话改用下一行更强
  # pinSHA256: $PIN
EOF

if [ "$USE_OBFS" -eq 1 ]; then
    cat >> "$APP_DIR/client.yaml" <<EOF
obfs:
  type: salamander
  salamander:
    password: $OBFS_PASSWORD
EOF
fi

cat >> "$APP_DIR/client.yaml" <<'EOF'

# 本地代理入口（按需改成 http: 或 tun:）
socks5:
  listen: 127.0.0.1:1080
  disableUDP: false
EOF

URI="hysteria2://$PASSWORD@$HOST:$PORT/?sni=$SNI&insecure=1"
if [ "$USE_OBFS" -eq 1 ]; then
    URI="$URI&obfs=salamander&obfs-password=$OBFS_PASSWORD"
fi
printf '%s#hy2-%s\n' "$URI" "$HOST" > "$APP_DIR/client-uri.txt"
chmod 0600 "$APP_DIR/client.yaml" "$APP_DIR/client-uri.txt"

if [ "$DO_START" -eq 1 ]; then
    "$APP_DIR/run.sh" start
fi

cat <<EOF

================ 部署完成 ================
安装目录   : $APP_DIR
服务端配置 : $APP_DIR/config.yaml
证书       : $APP_DIR/certs/  ($([ "$SELF_SIGNED" -eq 1 ] && echo 自签 || echo 自带))
监听       : udp/$PORT
认证密码   : $([ "$CRED_SHOW" -eq 1 ] && echo "$PASSWORD" || echo "见 config.yaml")
$( if [ "$USE_OBFS" -eq 1 ]; then echo "混淆密码   : $([ "$CRED_SHOW" -eq 1 ] && echo "$OBFS_PASSWORD" || echo "见 config.yaml")"; else echo "混淆       : 已关闭"; fi )
证书 pin   : $PIN

启动 : $APP_DIR/run.sh start      (前台: $APP_DIR/run.sh run)
状态 : $APP_DIR/run.sh status
日志 : $APP_DIR/run.sh log
客户端: $APP_DIR/run.sh show      或 scp $APP_DIR/client.yaml .
==========================================
EOF

[ "$DO_START" -eq 1 ] || say "还没启动：确认防火墙/安全组放行了 udp/$PORT 后执行 run.sh start"
