---------------------------------
--! @file
--! @brief The mobiled module containing glue logic for the entire Mobiled
---------------------------------

local require, tostring = require, tostring
local table, pairs, ipairs = table, pairs, ipairs

local mobiled_statemachine = require('mobiled.statemachine')
local mobiled_plugin = require('mobiled.plugin')
local mobiled_device = require('mobiled.device')
local mobiled_ubus = require('mobiled.ubus')
local version = require('mobiled.version')
local errors = require('mobiled.error')
local signal = require("signal").signal

local M = {}

local runtime
local plugins = {}
local stateMachines = {}

local device_index = 1

function M.cleanup()
	runtime.log:info("Cleaning up...")
	for i=#stateMachines,1,-1 do
		local sm = stateMachines[i]
		if sm.device then
			M.stop_device(sm.device, false)
		end
		table.remove(stateMachines, i)
	end

	for i=#plugins,1,-1 do
		local p = plugins[i]
		p:destroy()
		table.remove(plugins, i)
	end

	runtime.ubus:close()
	runtime.uloop.cancel()
end

function M.reloadconfig()
	runtime.log:info("Reloading config")
	runtime.config.reloadconfig(stateMachines, plugins)
end

function M.init(rt)
	runtime = rt

	M.platform = require('mobiled.platform')
	M.platform.init(runtime)
	local ret, errMsg = mobiled_ubus.init(runtime)
	if not ret then
		return nil, errMsg
	end

	signal("SIGTERM", function() M.cleanup() end)
	signal("SIGINT", function() M.cleanup() end)
	signal("SIGHUP", function() M.reloadconfig(); return true end)
	return true
end

local function ubus_send_reply(req, resp)
	runtime.ubus:reply(req, resp)
end

local function load_plugin(name, params)
	local plugin = M.get_plugin(name)
	if not plugin then
		local errMsg
		plugin, errMsg = mobiled_plugin.create(runtime, name, params)
		if not plugin then
			return nil, errMsg
		end
		if plugin.plugin.get_ubus_methods then
			local methods = plugin.plugin.get_ubus_methods(ubus_send_reply)
			if methods then
				runtime.ubus:add(methods)
			end
		end
		table.insert(plugins, plugin)
	end
	return plugin
end

function M.device_exists(dev_desc)
	for _, sm in ipairs(stateMachines) do
		if (sm.device and sm.device.desc == dev_desc) then
			return true
		end
	end
	return false
end

function M.add_device(params)
	if M.device_exists(params.dev_desc) then
		return nil, "Device " .. tostring(params.dev_desc).." was already added"
	end

	local sm
	for _, s in ipairs(stateMachines) do
		if not s.device then
			sm = s
			break
		end
	end

	if not sm then return nil, "No statemachine available to add device" end

	local c = M.get_config()

	local plugin, errMsg = load_plugin(params.plugin_name, { tracelevel = c.tracelevel })
	if not plugin then return nil, errMsg end

	local device
	params.dev_idx = sm.dev_idx
	device, errMsg = mobiled_device.create(runtime, params, plugin)
	if not device then return nil, errMsg end

	sm.device = device
	sm.device.sm = sm

	--[[
		Populate the data session list extracted from the UCI network config
		at creation of the device. This session info is needed to correctly configure
		the attach context.
		Additional data sessions can be created by Netifd sending the session_activate event.
	]]
	for _, session_config in pairs(runtime.config.get_session_config(device)) do
		-- Verify if the profile exists
		local profile
		profile, errMsg = M.get_profile(device, session_config.profile_id)
		if profile then
			device:add_data_session(session_config)
		else
			if errMsg then runtime.log:warning(errMsg) end
		end
	end

	runtime.events.send_event("mobiled", { event = "device_added", dev_idx = sm.dev_idx, dev_desc = sm.device.desc })

	M.start_new_statemachine()
	return device
end

function M.stop_device(device, force)
	if not force then
		M.stop_all_data_sessions(device)
	end
	local sessions = device:get_data_sessions() or {}
	M.propagate_session_state(device, "disconnected", "ipv4v6", sessions)
	device:destroy(force)
end

function M.remove_device(device)
	for i=#stateMachines,1,-1 do
		local sm = stateMachines[i]
		if(sm.device and sm.device.desc == device.desc) then
			local desc = device.desc
			M.stop_device(sm.device, true)
			runtime.log:info("Removed statemachine " .. sm.dev_idx)
			table.remove(stateMachines, i)
			runtime.events.send_event("mobiled", { event = "device_removed", dev_idx = sm.dev_idx, dev_desc = desc })
			break
		end
	end
	device_index = 1
	for _, sm in ipairs(stateMachines) do
		sm.dev_idx = device_index
		device_index = device_index + 1
	end
	M.start_new_statemachine()
end

function M.get_device(dev_idx)
	for _, sm in ipairs(stateMachines) do
		if sm.device and (sm.dev_idx == dev_idx or not dev_idx) then
			return sm.device
		end
	end
	return nil, "No device found with index " .. tostring(dev_idx)
end

function M.get_device_by_imei(imei)
	for _, sm in ipairs(stateMachines) do
		if sm.device and sm.device.info.imei == imei then
			return sm.device
		end
	end
	return nil, "No device found with IMEI " .. tostring(imei)
end

function M.get_device_by_desc(desc)
	for _, sm in ipairs(stateMachines) do
		if sm.device and (sm.device.desc == desc or not desc) then
			return sm.device
		end
	end
	return nil, "No device found with description " .. tostring(desc)
end

function M.get_devices()
	local devices = {}
	for _, sm in ipairs(stateMachines) do
		if sm.device then
			table.insert(devices, sm.device)
		end
	end
	return devices
end

function M.get_device_count()
	local devices = 0
	for _, sm in ipairs(stateMachines) do
		if sm.device then
			devices = devices + 1
		end
	end
	return devices
end

function M.get_statemachines()
	return stateMachines
end

function M.get_plugins()
	return plugins
end

function M.get_plugin(name)
	for _, p in ipairs(plugins) do
		if p.name == name then
			return p
		end
	end
	return nil, "No plugin found with name " .. tostring(name)
end

function M.get_attach_context(device)
	local sessions = device:get_data_sessions()
	if sessions[0] then
		return sessions[0], M.get_profile(device, sessions[0].profile_id)
	end
end

function M.configure_attach_context(device, session, profile)
	local log = runtime.log
	if session and session.changed and profile then
		local info = device:get_network_info()
		if info and info.nas_state == "registered" then
			log:info("Detaching from network")
			if not device:network_detach() then
				log:warning("Failed to detach")
			end
		end
		log:info("Configuring attach profile")
		device:set_attach_params(profile)
		session.changed = false
	end
end

function M.get_profile(device, profile_id)
	-- Check if the profile we want to use is a reused device profile
	local device_profile_id = tonumber(string.match(profile_id, "^device:(.*)$"))
	if device_profile_id then
		local profile = { device_profile = true, id = device_profile_id }
		local info = device:get_profile_info()
		if type(info) == "table" and type(info.profiles) == "table" then
			for _, p in pairs(info.profiles) do
				if tonumber(p.id) == profile.id then
					for k, v in pairs(p) do
						profile[k] = v
					end
					return profile
				end
			end
		end
		return nil, "Invalid device profile specified"
	end
	return runtime.config.get_profile(profile_id)
end

function M.activate_data_session(device, session_config)
	local log, events = runtime.log, runtime.events

	-- Verify if the profile exists
	local profile, errMsg = M.get_profile(device, session_config.profile_id)
	if profile then
		local session
		session, errMsg = device:activate_data_session(session_config)
		if session then
			log:info("Activated data session " .. tostring(session.session_id) .. " using profile " .. tostring(session.profile_id))
			events.send_event("mobiled", { event = "session_setup", session_id = session.session_id, dev_idx = device.sm.dev_idx })
		end
	end
	if errMsg then log:warning(errMsg) end
end

function M.deactivate_data_session(device, session_id)
	local log, events = runtime.log, runtime.events
	local ret, errMsg = device:deactivate_data_session(session_id)
	if ret then
		events.send_event("mobiled", { event = "session_teardown", session_id = session_id, dev_idx = device.sm.dev_idx })
	elseif errMsg then
		log:warning(errMsg)
	end
end

function M.start_data_session(device, session_id, profile, interface)
	M.propagate_session_state(device, "setup", "ipv4v6", { device:get_data_session(session_id) })
	return device:start_data_session(session_id, profile, interface)
end

function M.stop_data_session(device, session_id, interface)
	-- We need this teardown event here in order to kill the PPP interface otherwise the state will never change to disconnected
	M.propagate_session_state(device, "teardown", "ipv4v6", { device:get_data_session(session_id) })
	return device:stop_data_session(session_id, interface)
end

function M.stop_all_data_sessions(device)
	local sessions = device:get_data_sessions()
	for _, session in pairs(sessions) do
		M.propagate_session_state(device, "teardown", "ipv4v6", { session })
		device:stop_data_session(session.session_id)
	end
end

function M.get_data_session(device, session_id)
	local session, errMsg = device:get_data_session(session_id)
	return session or nil, errMsg
end

function M.get_config()
	return runtime.config.get_config()
end

function M.get_device_config(device)
	return runtime.config.get_device_config(device)
end

function M.validate_imsi(imsi)
	local config = M.get_config()
	if type(config.allowed_imsi_ranges) == "table" then
		for _, pattern in pairs(config.allowed_imsi_ranges) do
			if string.match(imsi, pattern) then
				return true
			end
		end
		return false
	end
	return true
end

function M.validate_roaming(imsi, mcc, roaming)
	if roaming == "national" then
		return imsi:sub(1,3) == mcc
	end
	return true
end

function M.validate_plmn(mcc, mnc)
	local config = M.get_config()
	if type(config.operators) == "table" then
		for _, operator in pairs(config.operators) do
			if operator.mcc .. operator.mnc == mcc .. mnc then
				return true
			end
		end
		return false
	end
	return true
end

function M.clear_pin()
	runtime.config.remove_all_pin_from_config()
end

function M.get_pin_from_config(pinType, iccid)
	return runtime.config.get_pin_from_config(pinType, iccid)
end

function M.remove_pin_from_config(pinType, iccid)
	runtime.config.remove_pin_from_config(pinType, iccid)
end

function M.store_pin_to_config(pinType, pin, iccid)
	local config = M.get_config()
	if config and config.store_pin then
		return runtime.config.store_pin_to_config(pinType, pin, iccid)
	end
end

function M.unlock_pin_from_config(device, pinType)
	if not device.iccid then
		return nil, "Invalid ICCID"
	end
	local pin = M.get_pin_from_config(pinType, device.iccid)
	if pin then
		local ret, errMsg = device:unlock_pin(pinType, pin)
		if not ret then
			M.remove_pin_from_config(pinType, device.iccid)
			return ret, errMsg
		end
		return true
	end
	return nil, "No PIN stored in config"
end

function M.propagate_session_state(device, session_state, pdp_type, sessions)
	if type(sessions) ~= "table" then return end
	for _, session in pairs(sessions) do
		runtime.events.send_event("mobiled", { dev_idx = device.sm.dev_idx, dev_desc = device.desc, event = "session_state_changed", session_state = session_state, session_id = session.session_id, pdp_type = pdp_type })
	end
end

function M.start_new_statemachine()
	local c = M.get_config()
	local smAvailable = false
	for _, sm in pairs(stateMachines) do
		if not sm.device then 
			smAvailable = true
			break
		end
	end
	if not smAvailable and #stateMachines < c.max_devices then
		runtime.log:info("Adding statemachine " .. device_index)
		-- Create a statemachine to look for new devices
		local config = runtime.config.get_raw_config()
		local sm = mobiled_statemachine.create(config.states, config.globals.initmode, runtime, device_index, M.handle_event)
		table.insert(stateMachines, sm)
		sm:start()
		device_index = device_index + 1
	end
end

function M.get_state(dev_idx)
	if not dev_idx then dev_idx = 1 end
	for _, sm in ipairs(stateMachines) do
		if sm.dev_idx == dev_idx then
			return sm:get_state()
		end
	end
	return nil, "No such statemachine (" .. tostring(dev_idx) .. ")"
end

function M.get_display_state(dev_idx)
	local state = M.get_state(dev_idx)
	local state_map = {
		["WaitingForDevice"]	= "no_device",
		["DeviceInit"]			= "configuring_device",
		["DeviceConfigure"]		= "configuring_device",
		["SimInit"]				= "configuring_device",
		["DeviceRemove"]		= "configuring_device",
		["UnlockSim"]			= "initializing_sim",
		["RegisterNetwork"]		= "connecting",
		["DataSessionSetup"]	= "connecting",
		["NetworkScan"]			= "scanning_network",
		["FirmwareUpgrade"]		= "upgrading_firmware",
		["SelectAntenna"]		= "configuring_device",
		["PlatformConfigure"]	= "configuring_device",
		["Disabled"]			= "disabled",
		["Error"]				= "error"
	}
	local display_state = state_map[state]
	if state == "Idle" then
		local device = M.get_device(dev_idx)
		if device then
			local sessions = device:get_data_sessions()
			if sessions[0] and sessions[0].activated then
				display_state = "connected"
			else
				display_state = "disconnected"
			end
		end
	end
	return display_state
end

function M.get_version()
	return version.version()
end

function M.add_error(device, severity, error_type, error_message)
	errors.add_error(device, severity, error_type, error_message)
end

function M.handle_event(event)
	if event.event == "device_disconnected" then
		-- In case of USB devices, we get a hotplug event without device index
		-- but with a device description. Let's figure out which device it is
		if not event.dev_idx then
			for _, sm in ipairs(stateMachines) do
				if sm.device and sm.device.desc == event.dev_desc then
					sm:handle_event(event)
					return
				end
			end
			runtime.log:error('Received event "%s" for unknown device', event.event)
			return
		end
	end

	local dev_idx = event.dev_idx
	if not dev_idx then
		if event.event ~= "device_connected" and event.event ~= "device_disconnected" and event.event ~= "platform_config_changed" then
			runtime.log:warning('Received event "%s" without device index', event.event)
		end
		dev_idx = 1
	end

	if event.event == "network_deregistered" or string.match(event.event, "session_") then
		local device = M.get_device(dev_idx)
		if not device then
			runtime.log:error('Received event "%s" for unknown device', event.event)
			return
		end

		if event.event == "network_deregistered" then
			if event.reject_cause then
				local severity = errors.reject_cause_severity(event.reject_cause)
				if severity == "warning" or severity == "error" or severity == "fatal" then
					errors.add_error(device, severity, "reject_cause", { reject_cause = event.reject_cause, pdp_type = event.pdp_type })
				end
			end
			M.propagate_session_state(device, "disconnected", "ipv4v6", device:get_data_sessions())
		elseif string.match(event.event, "session_") then
			if event.event == "session_disconnected" then
				if event.reject_cause then
					local severity = errors.reject_cause_severity(event.reject_cause)
					if severity == "warning" or severity == "error" or severity == "fatal" then
						errors.add_error(device, severity, "reject_cause", { reject_cause = event.reject_cause, pdp_type = event.pdp_type })
					end
				end
				M.propagate_session_state(device, "disconnected", event.pdp_type or "ipv4v6", { device:get_data_session(event.session_id) })
			elseif event.event == "session_activate" then
				M.activate_data_session(device, event)
			elseif event.event == "session_config_changed" then
				local session = device:get_data_session(event.session_id)
				if session then
					session.changed = true
				end
			elseif event.event == "session_deactivate" then
				M.deactivate_data_session(device, event.session_id)
			end
		end
	end

	for _, sm in ipairs(stateMachines) do
		if sm.dev_idx == dev_idx then
			sm:handle_event(event)
			break
		end
	end
end

return M
