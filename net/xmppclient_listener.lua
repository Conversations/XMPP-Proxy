
local print = print

local sessionmanager = require "core.sessionmanager"

module "xmppclient_listener"

local xmppclient = {}

function xmppclient.onconnect(conn)
  local session = sessionmanager.new_session(conn, "client")
  
  session.log("info", "Client connected")
  
  conn.session = session
end

function xmppclient.onincoming(conn, data)
  local session = conn.session
  
  if session then
    session.log("info", data)
    local ok, err = session.stream:feed(data)
    
    if not ok then
      print ("error", err)
    else
      print ("ok")
    end
  end
end

function xmppclient.ondisconnect(conn, err)
  local session = conn.session
  
  session.log("info", "Client disconnected")
end

return xmppclient