local string = string

local pdu = require("pdu")

local M = {}

function M.get_messages(device)
	local messages = {}
	local ret = device:send_sms_command("AT+CMGL=4", "+CMGL:")
	if ret then
		for _, line in pairs(ret) do
			if line.response and line.pdu then
				local message = pdu.decode(line.pdu)
				if message then
					local id, status = string.match(line.response, "+CMGL:%s?(%d+),%s?(%d+)")
					id = tonumber(id)
					if id then
						if status == "0" then
							message.status = "unread"
						else
							message.status = "read"
						end
						message.id = id
						table.insert(messages, message)
					end
				end
			end
		end
	end
	return { messages = messages }
end

function M.send(device, number, message)
	local pdu_str, errMsg = pdu.encode(number, message)
	if pdu_str then
		-- Set tpLayerLength to half (hex encoding) of string length and subtract 1 for default SMSC added in PDU library
		local tpLayerLength = ((#pdu_str/2) - 1)
		return device:send_sms(string.format("AT+CMGS=%d", tpLayerLength), pdu_str, "+CMGS:", 60 * 1000) or nil, "Failed to send message"
	end
	return nil, errMsg
end

function M.delete(device, message_id)
	return device:send_command(string.format("AT+CMGD=%d", message_id))
end

function M.info(device)
	local info = {
		read_messages = 0,
		unread_messages = 0,
		max_messages = 0
	}
	local ret = device:send_singleline_command("AT+CPMS?", "+CPMS:")
	if ret then
		info.max_messages = tonumber(string.match(ret, '+CPMS:%s?".-",%s?%d+,%s?(%d+)'))
	end
	ret = M.get_messages(device)
	if ret then
		for _, message in pairs(ret.messages) do
			if message.status == "read" then
				info.read_messages = info.read_messages + 1
			elseif message.status == "unread" then
				info.unread_messages = info.unread_messages + 1
			end
		end
	end
	return info
end

function M.init(device)
	-- 3GPP TS 23.040, 3GPP TS 23.041 (messaging AT command syntax is compatible with GSM 07.05 Phase 2+)
	device:send_singleline_command("AT+CSMS=1", "+CSMS:")
	-- Enable de reception of SMS
	device:send_command("AT+CNMI=1,1,0,0,0")
	-- SMS PDU mode
	device:send_command("AT+CMGF=0")
	-- Select ME storage if available
	local ret = device:send_singleline_command('AT+CPMS=?', '+CPMS:')
	if ret then
		local storages = {}
		for section in string.gmatch(ret, '%(([A-Z0-9a-z ",/_]-)%)') do
			local store = {}
			for storage in string.gmatch(section, '([^,]+)') do
				storage = string.gsub(storage, '"', '')
				store[storage] = true
			end
			table.insert(storages, store)
		end
		if storages[1] and storages[1]["ME"] then
			device:send_singleline_command('AT+CPMS="ME","ME","ME"', '+CPMS:')
		else
			device:send_singleline_command('AT+CPMS="SM","SM","SM"', '+CPMS:')
		end
	end
end

return M
