
local _G, croxy = _G, croxy
local tostring, setmetatable, ipairs, pairs, type, newproxy, getmetatable = tostring, setmetatable, ipairs, pairs, type, newproxy, getmetatable

local collectgarbage = collectgarbage

local xmppstream = require "util.xmppstream"
local logger = require "util.logger"
local random_string = require "util.random_string"
local st = require "util.stanza"
local uuid_generate = require "util.uuid".generate
local traverse = require "util.traverse"

local print = print

module "sessionmanager"

local sessions = { 
	client = {},
	proxy = {},
	server = {}
}

local allocated_sessions_count = {
	client = 0,
	proxy = 0,
	server = 0
};

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

local default_stream_attr = { ["xmlns:stream"] = "http://etherx.jabber.org/streams", xmlns = "jabber:client", version = "1.0", id = "" };

session_mt = {}
session_mt.__index = session_mt

function new_session(conn, type, proxy_session)
  local session
  
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
    croxy.log("error", tostring(conn).." try to create session that is not of type client nor server. Type is "..tostring(type))
    return nil, "wrong type"
  end
    
  ---
  -- Trace how many sessions we have
  ---

  session.log = logger.init(logname)

  if true then
    -- For debugging how many sessions are allocated
    local log = session.log

    session.trace = newproxy(true);
    getmetatable(session.trace).__gc = function ()
      allocated_sessions_count[type] = allocated_sessions_count[type] - 1
      log("debug", "Deallocated session. Now %d allocated and %d open sessions of type %s exists.",
        allocated_sessions_count[type], #sessions[type], type)
    end
    allocated_sessions_count[type] = allocated_sessions_count[type] + 1
  
    log("debug", "Now %d allocated and %d open sessions of type %s exists",
      allocated_sessions_count[type], #sessions[type], type)
  end
  
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
  
  croxy.events.fire_event('session-created', session)
  
  return session
end

function session_mt:send(t)
  --self.log("debug", '-> '..tostring(t))
  self.conn:write(tostring(t))
end

function session_mt:send_opening()
  ---
  -- Send stream opening.
  ---
  local stream_attr = default_stream_attr
  stream_attr["id"] = uuid_generate()
  if self.type == "client" then
    stream_attr["from"] = croxy.config['host']
  end
  
  if self.to ~= nil then
    stream_attr["to"] = self.to
  end
  
  self:send("<?xml version='1.0'?>")
  self:send(st.stanza("stream:stream", stream_attr):top_tag());
end

proxy_session_mt = {}
proxy_session_mt.__index = proxy_session_mt

function new_proxy_session()
  local session = {}
  setmetatable(session, proxy_session_mt)
  
  session.log = logger.init("p_"..tostring(session):match("[a-f0-9]+$"))
  session.secret = random_string(40, "%a%d{)(%][%_-=+}:;\|")
  
  ---
  -- Insert the session in our session table.
  -- the secret is the proxy for easy refinding later
  ---

  sessions["proxy"][session.secret] = session
    
  return session
end

function proxy_session_mt:set_client(session)
  if self.client then
    self.client.proxy = nil
  end
  
  if session then
    session.proxy = self
  end
  
  self.client = session
end

function proxy_session_mt:set_server(session)
  if self.server then
    self.server.proxy = nil
  end
  
  if session then
    session.proxy = self
  end
  
  self.server = session
end

function retire_session(session)
  for key, value in pairs(session) do
     if key ~= "destroyed" and key ~= "type" then
         session[key] = nil
     end
  end
end

function destroy_session(session)
  
  if session.destroyed then
    return --- Do nothing if already destroyed
  end
  
  session.destroyed = true
  
  if session.type ~= "proxy" then
    sessions[session.type][session.conn] = nil
    session.conn.session = nil
    session.stream = nil
    if session.type == "server" then
      session.proxy:set_server(nil)
    elseif session.type == "client" then
      session.proxy:set_client(nil)
    end
  else
    sessions[session.type][session.secret] = nil
    destroy_session(session.client)
    destroy_session(session.server)
  end
  
  retire_session(session)
end

--[[

  Stream Callbacks

]]--


function streamopened(session, attr)
  session.log("info", "Stream opened")
  local proxy = session.proxy

  session.notopen = nil
 
  ---
  -- If we were enabling tls before (setting secure to false).
  -- we are now secured via tls.
  ---
  if session.secure == false then
    session.secure = true
  end
 

  if session.type == "client" then
    ---
    -- If the connection to the server stand
    -- just forward the header
    ---
    if proxy.server and proxy.server.connected then
      proxy.server.notopen = true
      proxy.server.stream:reset()
    
      proxy.server:send("<?xml version='1.0'?>")
      attr["xmlns:stream"] = 'http://etherx.jabber.org/streams'
      attr["xmlns"] = "jabber:client"
      proxy.server:send(st.stanza("stream:stream", attr):top_tag())
      return
    else
      streamopened_client(session, attr)
    end
  end
  
  if session.type == "server" then
    if proxy.server.connected then
      proxy.client:send("<?xml version='1.0'?>")
      attr["xmlns:stream"] = 'http://etherx.jabber.org/streams'
      attr["xmlns"] = "jabber:client"
      proxy.client:send(st.stanza("stream:stream", attr):top_tag())
      return
    else
      streamopened_server(session, attr)
    end
  end
end

function streamopened_client(session, attr)
  local host = attr.to

  if not host then
    session:close{
      condition = "improper-addressing",
	  text = "A 'to' attribute is required on stream headers"
	};
    return;
  end
  
  if host ~= croxy.config['host'] then
    session:close{
      condition = "host-unknown",
      text = "This server does not serve "..tostring(host)
    };
    return
  end
  
  session.proxy.from = attr.from
  
  session:send_opening()
  
  ---
  -- Compose the proxy-stream features.
  -- they will be replaced later with the stream features of
  -- the server.
  ---
  local features = st.stanza("stream:features");
  
  croxy.events.fire_event('stream-features', session, features)
  
  session:send(features)
end

function streamopened_server(session, attr)
  -- Do nothing for now
end

function streamclosed(session)
  session.log("info", "Stream closed")
  session:close()
end

function eventname_from_stanza(stanza)
  if stanza.attr.xmlns == nil then
    if stanza.name == "iq" and (stanza.attr.type == "set" or stanza.attr.type == "get") then
      event = "/iq/"..stanza.tags[1].attr.xmlns..":"..stanza.tags[1].name;
    else
      event = "/"..stanza.name;
    end
  else
    event = "/"..stanza.attr.xmlns..":"..stanza.name;
  end

  return event
end

function handlestanza(session, stanza)
  --session.log("debug", '<- '..tostring(stanza))
  
  if session.type == "client" then
    local handled
    
    handled = croxy.events.fire_event('outgoing-stanza-prolog', session.proxy, stanza)
  
    if not handled then
      handled = croxy.events.fire_event('outgoing-stanza'..eventname_from_stanza(stanza), session.proxy, stanza)
    end
        
    if not handled then
      handled = croxy.events.fire_event('outgoing-stanza', session.proxy, stanza)
    end
        
    if not handled then
      session.log("error", "The following outgoing stanza was not handled and will be droped: %s", stanza:pretty_print())
    end
  elseif session.type == "server" then
    local handled
    
    handled = croxy.events.fire_event('incoming-stanza-prolog', session.proxy, stanza)
  
    if not handled then
      handled = croxy.events.fire_event('incoming-stanza'..eventname_from_stanza(stanza), session.proxy, stanza)
    end
    
    if not handled then
      handled = croxy.events.fire_event('incoming-stanza', session.proxy, stanza)
    end
      
    if handled == nil then handled = false end
    
    if not handled then
      session.log("error", "The following incoming stanza was not handled and will be droped: %s", stanza:pretty_print())
    end
  else
    session.log("error", "Reviced stanza but session of type %s dont recive stanzas. Following stanza is droped: %s", session.type, stanza:pretty_print())
  end
end

function outgoing_stanza_route(proxy_session, stanza)
  if not proxy_session.server or not proxy_session.server.connected then
    proxy_session.log("error", "not connected")
    return
  end
  
  proxy_session.server:send(stanza)
  
  return true
end

function incoming_stanza_route(proxy_session, stanza)
  if not proxy_session.server or not proxy_session.server.connected then
    proxy_session.log("error", "not connected")
    return
  end
  
  proxy_session.client:send(stanza)
  
  return true
end

croxy.events.add_handler('outgoing-stanza', outgoing_stanza_route, -10)
croxy.events.add_handler('incoming-stanza', incoming_stanza_route, -10)

return _M
