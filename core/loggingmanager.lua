
local croxy = _G.croxy
local string, require, print, ipairs, os, pcall, tostring = string, require, print, ipairs, os, pcall, tostring

local termcolours = require "util.termcolours"
local getstyle, getstring = termcolours.getstyle, termcolours.getstring

local logger = require "util.logger"

--- loggingmanager module
module "loggingmanager"

local logging_levels = { "debug", "info", "warn", "error", "critical" }
local default_timestamp = "%b %d %H:%M:%S";

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
  
  local level_string
  
  if level == "debug" then level_string = getstring(style_verbose, "D")
  elseif level == "info" then level_string = getstring(style_informal, "I")
  elseif level == "warn" then level_string = getstring(style_warning, "W")
  elseif level == "error" then level_string = getstring(style_error, "E")
  elseif level == "critical" then level_string = getstring(style_error, "C")
  end

  local formatted_message;

  local ok, err = pcall(string.format(message, ...))

  if not ok then
    formatted_message = string.format("Message formating failed. err: %s\nformat: %s\nargs: %s", tostring(err), tostring(message), tostring(...))
  end

  local message = string.format("[%s] %15s [%s] %s", os.date(default_timestamp), source_name, level_string, formatted_message)
  
  print (message)
end

setup()
setup_sinks()

return _m
