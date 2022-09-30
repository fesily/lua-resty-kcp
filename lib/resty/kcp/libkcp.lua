local ffi = require "ffi"

ffi.cdef [[
struct IQUEUEHEAD {
    struct IQUEUEHEAD *next, *prev;
};

typedef struct IQUEUEHEAD iqueue_head;
    
struct IKCPCB
{
    uint32_t conv, mtu, mss, state;
    uint32_t snd_una, snd_nxt, rcv_nxt;
    uint32_t ts_recent, ts_lastack, ssthresh;
    int32_t rx_rttval, rx_srtt, rx_rto, rx_minrto;
    uint32_t snd_wnd, rcv_wnd, rmt_wnd, cwnd, probe;
    uint32_t current, interval, ts_flush, xmit;
    uint32_t nrcv_buf, nsnd_buf;
    uint32_t nrcv_que, nsnd_que;
    uint32_t nodelay, updated;
    uint32_t ts_probe, probe_wait;
    uint32_t dead_link, incr;
    struct IQUEUEHEAD snd_queue;
    struct IQUEUEHEAD rcv_queue;
    struct IQUEUEHEAD snd_buf;
    struct IQUEUEHEAD rcv_buf;
    uint32_t *acklist;
    uint32_t ackcount;
    uint32_t ackblock;
    void *user;
    char *buffer;
    int fastresend;
    int fastlimit;
    int nocwnd, stream;
    int logmask;
    int (*output)(const char *buf, int len, struct IKCPCB *kcp, void *user);
    void (*writelog)(const char *log, struct IKCPCB *kcp, void *user);
};
typedef struct IKCPCB ikcpcb;

//---------------------------------------------------------------------
// interface
//---------------------------------------------------------------------

// create a new kcp control object, 'conv' must equal in two endpoint
// from the same connection. 'user' will be passed to the output callback
// output callback can be setup like this: 'kcp->output = my_udp_output'
ikcpcb* ikcp_create(uint32_t conv, void *user);

// release kcp control object
void ikcp_release(ikcpcb *kcp);

// set output callback, which will be invoked by kcp
void ikcp_setoutput(ikcpcb *kcp, int (*output)(const char *buf, int len, 
	ikcpcb *kcp, void *user));

// user/upper level recv: returns size, returns below zero for EAGAIN
int ikcp_recv(ikcpcb *kcp, char *buffer, int len);

// user/upper level send, returns below zero for error
int ikcp_send(ikcpcb *kcp, const char *buffer, int len);

// update state (call it repeatedly, every 10ms-100ms), or you can ask 
// ikcp_check when to call it again (without ikcp_input/_send calling).
// 'current' - current timestamp in millisec. 
void ikcp_update(ikcpcb *kcp, uint32_t current);

// Determine when should you invoke ikcp_update:
// returns when you should invoke ikcp_update in millisec, if there 
// is no ikcp_input/_send calling. you can call ikcp_update in that
// time, instead of call update repeatly.
// Important to reduce unnacessary ikcp_update invoking. use it to 
// schedule ikcp_update (eg. implementing an epoll-like mechanism, 
// or optimize ikcp_update when handling massive kcp connections)
uint32_t ikcp_check(const ikcpcb *kcp, uint32_t current);

// when you received a low level packet (eg. UDP packet), call it
int ikcp_input(ikcpcb *kcp, const char *data, long size);

// flush pending data
void ikcp_flush(ikcpcb *kcp);

// check the size of next message in the recv queue
int ikcp_peeksize(const ikcpcb *kcp);

// change MTU size, default is 1400
int ikcp_setmtu(ikcpcb *kcp, int mtu);

// set maximum window size: sndwnd=32, rcvwnd=32 by default
int ikcp_wndsize(ikcpcb *kcp, int sndwnd, int rcvwnd);

// get how many packet is waiting to be sent
int ikcp_waitsnd(const ikcpcb *kcp);

// fastest: ikcp_nodelay(kcp, 1, 20, 2, 1)
// nodelay: 0:disable(default), 1:enable
// interval: internal update timer interval in millisec, default is 100ms 
// resend: 0:disable fast resend(default), 1:enable fast resend
// nc: 0:normal congestion control(default), 1:disable congestion control
int ikcp_nodelay(ikcpcb *kcp, int nodelay, int interval, int resend, int nc);


void ikcp_log(ikcpcb *kcp, int mask, const char *fmt, ...);

// setup allocator
void ikcp_allocator(void* (*new_malloc)(size_t), void (*new_free)(void*));

// read conv
uint32_t ikcp_getconv(const void *ptr);

]]
local libkcp
local function do_library(name)
    local so_name = "lib" .. name .. ".so"
    local macos_name = "lib" .. name .. ".dylib"
    local HS_SUCCESS = 0

    local function exists(path)
        local f = io.open(path, "r")
        if f then
            f:close()
            return true
        end
        return false
    end

    -- load library
    for k, _ in string.gmatch(package.cpath, "[^;]+") do
        local so_path = string.match(k, "(.*/)")
        if so_path then
            if exists(so_path .. so_name) then
                libkcp = ffi.load(so_path .. so_name)
                break
            end
            if jit.os == "OSX" then
                if exists(so_path .. macos_name) then
                    libkcp = ffi.load(so_path .. macos_name)
                    break
                end
            end
        end
    end
    if not libkcp then
        libkcp = ffi.load("kcp")
    end
end

do_library('kcp')
if not libkcp then
    error("load shared library libkcp failed")
end
local gc = ffi.gc
---@class resty.kcp
---@field user any
---@field handler any
local _M = {}
local mt = {
    __index = _M
}

local callback_cache = setmetatable({}, { __mode = 'kv' })
local function output(buf, len, kcp, user)
    local self = callback_cache[tostring(kcp)]
    if self and self.output then
        return self.output(buf, len, self.user)
    end
    return -1
end

local function finalize(ptr)
    if ptr ~= nil then
        libkcp.ikcp_release(ptr)
    end
end

function _M.ikcp_create(conv, user)
    local kcp = libkcp.ikcp_create(conv, nil)
    gc(kcp, finalize)
    return setmetatable({ user = user, handler = kcp }, mt)
end

function _M:ikcp_release()
    if self.handler ~= nil then
        gc(self.handler, nil)
        libkcp.ikcp_release(self.handler)
        self.handler = nil
    end
end

function _M:ikcp_set_output(callback)
    self.output = callback
    callback_cache[tostring(self.handler)] = self
    if self.handler.output == nil then
        self.handler.output = output
    end
end

---@return integer
function _M:ikcp_send(buffer, len)
    return libkcp.ikcp_send(self.handler, buffer, len)
end

---@return integer
function _M:ikcp_recv(buf, len)
    return libkcp.ikcp_recv(self.handler, buf, len)
end

function _M:ikcp_update(millisec)
    libkcp.ikcp_update(self.handler, millisec)
end

---@return integer
function _M:ikcp_check(current)
    return libkcp.ikcp_check(self.handler, current)
end

---@return integer
function _M:ikcp_input(received_udp_packet, received_udp_size)
    return libkcp.ikcp_input(self.handler, received_udp_packet, received_udp_size)
end

function _M:ikcp_flush()
    libkcp.ikcp_flush(self)
end

---@return integer
function _M:ikcp_peeksize()
    return libkcp.ikcp_peeksize(self.handler)
end

---@param mtu integer
---@return integer
function _M:ikcp_setmtu(mtu)
    return libkcp.ikcp_setmtu(self.handler, mtu)
end

-- set maximum window size: sndwnd=32, rcvwnd=32 by default
---@return integer
function _M:ikcp_wndsize(sndwnd, rcvwnd)
    return libkcp.ikcp_wndsize(self.handler, sndwnd, rcvwnd)
end

---@return integer
function _M:ikcp_waitsnd()
    return libkcp.ikcp_waitsnd(self.handler)
end

---@return integer
function _M:ikcp_nodelay(nodelay, interval, resend, nc)
    return libkcp.ikcp_nodelay(self.handler, nodelay, interval, resend, nc)
end

function _M:ikcp_allocator(malloc, free)
    libkcp.ikcp_allocator(malloc, free)
end

---@return integer
function _M:ikcp_getconv(ptr)
    return libkcp.ikcp_getconv(ptr)
end

local function ffi_logger(log, kcp, user)
    local self = callback_cache[tostring(kcp)]
    if self and self.logger then
        self:logger(log)
    end
end

function _M:set_logger(logger, masks)
    self.logger = logger
    callback_cache[tostring(self.handler)] = self
    if self.handler.writelog == nil then
        self.handler.logmask = masks or 0xffff
        self.handler.writelog = ffi_logger
    end
end

return _M
