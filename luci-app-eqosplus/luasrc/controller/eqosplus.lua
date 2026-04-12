module("luci.controller.eqosplus", package.seeall)
-- Copyright 2022-2025 lava <byl0561@gmail.com>

local allowed_pkgs = { ["kmod-dummy"] = true, ["kmod-veth"] = true }

function index()
    if not nixio.fs.access("/etc/config/eqosplus") then return end
    local e = entry({"admin", "services", "eqosplus"}, cbi("eqosplus"), _("Eqosplus"), 10)
    e.dependent=false
    e.acl_depends = { "luci-app-eqosplus" }
    entry({"admin", "services", "eqosplus", "status"}, call("act_status")).leaf = true
    entry({"admin", "services", "eqosplus", "get_log"}, call("act_get_log")).leaf = true
    entry({"admin", "services", "eqosplus", "diag"}, call("act_diag")).leaf = true
    entry({"admin", "services", "eqosplus", "check_dep"}, call("act_check_dep")).leaf = true
    entry({"admin", "services", "eqosplus", "install_dep"}, call("act_install_dep")).leaf = true
    entry({"admin", "services", "eqosplus", "run_test"}, call("act_run_test")).leaf = true
    entry({"admin", "services", "eqosplus", "run_traffic_test"}, call("act_run_traffic_test")).leaf = true
end

function act_status()
    local sys = require "luci.sys"
    local e = {}
    e.status = sys.call("busybox ps -w | grep eqosplus | grep -v grep >/dev/null") == 0
    luci.http.prepare_content("application/json")
    luci.http.write_json(e)
end

function act_get_log()
    local fs = require "nixio.fs"
    luci.http.prepare_content("application/json")
    luci.http.write_json({log = fs.readfile("/tmp/eqosplus.log") or ""})
end

function act_diag()
    local sys = require "luci.sys"
    luci.http.prepare_content("application/json")
    luci.http.write_json({output = sys.exec("eqosplus status 2>&1")})
end

function act_check_dep()
    local sys = require "luci.sys"
    local pkg = luci.http.formvalue("pkg") or ""
    if not allowed_pkgs[pkg] then
        luci.http.prepare_content("application/json")
        luci.http.write_json({installed = false, error = "not allowed"})
        return
    end
    local installed = sys.call("opkg list-installed 2>/dev/null | grep -q '^" .. pkg .. " '") == 0
    luci.http.prepare_content("application/json")
    luci.http.write_json({installed = installed})
end

function act_install_dep()
    local sys = require "luci.sys"
    local pkg = luci.http.formvalue("pkg") or ""
    if not allowed_pkgs[pkg] then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, output = "Package not allowed"})
        return
    end
    local output = sys.exec("opkg update 2>&1 && opkg install " .. pkg .. " 2>&1")
    local success = sys.call("opkg list-installed 2>/dev/null | grep -q '^" .. pkg .. " '") == 0
    luci.http.prepare_content("application/json")
    luci.http.write_json({success = success, output = output})
end

function act_run_test()
    local sys = require "luci.sys"
    luci.http.prepare_content("application/json")
    luci.http.write_json({output = sys.exec("eqosplus_test 2>&1")})
end

function act_run_traffic_test()
    local sys = require "luci.sys"
    luci.http.prepare_content("application/json")
    luci.http.write_json({output = sys.exec("eqosplus_traffic_test 2>&1")})
end
