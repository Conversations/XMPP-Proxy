
local _G, croxy = _G, croxy
local tostring, setmetatable, ipairs, pairs = tostring, setmetatable, ipairs, pairs

local xmppstream = require "util.xmppstream"
local logger = require "util.logger"
local random_string = require "util.random_string"

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

ProxySession = {}
ProxySession.__index = ProxySession

function new_proxy_session()
  local proxy = {}
  setmetatable(proxy, ProxySession)

  return proxy
end

function ProxySession:set_client(session)

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
end

function handlestanza(session, stanza)
  if session.type == "client" then
    local handled = croxy.events.fire_event('outgoing-stanza', stanza)
    
    if handled == nil then handled = false end
    
    if not handled then
      session.log("error", "The following stanza was not handled and will be droped: %s", stanza:pretty_print())
    end
  elseif session.type == "server" then
    local handled = croxy.events.fire_event('outgoing-stanza', stanza)
    
    if handled == nil then handled = false end
    
    if not handled then
      session.log("error", "The following stanza was not handled and will be droped: %s", stanza:pretty_print())
    end
  else
    session.log("error", "Reviced stanza but session of type %s don't recive stanzas. Following stanza is droped: %s", session.type, stanza:pretty_print())
  end
end

return _M
