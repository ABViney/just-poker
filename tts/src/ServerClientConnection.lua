--[[
  The server is the source of truth. Most of what happens in this mod is
  dictated by what data the server provides.

  Messages from the server must be validated to ensure they fit our
  expectation, processed into a usable format, then published to the 
  EventBus so subscribers can act on new information.

  The flow of control for this is delicate. The connection to the server
  must be asynchronous to the actions taken on the table. The server may 
  provide several events in the time it takes for us to present the result 
  of one.
]]

local GameStateHandler
local Logger
local EventBus

function init(params)
  GameStateHandler = params.Services.GameStateHandler
  EventBus         = params.Services.EventBus
  Logger           = params.Services.ExternalLogConnection

  log("ServerClientConnection initialized")
end

local awaiting_event_bus = false
function lockExternalScriptMutex() awaiting_event_bus = true end
function unlockExternalScriptMutex() awaiting_event_bus = false end
function isExternalScriptMutexUnlocked() return not awaiting_event_bus end

ServerClientListener_onFinish_params = {
  service = self,
  callback = "unlockExternalScriptMutex"
}

do -- Connection configuration

--[[
  This holds a reference to the Game_ID on the server that this table should reflect.
  This value will either be read from the host or inferred from the response when 
  creating a game.
]]
GAME_ID = nil
function getGameId() return GAME_ID end

--[[
  Connecting to the server requires a valid auth_token.
  If mine isn't in setup as a placeholder, generate your own at:
  https://bahms.org/assets/poker-admin/ (in the User Management view)

  Note: Requires a Twitch account.
]]
AUTH_TOKEN = nil

HEADERS = {}

--[[
  This mod, and the poker server it uses, are both open source. You can deploy
  or fork your own if ours doesn't meet your needs:
  https://github.com/just-jane-inc/just-poker
]]
DEFAULT_POKER_SERVICE_ENDPOINT = "https://game.bahms.org/api/poker/game/{game_id}/state/listen"
POKER_SERVICE_ENDPOINT = nil

GAME_ENDPOINT                  = "https://game.bahms.org/api/poker/game"
DEFAULT_JOIN_GAME_ENDPOINT     = "https://game.bahms.org/api/poker/game/{game_id}/player"
DEFAULT_START_GAME_ENDPOINT    = "https://game.bahms.org/api/poker/game/{game_id}/started"
USER_ENDPOINT                  = "https://game.bahms.org/api/poker/user/me"

DEFAULT_START_HAND_ENDPOINT    = "https://game.bahms.org/api/poker/game/{game_id}/hand"
START_HAND_ENDPOINT    = nil

DEFAULT_DECK_ORDER_ENDPOINT    = "https://game.bahms.org/api/poker/game/{game_id}/deck"
DECK_ORDER_ENDPOINT   = nil

end -- Connection configuration


-- All JSON serialized messages received from polling are indexed by the order they are received.
local MESSAGE_QUEUE = {}

-- The event_queue's growth will outpace the rate at which events are processed.
-- An index
-- The index of the latest processed event
local CURRENT_EVENT_INDEX = 0
-- All parsed messages that are awaiting to be processed
local EVENT_QUEUE = {}


--[[
  Sets global variables used for connecting to a game.  

  params = {
    server_endpoint = string,
    game_id         = string,
    auth_token      = string
  }
]]
function setup(params)
  POKER_SERVICE_ENDPOINT = string.gsub(DEFAULT_POKER_SERVICE_ENDPOINT, "{game_id}", params.game_id)
  DECK_ORDER_ENDPOINT    = string.gsub(DEFAULT_DECK_ORDER_ENDPOINT, "{game_id}", params.game_id)
  START_HAND_ENDPOINT    = string.gsub(DEFAULT_START_HAND_ENDPOINT, "{game_id}", params.game_id)
  
  GAME_ID                = params.game_id
  GameStateHandler.setVar("GAME_ID", GAME_ID)
  
  AUTH_TOKEN             = params.auth_token
  HEADERS = {["Authorization"] = "Bearer "..AUTH_TOKEN}

  MESSAGE_QUEUE          = {}
  CURRENT_EVENT_INDEX    = 1
  EVENT_QUEUE            = {}
  
  if GAME_ID == "0" then -- Debug line. If GAME_ID is 0 then we use playback data
    log("Using playback data")
    MESSAGE_QUEUE = PREFAB_EVENT_QUEUE -- DEBUG LINE
  end
end

--[[
  The server facilitates everything that happens in game (with some caveats--see end of comment)

  There are two parts to setting up a listener:
  1. Send a POST request to the server to initialize a listener.
    (The server was designed for web socket connections. This is a compromise since TTS only supports HTTP)
  2. We poll that endpoint with GET requests

  params = {
    server_endpoint = string,
    game_id         = string,
    auth_token      = string
  }

  returns {true} if a 200 response was received
]]
function createEventListener(params)
  log("Setting up server-client connection")
  setup(params)

  log(params)

  if GAME_ID ~= "0" then -- Debug check. If GAME_ID is 0 then we use playback data
    WebRequest.custom(
      POKER_SERVICE_ENDPOINT,
      "POST",
      true,                               -- I AM handling the response body
      "",                                 -- Body is an empty string
      HEADERS,                            -- headers
      function(instance)                  -- callback_function
        -- instance is the web request instance after we've gotten a response
        
        if instance.is_error then
          local message = "Connection failed: " .. instance.response_code .. "\n" .. instance.text
          printToColor(
            message,
            "Black",
            "Grey"
          )
          return
        else
          local response_code = instance.response_code
          local initialization_response = instance.text
          log("Listener initialized")
          _logServerMessage(initialization_response)
  
          local body = logString(instance.text)
          log("Response code: " .. response_code .. '\n' .. body, "Connecting to listener", "[INFO]", false, true)
  
          pollEvents(1)
        end
    end)
  end

  -- pollEvents, processMessages, and processEvents should all operate independently and asynchronously.
  processMessages(1)
  processEvents(1)
end

--[[
  Polls the server for new events.
  Adds new events to the "message_queue" to be processed.

  index = int (Where in the message_queue this web request's response is stored)
]]
function pollEvents(index)
  local log_message = logString("Polling Event #"..index.."...", "ServerClientConnection.pollEvents", "[INFO]", false, true)
  log("\n"..log_message)

  WebRequest.custom(
    POKER_SERVICE_ENDPOINT,
    "GET",
    true,                               -- I AM handling the response body
    nil,                                -- Data I'm sending in the body
    HEADERS,                             -- headers

    function(instance)
      -- Expected errors: 504 (server timeout) and 502 (listener closed)
      if instance.is_error then
        local error = {
          status = instance.response_code,
          error  = instance.error,
        }
        local log_message = logString(error, "ServerClientConnection.pollEvents ("..index..")", "[ERROR]", false, true)
        log("\n"..log_message)

        Wait.time(
          function()
            pollEvents(index)
          end,
          0.1
        )
      end

      if instance.response_code == 504 then
        -- 504 is sent when the server timed out our request.
        -- Tabletop Simulator's WebRequest API doesn't have a TTL, in resposne to this we just need to poll again.
        Wait.time(
          function()
            pollEvents(index)
          end,
          0.1
        )
        return
      elseif instance.response_code == 502 then
        -- 502 is sent when the server no longer holds a reference for that game.
        -- This notifies us that the game is over and that we will no longer receive events for this game_id.
        local log_message = logString("Server has closed listener.", "ServerClientConnection.pollEvents ("..index..")", "[INFO]", false, true)
        log("\n"..log_message)
        return
      elseif instance.response_code >= 400 then
        -- The only response codes we should be getting are 200, 502, and 504.
        local log_message = logString("Unhandled response status ("..instance.response_code..")", "ServerClientConnection.pollEvents ("..index..")", "[CRITICAL]")
        log("\n"..log_message)
        return
      end

      -- The reponse body should not have any HTML in it.
      if instance.text == nil or string.find(instance.text, "<html>") then
        local log_message = logString({[instance.response_code] = instance.text or "nil"}, "ServerClientConnection.pollEvents ("..index..") Got some weird, third kind of response.", "[CRITICAL]", false, true)
        log("\n"..log_message)
        return
      end

      -- A successful status message gives us data that we may need to act on.
      -- Messages are stored to be eventually fielded by "processMessages"
      MESSAGE_QUEUE[index] = instance.text
      _logServerMessage(instance.text)
      pollEvents(index+1)
    end
  )
end

--[[
  Deserializes messages into the event_queue
]]
function processMessages(index)
  Wait.condition(
    function()
      local payload = JSON.decode(MESSAGE_QUEUE[index])
      -- once a message is decoded its reference is no longer needed
      MESSAGE_QUEUE[index] = nil
      -- Messages map to the event_queue 1-to-1.
      -- The order messages arrive from the server matters.
      EVENT_QUEUE[index] = payload
      processMessages(index+1)
    end,
    -- Waits until there's a message to parse.
    function() return MESSAGE_QUEUE[index] ~= nil end
  )
end

--[[
  Publish events to the EventBus, blocking until the EventBus has notified
  us that all subscribers have finished processing the event.
]]
function processEvents(index)
  --[[
    The first event may not arrive right away. Each call to this function creates a
    coroutine that waits until the payload associated with the received message is 
    decoded and it is time for this payload to be processed.
  ]]
  Wait.condition(
    function()
      local payload = EVENT_QUEUE[index]
      if payload and payload.event_type then
        local log_message = logString("Processing event #"..payload.id.." ["..payload.event_type.."]", "ServerClientConnection.processEvents", "[INFO]", false, true)
        log(log_message)
        local params = {
          event_type      = payload.event_type,
          data            = payload.data,
          onFinish_params = ServerClientListener_onFinish_params
        }
        lockExternalScriptMutex()
        -- I want a bit of delay before publishing the event to ensure
        -- that the log message prints first.
        Wait.frames(
          function() EventBus.call("publish", params) end,
          2
        )
      end

      EVENT_QUEUE[index] = false -- Handoff has happened. Free data up
      processEvents(index+1)
      CURRENT_EVENT_INDEX = CURRENT_EVENT_INDEX + 1
    end,
    function()
      return isExternalScriptMutexUnlocked() and EVENT_QUEUE[index] ~= nil and EVENT_QUEUE[index] ~= false
    end
  )
end

--[[
  Check if an auth token is valid and if so return the user profile for it.

  params = {
    ...  
    auth_token = string,

    onFinish_params = {
      service  = <Scripting Object>,
      callback = string
    }
  }
  
  Invokes the callback and passes it a table containing the decoded response (or an error) and the parameters
  passed to this function.
]]
function getUserByAuthToken(params)
  local auth_token = params.auth_token
  local onFinish_params = params.onFinish_params
  WebRequest.custom(
    USER_ENDPOINT,
    "GET",
    true,                               -- I AM handling the response body
    "",                                 -- Body is an empty string
    {["Authorization"] = "Bearer "..auth_token},
    function(instance)
      -- if instance.is_error then
      --   local error = {
      --     status = instance.response_code,
      --     error  = instance.error
      --   }
      --   local log_message = logString(error, "ServerClientConnection.getUserByAuthToken", "[ERROR]", false, true)
      --   log("\n"..log_message)
      -- end

      if instance.response_code == 200 then
        -- Success.
        local body = JSON.decode(instance.text)
        local result = {
          user = body.data,
          copy_of_args = params,
        }
        onFinish_params.service.call(onFinish_params.callback, result)
        return
      end

      local error = {response_code = instance.response_code, text = instance.text}
      local log_message = logString(error, "ServerClientConnection.getUserByAuthToken\nUnhandled response type.", "[ERROR]", false, true)
      log(log_message)

      local result = {
        error = error,
        copy_of_args = params
      }

      onFinish_params.service.call(onFinish_params.callback, result)
    end
  )
end

--[[
  Creates a game. Once the response is received, invokes the provided callback
  with the result.

  params = {
    auth_token = string,
    game_config_dto = <GameConfigDTO>,
    onFinish_params = {
      service  = string,
      callback = string
    }
  }
]]
function createGame(params)
  local auth_token      = params.auth_token
  local game_config_dto = params.game_config_dto
  local onFinish_params = params.onFinish_params
  local payload         = JSON.encode(game_config_dto)
  WebRequest.custom(
    GAME_ENDPOINT,
    "POST",
    true,
    payload,
    {["Authorization"] = "Bearer "..auth_token},
    function(instance)
      if instance.response_code == 200 then
        local json = JSON.decode(instance.text)
        onFinish_params.service.call(onFinish_params.callback, json)
        return
      end

      local result = {
        response_code = instance.response_code,
        error         = instance.text
      }
      onFinish_params.service.call(onFinish_params.callback, result)
    end
  )
end



--[[
  Creates a game. Once the response is received, invokes the provided callback
  with the result.

  params = {
    auth_token = string,
    game_config_dto = <GameConfigDTO>,
    onFinish_params = {
      service  = string,
      callback = string
    }
  }
]]
function startGame(params)
  local auth_token      = params.auth_token
  local onFinish_params = params.onFinish_params
  local start_game_endpoint = string.gsub(DEFAULT_START_GAME_ENDPOINT, "{game_id}", params.game_id)
  WebRequest.custom(
    start_game_endpoint,
    "POST",
    true,
    "",
    {["Authorization"] = "Bearer "..auth_token},
    function(instance)
      local body = JSON.decode(instance.text)
      if instance.response_code == 200 or body.data.error == "[2020]: game already started" then
        onFinish_params.service.call(onFinish_params.callback, {game_started = true})
        return
      end

      local result = {
        game_started  = false,
        errors = {
          response_code = instance.response_code,
          text          = instance.text
        }
      }
      onFinish_params.service.call(onFinish_params.callback, result)
    end
  )
end

--[[
  Posts a request to join a user to a game.
  The response for this is inconsequential

  params = {
    ...  
    auth_token = string,
    game_id    = string,

    onFinish_params = {
      service  = <Scripting Object>,
      callback = string
    }
  }
  
  Invokes the callback and passes it a table containing a boolean for if the player joined,
  an error if the player was not joined,
]]
function joinPlayerToGame(params)
  local auth_token = params.auth_token
  local onFinish_params = params.onFinish_params
  local join_game_endpoint = string.gsub(DEFAULT_JOIN_GAME_ENDPOINT, "{game_id}", params.game_id)

  WebRequest.custom(
    join_game_endpoint,
    "POST",
    true,                               -- I AM handling the response body
    "",                                 -- Body is an empty string
    {["Authorization"] = "Bearer "..auth_token},
    function(instance)
      local response_code = instance.response_code
      local body = JSON.decode(instance.text)
      if response_code == 200
        or (response_code == 400 and body.data.error == "player already joined table") then
        -- Success. Player is in the game.
        local result = {
          joined = true,
          copy_of_args = params,
        }
        onFinish_params.service.call(onFinish_params.callback, result)
        return
      end

      local error = {response_code = instance.response_code, text = instance.text}
      local log_message = logString(error, "ServerClientConnection.joinPlayerToGame\nUnhandled response type.", "[ERROR]", false, true)
      log(log_message)

      local result = {
        joined       = false,
        error        = error,
        copy_of_args = params
      }

      onFinish_params.service.call(onFinish_params.callback, result)
    end
  )
end

--[[
  Informs the server to start the next hand.

  onFinish_params = {
    service  = <Scripting Zone>,
    callback = string,
    args     = any
  }
]]
function startNextHand(onFinish_params)
  if GAME_ID == nil then
    onFinish_params.service.call(onFinish_params.callback, {
      success = false,
      status = 0,
      body = {
        data = {
          error = "Not listening to a game",
          error_code = 67
        }
      }
    })
    return
  end

  WebRequest.custom(
    START_HAND_ENDPOINT,
    "POST",
    true,
    "{}",
    HEADERS,

    function(instance)
      -- Expected errors: 504 (server timeout) and 502 (listener closed)
      if instance.is_error then
        local error = {
          status = instance.response_code,
          error  = instance.error,
        }
        local log_message = logString(error, "ServerClientConnection.startNexthand", "[ERROR]", false, true)
        log("\n"..log_message)
      end

      if instance.response_code == 400 then
        -- Bad request. Probably called this while in the middle of another hand.
        local log_message = logString("Response status: "..instance.response_code, "ServerClientConnection.startNextHand", "[WARNING]", false, true)
        log("\n"..log_message)
        return;
      elseif instance.response_code == 504 then
        -- 504 is sent when the server timed out our request.
        local log_message = logString("Response status: "..instance.response_code.."\nRequest timed out.", "ServerClientConnection.startNextHand", "[WARNING]", false, true)
        log("\n"..log_message)
        return
      elseif instance.response_code == 502 then
        -- 502 is sent when the server no longer holds a reference for that game.
        -- This notifies us that the game is over and that we will no longer receive events for this game_id.
        local log_message = logString("Response status: "..instance.response_code.."\nGame no longer valid.", "ServerClientConnection.startNextHand", "[WARNING]", false, true)
        log("\n"..log_message)
        return
      elseif instance.response_code >= 400 then
        -- The only response codes we should be getting are 200, 502, and 504.
        local log_message = logString("Unhandled response status: "..instance.response_code, "ServerClientConnection.startNextHand", "[ERROR]", false, true)
        log("\n"..log_message)
        return
      end

      local web_response_result = {
        success = not instance.is_error,
        status_code = instance.response_code,
        body = JSON.decode(instance.text)
      }

      log("\nServerClientConnection.startNextHand\nNext hand started.\n")
      onFinish_params.service.call(onFinish_params.callback, web_response_result)
    end
  )
end

--[[
  Fetches the order of the deck for the current GAME_ID for the current hand in the deck.
  Assumes the deck being fetched is for the game being listened to.

  The response from the server, if it is JSON, is serialized and passed to the callback provided
  by the caller.

  Because WebRequest in Tabletop Simulator is not synchronous, the content of the response body cannot
  be returned at the same time the function returns. The caller's callback must accept the serialized
  response in order for this function to be useful.

  onDeckOrderReceived_params = {
    service  = <Scripting Zone>,
    callback = string 
  }
]]
function getDeckOrder(deckOrderReceived_params)
  if GAME_ID == nil then
    deckOrderReceived_params.service.call(deckOrderReceived_params.callback, nil)
    return
  end

  WebRequest.custom(
    DECK_ORDER_ENDPOINT,
    "GET",
    true,
    nil,
    HEADERS,


    function(instance)
      -- Expected errors: 504 (server timeout) and 502 (listener closed)
      if instance.is_error then
        
        if instance.status_code == 504 then
          -- 504 is sent when the server timed out our request.
          -- Tabletop Simulator's WebRequest API doesn't have a TTL, in resposne to this we just need to poll again.
          log("ServerClientConnection.getDeckOrder\n504 error on GET deck order")
          return
        elseif instance.status_code == 502 then
          -- 502 is sent when the server no longer holds a reference for that game.
          -- This notifies us that the game is over and that we will no longer receive events for this game_id.
          log("ServerClientConnection.getDeckOrder\n502 error on GET deck order")
          return
        else
          -- The only response codes we should be getting are 200, 502, and 504.
          log("ServerClientConnection.getDeckOrder\n"..instance.status_code.." error on GET deck order")
          return
        end
      end

      if instance.text == nil or string.find(instance.text, "<html>") then
        local log_message = logString({[instance.response_code] = instance.text or "nil"}, "[ServerClientConnection.getDeckOrder] Got some weird, fifth kind of response.", "[CRITICAL]", false, true)
        log("\n"..log_message)
        return
      end


      local body = JSON.decode(instance.text)

      -- A successful status message gives us data that we may need to act on.
      -- Messages are stored to be eventually fielded by "processMessages"
      deckOrderReceived_params.service.call(deckOrderReceived_params.callback, body.data)
    end
  )

end

function _logServerMessage(message)
  local logMessage_params = {
    game_id = GAME_ID,
    file    = "events",
    level   = "INFO",
    message = message
  }
  Logger.call("logMessage", logMessage_params)
end

-- Preloaded data for testing that the finished game CAN play out a hand
PREFAB_EVENT_QUEUE = {
  [[{"id":0,"time_sent":"2026-10-21T04:15:38.671342856Z","event_type":"welcome","data":{"id":"4713","started_at":null,"ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[],"pot":{},"street":[],"current_round":{"bet":0,"current_player_position":0,"current_aggressor":0},"current_hand":{"id":0,"big_blind":0,"small_blind":0,"started_at":"0001-01-01T00:00:00Z"},"button_position":0,"small_blind_position":0,"big_blind_position":0}}}]],
  [[{"id":1,"time_sent":"2026-10-21T04:15:45.942571484Z","event_type":"game_starting","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":5,"500":1},"current_bet":{},"pot_contribution":0,"state":""},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":5,"500":1},"current_bet":{},"pot_contribution":0,"state":""}],"pot":{},"street":[],"current_round":{"bet":0,"current_player_position":0,"current_aggressor":0,"current_round_type":"unset"},"current_hand":{"id":0,"big_blind":0,"small_blind":0,"started_at":"0001-01-01T00:00:00Z"},"button_position":0,"small_blind_position":0,"big_blind_position":0}}}]],
  [[{"id":2,"time_sent":"2026-10-21T04:15:46.035446363Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":5,"500":1},"current_bet":{},"pot_contribution":0,"state":""},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":5,"500":1},"current_bet":{},"pot_contribution":0,"state":""}],"pot":{},"street":[],"current_round":{"bet":0,"current_player_position":0,"current_aggressor":0,"current_round_type":"unset"},"current_hand":{"id":0,"big_blind":0,"small_blind":0,"started_at":"0001-01-01T00:00:00Z"},"button_position":0,"small_blind_position":0,"big_blind_position":0}}}]],
  [[{"id":3,"time_sent":"2026-10-21T04:15:49.310897204Z","event_type":"hand_started","data":{"id":1,"big_blind_cost":100,"big_blind_position":0,"small_blind_cost":50,"small_blind_position":1,"button_position":1}}]],
  [[{"id":4,"time_sent":"2026-10-21T04:15:49.402764082Z","event_type":"round_started","data":{"round_type":"setup"}}]],
  [[{"id":5,"time_sent":"2026-10-21T04:15:49.480398423Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":5,"500":1},"current_bet":{},"pot_contribution":0,"state":"inactive"},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":5,"500":1},"current_bet":{},"pot_contribution":0,"state":"active"}],"pot":{},"street":[],"current_round":{"bet":50,"current_player_position":1,"current_aggressor":1,"current_round_type":"setup"},"current_hand":{"id":1,"big_blind":100,"small_blind":50,"started_at":"0001-01-01T00:00:00Z"},"button_position":1,"small_blind_position":1,"big_blind_position":0}}}]],
  [[{"id":6,"time_sent":"2026-10-21T04:15:49.563510805Z","event_type":"player_action","data":{"player_id":"107","intent":"ante","chips":{"50":1},"accepted_at":null}}]],
  [[{"id":7,"time_sent":"2026-10-21T04:15:49.649892898Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":5,"500":1},"current_bet":{},"pot_contribution":0,"state":"active"},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":4,"500":1},"current_bet":{"50":1},"pot_contribution":0,"state":"inactive"}],"pot":{"50":1},"street":[],"current_round":{"bet":100,"current_player_position":0,"current_aggressor":1,"current_round_type":"setup"},"current_hand":{"id":1,"big_blind":100,"small_blind":50,"started_at":"0001-01-01T00:00:00Z"},"button_position":1,"small_blind_position":1,"big_blind_position":0}}}]],
  [[{"id":8,"time_sent":"2026-10-21T04:15:49.734438708Z","event_type":"player_action","data":{"player_id":"105","intent":"ante","chips":{"100":1},"accepted_at":null}}]],
  [[{"id":9,"time_sent":"2026-10-21T04:15:49.825252085Z","event_type":"round_started","data":{"round_type":"pre_flop"}}]],
  [[{"id":10,"time_sent":"2026-10-21T04:15:49.920250825Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[{"rank":55,"suit":115},{"rank":52,"suit":100}],"stack":{"10":10,"100":4,"1000":4,"50":5,"500":1},"current_bet":{"100":1},"pot_contribution":0,"state":"inactive"},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[{"rank":52,"suit":104},{"rank":50,"suit":104}],"stack":{"10":10,"100":5,"1000":4,"50":4,"500":1},"current_bet":{"50":1},"pot_contribution":0,"state":"active"}],"pot":{"100":1,"50":1},"street":[],"current_round":{"bet":100,"current_player_position":1,"current_aggressor":1,"current_round_type":"pre_flop"},"current_hand":{"id":1,"big_blind":100,"small_blind":50,"started_at":"0001-01-01T00:00:00Z"},"button_position":1,"small_blind_position":1,"big_blind_position":0}}}]],
  [[{"id":11,"time_sent":"2026-10-21T04:15:50.011146918Z","event_type":"player_action","data":{"player_id":"107","intent":"fold","chips":{},"accepted_at":null}}]],
  [[{"id":12,"time_sent":"2026-10-21T04:15:50.089253608Z","event_type":"hand_payouts","data":[{"player_id":"105","chips":{"100":1,"50":1}}]}]],
  [[{"id":13,"time_sent":"2026-10-21T04:15:50.172278989Z","event_type":"round_started","data":{"round_type":"completed"}}]],
  [[{"id":14,"time_sent":"2026-10-21T04:15:50.250051739Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[{"rank":55,"suit":115},{"rank":52,"suit":100}],"stack":{"10":10,"100":5,"1000":4,"50":6,"500":1},"current_bet":{},"pot_contribution":100,"state":"inactive"},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[{"rank":52,"suit":104},{"rank":50,"suit":104}],"stack":{"10":10,"100":5,"1000":4,"50":4,"500":1},"current_bet":{},"pot_contribution":50,"state":"folded"}],"pot":{},"street":[],"current_round":{"bet":100,"current_player_position":1,"current_aggressor":1,"current_round_type":"completed"},"current_hand":{"id":1,"big_blind":100,"small_blind":50,"started_at":"0001-01-01T00:00:00Z"},"button_position":1,"small_blind_position":1,"big_blind_position":0}}}]],
  [[{"id":15,"time_sent":"2026-10-21T04:16:20.263753229Z","event_type":"hand_started","data":{"id":2,"big_blind_cost":100,"big_blind_position":1,"small_blind_cost":50,"small_blind_position":0,"button_position":0}}]],
  [[{"id":16,"time_sent":"2026-10-21T04:16:20.353500141Z","event_type":"round_started","data":{"round_type":"setup"}}]],
  [[{"id":17,"time_sent":"2026-10-21T04:16:20.4365993Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":6,"500":1},"current_bet":{},"pot_contribution":0,"state":"active"},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":4,"500":1},"current_bet":{},"pot_contribution":0,"state":"inactive"}],"pot":{},"street":[],"current_round":{"bet":50,"current_player_position":0,"current_aggressor":0,"current_round_type":"setup"},"current_hand":{"id":2,"big_blind":100,"small_blind":50,"started_at":"0001-01-01T00:00:00Z"},"button_position":0,"small_blind_position":0,"big_blind_position":1}}}]],
  [[{"id":18,"time_sent":"2026-10-21T04:16:20.519076388Z","event_type":"player_action","data":{"player_id":"105","intent":"ante","chips":{"50":1},"accepted_at":null}}]],
  [[{"id":19,"time_sent":"2026-10-21T04:16:20.610906134Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":5,"500":1},"current_bet":{"50":1},"pot_contribution":0,"state":"inactive"},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[],"stack":{"10":10,"100":5,"1000":4,"50":4,"500":1},"current_bet":{},"pot_contribution":0,"state":"active"}],"pot":{"50":1},"street":[],"current_round":{"bet":100,"current_player_position":1,"current_aggressor":0,"current_round_type":"setup"},"current_hand":{"id":2,"big_blind":100,"small_blind":50,"started_at":"0001-01-01T00:00:00Z"},"button_position":0,"small_blind_position":0,"big_blind_position":1}}}]],
  [[{"id":20,"time_sent":"2026-10-21T04:16:20.688585051Z","event_type":"player_action","data":{"player_id":"107","intent":"ante","chips":{"100":1},"accepted_at":null}}]],
  [[{"id":21,"time_sent":"2026-10-21T04:16:20.774174073Z","event_type":"round_started","data":{"round_type":"pre_flop"}}]],
  [[{"id":22,"time_sent":"2026-10-21T04:16:20.860502458Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[{"rank":81,"suit":99},{"rank":75,"suit":99}],"stack":{"10":10,"100":5,"1000":4,"50":5,"500":1},"current_bet":{"50":1},"pot_contribution":0,"state":"active"},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[{"rank":81,"suit":104},{"rank":74,"suit":104}],"stack":{"10":10,"100":4,"1000":4,"50":4,"500":1},"current_bet":{"100":1},"pot_contribution":0,"state":"inactive"}],"pot":{"100":1,"50":1},"street":[],"current_round":{"bet":100,"current_player_position":0,"current_aggressor":0,"current_round_type":"pre_flop"},"current_hand":{"id":2,"big_blind":100,"small_blind":50,"started_at":"0001-01-01T00:00:00Z"},"button_position":0,"small_blind_position":0,"big_blind_position":1}}}]],
  [[{"id":23,"time_sent":"2026-10-21T04:16:20.943088506Z","event_type":"player_action","data":{"player_id":"105","intent":"call","chips":{"50":1},"accepted_at":null}}]],
  [[{"id":24,"time_sent":"2026-10-21T04:16:21.020490155Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[{"rank":81,"suit":99},{"rank":75,"suit":99}],"stack":{"10":10,"100":5,"1000":4,"50":4,"500":1},"current_bet":{"50":2},"pot_contribution":0,"state":"inactive"},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[{"rank":81,"suit":104},{"rank":74,"suit":104}],"stack":{"10":10,"100":4,"1000":4,"50":4,"500":1},"current_bet":{"100":1},"pot_contribution":0,"state":"active"}],"pot":{"100":1,"50":2},"street":[],"current_round":{"bet":100,"current_player_position":1,"current_aggressor":0,"current_round_type":"pre_flop"},"current_hand":{"id":2,"big_blind":100,"small_blind":50,"started_at":"0001-01-01T00:00:00Z"},"button_position":0,"small_blind_position":0,"big_blind_position":1}}}]],
  [[{"id":25,"time_sent":"2026-10-21T04:16:21.110992217Z","event_type":"player_action","data":{"player_id":"107","intent":"all_in","chips":{},"accepted_at":null}}]],
  [[{"id":26,"time_sent":"2026-10-21T04:16:21.190140704Z","event_type":"round_started","data":{"round_type":"flop"}}]],
  [[{"id":27,"time_sent":"2026-10-21T04:16:21.271636116Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[{"rank":81,"suit":99},{"rank":75,"suit":99}],"stack":{"10":10,"100":5,"1000":4,"50":4,"500":1},"current_bet":{},"pot_contribution":100,"state":"inactive"},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[{"rank":81,"suit":104},{"rank":74,"suit":104}],"stack":{"10":0,"100":0,"1000":0,"50":0,"500":0},"current_bet":{},"pot_contribution":5300,"state":"active"}],"pot":{"10":10,"100":5,"1000":4,"50":6,"500":1},"street":[{"rank":53,"suit":99},{"rank":81,"suit":100},{"rank":84,"suit":104}],"current_round":{"bet":0,"current_player_position":1,"current_aggressor":1,"current_round_type":"flop"},"current_hand":{"id":2,"big_blind":100,"small_blind":50,"started_at":"0001-01-01T00:00:00Z"},"button_position":0,"small_blind_position":0,"big_blind_position":1}}}]],
  [[{"id":28,"time_sent":"2026-10-21T04:16:21.353602567Z","event_type":"player_action","data":{"player_id":"107","intent":"check","chips":{},"accepted_at":null}}]],
  [[{"id":29,"time_sent":"2026-10-21T04:16:21.436824301Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[{"rank":81,"suit":99},{"rank":75,"suit":99}],"stack":{"10":10,"100":5,"1000":4,"50":4,"500":1},"current_bet":{},"pot_contribution":100,"state":"active"},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[{"rank":81,"suit":104},{"rank":74,"suit":104}],"stack":{"10":0,"100":0,"1000":0,"50":0,"500":0},"current_bet":{},"pot_contribution":5300,"state":"all_in"}],"pot":{"10":10,"100":5,"1000":4,"50":6,"500":1},"street":[{"rank":53,"suit":99},{"rank":81,"suit":100},{"rank":84,"suit":104}],"current_round":{"bet":0,"current_player_position":0,"current_aggressor":1,"current_round_type":"flop"},"current_hand":{"id":2,"big_blind":100,"small_blind":50,"started_at":"0001-01-01T00:00:00Z"},"button_position":0,"small_blind_position":0,"big_blind_position":1}}}]],
  [[{"id":30,"time_sent":"2026-10-21T04:16:21.518857174Z","event_type":"player_action","data":{"player_id":"105","intent":"check","chips":{},"accepted_at":null}}]],
  [[{"id":31,"time_sent":"2026-10-21T04:16:21.602500278Z","event_type":"round_started","data":{"round_type":"turn"}}]],
  [[{"id":32,"time_sent":"2026-10-21T04:16:21.684564988Z","event_type":"round_started","data":{"round_type":"river"}}]],
  [[{"id":33,"time_sent":"2026-10-21T04:16:21.780762365Z","event_type":"hand_payouts","data":[{"player_id":"105","chips":{"100":2}},{"player_id":"107","chips":{"10":10,"100":3,"1000":4,"50":6,"500":1}}]}]],
  [[{"id":34,"time_sent":"2026-10-21T04:16:21.858459273Z","event_type":"round_started","data":{"round_type":"completed"}}]],
  [[{"id":35,"time_sent":"2026-10-21T04:16:21.936276576Z","event_type":"game_status_changed","data":{"id":"4713","started_at":"2026-10-21T04:15:45.942261894Z","ended_at":null,"game_config":{"player_count":2,"starting_chips":{"10":10,"100":5,"1000":4,"50":5,"500":1},"big_blind":100,"small_blind":50,"auto_starts_hands":false,"chip_denominations":[10,50,100,500,1000],"bot_turn_timeout":0},"table":{"players":[{"user_id":"105","display_name":"flow","user_type":"bot","position":0,"hole":[{"rank":81,"suit":99},{"rank":75,"suit":99}],"stack":{"10":10,"100":7,"1000":4,"50":4,"500":1},"current_bet":{},"pot_contribution":100,"state":"inactive"},{"user_id":"107","display_name":"red","user_type":"bot","position":1,"hole":[{"rank":81,"suit":104},{"rank":74,"suit":104}],"stack":{"10":10,"100":3,"1000":4,"50":6,"500":1},"current_bet":{},"pot_contribution":5300,"state":"all_in"}],"pot":{},"street":[{"rank":53,"suit":99},{"rank":81,"suit":100},{"rank":84,"suit":104},{"rank":54,"suit":115},{"rank":65,"suit":100}],"current_round":{"bet":0,"current_player_position":0,"current_aggressor":1,"current_round_type":"completed"},"current_hand":{"id":2,"big_blind":100,"small_blind":50,"started_at":"0001-01-01T00:00:00Z"},"button_position":0,"small_blind_position":0,"big_blind_position":1}}}]]
}