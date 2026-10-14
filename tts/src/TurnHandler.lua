--[[
  Players and bots require oversight to complete their turns.
  For bots, all the information is already provided, so all that is needed is to
  animate their decision.

  (To Be Implemented) For players, actions taken by them must be inferred and described
  in a stateful format:
  - How many chips they have in their stack, their bet, whether they have enough to check,
    if they have added enough to call/raise, or if they are all-in. 
  - The state of their cards--are they in their hand, folded on the table, or showing for
    the showdown
  - Exchanges of chips--if the player has exchanged chips for a different denomination,
    this must be reported to the server.
]]

local ChipManager
local EventBus
local PlayerManager
local PotManager
local TurnManager

local PotZone

function init(params)
  ChipManager   = params.Services.ChipManager
  EventBus      = params.Services.EventBus
  PlayerManager = params.Services.PlayerManager
  PotManager    = params.Services.PotManager
  TurnManager   = params.Services.TurnManager

  PotZone = params.Zones.pot_zone

  -- When a player_action is received or requested
  EventBus.call("subscribe", {
    event_type = "player_action",
    callback_params = {
      service  = self,
      callback = "onTurnStart"
    }
  })

  EventBus.call("subscribe", {
    event_type = "chip_exchange",
    callback_params = {
      service = self,
      callback = "onChipExchange"
    }
  })
end

do -- Config
  TURN_START_DELAY  = 2
  TURN_END_DELAY    = 2
end

local awaiting_external_script = false
function lockExternalScriptMutex() awaiting_external_script = true end
function unlockExternalScriptMutex() awaiting_external_script = false end
function isExternalScriptMutexUnlocked() return not awaiting_external_script end

ExternalScript_onFinish_params = {
  service = self,
  callback = "unlockExternalScriptMutex"
}

--[[
  Subscribed callback given to EventBus for "player_action" events.

  params = {
    data = {
      player_id   = string
      intent      = string
      chips       = [string]int
      accepted_at = datetime
    },

    onFinish_params = {
      service  = <Scripting Zone>,
      callback = string,
      args     = any
    }
  }
]]
function onTurnStart(params)
  local player_id = params.data.player_id
  local onFinish_params = params.onFinish_params

  local player = PlayerManager.call("getPlayerById", player_id)
  if not player then -- DEBUG
    log("Player with ID ["..player_id.."] not found.", "PlayerManager.onPlayerTurn", "[ERROR]", false, true)
    return
  end
  log(player.display_name.."'s ["..player.user_type.."] turn is starting")

  local params = {
    data = params.data,
    onFinish_params = ExternalScript_onFinish_params
  }

  lockExternalScriptMutex()
  PlayerManager.call("startPlayerTurn", params)

  Wait.condition(
    function() onFinish_params.service.call(onFinish_params.callback, onFinish_params.args) end,
    isExternalScriptMutexUnlocked
  )
end

--[[
  Subscribed callback given to EventBus for "chip_exchange" events.
  
  params = {
    data = {
      user_id = string,
      give    = [string]int,
      receive = [string]int
    },

    onFinish_params = {
      service  = <Scripting Zone>,
      callback = string,
      args     = any
    }
  }
]]
function onChipExchange(params)
  local data = params.data
  local onFinish_params = params.onFinish_params

  local params = {
    data            = data,
    onFinish_params = ExternalScript_onFinish_params
  }
  lockExternalScriptMutex()
  PlayerManager.call("animateExchangeChips", params)

  Wait.condition(
    function() onFinish_params.service.call(onFinish_params.callback, onFinish_params.args) end,
    isExternalScriptMutexUnlocked
  )
end