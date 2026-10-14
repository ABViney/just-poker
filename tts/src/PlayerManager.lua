--[[
{ 
  "user_id": string, // steam_id or bot ID
  "display_name": string, // steam name or bot ID
  "user_type": string, // "person|bot"
  "position": 0, // Distance from dealer. 0 = Red
  "hole": [
    {
      "rank": 53,
      "suite": 99
    },
    {
      "rank": 51,
      "suite": 99
    }
  ],
  "chips": {
    "10": 35,
    "100": 5,
    "1000": 0,
    "50": 10,
    "500": 1
  },
  "bet": 150,
  "state": string // "unset|inactive|active|folded|all_in|won|out",
  "color": Red|Orange|Yellow|Green|Teal|Blue|Purple|Pink,
  "zones": -- See Global.lua: onLoad
},
]]

local ChipManager
local DeckManager
local PotManager
local TurnManager

local ChipExchangeZone
local ChipExchangeStackZone
local PlayerZones
local PotZone
local SEATS = {'Red', 'Orange', 'Yellow', 'Green', 'Teal', 'Blue', 'Purple', 'Pink'}

-- All players in this game, ordered by position
local PLAYERS = {}
local CURRENT_PLAYER = nil

function init(params)
  ChipManager  = params.Services.ChipManager
  DeckManager  = params.Services.DeckManager
  PotManager   = params.Services.PotManager

  ChipExchangeZone         = params.Zones.chip_exchange_zone
  ChipExchangeStackZone    = params.Zones.chip_exchange_stack_zone
  PlayerZones              = params.Zones.PlayerZones
  PotZone                  = params.Zones.pot_zone
  log("PlayerManager initialized")
end

do -- Config
  PLAYER_START_TURN_DELAY = 1
  PLAYER_END_TURN_DELAY = 1

  REVEAL_HANDS_DELAY = 2
end

local animating_player_action = false
function lockExternalScriptMutex(args) animating_player_action = true end
function unlockExternalScriptMutex(args) animating_player_action = false end
function isExternalScriptMutexUnlocked() return not animating_player_action end

local Animation_onFinish_params = {
  service = self,
  callback = "unlockExternalScriptMutex"
}

local awaiting_player_finish_turn = false
function lockPlayerTurnMutex() awaiting_player_finish_turn = true end
function unlockPlayerTurnMutex() awaiting_player_finish_turn = false end
function isPlayerTurnMutexUnlocked() return not awaiting_player_finish_turn end

PlayerTurn_onFinish_params = {
  service = self,
  callback = "unlockPlayerTurnMutex"
}

-- Testing a new type of mutex for parallel asynchronous (See animateBet)
local associative_mutex = {}
function lockAssociativeMutex(index) associative_mutex[index] = true end
function unlockAssociativeMutex(index) associative_mutex[index] = false end
function isAssociativeMutexUnlocked(index) return not associative_mutex[index] end

--[[
  params = {
    data = {
      player_id = string

    },

    onFinish_params = {
      service   = <Scripting Zone>,
      callback  = string (function name in service's script),
      args      = table (arguments to pass to callback)
    }
  }
]]
function startPlayerTurn(params)
  local player = getPlayerById(params.data.player_id)
  log({"Starting " .. player.display_name.."'s turn"}, "PlayerManager.startPlayerTurn", "[INFO]", false, true)
  broadcastToAll(player.display_name.."'s turn", player.color)

  lockPlayerTurnMutex()

  if player.user_type == "bot" then
    local animate_player_params = {
      data = params.data,
      onFinish_params = PlayerTurn_onFinish_params
    }
    animatePlayerAction(animate_player_params)
  end

  Wait.condition(
    function() endPlayerTurn(params) end,
    isPlayerTurnMutexUnlocked
  )
end

function endPlayerTurn(params)
  local player = getPlayerById(params.data.player_id)
  local onFinish_params = params.onFinish_params
  -- Todo: Map intents to different broadcasts that relay more expressive
  -- messages
  broadcastToAll(player.display_name.." has "..player.state, player.color)
  Wait.time(
    function() onFinish_params.service.call(onFinish_params.callback) end,
    PLAYER_END_TURN_DELAY
  )
end

function revealActiveHands(onFinish_params)
  log("Revealing active hands")
  local promises = {}
  local players_that_must_reveal = {}
  for player in PLAYERS do
    log(player.display_name.." has state "..player.state)
    if player.state ~= "fold" and player.state ~= "out" then
      player.state = "show"
      table.insert(promises, false)
      table.insert(players_that_must_reveal, player)
    end
  end

  function _promisesAreFulfilled()
    for promise_fulfilled in promises do
      if not promise_fulfilled then
        return false
      end
    end
    return true
  end

  if #promises == 0 then
    log("No players have an active hand", "PlayerManager.revealActiveHands", "[ERROR]", false, true)
    return
  end

  if #promises == 1 then
    log("Only one player is active. No reveal required.")
    onFinish_params.service.call(onFinish_params.callback, onFinish_params.args)
    return
  end

  log(#players_that_must_reveal.." players must reveal their cards.")
  
  for i, player in ipairs(players_that_must_reveal) do
    local index = i
    local mutex_key = "Show_"..index
    
    if player.user_type == "bot" then
      log("Animating "..player.display_name.."'s action")
      lockAssociativeMutex(mutex_key)

      local params = {
        player          = player,

        onFinish_params = {
          service  = self,
          callback = "unlockAssociativeMutex",
          args     = mutex_key
        }
      }
      DeckManager.call("movePlayerCardsToReflectIntent", params)

      Wait.condition(
        function() log("Unlocking "..mutex_key) promises[index] = true end,
        function() return isAssociativeMutexUnlocked(mutex_key) end
      )
    end
    
    -- Todo: Figure out how to ensure players have shown their cards.
    -- That'll be fun :^)
  end

  Wait.condition(
    function() onFinish_params.service.call(onFinish_params.callback, onFinish_params.args) end,
    _promisesAreFulfilled
  )
end

--[[
  Setting the table from an existing state.

  The PLAYERS table will look like this after this function is ran:
  {
    {
      user_id = string,
      display_name = string,
      user_type = string,
      color = string,
      position = int,
      state = string,
      hole = {
        <Card>,
        <Card>
      },
      stack = {
        <Chip>,
        ...
      },
      stack_sum = int,
      bet = {
        <Chip>,
        ...
      },
      chips
      bet_sum = int,
      pot_contribution = int,
      zones = {
        hand_zone = <Scripting Zone>,
        bet_zone = <Scripting Zone>,
        blind_zone = <Scripting Zone>,
        stack_zone = <Scripting Zone>
      }
    },
    ...
  }
--]]
function setPlayers(players)

  log("Setting players from table state")
  PLAYERS = {}

  -- Upload players in the game to the global variable
  for _, player in ipairs(players) do
    PLAYERS[#PLAYERS+1] = player
  end
  -- Order players by their position so we can iterate through them naturally
  table.sort(PLAYERS, function(a, b) return a.position < b.position end)

  -- Figuring out which seats players can occupy. If there's less
  -- than 8, then players should be centered in front of the dealer.
  local starting_seat = math.floor(#SEATS/2) - math.floor(#players/2 - 1)
  for player in PLAYERS do
    player.color = SEATS[player.position + starting_seat]
    player.zones = PlayerZones[player.color]
    starting_seat = starting_seat

  -- Give player chips and put their bets (if any) forward
    PotManager.call("initializeChipsMapForPlayerId", player.user_id)
    local player_chips = ChipManager.call("initializeChipsForPlayer", player)
    player.stack = player_chips.stack
    player.bet = player_chips.current_bet
  end

  -- Seat present players to their assigned position
  -- This gets players that are present IN the game
  local tts_player_instances = Player.getPlayers() --TTS's PlayerManager instance
  for instance in tts_player_instances do
    local player = getPlayerById(instance.steam_id)
    if player then
      instance.changeColor(player.color)
    end
  end

  return true
end

--[[
  Utility functions
--]]
do

function getPlayers()
  return {table.unpack(PLAYERS)}
end

function getValidPlayers()
  local valid_players = {}
  for i=1, #PLAYERS do
    if PLAYERS[i].state ~= "out" then
      valid_players[#valid_players+1] = PLAYERS[i]
    end
  end
end

-- Get the next player after this one that isn't "out"
-- If there are no valid players after this one, returns nil
function getNextValidPlayer(player)
  -- Add 2 to position. One to normalize to lua indices, 
  -- another to target the next player.
  log("Finding next player from "..player.display_name)
  for i=player.position+2, player.position+#PLAYERS do
    local index = ((i-1) % #PLAYERS) + 1
    local next_player = PLAYERS[index]
    if next_player.state ~= "out" then
      log("Found next player at ["..index.."]")
      return next_player
    else
      log(next_player.display_name.." wasn't valid: "..next_player.state)
    end
  end
  return nil
end

function getPlayerById(id)
  if type(id) == "string" then
    for player in PLAYERS do
      if player.user_id == id then 
        return player
      end
    end
  end
end

function getPlayerByColor(color)
  for player in PLAYERS do
    if player.color == color then
      return player
    end
  end
  return nil
end

function getPlayerByPosition(position)
  for player in PLAYERS do
    if player.position == position then
      return player     
    end
  end
end


--[[
  params = {
    card = <Card ######>,
    position = position of player
  }
--]]
function addCardToPlayerHole(params)
  local player = getPlayerByPosition(params.position)
  player.hole[#player.hole+1] = params.card
end

function removeCardsFromPlayerHoles()
  for player in PLAYERS do
    player.hole = {}
  end
end


function addChipToStack(chip)
  local player = getPlayerById(chip.memo)
  if player == nil then log("Invalid user_id: " .. chip.memo, "PlayerManager.addChipToStack", "[ERROR]", false, true) end
  player.stack[tostring(chip.getValue())][chip] = true
end

function removeChipFromStack(chip)
  local player = getPlayerById(chip.memo)
  if player == nil then log("Invalid user_id: " .. chip.memo, "PlayerManager.removeChipFromStack", "[ERROR]", false, true) end
  player.stack[tostring(chip.getValue())][chip] = nil
end


function updatePlayerStackAndBet(player)
  -- Resetting these fields because some TTS operations can cause the existing references
  -- to be destroyed.
  resetPlayerStack(player)
  resetPlayerBet(player)

  local chips_for_this_player = {}
-- Getting a reference to all chip stacks on the table for this player
  for object in getObjects() do
    if PotManager.call("isChip", object) and string.find(object.memo, player.user_id) then
      table.insert(chips_for_this_player, object)
    end
  end
  -- Chips in the PotZone are part of the player's bet
  -- Chips outside of the PotZone are part of the stack
  for chip in chips_for_this_player do
    -- Had a weird issue with assignment of nil to not removing an association
    local value = chip.getValue() * math.abs(chip.getQuantity())
    if string.find(chip.memo, "(Bet)") then
      table.insert(player.bet[tostring(chip.getValue())], chip)
      player.bet_value = player.bet_value + value
    else
      table.insert(player.stack[tostring(chip.getValue())], chip)
      player.stack_value = player.stack_value + value
    end
  end
end

function resetPlayerStack(player)
  player.stack = _generateDenominationReferenceTable()
  player.stack_value = 0
end
function resetPlayerBet(player)
  player.bet = _generateDenominationReferenceTable()
  player.bet_value = 0
end
function _generateDenominationReferenceTable()
  return {
    ["1000"] = {},
    ["500"]  = {},
    ["100"]  = {},
    ["50"]   = {},
    ["10"]   = {}
  }
end

-- This is called when the Pot collects all bets for the round
function resetAllPlayerBets()
  for player in PLAYERS do
    resetPlayerBet(player)
  end
end

end -- End utility functions

--[[
  Bots (and websocket players) perform their actions directly against the
  server. We only get the report. We can infer "what" a they did based on
  the report that we get for their turn.
]]
do

--[[
  Handles exchanging chips between denominations for bots.
  The server validates the exchange rates for us. All that is needed
  here is animating the exchange of chips that took place.

  Note: I'm not sure "how" I want this animated. I was told to keep the dedicated
  chip-exchange area clear of bots to avoid confusing players who may engage exchanges
  outside of their turn. For now, I'm just going to raise the "give" chips above the
  bot's stack and then "poof" them into the "receive" chips.

  params = {
    data = { // <ChipExchangeDTO>
      user_id = string,
      give    = [string]int,
      receive = [string]int,
    },

    onFinish_params = {
      service   = <Scripting Zone>,
      callback  = string (function name in service's script),
      args      = any (arguments to pass to callback)
    }
  }
]]
function animateExchangeChips(params)
  local player = getPlayerById(params.data.user_id)
  if not player then
    log("Player "..params.data.user_id.." not found.", "PlayerManager.animateExchangeChips", "[ERROR]", false, true)
    return
  end

  broadcastToAll(player.display_name.." is exchanging chips", player.color)

  local onFinish_params = params.onFinish_params
  lockExternalScriptMutex()
  local exchangeChips_params = {
    owner             = player,
    chips_to_exchange = {
      give    = params.data.give,
      receive = params.data.receive,
    },
    onFinish_params   = {
      service  = self,
      callback = "unlockExternalScriptMutex",
      args     = nil
    }
  }
  ChipManager.call("exchangeChips", exchangeChips_params)

  Wait.condition(
    function() onFinish_params.service.call(onFinish_params.callback, onFinish_params.args) end,
    isExternalScriptMutexUnlocked
  )
end

--[[
  This function animates player actions that are provided by the server.
  I.e. this is for actions that are NOT done by players in Tabletop Simulator.

  params = {
    data = <PlayerAction>,

    onFinish_params = {
      service   = <Scripting Zone>,
      callback  = string (function name in service's script),
      args      = table (arguments to pass to callback)
    }
  }
--]]
function animatePlayerAction(params)
  local data = params.data

  local player = getPlayerById(data.player_id)
  if not player then
    log("Player " .. data.player_id .. " not found.", "PlayerManager.animatePlayerAction", "[ERROR]", false, true)
    return
  end

  if params.data.intent == "all_in" then
    -- going all in provides us an empty chips field.
    -- need to patch the data in order to move the actual chips
    local chips = {}
    for denomination, chip_references in pairs(player.stack) do
      chips[denomination] = 0
      for chip_reference in chip_references do
        chips[denomination] = chips[denomination] + math.abs(chip_reference.getQuantity())
      end
    end
    params.data.chips = chips
  end

  -- I'm sure I'll end up revisiting this again :^)
  Wait.time(
    function()
      Wait.condition(
        function()
          -- Move chips first
          animateBet(player, data.chips)
    
          Wait.condition(
            function()
              -- Move cards second (honestly, only one should happen in a turn)
              player.state = params.data.intent
              animateIntent(player)
    
              Wait.condition(
                -- Once actions are taken, wait a short bit before releasing
                function() 
                  unlockPlayerTurnMutex()
                end,
                isExternalScriptMutexUnlocked
              )
    
            end,
            isExternalScriptMutexUnlocked
          )
    
        end,
        isExternalScriptMutexUnlocked
      )
    end,
    PLAYER_START_TURN_DELAY
  )

end

--[[
  Moves the player's cards out of their hand if they have folded/are showing
  their cards.
]]
function animateIntent(player)
  lockExternalScriptMutex()

  -- Set the player's state to their intent in this action.
  local params = {
    player = player,
    onFinish_params = Animation_onFinish_params
  }
  DeckManager.call("movePlayerCardsToReflectIntent", params)
end

--[[
  Moves the chips that the player bet into the betting zone.
]]
function animateBet(player, chips)
  lockExternalScriptMutex()
  local moveChipsBetweenStacks_params = {
    owner = player,
    giving_stack_type    = "stack",
    receiving_stack_type = "bet",
    chips_to_move        = chips,

    onFinish_params = {
      service = self,
      callback = "unlockExternalScriptMutex"
    }
  }
  ChipManager.call("moveChipsBetweenStacks", moveChipsBetweenStacks_params)
end

end -- Bot animations

--[[
  Chips are "spawned" when taken out of a stack. 2 chips are spawned when a stack
  of 2 is split, with GUID's unique from the original stack.
]]
function onObjectSpawn(object)
  if string.find(object.type, "Chip") then
    -- Figure out who the chip belongs to
    -- If its the pot, do nothing
    if object.memo == "Pot" then return end

    local player_id_start, player_id_end = string.find(object.memo, "^[a-zA-Z0-9]+")
    local player_id = string.sub(object.memo, player_id_start, player_id_end)
    local player = getPlayerById(player_id)
    if player then
      updatePlayerStackAndBet(player)
    end
  end
end

function onObjectDestroy(object)
  if string.find(object.type, "Chip") then
    -- Figure out who the chip belongs to
    -- If its the pot, do nothing
    if object.memo == "Pot" then return end

    local player_id_start, player_id_end = string.find(object.memo, "^[a-zA-Z0-9]+")
    local player_id = string.sub(object.memo, player_id_start, player_id_end)
    local player = getPlayerById(player_id)
    if player then 
      updatePlayerStackAndBet(player)
    end
  end
end