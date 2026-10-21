--[[
  At the start of a hand, the blinds and are moved and their values are decided. This work
  is simple but it's nice to encapsulate it here.
  
  The end of a hand doesn't really "require" anything, but for sanity we can encapsulate
  cleanup actions here, such as reforming the Dealer's deck, ensuring chips are in the
  right place on the table, and whatever else is condusive to starting subsequent hands.
]]

local BlindManager
local DeckManager
local EventBus
local GameStateHandler
local TurnManager
local ServerClientConnection

function init(params)
  BlindManager           = params.Services.BlindManager
  DeckManager            = params.Services.DeckManager
  EventBus               = params.Services.EventBus
  GameStateHandler       = params.Services.GameStateHandler

  ServerClientConnection = params.Services.ServerClientConnection

  EventBus.call("subscribe", {
    event_type        = "hand_started",
    callback_params   = {
      service = self,
      callback = "onHandStarted"
    }
  })
end

do -- Config
  HAND_START_DELAY  = 2
  HAND_END_DELAY    = 2
end

local SORTING_DECK_MUTEX_INDEX       = "sorting deck"
local deckOrderReceived_params       = {
  service = self,
  callback = "onDeckOrderReceived"
}

do -- Mutex

  local associative_mutex = {}
  function lockAssociativeMutex(index) associative_mutex[index] = true end
  function unlockAssociativeMutex(index) associative_mutex[index] = false end
  function isAssociativeMutexUnlocked(index) return not associative_mutex[index] end

end

--[[
  
  When a hand starts, the buttons are configured.
  The big/small blinds are repositioned and may have a new cost.
  The dealer button is also repositioned.
  
  params = {
    data = {
      id                   = int,
      big_blind_cost       = int,
      big_blind_position   = int,
      small_blind_cost     = int,
      small_blind_position = int,
      button_position      = int
    },

    onFinish_params = {
      service  = <Scripting Zone>,
      callback = string,
      args     = any
    }
  }
]]
function onHandStarted(params)
  local data = params.data
  local onFinish_params = params.onFinish_params

  local log_message = logString(params.data, "nHandHandler.onHandStarted", "[INFO]", false, true)
  log(log_message)

  BlindManager.call("configureButtonsFromHandStart", data)

  
  --[[
    The order of the deck is available to fetch after a hand starts.
  ]]
  -- NOTE: Sometimes requests seem to "hang". Not sure if they get lost or why,
  -- but I might want to consider putting retry logic here.
  if GameStateHandler.getVar("GAME_ID") ~= "0" then -- Debug line. If GAME_ID is 0 then we're using playback data and the order of the deck is innaccessible.
    lockAssociativeMutex(SORTING_DECK_MUTEX_INDEX)
    Wait.time(
      function()
        ServerClientConnection.call("getDeckOrder", deckOrderReceived_params)
      end,
      0.5
    )
  end

  --[[
    Configuration of the buttons is technically instantaneous, though
    the graphical transformation of their location takes some time.
    Since the server fires hand_start and round_start pretty much at the
    same time, we provide a reasonable delay for this transformation to 
    occur.
  ]]
  Wait.condition(
    function()
      broadcastToAll("Starting hand #"..data.id, "White")
      Wait.time(
        function()
          log("EVENT BUS MUTEX SHOULD HAVE BEEN RELEASED HERE")
          onFinish_params.service.call(onFinish_params.callback)
        end,
        HAND_START_DELAY
      )
    end,
    function() return isAssociativeMutexUnlocked(SORTING_DECK_MUTEX_INDEX) end
  )
end

-- function testGetDeckOrder()
--   log("\nHandHandler.testGetDeckOrder:\nFetching deck order")
--   lockAssociativeMutex("sorting deck")
--   ServerClientConnection.call("getDeckOrder", deckOrderReceived_params)
-- end

function onDeckOrderReceived(serialized_deck_order)
  -- Need to normalize the entries
  if serialized_deck_order == nil then
    Wait.frames(
      function()
        -- TODO: have some recovery logic
        local log_message = logString("Failed to fetch deck order", "HandHandler.onDeckOrderReceived", "[ERROR]", false, true)
        log(log_message)
      end,
      1
    )
    return
  end

  local normalized_deck_order = {}
  for card in serialized_deck_order do
    table.insert(normalized_deck_order, string.char(card.rank, card.suit))
  end

  local sortDeckOrder_params = {
    deck_order = normalized_deck_order,
    onFinish_params = {
      service  = self,
      callback = "unlockAssociativeMutex",
      args     = SORTING_DECK_MUTEX_INDEX
    }
  }
  DeckManager.call("setDeckOrder", sortDeckOrder_params)
end