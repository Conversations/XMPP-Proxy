
local print, tostring = print, tostring

local sessionmanager = require "core.sessionmanager"
local xmppstream = require "util.xmppstream"

module "xmppclient_listener"

local xmppclient = {}

local stream_callbacks = { default_ns = "jabber:client", streamopened=sessionmanager.streamopened, streamclosed=sessionmanager.streamclosed, handlestanza=sessionmanager.handlestanza}

function stream_callbacks.error(session, error, data)
  print ("error"..tostring(session)..":"..tostring(error)..":"..tostring(data))
end

function xmppclient.onconnect(conn)
  local session = sessionmanager.new_session(conn, "client")
  
  session.log("info", "Client connected")
  session.stream = xmppstream.new(session, stream_callbacks)
  
  conn.session = session
end

function xmppclient.onincoming(conn, data)
  local session = conn.session
  
  if session then
    local ok, err = session.stream:feed(data)
    
    if not ok then
      session.log("debug", "Feeding stream returned error %q. Processed bytes where: %s", err, tostring(data))
      session:close("not-well-formed")
    end
  end
end

function xmppclient.ondisconnect(conn, err)
  local session = conn.session
  
  session.log("info", "Client disconnected")
end

return xmppclient