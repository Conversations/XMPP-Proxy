
local croxy = _G.croxy
local st = require "util.stanza"
local ssl = require "ssl"

local xmlns_starttls = 'urn:ietf:params:xml:ns:xmpp-tls';
local stream_ns = "http://etherx.jabber.org/"
local starttls_attr = { xmlns = xmlns_starttls };
local tls_feature = st.stanza("starttls", starttls_attr);

-- The server context is used when the proxy acts as server
-- therefore its used with client connections
local server_ssl_ctx
local client_ssl_ctx

croxy.events.add_handler("proxy-starting", function ()
  if croxy.config['require-client-encryption'] then
    tls_feature:tag("required"):up();
end
end)

croxy.events.add_handler("stream-features", function (session, features)
  if croxy.config['client-tls-disabled'] == true then
    session.log("warn", "Client tls support is disabled")
    return
  end

  -- Only add the tls feature if not already secured
  if session.secure ~= true then
    features:add_child(tls_feature);

    -- If we require tls only advertise it
    if croxy.config['require-client-encryption'] then
      return true
    end

  end
end, 100)

croxy.events.add_handler("outgoing-stanza/"..xmlns_starttls..":starttls", function (proxy_session, features)
  if proxy_session.client.secure ~= true then
    proxy_session.client:send(st.stanza("proceed", starttls_attr))
    proxy_session.client.conn:starttls(server_ssl_ctx)
    proxy_session.client.secure = false

    -- Reset the stream
    proxy_session.client.notopen = true
    proxy_session.client.stream:reset()
    
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
  session.server.conn:starttls(client_ssl_ctx)
  session.server.secure = false
 
  return true
end)

croxy.events.add_handler("register-config-defaults", function (config_defaults)
  config_defaults["ssl"] = {
    server = {
      mode = "server",
      protocol = "tlsv1",
      verify = "none",
      options = {"all", "no_sslv2"},
      ciphers = "ALL:!ADH:@STRENGTH"
    },
    client = {
      mode = "client",
      protocol = "tlsv1",
      verify = "peer",
      options = "all"
    }
  }
end)

croxy.events.add_handler("validate-config", function (croxy_config)
  local config = {
    server = {
      mode = "server",
      protocol = "tlsv1",
      verify = "none",
      options = {"all", "no_sslv2"},
      ciphers = "ALL:!ADH:@STRENGTH"
    },
    client = {
      mode = "client",
      protocol = "tlsv1",
      verify = "peer",
      options = "all"
    }
  }

  if croxy_config["ssl"]["server"]["key"] == nil then
    error("No ssl key found for the server context.")
  end

  if croxy_config["ssl"]["server"]["certificate"] == nil then
    error("No ssl cert found for the server context.")
  end

  for key, value in pairs(croxy_config["ssl"]["server"] or {}) do
    config["server"][key] = croxy_config["ssl"]["server"][key]
  end

  local ctx, err = ssl.newcontext(config["server"])

  if ctx ~= nil then
    server_ssl_ctx = ctx
  else
    error("Could not create server ssl context: "..err)
  end

  for key, value in pairs(croxy_config["ssl"]["client"] or {}) do
    config["client"][key] = croxy_config["ssl"]["client"][key]
  end

  ctx, err = ssl.newcontext(config["client"])

  if ctx ~= nil then
    client_ssl_ctx = ctx
  else
    error("Could not create client ssl context: "..err)
  end
end)
