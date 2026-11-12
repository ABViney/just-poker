--[[ Lua code. See documentation: https://api.tabletopsimulator.com/ --]]

--[[ The onLoad event is called after the game save finishes loading. --]]
GAME_STATE_LOADED = false

local POKER_SERVICE_ENDPOINT
local GAME_MASTER_AUTH_TOKEN
local GAME_ID
local GAME_STARTED = false


local Objects
local Services
local Zones

local associative_mutex = {}
function lockAssociativeMutex(index) associative_mutex[index] = true end
function unlockAssociativeMutex(index) associative_mutex[index] = false end
function isAssociativeMutexUnlocked(index) return not associative_mutex[index] end

function onLoad()
  print("=============================") -- Helps delimit restarts

  function createPlayerZoneTable(hand_zone_guid, stack_zone_guid, bet_zone_guid, blind_zone_guid)
    return {
      hand_zone  = getObjectFromGUID(hand_zone_guid),
      stack_zone = getObjectFromGUID(stack_zone_guid),
      bet_zone   = getObjectFromGUID(bet_zone_guid),
      blind_zone = getObjectFromGUID(blind_zone_guid)
    }
  end

  -- Group services and zones into a globally accessible format
  Services = {
    ExternalLogConnection  = getObjectFromGUID("89431a"),
    ServerClientConnection = getObjectFromGUID("1f6a51"),

    BlindManager     = getObjectFromGUID("07e1ee"),
    ChipManager      = getObjectFromGUID("c56c2d"),
    DeckManager      = getObjectFromGUID("f7f04c"),
    EventBus         = getObjectFromGUID("0f9a75"),
    PlayerManager    = getObjectFromGUID("03b336"),
    PotManager       = getObjectFromGUID("72d9ba"),

    GameStateHandler = getObjectFromGUID("ff149d"),
    HandHandler      = getObjectFromGUID("dc1416"),
    RoundHandler     = getObjectFromGUID("d97696"),
    TurnHandler      = getObjectFromGUID("1ec0b2"),
    PayoutHandler    = getObjectFromGUID("c1d0da"),

    UserRepository   = getObjectFromGUID("5d5c07")
  }

  Zones = {
    PlayerZones = {
      Red    = createPlayerZoneTable("0679f3", "1db08a", "cad943", "6c8e98"),
      Orange = createPlayerZoneTable("b1c996", "b4776d", "79ac5d", "eae4c3"),
      Yellow = createPlayerZoneTable("a16e18", "bc5bd3", "61e3f4", "2f7658"),
      Green  = createPlayerZoneTable("52b418", "123649", "7c3a59", "5de3a9"),
      Teal   = createPlayerZoneTable("5a773c", "7526cf", "eb2f1e", "363913"),
      Blue   = createPlayerZoneTable("c05d40", "6723f4", "ffbfd9", "47a939"),
      Purple = createPlayerZoneTable("23c35a", "c19173", "0fc032", "016b77"),
      Pink   = createPlayerZoneTable("ff2ae5", "92cb00", "06b225", "5d5794"),
    },

    bot_chip_exchange_stack_zone = getObjectFromGUID("662bb8"), -- Where bots exchange
    chip_exchange_zone           = getObjectFromGUID("7734f1"), -- Where players put chips to exchange
    chip_exchange_stack_zone     = getObjectFromGUID("135c3d"), -- Where chips are stacked after a player-authed exchanged
    dealer_deck_zone             = getObjectFromGUID("22b504"),
    dealer_deck_spread_zone      = getObjectFromGUID("49a960"),
    pot_zone                     = getObjectFromGUID("cac241"),
    pot_stack_zone               = getObjectFromGUID("8a44ce")
  }

  Objects = {
    initial_deck  = getObjectFromGUID("9988fb"),
    dealer_button = getObjectFromGUID("f26272"),
    big_blind     = getObjectFromGUID("a560f3"),
    small_blind   = getObjectFromGUID("a3ca23")
  }

  local params = {Services = Services, Zones = Zones, Objects = Objects}

  -- Initialize services
  log("Initializing services...")

  for service in params.Services do
    service.call("init", params)
  end

  do -- Whatever buttons i created to help me test things

  -- Create UI
  local create_deck = getObjectFromGUID("b0cdb9")
  create_deck.createButton({
    label=          "Create a deck with metadata",
    click_function= "createDeck",
    function_owner= Services.DeckManager,
    position=       {0, 0.5, 1},
    height=300, width=1000, font_size=100
  })

  local find_ace_of_spades = getObjectFromGUID("cebd10")
  find_ace_of_spades.createButton({
    label=          "Sort deck",
    click_function= "sortDeck",
    function_owner= Services.DeckManager,
    position=       {0, 0.5, 1},
    height=300, width=1000, font_size=100
  })

  local get_deck_order = getObjectFromGUID("71225f")
  get_deck_order.createButton({
    label=          "Log XML UI",
    click_function= "logXMLUI",
    function_owner= self,
    position=       {0, 0.5, 1},
    height=300, width=1000, font_size=100
  })

  end

  -- Services.ServerClientConnection.call("createEventListener")

  do -- Temp fill-ins for testing
    GAME_MASTER_AUTH_TOKEN = "bahms.hguVUkyjJyE5gvlL.J0vYraHLeKc_79FyNyrSOYo8cf1IGqG9RiXXZLCKXaI"
    _initializeGameConfigUI()
  end
end

function onUpdate() end


--[[
  Everything below this is for managing the UI.
  This is a pain in the butt.

  Note:
  The callbacks invoked by UI elements are provided 3 parameters:
  1. The <LuaPlayer> that caused the event
  2. The "value" of the event 
]]

--[[
  GAME CONFIG UI

  The game master handles setting up and starting the game.
  These controls 
]]

  -- Window
  local gameConfig_window_id                          = "panel_game-config-menu"

  -- Menu bar
  local gameConfig_window_titleText_id                = "text_game-config-menu-title"
  local gameConfig_window_minimizeButton_id           = "button_minimize-game-config-menu"

  -- Tabs
  local gameConfig_createNewGameTab_id                = "game-config_tab_create-new-game"
  local gameConfig_listenToExistingGameTab_id         = "game-config_tab_listen-to-existing-game"

  -- Pages
  local gameConfig_createNewGamePage_id               = "page_create-game-page"
  local gameConfig_listenToExistingGamePage_id        = "page_listen-to-existing-game-page"

  -- Form
  local gameConfig_createGameForm_id                  = "form_create-game"

  -- Buttons
  local gameConfig_createNewGameButton_id             = "button_create-game"
  local gameConfig_startGameButton_id                 = "button_start-game"

  -- Dropdowns
  local gameConfig_numberOfHumansDropdown_id          = "dropdown_number-of-humans"
  local gameConfig_numberOfBotsDropdown_id            = "dropdown_number-of-bots"

  -- Inputs
  local gameConfig_createGameAuthToken_id             = "input_create-game-auth-token"
  local gameConfig_listenToExistingGameAuthToken_id   = "listen_to_game_auth_input"

  local gameConfig_playerAuthTokenInputs_ids = {
    -- I could do an increment for this, but I don't intend to access any individual
    -- auth input outside of a loop
    [1] = "input_player-auth-token_1",
    [2] = "input_player-auth-token_2",
    [3] = "input_player-auth-token_3",
    [4] = "input_player-auth-token_4",
    [5] = "input_player-auth-token_5",
    [6] = "input_player-auth-token_6",
    [7] = "input_player-auth-token_7",
    [8] = "input_player-auth-token_8",
  }

  local gameConfig_botTurnTimeoutMsInput_id           = "input_bot-turn-timeout"
  
  local gameConfig_initialCostSmallBlindInput_id      = "input_initial-cost_small-blind"
  local gameConfig_initialCostBigBlindInput_id        = "input_initial-cost_big-blind"
  
  local gameConfig_initialStartingChips10Input_id     = "input_starting-chips_10"
  local gameConfig_initialStartingChips50Input_id     = "input_starting-chips_50"
  local gameConfig_initialStartingChips100Input_id    = "input_starting-chips_100"
  local gameConfig_initialStartingChips500Input_id    = "input_starting-chips_500"
  local gameConfig_initialStartingChips1000Input_id   = "input_starting-chips_1000"

  -- Toggles
  local gameConfig_autoStartHandsToggle_id            = "toggle_auto-start-hands"

  local gameConfig_usingChipDenomination10Toggle_id   = "toggle_using-chip-denomination_10"
  local gameConfig_usingChipDenomination50Toggle_id   = "toggle_using-chip-denomination_50"
  local gameConfig_usingChipDenomination100Toggle_id  = "toggle_using-chip-denomination_100"
  local gameConfig_usingChipDenomination500Toggle_id  = "toggle_using-chip-denomination_500"
  local gameConfig_usingChipDenomination1000Toggle_id = "toggle_using-chip-denomination_1000"

  local GAME_CONFIG = {
    -- Game master auth token
    auth_token = "bahms.hguVUkyjJyE5gvlL.J0vYraHLeKc_79FyNyrSOYo8cf1IGqG9RiXXZLCKXaI",

    -- Number of players
    number_of_human_players = 0,
    number_of_bot_players   = 8,

    -- In-game players' auth tokens
    player_auth_tokens = {},

    -- Bot turn timeout
    bot_turn_timeout_ms     = 30000,

    -- Auto start hands
    auto_start_hands        = false,

    -- Blinds costs
    big_blind_cost          = 100,
    small_blind_cost        = 50,

    -- Using chip denominations
    use_10_chips            = true,
    use_50_chips            = true,
    use_100_chips           = true,
    use_500_chips           = true,
    use_1000_chips          = true,

    -- Starting chips
    starting_10_chips       = 10,
    starting_50_chips       = 5,
    starting_100_chips      = 5,
    starting_500_chips      = 1,
    starting_1000_chips     = 4,
  }

  function _initializeGameConfigUI()
    -- Create game page
    UI.setAttribute("input_create-game-auth-token",   "text", GAME_MASTER_AUTH_TOKEN)
    _updateGameConfigPlayerCountFields()
    UI.setAttribute("input_bot-turn-timeout",         "text", GAME_CONFIG.bot_turn_timeout_ms)
    UI.setAttribute("input_initial-cost_big-blind",   "text", GAME_CONFIG.big_blind_cost)
    UI.setAttribute("input_initial-cost_small-blind", "text", GAME_CONFIG.small_blind_cost)
    UI.setAttribute("input_starting-chips_10",        "text", GAME_CONFIG.starting_10_chips)
    UI.setAttribute("input_starting-chips_50",        "text", GAME_CONFIG.starting_50_chips)
    UI.setAttribute("input_starting-chips_100",       "text", GAME_CONFIG.starting_100_chips)
    UI.setAttribute("input_starting-chips_500",       "text", GAME_CONFIG.starting_500_chips)
    UI.setAttribute("input_starting-chips_1000",      "text", GAME_CONFIG.starting_1000_chips)
    -- Setting the toggles by the GAME_CONFIG
    if GAME_CONFIG.use_10_chips then
      Global.UI.setAttribute(gameConfig_usingChipDenomination10Toggle_id, "isOn", "True")
    else
      Global.UI.setAttribute(gameConfig_usingChipDenomination10Toggle_id, "isOn", "False")
    end
    if GAME_CONFIG.use_50_chips then
      Global.UI.setAttribute(gameConfig_usingChipDenomination50Toggle_id, "isOn", "True")
    else
      Global.UI.setAttribute(gameConfig_usingChipDenomination50Toggle_id, "isOn", "False")
    end
    if GAME_CONFIG.use_100_chips then
      Global.UI.setAttribute(gameConfig_usingChipDenomination100Toggle_id, "isOn", "True")
    else
      Global.UI.setAttribute(gameConfig_usingChipDenomination100Toggle_id, "isOn", "False")
    end
    if GAME_CONFIG.use_500_chips then
      Global.UI.setAttribute(gameConfig_usingChipDenomination500Toggle_id, "isOn", "True")
    else
      Global.UI.setAttribute(gameConfig_usingChipDenomination500Toggle_id, "isOn", "False")
    end
    if GAME_CONFIG.use_1000_chips then
      Global.UI.setAttribute(gameConfig_usingChipDenomination1000Toggle_id, "isOn", "True")
    else
      Global.UI.setAttribute(gameConfig_usingChipDenomination1000Toggle_id, "isOn", "False")
    end
    _updateGameConfigStartingChipsInputFields()
    
    -- Listen to game page
    UI.setAttribute("listen_to_game_auth_input", "text", GAME_MASTER_AUTH_TOKEN)
  end

  --[[
    Handles switching which form is presented when a tab is selected.
    Note: Due to how ToggleGroup works, this callback gets invoked twice--that's why
      I compare value to "True" when matching the id
  ]]
  function onGameConfigMenuTabChanged(player, value, id)
    -- ToggleButtons can be clicked even if they are selected. Swapping their
    -- attributes gives a cleaner look and feel.
    local set_selected_tab_attributes = {
      interactable = "False",
      isOn = "True"
    }
    local set_unselected_tab_attributes = {
      interactable = "True",
      isOn = "False"
    }

    if id == "game-config_tab_create-new-game" and value == "True" then
      -- Reveals the create-new-game page layout and sets the tab
      Global.UI.setAttributes(gameConfig_createNewGameTab_id, set_selected_tab_attributes)
      Global.UI.setAttributes(gameConfig_listenToExistingGameTab_id, set_unselected_tab_attributes)
      Global.UI.show(gameConfig_createNewGamePage_id)
      Global.UI.hide(gameConfig_listenToExistingGamePage_id)
    elseif id == "game-config_tab_listen-to-existing-game" and value == "True" then
      -- Reveals the listen-to-existing-game page layout and sets the tab
      Global.UI.setAttributes(gameConfig_listenToExistingGameTab_id, set_selected_tab_attributes)
      Global.UI.setAttributes(gameConfig_createNewGameTab_id, set_unselected_tab_attributes)
      Global.UI.show(gameConfig_listenToExistingGamePage_id)
      Global.UI.hide(gameConfig_createNewGamePage_id)
    end
  end

  --[[
    Handles presentation for adjusting dropdowns and player auth tokens inputs
  ]]
  function _updateGameConfigPlayerCountFields()
    -- I'd like to reimagine this to remove from the view inputs that aren't used.
    -- For now, this will update the dropdowns to reflect the correct numbers,
    -- and disable inputs for auth inputs that exceed what the game master is expecting.
    local number_of_human_players = GAME_CONFIG.number_of_human_players
    local number_of_bot_players   = GAME_CONFIG.number_of_bot_players

    -- Apparently this is how you change which dropdown option is selected :^)
    Global.UI.setAttribute(gameConfig_numberOfHumansDropdown_id, "value", number_of_human_players)
    Global.UI.setAttribute(gameConfig_numberOfBotsDropdown_id, "value", number_of_bot_players)

    for i=1, 8 do
      if i <= number_of_human_players then
        Global.UI.setAttribute(gameConfig_playerAuthTokenInputs_ids[i], "interactable", "True")
      else
        Global.UI.setAttribute(gameConfig_playerAuthTokenInputs_ids[i], "interactable", "False")
      end
    end
  end

  function _updateGameConfigStartingChipsInputFields()
    local setInteractive = function(id, enabled)
      if enabled then
        Global.UI.setAttribute(id, "interactable", "True")
      else
        Global.UI.setAttribute(id, "interactable", "False")
      end
    end

    setInteractive(gameConfig_initialStartingChips10Input_id, GAME_CONFIG.use_10_chips)
    setInteractive(gameConfig_initialStartingChips50Input_id, GAME_CONFIG.use_50_chips)
    setInteractive(gameConfig_initialStartingChips100Input_id, GAME_CONFIG.use_100_chips)
    setInteractive(gameConfig_initialStartingChips500Input_id, GAME_CONFIG.use_500_chips)
    setInteractive(gameConfig_initialStartingChips1000Input_id, GAME_CONFIG.use_1000_chips)

  end
  --[[
    This is a verbose overload but it lets me encapsulate everything regarding 
    edits to the Game Config in the UI to one function.
    
    player - <LuaPlayer> (Doesn't matter)
    value  - string
    id     - string

    The `id` is formatted in a underscore delimited format
    e.g. input_starting-chips_1000

  ]]
  local test_index = 0
  function onGameConfigUpdated(player, value, id)
    local log_message = logString("Event from ("..id..") invoked with value ("..value..")", "Global.onGameConfigUpdated", "[INFO]", false, true)
    log("\n"..test_index.."\n"..log_message)
    test_index = test_index + 1

    -- Using this variable to discern if an event was resolved.
    -- If not, I know where to go back to.
    -- This can be removed from the final version.
    local resolved = false

    local metadata = split(id, "_") -- `split` is a string.split utility function defined at the bottom of this file
    local event_source = metadata[1]


    if event_source == "dropdown" then
      -- There are 2 dropdowns for setting the number of players/bots
      -- Players must have an accompanying auth token provided for them

      -- Update the fields in the config with new player distribution.
      -- Our poker mod only supports 8 players at the table. That's a hard limit.
      if id == gameConfig_numberOfHumansDropdown_id then
        GAME_CONFIG.number_of_human_players = tonumber(value)
        if GAME_CONFIG.number_of_human_players + GAME_CONFIG.number_of_bot_players > 8 then
          GAME_CONFIG.number_of_bot_players = 8 - GAME_CONFIG.number_of_human_players
        end
        resolved = true
      elseif id == gameConfig_numberOfBotsDropdown_id then
        GAME_CONFIG.number_of_bot_players = tonumber(value)
        if GAME_CONFIG.number_of_human_players + GAME_CONFIG.number_of_bot_players > 8 then
          GAME_CONFIG.number_of_human_players = 8 - GAME_CONFIG.number_of_bot_players
        end
        resolved = true
      end

      _updateGameConfigPlayerCountFields()

    elseif event_source == "input" then
      -- Game master's auth token

      if id == gameConfig_createGameAuthToken_id then
        GAME_CONFIG.auth_token = value or ""
      end

      -- Player auth tokens
      if metadata[2] == "player-auth-token" then
        GAME_CONFIG.player_auth_tokens[tonumber(metadata[3])] = value
        resolved = true

      -- Bot turn timeout
      elseif id == gameConfig_botTurnTimeoutMsInput_id then
        GAME_CONFIG.bot_turn_timeout_ms = tonumber(value) or 0
        resolved = true

      -- Blinds
      elseif id == gameConfig_initialCostBigBlindInput_id then
        GAME_CONFIG.big_blind_cost = tonumber(value) or 0
        resolved = true
      elseif id == gameConfig_initialCostSmallBlindInput_id then
        GAME_CONFIG.small_blind_cost = tonumber(value) or 0
        resolved = true

      -- Starting chips
      elseif metadata[2] == "starting-chips" then
        if metadata[3] == "10" then
          GAME_CONFIG.starting_10_chips = tonumber(value) or 0
          resolved = true
        elseif metadata[3] == "50" then
          GAME_CONFIG.starting_50_chips = tonumber(value) or 0
          resolved = true
        elseif metadata[3] == "100" then
          GAME_CONFIG.starting_100_chips = tonumber(value) or 0
          resolved = true
        elseif metadata[3] == "500" then
          GAME_CONFIG.starting_500_chips = tonumber(value) or 0
          resolved = true
        elseif metadata[3] == "1000" then
          GAME_CONFIG.starting_1000_chips = tonumber(value) or 0
          resolved = true
        end
      end
    elseif event_source == "toggle" then
      -- Auto-start hands
      if id == gameConfig_autoStartHandsToggle_id then
        GAME_CONFIG.auto_start_hands = value == "True" and true or false
      -- Chip denominations
      elseif metadata[2] == "using-chip-denomination" then
        if     id == gameConfig_usingChipDenomination10Toggle_id then
          GAME_CONFIG.use_10_chips = "True" and true or false
          resolved = true
        elseif id == gameConfig_usingChipDenomination50Toggle_id then
          GAME_CONFIG.use_50_chips = value == "True" and true or false
          resolved = true
        elseif id == gameConfig_usingChipDenomination100Toggle_id then
          GAME_CONFIG.use_100_chips = value == "True" and true or false
          resolved = true
        elseif id == gameConfig_usingChipDenomination500Toggle_id then
          GAME_CONFIG.use_500_chips = value == "True" and true or false
          resolved = true
        elseif id == gameConfig_usingChipDenomination1000Toggle_id then
          GAME_CONFIG.use_1000_chips = value == "True" and true or false
          resolved = true
        end
        _updateGameConfigStartingChipsInputFields()
      end
    end

    if not resolved then
      log_message = logString("["..event_source.."] event-source not supported. Event originated from ["..id.."] with value of["..value.."]")
    end
    
  end

  --[[
    If "Create game" is clicked while an input box is selected, the "onClick"
    event fires before "onEndEdit".

    This just adds a frame delay so that event has time to fire.
  ]]
  function onCreateGameFromConfigButtonClicked(player, value, id)
    Global.UI.setAttribute(gameConfig_createNewGameButton_id, "interactable", "False")
    Wait.frames(
      function()
        _onCreateGameFromConfigButtonClicked(player, value, id)
      end,
      1
    )
  end

  -- The result of web requests must be retrieved via another callback.
  local AUTH_TOKEN_REQUEST_RESULTS = {}
  local GAME_CREATED_RESULT        = nil
  local PLAYERS_JOINED_RESULTS      = {}
  function _onCreateGameFromConfigButtonClicked(_, _, _)
    local log_message = logString("", "Global.onCreateGameFromConfigButtonClicked", "[INFO]", false, true)
    log("\n"..log_message)

    --[[
      Validating form data

      Not super sure how to structure this. Validating config fields can
      be done sequentially, but validating auth tokens requires making
      web requests which can't be synchronous. Once web requests are finished,
      the logic goes back to being sequential.

      I think I'll just wing this for now. Update this if I come up with
      something better.
    ]]
    
    --[[
      There are 3 steps I take toward creating a game:
      1. Validate the user's form.
      2. Get the User profiles for the game master and any player auth tokens.
      3. Check that all User profiles exist.
      4. Create the game
      5. Join the human players.
      6. Listen to the game.
    ]]
    local PROCESSING_CREATE_GAME_MUTEX  = "validating fields and tokens for creating a new game"
    local INITIAL_FORM_VALIDATION_MUTEX = "validating fields in the Create Game form"
    local user_form_is_valid            = true -- The form is assumed correct until proven otherwise.
    local VALIDATING_AUTH_TOKENS_MUTEX  = "fetching user data for auth tokens"
    local auth_tokens_are_valid         = false
    local CREATING_GAME_MUTEX           = "creating game for this config"
    local game_was_created              = false
    local JOINING_HUMAN_PLAYERS_MUTEX   = "adding TTS players to the game"
    local all_human_players_joined      = false
    
    -- The final branch discerns if the form should still be usable, which
    -- is determined by whether all steps succeeded.
    local allConditionsFulfilled = function()
      -- Routines for each step are set to run once the preceding mutex is released.
      -- Whether or not they do anything is gated by the associated boolean.
      -- If there is an early return, those coroutines don't stop existing, so they 
      -- need to be ran to ensure there aren't duplicates later.
      return user_form_is_valid and auth_tokens_are_valid and game_was_created and all_human_players_joined
    end
    
    if not isAssociativeMutexUnlocked(PROCESSING_CREATE_GAME_MUTEX) then return end
    
    lockAssociativeMutex(PROCESSING_CREATE_GAME_MUTEX)
    lockAssociativeMutex(INITIAL_FORM_VALIDATION_MUTEX)
    lockAssociativeMutex(VALIDATING_AUTH_TOKENS_MUTEX)
    lockAssociativeMutex(CREATING_GAME_MUTEX)
    lockAssociativeMutex(JOINING_HUMAN_PLAYERS_MUTEX)

    -- Enables/Disables inputs in the form for creating a game
    local setGameConfigWindowInteractivity = function(interactable)
      local all_create_game_field_ids = {gameConfig_createGameAuthToken_id, gameConfig_numberOfHumansDropdown_id, gameConfig_numberOfBotsDropdown_id, gameConfig_botTurnTimeoutMsInput_id, gameConfig_autoStartHandsToggle_id, gameConfig_initialCostSmallBlindInput_id, gameConfig_initialCostBigBlindInput_id, gameConfig_usingChipDenomination10Toggle_id, gameConfig_usingChipDenomination50Toggle_id, gameConfig_usingChipDenomination100Toggle_id, gameConfig_usingChipDenomination500Toggle_id, gameConfig_usingChipDenomination1000Toggle_id, gameConfig_initialStartingChips10Input_id, gameConfig_initialStartingChips50Input_id, gameConfig_initialStartingChips100Input_id, gameConfig_initialStartingChips500Input_id, gameConfig_initialStartingChips1000Input_id, gameConfig_createNewGameButton_id, table.unpack(gameConfig_playerAuthTokenInputs_ids)}
      for field_id in all_create_game_field_ids do
        Global.UI.setAttribute(field_id, "interactable", tostring(interactable))
      end
    end

    -- The form shouldn't be editable until validation is complete.
    -- This can take a few seconds while web requests are made.
    setGameConfigWindowInteractivity(false)

    -- Resetting external fields
    AUTH_TOKEN_REQUEST_RESULTS = {}
    GAME_CREATED_RESULT        = nil
    PLAYERS_JOINED_RESULTS      = {}

    -- Unpacking all fields
    local game_master_auth_token  = GAME_CONFIG.auth_token

    local number_of_human_players = GAME_CONFIG.number_of_human_players
    local number_of_bot_players   = GAME_CONFIG.number_of_bot_players
    local player_auth_tokens      = {table.unpack(GAME_CONFIG.player_auth_tokens, 1, number_of_human_players)}

    local bot_turn_timeout_ms     = GAME_CONFIG.bot_turn_timeout_ms
    
    local auto_start_hands        = GAME_CONFIG.auto_start_hands

    local small_blind_cost        = GAME_CONFIG.small_blind_cost
    local big_blind_cost          = GAME_CONFIG.big_blind_cost

    local using_chips_denominations = {
      ["10"]   = GAME_CONFIG.use_10_chips,
      ["50"]   = GAME_CONFIG.use_50_chips,
      ["100"]  = GAME_CONFIG.use_100_chips,
      ["500"]  = GAME_CONFIG.use_500_chips,
      ["1000"] = GAME_CONFIG.use_1000_chips
    }

    local starting_chips_for_denomination = {
      ["10"]   = GAME_CONFIG.starting_10_chips,
      ["50"]   = GAME_CONFIG.starting_50_chips,
      ["100"]  = GAME_CONFIG.starting_100_chips,
      ["500"]  = GAME_CONFIG.starting_500_chips,
      ["1000"] = GAME_CONFIG.starting_1000_chips
    }
    

    -- Releases INITIAL_FORM_VALIDATION_MUTEX once completed.
    -- Sets user_form_is_valid to `false` if any steps failed.
    --
    -- This runs the initial validation to verify the form will produce a valid
    -- GameConfigDTO. If any of the validation steps return a string, then there
    -- are errors that the user must address.
    Wait.frames(
      function()
        local errors = ""
        -- Encapsulates all the logic for the initial checks against each field in the form.
        -- I.e. ensures that the current fields will produce a valid GameConfigDTO
        local field_validation_sequence = {
          {
            -- Player counts and initial auth token screens
            func = function()
              if not game_master_auth_token then errors = errors.."Missing auth token for game maker.\n"
              elseif #game_master_auth_token ~= 66 then errors = errors.."Invalid length of auth token for game maker.\n"
              elseif string.sub(game_master_auth_token, 1, 6) ~= "bahms." then errors = errors.."Malformed auth token for game maker.\n"
              end

              local number_of_players = number_of_human_players + number_of_bot_players

              if number_of_players < 2 then errors = errors.."A game must have a minimum of 2 players.\n" end
              if number_of_players > 8 then errors = errors.."A game must have a maximum of 8 players.\n" end

              for i=1, number_of_human_players do
                if not player_auth_tokens[i] then errors = errors.."Missing auth token for Player #"..i.."\n"
                elseif #player_auth_tokens[i] ~= 66 then errors = errors.."Invalid length of auth token for Player #"..i.."\n"
                elseif string.sub(player_auth_tokens[i], 1, 6) ~= "bahms." then errors = errors.."Malformed auth token for Player #"..i.."\n"
                end

                -- Check that player auth tokens are duplicated
                for c=i+1, number_of_human_players do
                  if player_auth_tokens[i] == player_auth_tokens[c] then errors = errors.."Player #"..i.." and Player #"..c.." have the same auth token.\n" end
                end
              end

              return #errors == 0
            end,
            log_message = "Confirming valid player count and appropriate number of auth tokens supplied"
          },
          {
            -- Checking bot turn timout isn't negative
            func = function()
              if bot_turn_timeout_ms < 0 then errors = errors.."Bot turn timeout ms cannot be negative.\n" end
              
              if #errors > 0 then return false end
              return #errors == 0
            end,
            log_message = "Checking bot turn timeout is a valid amount"
          },
          {
            -- Auto-start hands
            func = function()
              if type(auto_start_hands) ~= "boolean" then errors = errors.."Auto-start hands isn't a boolean.\n" end
              return #errors == 0
            end,
            log_message = "Making sure auto-start hands is a boolean"
          },
          {
            func = function()
              if small_blind_cost < 0 then errors = errors.."Small blind cannot be less than 0.\n" end
              if big_blind_cost   < 0 then errors = errors.."Big blind cannot be less than 0.\n" end
              if small_blind_cost > big_blind_cost then errors = errors.."Small blind cannot be greater than the Big blind.\n" end
              return #errors == 0
            end,
            log_message = "Ensuring small and big blinds are valid"
          },
          {
            func = function()
              local errors = ""
              for denomination in {"10", "50", "100", "500", "1000"} do
                if using_chips_denominations[denomination] then
                  if starting_chips_for_denomination[denomination] < 0 then
                    errors = errors.."Starting chip count for "..denomination.." chips must be 0 or greater.\n"
                  end
                end
              end
              return #errors == 0
            end,
            log_message = "Evaluating that all chips being used are real"
          }
        }

        local index = 1
        for i=1, #field_validation_sequence do
          local setup_index = i
          -- These execute in sequence and increment index after completing.
          -- This gates the execution of each validation step until the prior
          -- one is completed.
          Wait.condition(
            function()
              local func        = field_validation_sequence[index].func
              local log_message = "["..index.."]: "..field_validation_sequence[index].log_message

              log(log_message)
              func()

              -- If there are errors, then the user must address them before
              -- a game can be created.
              user_form_is_valid = user_form_is_valid and #errors == 0

              Wait.frames(
                function() index = index + 1 end,
                1
              )
            end,
            function() return index == setup_index end
          )
        end

        -- This runs after all validation steps have completed.
        Wait.condition(
          function()
            if not user_form_is_valid then
              -- If there were errors, inform the user and unlock the form.
              broadcastToColor("Could not start game: Invalid fields", "Black", "Red")
              broadcastToColor(errors, "Black", "Grey")
            end
            unlockAssociativeMutex(INITIAL_FORM_VALIDATION_MUTEX)
          end,
          function() return index == #field_validation_sequence+1 end
        )
      end,
      1
    )

    -- Releases VALIDATING_AUTH_TOKENS_MUTEX once completed.
    -- Sets auth_tokens_are_valid to `true` if the game master and all players have valid auth tokens.
    -- Modifies AUTH_TOKEN_REQUEST_RESULTS
    --
    -- This confirms that all auth tokens being used are valid 
    -- and associates them with their user profiles.
    local users = nil -- Will contain all user profiles attached to auth tokens. The first index is the game master, subsequent indices are players
    Wait.condition(
      function()
        -- If the initial validation failed, then do nothing.
        if not user_form_is_valid then
          unlockAssociativeMutex(VALIDATING_AUTH_TOKENS_MUTEX)
          return
        end

        -- If there were no issues with the form, we get user data from the server
        -- for each auth token being used.
        local ServerClientConnection = Services.ServerClientConnection
        local auth_tokens = {GAME_CONFIG.auth_token, table.unpack(GAME_CONFIG.player_auth_tokens)}
        
        for i, auth_token in ipairs(auth_tokens) do
          ServerClientConnection.call("getUserByAuthToken", {
            index = i,
            auth_token = auth_token,

            onFinish_params = {
              service  = self,
              callback = "_onGetUserByAuthTokenResponseReceived"
            }
          })
        end

        -- WebRequests run asynchronously. Responses are processed and loaded into
        -- the AUTH_TOKEN_REQUEST_RESULTS table via the callback defined elsewhere.
        --
        -- Once all queries to the server regarding auth tokens have completed,
        -- we can figure out if any are invalid and inform the user.
        Wait.condition(
          function()
            local errors = ""
            users = {}

            for i, result in ipairs(AUTH_TOKEN_REQUEST_RESULTS) do
              if result.error or result.user == nil then
                errors = errors..(i>1 and "Player #"..(i-1) or "Game Master").."'s auth token failed to validate: "..(result.error.text or "I don't know why.").."\n"
              else
                users[i] = result.user
                users[i].auth_token = result.auth_token
              end
            end

            if users[1] ~= nil and users[1].user_type ~= "game_master" then
              -- Check that the game master's token actually belongs to a game master.
              -- This is an admin token and is required for this mod to work.
                errors = errors.."A \"game_master\" user type is required to use this mod. [Received: "..user[1].user_type.."]"
            end

            for i=2, #users do
              if users[i] ~= nil and users[i].user_type == "bot" then
                errors = errors.."Player #"..(i-1).." ("..users[i].display_name..") has a \"bot\" user type.\n"
              end
            end

            auth_tokens_are_valid = #errors == 0

            -- If any auth tokens couldn't be associated with a profile, inform
            -- the user which ones were invalid.
            if auth_tokens_are_valid then
              local UserRepository = Services.UserRepository
            else
              broadcastToColor(errors, "Black", "Red")
            end
            
            unlockAssociativeMutex(VALIDATING_AUTH_TOKENS_MUTEX)
          end,
          function()
            for i=1, #player_auth_tokens+1 do
              if not AUTH_TOKEN_REQUEST_RESULTS[i] then return false end
            end
            return true
          end
        )
        
      end,
      function() return isAssociativeMutexUnlocked(INITIAL_FORM_VALIDATION_MUTEX) end
    )

    -- Releases CREATING_GAME_MUTEX once completed.
    -- Sets game_was_created to `true` if a game was indeed created.
    -- Modifies GAME_CREATED_RESULT
    --
    -- Gotta await another web request. The server gives us the game_id
    -- needed to join our players and listen to the game.
    local game_id = nil
    Wait.condition(
      function()
        if not auth_tokens_are_valid then
          unlockAssociativeMutex(CREATING_GAME_MUTEX)
          return
        end

        local ServerClientConnection = Services.ServerClientConnection
        local game_config_dto = {
          auto_starts_hands  = auto_start_hands,
          bot_turn_timeout   = bot_turn_timeout_ms,
          big_blind          = big_blind_cost,
          small_blind        = small_blind_cost,
          player_count       = number_of_bot_players + number_of_human_players,
          chip_denominations = {},
          starting_chips     = {}
        }
        for denomination, is_used in pairs(using_chips_denominations) do
          if is_used then
            table.insert(game_config_dto.chip_denominations, tonumber(denomination))
            game_config_dto.starting_chips[denomination] = starting_chips_for_denomination[denomination]
          end
        end

        ServerClientConnection.call("createGame", {
          auth_token      = game_master_auth_token,
          game_config_dto = game_config_dto,
          onFinish_params = {
            service  = self,
            callback = "_onCreateGameResponseReceived",
          }
        })

        Wait.condition(
          function()
            if GAME_CREATED_RESULT == nil then
              -- This shouldn't happen. The ServerClientConnection.createGame function should have 
              -- at least given an error report. Check _onCreateGameResponseReceived
              local log_message = logString("Failed to get resposne from server while creating game.", "Global._onCreateGameFromConfigButtonClicked", "[ERROR]", false, true)
              log(log_message)
            elseif GAME_CREATED_RESULT.error then
              -- If a game couldn't be created, maybe the response might help figure out why
              broadcastToColor("Failed to create game:\n["..GAME_CREATED_RESULT.response_code.."]: "..GAME_CREATED_RESULT.error, "Black", "Red")
            else
              game_id = GAME_CREATED_RESULT.data
              game_was_created = true
              broadcastToColor("Created game ["..game_id.."]", "Black", "White")
            end
            unlockAssociativeMutex(CREATING_GAME_MUTEX)
          end,
          function() return GAME_CREATED_RESULT ~= nil end
        )
      end,
      function() return isAssociativeMutexUnlocked(VALIDATING_AUTH_TOKENS_MUTEX) end
    )

    -- Releases JOINING_HUMAN_PLAYERS_MUTEX once completed.
    -- Sets all_human_players_joined to `true` if all TTS players were successfully joined to the game.
    -- Modifies PLAYERS_JOINED_RESULT
    --
    -- More web requests. Each TTS player must be joined to the game individually.
    Wait.condition(
      function()
        if not game_was_created then
          unlockAssociativeMutex(JOINING_HUMAN_PLAYERS_MUTEX)
          return
        end

        local ServerClientConnection = Services.ServerClientConnection
        local players = {table.unpack(users, 2, #users)}

        for i, user in ipairs(players) do
          ServerClientConnection.call("joinPlayerToGame", {
            index      = i,
            game_id    = game_id,
            auth_token = user.auth_token,

            onFinish_params = {
              service = self,
              callback = "_onJoinPlayerToGameResponseReceived"
            }
          })
        end

        Wait.condition(
          function()
            local errors = ""

            for result in PLAYERS_JOINED_RESULTS do
              if not result.joined then
                errors = errors.."Player #"..result.index.." failed to join. Reason: (["..result.error.response_code.."] "..result.error.text..")\n"
              end
            end

            all_human_players_joined = #errors == 0

            if not all_human_players_joined then
              broadcastToColor(errors, "Black", "Red")
            end

            unlockAssociativeMutex(JOINING_HUMAN_PLAYERS_MUTEX)
          end,
          function()
            for i=1, #player_auth_tokens do
              if not PLAYERS_JOINED_RESULTS[i] then return false end
            end
            return true
          end
        )
      end,
      function() return isAssociativeMutexUnlocked(CREATING_GAME_MUTEX) end
    )

    -- Releases PROCESSING_CREATE_GAME_MUTEX once completed.
    -- Returns control of the Game Config menu to the Game Master IF all stages weren't completed.
    Wait.condition(
      function()
        if not allConditionsFulfilled() then
          -- In the event that setup fails at any stage, the user can attempt to create a new game.
          Services.UserRepository.call("clear")
          setGameConfigWindowInteractivity(true)
          _updateGameConfigPlayerCountFields() -- This fixes player auth inputs that might have been made interactable
        else
          broadcastToAll("Game set up complete.\nClick \"Start game\" when all bots have joined.", "White")
          Global.UI.show(gameConfig_startGameButton_id)
          Global.UI.hide(gameConfig_createNewGameButton_id)
          
          GAME_MASTER_AUTH_TOKEN = game_master_auth_token
          GAME_ID               = game_id
          local ServerClientConnection = Services.ServerClientConnection
            ServerClientConnection.call("createListener", {
              game_id    = GAME_ID,
              auth_token = GAME_MASTER_AUTH_TOKEN
          })
        end

        unlockAssociativeMutex(PROCESSING_CREATE_GAME_MUTEX)
      end,
      function() return isAssociativeMutexUnlocked(JOINING_HUMAN_PLAYERS_MUTEX) end
    )
  end

  local START_GAME_RESULT
  function onStartGameFromConfigButtonClicked(player, value, id)
    Global.UI.setAttribute(gameConfig_startGameButton_id, "interactable", "False")
    local ServerClientConnection = Services.ServerClientConnection
    ServerClientConnection.call("startGame", {
      auth_token = GAME_MASTER_AUTH_TOKEN,
      game_id    = GAME_ID,

      onFinish_params = {
        service  = self,
        callback = "_onStartGameResponseReceived"
      }
    })
    
    Wait.condition(
      function()
        if not START_GAME_RESULT.game_started then
          local errors = START_GAME_RESULT.errors
          broadcastToColor("Failed to start game. ["..errors.response_code.."] "..errors.text, "Black", "Red")
          START_GAME_RESULT = nil
          Global.UI.setAttribute(gameConfig_startGameButton_id, "interactable", "True")
        else
          broadcastToAll("Starting game", "White")
          Global.UI.hide(gameConfig_window_id)
          ServerClientConnection.call("createEventListener", {
            auth_token = GAME_MASTER_AUTH_TOKEN,
            game_id    = GAME_ID
          })
        end
      end,
      function() return START_GAME_RESULT ~= nil end
    )
  end

  --[[
    params = {
      game_started = boolean,
      -- if game_started is false
      errors = {
        response_code = int,
        text          = string
      }
      
      _ = <ignore>
    }
  ]]
  function _onStartGameResponseReceived(params)
    local result = {
      game_started = params.game_started
    }
    if not result.game_started then
      result.errors = {
        response_code = params.errors.response_code,
        text          = params.errors.text
      }
    end
    START_GAME_RESULT = result
  end
  --[[
    params = {
      user = {
        user_id      = string,
        display_name = string,
        user_type    = "human"|"bot"|"game_master",
        twitch_id    = string
      },
      -- or
      error = {
        response_code = int,
        text          = string
      },


      copy_of_args = {
        index      = int,
        auth_token = string,
        _ = <ignore>
      }
    }
  ]]
  function _onGetUserByAuthTokenResponseReceived(params)
    local index  = params.copy_of_args.index
    local result = {auth_token = params.copy_of_args.auth_token}
    if params.user then
      result.user               = {}
      result.user.user_id       = params.user.user_id
      result.user.display_name  = params.user.display_name
      result.user.user_type     = params.user.user_type
    else
      result.error               = {}
      result.error.response_code = params.error.response_code
      result.error.text          = params.error.text
    end
    AUTH_TOKEN_REQUEST_RESULTS[index] = result
  end

  --[[
    params = {
      joined = true|false

      -- If `result` is false
      error  = {
        response_code = int,
        text          = string
      }

      copy_of_args = {
        index = int,
        _     = <ignore>
      }
    }
  ]]
  function _onJoinPlayerToGameResponseReceived(params)
    local index = params.copy_of_args.index
    local result = {
      index  = index,
      joined = params.joined
    }
    if not params.joined then
      result.error = {
        response_code = params.error.response_code,
        text          = params.error.text
      }
    end
    PLAYERS_JOINED_RESULTS[index] = result
  end

  --[[
    params = {
      type = "game_lobby_created",
      data = string (game ID)

      --or
      
      response_code = int,
      error         = string
    }
  ]]
  function _onCreateGameResponseReceived(params)
    local result = {}
    for k,v in pairs(params) do
      result[k] = v
    end
    GAME_CREATED_RESULT = result
  end

--[[
    END
        OF
           GAME_CONFIG_UI
]]


  --[[START Listen to existing game page]]
    function onListenToGameServerAuthEndEdit(_, value, id)
      GAME_MASTER_AUTH_TOKEN = value
    end

    function onListenToGameIdInputEndEdit(_, value, id)
      GAME_ID = value
    end

    function onListenToGameIdButtonPressed(a, b, c)
      if GAME_ID == nil then
        printToColor("Invalid Game ID provided.", "Black", "Red")
        return
      end

      printToColor("Attempting to connect to game #"..GAME_ID , "Black", "Grey")
      local params = {
        game_id = GAME_ID,
        auth_token = GAME_MASTER_AUTH_TOKEN
      }
      Services.ServerClientConnection.call("createEventListener", params)
    end
  --[[END Listen to game page]]
  
--[[
  END GAME CONFIG UI
]]

--[[
  DEALER UI

  The dealer gets an overview of information regarding the current hand.
  Any tools they need (like for starting the next hand) will be located here.
]]


--[[
  This callback just informs me the result of the call to get the deck
  order.

  web_response_result = {
    success = boolean,
    status  = int,
    body    = {
      data = {
        error      = string,
        error_code = int
      }
    } or {} if success is `true`
  }
]]
function _startNextHandResponseCallback(web_response_result)
  -- TODO: The ServerClient.startNextHand function should return 
  -- a table with information
  local log_message = logString(web_response_result, "Global._startNextHandResponseCallback", "[INFO]", false, true)
  log("\n"..log_message )
end

function onStartHandButtonPressed()
  local startNextHand_params = {
    service  = self,
    callback = "_startNextHandResponseCallback",
  }
  log("Attempting to start next hand")
  Services.ServerClientConnection.call("startNextHand", startNextHand_params)
end



function logXMLUI()
  print("frick")
  log(Global.UI.getXmlTable())
end

--[[ Util stuff I'm shoving down here until I need it elsewhere ]]

--[[
  String split

]]
function split(inputstr, sep)
  if sep == nil then
      sep = "%s" -- Default to whitespace if no separator provided
  end
  local t = {}
  -- Escape magic characters in the separator
  local safe_sep = sep:gsub("[%([%\\%.%+%-%*%?%^%$])]", "%%%1")
  local pattern = string.format("([^%s]+)", safe_sep)
  
  -- An elegant trick using gmatch to parse by separator positions
  local from = 1
  local delim_from, delim_to = string.find(inputstr, sep, from, true)
  while delim_from do
      table.insert(t, string.sub(inputstr, from, delim_from - 1))
      from = delim_to + 1
      delim_from, delim_to = string.find(inputstr, sep, from, true)
  end
  table.insert(t, string.sub(inputstr, from))
  return t
end