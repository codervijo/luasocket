-----------------------------------------------------------------------------
-- HTTP/1.1 client support for the Lua language.
-- LuaSocket toolkit.
-- Author: Diego Nehab
-- RCS ID: $Id$
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- Declare module and import dependencies
-------------------------------------------------------------------------------
local socket = require("socket")
local url = require("socket.url")
local ltn12 = require("ltn12")
local mime = require("mime")
local string = require("string")
local base = _G
local table = require("table")
module("socket.http")

-----------------------------------------------------------------------------
-- Program constants
-----------------------------------------------------------------------------
-- connection timeout in seconds
TIMEOUT = 60 
-- default port for document retrieval
PORT = 80
-- user agent field sent in request
USERAGENT = socket._VERSION

-----------------------------------------------------------------------------
-- Extra sources and sinks
-----------------------------------------------------------------------------
socket.sourcet["http-chunked"] = function(sock)
    return base.setmetatable({
        getfd = function() return sock:getfd() end,
        dirty = function() return sock:dirty() end
    }, { 
        __call = function()
            -- get chunk size, skip extention
            local line, err = sock:receive()
            if err then return nil, err end 
            local size = base.tonumber(string.gsub(line, ";.*", ""), 16)
            if not size then return nil, "invalid chunk size" end
            -- was it the last chunk?
            if size <= 0 then 
                -- skip trailer headers, if any
                local line, err = sock:receive()
                while not err and line ~= "" do
                    line, err = sock:receive()
                end
                return nil, err
            else
                -- get chunk and skip terminating CRLF
                local chunk, err, part = sock:receive(size)
                if chunk then sock:receive() end 
                return chunk, err
            end
        end
    })
end

socket.sinkt["http-chunked"] = function(sock)
    return base.setmetatable({
        getfd = function() return sock:getfd() end,
        dirty = function() return sock:dirty() end
    }, { 
        __call = function(self, chunk, err)
            if not chunk then return sock:send("0\r\n\r\n") end
            local size = string.format("%X\r\n", string.len(chunk))
            return sock:send(size ..  chunk .. "\r\n")
        end
    })
end

-----------------------------------------------------------------------------
-- Low level HTTP API
-----------------------------------------------------------------------------
local metat = { __index = {} }

-- default connect function, respecting the timeout
local function connect(host, port)
    local c, e = socket.tcp()
    if not c then return nil, e end
    c:settimeout(TIMEOUT)
    local r, e = c:connect(host, port or PORT)
    if not r then 
        c:close()
        return nil, e 
    end
    return c
end

function open(host, port, user)
    -- create socket with user connect function, or with default
    local c = socket.try((user or connect)(host, port))
    -- create our http request object, pointing to the socket
    local h = base.setmetatable({ c = c }, metat)
    -- make sure the object close gets called on exception
    h.try = socket.newtry(function() h:close() end)
    return h 
end

function metat.__index:sendrequestline(method, uri)
    local reqline = string.format("%s %s HTTP/1.1\r\n", method or "GET", uri) 
    return self.try(self.c:send(reqline))
end

function metat.__index:sendheaders(headers)
    for i, v in base.pairs(headers) do
        self.try(self.c:send(i .. ": " .. v .. "\r\n"))
    end
    -- mark end of request headers
    self.try(self.c:send("\r\n"))
    return 1
end

function metat.__index:sendbody(headers, source, step)
    source = source or ltn12.source.empty() 
    step = step or ltn12.pump.step
    -- if we don't know the size in advance, send chunked and hope for the best
    local mode = "http-chunked"
    if headers["content-length"] then mode = "keep-open" end
    return self.try(ltn12.pump.all(source, socket.sink(mode, self.c), step))
end

function metat.__index:receivestatusline()
    local status = self.try(self.c:receive())
    local code = socket.skip(2, string.find(status, "HTTP/%d*%.%d* (%d%d%d)"))
    return self.try(base.tonumber(code), status)
end

function metat.__index:receiveheaders()
    local line, name, value
    local headers = {}
    -- get first line
    line = self.try(self.c:receive())
    -- headers go until a blank line is found
    while line ~= "" do
        -- get field-name and value
        name, value = socket.skip(2, string.find(line, "^(.-):%s*(.*)"))
        self.try(name and value, "malformed reponse headers")
        name = string.lower(name)
        -- get next line (value might be folded)
        line  = self.try(self.c:receive())
        -- unfold any folded values
        while string.find(line, "^%s") do
            value = value .. line
            line = self.try(self.c:receive())
        end
        -- save pair in table
        if headers[name] then headers[name] = headers[name] .. ", " .. value
        else headers[name] = value end
    end
    return headers
end

function metat.__index:receivebody(headers, sink, step)
    sink = sink or ltn12.sink.null()
    step = step or ltn12.pump.step
    local length = base.tonumber(headers["content-length"])
    local TE = headers["transfer-encoding"]
    local mode = "default" -- connection close
    if TE and TE ~= "identity" then mode = "http-chunked"
    elseif base.tonumber(headers["content-length"]) then mode = "by-length" end
    return self.try(ltn12.pump.all(socket.source(mode, self.c, length), 
        sink, step))
end

function metat.__index:close()
    return self.c:close()
end

-----------------------------------------------------------------------------
-- High level HTTP API
-----------------------------------------------------------------------------
local function adjusturi(reqt)
    local u = reqt
    -- if there is a proxy, we need the full url. otherwise, just a part.
    if not reqt.proxy and not PROXY then
        u = {
           path = socket.try(reqt.path, "invalid path 'nil'"),
           params = reqt.params,
           query = reqt.query,
           fragment = reqt.fragment
        }
    end
    return url.build(u)
end

local function adjustproxy(reqt)
    local proxy = reqt.proxy or PROXY 
    if proxy then
        proxy = url.parse(proxy)
        return proxy.host, proxy.port or 3128
    else
        return reqt.host, reqt.port
    end
end

local function adjustheaders(headers, host)
    local lower = {}
    -- override with user values
    for i,v in pairs(headers or lower) do
        lower[string.lower(i)] = v
    end
    lower["user-agent"] = lower["user-agent"] or USERAGENT
    lower["host"] = lower["host"] or host
    return lower
end

local default = {
    host = "",
    port = PORT,
    path ="/",
    scheme = "http"
}

local function adjustrequest(reqt)
    -- parse url if provided
    local nreqt = reqt.url and url.parse(reqt.url, default) or {}
    local t = url.parse(reqt.url, default)
    -- explicit components override url
    for i,v in pairs(reqt) do nreqt[i] = v end
    socket.try(nreqt.host, "invalid host '" .. base.tostring(nreqt.host) .. "'")
    -- compute uri if user hasn't overriden
    nreqt.uri = reqt.uri or adjusturi(nreqt)
    -- ajust host and port if there is a proxy
    nreqt.host, nreqt.port = adjustproxy(nreqt)
    -- adjust headers in request
    nreqt.headers = adjustheaders(nreqt.headers, nreqt.host)
    return nreqt
end

local function shouldredirect(reqt, code, headers)
    return headers.location and
           string.gsub(headers.location, "%s", "") ~= "" and
           (reqt.redirect ~= false) and
           (code == 301 or code == 302) and
           (not reqt.method or reqt.method == "GET" or reqt.method == "HEAD")
           and (not reqt.nredirects or reqt.nredirects < 5)
end

local function shouldauthorize(reqt, code)
    -- if there has been an authorization attempt, it must have failed
    if reqt.headers and reqt.headers["authorization"] then return nil end
    -- if last attempt didn't fail due to lack of authentication,
    -- or we don't have authorization information, we can't retry
    return code == 401 and reqt.user and reqt.password
end

local function shouldreceivebody(reqt, code)
    if reqt.method == "HEAD" then return nil end
    if code == 204 or code == 304 then return nil end
    if code >= 100 and code < 200 then return nil end
    return 1
end

-- forward declarations
local trequest, tauthorize, tredirect

function tauthorize(reqt)
    local auth = "Basic " ..  (mime.b64(reqt.user .. ":" .. reqt.password))
    reqt.headers["authorization"] = auth
    return trequest(reqt)
end

function tredirect(reqt, headers)
    return trequest {
        -- the RFC says the redirect URL has to be absolute, but some
        -- servers do not respect that
        url = url.absolute(reqt, headers["location"]),
        source = reqt.source,
        sink = reqt.sink,
        headers = reqt.headers,
        proxy = reqt.proxy,
        nredirects = (reqt.nredirects or 0) + 1,
        connect = reqt.connect
    }
end

function trequest(reqt)
    reqt = adjustrequest(reqt)
    local h = open(reqt.host, reqt.port, reqt.connect)
    h:sendrequestline(reqt.method, reqt.uri)
    h:sendheaders(reqt.headers)
    if reqt.source then h:sendbody(reqt.headers, reqt.source, reqt.step) end
    local code, headers, status
    code, status = h:receivestatusline()
    headers = h:receiveheaders()
    if shouldredirect(reqt, code, headers) then 
        h:close()
        return tredirect(reqt, headers)
    elseif shouldauthorize(reqt, code) then 
        h:close()
        return tauthorize(reqt)
    elseif shouldreceivebody(reqt, code) then
        h:receivebody(headers, reqt.sink, reqt.step)
    end
    h:close()
    return 1, code, headers, status
end

local function srequest(u, body)
    local t = {}
    local reqt = { 
        url = u,
        sink = ltn12.sink.table(t)
    }
    if body then 
        reqt.source = ltn12.source.string(body) 
        reqt.headers = { ["content-length"] = string.len(body) }
        reqt.method = "POST"
    end
    local code, headers, status = socket.skip(1, trequest(reqt))
    return table.concat(t), code, headers, status
end

request = socket.protect(function(reqt, body)
    if base.type(reqt) == "string" then return srequest(reqt, body)
    else return trequest(reqt) end
end)

--getmetatable(_M).__index = nil
