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

# 非 root 的 PATH 常缺 /usr/sbin，PATH 找不到就查常见目录
find_exe() {
    p=$(command -v "$1" 2>/dev/null) && { printf '%s\n' "$p"; return 0; }
    for d in /usr/sbin /sbin /usr/bin /bin /usr/local/sbin /usr/local/bin; do
        [ -x "$d/$1" ] && { printf '%s\n' "$d/$1"; return 0; }
    done
    return 1
}

# UDP 端口占用检测：拿不到就跳过，不阻塞安装
# ss 的本地地址在第 5 列，netstat 在第 4 列；Linux 用 ":"、BSD/macOS 用 "." 分隔
port_busy() {
    if b=$(find_exe ss); then
        "$b" -lun 2>/dev/null | awk -v p="$1" '$4 ~ ("[.:]" p "$") || $5 ~ ("[.:]" p "$") {f=1} END {exit !f}'
    elif b=$(find_exe lsof); then
        "$b" -nP -iUDP:"$1" >/dev/null 2>&1
    elif b=$(find_exe netstat); then
        "$b" -lun 2>/dev/null | awk -v p="$1" '$4 ~ ("[.:]" p "$") || $5 ~ ("[.:]" p "$") {f=1} END {exit !f}'
    else
        return 1
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

# 首次安装才做端口预检；重装时端口多半被自己在用，会误报
if [ ! -f "$APP_DIR/config.yaml" ] && port_busy "$PORT"; then
    [ "$PORT" = "8443" ] && SUG=2053 || SUG=8443
    die "udp/${PORT} 已被其他进程占用，换个端口重试（--port ${SUG}），或先停掉占用者"
fi

# 443 之外只会给出提示，不阻止——VPS 允许哪些端口只有提供方知道
case "$PORT" in
    443) : ;;
    *)   say "使用非标准端口 udp/${PORT}：记得在安全组/防火墙放行 UDP ${PORT}，TCP 不用开" ;;
esac

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
    # hashes.txt 里的路径带 build/ 前缀，必须按 basename 比对，否则会静默跳过校验
    if fetch "https://github.com/HyNetworks/hysteria/releases/download/app/v$VERSION/hashes.txt" \
            "$TMP/hashes.txt" 2>/dev/null; then
        want=$(awk -v a="$ASSET" '{n=$2; sub(/^\*/,"",n); sub(/^.*\//,"",n); if (n==a) {print $1; exit}}' "$TMP/hashes.txt")
        if [ -n "$want" ]; then
            actual=$(sha256_of "$TMP/$ASSET")
            [ "$want" = "$actual" ] || die "sha256 不匹配（期望 ${want}，实际 ${actual}），文件可能被中间人改过"
            say "sha256 校验通过"
        else
            warn "hashes.txt 里没有 $ASSET，本次跳过校验"
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
    # 源和目标可能是同一个文件（用户直接把 cert 放在 certs/ 下），cp 会返回 1
    [ "$(readlink -f "$CERT_SRC" 2>/dev/null || printf '%s' "$CERT_SRC")" = \
      "$(readlink -f "$APP_DIR/certs/cert.pem" 2>/dev/null || printf '%s' "$APP_DIR/certs/cert.pem")" ] \
        || cp -f "$CERT_SRC" "$APP_DIR/certs/cert.pem"
    [ "$(readlink -f "$KEY_SRC" 2>/dev/null || printf '%s' "$KEY_SRC")" = \
      "$(readlink -f "$APP_DIR/certs/key.pem" 2>/dev/null || printf '%s' "$APP_DIR/certs/key.pem")" ] \
        || cp -f "$KEY_SRC" "$APP_DIR/certs/key.pem"
    rm -f "$APP_DIR/certs/selfsigned"
    say "使用已有证书: $CERT_SRC"
elif [ -f "$APP_DIR/certs/cert.pem" ] && [ -f "$APP_DIR/certs/key.pem" ] && [ "$FORCE" -eq 0 ]; then
    # 只有我们生成的自签证书才加 sniGuard: disable
    [ -f "$APP_DIR/certs/selfsigned" ] && SELF_SIGNED=1
    say "复用已有证书"
else
    command -v openssl >/dev/null 2>&1 || {
        if command -v apk >/dev/null 2>&1; then
            say "缺少 openssl，尝试 apk add（可能要十几秒）..."
            apk add --no-cache openssl > "$APP_DIR/apk-openssl.log" 2>&1 || true
        fi
    }
    if ! command -v openssl >/dev/null 2>&1; then
        warn "无法安装 openssl，原因（末尾几行）:"
        tail -n 3 "$APP_DIR/apk-openssl.log" 2>/dev/null | sed 's/^/      /' >&2
        rm -f "$APP_DIR/apk-openssl.log"
        cat >&2 <<EOF

### 没有 openssl，无法自动生成自签证书。两条路，任选一条：

  A) 在本地生成证书再传上去（推荐，不依赖容器软件源）：
       openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \\
         -keyout key.pem -out cert.pem -days 3650 \\
         -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI"
       # 传到服务器后：
       sh install.sh --port $PORT --cert /path/cert.pem --key /path/key.pem

  B) 修好 apk 源后重试：
       apk update          # 看报错，多半是网络或 /etc/apk/repositories
EOF
        exit 1
    fi
    rm -f "$APP_DIR/apk-openssl.log"

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

# 证书指纹：纯 shell 从 PEM 解出 DER 再 sha256，不依赖 openssl
# （容器里常常没有 openssl，但 base64/sha256sum 一定有）
cert_fingerprint() {
    sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$1" 2>/dev/null \
        | grep -v -- '-----' | tr -d '\n' | base64 -d 2>/dev/null \
        | sha256sum 2>/dev/null | awk '{print toupper($1)}' \
        | sed 's/\(..\)/\1:/g; s/:$//'
}

PIN=$(cert_fingerprint "$APP_DIR/certs/cert.pem")
[ -n "$PIN" ] || PIN=$(openssl x509 -in "$APP_DIR/certs/cert.pem" -noout -fingerprint -sha256 2>/dev/null \
      | awk -F= '{print $2}' || true)

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
        # 纯 shell：PEM 解出 DER 再 sha256，无需 openssl
        sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$DIR/certs/cert.pem" 2>/dev/null \
            | grep -v -- '-----' | tr -d '\n' | base64 -d 2>/dev/null \
            | sha256sum 2>/dev/null | awk '{print toupper($1)}' \
            | sed 's/\(..\)/\1:/g; s/:$//'
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

# ---------------------------------------------------------------- 5b. manage.sh
# 运维入口：改端口、换密码、导出 Clash 配置、自检、自启、升级
cat > "$APP_DIR/manage.sh" <<'MANAGE'
#!/bin/sh
# Hysteria 2 运维脚本（BusyBox / POSIX sh）
#   manage.sh show            客户端信息（含 Clash 片段）
#   manage.sh set-port 8443   改监听端口，同步客户端配置
#   manage.sh set-pass        重新生成认证密码与混淆密码
#   manage.sh export          导出可直接导入 Clash Verge 的完整配置
#   manage.sh doctor          自检（进程/监听/内存/磁盘）
#   manage.sh autostart       安装开机自启
#   manage.sh no-autostart    移除开机自启
#   manage.sh upgrade [版本]   换二进制（保留配置）
#   manage.sh start|stop|restart|status|log|run   委托给 run.sh
set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONF="$DIR/config.yaml"
CLIENT="$DIR/client.yaml"
URI="$DIR/client-uri.txt"
R="$DIR/run.sh"

die() { printf '### %s\n' "$*" >&2; exit 1; }
need_conf() { [ -f "$CONF" ] || die "找不到 $CONF，先跑 install.sh"; }

# 就地改写：用临时文件替代 sed -i
# （BSD sed -i 需要额外参数，busybox 不需要，这里统一绕开）
rewrite() {   # rewrite <文件> [sed 参数...]
    f=$1; shift
    [ -f "$f" ] || return 1
    sed "$@" "$f" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
}

cfg_port() {
    awk '/^listen:/{s=$0; sub(/^[^:]*:/,"",s); gsub(/[^0-9]/,"",s); print s; exit}' "$CONF" 2>/dev/null
}
cfg_auth() {
    awk '/^auth:/{f=1;next} /^[^ #]/{f=0} f&&/^[[:space:]]+password:/{print $2; exit}' "$CONF" 2>/dev/null
}
cfg_obfs() {
    awk '/^obfs:/{f=1;next} /^[^ #]/{f=0} f&&/^[[:space:]]+password:/{print $2; exit}' "$CONF" 2>/dev/null
}
cli_host() {
    awk '/^server:/{s=$2; sub(/:[0-9]+$/,"",s); print s; exit}' "$CLIENT" 2>/dev/null
}
cli_sni() {
    awk '/^[[:space:]]+sni:/{print $2; exit}' "$CLIENT" 2>/dev/null
}

# 纯 shell 证书指纹：PEM -> DER -> sha256
fingerprint() {
    sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$DIR/certs/cert.pem" 2>/dev/null \
        | grep -v -- '-----' | tr -d '\n' | base64 -d 2>/dev/null \
        | sha256sum 2>/dev/null | awk '{print toupper($1)}' \
        | sed 's/\(..\)/\1:/g; s/:$//'
}

rebuild_uri() {
    h=$(cli_host); s=$(cli_sni); p=$(cfg_port); a=$(cfg_auth); o=$(cfg_obfs)
    [ -n "$h" ] && [ -n "$p" ] && [ -n "$a" ] || return 0
    u="hysteria2://$a@$h:$p/?sni=$s&insecure=1"
    [ -n "$o" ] && u="$u&obfs=salamander&obfs-password=$o"
    printf '%s#hy2-%s\n' "$u" "$h" > "$URI"
    chmod 600 "$URI" 2>/dev/null
}

write_clash() {
    h=$(cli_host); s=$(cli_sni); p=$(cfg_port); a=$(cfg_auth); o=$(cfg_obfs)
    fp=$(fingerprint)
    cat <<EOF
# 由 manage.sh export 生成，可直接另存为 .yaml 导入 Clash Verge
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: hy2
    type: hysteria2
    server: $h
    port: $p
    password: $a
    sni: $s
    skip-cert-verify: true
    alpn:
      - h3
EOF
    [ -n "$fp" ] && printf '    fingerprint: %s\n' "$fp"
    if [ -n "$o" ]; then
        printf '    obfs: salamander\n    obfs-password: %s\n' "$o"
    fi
    cat <<'EOF'
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - hy2
      - DIRECT
rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
}

case "${1:-}" in
    show)
        echo "--- 客户端配置 ---"
        cat "$CLIENT" 2>/dev/null || echo "(没有 $CLIENT)"
        echo
        echo "--- 分享链接 ---"
        rebuild_uri; cat "$URI" 2>/dev/null
        echo
        echo "--- 证书指纹 ---"
        fingerprint
        ;;
    export)
        need_conf
        out="$DIR/clash.yaml"
        write_clash > "$out"
        chmod 600 "$out"
        echo "已生成 $out"
        echo "用法：Clash Verge -> 配置 -> 新建 -> 本地文件，选这个文件"
        echo
        write_clash
        ;;
    set-port)
        need_conf
        [ -n "${2:-}" ] || die "用法: manage.sh set-port <端口>"
        printf '%s' "$2" | grep -qE '^[0-9]+$' || die "端口必须是数字"
        [ "$2" -ge 1 ] && [ "$2" -le 65535 ] || die "端口范围 1-65535"
        old=$(cfg_port)
        cp -f "$CONF" "$CONF.bak.$(date +%s)"
        rewrite "$CONF" "s/^listen: .*/listen: :$2/" || die "写入失败，已保留备份"
        grep -q "^listen: :$2" "$CONF" || die "写入失败，已保留备份"
        if [ -f "$CLIENT" ]; then
            cp -f "$CLIENT" "$CLIENT.bak.$(date +%s)"
            rewrite "$CLIENT" "s/^server: \(.*\):[0-9]*\$/server: \1:$2/"
        fi
        rebuild_uri
        echo "端口 $old -> $2"
        echo "!! 记得：面板/安全组放行 UDP $2，而不是 $old"
        "$R" restart 2>/dev/null || echo "(服务未在运行，用 manage.sh start 启动)"
        ;;
    set-pass)
        need_conf
        a=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
        o=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
        cp -f "$CONF" "$CONF.bak.$(date +%s)"
        rewrite "$CONF" "s/^  password: .*/  password: $a/" || die "写入失败，已保留备份"
        if grep -q '^obfs:' "$CONF"; then
            rewrite "$CONF" "s/^    password: .*/    password: $o/"
        else
            o=""
        fi
        if [ -f "$CLIENT" ]; then
            rewrite "$CLIENT" "s/^auth: .*/auth: $a/"
            [ -n "$o" ] && rewrite "$CLIENT" "/^obfs:/,/^[^ ]/ s/^[[:space:]]*password: .*/    password: $o/"
            rebuild_uri
        fi
        echo "新认证密码 : $a"
        [ -n "$o" ] && echo "新混淆密码 : $o"
        echo "客户端需重新导入：manage.sh show 查看"
        "$R" restart 2>/dev/null || true
        ;;
    doctor)
        need_conf
        echo "== 进程 =="
        "$R" status 2>/dev/null | sed 's/^/  /' || echo "  未运行"
        p=$(cfg_port)
        if [ -n "$p" ]; then
            hex=$(printf '%04X' "$p")
            echo "== 监听 udp/$p =="
            if cat /proc/net/udp /proc/net/udp6 2>/dev/null | awk -v h=":$hex" 'index($2,h)>0 {f=1} END{exit !f}'; then
                echo "  已监听"
            else
                echo "  未监听！(服务没起，或绑定失败)"
            fi
        fi
        echo "== 内存 =="
        found=0
        for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
            [ -r "$f" ] && { echo "  上限: $(cat "$f") 字节"; found=1; break; }
        done
        [ "$found" -eq 0 ] && echo "  (无 cgroup 限制信息)"
        echo "== 磁盘 =="
        df -h / 2>/dev/null | tail -1 | awk '{print "  可用 " $4}'
        echo "== 证书 =="
        [ -f "$DIR/certs/cert.pem" ] && echo "  cert.pem $(wc -c < "$DIR/certs/cert.pem") 字节" || echo "  缺失！"
        [ -f "$DIR/certs/key.pem" ] && echo "  key.pem  $(wc -c < "$DIR/certs/key.pem") 字节" || echo "  缺失！"
        echo "== 指纹 =="
        fingerprint | sed 's/^/  /'
        ;;
    autostart)
        if command -v rc-update >/dev/null 2>&1 && [ -d /etc/local.d ]; then
            printf '#!/bin/sh\n%s/run.sh start\n' "$DIR" > /etc/local.d/hysteria.start
            chmod +x /etc/local.d/hysteria.start
            rc-update add local default 2>/dev/null
            echo "已用 OpenRC 配置自启 (/etc/local.d/hysteria.start)"
        elif [ -d /etc/crontabs ] || [ -d /var/spool/cron/crontabs ]; then
            if [ -d /etc/crontabs ]; then f=/etc/crontabs/root; else f=/var/spool/cron/crontabs/root; fi
            mkdir -p "$(dirname "$f")"
            grep -qF "$DIR/run.sh" "$f" 2>/dev/null && { echo "已存在自启项"; exit 0; }
            echo "* * * * * $DIR/run.sh status >/dev/null 2>&1 || $DIR/run.sh start" >> "$f"
            if command -v rc-service >/dev/null 2>&1 && rc-service crond start 2>/dev/null; then
                :
            elif command -v crond >/dev/null 2>&1; then
                crond -b 2>/dev/null || true
            else
                echo "!! 本机没有 crond，自启项已写入但不会执行。" >&2
                echo "   装一个：apk add busybox-initscripts 或 apk add cronie" >&2
                exit 1
            fi
            echo "已用 cron 看门狗配置自启 ($f)，每分钟检查一次"
        else
            echo "没有 OpenRC 也没有 crontabs，无法自动配置。" >&2
            echo "请让提供方在容器启动命令里加一行：$DIR/run.sh start" >&2
            exit 1
        fi
        ;;
    no-autostart)
        rm -f /etc/local.d/hysteria.start
        for f in /etc/crontabs/root /var/spool/cron/crontabs/root; do
            if [ -f "$f" ] && grep -qF "$DIR/run.sh" "$f"; then
                grep -vF "$DIR/run.sh" "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
            fi
        done
        echo "已移除自启项"
        ;;
    upgrade)
        ver=${2:-}
        [ -n "$ver" ] || die "用法: manage.sh upgrade <版本号>，例如 manage.sh upgrade 2.13.0"
        case "$(uname -m)" in
            x86_64|amd64) a=amd64 ;; aarch64|arm64) a=arm64 ;;
            armv7l|armv7) a=arm ;; *) die "未知架构" ;;
        esac
        url="https://github.com/HyNetworks/hysteria/releases/download/app/v$ver/hysteria-linux-$a"
        echo "下载 $url"
        tmp="$DIR/.hysteria.new"
        if command -v wget >/dev/null 2>&1; then wget -q -O "$tmp" "$url"; else curl -fsSL -o "$tmp" "$url"; fi
        [ -s "$tmp" ] || die "下载失败"
        chmod 755 "$tmp"
        "$tmp" version >/dev/null 2>&1 || die "新二进制无法运行，已放弃"
        cp -f "$DIR/hysteria" "$DIR/hysteria.bak" 2>/dev/null
        "$R" stop 2>/dev/null
        mv -f "$tmp" "$DIR/hysteria"
        "$R" start
        echo "已升级到 $ver（旧版备份为 hysteria.bak）"
        ;;
    start|stop|restart|status|log|run|check)
        exec "$R" "$@"
        ;;
    *)
        sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
MANAGE

chmod 0755 "$APP_DIR/manage.sh"

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
  insecure: true          # 自签证书；客户端支持 pinSHA256 的话用证书指纹代替
EOF

if [ -n "$PIN" ]; then
    cat >> "$APP_DIR/client.yaml" <<EOF
  # pinSHA256: $PIN
EOF
fi

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
$( if [ -n "$PIN" ]; then echo "证书 pin   : $PIN"; else echo "证书 pin   : (未计算；客户端用 insecure: true)"; fi )

常用命令（都在 /opt/hysteria 下）：
  manage.sh show          查看客户端配置 + 链接 + 指纹
  manage.sh export        生成可直接导入 Clash Verge 的配置
  manage.sh set-port 8443 改端口（自动同步客户端配置）
  manage.sh set-pass      换密码
  manage.sh doctor        自检
  manage.sh autostart     配置开机自启
  manage.sh start|stop|restart|status|log

快捷入口：ln -sf $APP_DIR/manage.sh /usr/local/bin/hy2 && hy2 show
==========================================
EOF

[ "$DO_START" -eq 1 ] || say "还没启动：确认防火墙/安全组放行了 udp/$PORT 后执行 $APP_DIR/manage.sh start"
