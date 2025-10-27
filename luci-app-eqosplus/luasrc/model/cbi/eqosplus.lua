-- Copyright 2022-2025 lava <byl0561@gmail.com>
-- Licensed to the public under the Apache License 2.0.
local sys = require "luci.sys"
local nw = require "luci.model.network".init()
local interfaces = nw:get_interfaces()
local ipc = require "luci.ip"
local a, t, e

-- Enhanced device discovery function
local function get_devices(interface_name)
    local devices = {}
    local seen_ips = {}
    local ubus = require "ubus"
    
    local function get_hostname(ip)
        local f = io.popen("nslookup "..ip.." 2>/dev/null | grep 'name =' | cut -d'=' -f2 | sed 's/\\.$//'")
        if f then
            local name = f:read("*l")
            f:close()
            if name and name ~= "" then
                return name:match("^%s*(.-)%s*$")
            end
        end
        local leases_file = io.open("/tmp/dhcp.leases", "r")
        if leases_file then
            for line in leases_file:lines() do
                local mac, ip_lease, _, hostname = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
                if ip_lease == ip and hostname ~= "*" then
                    leases_file:close()
                    return hostname
                end
            end
            leases_file:close()
        end
        return "unknown"
    end
    
    -- Get devices from DHCP leases
    local conn = ubus.connect()
    if conn then
        local leases = conn:call("dhcp", "ipv4leases", {}) or {}
        for _, lease in ipairs(leases) do
            if lease.ipaddr and lease.mac then
                local hostname = lease.hostname or get_hostname(lease.ipaddr)
                devices[#devices+1] = {
                    ip = lease.ipaddr,
                    mac = lease.mac:upper(),
                    hostname = hostname,
                    display = string.format("%s (%s) - %s", lease.ipaddr, lease.mac:upper(), hostname)
                }
                seen_ips[lease.ipaddr] = true
            end
        end
        conn:close()
    end
    
    -- Get devices from ARP table
    local arp_cmd = io.popen("ip -4 neigh show dev "..interface_name.." 2>/dev/null")
    if arp_cmd then
        for line in arp_cmd:lines() do
            local ip_addr, mac = line:match("^(%S+)%s+.+%s+(%S+)%s+")
            if ip_addr and mac and mac ~= "00:00:00:00:00:00" and not seen_ips[ip_addr] then
                mac = mac:upper()
                local hostname = get_hostname(ip_addr)
                devices[#devices+1] = {
                    ip = ip_addr,
                    mac = mac,
                    hostname = hostname,
                    display = string.format("%s (%s) - %s", ip_addr, mac, hostname)
                }
                seen_ips[ip_addr] = true
            end
        end
        arp_cmd:close()
    end
    
    -- Sort devices by IP address
    table.sort(devices, function(a, b) return a.ip < b.ip end)
    return devices
end

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
		ip.size = 12
		
		-- Use enhanced device discovery
		local devices = get_devices(name)
		for _, dev in ipairs(devices) do
			ip:value(dev.ip, dev.display)
			ip:value(dev.mac, dev.display)
		end
		
		-- Fallback to original method for compatibility
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
