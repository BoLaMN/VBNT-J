local M = {}

function M.check(runtime, event, dev_idx)
	local mobiled = runtime.mobiled
	local log = runtime.log

	local device, errMsg = mobiled.get_device(dev_idx)
	if not device then
		if errMsg then log:error(errMsg) end
		return "WaitingForDevice"
	end
	mobiled.remove_device(device)
	return "WaitingForDevice"
end

return M
