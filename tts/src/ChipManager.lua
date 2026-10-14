local PlayerManager
local PotManager

local Zones
local BotChipExchangeStackZone
local ChipExchangeStackZone
local PotStackZone

local ChipStackId = {
  Stack    = " (Stack)",
  Bet      = " (Bet)",
  Exchange = " (Exchange)",
  Pot      = " (Pot)"
}

CHIP_DENOMINATION_RELATIVE_POSITION = {
  ["1000"] =  {x=0,    y=0.5, z=-0.75},
  ["500"]  =  {x=1.75, y=0.5, z=-0.75},
  ["100"]  =  {x=3.5,  y=0.5, z=-0.75},
  ["50"]   =  {x=1,    y=0.5, z= 0.75},
  ["10"]   =  {x=2.85, y=0.5, z= 0.75}
}

function init(params)
  PlayerManager = params.Services.PlayerManager
  PotManager = params.Services.PotManager

  Zones = params.Zones
  BotChipExchangeStackZone = params.Zones.bot_chip_exchange_stack_zone
  ChipExchangeStackZone    = params.Zones.chip_exchange_stack_zone
  PotStackZone             = params.Zones.pot_stack_zone
  log("ChipManager initialized")
end

do -- Config

CHIP_TRANSFER_DELAY = 1.25

end

do -- Mutex

local associative_mutex = {}
function lockAssociativeMutex(index) associative_mutex[index] = true end
function unlockAssociativeMutex(index) associative_mutex[index] = false end
function isAssociativeMutexUnlocked(index) return not associative_mutex[index] end

end

--[[
  Generates a table for the name and memo to be assigned to chips based on who owns
  them and where they will be.

]]
function generateChipData(player, stack_type)
  if string.lower(stack_type) == "pot" then
    return { name = "- (Pot)", memo = ChipStackId.Pot }
  end
  
  if player == nil then
    -- Concatenating nil in the next branch will throw an error making issues here obvious
    log("\"player\" field is nil", "ChipManager.generateChipData", "[ERROR]", false, true)
  end

function assignChipsToPot(chips)
  chips.setName("- Pot")
  chips.memo = "Pot"
end



function getAllBetChips()
  local betted_chips = {}
  for object in getObjects() do
    if string.find(object.type, "Chip") and string.find(object.memo, "(Bet)") then
      table.insert(betted_chips, object)
    end
  end
  return betted_chips
end

--[[
  Handles exchanging chips between two stacks.
  Returns the number of chips moved.

  transferChips_params = {
    chips_to_transfer = <Chip>|<ChipStack>,
    destination       = Vector3|<Chip>|<ChipStack>,
    count             = int,
    new_name          = string|nil,
    new_memo          = string|nil,
    onFinish_params   = {
      service  = <Scripting Zone>,
      callback = string,
      args     = any
    }
  }
]]
function transferChips(transferChips_params)
  local chips_to_transfer = transferChips_params.chips_to_transfer
  local destination       = transferChips_params.destination
  local count             = transferChips_params.count
  local new_name          = transferChips_params.new_name
  local new_memo          = transferChips_params.new_memo
  local onFinish_params   = transferChips_params.onFinish_params

  local number_of_chips_moved = 0
  -- If the destination is a chip, we will move the chips to just above it
  if destination.type then
    local destination_height = math.abs(destination.getQuantity())*0.2 + 1
    destination = destination.getPosition()
    destination.y = destination_height
  end

  local stack_quantity = math.abs(chips_to_transfer.getQuantity())
  if count == 1 then
    if stack_quantity == 1 then
      -- Perfect. Have the right amount. Update its meta data and move it.
      updateChipMetaData(chips_to_transfer, new_name, new_memo)
      chips_to_transfer.setPositionSmooth(destination, false, true)
    else
      -- I just need one chip from the stack.
      -- callback is called when the object finishes moving. It may be colliding
      -- with the destination before it has time to update.
      local above_destination = chips_to_transfer.getPosition()
      above_destination.y = above_destination.y + 0.2*math.abs(chips_to_transfer.getQuantity())
      chips_to_transfer.takeObject({
        position = above_destination,
        top      = true,
        smooth   = true,
        callback_function = function(chip)
          updateChipMetaData(chip, new_name, new_memo)
          chip.setPositionSmooth(destination, false, true)
        end
      })
    end
    -- counts[index] = 0
    number_of_chips_moved = count
  elseif stack_quantity-2 >= count then
    -- If the quantity is greater than the count+2 then we can use
    -- the cut method to split the stack to our needed size
    -- The [1] index is the remainder (quantity of 2 or more)
    -- The [2] index is a stack of `count` quantity
    local stacks = chips_to_transfer.cut(count)
    updateChipMetaData(stacks[2], new_name, new_memo)
    stacks[2].setPositionSmooth(destination, false, true)
    -- counts[index] = 0 -- We moved exactly as many chips as needed
    number_of_chips_moved = count
  elseif stack_quantity-1 == count then
    -- If the quantity is only greater than the count by 1 then we have
    -- to do more work to split the stack manually using takeObject
    local current_position_of_chips_to_transfer = chips_to_transfer.getPosition()
    chips_to_transfer.takeObject({
      position = current_position_of_chips_to_transfer,
      smooth   = false
    })
    updateChipMetaData(chips_to_transfer, new_name, new_memo)
    chips_to_transfer.setPositionSmooth(destination, false, true)
    -- counts[index] = 0 -- We moved exactly as many chips as needed
    number_of_chips_moved = count
  elseif stack_quantity <= count then
    -- If the quantity is exactly the same as or less than count, (excluding
    -- the case for count-1 above) we can just move the entire stack
    updateChipMetaData(chips_to_transfer, new_name, new_memo)
    chips_to_transfer.setPositionSmooth(destination, false, true)
    -- counts[index] = counts[index] - stack_quantity
    number_of_chips_moved = stack_quantity
  end

  Wait.time(
    function()
      onFinish_params.service.call(onFinish_params.callback, onFinish_params.args)
    end,
    CHIP_TRANSFER_DELAY
  )

  return number_of_chips_moved
end

--[[
  Gets the position of a chip of a specific denomination for a player.
  If the player does not have any of this chip type, it returns where
  the chip would otherwise go.

  data = {
    player_id    = string,
    player       = <Player>,
    denomination = string
  }
]]
function getPositionOfChipsForPlayer(data)
  local player = data.player
  if data.player_id then player = PlayerManager.call("getPlayerById", data.player_id) end
  local chip_reference = nil
  if player.stack and player.stack[data.denomination] then
    for chip, _ in player.stack[data.denomination] do
      if not chip == nil then
        chip_reference = chip
        break
      end
    end
  end
  if chip_reference then return chip_reference end
  return player.zones.stack_zone.positionToWorld(CHIP_DENOMINATION_RELATIVE_POSITION[data.denomination])
end

function getPositionOfChipsForPot(denomination)
  return Zones.pot_stack_zone.positionToWorld(CHIP_DENOMINATION_RELATIVE_POSITION[denomination])
end

function initializePot(pot)
  local chip_data = generateChipData(nil, "pot")
  local spawnChips_params = {
    name = chip_data.name,
    memo = chip_data.memo,
    rotation = {0, 180, 0},
  }
  for denomination, count in pairs(pot or {}) do
    chip_data.type = "Chip_"..denomination
    -- chip_data.position = Zones.pot_stack_zone.positionToWorld(ChipDenominationRelativePosition[denomination])
    chip_data.count = count
    local chip_stack = spawnChips(spawnChips_params)
    if chip_stack ~= nil then
      chip_stack.setPosition(Zones.pot_stack_zone.positionToWorld(CHIP_DENOMINATION_RELATIVE_POSITION[denomination]))
    end
  end
end

--[[
    
--]]
function initializeChipsForPlayer(player)
  log("Initializing chips for " .. player.display_name)
  local stack_chip_data = generateChipData(player, "stack")
  stack_chip_data.rotation = player.zones.hand_zone.getRotation()
  local bet_chip_data   = generateChipData(player, "bet")
  bet_chip_data.rotation = player.zones.hand_zone.getRotation()

  local player_stack = {
    ["1000"] = {},
    ["500"]  = {},
    ["100"]  = {},
    ["50"]   = {},
    ["10"]   = {}
  }
  local player_current_bet = {
    ["1000"] = {},
    ["500"]  = {},
    ["100"]  = {},
    ["50"]   = {},
    ["10"]   = {}
  }

  for denomination, count in pairs(player.stack) do
    stack_chip_data.type = "Chip_"..denomination
    -- Placement of chips will be offset from the "stack zone" each player has
    stack_chip_data.position = player.zones.stack_zone.positionToWorld(CHIP_DENOMINATION_RELATIVE_POSITION[denomination])
    stack_chip_data.count = count
    local chip_stack = spawnChips(stack_chip_data)
    if chip_stack then
      table.insert(player_stack[denomination], chip_stack)
    end
  end
  for denomination, count in pairs(player.current_bet or {}) do
    bet_chip_data.type = "Chip_"..denomination
    -- Placement of chips will be offset from the "stack zone" each player has
    bet_chip_data.position = player.zones.bet_zone.positionToWorld(CHIP_DENOMINATION_RELATIVE_POSITION[denomination])
    bet_chip_data.count = count
    local chip_stack = spawnChips(bet_chip_data)
    if chip_stack then
      table.insert(player_current_bet[denomination], chip_stack)
    end
  end

  local player_chips = {stack = player_stack, current_bet = player_current_bet}
  return player_chips
end

--[[
  Spawns in chips and groups them. Returns a reference to the stack.
  chip_data = {
    type = "Chip_10|Chip_50|Chip_100|Chip_500|Chip_1000",

    -- Prevents non-matching chips from stacking
    public_owner = string,
    name = string,
    memo = string,
    position = {x: float, y: float, z: float},
    rotation = {x: float, y: float, z: float},
    count = int
  }
--]]
function spawnChips(chip_data)
  if not chip_data.count then chip_data.count = 0 end
  if not chip_data.position then
    chip_data.position = {x=0, y=0, z=0}
  end
  local chips = {}
  for i=1, chip_data.count do
    local chip = spawnObject({
      type = chip_data.type,
      position = {chip_data.position.x, chip_data.position.y+i*0.1, chip_data.position.z},
      rotation = chip_data.rotation,
      scale = {1, 1, 1},
      sound = false,
    })
    chip.setName(chip_data.name)
    chip.memo = chip_data.memo

    table.insert(chips, chip)
  end
  
  if chip_data.count == 0 then return nil end
  if #chips == 1 then return chips[1] end

  -- Using putObject:
  -- I get my expected stack of 5, but I get 3 extra that fall
  -- through the table until they reset above the first stack
  local chip_stack = chips[1].putObject(chips[2])
  for i=3, #chips do
    chip_stack.putObject(chips[i])
  end
  return chip_stack

  -- Trying to group:
  -- I get a stack of 8 in the middle of the table, and 3 that fall
  -- through the table until they reset above the first stack
  -- return group(chips)
end

function updateChipMetaData(chip_reference, name, memo)
  chip_reference.setName(name)
  chip_reference.memo = memo
--[[
  Moves chips between two stacks (stack/bet, stack/exchange, bet/pot, etc.)
  Handles positioning and modifying metadata for the chips.

  The "stack_type" describes which chips are being moved, and what they become after being moved.
  I.e. if giving_stack_type is "stack" and receiving_stack_type is "bet", then the function finds
  the chips specified in chips_to_move from the player's stack and moves them to their bet.
  This handles renaming and modifying metadata so chips always have an owner.

  params = {
    owner                    = <Player>|string,
    giving_stack_type        = "stack"|"bet"|"exchange"|"pot",
    receiving_stack_type     = "stack"|"bet"|"exchange"|"pot",
    chips_to_move            = {
      [denomination] = int,
      ...
    }
    
    onFinish_params = {
      service  = <Scripting Zone>,
      callback = string (func name),
      args     = any
    }
  }
]]
function moveChipsBetweenStacks(params)
  local owner
  if type(params.owner) == "string" then
    owner = PlayerManager.call("getPlayerById", params.owner)
    if not owner then
      local msg = logString("Player "..params.owner.." not found.", "ChipManager.moveChipsBetweenStacks", "[ERROR]", false, true)
      log(msg)
      return
    end
  else
    owner = params.owner
  end

  local giving_stack_type        = params.giving_stack_type
  local receiving_stack_type     = params.receiving_stack_type
  local onFinish_params          = params.onFinish_params

  if not type(params.chips_to_move) == "table" then
    log("Invalid [chips_to_transfer] parameter provided", "ChipManager.moveChipsBetweenStacks", "[ERROR]", false, true)
    return
  end

  -- Each movement can be done 
  local promises      = {}
  local denominations = {}
  local counts        = {}
  for denomination, count in pairs(params.chips_to_move) do
    if count > 0 then
      table.insert(denominations, denomination)
      table.insert(counts, count)
      table.insert(promises, false)
    end
  end

  -- Once all denominations have been moved, this returns true
  function _promisesFulfilled()
    for promise_fulfilled in promises do if not promise_fulfilled then return false end end
    return true
  end

  if _promisesFulfilled() then
    -- Empty move data. Whatever.
    onFinish_params.service.call(onFinish_params.callback, onFinish_params.args)
    return
  end
  
  local givable_chip_data = generateChipData(owner, giving_stack_type)
  local givable_chips = getChipsByMemo(givable_chip_data.memo)
  
  local receivable_chip_data = generateChipData(owner, receiving_stack_type)
  local receivable_chips = getChipsByMemo(receivable_chip_data.memo)
  
  local chip_offsets = CHIP_DENOMINATION_RELATIVE_POSITION

  function _getChipToMoveForDenomination(denomination)
    if not givable_chips[denomination] then
      log(giving_stack_type.." has no valid reference of a $"..denomination.." chip that can be referenced", "ChipManager.moveChipsBetweenStacks", "ChipManager.moveChipsBetweenStacks", "[ERROR]", false, true)
      return
    end
    for chip_reference in givable_chips[denomination] do
      if chip_reference then
        return chip_reference
      end
    end
  end

  -- TODO: Adjust exchange zone to a position for bots
  local receiving_stack_zone = nil
  if string.lower(receiving_stack_type) == "stack" then
    receiving_stack_zone = owner.zones.stack_zone
  elseif string.lower(receiving_stack_type) == "bet" then
    receiving_stack_zone = owner.zones.bet_zone
  elseif string.lower(receiving_stack_type) == "exchange" then
    if owner.user_type == "bot" then
      receiving_stack_zone = BotChipExchangeStackZone
    else
      receiving_stack_zone = ChipExchangeStackZone
    end
  elseif string.lower(receiving_stack_type) == "pot" then
    receiving_stack_zone = PotStackZone
  end

  function _getDestinationForDenomination(denomination)
    if receivable_chips[denomination] then
      for chip_reference in receivable_chips[denomination] do
        if chip_reference then
          return chip_reference
        end
      end
    end
    if type(receiving_stack_zone) == "userdata" then
      return receiving_stack_zone.positionToWorld(chip_offsets[denomination])
    elseif type(receiving_stack_zone) == "table" then
      return {
        x = receiving_stack_zone.x + chip_offsets[denomination].x,
        y = receiving_stack_zone.y + chip_offsets[denomination].y,
        z = receiving_stack_zone.z + chip_offsets[denomination].z
      }
    end
  end

  function _moveChipsForPromise(index)
    local denomination = denominations[index]
    local count        = counts[index]

    -- Early return if there's no chips left to move
    if count == 0 then
      promises[index] = true
      return
    end

    -- Get the chips being moved
    local chip_reference = _getChipToMoveForDenomination(denomination)
    -- Where the chips will move to
    local destination    = _getDestinationForDenomination(denomination)

    if not chip_reference then
      log("Could not find $"..denomination.." chips to move for "..giving_stack_type, "ChipManager.moveChipsBetweenStacks", "[ERROR]", false, true)
      return
    end

    local transferChips_params = {
      chips_to_transfer = chip_reference,
      destination       = destination,
      count             = count,
      new_name          = receivable_chip_data.name,
      new_memo          = receivable_chip_data.memo,
      onFinish_params   = {
        service  = self,
        callback = "unlockAssociativeMutex",
        args     = denomination
      }
    }
    lockAssociativeMutex(denomination)
    local number_of_chips_moved = transferChips(transferChips_params)
    counts[index] = count - number_of_chips_moved

    Wait.condition(
      function()
        givable_chips    = getChipsByMemo(givable_chip_data.memo)
        receivable_chips = getChipsByMemo(receivable_chip_data.memo)
        _moveChipsForPromise(index)
      end,
      function() return isAssociativeMutexUnlocked(denomination) end
    )
  end
  
  for i = 1, #promises do
    _moveChipsForPromise(i)
  end

  Wait.condition(
    function()
      onFinish_params.service.call(onFinish_params.callback, onFinish_params.args)
    end,
    _promisesFulfilled
  )
end

--[[
  params = {
    owner                      = <Player>,
    chips_to_exchange          = {
      give    = { [denomination] = int, ... },
      receive = { [denomination] = int, ... }
    }

    onFinish_params = {
      service  = <Scripting Zone>,
      callback = string (func name),
      args     = any
    }l
  }
]]
function exchangeChips(params)
  -- These indexes can be arbitrary, just used for controlling flow
  local giving_chips_mutex_index     = "exchangeChips -- moving the give chips"
  local exchanging_chips_mutex_index = "exchangeChips -- deleting the given chips and spawning the receive chips"
  local receiving_chips_mutex_index  = "exchangeChips -- moving the receive chips"

  -- The first move is give->receive, the second move is receive->give.
  local giving_stack_type    = "stack"
  local receiving_stack_type = "exchange"

  -- Unpacked params
  local owner           = params.owner
  local give_chips      = params.chips_to_exchange.give
  local receive_chips   = params.chips_to_exchange.receive
  local onFinish_params = params.onFinish_params

  --[[
    The exchange process for bots is broken into 4 steps that allow each
    process to be encapsulated thanks to execution control flow:
      1. Move the given chips
      2. Delete the given chips and spawn in the received chips
      3. Move the received chips
      4. Invoke the onFinish callback  
  ]] 
  lockAssociativeMutex(giving_chips_mutex_index)
  lockAssociativeMutex(exchanging_chips_mutex_index)
  lockAssociativeMutex(receiving_chips_mutex_index)

  -- Step 1: Move given chips
  -- The first thing to happen is moving the chips being exchanged to their
  -- designated zone
  local give_moveChipsBetweenStacks_params = {
    owner = owner,
    giving_stack_type = giving_stack_type,
    receiving_stack_type = receiving_stack_type,
    chips_to_move = give_chips,

    onFinish_params = {
      service  = self,
      callback = "unlockAssociativeMutex",
      args     = giving_chips_mutex_index
    }
  }
  moveChipsBetweenStacks(give_moveChipsBetweenStacks_params)

  
  -- Step 2: Delete given chips and spawn in the received chips
  -- This list will contain all the information for the chips we need to create
  local exchange_chip_data = generateChipData(owner, receiving_stack_type)
  local spawnChips_params_list = generateSpawnChipsParameters({
    name        = exchange_chip_data.name,
    memo        = exchange_chip_data.memo,
    origin_zone = BotChipExchangeStackZone,
    chips       = receive_chips
  })
  Wait.condition(
    function()
      -- The given chips are deleted and the received chips are spawned
      local given_chips = getChipsByMemo(exchange_chip_data.memo)
      for _, chip_references in pairs(given_chips) do
        for chip_reference in chip_references do
          if chip_reference then chip_reference.destruct() end
        end
      end
      for spawnChips_params in spawnChips_params_list do
        spawnChips(spawnChips_params)
      end

      -- Need to wait at least 1 frame for the game to fully destruct the given chips
      -- Once that guarantee is realized we can mark spawning chips as complete
      Wait.frames(
        function()
          unlockAssociativeMutex(exchanging_chips_mutex_index)
        end,
        1
      )
    end,
    function() return isAssociativeMutexUnlocked(giving_chips_mutex_index) end
  )

  -- Step 3: Move the received chips
  -- Once the exchange has happened, the received chips are moved to the bot's stack
  local receive_moveChipsBetweenStacks_params = {
    owner                = owner,
    giving_stack_type    = receiving_stack_type,
    receiving_stack_type = giving_stack_type,
    chips_to_move        = receive_chips,

    onFinish_params      = {
      service  = self,
      callback = "unlockAssociativeMutex",
      args     = receiving_chips_mutex_index
    }
  }
  Wait.condition(
    function()
      
      -- There's an issue where, when chips are stacked, the reference for one of the
      -- chips that is destroyed when the stack is formed lingers. I don't know if ther
      -- is a specified time/frame i should wait, but around 0.75 seconds seems to be
      -- enough time on my system for it to figure itself out.
      Wait.time(
        function() moveChipsBetweenStacks(receive_moveChipsBetweenStacks_params) end,
        0.75
      )
    end,
    function() return isAssociativeMutexUnlocked(exchanging_chips_mutex_index) end
  )

  -- Step 4: Invoke the onFinish callback
  -- Everything is done. All that's left is to give control back to the caller.
  Wait.condition(
    function()
      onFinish_params.service.call(onFinish_params.callback, onFinish_params.args)
    end,
    function() return isAssociativeMutexUnlocked(receiving_chips_mutex_index) end
  )
end

function getChipsByMemo(memo)
  local chips = {}
  for object in getObjects() do
    if PotManager.call("isChip", object) and object.memo == memo then
      local denomination = tostring(object.getValue())
      if not chips[denomination] then
        chips[denomination] = {}
      end
      table.insert(chips[denomination], object)
    end
  end
  return chips
end

function getBettedChips()
  local chips = {}
  for object in getObjects() do
    if PotManager.call("isChip", object) and string.sub(object.memo, -#ChipStackId.Bet) == ChipStackId.Bet then
      table.insert(chips, object)
    end
  end
  return chips
end

function moveBetsToPot(onFinish_params)
  -- Completion of this function determined is when all players with active bets have had their bets collected
  local mutex_indices = {}
  function _allMutexesReleased()
    for mutex_index in mutex_indices do
      if not isAssociativeMutexUnlocked(mutex_index) then return false end
    end
    return true
  end

  -- All players in/out are checked. Out players won't have a bet, but if they did, it's collected.
  local players = PlayerManager.call("getPlayers")

  -- Execution of a player's bets being collected occurs after the previous player's bet has been collected.
  -- This allows chips to be moved quickly without having to manage collapsing multiple references into one.
  local previous_mutex_index = nil
  for player in players do
    -- This index can be arbitrary
    local mutex_index = player.user_id.." collecting bet"

    -- If the player doesn't have any chips betted then they will be skipped.
    local player_has_betted_chips = false
    -- The data we get from the getChipsByMemo is { [denomination] = {Object, ...} } which 
    -- needs to be mapped to { [denomination] = int }
    local chips_to_move = {}
    local betted_chips = getChipsByMemo( generateChipData(player, "bet").memo )
    for denomination, chip_references in pairs(betted_chips) do
      chips_to_move[denomination] = 0
      for chip_reference in chip_references do
        chips_to_move[denomination] = chips_to_move[denomination] + math.abs(chip_reference.getQuantity())
        player_has_betted_chips = true
      end
    end

    if player_has_betted_chips then
      -- Since this loop executes synchronously we can ensure each coroutine will execute only when
      -- the previous coroutine has finished
      lockAssociativeMutex(mutex_index)
      table.insert(mutex_indices, mutex_index)
      local locally_scoped_previous_mutex_index = previous_mutex_index -- need a locally scoped variable for a later comparison
      previous_mutex_index = mutex_index

      Wait.condition(
        function()
          moveChipsBetweenStacks({
            owner = player.user_id,
            giving_stack_type = "bet",
            receiving_stack_type = "pot",
            chips_to_move = chips_to_move,
            onFinish_params = {
              service = self,
              callback = "unlockAssociativeMutex",
              args = mutex_index
            }
          })
        end,
        function()
          -- If there is no previous mutex index assigned then this is the first coroutine to run
          if locally_scoped_previous_mutex_index == nil then return true end
          -- Once the previous mutex index is released then it is this coroutine's turn
          if not isAssociativeMutexUnlocked(locally_scoped_previous_mutex_index) then return false end
          return true
        end
      )
    end
  end

  Wait.condition(
    function() onFinish_params.service.call(onFinish_params.callback, onFinish_params.args) end,
    _allMutexesReleased
  )
end