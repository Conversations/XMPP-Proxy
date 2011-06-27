local croxy = _G.croxy
local st = require "util.stanza"
local datetime = require "util.datetime".datetime
local eventname_from_stanza = require "core.sessionmanager".eventname_from_stanza
local proxy_sessions = require "core.sessionmanager".sessions["proxy"]
local destroy_session = require "core.sessionmanager".destroy_session
local datamanager = require "util.datamanager"
local add_task = require "util.timer".add_task
local os_time = os.time
local math_min = math.min
local t_remove = table.remove
local pairs, tonumber = paris, tonumber

local sm_xmlns = 'urn:xmpp:sm:3';
local sm_attrs = { xmlns = sm_xmlns };
local sm_feature = st.stanza("sm", sm_attrs);

local stream_ns = "http://etherx.jabber.org/"

croxy.events.add_handler("session-created", function (session)
  if session.type ~= 'client' then
    return
  end

  session.resumption_enabled = false
end, 10)

croxy.events.add_handler("stream-features", function (session, features)
  features:add_child(sm_feature)
end)

croxy.events.add_handler("incoming-stanza/"..stream_ns.."streams:features", function (session, features)
  -- Remove the sm feature
  local bind_advertised = false

  features:maptags(function (element)
    if element.name == "bind" and element.attr.xmlns == "urn:ietf:params:xml:ns:xmpp-bind" then
      bind_advertised = true
    end

    if element.name ~= "sm" and element.attr.xmlns ~= sm_xmlns then
      return element
    end
  end)

  if bind_advertised then
    features:add_child(sm_feature)
  end
end)

-- Session is a client or server session
function enable_sm(session) 
  if session.type ~= 'client' and session ~= 'server' then
    error('can not enable sm on '..session.type) 
  end
  
  session.last_acknowledged_stanza = 0
  session.handled_stanza_count = 0
  
  if session.sm_enabled ~= true then
    session.sm_enabled = true
    
    session.queue = {}
    
    local org_send = session.send
    
    session.send = function (self, t)
      org_send(self, t)

      if t.attr.xmlns == nil or t.attr.xmlns == "jabber:client" then
        session.queue[#session.queue + 1] = st.clone(t)
        
        if session.awaiting_ack ~= true then
          session.awaiting_ack = true

          -- Delay the actual sending to the next "cycle" to
          -- get batches of stanzas better acknowledged
          add_task(0, function ()
            org_send(self, st.stanza('r', sm_attrs))
          end)
        end
      end
    end
  end
end 

croxy.events.add_handler("outgoing-stanza/"..sm_xmlns..":enable", function (session, stanza)
  local enabled
  
  enabled = st.stanza('enabled', {xmlns = sm_xmlns, id=session.secret, resume='true'})
  
  session.resumption_enabled = true
  
  enable_sm(session.client)
  
  session.client:send(enabled)
  
  return true
end)

local function handle_ack_request(session, stanza)
  if session.sm_enabled ~= true then
     session.log('warn', 'Entity requested ack on non sm enabled session')
     
     return false
  end
  
  session:send(st.stanza('a', {xmlns = sm_xmlns, h=session.handled_stanza_count}))
  
  return true
end

croxy.events.add_handler("outgoing-stanza/"..sm_xmlns..":r", function (session, stanza)
  return handle_ack_request(session.client, stanza)
end)

croxy.events.add_handler("incoming-stanza/"..sm_xmlns..":r", function (session, stanza)
  return handle_ack_request(session.server, stanza)
end)

local function handle_ack(session, stanza)
  if session.sm_enabled ~= true then
     session.log('warn', 'Entity requested ack on non sm enabled session')
     
     return false
  end
  
  local handled_stanza_count = tonumber(stanza.attr.h) - session.last_acknowledged_stanza
  
  if handled_stanza_count > #session.queue then
    session.log('warn', 'Entity acked %d stanzas but only sent %d', handled_stanza_count, #session.queue)
  end
  
  for i=1,math_min(handled_stanza_count, #session.queue) do
  	t_remove(session.queue, 1)
  end
  
  session.last_acknowledged_stanza = session.last_acknowledged_stanza + handled_stanza_count;

  session.awaiting_ack = false

  return true
end

croxy.events.add_handler("outgoing-stanza/"..sm_xmlns..":a", function (proxy_session, stanza)
  return handle_ack(proxy_session.client, stanza)
end)

croxy.events.add_handler("incoming-stanza/"..sm_xmlns..":a", function (proxy_session, stanza)
  return handle_ack(proxy_session.server, stanza)
end)

croxy.events.add_handler("outgoing-stanza-prolog", function (proxy_session, stanza)
  if proxy_session.client.sm_enabled == true and (stanza.attr.xmlns == nil or stanza.attr.xmlns == "jabber:client") then
    proxy_session.client.handled_stanza_count = proxy_session.client.handled_stanza_count + 1
  end
end)

croxy.events.add_handler("incoming-stanza-prolog", function (proxy_session, stanza)
  if proxy_session.server.sm_enabled == true and (stanza.attr.xmlns == nil or stanza.attr.xmlns == "jabber:client") then
    proxy_session.server.handled_stanza_count = proxy_session.server.handled_stanza_count + 1
  end
end)

local function dispatch_offline_stanza(proxy_session, stanza)
  local stanza = stanza
  local handled
  
  if stanza:get_child('delay', 'urn:xmpp:delay') ~= true then
    stanza = st.clone(stanza)
    
    stanza:tag('delay', {
      xmlns='urn:xmpp:delay',
      from=croxy.config['host'],
      stamp=datetime(os.time())
    }):up()
  end
   
  handled = croxy.events.fire_event('offline-stanza'..eventname_from_stanza(stanza), proxy_session, stanza)
  
  if not handled then
    handled = croxy.events.fire_event('offline-stanza', proxy_session, stanza)
  end

  if not handled then
    -- this should not happened, as they should be saved by the default handler
    proxy_session.log("warn", "Offline stanza was not handled and will be droped: %s", stanza:pretty_print())
  end
end

croxy.events.add_handler("client-disconnected", function (session)
  if session.client.sm_enabled == true or true then
    session.client_disconnected = true
  
    ---
    -- The client session will be destroyed soon, so we need to save the 
    -- not acknownledged stanzas here, sent notifications as needed.
    ---
    local unhandled_stanzas = session.client.queue or {}
        
    for i, stanza in ipairs(unhandled_stanzas) do 
          dispatch_offline_stanza(session, stanza)
    end
  
    datamanager.store(session.secret, croxy.config['host'], 'stream-management', {
      handled_stanza_count = session.client.handled_stanza_count,
      last_acknowledged_stanza = session.client.last_acknowledged_stanza
    })
  
    return true
  end
end, 10)

croxy.events.add_handler('incoming-stanza', function (session, stanza)
  if session.client_disconnected == true then
    dispatch_offline_stanza(session, stanza)
    
    return true
  end
end)

-- To store offline stanzas
croxy.events.add_handler('offline-stanza', function (session, stanza)
  return datamanager.list_append(session.secret, croxy.config['host'], 'offline-stanzas', st.preserialize(stanza))
end)


croxy.events.add_handler("outgoing-stanza/"..sm_xmlns..":resume", function (source_proxy_session, stanza)
  if source_proxy_session.server and source_proxy_session.server.connected == true then
    -- When the client is connected to an server, resumption is not longer possible

    source_proxy_session.client:send(st.stanza("failed", sm_attrs):tag("unexpected-request", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}))

    return
  end

  local proxy_session_id = stanza.attr['previd']
  local proxy_session = proxy_session_id ~= nil and proxy_sessions[proxy_session_id] or nil

  if proxy_session == nil then
    -- The proxy session could not be found and therefore cannot be resumed

    source_proxy_session.client:send(st.stanza("failed", sm_attrs):tag("item-not-found", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}))

    return
  end

  if proxy_session.client_disconected ~= true then
    -- todo disconnect the old client
  end

  local sm_info = datamanager.load(proxy_session.secret, croxy.config['host'], 'stream-management')

  if sm_info == nil then
    source_proxy_session:send(st.stanza("failed", sm_attrs):tag("internal-server-error", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}))

    proxy_session.server:disconnect()
    destroy_session(proxy_session)

    return
  end

  -- Reconnect the client to the resumed proxy_session
  local client = source_proxy_session.client

  source_proxy_session:set_client(nil)
  destroy_session(source_proxy_session)

  proxy_session:set_server(client)
  proxy_session.client_disconnected = nil

  enable_sm(proxy_session.client)
  -- Restore old sm parameters
  proxy_session.client.handled_stanza_count = sm_info.handled_stanza_count
  proxy_session.client.last_acknowledged_stanza = sm_info.last_acknowledged_stanza

  local offline_stanzas = datamanager.list_load(session.secret, croxy.config['host'], 'offline-stanzas')

  if stanza.attr['h'] ~= nil then
    local h = stanza.attr['h']

    if h > proxy_session.client.last_acknowledged_stanza then
      -- The client has handled more stanzas than he was able to ack last time
      -- ack them now.
      local handled_stanza_count = tonumber(h) - proxy_session.client.last_acknowledged_stanza

      if handled_stanza_count > #offline_stanzas then
        proxy_session.log('warn', 'Entity acked %d stanzas but only sent %d', handled_stanza_count, #offline_stanzas)
      end

      for i=1,math_min(handled_stanza_count, #offline_stanzas) do
  	    t_remove(offline_stanzas, 1)
      end

      proxy_session.client.last_acknowledged_stanza = proxy_session.client.last_acknowledged_stanza + handled_stanza_count;
    elseif h < proxy_session.client.last_acknowledged_stanza then
      -- The client handled less stanzas than acknowledged... ignore this kind of error
      proxy_session.log("debug", "Client already acked %d handled stanzas but now claims to only have handled %d.",
        proxy_session.client.last_acknowledged_stanza, h)
    end
  end

  -- Stream has been resumed, tell the client that
  proxy_session.client:send(st.stanza("resumed", { xmlns = sm_xmlns, h = proxy_session.client.handled_stanza_count, previd=proxy_session.secret}))

  -- Now send all stored stanzas
  proxy_session.log("info", "Client resumed. Send %d offline stanzas.", #offline_stanzas)

  for _, stanza in ipars(offline_stanzas) do
    stanza = stanza.deserialize(stanza)

    proxy_session.client:send(stanza)
  end

  croxy.events.fire_event("client-resumed", proxy_session)
  -- Done =)
end, 10)