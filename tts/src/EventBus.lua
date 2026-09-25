--[[
  Various services in this mod rely on events to get the information needed
  to perform actions on the table. We need to be able to guarantee that 
  services dependent on events receive them, and that their actions are 
  completed before processing the next event.

  This service operates entirely independent of any other service. It is a 
  model of events that the poker server transmits to inform us of the state 
  of the game. External services that act on that information can subscribe
  to those events via the methods provided here.
]]

HAND_IN_PROGRESS         = false
ROUND_IN_PROGRESS        = false

HAND_DATA_TYPE = "hand_data"

ROUND_DATA_TYPE = "round_data"
ROUND_TYPES = {
  setup     = true,
  pre_flop  = true,
  flop      = true,
  turn      = true,
  river     = true,
  completed = true
}

PLAYER_ACTION_DATA_TYPE = "player_action_data"
PLAYER_INTENTS = {
  ante   = true,
  check  = true,
  call   = true,
  raise  = true,
  all_in = true,
  fold   = true
}
PLAYER_CHIP_DENOMINATIONS = {
  ["1000"] = true,
  ["500"]  = true,
  ["100"]  = true,
  ["50"]   = true,
  ["10"]   = true
}

function init(params)
  log("EventBus initialized")
end

--[[
  External scripts can set callbacks to be invoked when a specific event happens.

  Callbacks are invoked in order of when they were added. A callback must finished before
  the next one is invoked.

  Callbacks receive a table with relevant information to the event, and parameters for 
  notifying this script that they are finished.
]]
do

-- This mutex is for this script to know if it is currently invoking external scripts.
local is_currently_iterating_callbacks = false
function isNotCurrentlyIteratingCallbacks() return not is_currently_iterating_callbacks end

-- The flow for external callbacks is dictated by this mutex.
local awaiting_external_script_action = false
function lockExternalScriptMutex() log("EventBus mutex locked") awaiting_external_script_action = true end
function unlockExternalScriptMutex()  log("EventBus mutex unlocked") awaiting_external_script_action = false end
function isExternalScriptMutexUnlocked() return not awaiting_external_script_action end

--[[
  Explicit coordination between scripts regarding actions that may take an indeterminate amount
  of time require blocking of the flow of execution to avoid race conditions.
  This paradigm is present in most other scripts in this mod, first defined in GameManager and
  replicated in other scripts as the need arose.

  There are two components to this:
  1. onFinish_params for the encapsulating script:
      {
        service  = self,
        callback = "unlockExternalScriptMutex"
      }
  2. The ability to process others' onFinish_params that follow the same paradigm.
]]
local onFinishExternalScript_params = {
  service  = self,
  callback = "unlockExternalScriptMutex",
  args     = nil
}

--[[
  External callers provide onFinish_params that describe what to do when
  finished.
  This is unreadable. Putting it in a function to hide away.
]]
function processOnFinishParams(onFinish_params)
  onFinish_params.service.call(onFinish_params.callback, onFinish_params.args)
end

-- -- hand_id, big/small_blind_cost, big/small_blind_position, button_position
-- local ON_HAND_START_CALLBACKS        = {}
-- -- hand_id
-- local ON_HAND_END_CALLBACKS          = {}
-- -- round_type
-- local ON_ROUND_START_CALLBACKS       = {}
-- -- round_type
-- local ON_ROUND_END_CALLBACKS         = {}
-- -- player_id, intent, chips
-- local ON_PLAYER_TURN_START_CALLBACKS = {}
-- -- player_id
-- local ON_PLAYER_TURN_END_CALLBACKS   = {}

--[[
  Went ahead and defined all expected event types that the server sends.

  The data field for these events is defined in relevant sections,
  but for more information you can review the Swagger:
  - See https://api.bahms.org/swagger/poker
]]
local EVENT_SUBSCRIPTIONS = {
  ["listener_created"]    = {},
  ["welcome"]             = {},
  ["starting_game"]       = {},
  ["game_status_changed"] = {},
  ["hand_started"]        = {},
  ["round_started"]       = {},
  ["chip_exchange"]       = {},
  ["player_action"]       = {},
  ["hand_payouts"]        = {},
  ["game_ending"]         = {}
}

--[[
  Subscribes a callback to an event defined in EventBus.EVENT_SUBSCRIPTIONS.
  
  Subscribers are called in the order they subscribed. The callback they 
  register receives the data from the payload carrying the event.

  params = {
    event_type = string,

    callback_params = {
      service = <Scripting Zone>,
      callback = string
    }
  }
]]
function subscribe(params)
  local event_type = params.event_type
  local callback_params = params.callback_params

  if not event_type then
    log({"No event_type provided", "EventBus.createSubscription"}, "[ERROR]", false, true)
    return
  end
  if not EVENT_SUBSCRIPTIONS[event_type] then
    log({"No publisher of " .. event_type .. " found"}, "EventBus.createSubscription", "[WARNING]", false, true)
  end
  if not callback_params then
    log({"Cannot subscribe to "..event_type.." without providing a callback"}, "EventBus.createSubscription", "[ERROR]", false, true)
    return
  end

  if not EVENT_SUBSCRIPTIONS[event_type] then
    EVENT_SUBSCRIPTIONS[event_type] = {}
  end

  table.insert(EVENT_SUBSCRIPTIONS[event_type], callback_params)
  log(callback_params.service, "Subscription to "..event_type.." created", "[INFO]", false, true)
end

--[[
  Publishes an event to all current subscribers.

  params = {
    event_type = string,
    data       = any,

    -- Optional - Only necessary for asynchronous operations.
    onFinish_params = {
      service  = <Scripting Zone>,
      callback = string,
      args     = any
    }
  }
]]
function publish(params)
  if not params.event_type then
    log("Missing params.event_type", "EventBus.publish", "[WARNING]", false, true)
  end
  if not EVENT_SUBSCRIPTIONS[params.event_type] then
    log("Event ["..params.event_type.."] has no subscribers", "EventBus.publish", "[WARNING]", false, true)
  end
  log("[EventBus.publish]: Publishing " .. params.event_type)
  publishToSubscribers(EVENT_SUBSCRIPTIONS[params.event_type], params.data)

  --[[
    If the caller provided a callback it will be invoked once all subscribers
    have been informed and processed the event.
  ]]
  if params.onFinish_params then
    local onFinish_params = params.onFinish_params
    Wait.condition(
      function() onFinish_params.service.call(onFinish_params.callback, onFinish_params.args) end,
      isNotCurrentlyIteratingCallbacks
    )
  end
end

--[[
  

  callback_params_array = [
    {
      service  = <Scripting Zone>,
      callback = string
    },
    ...
  ],

  data = any (the data being published, if any)
]]
function publishToSubscribers(callback_params_array, data)
  -- Don't want to block if there's nothing to do.
  if not callback_params_array or #callback_params_array == 0 then
    return
  end
  -- Locking this mutex informs this script that it cannot proceed
  -- the game until external work is finished.
  is_currently_iterating_callbacks = true

  local index = 1 -- Acts as an ID for the current callback being executed
  for i, callback_params in ipairs(callback_params_array) do
    local id = i
    local callback_params = callback_params
    Wait.condition(
      function()
        lockExternalScriptMutex()
        log(callback_params, "Publishing to: ", "", false, true)
        -- When this callback finishes, it will unlock the mutex, incrementing the index and allowing the next callback to be invoked
        callback_params.service.call(callback_params.callback, {data=data, onFinish_params=onFinishExternalScript_params})
        -- Once all callbacks have returned, the associated mutex isNotCurrentlyIteratingCallbacks is unlocked.
        Wait.condition(function()
          index = index + 1
          if index > #callback_params_array then
            is_currently_iterating_callbacks = false
          end
        end, isExternalScriptMutexUnlocked)
      end,
      function() return id == index and isExternalScriptMutexUnlocked() end
    )
  end
end

end -- End callbacks block

--[[
  Determines whether the passed data is valid for the described data type.

  Valid "data_type":
    - "hand_data"
    - "round_data"

  See function body for expected data makeup. 
--]]
function dataIsValid(data_type, data)
  local data_is_valid = true
  local errors = {missing_fields={}, invalid_types={}}
  function addMissingField(field)
    data_is_valid = false
    table.insert(errors.missing_fields, field)
  end
  function addInvalidType(key, received, expected)
    data_is_valid = false
    table.insert(errors.invalid_types, {[key] = "Expected " .. expected .. ", found " .. received .. " instead."})
  end

  if     HAND_DATA_TYPE  == data_type then
    -- id
    if not data.id then
      addMissingField("id")
    end
    if data.id and not type(data.id) == "number" then
      data_is_valid = false
      addInvalidType("id", type(data.id), "number")
    end
    -- big blind cost
    if not data.big_blind_cost then
      addMissingField("big_blind_cost")
    end
    if data.big_blind_cost and not type(data.big_blind_cost) == "number" then
      addInvalidType("big_blind_cost", type(data.big_blind_cost), "number")
    end
    -- big blind position
    if not data.big_blind_position then
      addMissingField("big_blind_position")
    end
    if data.big_blind_position and not type(data.big_blind_position) == "number" then
      addInvalidType("big_blind_position", type(data.big_blind_position), "number")
    end
    -- small_blind_cost
    if not data.small_blind_cost then
      addMissingField("small_blind_cost")
    end
    if data.small_blind_cost and not type(data.small_blind_cost) == "number" then
      addInvalidType("small_blind_cost", type(data.small_blind_cost), "number")
    end
    -- small blind position
    if not data.small_blind_position then
      addMissingField("small_blind_position")
    end
    if data.small_blind_position and not type(data.small_blind_position) == "number" then
      addInvalidType("small_blind_position", type(data.small_blind_position), "number")
    end
    -- dealer button
    if not data.button_position then
      addMissingField("button")
    end
    if data.button_position and not type(data.button_position) == "number" then
      addInvalidType("button", type(data.button), "number")
    end
  elseif ROUND_DATA_TYPE == data_type then
    if not data.round_type then
      addMissingField("round_type")
    end
    if data.round_type and not ROUND_TYPES[data.round_type] then
      local round_types = {}
      for round_type, _ in ROUND_TYPES do table.insert(round_types, round_type) end
      addInvalidType("round_type", data.round_type, table.concat(round_types, "|"))
    end
  elseif PLAYER_ACTION_DATA_TYPE == data_type then
    if not data.player_id then
      addMissingField("player_id")
    end
    if data.player_id and not type(data.player_id) == "string" then
      addInvalidType("player_id", data.player_id, "string")
    end
    if not data.intent then
      addMissingField("intent")
    end
    if data.intent and not PLAYER_INTENTS[data.intent] then
      local player_intents = {}
      for intent, _ in PLAYER_INTENTS do table.insert(player_intents, intent) end
      addInvalidType("intent", data.intent, table.concat(player_intents, "|"))
    end
    if data.chips and not type(data.chips) == "table" then
      local denominations = {}
      for denomination, _ in PLAYER_CHIP_DENOMINATIONS do table.insert(denominations, denomination) end
      for denomination, count in data.chips do
        if not PLAYER_CHIP_DENOMINATIONS[denomination] then
          addInvalidType("chips", denomination, "index of "..table.concat(denominations, "|"))
        elseif not type(count) == "number" then
          addInvalidType('chips["'..denomination..'"]', type(count), "number")
        end
      end
    end
  end

  if not data_is_valid then
    log(errors, "Errors validating hand_start: ", "", false, true)
    return false
  end
  return true
end
