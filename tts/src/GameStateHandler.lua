
local BlindManager
local ChipManager
local DeckManager
local DealerDeckZone
local PlayerManager
local PotManager
local EventBus

--[[
    Ran into an issue where I couldn't access the PotManager by
    GUID in the onLoaded overload.
    Maybe this script runs before all objects are loaded?
    Just gonna hand off initialization to the Global script
    if I want access to other scripts.
]]
function init(params)
    BlindManager    = params.Services.BlindManager
    ChipManager     = params.Services.ChipManager
    EventBus        = params.Services.EventBus
    DeckManager     = params.Services.DeckManager
    PlayerManager   = params.Services.PlayerManager
    PotManager      = params.Services.PotManager

    do -- EventBus Subscriptions
    EventBus.call("subscribe", {
      event_type = "welcome",
      callback_params = {
        service  = self,
        callback = "onWelcome"
      }
    })
    EventBus.call("subscribe", {
      event_type = "game_starting",
      callback_params = {
        service  = self,
        callback = "onStartingGame"
      }
    })
    EventBus.call("subscribe", {
      event_type = "game_status_changed",
      callback_params = {
        service  = self,
        callback = "onGameStateUpdate"
      }
    })
    EventBus.call("subscribe", {
      event_type = "game_ending",
      callback_params = {
        service  = self,
        callback = "onGameOver"
      }
    })
    end
    
    log("GameStateHandler initialized")
end

do -- Config
  GAME_STATE_LOADED_DELAY = 1
end

--[[
  Since many actions in Tabletop Simulator are asynchronous, and lua doesn't have an
  async/await paradigm (that i know how to implement), I came up with a paradigm that
  allows me to block the flow of execution based on a mutex from the caller.

  When external services (other scripts) are called, I pass them a table containing
  expected data and the following table. This table describes what the external script
  should invoke upon completion of its actions.
]]
local GameManager_onFinish_params = {
  service = self,
  callback = "unlockExternalScriptMutex",
  args = false
}

-- If the game is known to be in progress then there is already a game_state loaded,
-- no additional game_state should be parsed.
local GAME_IN_PROGRESS = false

-- If the game is over, events of this game_id should be ignored
local GAME_OVER = false


function onWelcome(params)
  log("Welcome event received") -- DEBUG

  if GAME_OVER then
    log("Game is over, ignoring game_state_update")
    return
  end

  -- If the state was provided by the welcome message, all players may not have joined yet.
  -- If so, the game hasn't started yet and we can back out and wait for the "game_start"
  -- event to get a more complete view of the table.
  if not params.data.started_at then
    local onFinish_params = params.onFinish_params
    log("Game not started yet. Deferring game_state load to game_start event.")
    Wait.frames(
      function() onFinish_params.service.call(onFinish_params.callback) end,
      2
    )
    
    return
  end
  onGameStateReceived(params)
end

function onStartingGame(params)
  log("game_started message received") -- DEBUG
  onGameStateReceived(params)
end

function onGameStateUpdate(params)
  log("game_state_update event received") -- DEBUG
  onGameStateReceived(params)
end

--[[
  Game state can be set on two conditions:
    1. The "game_started" event is received (New game)
    2. GAME_IN_PROGRESS is false when a game_state_update event is received
]]
function onGameStateReceived(params)
  local data = params.data
  local onFinish_params = params.onFinish_params

  if GAME_IN_PROGRESS then
    -- We don't get events specifically for when a player is out
    for player_data in params.data.table.players do
      local player = PlayerManager.call("getPlayerById", player_data.user_id)
      player.state = player_data.state
    end
    onFinish_params.service.call(onFinish_params.callback, onFinish_params.args)
    return
  end

  if not data.table or type(data.table) ~= "table" then
    print("Error: data.table is not an instance of Table")
    return
  end
  GAME_IN_PROGRESS = true
  local table = data.table

  -- -- TODO: The game state should provide the deck layout if a game is in progress.
  -- -- TODO: The cards in play should be dealt from the deck same as in normal game playback
  local frame_delay = 5
  local game_setup_parameters = {
    {
      service     = PlayerManager,
      callback    = "setPlayers",
      args        = table.players,
      log_message = "Initializing, seating, and generating chips for players."
    },
    {
      service     = BlindManager,
      callback    = "configureButtonsFromTable",
      args        = table,
      log_message = "Moving blinds and dealer chip."
    },
    {
      service     = DeckManager,
      callback    = "setPlayers",
      args        = table.players,
      log_message = "Fixing the street to match the current round."
    },
    {
      service     = PotManager,
      callback    = "setPotFromState",
      args        = table,
      log_message = "Initializing the pot."
    },
    -- Terminating service call
    {
      service     = onFinish_params.service,
      callback    = onFinish_params.callback,
      args        = onFinish_params.args,
      log_message = "Game state initialized"
    }
  }

  Wait.frames(
    function()
      local index = 1
        for i=1, #game_setup_parameters do
          local setup_index = i
          Wait.condition(
            function()
              local service     = game_setup_parameters[index].service
              local callback    = game_setup_parameters[index].callback
              local args        = game_setup_parameters[index].args
              local log_message = game_setup_parameters[index].log_message
              
              log(log_message)
              service.call(callback, args)
              
              -- After 2 frames, increment the index.
              -- The preceeding code should have finished executing by now, so incrementing the index
              -- will allow the next condition to be fulfilled. 
              Wait.frames(
                function()
                  index = index + 1
                end,
                frame_delay
              )
            end,
            function() return index == setup_index end
          )
        end
    end,
    1
  )
end

function onGameOver(params)
  log("GameStateHandler.onGameOver not implemented", "Not implemented", "[ERROR]")
end