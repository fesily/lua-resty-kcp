local libkcp = require 'resty.kcp.libkcp'
local buffer = require 'string.buffer'
local ngx_errlog = require("ngx.errlog")

local ffi = require 'ffi'
local bit = require 'bit'
local band = bit.band
local char_type = ffi.typeof('char[?]')
local now = ngx.now
local ffi_str = ffi.string
local ngx_get_phase = ngx.get_phase
---@class resty.kcp.factory:resty.kcp
---@field user udpsock
local _M = {}
local mt = {
    __index = _M
}

---@param udpsock udpsock
local function output(buf, len, udpsock)
    local ok, err = udpsock:send(ffi_str(buf, len))
    if not ok then
        ngx.log(ngx.WARN, err)
        return -1
    end
    return 0;
end

---@param conv integer
---@param udpsock?  udpsock
function _M.new(conv, udpsock)
    local kcp = libkcp.ikcp_create(conv, udpsock or ngx.socket.udp())
    return setmetatable(kcp, mt)
end

function _M:set_output(callback)
    libkcp.ikcp_set_output(self, callback or output)
end

function _M:updater_receive()
    local buf, err = self.user:receive()
    if err then
        return err
    end
    if buf then
        return libkcp.ikcp_input(self, buf, #buf)
    end
end

function _M:updater()
    local n = now()
    local period = (n * 1000) % 0xFFFFFFFF
    libkcp.ikcp_update(self, period)
    local next_ms = libkcp.ikcp_check(self, period)
    return ((next_ms - period) / 1000)
end

function _M:nodelay(nodelay, interval, resend, nc)
    return libkcp.ikcp_nodelay(self, nodelay, interval, resend, nc)
end

function _M:wndsize(sndwnd, rcvwnd)
    return libkcp.ikcp_wndsize(self, sndwnd, rcvwnd)
end

function _M:waitsnd()
    return libkcp.ikcp_waitsnd(self)
end

local function ngx_logger(self, log)
    ngx.log(self.log_level, ffi_str(log))
end

local cur_level

local function update_log_level()
    -- Nginx use `notice` level in init phase instead of error_log directive config
    -- Ref to src/core/ngx_log.c's ngx_log_init
    if ngx_get_phase() ~= "init" then
        cur_level = ngx.config.subsystem == "http" and ngx_errlog.get_sys_filter_level()
    end
end

function _M:enable_log(level, ...)
    update_log_level()
    if cur_level and level > cur_level then
    else
        self.log_level = level

        libkcp.set_logger(self, ngx_logger, select('#', ...) ~= 0 and band(...))
    end
end

function _M:send(buf)
    if type(buf) == "table" then
        for _, v in ipairs(buf) do
            _M:send(v)
        end
    else
        if type(buf) ~= "string" then
            buf = tostring(buf)
        end
        if libkcp.ikcp_send(self, buf, #buf) < 0 then
            return nil, 'error'
        end
        return true
    end
end

function _M:receive(size)
    size = size or libkcp.ikcp_peeksize(self)
    if size < 0 then
        return nil
    end
    local buf = char_type(size)
    local n = libkcp.ikcp_recv(self, buf, size)
    if n <= 0 then
        return nil, 'error'
    end
    return ffi_str(buf, n)
end

function _M:close()
    libkcp.ikcp_release(self)
end

function _M:settimeouts(connect_timeout, send_timeout, read_timeout)
    self.user:settimeout(send_timeout)
end

function _M:connect(host, port)
    return self.user:setpeername(host, port)
end

return _M
