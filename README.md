# Hysteria 2 一键部署

给「Alpine 小内存服务器 / TCP 全被封只剩 UDP / 没有 systemd」用的 Hysteria 2 部署与运维脚本。

一条命令装好，之后全部用 `manage.sh` 管：改端口、换密码、导出 Clash 配置、自检、自启、升级。

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/dongjiahong/hysteria2-alpine/main/install.sh
sh /tmp/install.sh --port 8443 --start
```

---

## 目录

- [它做了什么](#它做了什么)
- [环境要求](#环境要求)
- [安装](#安装)
- [连上它：客户端配置](#连上它客户端配置)
- [Clash Verge 怎么用](#clash-verge-怎么用)
- [日常运维](#日常运维)
- [端口与防火墙](#端口与防火墙)
- [为什么 64MB 能跑](#为什么-64mb-能跑)
- [证书与域名策略](#证书与域名策略)
- [排障](#排障)
- [卸载](#卸载)
- [说明](#说明)
- [License](#license)

---

## 它做了什么

`install.sh` 在你的服务器上完成六件事：

| 步骤 | 内容 |
| :-- | :-- |
| 1 | 检查架构、内存上限、端口占用 |
| 2 | 下载官方静态二进制（多镜像回退 + sha256 校验） |
| 3 | 准备证书（自签，或用 `--cert/--key` 指定） |
| 4 | 生成 64MB 档位的服务端配置 |
| 5 | 生成 `run.sh`（进程守护）和 `manage.sh`（运维入口） |
| 6 | 生成客户端配置、分享链接、证书指纹 |

装完目录结构：

```
/opt/hysteria/
├── hysteria          官方二进制
├── config.yaml       服务端配置（含密码）
├── certs/            证书与私钥
├── run.sh            进程守护（启停/状态/日志）
├── manage.sh         运维入口（推荐用这个）
├── client.yaml       客户端配置
├── client-uri.txt    hysteria2:// 分享链接
├── clash.yaml        manage.sh export 后生成的 Clash 配置
└── hysteria.log      日志，超 5MB 自动滚动
```

---

## 环境要求

- Alpine Linux（只依赖 POSIX sh 和 busybox applet，不需要 bash / Python）
- 内存 64MB 起
- **一个 UDP 端口**必须在面板 / 安全组放行（不是 TCP）
- 架构：`amd64` `arm64` `arm` `armv5` `386` `mipsle` `riscv64` `loong64` `s390x`
- root 权限

不需要 systemd 或 OpenRC。

---

## 安装

### 1. 登录服务器

用提供方的 Web 终端 / VNC，或 SSH。

### 2. 下载脚本

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/dongjiahong/hysteria2-alpine/main/install.sh
```

`raw.githubusercontent.com` 慢或不通时换镜像：

```sh
wget -O /tmp/install.sh https://cdn.jsdelivr.net/gh/dongjiahong/hysteria2-alpine@main/install.sh
```

都不行就在本地下好再 `scp` 上去。

### 3. 运行

```sh
sh /tmp/install.sh --port 8443 --start
```

输出示例：

```
==> 1/6 环境检查
==> 架构 amd64 / 版本 2.13.0 / 内存上限 64 MiB
==> 使用非标准端口 udp/8443：记得在安全组/防火墙放行 UDP 8443，TCP 不用开
==> 2/6 准备二进制
==> 3/6 准备证书
==> 4/6 生成服务端配置
==> 5/6 生成进程管理脚本
==> 6/6 生成客户端配置
已启动 (pid 8688)

================ 部署完成 ================
认证密码   : xxxxxxxxxxxxxxxxxxxxxxxx
混淆密码   : yyyyyyyyyyyyyyyyyyyyyyyy
证书 pin   : AA:BB:CC:...
```

**密码记下来**，也可以用 `manage.sh show` 随时查看。

### 4. 参数

| 参数 | 默认 | 说明 |
| :-- | :-- | :-- |
| `-p, --port N` | `443` | UDP 监听端口 |
| `--host HOST` | 自动探测 | 客户端连接地址 |
| `--password P` | 随机 24 位 | 认证密码 |
| `--obfs-password P` | 随机 24 位 | salamander 混淆密码 |
| `--sni NAME` | `hy2.local` | TLS SNI / 证书 CN |
| `--no-obfs` | 关闭 | 关掉混淆 |
| `--cert FILE --key FILE` | 自签 | 用已有证书 |
| `--binary FILE` | 下载 | 用本地二进制 |
| `--force` | 不覆盖 | 覆盖配置并**重新生成密码** |
| `--start` | 不启动 | 装完立刻启动 |
| `--version V` | `2.13.0` | 指定版本 |

环境变量 `APP_DIR`（默认 `/opt/hysteria`）、`HY_VERSION`。

安装时会自动预检端口占用；首次安装若端口被占会直接报错并建议替代端口。

### 5. 服务器连不上 GitHub

```sh
# 本地
curl -LO https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64
scp hysteria-linux-amd64 root@<服务器IP>:/tmp/

# 服务器
sh /tmp/install.sh --binary /tmp/hysteria-linux-amd64 --port 8443 --start
```

> 官方仓库已从 `apernet/hysteria` 迁到 `HyNetworks/hysteria`。

---

## 连上它：客户端配置

### 看配置

```sh
/opt/hysteria/manage.sh show
```

输出客户端 YAML、`hysteria2://` 链接、证书指纹。

### 三种接入方式

| 方式 | 适合 |
| :-- | :-- |
| **分享链接** | 手机 App、Clash Verge 直接粘贴 |
| **Clash 配置** | Clash Verge / mihomo，`manage.sh export` |
| **原生 client.yaml** | 官方 hysteria 客户端 |

分享链接长这样：

```
hysteria2://<密码>@<IP>:8443/?sni=hy2.local&insecure=1&obfs=salamander&obfs-password=<混淆密码>#hy2
```

---

## Clash Verge 怎么用

**可以用。** Clash Verge 的内核是 mihomo，原生支持 hysteria2（含 salamander 混淆和证书指纹 pinning）。

### 方法一：一键导出（推荐）

```sh
/opt/hysteria/manage.sh export
```

生成 `/opt/hysteria/clash.yaml`，内容已经填好你的端口、密码、SNI、混淆密码和证书指纹：

```yaml
proxies:
  - name: hy2
    type: hysteria2
    server: 134.185.104.103
    port: 8443
    password: xxxxxxxx
    sni: hy2.local
    skip-cert-verify: true
    alpn:
      - h3
    fingerprint: AA:BB:CC:...          # 证书 pin，防中间人
    obfs: salamander
    obfs-password: yyyyyyyy
proxy-groups:
  - name: PROXY
    type: select
    proxies: [hy2, DIRECT]
rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
```

拿到本地：

```sh
# 本地执行
scp root@<服务器IP>:/opt/hysteria/clash.yaml .
```

Clash Verge 里：**配置 → 新建 → 本地文件**，选这个文件，然后启用它。

> 如果服务端连不上 scp，直接 `cat /opt/hysteria/clash.yaml` 复制整段，在 Clash Verge 里"新建 → 本地文件"保存成 yaml 也行。

### 方法二：粘贴分享链接

```sh
/opt/hysteria/manage.sh show      # 复制 hysteria2:// 那一行
```

Clash Verge：**配置 → 新建 → 从剪贴板导入**。

> 如果链接里的地址不对，改 `/opt/hysteria/client.yaml` 的 `server:` 那行，再跑 `manage.sh show` 重新生成链接。
>
> `clash.yaml` 里的 `mixed-port` 等是全局项，Clash Verge 会用自己的设置覆盖，不影响使用。

### 方法三：手写

```yaml
proxies:
  - name: hy2
    type: hysteria2
    server: <服务器IP>
    port: 8443
    password: <认证密码>
    sni: hy2.local
    skip-cert-verify: true
    obfs: salamander
    obfs-password: <混淆密码>
```

### 几个坑

| 现象 | 原因 |
| :-- | :-- |
| 一直超时、节点测速失败 | 混淆密码不一致；或面板映射是 TCP 不是 UDP |
| 提示 `unsupported proxy type` | Clash Verge 内核太旧，更新 Rev 到最新版 |
| 能连但很慢 | 见 [为什么 64MB 能跑](#为什么-64mb-能跑)，20 Mbps 左右是保守档的合理水平 |
| 指纹报错 | `fingerprint` 必须是 SHA256、冒号分隔大写；`manage.sh export` 已自动生成 |
| 指纹是否需要配合 skip-cert-verify | **需要**。Go 的证书校验只在跳过常规校验后才走指纹比对，自签证书必须两个都写 |

---

## 日常运维

所有操作走 `manage.sh`。可以先建个快捷命令：

```sh
ln -sf /opt/hysteria/manage.sh /usr/local/bin/hy2
```

之后 `hy2 show`、`hy2 doctor` 都能用。

### 命令速查

| 命令 | 作用 |
| :-- | :-- |
| `manage.sh show` | 客户端配置 + 链接 + 证书指纹 |
| `manage.sh export` | 生成 Clash Verge 可导入的完整配置 |
| `manage.sh set-port 8443` | 改端口，自动同步客户端配置并重启 |
| `manage.sh set-pass` | 重新生成认证密码与混淆密码 |
| `manage.sh doctor` | 自检：进程、监听、内存、磁盘、证书 |
| `manage.sh autostart` | 安装开机自启 |
| `manage.sh no-autostart` | 移除开机自启 |
| `manage.sh upgrade 2.13.0` | 换二进制，保留配置 |
| `manage.sh start` / `stop` / `restart` / `status` / `log` | 进程管理 |

### 看状态

```sh
manage.sh status
```

```
运行中: supervisor pid=8688 hysteria pid=8694
  VmRSS:            3728 kB
  Threads:      6
  cgroup 限制: 67108864 字节
```

`status` 退出码：`0` 运行中，`3` 未运行，可直接用于脚本判断。

### 自检

```sh
manage.sh doctor
```

一次性检查进程、UDP 监听、内存上限、磁盘、证书文件、指纹。**连不上时先跑这个。**

### 改端口

```sh
manage.sh set-port 2053
```

会自动：备份旧配置 → 改 `config.yaml` → 改 `client.yaml` → 重新生成链接 → 重启服务。

改完记得**在面板放行新的 UDP 端口**。

### 换密码

```sh
manage.sh set-pass
```

自动生成新密码、同步服务端与客户端配置、重启。之后客户端要重新导入（`manage.sh export` 或 `show`）。

### 开机自启

```sh
manage.sh autostart
```

按环境自动选择：

- 有 OpenRC → 写 `/etc/local.d/hysteria.start`
- 有 crontabs → 写 cron 看门狗（每分钟检查，挂了就拉起）

两个都没有（纯容器很常见）会明确告诉你：让提供方在容器启动命令里加 `run.sh start`。

移除：`manage.sh no-autostart`。

> 手动启动也完全够用：`manage.sh start` 一条命令。进程用 `setsid` 脱离会话，SSH 断开不会掉。

### 崩溃与 OOM

- 进程被 kill（含 OOM，退出码 137）→ 3 秒后自动拉起
- 连续 3 次「启动 5 秒内退出」→ 判定配置/端口问题，停止重试并写日志

判断是否被 OOM：

```sh
dmesg -T | grep -i -E 'killed process|out of memory'
```

容器里看不到 dmesg 就看 `manage.sh status` 的 RSS。

真被 OOM 时的处理顺序：

1. 改 `run.sh` 顶部 `GOMEMLIMIT`：`32MiB` → `24MiB`
2. `config.yaml` 窗口再压一档：`1048576` → `524288`，`2621440` → `1310720`
3. `maxIncomingStreams: 64` → `32`
4. 换更大的内存

### 升级

```sh
manage.sh upgrade 2.13.0
```

下载新二进制 → 验证能运行 → 备份旧版为 `hysteria.bak` → 替换 → 重启。配置和密码不动。

### 备份

```sh
tar czf /root/hy2-$(date +%Y%m%d).tar.gz -C /opt/hysteria \
  config.yaml certs client.yaml client-uri.txt clash.yaml
```

恢复：解压回 `/opt/hysteria` 再 `manage.sh restart`。

### 日志

```sh
manage.sh log          # tail -f
```

日志超过 5MB 自动滚动为 `hysteria.log.1`。

---

## 端口与防火墙

三件事互相独立：

| | 需要开端口吗 |
| :-- | :-- |
| **客户端**（电脑/手机） | **不需要**，只在本机 `127.0.0.1:1080` 起本地代理 |
| **服务器** | 需要 **1 个 UDP 端口** |
| **Cloudflare** | 与 hy2 无关，CF 不转发 UDP |

> **最常见的坑**：很多面板的端口转发默认只做 **TCP**。hy2 是纯 UDP，映射成 TCP 就完全不通，症状是客户端一直超时、服务端日志一条连接记录都没有。
>
> 面板里务必确认：协议 = **UDP**，内网端口 = **8443**（与 `--port` 一致），不要映射到 443。

推荐端口：`8443`（首选）、`2053` / `2083` / `2087` / `2096`。避开 53、123、5060。

Cloudflare 支持的那串端口（8443/2053/2083…）是给它代理 HTTPS 用的，**hy2 用不上 CF 转发**，只是这些端口号在网络上比较通畅。

### 怎么确认 UDP 通了

UDP 没有握手，`telnet` / `nc -z` 测不出来。只能这样：

1. 服务器上 `manage.sh doctor` → 确认「已监听」
2. 客户端连 → 日志出现 `connected to server`

一直超时的话，先换端口试，别急着改配置。

---

## 为什么 64MB 能跑

默认配置跑不了。QUIC 接收窗口是**每连接**的内存上限，Hysteria 默认 stream 8MB / conn 20MB，几个连接就吃穿 64MB。

脚本做了四件事：

| 旋钮 | 默认 | 本脚本 |
| :-- | :-- | :-- |
| `quic.*ReceiveWindow` | 8MB / 20MB | **1MB / 2.5MB** |
| `GOMEMLIMIT` | 无 | **32MiB** + `GOGC=50` |
| `GOMAXPROCS` | 核数 | **1** |
| `ignoreClientBandwidth` | false | **true**（统一走 BBR 保守档） |

实测（Alpine 3.24 / amd64 / 64MB 容器）：

| 场景 | 服务端内存 |
| :-- | :-- |
| 空载 | **3.7 MB** |
| 跑满带宽 | 20 MB 上下 |

**吞吐上限 ≈ 窗口 ÷ RTT**。1MB 窗口在 200ms RTT 下约 40 Mbps。实测单流约 19 Mbps、4 并发合计约 22 Mbps，瓶颈在服务器带宽而不是窗口。

内存放宽到 128MB / 256MB 时，把窗口按 **2:5** 放大（如 2MB/5MB、4MB/10MB）再重启。

---

## 证书与域名策略

默认自签 + `obfs: salamander`：整个 QUIC 包被随机化，SNI 和 QUIC 指纹都不出现在线路上，域名零暴露，也不用管续期。客户端用 `insecure: true` 或 `fingerprint` 固定证书。

想用真域名时：

| 封锁形态 | 影响范围 | 牵连主域吗 |
| :-- | :-- | :-- |
| SNI 封锁 | 只用该 SNI 的连接 | 用子域不牵连 |
| IP 封锁 | 解析到该 VPS 的域名 | CF 橙云站点不受影响 |
| DNS 污染 | 该子域解析 | 不影响主域 |

结论：用子域（如 `hy2.example.com`）且**必须 DNS only（灰云）**。

签发建议在本地做，别在 64MB 机器上跑 ACME：

```sh
export CF_Token=你的CF_Token
acme.sh --issue --dns dns_cf -d hy2.example.com --server letsencrypt
acme.sh --install-cert -d hy2.example.com --key-file /tmp/key.pem --fullchain-file /tmp/cert.pem

scp /tmp/cert.pem /tmp/key.pem root@<服务器IP>:/tmp/
ssh root@<服务器IP> sh /tmp/install.sh --cert /tmp/cert.pem --key /tmp/key.pem --sni hy2.example.com
```

替代证书不用重装，直接覆盖再重启：

```sh
manage.sh stop
cp 新cert.pem /opt/hysteria/certs/cert.pem
cp 新key.pem  /opt/hysteria/certs/key.pem
manage.sh start
```

> 从自签换真证书后，要删掉 `config.yaml` 里的 `sniGuard: disable` 那行。

---

## 排障

**客户端一直超时，服务端没有连接记录**

1. 面板端口映射协议是不是 **UDP**
2. 内网端口是不是和 `--port` 一致
3. `manage.sh doctor` 看是否已监听
4. 混淆密码是否一致（不一致也是超时）

**服务起不来**

```sh
manage.sh check      # 只验配置，起 3 秒就关
```

注意 `check` 会绑同一端口，**服务在跑时要先 stop**。

**卡在 3/6 准备证书**

容器没 `openssl` 且 `apk add` 失败。新版会打印 apk 的报错原因和两条处理路径。最快解法：在本地生成证书传上去，用 `--cert/--key` 走「复用已有证书」分支。

**装完客户端还是连不上，但 doctor 显示已监听**

问题在面板映射，不在服务端。

**重启服务器后连不上**

进程没自启。`manage.sh autostart`，或每次重启后手动 `manage.sh start`。

**内存持续上涨 / 进程消失**

见 [崩溃与 OOM](#崩溃与-oom)。

---

## 卸载

```sh
manage.sh stop
manage.sh no-autostart
rm -rf /opt/hysteria
rm -f /usr/local/bin/hy2
```

---

## 说明

- 默认 hysteria `v2.13.0`，配置字段以[官方文档](https://v2.hysteria.network/)为准
- 只依赖 POSIX sh 与 busybox applet；已在 macOS `sh` / `dash` 下跑通完整流程
- 证书指纹用纯 shell 计算（PEM → DER → sha256），不需要 `openssl`，结果与 `openssl x509 -fingerprint -sha256` 一致
- 修改配置一律先备份为 `*.bak.<时间戳>`，写入后回读校验
- `config.yaml` / `client.yaml` / `clash.yaml` 含密码，权限 600，别提交到仓库

---

## License

[MIT](LICENSE)
