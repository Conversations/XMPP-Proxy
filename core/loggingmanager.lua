
local croxy = _G.croxy
local require = require
local print = print
local ipairs = ipairs

local logger = require "util.logger"

--- loggingmanager module
module "loggingmanager"

local logging_levels = { "debug", "info", "warn", "error", "critical" }

function setup()  
  croxy.log = logger.init("general")
end

function setup_sinks()
  --- Reset logger
  logger.reset()

  for _, level in ipairs(logging_levels) do
    logger.add_level_sink(level, log_sink)
  end
end

function log_sink(source_name, level, message, ...)
  print (source_name, level, message, ...)
end

setup()
setup_sinks()

return _m
