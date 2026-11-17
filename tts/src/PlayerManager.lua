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
local ServerClientConnection
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
  ChipManager            = params.Services.ChipManager
  DeckManager            = params.Services.DeckManager
  PotManager             = params.Services.PotManager
  ServerClientConnection = params.Services.ServerClientConnection

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

      -- If human player_id
      current_round = string,
      minimum_chip_in = number
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
  else
    _trackPlayerTurn(
      player,
      params.data.current_round,
      params.data.current_player_stack_amount,
      params.data.minimum_chip_in
    )
    
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
    
    -- NOTE: Disabled until i add a way to track when a player has shown their hand
    -- if player.user_type == "bot" then
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
    -- end
    
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

function getSeats()
  return {table.unpack(SEATS)}
end

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
    local player_stack = ChipManager.call("getChipsForPlayerById", player.user_id).stack
    local chips = {}
    log(player_stack)
    for denomination, chip_stacks in pairs(player_stack) do
      -- Populate field if not set
      if not chips[denomination] then chips[denomination] = 0 end
      for chip_stack in chip_stacks do
        chips[denomination] = chips[denomination] + math.abs(chip_stack.getQuantity())
      end
    end
    data.chips = chips
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
  START TRACKING PLAYER TURN
  Conjuring a PlayerActionDTO from the board state is a different set of complicated
  than animating one.
]]

-- UI IDs
local playerAction_window_id              = "panel_player-action-menu"
local playerAction_minimumToStayIn_id     = "label_minimum-to-stay-in"
local playerAction_currentBetAmount_id    = "label_current-bet-amount"
local playerAction_confirmPlayerAction_id = "button_confirm-player-action"

CARD_POSITION = {
  no_cards = "no_cards",
  in_hand  = "in_hand",
  folded   = "folded",
  showing  = "showing",
  unknown  = "unknown" -- If both cards aren't in the same position
}

--[[
  Creates a persistent observer that invokes a callback whenever the 
  observed field changes.

  The observer self-terminates and disposes once the `continue_observing`
  field is set to false.

  params = {
    getValue     = func <any>,
    onChange     = func <void>,
    continue_observing = boolean
  }
]]
function _startMutationObserver(params)
  local getValue           = params.getValue
  local onChange           = params.onChange
  local old_value          = getValue()

  Wait.condition(
    function()
      if params.continue_observing then
        onChange()
        _startMutationObserver(params)
      end
    end,
    function() return old_value ~= getValue() or not params.continue_observing end
  )
end

-- This field specifically refers to the human player whose turn it is.
-- nil if it is not a human's turn.
local CURRENT_PLAYER               = nil
-- Intents are limited based on the round.
local CURRENT_ROUND                = nil
-- Intents vary based on how many chips are put forward relative to the player's stack and the current bet
local CURRENT_MINIMUM_CHIP_IN      = nil
local CURRENT_PLAYER_STACK_AMOUNT  = nil

-- Intent is derived from the location and orientation of the player's cards
local CURRENT_PLAYER_CARD_POSITION = nil
-- Need a reference to the player's chips to mark them while the request is sent
local CURRENT_CHIPS_BEING_BET      = nil
-- This field is just a courtesy to numerize the inferred bet
local CURRENT_BET_VALUE            = nil

-- The DTO is constantly rebuilt until it is sent so I can track if the player is
-- in a valid state and relay what state is being submitted to them.
local PLAYER_ACTION_DTO            = nil
-- The result is set via a callback. A successful result means the player's turn has ended.
local PLAYER_ACTION_RESULT         = nil

function _resetTrackedFields()
  CURRENT_PLAYER               = nil
  CURRENT_ROUND                = nil
  CURRENT_MINIMUM_CHIP_IN      = nil
  CURRENT_PLAYER_STACK_AMOUNT  = nil
  CURRENT_PLAYER_CARD_POSITION = nil
  CURRENT_CHIPS_BEING_BET      = nil
  CURRENT_BET_VALUE            = nil
  PLAYER_ACTION_DTO            = nil
  PLAYER_ACTION_RESULT         = nil
end

-- When the player clicks the button to submit their turn.
function _onPlayerActionButtonClicked(player, value, id)
  if CURRENT_PLAYER == nil then return end
  if PLAYER_ACTION_DTO == nil then return end

  -- While the request is processing, prevent the value of the chips being
  -- bet from being modified.
  local markChipsAsPending_params = {
    user_id = CURRENT_PLAYER.user_id,
    chips   = CURRENT_CHIPS_BEING_BET
  }
  ChipManager.call("markChipsAsPending", markChipsAsPending_params)
  
  Global.UI.setAttribute(playerAction_confirmPlayerAction_id, "interactable", "False")

  local postPlayerAction_params = {
    player_action_dto = PLAYER_ACTION_DTO,

    onFinish_params = {
      service  = self,
      callback = "_onPostPlayerActionResponseReceived"
    }
  }
  ServerClientConnection.call("postPlayerAction", postPlayerAction_params)
end

-- Have to use a callback to capture the result from posting the player action via ServerClientConnection.
function _onPostPlayerActionResponseReceived(result)
  local player_action_result = {
    player_action_dto = result.copy_of_args.player_action_dto
  }
  if result.error then
    player_action_result.error = {
      response_code = result.error.response_code,
      text          = result.error.text
    }
  end
  PLAYER_ACTION_RESULT = player_action_result
end

function updateCurrentChipsBeingBet()
  if CURRENT_PLAYER == nil then return end
  CURRENT_CHIPS_BEING_BET = {table.unpack(ChipManager.call("getStackChipsInBettingZoneForPlayer", CURRENT_PLAYER.user_id))}
  CURRENT_BET_VALUE = 0
  for chip in CURRENT_CHIPS_BEING_BET do
    CURRENT_BET_VALUE = CURRENT_BET_VALUE + chip.getValue() * math.abs(chip.getQuantity())
  end
end

--[[
  We can determine what the player is doing with their cards
  by their location and rotation.
]]
function updateCurrentPlayerCardPosition()
  if CURRENT_PLAYER == nil then return end

  if #CURRENT_PLAYER.hole ~= 2 then
    CURRENT_PLAYER_CARD_POSITION = CARD_POSITION.no_cards
    log("No cards")
    return
  end

  local number_of_cards_in_hand = 0
  -- Check if cards are in the player's hand
  for object in CURRENT_PLAYER.zones.hand_zone.getObjects() do
    if object.type == "Card" then
      for card in CURRENT_PLAYER.hole do
        if card == object then
          number_of_cards_in_hand = number_of_cards_in_hand + 1
          break
        end
      end
    end
  end

  if number_of_cards_in_hand == 2 then 
    CURRENT_PLAYER_CARD_POSITION = CARD_POSITION.in_hand
    log("In hand")
    return
  end

  local number_of_cards_face_down = 0
  local number_of_cards_face_up   = 0
  for card in CURRENT_PLAYER.hole do
    if card.is_face_down then number_of_cards_face_down = number_of_cards_face_down + 1
    else number_of_cards_face_up = number_of_cards_face_up + 1
    end
  end

  if number_of_cards_face_down == 2 then
    CURRENT_PLAYER_CARD_POSITION = CARD_POSITION.folded
    log("folded")
    return
  end
  if number_of_cards_face_up == 2 then
    CURRENT_PLAYER_CARD_POSITION = CARD_POSITION.showing
    log("showing")
    return
  end

  log("unknown")
  CURRENT_PLAYER_CARD_POSITION = CARD_POSITION.unknown
end

function updatePlayerActionDto()
  if CURRENT_PLAYER == nil then return end
  local player_action_dto = { player_id = CURRENT_PLAYER.user_id }

  player_action_dto.chips = {}
  for chip in CURRENT_CHIPS_BEING_BET do
    local denomination = tostring(chip.getValue())
    local count        = math.abs(chip.getQuantity())
    if not player_action_dto.chips[denomination] then
      player_action_dto.chips[denomination] = 0
    end
    player_action_dto.chips[denomination] = player_action_dto.chips[denomination] + count
  end

  if CURRENT_BET_VALUE == CURRENT_PLAYER_STACK_AMOUNT then
    player_action_dto.intent = "all_in"
  elseif CURRENT_ROUND == "setup" then
    -- `all_in` is transformed to `ante` by the server if necessary
    if CURRENT_BET_VALUE == CURRENT_MINIMUM_CHIP_IN then
      -- Can only put forward up to the blind cost for the ante
      player_action_dto.intent = "ante"
    end
  elseif CURRENT_PLAYER_CARD_POSITION == CARD_POSITION.folded then
    player_action_dto.intent = "fold"
    player_action_dto.chips = nil -- Don't bet chips if the player is folding.
  elseif CURRENT_BET_VALUE == 0 and CURRENT_MINIMUM_CHIP_IN == 0 then
    player_action_dto.intent = "check"
    player_action_dto.chips = nil
  elseif CURRENT_BET_VALUE == CURRENT_MINIMUM_CHIP_IN then
    player_action_dto.intent = "call"
  elseif CURRENT_BET_VALUE > CURRENT_MINIMUM_CHIP_IN then
    player_action_dto.intent = "raise"
  end

  PLAYER_ACTION_DTO = player_action_dto
end

function updatePlayerActionMenu()
  Global.UI.setAttribute(playerAction_currentBetAmount_id, "text", tostring(CURRENT_BET_VALUE or 0))
  local intent = PLAYER_ACTION_DTO and PLAYER_ACTION_DTO.intent
  Global.UI.setAttribute(playerAction_confirmPlayerAction_id, "text", intent or "Waiting for player...")
  if intent ~= nil then
    Global.UI.setAttribute(playerAction_confirmPlayerAction_id, "interactable", true)
  else
    Global.UI.setAttribute(playerAction_confirmPlayerAction_id, "interactable", false)
  end
end

function _trackPlayerTurn(player, current_round, current_player_stack_amount, minimum_chip_in)
  CURRENT_PLAYER = player
  CURRENT_ROUND = current_round
  CURRENT_PLAYER_STACK_AMOUNT = current_player_stack_amount
  CURRENT_MINIMUM_CHIP_IN = minimum_chip_in

  -- Initial check for what chips are in the betting zone
  updateCurrentChipsBeingBet()
  -- Initial check for where cards are.
  updateCurrentPlayerCardPosition()
  -- See if we can generate a valid dto from the current state
  updatePlayerActionDto()

  -- Event handlers cover chips entering/leaving the betting zone, as well
  -- as being picked up/dropped by the player.
  local observeBet_params = {
    getValue = function() return CURRENT_CHIPS_BEING_BET end,
    onChange = updatePlayerActionDto,
    continue_observing = true
  }
  -- Event handlers cover cards entering/leaving the player's hand zone, as well
  -- as being rotated by the player.
  local observeCards_params = {
    getValue = function() return CURRENT_PLAYER_CARD_POSITION end,
    onChange = updatePlayerActionDto,
    continue_observing = true
  }
  -- These two update the UI to relay the current inference to the player.
  local observeBetValue_params = {
    getValue = function() return CURRENT_BET_VALUE end,
    onChange = updatePlayerActionMenu,
    continue_observing = true
  }
  local observePlayerActionDto_params = {
    getValue = function() return PLAYER_ACTION_DTO end,
    onChange = updatePlayerActionMenu,
    continue_observing = true
  }
  -- Contexts are stored in a collection. I either need all the observers or none of them,
  -- so shutdown is simple.
  local observer_contexts = { observeBet_params, observeCards_params, observeBetValue_params, observePlayerActionDto_params }
  for context in observer_contexts do
    _startMutationObserver(context)
  end

  -- Setting up the UI
  local visible_to = "Black" --Debug. Menu should only be visible to the player making a decision.
  visible_to = visible_to.."|"..CURRENT_PLAYER.color
  Global.UI.setAttribute(playerAction_window_id, "visibility", visible_to)
  Global.UI.setAttribute(playerAction_minimumToStayIn_id, "text", CURRENT_MINIMUM_CHIP_IN)
  updatePlayerActionMenu()

  _awaitValidActionPosted(observer_contexts)
end

function _awaitValidActionPosted(observer_contexts)
  Wait.condition(
    function()
      -- We know that PLAYER_ACTION_RESULT is not nil if we're running this function.
      -- My linter is stupid, this just makes some squigglies go away.
      if PLAYER_ACTION_RESULT and PLAYER_ACTION_RESULT.error then
        local log_message = logString(PLAYER_ACTION_RESULT.error, "PlayerManager._awaitValidActionPosted", "[ERROR]", false, true)
        log(log_message)

        local error = PLAYER_ACTION_RESULT.error

        PLAYER_ACTION_RESULT = nil
        local markPendingChips_params = { user_id = CURRENT_PLAYER.user_id }
        ChipManager.call("markPendingChipsAsStack", markPendingChips_params)
        broadcastToColor(error.text, "Black", "Red")

        _awaitValidActionPosted(observer_contexts)
        return
      end

      -- If PLAYER_ACTION_RESULT is not an error response, then great.
      -- The turn was successfully posted.
      -- We can reset the fields, set the metdata for the player's chips,
      -- and release the mutex for the player turn.
      local log_message = logString(PLAYER_ACTION_RESULT, "PlayerManager._awaitValidActionPosted", "[INFO]", false, true)
      log(log_message)

      local player_action_dto = PLAYER_ACTION_RESULT.player_action_dto
      local intent = player_action_dto.intent
      local markPendingChips_params = { user_id = player_action_dto.player_id }
      if intent == "fold" or intent == "check" then
        -- If the player folded, their chips are not betted.
        ChipManager.call("markPendingChipsAsStack", markPendingChips_params)
      else
        ChipManager.call("markPendingChipsAsBet", markPendingChips_params)
      end

      CURRENT_PLAYER.state = intent

      _resetTrackedFields()
      unlockPlayerTurnMutex()
    end,
    function() return PLAYER_ACTION_RESULT ~= nil end
  )
end

do -- TTS Event listeners

  -- Track if cards enter hand or chips enter betting zone
  function onObjectEnterZone(zone, object)
    if CURRENT_PLAYER == nil then return end
    if zone == PotZone then
      if object.type == "Chip" then updateCurrentChipsBeingBet() end
      return
    end
    if zone == CURRENT_PLAYER.zones.hand_zone then
      if object.type == "Card" then updateCurrentPlayerCardPosition() end
      return
    end
  end

  -- Track if cards leave hand or chips leave betting zone
  function onObjectLeaveZone(zone, object)
    if CURRENT_PLAYER == nil then return end
    if zone == PotZone then
      if object.type == "Chip" then
        log("Card entered "..CURRENT_PLAYER.color.." hand zone")
        updateCurrentChipsBeingBet()
      end
      return
    end
    if zone == CURRENT_PLAYER.zones.hand_zone then
      if object.type == "Card" then
        log("Card left "..CURRENT_PLAYER.color.." hand zone")
        updateCurrentPlayerCardPosition()
      end
      return
    end
  end

  -- Track if the player drops a card or chip(s)
  function onObjectDrop(_, object)
    if CURRENT_PLAYER == nil then return end
    if object.type == "Chip" then updateCurrentChipsBeingBet() end
    if object.type == "Card" then updateCurrentPlayerCardPosition() end
  end

  -- Track if the player flips a card
  function onObjectRotate(object, spin, flip, player_color, old_spin, old_flip)
    if CURRENT_PLAYER == nil then return end
    if object.type == "Card" then
      updateCurrentPlayerCardPosition()
    end
  end

end -- TTS Event listeners
--[[
  END   TRACKING PLAYER TURN
]]

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