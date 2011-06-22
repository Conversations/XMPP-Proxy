local croxy = _G.croxy
local st = require "util.stanza"
local math_min = math.min

local sm_xmlns = 'urn:xmpp:sm:3';
local sm_attrs = { xmlns = sm_xmlns };
local sm_feature = st.stanza("sm", sm_attrs);

function session_created(session)
  if session.type ~= 'client' then
    return
  end

  session.resumption_enabled = false
end

croxy.events.add_handler("session-created", session_created, 10)

croxy.events.add_handler("stream-features", function (session, features)
  features:add_child(sm_feature)
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
     
      if t.type == 'stanza' and (t.attr.xmlns == nil or t.attr.xmlns == "jabber:client") then
        session.queue[#queue + 1] = st.clone(t)
        
        if session.awaiting_ack ~= true then
          session.awaiting_ack = true
          
          org_send(self, st.stanza('r', sm_attrs))
        end
      end
    end
  end
end 

croxy.events.add_handler("outgoing-stanza/"..sm_xmlns..":enabled", function (session, stanza) 
  local enabled
  
  enabled = st.stanza('enabled', {xmlns = sm_xmlns, id=session.secret, resume='true'})
  
  session.resumption_enabled = true
  
  enable_sm(session.client)
  
  session.client:send(enabled)
  
  return true
end)

function handle_ack_request(session, stanza)
  if session.sm_enabled ~= true then
     session.log('warn', 'Entity requested ack on non sm enabled session')
     
     return false
  end
  
  session:send(st.stanza('a', {xmlns = sm_xmlns, h=session.handled_stanza_count}))
  
  return true
end

croxy.event.add_handler("outgoing-stanza/"..sm_xmlns..":r", function (session, stanza)
  return handle_ack_request(session.client, stanza)
end)

croxy.event.add_handler("incoming-stanza/"..sm_xmlns..":r", function (session, stanza)
  return handle_ack_request(session.server, stanza)
end)

function handle_ack(session, stanza)
  if session.sm_enabled ~= true then
     session.log('warn', 'Entity requested ack on non sm enabled session')
     
     return false
  end
  
  local handled_stanza_count = tonumber(stanza.attr.h) - session.last_acknowledged_stanza
  
  if handled_stanza_count > #session.queue then
    session.log('warn', 'Entity acked %d stanzas but only sent %d', handle_stanza_count, #session.queue)
  end
  
  for i=1,math_min(handled_stanza_count, #session.queue) do
  	t_remove(session.queue, 1)
  end
  
  session.last_acknowledged_stanza = session.last_acknowledged_stanza + handled_stanza_count;
  
  return true
end

croxy.event.add_handler("outgoing-stanza/"..sm_xmlns..":a", function (session, stanza)
  return handle_ack(session.client, stanza)
end)

croxy.event.add_handler("incoming-stanza/"..sm_xmlns..":a", function (session, stanza)
  return handle_ack(session.server, stanza)
end)

croxy.event.add_handler("outgoing-stanza-prolog", function (session, stanza)
  if session.client.sm_enabled == true then
    session.client.handled_stanza_count = session.client.handled_stanza_count + 1
  end
end)

croxy.event.add_handler("incoming-stanza-prolog", function (session, stanza)
  if session.server.sm_enabled == true then
    session.server.handled_stanza_count = session.server.handled_stanza_count + 1
  end
end)

croxy.events.add_handler("outgoing-stanza/iq/urn:conversations:notifications:0:notification-gateway", notification_gateway, 10)

croxy.events.add_handler("client-disconnected", function client_disconnected(session)
  if session.client.sm_enabled == true then
    session.client_disconnected = true
  
    return true
  else
    return nil
  end
end, 10)
