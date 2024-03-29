local M = {}

M.SenseEventSet = {
	"device_initialized",
	"device_disconnected",
	"device_config_changed",
	"platform_config_changed",
	"attach_delay_expired"
}

function M.check(runtime, event, dev_idx)
	local mobiled = runtime.mobiled
	local log = runtime.log

	local device, errMsg = mobiled.get_device(dev_idx)
	if not device then
		if errMsg then log:error(errMsg) end
		return "DeviceRemove"
	end

	if event.event == "timeout" or event.event == "device_initialized" or event.event == "device_config_changed" or event.event == "attach_delay_expired" then
		local info = device:get_device_info()
		if info and info.initialized then
			if not device.info then
				device.info = {}
			end
			-- Some devices don't support reading the IMEI so allow Mobiled to use any other parameter to link the config
			device.info.device_config_parameter = info.device_config_parameter or "imei"
			if info[device.info.device_config_parameter] then
				device.info[device.info.device_config_parameter] = info[device.info.device_config_parameter]
				device.info.model = info.model

				local device_config = mobiled.get_device_config(device)
				-- If the attach_allowed field does not exist, the timer has not been started yet.
				if not device.attach_allowed and not device.attach_timer then
					-- Choose a random time to wait before the device attaches to the network.
					local minimum_attach_delay = math.max(device_config.device.minimum_attach_delay or 0, 0)
					local maximum_attach_delay = math.max(device_config.device.maximum_attach_delay or minimum_attach_delay + 10, minimum_attach_delay)
					local random_attach_delay = math.random(minimum_attach_delay * 1000, maximum_attach_delay * 1000)

					if random_attach_delay > 0 then
						device.attach_timer = runtime.uloop.timer(function()
							device.attach_allowed = true
							device.attach_timer = nil
							runtime.events.send_event("mobiled", { event = "attach_delay_expired", dev_idx = dev_idx })
						end, random_attach_delay)
						log:info("Device " .. dev_idx .. " will wait " .. random_attach_delay / 1000 .. " seconds before initializing")
					else
						device.attach_allowed = true
						log:info("Device " .. dev_idx .. " will initialize immediately")
					end
				end
				if device.attach_allowed then
					return "DeviceConfigure"
				end
			end
		end
	elseif event.event == "platform_config_changed" then
		return "PlatformConfigure"
	elseif event.event == "device_disconnected" then
		return "DeviceRemove"
	end

	return "DeviceInit"
end

return M
