module("luci.controller.campusauth", package.seeall)

function index()
    entry({ "admin", "services", "campusauth" }, cbi("campusauth/general"),
          _("校园网认证"), 60)
    entry({ "admin", "services", "campusauth", "status" }, call("action_status")).leaf = true
    entry({ "admin", "services", "campusauth", "login" }, call("action_login")).leaf = true
    entry({ "admin", "services", "campusauth", "logout" }, call("action_logout")).leaf = true
    entry({ "admin", "services", "campusauth", "log" }, call("action_log")).leaf = true
end

local function out(plain)
    local http = require("luci.http")
    http.prepare_content("text/plain; charset=utf-8")
    http.write(plain)
end

function action_status()
    local f = io.open("/tmp/campus-auth.status", "r")
    if f then
        local t = f:read("*a")
        f:close()
        out(t)
    else
        out("state=unknown\ndetail=尚未执行过检测\n")
    end
end

function action_login()
    local sys = require("luci.sys")
    local rc
    local txt = sys.exec("/usr/bin/campus-auth login 2>&1; echo rc=$?")
    local f = io.open("/tmp/campus-auth.status", "r")
    if f then
        rc = f:read("*a")
        f:close()
    end
    out((rc or "") .. "\n---\n" .. txt)
end

function action_logout()
    local sys = require("luci.sys")
    out(sys.exec("/usr/bin/campus-auth logout 2>&1; echo rc=$?"))
end

function action_log()
    local sys = require("luci.sys")
    out(sys.exec("logread -e campus-auth 2>&1 | tail -n 30"))
end
