
local BlindManager
local ChipManager
local DeckManager
local EventBus
local Logger
local PlayerManager
local PotManager

TABLE_IS_SET = false

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
    DeckManager     = params.Services.DeckManager
    EventBus        = params.Services.EventBus
    Logger          = params.Services.ExternalLogConnection
    PlayerManager   = params.Services.PlayerManager
    PotManager      = params.Services.PotManager

    do -- EventBus Subscriptions
    EventBus.call("subscribe", {
      event_type = "welcome",
      callback_params = {
        service  = self,
        callback = "onGameStateUpdate"
      }
    })
    EventBus.call("subscribe", {
      event_type = "game_starting",
      callback_params = {
        service  = self,
        callback = "onGameStateUpdate"
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
local awaiting_external_script = false
function lockExternalScriptMutex() awaiting_external_script = true end
function unlockExternalScriptMutex() awaiting_external_script = false end
function isExternalScriptMutexUnlocked() return not awaiting_external_script end
local GameManager_onFinish_params = {
  service = self,
  callback = "unlockExternalScriptMutex",
  args = false
}

local associative_mutex = {}
function lockAssociativeMutex(index) associative_mutex[index] = true end
function unlockAssociativeMutex(index) associative_mutex[index] = false end
function isAssociativeMutexUnlocked(index) return not associative_mutex[index] end

-- If the game is known to be in progress then there is already a game_state loaded,
-- no additional game_state should be parsed.
local GAME_IN_PROGRESS = false

-- If the game is over, events of this game should be ignored
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
    log("Game not started yet. Deferring setup until next game state received.")
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

  local SETTING_TABLE_MUTEX = "setting-table-mutex"

  if not data.started_at then
    local log_message = logString("Game not started yet. Deferring to next game state.", "GameStateHandler.onGameStateReceived", "[INFO]", false, true)
    log(log_message)
    onFinish_params.service.call(onFinish_params.callback, onFinish_params.args)
    return
  end

  if not data.table or type(data.table) ~= "table" then
    print("Error: data.table is not an instance of Table")
    return
  end

  if not TABLE_IS_SET then
    local setupTable_params = {
      table = data.table,

      onStart_params = {
        service  = self,
        callback = "lockAssociativeMutex",
        args     = SETTING_TABLE_MUTEX
      },
      onFinish_params = {
        service  = self,
        callback = "unlockAssociativeMutex",
        args     = SETTING_TABLE_MUTEX
      }
    }
    setupTable(setupTable_params)
  end

  Wait.condition(
    function()
      TABLE_IS_SET = true
      handleDataForPlayers(params)
    end,
    function() return isAssociativeMutexUnlocked(SETTING_TABLE_MUTEX) end
  )
end

function setupTable(params)
  local table           = params.table
  local onStart_params  = params.onStart_params
  local onFinish_params = params.onFinish_params

  -- Lock the mutex
  onStart_params.service.call(onStart_params.callback, onStart_params.args)

  table.pot = _fixPot(table.pot, table.players)

  -- -- TODO: The game state should provide the deck layout if a game is in progress.
  -- -- TODO: The cards in play should be dealt from the deck same as in normal game playback

  -- TODO: Need to refactor this to use mutexes instead of frame spacing.
  -- TODO: The table, hands, etc. should be set based on the game state
  -- TODO: Clear the table and return cards as a first step
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
      callback    = "dealToRound",
      args        = table.current_round.current_round_type,
      log_message = "Dealing cards to the correct round."
    },
    {
      service     = ChipManager,
      callback    = "initializePot",
      args        = table.pot,
      log_message = "Initializing the pot."
    },
    -- Terminating service call
    {
      -- Unlock the mutex
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

function handleDataForPlayers(params)
  local data = params.data
  local onFinish_params = params.onFinish_params

  -- Update the state of each player in the game.
  -- A player's state informs of their last action which affects what they do on the table.
  for player_data in params.data.table.players do
    local player = PlayerManager.call("getPlayerById", player_data.user_id)
    player.state = player_data.state
  end

  local table                   = data.table
  local current_round           = table.current_round.current_round_type
  local current_player_position = table.current_round.current_player_position
  local current_player          = _getPlayerStateByPosition(table.players, current_player_position)
  if current_round == "unset" or current_round == "completed" 
    or current_player.user_type == "bot" then
    -- If the player is a bot then they'll submit their PlayerActionDto autonomously
    onFinish_params.service.call(onFinish_params.callback, onFinish_params.args)
    return
  end

  local current_stack_amount = _getValueOfChips(current_player.stack)

  -- It makes life easier if the player knows how much they need to chip in during their turn
  local minimum_chip_in = 0
  if current_round == "setup" then
    -- The player must ante either the small or big blind
    if current_player_position == table.small_blind_position then
      minimum_chip_in = table.current_hand.small_blind
    elseif current_player_position == table.big_blind_position then
      minimum_chip_in = table.current_hand.big_blind
    end
  else
    -- The minimum chip in is the difference between the value of the player's
    -- current bet and the value of the current aggressor's bet.
    
    local current_aggressor_bet_sum = _getCurrentMaxBet(table.players)
    local current_player_bet_sum = _getValueOfChips(current_player.current_bet)
    
    minimum_chip_in = current_aggressor_bet_sum - current_player_bet_sum
  end

  -- A human player must take their turn.
  local params = {
    -- Spoofing a PlayerActionDTO
    data = {
      player_id            = current_player.user_id,
      current_round        = current_round,
      current_stack_amount = current_stack_amount,
      minimum_chip_in      = minimum_chip_in
    },

    onFinish_params = onFinish_params
  }

  PlayerManager.call("startPlayerTurn", params)
end

function onGameOver(params)
  log("GameStateHandler.onGameOver not implemented", "Not implemented", "[ERROR]")
end
--[[
  Utils
]]

function _getPlayerStateByPosition(player_states, position)
  for player_state in player_states do
    if player_state.position == position then
      return player_state
    end
  end
end

function _getValueOfChips(chips)
  local value = 0
  for denomination, quantity in pairs(chips) do
    value = value + tonumber(denomination) * quantity
  end
  return value
end

function _getCurrentMaxBet(players)
  local max_bet = 0
  for player in players do
    local player_current_bet = _getValueOfChips(player.current_bet)
    if player_current_bet > max_bet then max_bet = player_current_bet end
  end
  return max_bet
end

--[[
  The pot in the gamestate also includes the current bets of players.
  Dunno if this is intentional, but i get too many chips on the board
  if I don't account for this.
]]
function _fixPot(pot, players)
  local fixed_pot = {}
  -- Cloning table, ignore.
  for denomination, count in pairs(pot) do fixed_pot[denomination] = count end

  for player in players do
    local current_bet = player.current_bet
    for denomination, count in pairs(current_bet) do
      fixed_pot[denomination] = fixed_pot[denomination] - count
    end
  end

  return fixed_pot
end