
local croxy = _G.croxy
local st = require "util.stanza"

local xmlns_starttls = 'urn:ietf:params:xml:ns:xmpp-tls';
local stream_ns = "http://etherx.jabber.org/"
local starttls_attr = { xmlns = xmlns_starttls };
local tls_feature = st.stanza("starttls", starttls_attr);

if croxy.config['require-client-encryption'] then
  tls_feature:tag("required"):up();
end

croxy.events.add_handler("stream-features", function (session, features)
  features:add_child(tls_feature);

  -- If we require tls only advertise it
  if croxy.config['require-client-encryption'] then
    return true
  end
end, 100)

croxy.events.add_handler("outgoing-stanza/"..xmlns_starttls..":starttls", function (session, features)
  if session.client.secure ~= true then
    session.client:send(st.stanza("proceed", starttls_attr))
    session.client.conn:starttls({
      mode = "server",
      protocol = "tlsv1",
      verify = "none",
      options = {"all", "no_sslv2"},
      key = croxy.config['key'],
      certificate = croxy.config['cert']
    })
    session.client.secure = false
    
    return true
  end
end)

croxy.events.add_handler("incoming-stanza/"..stream_ns.."streams:features", function (session, features)
  ---
  -- Because we work on the XMPP layer reconfiguring on
  -- the tls layer is not possible...
  ---
  features:maptags(function (element)
    if element.name ~= "starttls" then
      return element
    end
  end)
end)

croxy.events.add_handler("server-connected", function (session)
  ---
  -- If we need to bring up the tls we
  -- behave as client first and starttls
  ---
  if session.server.should_starttls and not session.server.secure then
    session.server:send_opening()
    
    return true
  end
end, 10)

croxy.events.add_handler("incoming-stanza/"..stream_ns.."streams:features", function (session, features)
  if not session.server.secure and features:child_with_ns(xmlns_starttls) then
    session.log("debug", "Start tls with server")
    
    session.server:send(st.stanza("starttls", starttls_attr))
    
    return true
  end
end, 10)

croxy.events.add_handler("incoming-stanza/"..xmlns_starttls..":proceed", function (session, stanza)
  session.server.conn:starttls({
    mode = "client",
    protocol = "tlsv1",
    verify = "peer",
    options = "all",
  })
  session.server.secure = false
 
  return true
end)

-- -- Use high priority
