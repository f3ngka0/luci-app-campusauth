# luci-app-campusauth

**校园网 Dr.COM Portal 自动登录插件（OpenWrt / ImmortalWrt LuCI 应用）**

断线自动重登，附带一个「上行链路看门狗」—— 因为**上行丢了 DHCP 租约时根本没有路由到认证服务器**，光靠重登是救不回来的。

> **English:** A LuCI app that keeps a Dr.COM campus portal session alive. It
> polls the portal, detects a dropped session and logs back in automatically.
> It ships with a companion uplink watchdog, because the most common failure is
> not the portal session but a **lost DHCP lease on the WAN** — which leaves the
> router with no route to the portal at all. The watchdog records WAN health to
> a durable journal (syslog is useless during an outage) and recovers the
> uplink by itself.

---

## 功能

- **自动重登**：检测掉线，自动重新登录 Dr.COM Portal，支持 5 种登录方式
  （校园网 / 中国移动 / 中国电信 / 中国联通 / 中国广电，对应 R3 字段 0–4）。
- **双层检测**：先 `ping` 一个公共地址，失败再问 portal 的 `chkstatus` 接口。
  很多校园网关屏蔽 ICMP，纯 ping 判断会一直误报，所以 ping 失败**不足以**触发登录。
- **分级退避**：连续失败时检测间隔按 1×2×4×… 退避（上限 32×），不会把认证服务器打爆；
  但**上行没有 IP 时保持快速轮询**，避免网络恢复后还等十几分钟才重登。
- **LuCI 页面**：`服务 → 校园网认证`，可填账号/密码/登录方式，有手动登录、
  注销、刷新按钮，以及运行状态与事件记录。
- **持久化事件记录**：`/etc/campus-auth.journal`，重启不丢。
- **配套上行看门狗**：记录上行健康状态并自动恢复（见下文）。

## 环境要求

- OpenWrt 21.02 及以上 / ImmortalWrt（`firewall4` + `nftables` 或 `iptables` 均可，
  本插件不依赖防火墙能力）。
- `luci-compat`（Lua CBI 模型需要）。
- `wget`（busybox 自带或 `uclient-fetch` 提供）。
- 已能正常访问校园网认证服务器（抓包确认过协议）。

依赖 `ip`、`ubus`、`iw`、`ping`、`logger` —— 都是 OpenWrt 基础组件。

## 目录结构

```
luci-app-campusauth/
├── Makefile                         # OpenWrt 包定义（放进 luci feed 后可编译成 ipk）
├── LICENSE
├── README.md
├── .gitignore
└── root/                            # 会被安装到路由器根目录的内容
    ├── etc/
    │   ├── config/campusauth        # UCI 默认配置（不含任何凭据）
    │   └── init.d/
    │       ├── campusauth           # procd 服务：认证守护进程
    │       └── net-watchdog         # procd 服务：上行看门狗
    └── usr/
        ├── bin/
        │   ├── campus-auth          # 主脚本：status|login|logout|check|daemon|journal
        │   └── net-watchdog         # 看门狗：run|once|status|log|journal
        ├── lib/lua/luci/
        │   ├── controller/campusauth.lua
        │   └── model/cbi/campusauth/general.lua
        └── share/rpcd/acl.d/
            └── luci-app-campusauth.json
```

> 仓库里的 `root/etc/config/campusauth` **凭据字段是空的**，`server` 也是空的
> （各校地址不同，故意不给默认值）。装完必须自己填。

## 安装

### 方式 A：直接把文件拷到路由器（最快）

```sh
# 在路由器上（或先传到路由器再执行）
cd /tmp
wget -O - https://github.com/<you>/luci-app-campusauth/archive/refs/heads/main.tar.gz | tar xz
cd luci-app-campusauth-main/root

# 拷文件并修正换行符（脚本必须是 LF，不能有 CRLF）
for f in $(find . -type f); do
    mkdir -p "$(dirname "/$f")"
    tr -d '\r' < "$f" > "/$f"
done

chmod 755 /usr/bin/campus-auth /usr/bin/net-watchdog \
          /etc/init.d/campusauth /etc/init.d/net-watchdog
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
```

然后编辑 `/etc/config/campusauth`（至少填 `server`、`username`、`password`），再：

```sh
/etc/init.d/campusauth enable
/etc/init.d/net-watchdog enable
/etc/init.d/campusauth start
/etc/init.d/net-watchdog start
```

刷新 LuCI，菜单里会出现 **服务 → 校园网认证**。

### 方式 B：编译成 ipk

把本目录放进 luci feed：

```
feeds/luci/applications/luci-app-campusauth/
```

然后在 OpenWrt 源码根目录：

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig     # LuCI -> Applications -> luci-app-campusauth
make package/luci-app-campusauth/compile V=s
```

产物在 `bin/packages/*/luci/luci-app-campusauth_*.ipk`。

## 配置

### UCI 选项（`/etc/config/campusauth`）

| 选项 | 默认 | 说明 |
|---|---|---|
| `enabled` | `1` | 是否开机启动守护进程 |
| `username` | 空 | 上网账号（通常是学号） |
| `password` | 空 | 上网密码。**协议要求明文 HTTP GET，无法加密存储** |
| `isp` | `0` | 登录方式：0=校园网 1=移动 2=电信 3=联通 4=广电 |
| `server` | 空 | 认证服务器地址，**必填**，各校不同 |
| `iface` | `wwan` | 持有校园网 IP 的逻辑接口（无线中继上网通常是 `wwan`） |
| `interval` | `30` | 检测间隔（秒），连续失败会退避 |
| `ping_host` | `223.5.5.5` | 快速探测目标（公共 DNS，非私人地址） |
| `last_login` / `last_result` | — | 运行状态，脚本自动写入，不用手改 |

命令行方式：

```sh
uci set campusauth.main.server='<你学校的认证服务器地址>'
uci set campusauth.main.username='<账号>'
uci set campusauth.main.password='<密码>'
uci set campusauth.main.isp='0'
uci commit campusauth
/etc/init.d/campusauth restart
```

### 手动操作

```sh
campus-auth status      # 问 portal：1=在线 0=离线
campus-auth login       # 立即登录
campus-auth logout      # 注销
campus-auth check       # 单次检测（掉线则登录）
campus-auth journal     # 看持久化事件记录
net-watchdog status     # 上行状态
net-watchdog journal    # 上行事件 + 恢复动作
net-watchdog log        # 最近采样（RAM）
```

## 它是怎么工作的

### 协议

Dr.COM Portal（服务端标识 `DrcomServer1.2`），**登录请求是明文 HTTP GET**：

| 接口 | 响应 |
|---|---|
| `GET /drcom/login?...` | `result:1` = 登录成功；`result:0` + `msga:"clientip online"` = 本来就在线 |
| `GET /drcom/chkstatus?...` | `result:1` = 在线；`result:0` = 离线 |
| `GET /drcom/logout?...` | `result:1` = 注销成功 |

服务端**只校验** `DDDDD`（账号）、`upass`（密码）、`R3`（运营商）、`wlan_user_ip`
四个字段；`program_index`、`page_index`、`rcn`、`user_agent` 之类都不校验
（实测：极简请求也能拿到结构完整的正常响应）。响应是 JSONP，外层包一层
`dr1003({...})`，所以解析用正则取 `"result"` 即可。

### 检测逻辑

```
ping ping_host 成功            → 在线，不做任何事
ping 失败 且 上行没有 IP        → 不是 portal 的问题（没有路由），交给看门狗，跳过
ping 失败 → 问 portal chkstatus
    result=1                   → 在线（校园网关掉了 ICMP，只是探测失败）
    其它                       → 掉线，执行登录
```

「ping 失败但 portal 说在线」这个分支很重要：校园网关常屏蔽 ICMP，
如果只信 ping，会每 30 秒无意义地登录一次。

### 为什么要区分「没有 IP」和「portal 掉线」

这是实践中踩出来的：

- **portal 掉线**：上行有 IP、有路由，只是认证会话过期 → 重登即可。
- **上行丢租约**：路由器**没有 WAN 地址，也就没有默认路由**，
  连 `http://<认证服务器>/` 都打不开 —— 表现和「认证服务器挂了」一模一样，
  但实际上**根本无法发出登录请求**。此时重登多少次都没用，
  必须先拿回 DHCP 租约。

校园网 DHCP 租期可能很短（见过约 2 小时的），续租失败的概率不低，
所以第二种情况并不罕见。本插件在检测到「无 WAN IP」时会明确报告，
并把恢复工作交给配套的上行看门狗。

## 上行看门狗（net-watchdog）

每 30 秒采样一次上行状态，写入两份记录：

| 文件 | 介质 | 内容 | 写入频率 |
|---|---|---|---|
| `/tmp/net-watchdog.log` | RAM | 每 30 s 一条完整采样 | 滚动保留 3000 行，重启丢 |
| `/etc/net-watchdog.journal` | flash | 状态**变化** + 恢复动作 | 变化时 + 异常期间每 5 min |

**为什么不直接看 syslog**：上行断开时，透明代理类插件（如 UA3F）会以每秒几十条
的速度刷 `network is unreachable`，几十 KB 的 syslog 环形缓冲几分钟就被冲光，
几小时前的事故现场**一点都查不到**。dmesg 也帮不上忙——wpa_supplicant 的事件走
syslog，不进内核环缓冲。所以要自己留一份。

### 状态定义

| 状态 | 含义 |
|---|---|
| `OK` | 有 IP、有默认路由、能 ping 通 |
| `NOINET` | 有 IP 有路由但 ping 不通 → 通常是 portal 掉线，**看门狗不动手** |
| `NOROUTE` | 有 IP 但没有默认路由 |
| `NOIP` | 已关联但没有 IPv4 地址（租约丢了） |
| `NOLINK` | 无线设备未关联 |

### 恢复阶梯

| 触发 | 阈值 | 动作 |
|---|---|---|
| `NOIP` / `NOROUTE` | ≥60 s | `ubus call network.interface.<if> renew`（每 2 min 一次） |
| 同上 | ≥240 s | 接口 `down` + `up`（每 10 min 一次） |
| `NOLINK`（仅无线） | ≥120 s | `iw dev <sta> disconnect` 强制重连（每 5 min 一次） |
| 任意异常态 | ≥900 s | `ubus call network.wireless reconf`（每 30 min 一次） |

所有恢复命令都用 `setsid` 甩到独立会话执行，避免"重配网络把自己的 shell 弄死"。

> ⚠️ 接口 `down/up` 会重启该接口所在射频；如果本机 AP 和上行 STA 在同一射频上，
> 你的 Wi-Fi 会中断约 10 秒。这是最后手段，只在断网超过 4 分钟时触发。

### 演练模式（安全验证恢复逻辑）

不要拿真实链路去试恢复动作。看门狗支持环境变量覆盖与 DRY-RUN，
可以用一个无害接口把整个阶梯跑一遍：

```sh
NET_WD_SUFFIX=-test NET_WD_DRY=1 NET_WD_IFACE=wan NET_WD_INTERVAL=5 \
NET_WD_SETTLE=2 NET_WD_T_RENEW=10 NET_WD_T_BOUNCE=20 NET_WD_T_RECONF=9999 \
NET_WD_CD_RENEW=15 NET_WD_CD_BOUNCE=25 \
setsid /usr/bin/net-watchdog run >/dev/null 2>&1 &

# 等 60 秒，看它是否按顺序触发了 renew / bounce
cat /etc/net-watchdog-test.journal

# 清场（procd 会自动把真实例拉回来）
killall net-watchdog
rm -f /tmp/net-watchdog-test.log /etc/net-watchdog-test.journal
```

可覆盖的变量：`SUFFIX` `DRY` `INTERVAL` `SETTLE` `IFACE`
`T_RENEW` `T_BOUNCE` `T_REASSOC` `T_RECONF` `CD_RENEW` `CD_BOUNCE`
`CD_REASSOC` `CD_RECONF`。

## 换个学校怎么适配

参数名（`DDDDD` / `upass` / `R3` / `wlan_user_ip`）在不同学校的 Dr.COM
部署里可能不同，所以第一步是抓一次你自己的登录：

```sh
# 在路由器上装抓包工具
opkg update && opkg install tcpdump

# 抓「与认证服务器的全部流量」。把 <portal-ip> 换成你学校的认证服务器地址。
# 先注销、确认断网，再在浏览器里重新登录一次，完整流程都要抓到。
tcpdump -i <wan-if> -nn -A -s0 -c 200 'host <portal-ip> and tcp port 80' > /tmp/portal.txt 2>&1

# 找 GET 请求
grep -o 'GET /[^ ]*' /tmp/portal.txt | head
```

> 抓到的包里**含明文密码**，分析完请立刻删除：`rm -f /tmp/portal.txt`。

拿到的 `GET /drcom/login?...` 那一行就是全部参数。对照
`/usr/bin/campus-auth` 里的 `do_login()` 改：
- 参数名不同 → 改 URL 拼接那几行；
- 运营商字段不同 → 改 `R3` 的取值和 LuCI 里的下拉项；
- 接口路径不同（有的学校是 `/drcom/login`，有的是 `/?user_account=...`）→ 改路径。

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 状态一直是「认证服务器地址未配置」 | `server` 没填，或填错。抓包确认地址 |
| 「上行无 IP，等待重新获取租约」 | 上行丢了 DHCP 租约，看 `net-watchdog journal` 有没有恢复动作 |
| 「探测失败但认证在线」 | 校园网关屏蔽 ICMP，属正常，不会误触发登录 |
| 登录返回 `result:0` 且 `msga` 含 online | 服务端说本来就在线，脚本已兼容，不是错误 |
| 登录返回 `result:0`，`msga` 是别的 | 账号/密码/运营商选错，或该账号已在别处登录 |
| `logread` 里查不到历史 | 很正常，syslog 会被刷爆。看 `campus-auth journal` |
| LuCI 页面 404 | `rm -rf /tmp/luci-indexcache /tmp/luci-modulecache` 后刷新 |
| 脚本报 `not found` / 语法错误 | 文件带 CRLF。`tr -d '\r' < f > f.tmp && mv f.tmp f` |

## 隐私与安全

- **本仓库不含任何真实凭据**：账号、密码、学号、姓名、邮箱、手机号、
  MAC、SSID、公网/内网 IP、Cookie、Token、本地绝对路径**均已移除**，
  相关位置改用占位符或留空。
- **`server` 故意没有默认值**。上游代码里曾经硬编码一个私网地址作为兜底，
  那会让别人家的路由器去访问一个不存在的内网主机；现在为空则由脚本明确报错。
- 唯一保留的 IP 字面量是 `223.5.5.5`（阿里公共 DNS），仅作为
  “先做一次廉价连通性探测”的默认目标，可在 `ping_host` 里改成任意你信任的地址。
- **密码是明文存储的**：Dr.COM 的登录请求本身就把密码放在 URL 查询串里，
  插件无法加密它。请把路由器的管理密码设置得足够强，
  不要把带凭据的 `/etc/config/campusauth` 分享出去，也不要提交进版本库。
- 抓包文件（`*.pcap`）已在 `.gitignore` 中排除 —— 它们含明文密码。
- 建议在路由器上限制 LuCI 的访问来源，或改用 HTTPS + 强口令。

## 许可

MIT，见 [LICENSE](LICENSE)。
