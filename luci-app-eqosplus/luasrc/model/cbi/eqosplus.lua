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

-- Build hostname lookup from DHCP leases + static leases (LuCI's own use).
-- Note: MAC-based connection limits are NOT supported — the FORWARD chain
-- can't match L2 destination MAC for inbound traffic, and "outbound only"
-- semantics would be inconsistent. CBI rejects MAC + conn_in/conn_out > 0
-- at validate time; the UI also greys-out the inputs when MAC is selected.
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
        local macs = type(s.mac) == "table" and s.mac or {s.mac}
        for _, mac in ipairs(macs) do
            if mac and mac ~= "" then
                hostnames[mac:upper()] = s.name
            end
        end
        if s.ip then hostnames[s.ip] = s.name end
    end
end)

local function is_mac_string(v)
	return type(v) == "string"
		and v:match("^%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x$") ~= nil
end

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

		-- Field stores MAC | IPv4 | IPv6 | CIDR. UCI option is "target"; we
		-- still read legacy "mac" as a fallback so unedited rules from older
		-- versions keep working without a forced migration step.
		ip = t:option(Value, "target", translate("IP/MAC"))
		ip.rmempty = false
		ip.datatype = "or(macaddr, ipaddr, ip6addr, cidr4, cidr6)"
		-- Read target first; fall back to legacy "mac" for un-resaved rules.
		-- Old rules may still carry a "MAC#ipv4" form from a prior release —
		-- strip everything after the first '#' to recover the bare value.
		ip.cfgvalue = function(self, section)
			local raw = self.map:get(section, self.option)
			if not raw or raw == "" then
				raw = self.map:get(section, "mac") or ""
			end
			return (raw:match("^([^#]+)")) or raw
		end
		-- MAC identifiers cannot have connection limits: the FORWARD chain
		-- can't match L2 destination MAC for inbound traffic (it's rewritten
		-- by the neigh subsystem AFTER our hook), and "outbound only" would
		-- be a half-feature that surprises users. The UI greys out conn_in /
		-- conn_out when MAC is selected; this validate is the defense in
		-- depth in case the form is bypassed (direct UCI / scripted POST).
		ip.validate = function(self, value, section)
			if is_mac_string(value) then
				local n = function(field)
					return tonumber(luci.http.formvalue("cbid.eqosplus." .. section .. "." .. field)) or 0
				end
				if n("conn_in") > 0 or n("conn_out") > 0 then
					return nil, translate("MAC identifiers do not support connection limits — pick an IP/CIDR identifier instead, or set both Conn In and Conn Out to 0")
				end
			end
			return value
		end
		-- No encoding any more — we just store the bare value. Also clean
		-- up the legacy "mac" field so "target" becomes the single source.
		ip.write = function(self, section, value)
			self.map:del(section, "mac")
			return Value.write(self, section, value)
		end
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

		-- Shared validator: download / upload / conn_in / conn_out cannot all be 0.
		-- Reads peer fields from the in-flight form rather than committed UCI.
		local function validate_capacity(self, value, section)
			local function n(field)
				local v = luci.http.formvalue("cbid.eqosplus." .. section .. "." .. field)
				return tonumber(v) or 0
			end
			if n("download") == 0 and n("upload") == 0
				and n("conn_in") == 0 and n("conn_out") == 0 then
				return nil, translate("Download, upload, inbound and outbound connection limits cannot all be 0")
			end
			return value
		end

		dl = t:option(Value, "download", translate("Download"))
		dl.default = '0.1'
		dl.size = 4
		dl.datatype = "and(ufloat, max(1250))"
		dl.rmempty = false
		dl.validate = validate_capacity

		ul = t:option(Value, "upload", translate("Upload"))
		ul.default = '0.1'
		ul.size = 4
		ul.datatype = "and(ufloat, max(1250))"
		ul.rmempty = false
		ul.validate = validate_capacity

		cin = t:option(Value, "conn_in", translate("Conn In"))
		cin.default = '0'
		cin.size = 4
		cin.datatype = "and(uinteger, max(65535))"
		cin.rmempty = false
		cin.description = translate("Max inbound connections (0 = no limit). For port-forwarded services / PCDN.")
		cin.validate = validate_capacity

		cout = t:option(Value, "conn_out", translate("Conn Out"))
		cout.default = '0'
		cout.size = 4
		cout.datatype = "and(uinteger, max(65535))"
		cout.rmempty = false
		cout.description = translate("Max outbound connections (0 = no limit). Counts connections initiated by the device.")
		cout.validate = validate_capacity

		tco = t:option(Flag, "tcp_only", translate("TCP only"))
		tco.default = "1"
		tco.rmempty = false
		tco.size = 4
		tco.description = translate("When checked, only TCP connections are counted; otherwise all protocols (TCP+UDP+ICMP+...)")

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

		week=t:option(MultiValue,"week",translate("Schedule"))
		week.delimiter = ","
		week.default = "1,2,3,4,5,6,7"
		week.rmempty = false
		week:value('1',translate("Mon"))
		week:value('2',translate("Tue"))
		week:value('3',translate("Wed"))
		week:value('4',translate("Thu"))
		week:value('5',translate("Fri"))
		week:value('6',translate("Sat"))
		week:value('7',translate("Sun"))
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
e.default = "1"

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
