local M = {}
local open = io.open
local format, match = string.format, string.match
local pairs = pairs
local sort, concat = table.sort, table.concat

local uci_helper = require("transformer.mapper.ucihelper")
local profile_default = require("transformer.shared.servicedefault")
local outgoing_order = profile_default.outgoingmap_order
local services_default_cfg = profile_default.services
local naming_rule = profile_default.naming_rule
local dial_plan_entry_default = profile_default.dial_plan_entry_default
local dial_plan_pattern_generator = profile_default.dial_plan_pattern_generator

local mmpbx_binding = { config="mmpbx" }
local service_binding = { config = "mmpbx", sectionname = "service"}
local sipnet_binding = { config="mmpbxrvsipnet" }
local binding = {}

local function incomingmap_set(profile, ports, transactions, commitapply)
    mmpbx_binding.sectionname = "incoming_map"
    mmpbx_binding.option = nil
    binding.config = "mmpbx"
    binding.sectionname = nil
    local uci_devices
    uci_helper.foreach_on_uci(mmpbx_binding, function(s)
        if s.profile == profile then
            binding.sectionname = s[".name"]
            uci_devices = s["device"]
            return true
        end
    end)

    if not binding.sectionname then
        if #ports == 0 then
            return false
        else
            local section = uci_helper.add_on_uci(mmpbx_binding)
            binding.sectionname = section
            binding.option = "profile"
            uci_helper.set_on_uci(binding, profile, commitapply)
        end
    elseif #ports == 0 then
        binding.option = nil
        uci_helper.delete_on_uci(binding, commitapply)
        transactions[binding.config] = true
        return true
    elseif type(uci_devices) == 'table' then
        sort(uci_devices)
        sort(ports)
        if concat(uci_devices) == concat(ports) then
            return false
        end
    end

    binding.option = "device"
    uci_helper.set_on_uci(binding, ports, commitapply)
    transactions[binding.config] = true
    return true
end

local function outgoingmap_create(profile, device, transactions, commitapply)
    mmpbx_binding.sectionname = "outgoing_map"
    local section = uci_helper.add_on_uci(mmpbx_binding)
    mmpbx_binding.sectionname = section
    mmpbx_binding.option = "device"
    uci_helper.set_on_uci(mmpbx_binding, device, commitapply)
    mmpbx_binding.option = "profile"
    uci_helper.set_on_uci(mmpbx_binding, { profile }, commitapply)
    mmpbx_binding.option = "priority"
    uci_helper.set_on_uci(mmpbx_binding, { "1" }, commitapply)
    transactions[mmpbx_binding.config] = true
end

local function getProfileOrderParam(value)
    local profile_type, index = value:match("(.*)_(%d+)")
    if not profile_type then
        profile_type, index = value, 0
    end
    return outgoing_order[profile_type], index
end

local function outgoingmap_set(profile, ports, transactions, commitapply)
    local check = {}
    for _,v in ipairs(ports) do
        check[v] = true
    end
    mmpbx_binding.sectionname = "outgoing_map"
    mmpbx_binding.option = nil
    binding.config = "mmpbx"
    uci_helper.foreach_on_uci(mmpbx_binding, function(s)
        local new_profiles, new_priorities
        if type(s.priority) == "table" and type(s.profile) == "table" then
            new_profiles = {}
            new_priorities = {}
            local highest = 0
            for k,v in pairs(s.profile) do
                if v == profile then
                    if check[s.device] then
                        new_profiles = nil
                        new_priorities = nil
                        break
                    end
                else
                    new_profiles[#new_profiles+1] = v
                    new_priorities[#new_priorities+1] = s["priority"][k]
                    local priority = tonumber(s["priority"][k])
                    if priority > highest then
                        highest = priority
                    end
                end
            end

            if new_profiles and #new_profiles == #s["profile"] then
                if check[s.device] then
                    new_profiles[#new_profiles+1] = profile
                    new_priorities[#new_priorities+1] = tonumber(highest+1)
                else
                    new_profiles = nil
                    new_priorities = nil
                end
            end
        elseif check[s.device] then
            new_profiles = { profile }
            new_priorities = { "1" }
        end

        if new_profiles then
            binding.sectionname = s[".name"]
            if #new_profiles > 0 then
                binding.option = "profile"
                if outgoing_order then
                    table.sort(new_profiles, function(a,b)
                        local order_a, index_a = getProfileOrderParam(a)
                        local order_b, index_b = getProfileOrderParam(b)

                        if order_a and order_b and (order_a < order_b or (order_a == order_b) and index_a < index_b) then
                            return true
                        elseif not order_a  then
                            return true
                        end
                        return false
                    end)
                end
                uci_helper.set_on_uci(binding, new_profiles, commitapply)
                binding.option = "priority"
                uci_helper.set_on_uci(binding, new_priorities, commitapply)
                transactions[binding.config] = true
           elseif #new_profiles == 0 then
                binding.option = nil
                uci_helper.delete_on_uci(binding, commitapply)
                transactions[binding.config] = true
           end
        end
        if s.device then
            check[s.device] = nil
        end
    end)

    for port,_ in pairs(check) do
        outgoingmap_create(profile, port, transactions, commitapply)
    end
end

function M.port_set(profile, ports, transactions, commitapply)
    local changed = incomingmap_set(profile, ports, transactions, commitapply)
    if changed then
        outgoingmap_set(profile, ports, transactions, commitapply)
    end
end

local function getHighestSipId()
    local highest = -1
    sipnet_binding.sectionname = "profile"
    uci_helper.foreach_on_uci(sipnet_binding, function(s)
        local id = tonumber(s['.name']:match("(%d+)$"))
        if (highest < id) then
             highest = id
        end
    end)
    return highest + 1
end

local function getFirstAvailableId()
    local all = {}
    sipnet_binding.sectionname = "profile"
    uci_helper.foreach_on_uci(sipnet_binding, function(s)
        local id = s['.name']:match("(%d+)$")
        all[id] = true
    end)
    local i = 0
    while all[tostring(i)] do
        i = i+1
    end
    return i
end

local function add_services(profile_name, transactions, commitapply)
    local binding = {}
    if services_default_cfg then
        binding.config = "mmpbx"

        local services = {}
        for k,v in pairs(services_default_cfg.append or {}) do
            services[k] = v
        end

        uci_helper.foreach_on_uci(service_binding, function(s)
	    if services[s["type"]] and not s.device then
		local profiles = s["profile"] or {}
                profiles[#profiles+1] = profile_name
                binding.sectionname = s[".name"]
                binding.option = "profile"
                uci_helper.set_on_uci(binding, profiles, commitapply)
                services[s["type"]] = nil
            end
        end)

        for k,v in pairs(services_default_cfg.add or {}) do
            services[k] = v
        end

        for k,v in pairs (services) do
            local service_name = uci_helper.add_on_uci(service_binding)
            transactions[service_binding.config] = true
            binding.sectionname = service_name
            binding.option = "type"
            uci_helper.set_on_uci(binding, k, commitapply)
            binding.option = "profile"
            uci_helper.set_on_uci(binding, {profile_name}, commitapply)
            for param, value in pairs (v) do
                binding.option = param
                uci_helper.set_on_uci(binding, value, commitapply)
            end
        end
    end
end

function M.delete_sip_dial_plan_entry(dpename, transactions, commitapply)
    mmpbx_binding.sectionname = "dial_plan_entry"
    mmpbx_binding.option = nil
    local found = false
    uci_helper.foreach_on_uci(mmpbx_binding, function(s)
        if s[".name"] == dpename then
            found = true
            return found
        end
    end)
    if found then
        mmpbx_binding.sectionname = dpename
        uci_helper.delete_on_uci(mmpbx_binding, commitapply)
        transactions[mmpbx_binding.config] = true
        uci_helper.commit(mmpbx_binding)
        return true
    end
end

function M.add_sip_dial_plan_entry(id, sip_net, transactions, commitapply)
    mmpbx_binding.sectionname = "dial_plan"
    mmpbx_binding.option = nil
    local dial_plan, _key
    local add_dpe_binding = {config ="mmpbx"}
    uci_helper.foreach_on_uci(mmpbx_binding, function(s)
        if type(s["network"]) == "table" and match(concat(s["network"], " "), "sip_net") then
            dial_plan = s[".name"]
            return false
        end
    end)
    local max_dial_plan = 0
    if dial_plan then
        mmpbx_binding.sectionname = "dial_plan_entry"
        uci_helper.foreach_on_uci(mmpbx_binding, function(s)
        if (s['.name']) then
                if (s['.name']:match("dial_plan_entry_generic")) then
                        local next_index = tonumber((s['.name']:match("dial_plan_entry_generic_(.*)$")))
                        if next_index > max_dial_plan then
                                max_dial_plan = next_index
                        end
                end
        end
    end)
    if max_dial_plan > 0 then
	mmpbx_binding.sectionname = "dial_plan_entry_generic_"..max_dial_plan+1
	uci_helper.set_on_uci(mmpbx_binding,"dial_plan_entry",commitapply)
    else
	mmpbx_binding.sectionname = "dial_plan_entry"
        local sectionname = uci_helper.add_on_uci(mmpbx_binding, commitapply)
        mmpbx_binding.sectionname = sectionname
    end
    local _key = uci_helper.generate_key()
    mmpbx_binding.option = "_key"
    uci_helper.set_on_uci(mmpbx_binding, _key)
    _key = "dial_plan_entry" .. "|" .. _key
    mmpbx_binding.option = "dial_plan"
    uci_helper.set_on_uci(mmpbx_binding, "dial_plan_generic",commitapply)
    for k,v in pairs(profile_default.dial_plan_entry_table) do
          mmpbx_binding.option = k
          uci_helper.set_on_uci(mmpbx_binding, v, commitapply)
    end
    transactions[mmpbx_binding.config] = true
    return _key
end
end

local function add_dial_plan_entry(id, sip_net, transactions, commitapply)
    mmpbx_binding.sectionname = "dial_plan"
    mmpbx_binding.option = nil
    local dial_plan
    uci_helper.foreach_on_uci(mmpbx_binding, function(s)
        if type(s["network"]) == "table" and match(concat(s["network"], " "), sip_net) then
            dial_plan = s[".name"]
            return false
        end
    end)
    if dial_plan then
        mmpbx_binding.sectionname = "dial_plan_entry"
        local dialplan_entry = uci_helper.add_on_uci(mmpbx_binding)
        transactions[mmpbx_binding.config] = true
        mmpbx_binding.sectionname = dialplan_entry
        mmpbx_binding.option = 'pattern'
        local pattern = dial_plan_pattern_generator(id)
        uci_helper.set_on_uci(mmpbx_binding, pattern, commitapply)
        mmpbx_binding.option = 'forced_profile'
        local profile_name = format ("sip_profile_%s", id)
        uci_helper.set_on_uci(mmpbx_binding, profile_name, commitapply)
        for k,v in pairs(dial_plan_entry_default) do
            mmpbx_binding.option = k
            uci_helper.set_on_uci(mmpbx_binding, v, commitapply)
        end
    end
end

function M.profile_add(add_sipnet_defaults, transactions, commitapply)
    local id
    if naming_rule == "firstAvailableId" then
        id = getFirstAvailableId()
    else
        id = getHighestSipId()
    end
    local profile_name = format ("sip_profile_%s", id)
    sipnet_binding.sectionname = profile_name
    sipnet_binding.option = nil
    uci_helper.set_on_uci(sipnet_binding, "profile", commitapply)
    if add_sipnet_defaults then
        local defaultvalue = format("profile%s", id+1)
        local sipconfig_defaults = {
            network = "sip_net",
            uri = defaultvalue,
            user_name = defaultvalue,
            password = defaultvalue,
            display_name = defaultvalue,
            enabled = "0",
        }
        for k,v in pairs(sipconfig_defaults) do
            sipnet_binding.option = k
            uci_helper.set_on_uci(sipnet_binding, v, commitapply)
        end
    end
    transactions[sipnet_binding.config] = true
    mmpbx_binding.sectionname = profile_name
    mmpbx_binding.option = nil
    uci_helper.set_on_uci(mmpbx_binding, "profile", commitapply)
    mmpbx_binding.option = "config"
    uci_helper.set_on_uci(mmpbx_binding, "mmpbxrvsipnet", commitapply)
    add_services(profile_name, transactions, commitapply)
    if dial_plan_entry_default then
        add_dial_plan_entry(id, "sip_net", transactions, commitapply)
    end
    transactions[mmpbx_binding.config] = true
    return profile_name
end

local function delete_services(profile, transactions, commitapply)
    mmpbx_binding.sectionname = "service"
    local binding = {config="mmpbx"}
    local entries = {}
    uci_helper.foreach_on_uci(mmpbx_binding, function(s)
         if type(s.profile) == "table" then
             local new_profiles = {}
             for _,v in pairs(s.profile) do
                 if v ~= profile then
                     new_profiles[#new_profiles+1] = v
                 end
             end
             if #new_profiles == 0 and services_default_cfg and services_default_cfg["add"][s["type"]] then
                entries[#entries+1] = s[".name"]
             else
                binding.sectionname = s[".name"]
                binding.option = "profile"
                uci_helper.set_on_uci(binding, new_profiles, commitapply)
                transactions[binding.config] = true
             end
         end
    end)
    for _,v in pairs(entries) do
        mmpbx_binding.sectionname = v
        uci_helper.delete_on_uci(mmpbx_binding, commitapply)
        transactions[mmpbx_binding.config] = true
    end
end

local function delete_dial_plan_entry(profile, transactions, commitapply)
    mmpbx_binding.sectionname = "dial_plan_entry"
    mmpbx_binding.option = nil
    local entries = {}
    uci_helper.foreach_on_uci(mmpbx_binding, function(s)
        if s["forced_profile"] == profile then
            entries[#entries+1] = s[".name"]
        end
    end)
    for _,v in pairs(entries) do
        mmpbx_binding.sectionname = v
        uci_helper.delete_on_uci(mmpbx_binding, commitapply)
        transactions[mmpbx_binding.config] = true
    end
end

function M.profile_delete(profile, transactions, commitapply)
    sipnet_binding.sectionname = profile
    sipnet_binding.option = nil
    uci_helper.delete_on_uci(sipnet_binding, commitapply)
    transactions[sipnet_binding.config] = true
    mmpbx_binding.sectionname = profile
    mmpbx_binding.option = nil
    uci_helper.delete_on_uci(mmpbx_binding, commitapply)
    transactions[mmpbx_binding.config] = true
    delete_services(profile, transactions, commitapply)
    if dial_plan_entry_default then
        delete_dial_plan_entry(profile, transactions, commitapply)
    end
    M.port_set(profile, {}, transactions, commitapply)
end

function M.find_device_support(parentkey)
    local numOfFxs, numOfDect, numOfSipdev = 0, 0, 0
    local entries = {}

    binding.config = "mmpbx"
    binding.sectionname = "device"
    uci_helper.foreach_on_uci(binding, function(s)
    if parentkey:match(s.config) then
        entries[#entries + 1] = s['.name']
    end
        if s['.name']:sub(1,1) == "f" then
            numOfFxs = numOfFxs + 1
        end
        if s['.name']:sub(1,1) == "d" then
            numOfDect = numOfDect + 1
        end
        if s['.name']:sub(1,1) == "s" then
            numOfSipdev = numOfSipdev + 1
        end
    end)

    return numOfFxs, numOfDect, numOfSipdev
end

return M
