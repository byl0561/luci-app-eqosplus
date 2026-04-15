module("luci.controller.eqosplus", package.seeall)
-- Copyright 2022-2025 lava <byl0561@gmail.com>

local allowed_pkgs = { ["kmod-dummy"] = true, ["kmod-veth"] = true, ["ip-full"] = true }
local TIMEOUT = "/usr/lib/eqosplus/timeout_exec"

function index()
    if not nixio.fs.access("/etc/config/eqosplus") then return end
    local e = entry({"admin", "network", "eqosplus"}, cbi("eqosplus"), _("Eqosplus"), 10)
    e.dependent=false
    e.acl_depends = { "luci-app-eqosplus" }
    local function sub_entry(path, func)
        local e = entry(path, call(func))
        e.leaf = true
        e.acl_depends = { "luci-app-eqosplus" }
    end
    sub_entry({"admin", "network", "eqosplus", "status"}, "act_status")
    sub_entry({"admin", "network", "eqosplus", "get_log"}, "act_get_log")
    sub_entry({"admin", "network", "eqosplus", "diag"}, "act_diag")
    sub_entry({"admin", "network", "eqosplus", "check_dep"}, "act_check_dep")
    sub_entry({"admin", "network", "eqosplus", "install_dep"}, "act_install_dep")
    sub_entry({"admin", "network", "eqosplus", "check_deps"}, "act_check_deps")
    sub_entry({"admin", "network", "eqosplus", "install_deps"}, "act_install_deps")
    sub_entry({"admin", "network", "eqosplus", "run_test"}, "act_run_test")
    sub_entry({"admin", "network", "eqosplus", "run_traffic_test"}, "act_run_traffic_test")
end

function act_status()
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    local e = {}
    e.status = sys.call("pgrep -x eqosplusctrl >/dev/null 2>&1") == 0
    local sw = uci:get("turboacc", "config", "sw_flow") or "0"
    local sfe = uci:get("turboacc", "config", "sfe_flow") or "0"
    if sw == "1" or sfe == "1" then
        e.warning = "turboacc"
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json(e)
end

function act_get_log()
    local sys = require "luci.sys"
    luci.http.prepare_content("application/json")
    luci.http.write_json({log = sys.exec("tail -c 65536 /tmp/eqosplus.log 2>/dev/null") or ""})
end

function act_diag()
    local sys = require "luci.sys"
    luci.http.prepare_content("application/json")
    luci.http.write_json({output = sys.exec(TIMEOUT .. " 30 eqosplus status 2>&1")})
end

function act_check_dep()
    local sys = require "luci.sys"
    local util = require "luci.util"
    local pkg = luci.http.formvalue("pkg") or ""
    if not allowed_pkgs[pkg] then
        luci.http.prepare_content("application/json")
        luci.http.write_json({installed = false, error = "not allowed"})
        return
    end
    local installed = sys.call("opkg list-installed 2>/dev/null | grep -qF " .. util.shellquote(pkg)) == 0
    luci.http.prepare_content("application/json")
    luci.http.write_json({installed = installed})
end

function act_install_dep()
    local sys = require "luci.sys"
    local util = require "luci.util"
    local pkg = luci.http.formvalue("pkg") or ""
    if not allowed_pkgs[pkg] then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, output = "Package not allowed"})
        return
    end
    local qpkg = util.shellquote(pkg)
    local output = sys.exec(TIMEOUT .. " 60 opkg update 2>&1 && " .. TIMEOUT .. " 120 opkg install " .. qpkg .. " 2>&1")
    local success = sys.call("opkg list-installed 2>/dev/null | grep -qF " .. qpkg) == 0
    luci.http.prepare_content("application/json")
    luci.http.write_json({success = success, output = output})
end

function act_check_deps()
    local sys = require "luci.sys"
    local util = require "luci.util"
    local pkgs_str = luci.http.formvalue("pkgs") or ""
    local missing = {}
    for pkg in pkgs_str:gmatch("[^,]+") do
        pkg = pkg:match("^%s*(.-)%s*$")
        if allowed_pkgs[pkg] then
            local installed = sys.call("opkg list-installed 2>/dev/null | grep -qF " .. util.shellquote(pkg)) == 0
            if not installed then
                missing[#missing + 1] = pkg
            end
        end
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({missing = missing})
end

function act_install_deps()
    local sys = require "luci.sys"
    local util = require "luci.util"
    local pkgs_str = luci.http.formvalue("pkgs") or ""
    local to_install = {}
    for pkg in pkgs_str:gmatch("[^,]+") do
        pkg = pkg:match("^%s*(.-)%s*$")
        if allowed_pkgs[pkg] then
            to_install[#to_install + 1] = pkg
        end
    end
    if #to_install == 0 then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, output = "No valid packages"})
        return
    end
    local quoted = {}
    for _, pkg in ipairs(to_install) do
        quoted[#quoted + 1] = util.shellquote(pkg)
    end
    local cmd = TIMEOUT .. " 60 opkg update 2>&1 && " .. TIMEOUT .. " 120 opkg install " .. table.concat(quoted, " ") .. " 2>&1"
    local output = sys.exec(cmd)
    local all_ok = true
    for _, pkg in ipairs(to_install) do
        if sys.call("opkg list-installed 2>/dev/null | grep -qF " .. util.shellquote(pkg)) ~= 0 then
            all_ok = false
            break
        end
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({success = all_ok, output = output})
end

function act_run_test()
    local sys = require "luci.sys"
    luci.http.prepare_content("application/json")
    luci.http.write_json({output = sys.exec(TIMEOUT .. " 120 eqosplus_test 2>&1")})
end

function act_run_traffic_test()
    local sys = require "luci.sys"
    luci.http.prepare_content("application/json")
    luci.http.write_json({output = sys.exec(TIMEOUT .. " 120 eqosplus_traffic_test 2>&1")})
end
