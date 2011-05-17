
local _G, croxy = _G, croxy
local tostring, setmetatable, ipairs, pairs = tostring, setmetatable, ipairs, pairs

local xmppstream = require "util.xmppstream"
local logger = require "util.logger"
local random_string = require "util.random_string"
local st = require "util.stanza"

local print = print

module "sessionmanager"

local sessions = { 
	client = {},
	proxy = {},
	server = {}
}

--[[

Overview
===========

Client       +--------------------------------Proxy----------------------+        Server
             |                                                           |
  +============>client_session                           server_session<============+
             |   | - connection                        - connection  |   |
             |   | - xmpp stream                       - xmpp stream |   |
             |   |                                                   |   |
             |   +=================> proxy_session <=================+   |
             |                - holds client/server session              |
             |                - client queue                             |
             |                  > All unacked stanzas                    |
             |                  > If client becomes unaviable            |
             |                    store them on disk.                    |
             |                  > If client becomes avaiable             |
             |                    again resend them (with                |
             |                    appropiated delay date set)            |
             |                - secret for reattaching                   |
             |                                                           |
             +-----------------------------------------------------------+

]]--

session_mt = {}
session_mt.__index = session_mt

function new_session(conn, type, proxy_session)
  local session = nil
  
  session = (sessions[type] or {})[conn]
  
  if session then
    session.log("warn", "Tried to create two sessions for the same connection!")
    
    return session
  end
  
  croxy.log("info", "Create session of type %s", type)
  
  ---
  -- Create a new session
  ---
  session = {}
  setmetatable(session, session_mt)
  
  session.notopen = true
  session.conn = conn
  
  session.type = type
  
  ---
  -- Create logger for this session
  ---
  local logname
  if session.type == "client" then
    logname = "c_"..tostring(conn):match("[a-f0-9]+$")
  elseif session.type == "server" then
    logname = "s_"..tostring(conn):match("[a-f0-9]+$")
  else
    croxy.log("error", tostring(conn).." try to create session that is not of type client or server. Type is "..tostring(type))
    return nil, "wrong type"
  end
  
  session.log = logger.init(logname)
  
  ---
  -- If the caller didn't pass an proxy_session
  -- we need to create it now.
  ---
  local proxy = (proxy_session or new_proxy_session())
  
  if session.type == "client" then
    proxy:set_client(session)
  elseif session.type == "server" then
    proxy:set_server(session)
  end
  
  ---
  -- Register the session for later finding
  ---
  sessions["client"][conn] = session
  
  return session
end

function session_mt:send(t)
  self.conn:write(tostring(t))
end

local default_stream_attr = { ["xmlns:stream"] = "http://etherx.jabber.org/streams", xmlns = "jabber:client", version = "1.0", id = "" };

function session_mt:close(reason)
  
  if self.notopen then
    self:send("<?xml version='1.0'?>")
    self:send(st.stanza("stream:stream", default_stream_attr):top_tag());
  end
  if reason then
    local error = st.stanza("stream:error"):tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' })
  
    self:send(error)
    self.log("error", "Close sessions with error %s", error:pretty_print())
  end
  self:send("</stream:stream>")

  -- Call handler
  self.conn:close()
end

proxy_session_mt = {}
proxy_session_mt.__index = proxy_session_mt

function new_proxy_session()
  local proxy = {}
  setmetatable(proxy, proxy_session_mt)
  
  proxy.log = logger.init("p_"..tostring(proxy):match("[a-f0-9]+$"))
  
  return proxy
end

function proxy_session_mt:set_client(session)
  session.proxy = self
  self.client = session
end

function destroy_session(session)
  
  if session.destroyed then
    return --- Do nothing if already destroyed
  end
  
end

--[[

  Stream Callbacks

]]--


function streamopened(session, attr)
  session.log("info", "Stream opened")
  session.notopen = false
end

function streamclosed(session)
  session.log("info", "Stream closed")
  session:close()
end

function handlestanza(session, stanza)
  if session.type == "client" then
    local handled = croxy.events.fire_event('outgoing-stanza', session.proxy, stanza)
    
    if handled == nil then handled = false end
    
    if not handled then
      session.log("error", "The following outgoing stanza was not handled and will be droped: %s", stanza:pretty_print())
    end
  elseif session.type == "server" then
    local handled = croxy.events.fire_event('incoming-stanza', session.proxy, stanza)
    
    if handled == nil then handled = false end
    
    if not handled then
      session.log("error", "The following incoming stanza was not handled and will be droped: %s", stanza:pretty_print())
    end
  else
    session.log("error", "Reviced stanza but session of type %s don't recive stanzas. Following stanza is droped: %s", session.type, stanza:pretty_print())
  end
end

function outgoing_stanza_unconnected(session, stanza)
  session.log("error", "not connected")
end
croxy.events.add_handler('outgoing-stanza', outgoing_stanza_unconnected, -10)

return _M
