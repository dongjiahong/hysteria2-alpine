# Hysteria 2 一键部署

给「Alpine 小内存服务器 / TCP 全被封只剩 UDP / 没有 systemd」用的一键部署脚本。

在服务器上跑一条命令：自动下载官方静态二进制、生成 64MB 档位配置、自签证书、进程守护脚本和客户端配置。不编译任何东西。

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/dongjiahong/hysteria2-alpine/main/install.sh
sh /tmp/install.sh --port 8443 --start
```

端口随便挑一个 **UDP** 端口，只要 VPS 允许且安全组放行。`443` 被占或不让用时，`8443` 是好选择，见 [端口怎么选](#端口怎么选)。

---

## 特点

| | |
| :-- | :-- |
| 不编译 | 取官方 Go 静态单文件，Alpine 直接跑，编译才吃内存，下载不吃 |
| 64MB 可用 | QUIC 窗口压到 1MB/2.5MB + `GOMEMLIMIT=32MiB`，实测 8 并发峰值 21.5 MiB |
| 无需 systemd | 自带 `run.sh` 守护，崩溃 3 秒拉起，`setsid` 脱离 SSH 会话 |
| 默认零域名暴露 | 自签证书 + salamander 混淆，SNI 与 QUIC 指纹不上线路 |
| 防中间人 | 下载走 `hashes.txt` 做 sha256 校验，多镜像自动回退 |
| 一键出客户端 | 生成 `client.yaml`、`hysteria2://` 链接、证书指纹 |

---

## 目录

- [环境要求](#环境要求)
- [端口怎么选](#端口怎么选)
- [安装](#安装)
- [使用](#使用)
- [运维](#运维)
- [为什么 64MB 能跑](#为什么-64mb-能跑)
- [证书与域名策略](#证书与域名策略)
- [常见问题](#常见问题)
- [卸载](#卸载)
- [License](#license)

---

## 环境要求

- Alpine Linux（脚本只依赖 POSIX sh 和 busybox applet，不需要 bash、不需要 Python）
- 内存 64MB 起，128MB 以上更从容
- **一个 UDP 端口必须在安全组 / 防火墙上放行，TCP 不用开**
- 架构支持：`amd64` `arm64` `arm` `armv5` `386` `mipsle` `riscv64` `loong64` `s390x`
- 有 `root` 权限（装到 `/opt` 需要；监听 `1024` 以下的端口也需要，`8443` 这类高位端口不需要）

不依赖 systemd 或 OpenRC，有没有 init 都能跑。

---

## 端口怎么选

先分清三件事，它们的端口互不相干：

| | 需要开放端口吗 | 说明 |
| :-- | :-- | :-- |
| **客户端**（你的 Mac / 手机） | **不需要** | hy2 客户端是主动出站连接，只在本机 `127.0.0.1:1080` 起个本地代理，不占对外端口 |
| **服务器** | 需要 **1 个 UDP 端口** | 要安全组 / 防火墙放行；VPS 提供方也可能限制可用端口 |
| **Cloudflare** | 与 hy2 无关 | CF 只代理 HTTP/HTTPS（TCP），**不转发 UDP** |

> **别被「CF 的 8443」带偏**：8443、2053、2083、2087、2096 这串端口是 Cloudflare 代理 HTTPS 用的（TCP）。hy2 是纯 UDP，流量不可能走 CF 代理，你连的永远是 `VPS_IP:端口` 的 UDP，CF 最多当个 DNS（灰云）。
>
> 不过这几个端口号本身**值得优先试**——它们上面跑着大量正常 HTTPS 流量，不容易被针对性封锁。用就行，只是记住那是你 VPS 的 UDP 端口。

### 推荐顺序

| 端口 | 说明 |
| :-- | :-- |
| `8443` | 首选。替代 HTTPS 端口，常见且不刺眼 |
| `2053` / `2083` / `2087` / `2096` | CF 支持的同款端口，适合脚本被拦时换着试 |
| `443` | 最像正常 QUIC，但部分网络对 UDP 443 单独限速 |
| `20000-50000` 之间的高位端口 | 避开扫描和 QoS，但有的网络限制高位 UDP |

避开 `53`（DNS，可能被劫持/限速）、`123`（NTP）、`5060`（SIP）、以及提供方明确封禁的端口。

### 换端口

```sh
sh /tmp/install.sh --port 8443 --start
```

改端口后要同步三处：**安全组 / 防火墙放行 UDP 新端口**、客户端配置里的端口、分享链接里的端口。脚本生成的 `client.yaml` 和链接会自动用新端口。

装完之后改也可以，不用重装：

```sh
sed -i 's/^listen: .*/listen: :2053/' /opt/hysteria/config.yaml
/opt/hysteria/run.sh restart
```

### 验证端口是否真的通了

UDP 没有 TCP 那种"握手成功"的概念，`telnet` / `nc -z` 都测不出来，只能靠应用层确认：

```sh
# 1. 服务器上确认进程在跑
/opt/hysteria/run.sh status

# 2. 日志里确认监听地址和端口正确
/opt/hysteria/run.sh log | grep "server up and running"
# 应看到 {"listen": ":8443"}
```

3. 真正能证明"通了"的只有客户端日志里的 `connected to server`。

所以顺序是：先确认服务在跑、端口对，再用客户端连。**一直超时的话先换端口试，别急着改配置**——端口被拦、密码错、混淆密码错，这三者表现完全一样。

安全组没放行时，服务端日志里连一个连接记录都不会有，这是最典型的症状。

---

## 安装

### 1. 登录服务器

```sh
ssh root@<服务器IP>
```

### 2. 下载脚本

服务器能访问 GitHub：

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/dongjiahong/hysteria2-alpine/main/install.sh
```

没有 `wget` 就用 `curl`（两者任选，busybox 自带 `wget`）：

```sh
curl -fsSL -o /tmp/install.sh https://raw.githubusercontent.com/dongjiahong/hysteria2-alpine/main/install.sh
```

`raw.githubusercontent.com` 在部分线路很慢或不通，换 jsDelivr 镜像：

```sh
wget -O /tmp/install.sh https://cdn.jsdelivr.net/gh/dongjiahong/hysteria2-alpine@main/install.sh
```

都连不上就在本地下好再传上去：

```sh
# 本地执行
curl -fsSLO https://raw.githubusercontent.com/dongjiahong/hysteria2-alpine/main/install.sh
scp install.sh root@<服务器IP>:/tmp/
```

### 3. 运行

```sh
sh /tmp/install.sh --port 8443 --start
```

装完会打印这些，**认证密码和混淆密码都记下来**：

```
================ 部署完成 ================
安装目录   : /opt/hysteria
服务端配置 : /opt/hysteria/config.yaml
证书       : /opt/hysteria/certs/  (自签)
监听       : udp/8443
认证密码   : xxxxxxxxxxxxxxxxxxxxxxxx
混淆密码   : yyyyyyyyyyyyyyyyyyyyyyyy
证书 pin   : 85F9AC58...
```

密码随时可以用 `/opt/hysteria/run.sh show` 再查，不用怕丢。

> **先确认一件事**：`/opt` 在服务器重启后会不会被清空。如果这台机器是别人给的容器、目录不持久，重启后要重跑一次安装脚本（一条命令，很快）。不确定就先写个笔记记下密码，或者用 `APP_DIR=/root/hysteria` 装到别的位置。

### 4. 参数

| 参数 | 默认 | 说明 |
| :-- | :-- | :-- |
| `-p, --port N` | `443` | UDP 监听端口 |
| `--host HOST` | 自动探测公网 IP | 客户端连接地址；探测不到就留 `YOUR_SERVER_IP` 等手填 |
| `--password P` | 随机 24 位 | hy2 认证密码 |
| `--obfs-password P` | 随机 24 位 | salamander 混淆密码 |
| `--sni NAME` | `hy2.local` | TLS SNI / 自签证书 CN |
| `--no-obfs` | 关闭 | 关掉混淆，回到标准 HTTP/3 外观 |
| `--cert FILE` `--key FILE` | 自签 | 用已有证书（两者必须同时给） |
| `--binary FILE` | 下载 | 用本地二进制，跳过下载 |
| `--force` | 不覆盖 | 覆盖已有配置，**会重新生成密码** |
| `--start` | 不启动 | 装完立刻启动 |
| `--version V` | `2.13.0` | 指定 hysteria 版本 |
| `-h, --help` | | 帮助 |

环境变量 `APP_DIR` 可改安装目录（默认 `/opt/hysteria`），`HY_VERSION` 可指定版本。

### 5. 安装目录

| 文件 | 作用 |
| :-- | :-- |
| `hysteria` | 官方二进制 |
| `config.yaml` | 服务端配置，含密码，别外传 |
| `certs/` | 证书与私钥（`key.pem` 权限 0600） |
| `run.sh` | 进程管理脚本 |
| `client.yaml` | 客户端配置（权限 0600） |
| `client-uri.txt` | `hysteria2://` 分享链接 |
| `hysteria.log` | 日志，超过 5MB 自动滚动一次 |
| `hysteria.pid` / `hysteria.child` | 守护进程 / 子进程 PID |

### 6. 服务器连不上 GitHub 怎么办

脚本的下载失败时，在本地取好二进制再传上去：

```sh
# 本地（Mac / Linux）
curl -LO https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64
scp hysteria-linux-amd64 root@<服务器IP>:/tmp/

# 服务器上
sh /tmp/install.sh --binary /tmp/hysteria-linux-amd64 --port 8443 --start
```

按服务器架构换资产名：`amd64` / `arm64` / `arm` / `386` 等，用 `uname -m` 确认。

> 官方仓库已从 `apernet/hysteria` 迁到 `HyNetworks/hysteria`，老链接会 301 跳转。

---

## 使用

### 验证服务在跑

```sh
/opt/hysteria/run.sh status
```

正常输出：

```
运行中: supervisor pid=3602 hysteria pid=3610
  RSS: 9.4 MiB
```

再确认日志里有 `server up and running`：

```sh
/opt/hysteria/run.sh log
```

### 拿客户端配置

```sh
/opt/hysteria/run.sh show
```

会打印三样东西：`client.yaml` 内容、`hysteria2://` 链接、证书 `pinSHA256`。

取回本地：

```sh
# 本地执行
scp root@<服务器IP>:/opt/hysteria/client.yaml .
```

`client.yaml` 长这样：

```yaml
server: 1.2.3.4:8443
auth: xxxxxxxx
tls:
  sni: hy2.local
  insecure: true
  # pinSHA256: 85F9AC...   # 客户端支持的话用这行代替 insecure
obfs:
  type: salamander
  salamander:
    password: yyyyyyyy
socks5:
  listen: 127.0.0.1:1080
  disableUDP: false
```

### 用分享链接

```
hysteria2://<auth>@<IP>:8443/?sni=hy2.local&insecure=1&obfs=salamander&obfs-password=<pw>#hy2
```

可直接导入 Clash Verge Rev、Hiddify、NekoBox 等支持 hy2 的客户端。

### 用 mihomo 手写

```yaml
proxies:
  - name: hy2
    type: hysteria2
    server: 1.2.3.4
    port: 8443
    password: xxxxxxxx
    sni: hy2.local
    skip-cert-verify: true
    obfs: salamander
    obfs-password: yyyyyyyy
```

### 判断真的通了

客户端日志出现下面这行才算成功：

```
connected to server  {"addr": "1.2.3.4:8443", "udpEnabled": true, ...}
```

只看到 `client mode` 而没有 `connected to server`，说明还没连上，按 [常见问题](#常见问题) 查。

---

## 运维

### 命令速查

```sh
/opt/hysteria/run.sh start      # 后台启动
/opt/hysteria/run.sh stop
/opt/hysteria/run.sh restart
/opt/hysteria/run.sh status     # 状态 + RSS + 线程数 + cgroup 上限
/opt/hysteria/run.sh log        # tail -f
/opt/hysteria/run.sh show       # 客户端配置 + 链接 + 证书指纹
/opt/hysteria/run.sh check      # 只验配置能否启动，3 秒后自动关闭
/opt/hysteria/run.sh run        # 前台运行（交给外部 supervisor 时用）
```

`status` 的退出码：`0` 运行中，`3` 未运行，适合放进检查脚本。

### 开机 / 重启后自动拉起

先看这台机器有什么 init：

```sh
ps -p 1 -o comm=
```

**输出是 `init` 或 `openrc-init`（绝大多数 Alpine VPS）：**

```sh
echo '/opt/hysteria/run.sh start' > /etc/local.d/hysteria.start
chmod +x /etc/local.d/hysteria.start
rc-update add local default
```

**输出是别的东西（纯容器，没有 init）：**

用 cron 每分钟检查一次，发现挂了就拉起来。这一招对没有 init 的环境最稳：

```sh
echo '* * * * * /opt/hysteria/run.sh status >/dev/null 2>&1 || /opt/hysteria/run.sh start' \
  >> /var/spool/cron/crontabs/root
rc-service crond start 2>/dev/null || crond -b 2>/dev/null || true
```

提供服务的一方如果有面板或启动脚本，把 `/opt/hysteria/run.sh start` 加进去最省事。

> `run.sh start` 用 `setsid` 把进程脱离当前会话，所以 SSH 断开不会把它带走。但要记住：**进程活着 ≠ 机器重启后还在**，重启后必须靠上面任一方式拉起。

### 崩溃与 OOM 后的行为

- 进程被 kill（含被 OOM killer 干掉，退出码 137）：3 秒后自动拉起
- 连续 3 次「启动 5 秒内就退出」：判定为配置或端口错误，停止重试并写日志，避免刷屏

确认是否被 OOM：

```sh
dmesg -T | grep -i -E 'killed process|out of memory'
```

容器里看不到 `dmesg` 时，直接看 RSS 增长：

```sh
/opt/hysteria/run.sh status
```

真被 OOM 了，按这个顺序处理：

1. `GOMEMLIMIT` 从 `32MiB` 降到 `24MiB`（改 `run.sh` 顶部）
2. QUIC 窗口再压一档：`1048576` → `524288`，`2621440` → `1310720`
3. 降低并发：`maxIncomingStreams: 64` → `32`
4. 实在不够就换 128MB 以上的套餐

### 改端口

编辑 `config.yaml` 第一行，然后重启：

```sh
sed -i 's/^listen: .*/listen: :8443/' /opt/hysteria/config.yaml
/opt/hysteria/run.sh restart
```

客户端和 `client.yaml`、分享链接里的端口要同步改。**新端口记得在安全组放行 UDP。**

> 重跑 `install.sh` 不加 `--force` 时会沿用 `config.yaml` 里已有的端口，`--port` 会被忽略。这是有意的，防止误改。

### 改密码

```sh
# 1. 改服务端
sed -i 's/^  password: .*/  password: 新密码/' /opt/hysteria/config.yaml
/opt/hysteria/run.sh restart

# 2. 改 client.yaml 里的 auth 字段，客户端重新导入
```

混淆密码在 `obfs.salamander.password`。**两边不一致的现象是「一直超时」，看起来和服务端没启动完全一样。**

### 换证书

证书路径固定，直接替换文件再重启即可，不用重装：

```sh
/opt/hysteria/run.sh stop
cp 新的cert.pem /opt/hysteria/certs/cert.pem
cp 新的key.pem  /opt/hysteria/certs/key.pem
chmod 600 /opt/hysteria/certs/key.pem
# 重要：原来用自签证书时 config.yaml 里有 sniGuard: disable，换成真证书后要删掉这一行
/opt/hysteria/run.sh restart
```

证书在本地签好后传上去：

```sh
scp cert.pem key.pem root@<服务器IP>:/tmp/
```

### 升级

只换二进制，配置、证书、密码全部保留：

```sh
/opt/hysteria/run.sh stop
wget -O /opt/hysteria/hysteria \
  https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64
chmod +x /opt/hysteria/hysteria
/opt/hysteria/run.sh start
/opt/hysteria/run.sh status
```

或者重跑安装脚本（**不加 `--force`**），它会替换二进制但保留配置：

```sh
/opt/hysteria/run.sh stop
sh /tmp/install.sh
/opt/hysteria/run.sh start
```

加 `--force` 会重新生成密码和配置，客户端得重导，升级时别用。

### 备份与恢复

```sh
# 备份（配置 + 证书 + 客户端配置，不含二进制和日志）
tar czf /root/hy2-backup-$(date +%Y%m%d).tar.gz \
  -C /opt/hysteria config.yaml certs client.yaml client-uri.txt

# 传回本地保存
scp root@<服务器IP>:/root/hy2-backup-*.tar.gz .
```

恢复：

```sh
tar xzf /root/hy2-backup-20261030.tar.gz -C /opt/hysteria
/opt/hysteria/run.sh restart
```

升级、改端口、换证书前都建议先备份一次。

### 日常检查清单

```sh
/opt/hysteria/run.sh status          # 在跑吗，内存正常吗
/opt/hysteria/run.sh log | tail -20  # 有没有异常断开
```

`RSS` 长期高于 45 MiB 就该考虑压窗口或升级内存了。

---

## 为什么 64MB 能跑

默认配置跑不了。QUIC 的接收窗口是**每个连接**的内存上限，Hysteria 默认给到 stream 8MB / conn 20MB，几个连接就把 64MB 吃穿。

脚本做了四件事：

| 旋钮 | 默认 | 本脚本 | 作用 |
| :-- | :-- | :-- | :-- |
| `quic.*ReceiveWindow` | stream 8MB / conn 20MB | **1MB / 2.5MB** | 直接决定并发内存 |
| `GOMEMLIMIT` | 无 | **32MiB** + `GOGC=50` | Go 堆软上限，到线多 GC 而不是撑爆内存 |
| `GOMAXPROCS` | 核数 | **1** | 少一套 per-P 缓存 |
| `ignoreClientBandwidth` | false | **true** | 不按客户端声称带宽堆 Brutal 缓冲，统一走 BBR 保守档 |

实测数据（macOS arm64，同一份配置、同一 QUIC 路径）：

| 场景 | 服务端 RSS |
| :-- | :-- |
| 空载 | 9.3 – 15 MiB |
| 单流持续下载 250MB（150MB/s） | 16.7 – 20.8 MiB |
| 8 并发同时下载 | 峰值 21.5 MiB |

Linux amd64 通常比 macOS 高 10~30%，按 **30 MiB 左右**估算是安全的。

**代价要知情**：吞吐上限 ≈ 窗口 ÷ RTT。

- 单流 1MB 窗口、200ms RTT ⇒ 约 40 Mbps
- 连接级 2.5MB 窗口、200ms RTT ⇒ 约 100 Mbps

够用就别动。以后内存放宽到 128MB / 256MB，把窗口按 **2:5** 的比例放大（如 2/5MB、4/10MB），重启即生效。

---

## 证书与域名策略

### 默认：不碰你的域名

自签证书 + `obfs: salamander`。salamander 把整个 QUIC 包随机化，ClientHello、SNI、QUIC 指纹都不出现在线路上，对中间盒来说就是一段无结构的 UDP。

好处：不用签证书、不用管 90 天续期、域名和这台机器在链路上毫无关联。

客户端用 `insecure: true` 或证书指纹 `pinSHA256` 固定。后者能防中间人，客户端支持就用它。

### 想用真域名：先分清三种封锁

| 封锁形态 | 影响范围 | 会不会牵连主域 |
| :-- | :-- | :-- |
| SNI 封锁 | 只用这个 SNI 的连接 | 用子域不牵连；用 Apex 会牵连 |
| IP 封锁 | 解析到这台 VPS 的所有域名 | CF 橙云站点不受影响，灰云子域受影响 |
| DNS 污染 | 只影响被污染的子域解析 | 不影响主域和其他子域 |

结论：**用子域**（如 `hy2.example.com`），且必须是 **DNS only（灰云）**。Cloudflare 橙云只代理 HTTP(S)，不转发 UDP/QUIC 到源站。

最坏情况就是「这个子域废了，删掉换一个」，主站和 CF 代理完全不受影响。

### 用真证书（伪装成正常 HTTP/3 站点）

**别在 64MB 机器上跑内置 ACME**，签发时会额外吃内存，正好卡在最脆弱的启动时刻。在本地用 `acme.sh` 走 Cloudflare DNS-01 签发，不需要开放 80/443 TCP：

```sh
# 本地执行
export CF_Token=你的CF_API_Token
acme.sh --issue --dns dns_cf -d hy2.example.com --server letsencrypt
acme.sh --install-cert -d hy2.example.com \
  --key-file /tmp/key.pem --fullchain-file /tmp/cert.pem

scp /tmp/cert.pem /tmp/key.pem root@<服务器IP>:/tmp/
ssh root@<服务器IP> sh /tmp/install.sh \
  --cert /tmp/cert.pem --key /tmp/key.pem --sni hy2.example.com
```

之后每 90 天续期一次，替换 `certs/` 里的文件并 `run.sh restart`。

### 想更像真站点

把 `config.yaml` 里的 masquerade 从 `string` 换成 `proxy`，反向代理一个真实网站：

```yaml
masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
```

注意这会额外起一个 HTTP 客户端，64MB 环境下建议只用 `string` 模式（默认）。

---

## 常见问题

**客户端一直超时，服务端日志没有任何连接记录**

按这个顺序查：

1. 安全组 / 防火墙是否放行 **UDP**（不是 TCP）
2. 混淆密码是否和服务端一致（不一致的表现就是超时）
3. `run.sh status` 是否运行中
4. `--host` 填的地址是否可达
5. 这个端口本身是否被 VPS 提供方封禁——换 `8443` 或 `2053` 再试一次

**VPS 不给我 443 端口怎么办**

随便换一个 UDP 端口，`8443` 最好用，而且不需要 root（高位端口）。见 [端口怎么选](#端口怎么选)。

注意 Cloudflare 支持的那批端口（8443 / 2053 / 2083…）是给 HTTPS/TCP 代理用的，**CF 不转发 UDP**，hy2 用不上 CF 的端口本身，只是这些端口号在网络上比较通畅。

**日志没有 `server up and running`**

```sh
/opt/hysteria/run.sh check
```

它会启动一次并打印具体报错。注意 `check` 会绑定同一个端口，**服务在跑时要先 `stop`**，否则报端口占用。

**能连但速度上不去**

1MB 窗口在 200ms RTT 下的物理上限约 40 Mbps。内存允许就放大窗口；另外 UDP 443 在某些线路上会被单独 QoS 限速，换 `8443` / `2053` / `2087` 试试，往往比调窗口有效。

**`wget` 下载脚本失败**

服务器连不上 GitHub。在本地下好 `scp` 上去，见 [服务器连不上 GitHub 怎么办](#6-服务器连不上-github-怎么办)。

**`apk add` 失败**

没有可用软件源。用 `--binary` 装二进制，证书用 `--cert/--key` 从外部带入。

**重装后客户端连不上**

加了 `--force` 会重新生成密码。用 `run.sh show` 重新导出配置。

**`status` 显示未运行，但日志里刚启动过**

看日志末尾。如果是「连续 3 次启动即退出」，说明是配置或端口问题，`run.sh check` 能看到原因。

**重启服务器后连不上了**

进程没自启。见 [开机 / 重启后自动拉起](#开机--重启后自动拉起)。

**能不能和 xray-lite 共存**

可以，但 64MB 里同时跑两个不划算（hy2 常驻约 20MB，[xray-lite](https://github.com/dongjiahong/xray-lite) 从 43MB 起）。TCP 被封干净时只留 hy2 更省心。

---

## 卸载

```sh
/opt/hysteria/run.sh stop
rm -rf /opt/hysteria
```

如果加过自启项，一并删掉：

```sh
rm -f /etc/local.d/hysteria.start /etc/local.d/hysteria.start.bak
sed -i '/hysteria/d' /var/spool/cron/crontabs/root
```

---

## 说明

- 服务端版本默认 `v2.13.0`，配置字段以 [Hysteria 2 官方文档](https://v2.hysteria.network/) 为准
- 脚本只依赖 POSIX sh 与 busybox applet，已在 macOS 的 `sh` 和 `dash`（POSIX 严格模式）下跑通完整流程；**尚未在真实 Alpine 机器上验证**，首次部署请留意前两步输出
- busybox 差异已做 fallback：无 `curl` 用 `wget`，无 `sha256sum` 用 `shasum` 或 `openssl`，无 `setsid` 用 `nohup`
- `config.yaml` 含密码，权限为 `0644`；多用户机器上建议 `chmod 600`

---

## License

[MIT](LICENSE)
