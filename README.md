# luci-app-campusauth

**校园网 Dr.COM Portal 自动登录插件（OpenWrt / ImmortalWrt LuCI 应用）**

## 功能

- **自动重登**：检测掉线，自动重新登录 Dr.COM Portal，支持 5 种登录方式
  （校园网 / 中国移动 / 中国电信 / 中国联通 / 中国广电，对应 R3 字段 0–4）。
- **双层检测**：先做一次 **HTTP 探测**（不是 ping —— 校园网关常丢弃 ICMP），
  失败再问 portal 的 `chkstatus` 接口。ICMP 只作最后参考，单独的 ping 失败
  **不足以**触发登录。
- **分级退避**：连续失败时检测间隔按 1×2×4×… 退避（上限 32×），不会把认证服务器打爆；
  但**上行没有 IP 时保持快速轮询**，避免网络恢复后还等十几分钟才重登。
- **LuCI 页面**：`服务 → 校园网认证`，可填账号/密码/登录方式，有手动登录、
  注销、刷新按钮，以及运行状态与事件记录。
- **持久化事件记录**：`/etc/campus-auth.journal`，重启不丢。
- **上行看门狗**：记录上行健康状态并自动恢复。

## 环境要求

- OpenWrt 21.02 及以上 / ImmortalWrt（`firewall4` + `nftables` 或 `iptables` 均可，
  本插件不依赖防火墙能力）。
- `luci-compat`（Lua CBI 模型需要）。
- `wget`（busybox 自带或 `uclient-fetch` 提供）。
- 已能正常访问校园网认证服务器。

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
    │   ├── config/
    │   │   ├── campusauth           # UCI 默认配置（不含任何凭据）
    │   │   └── netwatchdog          # 看门狗开关（破坏性恢复默认关闭）
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
| `probe_url` | `http://www.baidu.com/` | **活性探测目标（HTTP GET）**。见「为什么不用 ping」 |
| `ping_host` | `223.5.5.5` | 备用信号，仅在认证服务器也无响应时参考 |
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
上行没有 IP                        → 不是 portal 的问题（没有路由），交给看门狗，跳过
HTTP 探测（probe_url）成功          → 在线，不做任何事
HTTP 探测失败 → 问 portal chkstatus
    result=1                       → 在线（外网不通但认证还在）
    result=0                       → 掉线，执行登录
    portal 也无响应 → ping 作参考
        ping 通                    → 网络可用，只是 portal 挂了，不折腾
        ping 不通                  → 执行登录
```

**最后一步的 ICMP 只作参考**，单独的 ping 失败**不会**触发登录。

### 为什么不用 ping 判断在线（重要）

这是踩出来的教训。校园网关经常限速甚至直接丢弃 ICMP。在某校园网上行实测，
**同一时刻**：

| 探测方式 | 结果 |
|---|---|
| TCP（HTTP GET 外网） | **6/6 成功** |
| ICMP → 114.114.114.114 | **100% 丢包** |
| ICMP → 223.5.5.5 | 10% 丢包 |

也就是说**网络完全正常，但 ping 大面积失败**。如果拿 ping 当主探测，就会把正常
网络判成离线：既会反复做无用的登录，也会触发看门狗的恢复动作 —— 而恢复动作
（重启接口）会把本地 AP 一起带下去，把「能上网」变成「真上不了网」。

所以活性探测是 **HTTP GET**（`probe_url`），ICMP 只在 portal 也无响应时作参考。

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

活性探测同样是 **HTTP GET**（`probe_url`），不用 ICMP，原因见上文。

| 状态 | 含义 |
|---|---|
| `OK` | 接口已启用 + 已关联 + 有 IPv4 + 有默认路由 + HTTP 探测通 |
| `IFDOWN` | netifd 认为接口未启用，或该接口没有设备 |
| `NOLINK` | 上行设备未关联 / 无载波 |
| `NOIP` | 已关联但没有可用 IPv4 地址或没有默认路由 |
| `NOHTTP` | 地址和路由都正常，但外网取不到任何东西 |

### 恢复阶梯

**每次采样只执行一个动作**，从最便宜的往上选：

| 状态 | 阈值 | 动作 |
|---|---|---|
| `IFDOWN` | ≥60 s | `ubus call network.interface.<if> up`（每 3 min 一次） |
| `NOLINK`（仅无线） | ≥120 s | `iw dev <sta> disconnect` 强制重连（每 5 min 一次） |
| `NOIP` | ≥90 s | `ubus call network.interface.<if> renew`（每 3 min 一次） |
| `NOHTTP` | ≥600 s | `ubus call network.interface.<if> renew`（每 10 min 一次） |

所有恢复命令都用 `setsid` 甩到独立会话执行，避免"重配网络把自己的 shell 弄死"。

### 刻意**不**自动做的事

接口 `down` + `up` 和 `wireless reconf` **默认关闭**，需要在
`/etc/config/netwatchdog` 里把 `allow_rebounce` 设为 `1` 才启用。

原因很实际：本机 AP 和上行 STA 常常在**同一个射频**上，把接口按下去会重启整个
射频，于是**连正在排查问题的那台设备也被踢下线**；而且接口重新 up 之后可能好
几分钟都拿不到 DHCP 租约。在一个校园网上，一次这样的"恢复"直接造成了
**11 分钟**的完全断网 —— 比它想修的问题还严重。

上面四个安全动作（`up` / `renew` / `disconnect`）不受影响，始终启用。


## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 状态一直是「认证服务器地址未配置」 | `server` 没填，或填错。抓包确认地址 |
| 「上行无 IP，等待重新获取租约」 | 上行丢了 DHCP 租约，看 `net-watchdog journal` 有没有恢复动作 |
| 「外网探测失败但认证在线」 | 校园网关屏蔽 ICMP 或只放行校内，属正常，不会误触发登录 |
| 登录返回 `result:0` 且 `msga` 含 online | 服务端说本来就在线，脚本已兼容，不是错误 |
| 登录返回 `result:0`，`msga` 是别的 | 账号/密码/运营商选错，或该账号已在别处登录 |
| `logread` 里查不到历史 | 很正常，syslog 会被刷爆。看 `campus-auth journal` |
| LuCI 页面 404 | `rm -rf /tmp/luci-indexcache /tmp/luci-modulecache` 后刷新 |
| 脚本报 `not found` / 语法错误 | 文件带 CRLF。`tr -d '\r' < f > f.tmp && mv f.tmp f` |


## 许可

MIT，见 [LICENSE](LICENSE)。
