
local croxy = _G.croxy
local st = require "util.stanza"

local xmlns_starttls = 'urn:ietf:params:xml:ns:xmpp-tls';
local starttls_attr = { xmlns = xmlns_starttls };
local tls_feature = st.stanza("starttls", starttls_attr);

if croxy.config['require-client-encryption'] then
  tls_feature:tag("required"):up();
end

local function advertize_tls (session, features)
  features:add_child(tls_feature);
  
  -- If we require tls only advertize it
  if croxy.config['require-client-encryption'] then
    return true
  end
end

local function clean_stream_features(session, features)
  ---
  -- Because we work on the XMPP layer reconfiguring on
  -- the tls layer is not possible...
  ---
  features:maptags(function (element)
    if element.name ~= "starttls" then
      return element
    end
  end)
end

local function server_connected(session)
  ---
  -- If we need to bring up the tls we
  -- behave as client first and starttls
  ---
  if session.server.should_starttls and not session.server.secure then
    session.server:send_opening()
    
    return true
  end
end

function start_server_tls(session, features)
  if not session.server.secure and features:child_with_ns(xmlns_starttls) then
    session.log("debug", "Start tls with server")
    
    session.server:send(st.stanza("starttls", starttls_attr))
    
    return true
  end
end

function server_proceed(session, stanza)
  session.server.conn:starttls({
    mode = "client",
    protocol = "tlsv1",
    verify = "peer",
    options = "all",
  })
  session.server.secure = false
 
  return true
end

croxy.events.add_handler("server-connected", server_connected, 10)
--croxy.events.add_handler("stream-features", advertize_tls, 100) -- Use high priority
croxy.events.add_handler("incoming-stanza/http://etherx.jabber.org/streams:features", clean_stream_features)
croxy.events.add_handler("incoming-stanza/http://etherx.jabber.org/streams:features", start_server_tls, 10)
croxy.events.add_handler("incoming-stanza/urn:ietf:params:xml:ns:xmpp-tls:proceed", server_proceed)
