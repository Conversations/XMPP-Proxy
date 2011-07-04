
local require, ipairs, type, error = require, ipairs, type, error

local croxy = _G.croxy
local sessions = require "core.sessionmanager".sessions
local add_task = require "util.timer".add_task

local function send_whitespace_keepalive()
  for _, session in ipairs(sessions["server"]) do
    session:send(" ")
  end

  for _, session in ipairs(sessions["client"]) do
    session:send(" ")
  end

  add_task(croxy.config["keepalive_intervall"], send_whitespace_keepalive)
end

croxy.events.add_handler("proxy-starting", function ()
  add_task(croxy.config["keepalive_intervall"], send_whitespace_keepalive)
end)

croxy.events.add_handler("register-config-defaults", function (config_defaults)
  config_defaults["keepalive_intervall"] = 500
end)

croxy.events.add_handler("validate-config", function (config)
  if type(config["keepalive_intervall"]) ~= "number" then
    error("Config value 'keepalive_intervall' must be an number.")
  end

  if config["keepalive_intervall"] < 20 then
    error("Config value 'keepalive_intervall' must be greater or equal to 20.")
  end
end)