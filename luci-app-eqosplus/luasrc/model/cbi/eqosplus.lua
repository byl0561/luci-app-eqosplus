-- Copyright 2022-2025 lava <byl0561@gmail.com>
-- Licensed to the public under the Apache License 2.0.
local nw = require "luci.model.network".init()
local ipc = require "luci.ip"
local uci_cursor = require "luci.model.uci".cursor()
local a, t, e

-- Build zone -> networks map (exclude wan zone)
local zone_networks = {}
local net_to_zone = {}
uci_cursor:foreach("firewall", "zone", function(z)
	if z.name and z.name ~= "wan" then
		local nets = z.network or {}
		if type(nets) == "string" then nets = {nets} end
		zone_networks[z.name] = nets
		for _, n in ipairs(nets) do
			net_to_zone[n] = z.name
		end
	end
end)

-- Build hostname lookup from DHCP leases + static leases
local hostnames = {}
local lease_file = io.open("/tmp/dhcp.leases", "r")
if lease_file then
	for line in lease_file:lines() do
		local ts, mac, ip_addr, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
		if name and name ~= "*" then
			hostnames[mac:upper()] = name
			hostnames[ip_addr] = name
		end
	end
	lease_file:close()
end
uci_cursor:foreach("dhcp", "host", function(s)
	if s.mac and s.name then
		hostnames[s.mac:upper()] = s.name
		if s.ip then hostnames[s.ip] = s.name end
	end
end)

function validate_time(self, value, section)
	local hh, mm
	hh, mm = string.match (value, "^(%d?%d):(%d%d)$")
	hh = tonumber (hh)
	mm = tonumber (mm)
	if hh and mm and hh <= 23 and mm <= 59 then
		return value
	else
		return nil, "Time HH:MM or space"
	end
end

function validate_time_range(self, value, section)
	local ok, err = validate_time(self, value, section)
	if not ok then return nil, err end
	local peer_field = (self.option == "timestart") and "timeend" or "timestart"
	-- Read peer from form submission (not yet committed to UCI), fall back to saved value
	local peer = luci.http.formvalue("cbid.eqosplus." .. section .. "." .. peer_field)
		or uci_cursor:get("eqosplus", section, peer_field)
		or "00:00"
	if value == peer and value ~= "00:00" then
		return nil, translate("Start and end time must differ (00:00 ~ 00:00 means all day)")
	end
	return value
end

a = Map("eqosplus", translate("Network speed limit"))
a.description = translate("Users can limit the network speed for uploading/downloading through MAC, IP. The speed unit is MB/second.")
a.template = "eqosplus/index"

-- Section: Status + Enabled (always visible above tabs)
t = a:section(TypedSection, "eqosplus")
t.anonymous = true

e = t:option(DummyValue, "eqosplus_status", translate("Status"))
e.template = "eqosplus/eqosplus"
e.value = translate("Collecting data...")

e = t:option(Flag, "service_enable", translate("Enabled"))
e.rmempty = false
e.size = 4

-- Section: Zone selector (top of Configuration tab)
t = a:section(TypedSection, "eqosplus")
t.anonymous = true

e = t:option(MultiValue, "enabled_zones", translate("Visible Networks"))
e.delimiter = " "
e.default = "lan"
e.rmempty = false
for zone_name, nets in pairs(zone_networks) do
	local net_list = table.concat(nets, ", ")
	e:value(zone_name, zone_name:upper() .. " (" .. net_list .. ")")
end

e = t:option(Flag, "zone_bypass", translate("Same-zone bypass"))
e.description = translate("Skip rate limiting for traffic between devices in the same firewall zone (e.g. LAN-to-LAN)")
e.default = "1"
e.rmempty = false

-- Pre-fetch all neighbors once (avoid repeated ipc.neighbors calls per network)
local all_neigh_v4, all_neigh_v6 = {}, {}
ipc.neighbors({family = 4}, function(n) all_neigh_v4[#all_neigh_v4 + 1] = n end)
ipc.neighbors({family = 6}, function(n) all_neigh_v6[#all_neigh_v6 + 1] = n end)

-- Network sections (Configuration tab, all zones; JS controls visibility)
for _, net in ipairs(nw:get_networks()) do
    local net_name = net:name()
    local zone = net_to_zone[net_name]
    if zone then
		local iface = net:get_interface()
		local name = iface and iface:name()
		local MAX_RULES = 50
		local rule_count = 0
		uci_cursor:foreach("eqosplus", "network_"..net_name, function() rule_count = rule_count + 1 end)
		local title = net_name:upper() .. " " .. translate("Configuration") ..
			" (" .. rule_count .. "/" .. MAX_RULES .. ")"
		t = a:section(TypedSection, "network_"..net_name, title)
		t.template = "cbi/tblsection"
		t.anonymous = true
		t.addremove = true

		-- Enforce per-network rule limit (tc class ID space is 100 per network)
		local _orig_create = t.create
		t.create = function(self, ...)
			local count = 0
			uci_cursor:foreach("eqosplus", "network_"..net_name, function() count = count + 1 end)
			if count >= MAX_RULES then
				return nil
			end
			return _orig_create(self, ...)
		end

		e = t:option(Flag, "enable", translate("Enabled"))
		e.rmempty = false
		e.size = 4

		ip = t:option(Value, "mac", translate("IP/MAC"))
		ip.datatype = "or(macaddr, ipaddr, ip6addr, cidr4, cidr6)"
		if name then
			-- Collect all device info, keyed by MAC (uppercase)
			local devices = {}
			local mac_order = {}

			local function add_neighbor(family, n)
				if not (n.mac and n.dest) then return end
				local mk = tostring(n.mac):upper()
				if not devices[mk] then
					devices[mk] = { mac = tostring(n.mac), ipv4 = {}, ipv6 = {} }
					mac_order[#mac_order + 1] = mk
				end
				local d = devices[mk]
				local addr = n.dest:string()
				local list = (family == 4) and d.ipv4 or d.ipv6
				local dup = false
				for _, v in ipairs(list) do if v == addr then dup = true; break end end
				if not dup then list[#list + 1] = addr end
				if not d.hostname or d.hostname == "" then
					d.hostname = hostnames[mk] or hostnames[addr] or ""
				end
			end

			for _, n in ipairs(all_neigh_v4) do
				if n.dev == name then add_neighbor(4, n) end
			end
			for _, n in ipairs(all_neigh_v6) do
				if n.dev == name then add_neighbor(6, n) end
			end

			-- Build label: value (other identifiers) - hostname
			local function mklabel(val, d)
				local ctx = {}
				if val ~= d.mac then ctx[#ctx + 1] = d.mac end
				local is_v4 = false
				for _, v in ipairs(d.ipv4) do if v == val then is_v4 = true; break end end
				if not is_v4 and #d.ipv4 > 0 then ctx[#ctx + 1] = d.ipv4[1] end
				local is_v6 = false
				for _, v in ipairs(d.ipv6) do if v == val then is_v6 = true; break end end
				if not is_v6 and #d.ipv6 > 0 then ctx[#ctx + 1] = d.ipv6[1] end
				local label = val
				if #ctx > 0 then label = label .. " (" .. table.concat(ctx, " / ") .. ")" end
				local hn = d.hostname or ""
				if hn ~= "" then label = label .. " - " .. luci.util.pcdata(hn) end
				return label
			end

			-- Group 1: IPv4 entries
			for _, mk in ipairs(mac_order) do
				for _, v4 in ipairs(devices[mk].ipv4) do
					ip:value(v4, mklabel(v4, devices[mk]))
				end
			end
			-- Group 2: IPv6 entries
			for _, mk in ipairs(mac_order) do
				for _, v6 in ipairs(devices[mk].ipv6) do
					ip:value(v6, mklabel(v6, devices[mk]))
				end
			end
			-- Group 3: MAC entries
			for _, mk in ipairs(mac_order) do
				ip:value(devices[mk].mac, mklabel(devices[mk].mac, devices[mk]))
			end
		end

		e.size = 8
		dl = t:option(Value, "download", translate("Download"))
		dl.default = '0.1'
		dl.size = 4
		dl.datatype = "and(ufloat, max(1250))"

		ul = t:option(Value, "upload", translate("Upload"))
		ul.default = '0.1'
		ul.size = 4
		ul.datatype = "and(ufloat, max(1250))"

		e = t:option(Value, "timestart", translate("Start"))
		e.placeholder = '00:00'
		e.default = '00:00'
		e.validate = validate_time_range
		e.rmempty = true
		e.size = 4

		e = t:option(Value, "timeend", translate("End"))
		e.placeholder = '00:00'
		e.default = '00:00'
		e.validate = validate_time_range
		e.rmempty = true
		e.size = 4

		week=t:option(Value,"week",translate("Schedule"))
		week.rmempty = true
		week:value('0',translate("Everyday"))
		week:value(1,translate("Mon"))
		week:value(2,translate("Tue"))
		week:value(3,translate("Wed"))
		week:value(4,translate("Thu"))
		week:value(5,translate("Fri"))
		week:value(6,translate("Sat"))
		week:value(7,translate("Sun"))
		week:value('1,2,3,4,5',translate("Weekdays"))
		week:value('6,7',translate("Weekend"))
		week.default='0'
		week.size = 6

		comment = t:option(Value, "comment", translate("Comment"))
		comment.size = 8
    end
end

-- Debug section
t = a:section(TypedSection, "eqosplus")
t.anonymous = true

e = t:option(ListValue, "log_level", translate("Log Level"))
e:value("0", translate("Off"))
e:value("1", translate("Error"))
e:value("2", translate("Info"))
e:value("3", translate("Debug"))
e.default = "2"

e = t:option(DummyValue, "debug_panel")
e.template = "eqosplus/debug"

-- After commit: delete rules for zones no longer in enabled_zones
function a.on_after_commit(self)
	local uci = require("luci.model.uci").cursor()
	local new_str = uci:get("eqosplus", "@eqosplus[0]", "enabled_zones") or "lan"
	local new_zones = {}
	for z in new_str:gmatch("%S+") do new_zones[z] = true end

	local to_delete = {}
	uci:foreach("eqosplus", nil, function(s)
		local net = (s[".type"] or ""):match("^network_(.+)$")
		if net and net_to_zone[net] and not new_zones[net_to_zone[net]] then
			to_delete[#to_delete + 1] = s[".name"]
		end
	end)
	for _, name in ipairs(to_delete) do uci:delete("eqosplus", name) end
	if #to_delete > 0 then uci:commit("eqosplus") end
end

return a
