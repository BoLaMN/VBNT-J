--pretranslated: do not change this file
 
-- Enable localization
gettext.textdomain('webui-core')

local format = string.format
local ui_helper = require("web.ui_helper")
local content_helper = require("web.content_helper")
local proxy = require("datamodel")
local session = ngx.ctx.session
local modalPath = "/modals/iproutes-modal.lp"

if session:hasAccess(modalPath) then
--Dynamic Routes
local dyn_count = proxy.getPN("sys.class.iproutes.", true)
dyn_count = dyn_count and #dyn_count or 0

--DNS

function split(x,sep)
        x = tostring(x)
        local sep, fields = sep or ":", {}
        local pattern = format("([^%s]+)", sep)
        x:gsub(pattern, function(c) fields[#fields+1] = c end)
        return fields
end

local dns_rpc_path = "rpc.network.interface."
local interface_pn = proxy.getPN(dns_rpc_path, true)
local dnsservers_paths = {}
for _, v in pairs(interface_pn or {}) do
    if v.path then
        dnsservers_paths[#dnsservers_paths + 1] = v.path .. "dnsservers"
    end
end

local dns_rpc_content = proxy.get(unpack(dnsservers_paths)) -- use unpack for get() compatibility
local dns_count = 0
for _, v in pairs (dns_rpc_content or {}) do
   if v and v.value ~= "" then
      local subcount = split(format("%s",v.value),",")
      dns_count = dns_count + #subcount
   end
end

  ngx.print('\
\
<div class="span3">\
    <div class="smallcard">\
        ');  ngx.print( ui_helper.createCardHeader(T"IP Extras", "modals/iproutes-modal.lp") ); ngx.print('\
        <div class="content">\
            <p class="subinfos">\
            ');  
            local modal_link=format("class=\"modal-link\" data-toggle=\"modal\" data-remote=\"%s\" data-id=\"device-modal\"",modalPath)
            ngx.print(
            format( N('<strong %1$s>%2$d Route</strong>',
                      '<strong id="iproutescard_noofroutes" %1$s>%2$d Routes</strong> ', dyn_count),
                      modal_link, dyn_count))
              ngx.print('\
            </p>\
            <p class="subinfos">\
            ');  
            ngx.print(
            format( N('<strong %1$s>%2$d DNS Server</strong>',
                      '<strong id="iproutescard_dnsservers" %1$s>%2$d DNS Servers</strong>', dns_count),
                      modal_link, dns_count))
              ngx.print('\
            </p>\
         </div>\
\
    </div>\
</div>\
');  
end
  ngx.print('\
'); 