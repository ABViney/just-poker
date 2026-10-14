local PlayerManager
local PotManager

local Zones
local BotChipExchangeStackZone

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
  PotStackZone             = params.Zones.pot_stack_zone
  log("ChipManager initialized")
end

do -- Config

CHIP_TRANSFER_DELAY = 1.25

end

--[[
  Takes a chip or chip stack and assigns it to a player.

  data = {
    player_id    = string,
    player       = <Player>,
    chips        = <Chip>|<ChipStack>
  }
]]
function assignChipsToPlayer(data)
  local player = data.player
  if data.player_id then player = PlayerManager.call("getPlayerById", data.player_id) end
  data.chips.setName("- " .. player.display_name)
  data.chips.memo = player.user_id
  PlayerManager.call("addChipToStack", data.chips)
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
      log(onFinish_params)
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
  local chip_data = {
    public_owner = "Pot",
    rotation = {0, 180, 0},
    memo = "Pot"
  }
  for denomination, count in pairs(pot or {}) do
    chip_data.type = "Chip_"..denomination
    -- chip_data.position = Zones.pot_stack_zone.positionToWorld(ChipDenominationRelativePosition[denomination])
    chip_data.count = count
    local chip_stack = spawnChips(chip_data)
    chip_stack.setPosition(Zones.pot_stack_zone.positionToWorld(CHIP_DENOMINATION_RELATIVE_POSITION[denomination]))
  end
end

--[[
    
--]]
function initializeChipsForPlayer(player)
  log("Initializing chips for " .. player.display_name)

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

  local chip_data = {
    public_owner = player.display_name,
    rotation = player.zones.hand_zone.getRotation(),
    memo = player.user_id
  }
  for denomination, count in pairs(player.stack) do
    chip_data.type = "Chip_"..denomination
    -- Placement of chips will be offset from the "stack zone" each player has
    chip_data.position = player.zones.stack_zone.positionToWorld(CHIP_DENOMINATION_RELATIVE_POSITION[denomination])
    chip_data.count = count
    local chip_stack = spawnChips(chip_data)
    if chip_stack then
      table.insert(player_stack[denomination], chip_stack)
    end
  end
  for denomination, count in pairs(player.current_bet or {}) do
    chip_data.type = "Chip_"..denomination
    -- Placement of chips will be offset from the "stack zone" each player has
    chip_data.position = player.zones.bet_zone.positionToWorld(CHIP_DENOMINATION_RELATIVE_POSITION[denomination])
    chip_data.count = count
    local chip_stack = spawnChips(chip_data)
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
    position = {x: float, y: float, z: float},
    rotation = {x: float, y: float, z: float},
    memo = string
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
    chip.setName("- " .. chip_data.public_owner)
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
end