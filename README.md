# Hysteria 2 一键部署

面向「Alpine 容器 / 64MB 内存 / TCP 全被封、只剩 UDP / 没有 systemd」场景的 Hysteria 2 服务端部署脚本。

不编译任何东西，直接取官方静态二进制；把运行内存压进 64MB；崩溃自动拉起；顺带生成客户端配置。

```sh
docker cp install.sh <容器>:/tmp/
docker exec -it <容器> sh /tmp/install.sh --port 443 --start
```

---

## 特点

| | |
| :-- | :-- |
| 不编译 | 官方 Go 静态单文件，Alpine 直接跑，容器内存只受运行影响 |
| 64MB 可用 | QUIC 窗口压到 1MB/2.5MB + `GOMEMLIMIT=32MiB`，实测 8 并发峰值 21.5 MiB |
| 无 systemd | 自带 `run.sh` 守护，崩溃 3 秒拉起，`setsid` 脱离会话 |
| 默认零域名暴露 | 自签证书 + salamander 混淆，SNI 与 QUIC 指纹不上线路 |
| 抗中间人 | 下载走 `hashes.txt` 做 sha256 校验，多镜像自动回退 |
| 一键出客户端 | 生成 `client.yaml`、`hysteria2://` 链接、证书指纹 |

---

## 目录

- [环境要求](#环境要求)
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

- Linux 容器，Alpine 优先（脚本只依赖 POSIX sh 和 busybox applet）
- 内存 64MB 起，128MB 以上更从容
- **UDP 端口必须在安全组 / 防火墙上放行，TCP 不用开**
- 架构支持：`amd64` `arm64` `arm` `armv5` `386` `mipsle` `riscv64` `loong64` `s390x`

宿主机没有 OpenRC 或 systemd 都可以，脚本不依赖 init 系统。

---

## 安装

### 1. 把脚本送进容器

```sh
docker cp install.sh <容器名>:/tmp/
```

### 2. 运行

```sh
docker exec -it <容器名> sh /tmp/install.sh --port 443 --start
```

装完会打印这样的信息，**认证密码和混淆密码都记下来**：

```
================ 部署完成 ================
安装目录   : /opt/hysteria
服务端配置 : /opt/hysteria/config.yaml
证书       : /opt/hysteria/certs/  (自签)
监听       : udp/443
认证密码   : xxxxxxxxxxxxxxxxxxxxxxxx
混淆密码   : yyyyyyyyyyyyyyyyyyyyyyyy
证书 pin   : 85F9AC58...
```

密码也随时可以用 `run.sh show` 再查，不用怕丢。

### 3. 参数

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

### 4. 安装目录

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

### 5. 容器没出站网络怎么办

下载失败时，在能上网的机器上取好二进制再送进去：

```sh
# Mac 上
curl -LO https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64
docker cp hysteria-linux-amd64 <容器名>:/tmp/

# 容器内
sh /tmp/install.sh --binary /tmp/hysteria-linux-amd64 --port 443 --start
```

官方仓库已从 `apernet/hysteria` 迁到 `HyNetworks/hysteria`，老链接会 301 跳转。

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

```sh
docker cp <容器名>:/opt/hysteria/client.yaml .
```

`client.yaml` 长这样：

```yaml
server: 1.2.3.4:443
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
hysteria2://<auth>@<IP>:443/?sni=hy2.local&insecure=1&obfs=salamander&obfs-password=<pw>#hy2
```

可直接导入 Clash Verge Rev、Hiddify、NekoBox 等支持 hy2 的客户端。

### 用 mihomo 手写

```yaml
proxies:
  - name: hy2
    type: hysteria2
    server: 1.2.3.4
    port: 443
    password: xxxxxxxx
    sni: hy2.local
    skip-cert-verify: true
    obfs: salamander
    obfs-password: yyyyyyyy
```

### 判断真的通了

客户端日志出现下面这行才算成功：

```
connected to server  {"addr": "1.2.3.4:443", "udpEnabled": true, ...}
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
/opt/hysteria/run.sh run        # 前台运行（容器入口用）
```

`status` 的退出码：`0` 运行中，`3` 未运行，适合放进检查脚本。

### 让容器重启后自动拉起

最省事的做法是把 `run.sh run` 设为容器入口，不需要装任何 init：

```sh
docker run -d --name hy2 --restart=always \
  -p 443:443/udp \
  -v /srv/hy2:/opt/hysteria \
  <镜像> /opt/hysteria/run.sh run
```

容器启动命令改不了的话，就手动 `run.sh start`。进程是 `setsid` 出去的，断开 `docker exec` 会话不会被 SIGHUP 带走。

宿主机是带 OpenRC 的 Alpine 时：

```sh
echo '/opt/hysteria/run.sh start' > /etc/local.d/hysteria.start
chmod +x /etc/local.d/hysteria.start
rc-update add local default
```

### 崩溃与 OOM 后的行为

- 进程被 kill（含被 OOM killer 干掉，退出码 137）：3 秒后自动拉起
- 连续 3 次「启动 5 秒内就退出」：判定为配置或端口错误，停止重试并写日志，避免刷屏

确认是否被 OOM：

```sh
dmesg -T | grep -i -E 'killed process|out of memory'
```

真被 OOM 了，按这个顺序处理：

1. `GOMEMLIMIT` 从 `32MiB` 降到 `24MiB`（改 `run.sh` 顶部）
2. QUIC 窗口再压一档：`1048576` → `524288`，`2621440` → `1310720`
3. 降低并发：`maxIncomingStreams: 64` → `32`
4. 实在不够就换 128MB 容器

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
# 重要：如果原来用的是自签证书，config.yaml 里有 sniGuard: disable，换成真证书后要删掉这一行
/opt/hysteria/run.sh restart
```

### 升级

只换二进制，配置、证书、密码全部保留：

```sh
/opt/hysteria/run.sh stop
curl -fsSL -o /opt/hysteria/hysteria \
  https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64
chmod +x /opt/hysteria/hysteria
/opt/hysteria/run.sh start
/opt/hysteria/run.sh status
```

或者重跑安装脚本（**不加 `--force`**），它会替换二进制但保留配置：

```sh
/opt/hysteria/run.sh stop
sh /tmp/install.sh --binary /tmp/hysteria-linux-amd64
/opt/hysteria/run.sh start
```

加 `--force` 会重新生成密码和配置，客户端得重导，升级时别用。

### 备份与恢复

```sh
# 备份（配置 + 证书 + 客户端配置）
docker cp <容器名>:/opt/hysteria ./hy2-backup

# 恢复
docker cp ./hy2-backup/. <容器名>:/opt/hysteria/
docker exec <容器名> /opt/hysteria/run.sh start
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
| `GOMEMLIMIT` | 无 | **32MiB** + `GOGC=50` | Go 堆软上限，到线多 GC 而不是撑爆容器 |
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

**别在 64MB 容器里跑内置 ACME**，签发时会额外吃内存，正好卡在最脆弱的启动时刻。在宿主机或本地用 `acme.sh` 走 Cloudflare DNS-01 签发，不需要开放 80/443 TCP：

```sh
# 在 Mac 或宿主机上
export CF_Token=你的CF_API_Token
acme.sh --issue --dns dns_cf -d hy2.example.com --server letsencrypt
acme.sh --install-cert -d hy2.example.com \
  --key-file /tmp/key.pem --fullchain-file /tmp/cert.pem

docker cp /tmp/cert.pem <容器>:/tmp/
docker cp /tmp/key.pem  <容器>:/tmp/

docker exec <容器> sh /tmp/install.sh \
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

**日志没有 `server up and running`**

```sh
/opt/hysteria/run.sh check
```

它会启动一次并打印具体报错。

**能连但速度上不去**

1MB 窗口在 200ms RTT 下的物理上限约 40 Mbps。内存允许就放大窗口；另外 UDP 443 在某些线路上会被单独 QoS 限速，换 `8443` / `2053` / `2087` 试试，往往比调窗口有效。

**`apk add` 失败**

容器没有可用软件源。用 `--binary` 装二进制，证书用 `--cert/--key` 从外部带入。

**重装后客户端连不上**

加了 `--force` 会重新生成密码。用 `run.sh show` 重新导出配置。

**`status` 显示未运行，但日志里刚启动过**

看日志末尾。如果是「连续 3 次启动即退出」，说明是配置或端口问题，`run.sh check` 能看到原因。

**能不能和 xray-lite 共存**

可以，但 64MB 容器里同时跑两个不划算（hy2 常驻约 20MB，[xray-lite](https://github.com/dongjiahong/xray-lite) 从 43MB 起）。TCP 被封干净时只留 hy2 更省心。

---

## 卸载

```sh
/opt/hysteria/run.sh stop
rm -rf /opt/hysteria
```

容器里如果加了 OpenRC 自启项，一并删掉：

```sh
rm -f /etc/local.d/hysteria.start
```

---

## 说明

- 服务端版本默认 `v2.13.0`，配置字段以 [Hysteria 2 官方文档](https://v2.hysteria.network/) 为准
- 脚本只依赖 POSIX sh 与 busybox applet，已在 macOS 的 `sh` 和 `dash`（POSIX 严格模式）下跑通完整流程；**尚未在真实 Alpine 容器内验证**（开发机没有 Docker），首次部署请留意 `install.sh` 的前两步输出
- busybox 特有差异已做 fallback：无 `curl` 用 `wget`，无 `sha256sum` 用 `shasum` 或 `openssl`，无 `setsid` 用 `nohup`
- `config.yaml` 含密码，权限为 `0644`；多用户容器里建议 `chmod 600`

---

## License

[MIT](LICENSE)
