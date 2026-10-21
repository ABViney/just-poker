--[[
  Made this for two reasons:
  1. Reading logs in the console provided by Rolandostar's TTS extension in
      VSCode is great for realtime monitoring, but sucks for looking back at 
      logs. There's no Ctrl+F, there's no to-file logging afaik, and there's 
      only one log channel, so all messages occupy the same terminal.
  2. I can't listen to a game with my recorder and TTS at the same time, the
      connection consumes events from the server and they aren't repeated.
      Addressing the issues in (1.) allows me to record games for playback 
      later. I've had some bugs lately with being unable to find chips, and 
      I can't tell if the issue is from a divergence in state on my end or 
      the server's.

  How it works:
  I run an ASP.NET server locally that provides two endpoints:
  GET  /                            -- Checks if the service is live.
  POST /log/{app_id}/{file}/{level} -- Logs a message to `app_id`/`file` 
                                        with the prefix of `level` 
  Generally, app_id = game_id, file = trace/events.
  The POST body contains the message to log.
]]
local EXTERNAL_LOGGER_HOST = "http://localhost:5263/"

local CONNECTION_ESTABLISHED = false
local function _checkConnection()
  return WebRequest.get(
    EXTERNAL_LOGGER_HOST,
    function(instance)
      if not instance.is_error and instance.response_code == 200 then
        CONNECTION_ESTABLISHED = true
        local log_message = logString("Successfully connected to external logger", "ExternalLogConnection._checkConnection", "[INFO]", false, true)
        log("\n"..log_message)
      end
    end
  )
end

local GameStateHandler

function init(params)
  GameStateHandler = params.Services.GameStateHandler

  -- If we don't get a connection in less than a second then the
  -- server isn't live.
  _checkConnection()
  Wait.time(
    function()
      if not CONNECTION_ESTABLISHED then
        local log_message = logString("Failed to connect to external logger.", "ExternalLogConnection._checkConnection", "[INFO]", false, true)
        log("\n"..log_message)
      end
    end,
    0.75
  )
end

--[[
  If there is an established connection, formats a web request to the
  external logger. Otherwise does nothing.

  params = {
    game_id  = string, -- Denotes a folder
    file     = string, -- Denotes a file
    level    = string, -- Prefix for log level
    message  = string  -- Message to log
  }
]]
function logMessage(params)
  if not CONNECTION_ESTABLISHED then return end

  -- This isn't a great way to do this, but I don't have a 
  -- standardized way of storing state yet.
  local game_id = GameStateHandler.getVar("GAME_ID")

  local game_id = params.game_id or game_id
  local file    = params.file
  local level   = params.level
  local message = params.message

  if type(message) == "table" then
    message = JSON.encode(message)
  end

  if not (game_id and file and level and message) then
    local log_message = logString(params, "ExternalLogConnection.log\nMissing parameter", "[WARNING]", false, true)
    log(log_message)
  end

  local LOG_ENDPOINT = EXTERNAL_LOGGER_HOST.."log/"..game_id.."/"..file.."/"..level.."/"

  WebRequest.custom(
    LOG_ENDPOINT,
    "POST",
    true,
    message,
    {["Content-Type"]="text/plain"},
    function(instance)
      if instance.is_error or instance.response_code ~= 200 then
        local log_message = logString("Request denied with status code ["..instance.response_code.."]\n"..instance.text, "ExternalLogConnection.log", "[WARNING]", false, true)
        log(log_message)
        CONNECTION_ESTABLISHED = false -- If one request fails, subsequent will fail. Figure out why so this doesn't happen.
      end
    end
  )

end