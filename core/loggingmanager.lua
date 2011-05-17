
local croxy = _G.croxy
local string, require, print, ipairs = string, require, print, ipairs

local termcolours = require "util.termcolours"
local getstyle, getstring = termcolours.getstyle, termcolours.getstring

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
  local style_verbose = getstyle("magenta", "bold")
  local style_informal = getstyle("green", "bold")
  local style_warning = getstyle("yellow", "bold")
  local style_error = getstyle("red", "bold")
  
  local level_string = nil
  
  if level == "debug" then level_string = getstring(style_verbose, "D")
  elseif level == "info" then level_string = getstring(style_informal, "I")
  elseif level == "warn" then level_string = getstring(style_warning, "W")
  elseif level == "error" then level_string = getstring(style_error, "E")
  elseif level == "critical" then level_string = getstring(style_error, "C")
  end
  
  local message = string.format("%15s [%s] %s", source_name, level_string, string.format(message, ...))
  
  print (message)
end

setup()
setup_sinks()

return _m
