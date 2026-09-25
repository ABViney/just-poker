--[[
  Various things happen at the start and end of each round.
  The server defines 6 round types:
    1. setup
    2. pre_flop
    3. flop
    4. turn
    5. river
    6. completed
  
  Actions taken upon the start and end of a round depend on the round type:
    1. setup - nothing
    2. pre_flop:
        start: deal cards to players
        end: collect any bets into the pot
    3. flop:
        start: reveal the first 3 cards of the street
        end: collect any bets into the pot
    4. turn:
        start: reveal the 4th card of the street
        end: collect any bets into the pot
    3. river:
        start: reveal the 5th card of the street
        end: collect any bets into the pot and reveal cards in player's hands
    3. completed:
        start: gather cards on the table back into the deck
]]
local DeckManager
local EventBus
local PlayerManager
local PotManager

--[[
  There's no discrete event for ending a round. When a round ends must be
  inferred via the start of a new round.
]]
local CURRENT_ROUND_TYPE

local ROUND_START_FUNC_MAP
local ROUND_END_FUNC_MAP

function init(params)
  DeckManager   = params.Services.DeckManager
  EventBus      = params.Services.EventBus
  PlayerManager = params.Services.PlayerManager
  PotManager    = params.Services.PotManager

  do -- Routing for logic based on round type received
  ROUND_START_FUNC_MAP = {
    ["setup"]     = nil,
    ["pre_flop"]  = startPreFlop,
    ["flop"]      = startFlop,
    ["turn"]      = startTurn,
    ["river"]     = startRiver,
    ["completed"] = startCompleted
  }

  ROUND_END_FUNC_MAP = {
    ["setup"]     = nil,
    ["pre_flop"]  = endPreFlop,
    ["flop"]      = endFlop,
    ["turn"]      = endTurn,
    ["river"]     = endRiver,
    ["completed"] = nil
  }
  end

  EventBus.call("subscribe", {
    event_type = "round_started",
    callback_params = {
      service  = self,
      callback = "onRoundStart"
    }
  })

  EventBus.call("subscribe", {
    event_type = "hand_payouts",
    callback_params = {
      service  = self,
      callback = "onPayout"
    }
})

  log("RoundHandler initialized")
end


do -- Config
  ROUND_START_DELAY = 2
  ROUND_END_DELAY   = 2
end


do -- Mutexes

--[[
  This mutex is for blocking while waiting for external scripts like
  DeckManager and PotManager to finish doing stuff that requires moving
  objects.
]]
local awaiting_external_script = false
function lockExternalScriptMutex() awaiting_external_script = true end
function unlockExternalScriptMutex() awaiting_external_script = false end
function isExternalScriptMutexUnlocked() return not awaiting_external_script end

ExternalScript_onFinish_params = {
  service = self,
  callback = "unlockExternalScriptMutex"
}

--[[
  This mutex is for blocking the onFinish_params callback for the EventBus
  until all external script calls are finished.

  Todo: Might be more semantically clear if I define mutexes for "start round"
  and "end round"
]]
local running_routines = false
function lockRoundHandlerMutex() running_routines = true end
function unlockRoundHandlerMutex() running_routines = false end
function isRoundHandlerMutexUnlocked() return not running_routines end

end


function onRoundStart(params)
  local data = params.data
  local onFinish_params = params.onFinish_params

  -- If there was a preceeding round, then we need to 
  if CURRENT_ROUND_TYPE and ROUND_END_FUNC_MAP[CURRENT_ROUND_TYPE] then
    ROUND_END_FUNC_MAP[CURRENT_ROUND_TYPE]()
  end

  CURRENT_ROUND_TYPE = data.round_type
  Wait.condition(
    function()
      if ROUND_START_FUNC_MAP[data.round_type] ~= nil then
        ROUND_START_FUNC_MAP[data.round_type]()
      end

      -- If asynchronous work is taking place we have to wait until that's finished
      Wait.condition(
        function() onFinish_params.service.call(onFinish_params.callback, onFinish_params.args) end,
        isRoundHandlerMutexUnlocked
      )
    end,
    isRoundHandlerMutexUnlocked
  )
end

--[[
  The payout can show up whenever a round would normally end.
  We need to be able to accumulate the bets to this point and pay it out
  from the pot.
]]
function onPayout(params)
  local data = params.data
  local onFinish_params = params.onFinish_params

  CURRENT_ROUND_TYPE = "payout"
  
  -- The payout can show up as early as at the end of the pre_flop so the
  -- function map is irrelevant here. Instead we'll gather chips manually,
  -- figure out if players should show their cards, and then divvy out the
  -- pot as described in the payload.
  log("Payout occuring. Gathering remaining bets")
  gatherBets()
  
  Wait.condition(
    function()
      log("Showing cards")
      showCardsIfShowdown()

      Wait.condition(
        function()
          log("Paying out pot")
          payoutPot(data)
          
          Wait.condition(
            function() onFinish_params.service.call(onFinish_params.callback, onFinish_params) end,
            isRoundHandlerMutexUnlocked
          )
        end,  
        isRoundHandlerMutexUnlocked
      )
    end,
    isRoundHandlerMutexUnlocked
  )
end

--[[
      THE PRE_FLOP
]]
function startPreFlop()
  lockRoundHandlerMutex()
  lockExternalScriptMutex()
  
  -- Todo: if the dealer is a human, we should block until they have
  -- hit the "Deal cards" button in the deck's context menu
  DeckManager.call("dealHand", ExternalScript_onFinish_params)

  Wait.condition(
    unlockRoundHandlerMutex,
    isExternalScriptMutexUnlocked
  )
end
function endPreFlop()
  gatherBets()
end

--[[
      THE FLOP
]]
function startFlop()
  lockRoundHandlerMutex()
  lockExternalScriptMutex()

  DeckManager.call("dealFlop", ExternalScript_onFinish_params)
  
  Wait.condition(
    unlockRoundHandlerMutex,
    isExternalScriptMutexUnlocked
  )
end
function endFlop()
  gatherBets()
end

--[[
      THE TURN
]]
function startTurn()
  lockRoundHandlerMutex()
  lockExternalScriptMutex()

  DeckManager.call("dealTurn", ExternalScript_onFinish_params)
  
  Wait.condition(
    unlockRoundHandlerMutex,
    isExternalScriptMutexUnlocked
  )
end
function endTurn()
  gatherBets()
end

--[[
      THE RIVER
]]
function startRiver()
  lockRoundHandlerMutex()
  lockExternalScriptMutex()

  DeckManager.call("dealRiver", ExternalScript_onFinish_params)
  
  Wait.condition(
    unlockRoundHandlerMutex,
    isExternalScriptMutexUnlocked
  )
end
function endRiver()
  gatherBets()
end

--[[
      THE COMPLETED
]]
function startCompleted()
  lockRoundHandlerMutex()
  lockExternalScriptMutex()

  DeckManager.call("gatherCards", ExternalScript_onFinish_params)

  Wait.condition(
    unlockRoundHandlerMutex,
    isExternalScriptMutexUnlocked
  )
end


-- Common routine.
function gatherBets()
  lockRoundHandlerMutex()
  lockExternalScriptMutex()

  
  PotManager.call("gatherBets", ExternalScript_onFinish_params)

  Wait.condition(
    unlockRoundHandlerMutex,
    isExternalScriptMutexUnlocked
  )
end

function showCardsIfShowdown()
  lockRoundHandlerMutex()
  lockExternalScriptMutex()

  PlayerManager.call("revealActiveHands", ExternalScript_onFinish_params)

  Wait.condition(
    unlockRoundHandlerMutex,
    isExternalScriptMutexUnlocked
  )
end

--[[
  The payload for payout looks like:
  [
    {
      "player_id": string,
      "chips" {
        "1000": int,
        ...
      }
    },
    ...
  ]
]]
function payoutPot(data)
  lockRoundHandlerMutex()
  -- Right now we don't have an event specific to when players 

  if #data == 0 then
    -- Just some stupid edge case i thought of
    unlockRoundHandlerMutex()
    return
  end

  local index = 1
  for i, payout_data in ipairs(data) do
    local id = i
    local payoutChips_params = {
      player_id       = payout_data.player_id,
      chips           = payout_data.chips,
      onFinish_params = ExternalScript_onFinish_params
    }

    Wait.condition(
      function()
        lockExternalScriptMutex()
        PotManager.call("animatePayout", payoutChips_params)
        index = index + 1
      end,
      function() return isExternalScriptMutexUnlocked() and index == id end
    )
  end

  Wait.condition(
    unlockRoundHandlerMutex,
    function() return isExternalScriptMutexUnlocked() and index == #data + 1 end
  )
end