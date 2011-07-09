
local croxy = _G.croxy
local st = require "util.stanza"
local socket = require "socket"
local wrapclient = require "net.server".wrapclient
local xmppserver_listener = require "net.xmppserver_listener"
local sessionmanager = require "core.sessionmanager"

local xmlns_xmpp_proxy = 'urn:conversations:xmpp-proxy';
local xmpp_proxy_attr = { xmlns = xmlns_xmpp_proxy };
local xmpp_proxy_feature = st.stanza("xmpp-proxy", xmpp_proxy_attr);

local function create_outgoing_connection(proxy_session, host, port)

  local conn, handler = socket.tcp();

  if not conn then
    proxy_session.log("error", "Could not create tcp socket")
    return nil, nil
  end

  conn:settimeout(0);
  local success, err = conn:connect(host, port);
  if not success and err ~= "timeout" then
    proxy_session.log("error", "could not connect to %s:%d: %s", host, port, err)
	return nil, err;
  end

  proxy_session.log("debug", "created outgoing connection")

  conn = wrapclient(conn, host, port, xmppserver_listener, "*a");

  return conn, nil
end

local function handle_connect_stanza(proxy_session, stanza)
  local connect_element = stanza.tags[1]:get_child("connect")
  
  local to = connect_element.attr["to"]
  local host = connect_element.attr["host"]
  local port = tonumber(connect_element.attr["port"])
  -- todo figure out starttls here and check it's xmlns
  
  if not (to ~= nil and host ~= nil and port ~= nil and port > 0 and port < 65536) then
    proxy_session.client:send(st.error_reply(stanza, "modify", "bad-request"))
    return
  end

  -- The stanza seems to be valid, reply the client that it was ok
  proxy_session.client:send(st.reply(stanza))

  proxy_session.log("debug", "client asks to connect to "..tostring(to).." using host "..tostring(host).." on port "..tostring(port))
  
  local conn,err = create_outgoing_connection(proxy_session, host, port)

  if conn == nil then
    local iq

    iq = st.iq({ type="set", to= proxy_session.client.from }):tag("xmpp-proxy", xmpp_proxy_attr)

    iq:tag("status"):tag("error"):text(tostring(err)):up():up():up():up()

    proxy_session.client:send(iq)

    return
  end

  local server = sessionmanager.new_session(conn, "server", proxy_session)
  conn.session = server
  
  proxy_session.server.to = to
  
  if connect_element:get_child("starttls") ~= nil then
      proxy_session.server.should_starttls = true
  end
end

croxy.events.add_handler("outgoing-stanza/iq/"..xmlns_xmpp_proxy..":xmpp-proxy", function (proxy_session, stanza)

  -- This stanza is not addressed to us, so leave it alone
  if stanza.attr.to ~= croxy.config['host'] then
    return nil
  end
  
  local xmpp_proxy_element = stanza.tags[1]
  
  if xmpp_proxy_element:get_child("connect") ~= nil then
    handle_connect_stanza(proxy_session, stanza)
    
    return true
  else
    -- Don't know that action
    proxy_session.client:send(st.error_reply(stanza, "modify", "bad-request"))
  end

  return true
end, 10)


croxy.events.add_handler("outgoing-stanza/iq", function (proxy_session, stanza)
  -- This stanza is not addressed to us, so leave it alone
  if not (stanza.attr.to == croxy.config['host'] and (stanza.attr.type == "result" or stanza.attr.type == "error"))  then
    return nil
  end

  local xmpp_proxy_element = stanza:get_child("xmpp-proxy", xmlns_xmpp_proxy)

  if xmpp_proxy_element == nil then
    return nil
  end

  if xmpp_proxy_element:get_child("certificate-trust") ~= nil then
    local trusted = false

    if xmpp_proxy_element:get_child("certificate-trust"):get_child("trusted") then
      trusted = true
    end

    croxy.events.fire_event("server-verified-cert", proxy_session, trusted)

    return true
  end
end)

croxy.events.add_handler("server-connected", function (proxy_session)
  local iq

  iq = st.iq({ type="set", to=proxy_session.client.from, from = croxy.config['host']}):tag("xmpp-proxy", xmpp_proxy_attr):tag("server-certificate"):text(proxy_session.server.conn:getpeercertificate():pem()):up():up():up()
  proxy_session.client:send(iq)
  iq = st.iq({ type="set", to= proxy_session.client.from, from = croxy.config['host']}):tag("xmpp-proxy", xmpp_proxy_attr):tag("status"):tag("connected"):up():up():up()
  proxy_session.client:send(iq)

  -- Don't reset streams yet, we're expecting results from above
  proxy_session.server.connected = true
  proxy_session.client.allows_stream_restarts = true

  return true
end)

croxy.events.add_handler("server-verify-cert", function (proxy_session, certificate)
  local iq

  iq = st.iq({ type="get", to=proxy_session.client.from, from = croxy.config['host']})

  iq:tag("xmpp-proxy", xmpp_proxy_attr):tag("certificate-trust"):text(certificate:pem()):up():up():up()

  proxy_session.client:send(iq)

  return true
end)

croxy.events.add_handler("server-stream-error", function (proxy_session, error)
  ---
  --  The server stream failed, fail the client stream too...
  ---


  if proxy_session.client_disconnected ~= true then
    local stanza = st.stanza("stream:error")
  
    for _, child in ipairs(error.tags) do
      stanza:add_child(child):up()
    end
  
    proxy_session.client:send(stanza)
    proxy_session.client:close()
  end
end)

---
-- If nobody prevents us, we close the connection to the server
-- when the client disconnects
---
croxy.events.add_handler("client-disconnected", function (proxy_session)
  proxy_session.server:close()
end)

croxy.events.add_handler("incoming-stanza/iq", function (proxy_session, stanza)
  if #stanza.tags == 0 then
    return
  end

  local bindElement = stanza:get_child('bind', 'urn:ietf:params:xml:ns:xmpp-bind')
  
  if bindElement == nil then
    return
  end

  proxy_session.from = bindElement:get_child_text('jid')
  
  proxy_session.log('debug', 'Client bound its resource. The full JID of this proxy is now %s', proxy_session.from)
end, 10)

croxy.events.add_handler("stream-features", function (session, features)
  features:add_child(xmpp_proxy_feature);
end)
