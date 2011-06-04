
local croxy = _G.croxy
local st = require "util.stanza"

function notification_gateway(session, stanza)
---
-- <iq from='client@example.org' type='set'>
--   <notification-gateway xmlns='urn:conversations:notifications'>
--     <gateway>notification-gateway.conversations.im</gateway>
--     <user-identifier>5725075D-315D-41EE-B758-9A1F5D54488D</user-identifier>
--     <notify-content>
--       <from/>
--       <body/>
--     </notify-content>
--   </notification-gateway>
-- </iq>
---

    local gateway = stanza.tags[1]:get_child_text('gateway')
    local user_identifier = stanza.tags[1]:get_child_text('user-identifier')
    local notify_content = stanza.tags[1]:get_child('notify-content')
    
    session.notification_gateway = {}
    
    session.notification_gateway.gateway = gateway
    session.notification_gateway.user_identifier = user_identifier
    
    
    session.log("debug", "gateway %s and user-identifier %s", gateway, user_identifier)
    
    if notify_content:get_child('from') ~= nil then
        session.notification_gateway.sendFrom = true
    else
        session.notification_gateway.sendFrom = false
    end
    
    if notify_content:get_child('body') ~= nil then
        session.notification_gateway.sendBody = true
    else
        session.notification_gateway.sendBody = false
    end
    
    session.client:send(st.reply(stanza))
end

croxy.events.add_handler("outgoing-stanza/iq/urn:conversations:notifications:0:notification-gateway", notification_gateway, 10)

function client_disconnected(session)
  session.client_disconnected = true
  
  return true
end

croxy.events.add_handler("client-disconnected", client_disconnected, 10)

function handle_detached_message(session, stanza)
  if session.client_disconnected ~= true then
    return
  end
  
  local body = stanza:get_child('body')
  
  if body ~= nil then
  
---
-- <message from='server.org' to='gateway.conversations.im' type='normal'>
--   <notify xmlns='urn:conversations:notifications' user-identifier='5725075D-315D-41EE-B758-9A1F5D54488D'>
--     <from>Julia Capulet</from>
--     <body>To be or not to be, thats the question!</body>
--   </notify>
-- </message>
---
  
    local notify_stanza = st.message({to=session.notification_gateway.gateway, from=session.from})
    
    notify_stanza:tag('notify', {['user-identifier']=session.notification_gateway.user_identifier, xmlns='urn:conversations:notifications:0'})
    
    if session.notification_gateway.sendBody then
      notify_stanza:tag('body'):text(body:get_text()):up()
    end
    
    if session.notification_gateway.sendFrom then
      notify_stanza:tag('from'):text(stanza.attr["from"]):up()
    end
    
    notify_stanza:up()
    
    -- Not nice but working for now
    session.server:send(notify_stanza)
  end
  
  return true
end

croxy.events.add_handler("incoming-stanza/message", handle_detached_message)
