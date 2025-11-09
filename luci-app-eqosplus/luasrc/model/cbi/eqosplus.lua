-- Copyright 2022-2025 lava <byl0561@gmail.com>
-- Licensed to the public under the Apache License 2.0.
local sys = require "luci.sys"
local nw = require "luci.model.network".init()
local interfaces = nw:get_interfaces()
local ipc = require "luci.ip"
local a, t, e

function validate_time(self, value, section)
	local hh, mm, ss
	hh, mm, ss = string.match (value, "^(%d?%d):(%d%d)$")
	hh = tonumber (hh)
	mm = tonumber (mm)
	if hh and mm and hh <= 23 and mm <= 59 then
		return value
	else
		return nil, "Time HH:MM or space"
	end
end

a = Map("eqosplus", translate("Network speed limit"))
a.description = translate("Users can limit the network speed for uploading/downloading through MAC, IP. The speed unit is MB/second.")..translate("Suggested feedback:")..translate("<a href=\'https://github.com/byl0561/luci-app-eqosplus.git' target=\'_blank\'>GitHub @byl0561/luci-app-eqosplus </a>")
a.template = "eqosplus/index"

t = a:section(TypedSection, "eqosplus")
t.anonymous = true

e = t:option(DummyValue, "eqosplus_status", translate("Status"))
e.template = "eqosplus/eqosplus"
e.value = translate("Collecting data...")

e = t:option(Flag, "service_enable", translate("Enabled"))
e.rmempty = false
e.size = 4

for _, iface in ipairs(interfaces) do
    local name = iface:name()
    local net = iface:get_network()

    if net and net:name() then
		local net_name = net:name()
		t = a:section(TypedSection, "network_"..net_name, net_name:upper().." "..translate("Configuration"))
		t.template = "cbi/tblsection"
		t.anonymous = true
		t.addremove = true

		comment = t:option(Value, "comment", translate("Comment"))
		comment.size = 8

		e = t:option(Flag, "enable", translate("Enabled"))
		e.rmempty = false
		e.size = 4

		ip = t:option(Value, "mac", translate("IP/MAC"))
		ipc.neighbors({family = 4, dev = name}, function(n)
			if n.mac and n.dest then
				ip:value(n.dest:string(), "%s (%s)" %{ n.dest:string(), n.mac })
			end
		end)
		ipc.neighbors({family = 4, dev = name}, function(n)
			if n.mac and n.dest then
				ip:value(n.mac, "%s (%s)" %{n.mac, n.dest:string() })
			end
		end)

		e.size = 8
		dl = t:option(Value, "download", translate("Downloads"))
		dl.default = '0.1'
		dl.size = 4

		ul = t:option(Value, "upload", translate("Uploads"))
		ul.default = '0.1'
		ul.size = 4

		e = t:option(Value, "timestart", translate("Start control time"))
		e.placeholder = '00:00'
		e.default = '00:00'
		e.validate = validate_time
		e.rmempty = true
		e.size = 4

		e = t:option(Value, "timeend", translate("Stop control time"))
		e.placeholder = '00:00'
		e.default = '00:00'
		e.validate = validate_time
		e.rmempty = true
		e.size = 4

		week=t:option(Value,"week",translate("Week Day(1~7)"))
		week.rmempty = true
		week:value('0',translate("Everyday"))
		week:value(1,translate("Monday"))
		week:value(2,translate("Tuesday"))
		week:value(3,translate("Wednesday"))
		week:value(4,translate("Thursday"))
		week:value(5,translate("Friday"))
		week:value(6,translate("Saturday"))
		week:value(7,translate("Sunday"))
		week:value('1,2,3,4,5',translate("Workday"))
		week:value('6,7',translate("Rest Day"))
		week.default='0'
		week.size = 6
    end
end

return a
