
local croxy = _G.croxy
local st = require "util.stanza"
local socket = require "socket"
local wrapclient = require "net.server".wrapclient
local xmppserver_listener = require "net.xmppserver_listener"
local sessionmanager = require "core.sessionmanager"

local xmlns_xmpp_proxy = 'urn:conversations:xmpp-proxy';
local xmpp_proxy_attr = { xmlns = xmlns_xmpp_proxy };
local xmpp_proxy_feature = st.stanza("xmpp-proxy", xmpp_proxy_attr);

local function advertize_xmpp_proxy (session, features)
  features:add_child(xmpp_proxy_feature);
end

function handle_connect_stanza(session, stanza)
  local connect_element = stanza.tags[1]:get_child("connect")
  
  local to = connect_element.attr["to"]
  local host = connect_element.attr["host"]
  local port = tonumber(connect_element.attr["port"])
  
  if to == nil or host == nil or port == nil then
    session.client:send(st.error_reply(stanza, "modify", "bad-request"));
    return
  end
  
  session.log("debug", "client asks to connect to "..tostring(to).." using host "..tostring(host).." on port "..tostring(port))
  
  local conn = create_outgoing_connection(session, host, port)
  local server = sessionmanager.new_session(conn, "server", session)
  conn.session = server
  
  session.server.to = to
  
  if connect_element:get_child("starttls") ~= nil then
      session.server.should_starttls = true
  end
  
  session.client:send(st.reply(stanza))
end

local function xmpp_proxy (session, stanza)

  -- This stanza is not adressed to us, so leave it alone
  if stanza.attr.to ~= croxy.config['host'] then
    return nil
  end
  
  local xmpp_proxy_element = stanza.tags[1]
  local action_element = nil
  
  action_element = xmpp_proxy_element:get_child("connect")
  
  if action_element ~= nil then
    handle_connect_stanza(session, stanza)
    
    return true
  end
  
  session.log("debug", "got xmpp-proxy stanza"..tostring(element))
  
  return true
end

function create_outgoing_connection(proxy_session, host, port)

  local conn, handler = socket.tcp();
	
  if not conn then
    proxy_session.log("error", "Could not create tcp socket")
    return false
  end

  conn:settimeout(0);
  local success, err = conn:connect(host, port);
  if not success and err ~= "timeout" then
    proxy_session.log("error", "could not connect to %s:%d: %s", host, port, err)
	return false, err;
  end

  proxy_session.log("debug", "created outgoing connection")
  
  conn = wrapclient(conn, host, port, xmppserver_listener, "*a");
  
  return conn
end

function server_connected(session)
  local iq = st.iq({ type="set", to=session.client.from }):tag("xmpp-proxy", xmpp_proxy_attr):tag("status"):tag("connected"):up():up():up()
    
  session.server.notopen = true
  session.server.stream:reset()
  session.server.connected = true
  session.client:send(iq)
  session.client.notopen = true
  session.client.stream:reset()
  session.client.allows_stream_restarts = true
end

function server_stream_error(session, error)
  ---
  --  The server stream failed, fail the client stream too...
  ---
  
  local stanza = st.stanza("stream:error")
  
  for _, child in ipairs(error.tags) do
    stanza:add_child(child):up()
  end
  
  session.client:send(stanza)
  session.client:close()
end

function client_disconnected(session)
  session.server:close()
end

function bind(session, stanza)
  if #stanza.tags == 0 then
    return
  end

  local bindElement = stanza:get_child('bind', 'urn:ietf:params:xml:ns:xmpp-bind')
  
  if bindElement == nil then
    return
  end

  session.from = bindElement:get_child_text('jid')
  
  session.log('debug', 'got from %s', tostring(session.from))
end

croxy.events.add_handler("client-disconnected", client_disconnected, 0)
croxy.events.add_handler("server-stream-error", server_stream_error, 0)
croxy.events.add_handler("stream-features", advertize_xmpp_proxy, 0)
croxy.events.add_handler("server-connected", server_connected, 0)
croxy.events.add_handler("outgoing-stanza/iq/urn:conversations:xmpp-proxy:xmpp-proxy", xmpp_proxy, 10)
croxy.events.add_handler("incoming-stanza/iq", bind, 10)
