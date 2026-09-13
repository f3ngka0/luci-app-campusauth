local m, s, o

local fs = require("nixio.fs")
local sys = require("luci.sys")

local ISP_NAMES = {
    ["0"] = "校园网",
    ["1"] = "中国移动",
    ["2"] = "中国电信",
    ["3"] = "中国联通",
    ["4"] = "中国广电",
}

local STATE_TEXT = {
    online  = '<span style="color:#2f8f3f;font-weight:bold">已在线</span>',
    offline = '<span style="color:#c33;font-weight:bold">已掉线</span>',
    unknown = '<span style="color:#a60">未知</span>',
}

m = Map("campusauth",
        translate("校园网认证"),
        translate("自动检测校园网掉线并重新登录。认证协议为 Dr.COM Portal，" ..
                  "登录请求直接发往认证服务器，不依赖浏览器页面。"))

s = m:section(TypedSection, "campusauth", translate("账号与登录方式"))
s.addremove = false
s.anonymous = true

o = s:option(Flag, "enabled", translate("启用自动登录"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "username", translate("账号"),
             translate("校园网上网账号（通常是学号）"))
o.rmempty = false
o.placeholder = translate("上网账号 / 学号")

o = s:option(Value, "password", translate("密码"),
             translate("Portal 要求明文传输，因此只能明文保存在路由器上"))
o.password = true
o.rmempty = false

o = s:option(ListValue, "isp", translate("登录方式"))
o:value("0", translate("校园网"))
o:value("1", translate("中国移动"))
o:value("2", translate("中国电信"))
o:value("3", translate("中国联通"))
o:value("4", translate("中国广电"))
o.default = "0"

s = m:section(TypedSection, "campusauth", translate("检测参数"))
s.addremove = false
s.anonymous = true

o = s:option(Value, "server", translate("认证服务器"),
             translate("你学校 Dr.COM Portal 的地址。抓一次登录过程，" ..
                       "或看浏览器登录页的地址栏就能拿到；各校不同，所以没有内置默认值。"))
o.datatype = "ipaddr"
o.rmempty = false

o = s:option(Value, "iface", translate("WAN 接口"),
             translate("校园网 IP 所在的逻辑接口，中继上网通常是 wwan"))
o.default = "wwan"

o = s:option(Value, "interval", translate("检测间隔（秒）"),
             translate("连续失败时会自动翻倍退避，最大 32 倍"))
o.default = "30"
o.datatype = "and(uinteger,min(10))"

o = s:option(Value, "ping_host", translate("连通性探测地址"),
             translate("先用 ping 快速判断，失败后再问认证服务器确认"))
o.default = "223.5.5.5"

s = m:section(SimpleSection, translate("运行状态"))

o = s:option(DummyValue, "_state", translate("当前状态"))
o.rawhtml = true
o.cfgvalue = function()
    local txt = fs.readfile("/tmp/campus-auth.status") or ""
    local state = txt:match("state=([%w_-]+)") or "unknown"
    local detail = txt:match("detail=([^\n]*)") or ""
    local wan = txt:match("wan_ip=([^\n]*)") or ""
    local upd = txt:match("updated=([^\n]*)") or ""
    local isp = m.uci:get("campusauth", "main", "isp") or "0"
    local last = m.uci:get("campusauth", "main", "last_login") or "从未"
    local res = m.uci:get("campusauth", "main", "last_result") or ""

    local html = "<table style='border-collapse:collapse'>"
    html = html .. "<tr><td style='padding:2px 10px 2px 0;color:#666'>状态</td><td>"
            .. (STATE_TEXT[state] or STATE_TEXT.unknown) .. "</td></tr>"
    if detail ~= "" then
        html = html .. "<tr><td style='padding:2px 10px 2px 0;color:#666'>说明</td><td>"
                .. luci.util.pcdata(detail) .. "</td></tr>"
    end
    html = html .. "<tr><td style='padding:2px 10px 2px 0;color:#666'>登录方式</td><td>"
            .. (ISP_NAMES[isp] or isp) .. "</td></tr>"
    html = html .. "<tr><td style='padding:2px 10px 2px 0;color:#666'>WAN IP</td><td>"
            .. luci.util.pcdata(wan) .. "</td></tr>"
    html = html .. "<tr><td style='padding:2px 10px 2px 0;color:#666'>上次登录</td><td>"
            .. luci.util.pcdata(last) .. (res ~= "" and ("（" .. luci.util.pcdata(res) .. "）") or "")
            .. "</td></tr>"
    html = html .. "<tr><td style='padding:2px 10px 2px 0;color:#666'>状态更新</td><td>"
            .. luci.util.pcdata(upd) .. "</td></tr>"
    html = html .. "</table>"
    return html
end

-- ---------------------------------------------------------------------------
-- uplink watchdog (see /usr/bin/net-watchdog)
--
-- Kept separate from the campus-auth status above on purpose: losing the WAN
-- address (DHCP lease) is a different failure from losing the portal session,
-- and during an outage UA3F floods syslog with "network is unreachable" so
-- logread is useless as evidence. The watchdog keeps its own record.
-- ---------------------------------------------------------------------------

local WD_STATE = {
    OK      = '<span style="color:#2f8f3f;font-weight:bold">正常</span>',
    NOINET  = '<span style="color:#a60;font-weight:bold">有 IP 但上不了网</span>',
    NOROUTE = '<span style="color:#c33;font-weight:bold">无默认路由</span>',
    NOIP    = '<span style="color:#c33;font-weight:bold">无 IP（租约丢失）</span>',
    NOLINK  = '<span style="color:#c33;font-weight:bold">无线未关联</span>',
}

s = m:section(SimpleSection, translate("上行链路看门狗"),
              translate("独立于系统日志记录上行状态，并在 DHCP 租约丢失时自动恢复" ..
                        "（重新续租 → 重启接口 → 强制重连 → 重载无线）。" ..
                        "断网时 UA3F 会把系统日志刷爆，所以这里是唯一可靠的现场记录。"))

o = s:option(DummyValue, "_wd_state", translate("链路状态"))
o.rawhtml = true
o.cfgvalue = function()
    local txt = fs.readfile("/tmp/net-watchdog.status")
    if not txt then
        return '<span style="color:#a60">看门狗未运行</span>'
    end
    local st      = txt:match("state=([^\n]*)") or "unknown"
    local iface   = txt:match("iface=([^\n]*)") or "-"
    local dev     = txt:match("device=([^\n]*)") or "-"
    local ip      = txt:match("ip=([^\n]*)") or "-"
    local gw      = txt:match("gateway=([^\n]*)") or "-"
    local asoc    = txt:match("associated=([^\n]*)") or "-"
    local downfor = tonumber(txt:match("down_for=([^\n]*)")) or 0
    local acts    = txt:match("actions=([^\n]*)") or "0"
    local upd     = txt:match("updated=([^\n]*)") or ""

    local cell = "padding:2px 10px 2px 0;color:#666"
    local html = "<table style='border-collapse:collapse'>"
    html = html .. "<tr><td style='" .. cell .. "'>状态</td><td>"
            .. (WD_STATE[st] or ("<b>" .. luci.util.pcdata(st) .. "</b>")) .. "</td></tr>"
    html = html .. "<tr><td style='" .. cell .. "'>接口</td><td>"
            .. luci.util.pcdata(iface) .. " / " .. luci.util.pcdata(dev) .. "</td></tr>"
    html = html .. "<tr><td style='" .. cell .. "'>WAN IP</td><td>"
            .. luci.util.pcdata(ip) .. "（网关 " .. luci.util.pcdata(gw) .. "）</td></tr>"
    html = html .. "<tr><td style='" .. cell .. "'>无线关联</td><td>"
            .. (asoc == "1" and "已连接" or "未连接") .. "</td></tr>"
    if downfor > 0 then
        html = html .. "<tr><td style='" .. cell .. "'>异常持续</td><td style='color:#c33'>"
                .. downfor .. " 秒</td></tr>"
    end
    html = html .. "<tr><td style='" .. cell .. "'>累计恢复动作</td><td>"
            .. luci.util.pcdata(acts) .. " 次</td></tr>"
    html = html .. "<tr><td style='" .. cell .. "'>采样时间</td><td>"
            .. luci.util.pcdata(upd) .. "</td></tr>"
    return html .. "</table>"
end

o = s:option(DummyValue, "_wd_journal", translate("链路事件记录"))
o.rawhtml = true
o.cfgvalue = function()
    local j = sys.exec("/usr/bin/net-watchdog journal 2>/dev/null | tail -n 14")
    if not j or j == "" then
        j = "（暂无事件记录，说明上行一直正常）"
    end
    local raw = sys.exec("/usr/bin/net-watchdog log 2>/dev/null | tail -n 40")
    if not raw or raw == "" then
        raw = "（暂无采样）"
    end
    local box = "max-height:240px;overflow:auto;background:#f7f7f7;" ..
                "padding:8px;border-radius:4px;font-size:12px"
    return "<pre style='" .. box .. "'>" .. luci.util.pcdata(j) .. "</pre>"
           .. "<details><summary style='cursor:pointer;color:#666;font-size:12px'>"
           .. translate("原始采样（最近 40 条）") .. "</summary>"
           .. "<pre style='" .. box .. "'>" .. luci.util.pcdata(raw) .. "</pre></details>"
           .. "<div style='color:#888;font-size:12px;margin-top:4px'>"
           .. translate("事件记录持久保存在 /etc/net-watchdog.journal，重启不丢；" ..
                        "原始采样在 RAM 中滚动保留。") .. "</div>"
end

o = s:option(DummyValue, "_actions", translate("手动操作"))
o.rawhtml = true
o.cfgvalue = function()
    -- NOTE: this block is quoted with [==[ ... ]==] on purpose.
    -- The embedded JS ends with //]]> which contains ]] and would
    -- terminate a plain [[ ... ]] long string early (Lua 5.1 syntax error).
    return [==[
<button class="btn cbi-button cbi-button-apply" id="ca_login">立即登录</button>
<button class="btn cbi-button cbi-button-reset" id="ca_logout">注销</button>
<button class="btn cbi-button" id="ca_refresh">刷新状态</button>
<span id="ca_result" style="margin-left:10px;color:#666"></span>
<script type="text/javascript">//<![CDATA[
(function(){
  var base = location.href.replace(/\?.*$/, '').replace(/\/(login|logout|status|log)$/, '');
  function go(act){
    var el = document.getElementById('ca_result');
    if(!el){ return; }
    el.textContent = '执行中…';
    fetch(base + '/' + act, {credentials:'same-origin'})
      .then(function(r){ return r.text(); })
      .then(function(t){
        el.textContent = t.replace(/\n+/g, ' | ').substring(0, 220);
        setTimeout(function(){ location.reload(); }, 1500);
      })
      .catch(function(e){ el.textContent = '请求失败：' + e; });
  }
  function bind(id, act){
    var b = document.getElementById(id);
    if(b){ b.onclick = function(){ go(act); return false; }; }
  }
  bind('ca_login', 'login');
  bind('ca_logout', 'logout');
  bind('ca_refresh', 'status');
})();
//]]></script>]==]
end

o = s:option(DummyValue, "_logs", translate("认证事件记录"))
o.rawhtml = true
o.cfgvalue = function()
    local box = "max-height:220px;overflow:auto;background:#f7f7f7;" ..
                "padding:8px;border-radius:4px;font-size:12px"
    local j = sys.exec("/usr/bin/campus-auth journal 2>/dev/null | tail -n 16")
    if not j or j == "" then
        j = "（暂无事件记录）"
    end
    local t = sys.exec("logread -e campus-auth 2>/dev/null | tail -n 12")
    if not t or t == "" then
        t = "（暂无系统日志）"
    end
    return "<pre style='" .. box .. "'>" .. luci.util.pcdata(j) .. "</pre>"
           .. "<details><summary style='cursor:pointer;color:#666;font-size:12px'>"
           .. translate("系统日志（可能已被冲掉）") .. "</summary>"
           .. "<pre style='" .. box .. "'>" .. luci.util.pcdata(t) .. "</pre></details>"
           .. "<div style='color:#888;font-size:12px;margin-top:4px'>"
           .. translate("事件记录持久保存在 /etc/campus-auth.journal，重启不丢。") .. "</div>"
end

return m
