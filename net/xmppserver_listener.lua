
local print, tostring, type = print, tostring, type

local croxy = croxy
local sessionmanager = require "core.sessionmanager"
local xmppstream = require "util.xmppstream"
local st = require "util.stanza"

module "xmppclient_server"

local xmppserver = {}

local stream_callbacks = { default_ns = "jabber:client", streamopened=sessionmanager.streamopened, streamclosed=sessionmanager.streamclosed, handlestanza=sessionmanager.handlestanza}
local stream_xmlns_attr = {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' }

function session_close(self, reason)
  
  if self.notopen then
    self:send("<?xml version='1.0'?>")
    self:send(st.stanza("stream:stream", default_stream_attr):top_tag());
  end
  if reason then
    local error_stanza
    
    if type(reason) == "string" then
      error_stanza = st.stanza("stream:error"):tag(reason, stream_xmlns_attr)
    elseif type(reason) == "table" then
      error_stanza = st.stanza("stream:error"):tag(reason.condition, stream_xmlns_attr):up();
      
      if reason.text then
        error_stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
      end
    end
  
    self:send(error_stanza)
    self.log("error", "Disconnect from server with error: %s", error_stanza:pretty_print())
  end
  self:send("</stream:stream>")

  -- Call handler
  self.conn:close()
  xmppserver.ondisconnect(self.conn)
  
  sessionmanager.destroy_session(self)
end

function stream_callbacks.error(session, error, data)
  if error == "stream-error" then
    croxy.events.fire_event("server-stream-error", session.proxy, data)
  else
    croxy.events.fire_event("server-stream-failed", session.proxy, error, data)
  end
  print ("error"..tostring(session)..":"..tostring(error)..":"..data:pretty_print())
end

function xmppserver.onconnect(conn)
  local session = conn.session

  session.log("info", "Connected to Server")
  session.not_open = true
  session.stream = xmppstream.new(session, stream_callbacks)
  session.close = session_close
  
  conn:setoption('keepalive', true)
  
  croxy.events.fire_event('server-connected', session.proxy)
end

function xmppserver.onincoming(conn, data)
  local session = conn.session
  
  if session then
    local ok, err = session.stream:feed(data)
    
    if not ok then
      session.log("debug", "Feeding stream returned error %q. Processed bytes where: %s", err, tostring(data))
      session:close("not-well-formed")
    end
  end
end

function xmppserver.ondisconnect(conn, err)
  local session = conn.session
  
  conn.session =  nil
  
  session.log("info", "Disconnected from Server")
end

function xmppserver.onstatus(conn, status)
  local session = conn.session
    
  if status == "ssl-handshake-complete" then
    session.secure = true
  
    croxy.events.fire_event('server-connected', session.proxy)
  end
end

return xmppserver