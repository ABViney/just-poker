local ChipManager
local PotZone
local PotStackZone
local onTurnEnd_params

local LARGEST_BET_THIS_ROUND = 0
local POT_STACK = {
  ["1000"] = false,
  ["500"]  = false,
  ["100"]  = false,
  ["50"]   = false,
  ["10"]   = false
}

PLAYER_BETTED_CHIP_MAP = {
  --[[
    Makeup of this table:
    {
      ["user_id"] = {
        total_value_in_pot = int,
        bet                = int,
        
        chips = {
          ["denomination"] = {
            <Chip instance> = 1,
          },
          ...
        }
      }
      ...
    }
  ]]
  -- total_value_in_pot: int -- The total value of all chips in the pot
  -- bet: int -- The total value of chips being recognized as a bet
  -- <Chip instance>: int (1 if counted towards bet)
}

function init(params)
  ChipManager   = params.Services.ChipManager
  PlayerManager = params.Services.PlayerManager
  PotZone       = params.Zones.pot_zone
  PotStackZone  = params.Zones.pot_stack_zone

  onTurnEnd_params = {
    service  = self,
    callback = "updatePotStack",
    args     = nil
  }

  onRoundEnd_params = {
    service  = self,
    callback = "gatherBets",
    args     = nil
  }

  log("PotManager initialized")
end

do -- Config

GATHER_BETS_DELAY = 1.2

end


do -- Mutexes

local associative_mutex = {}
function lockAssociativeMutex(index) associative_mutex[index] = true end
function unlockAssociativeMutex(index) associative_mutex[index] = false end
function isAssociativeMutexUnlocked(index) return not associative_mutex[index] end

end

function setPotFromState(table)
  ChipManager.call("initializePot", table.pot)
  CurrentBet = table.current_round.bet
end



-- Determines if an object is a poker chip that we manage.
function isChip(object)
  return string.find(object.type, "Chip") and object.memo
end

function isBettedChip(object)
  return object ~= nil and object.memo ~= "Pot" and isChip(object) and string.find(object.memo, "(Bet)")
end

--[[
  player = <Player>,
--]]
function getBettedChipsForPlayer(player)
  return PLAYER_BETTED_CHIP_MAP[player.user_id].chips
end

-- From all the chips on the table, get references to those that are part of the pot.
function updatePotStack()
  POT_STACK = {
    ["1000"] = {},
    ["500"]  = {},
    ["100"]  = {},
    ["50"]   = {},
    ["10"]   = {}
  }
  for object in getObjects() do
    if isChip(object) and object.memo == "Pot" then
      table.insert(POT_STACK[tostring(object.getValue())], object)
    end
  end
end

--[[
  Groups the pot in the middle and updates the references to its stacks.
]]
function updatePotStack()
  local pot_stack = {
    ["1000"] = {},
    ["500"]  = {},
    ["100"]  = {},
    ["50"]   = {},
    ["10"]   = {}
  }
  for object in getObjects() do
    if isChip(object) and object.memo == "Pot" then
      local denomination = tostring(object.getValue())
      table.insert(pot_stack[denomination], object)
    end
  end

  local offset = ChipManager.getVar("CHIP_DENOMINATION_RELATIVE_POSITION")
  for denomination, stacks in pairs(pot_stack) do
    if #stacks == 0 then pot_stack[denomination] = false
    elseif #stacks == 1 then
      pot_stack[denomination] = stacks[1]
      pot_stack[denomination].setPosition(PotStackZone.positionToWorld(offset[denomination]))
    elseif #stacks >= 2 then
      pot_stack[denomination] = group(stacks)[1]
      pot_stack[denomination].setPosition(PotStackZone.positionToWorld(offset[denomination]))
    end
  end

  POT_STACK = pot_stack
end

--[[
  payoutChips_params = {
    player_id = string,
    chips     = {
      "1000" = int,
      "500"  = int,
      "100"  = int,
      "50"   = int,
      "10"   = int,
    },

    onFinish_params = {
      service = <Scripting Zone>
      callback = string,
      args = any
    }
  }  
]]
function animatePayout(payoutChips_params)
  local player = PlayerManager.call("getPlayerById", payoutChips_params.player_id)
  if not player then
    log("Could not find player with this ID: " .. payoutChips_params.player_id, "PotManager.animatePayout", "[ERROR]", false, true)
    return
  end

  local chips           = payoutChips_params.chips
  local onFinish_params = payoutChips_params.onFinish_params

  -- Broadcasting who won and how much
  local sum = 0
  for denomination, count in pairs(chips) do
    sum = sum + (denomination * count)
  end

  broadcastToAll(player.display_name.." wins $"..tostring(sum), "White")

  local moveChipsBetweenStacks_params = {
    owner                = payoutChips_params.player_id,
    giving_stack_type    = "pot",
    receiving_stack_type = "stack",
    chips_to_move        = chips,
    onFinish_params      = onFinish_params
  }
  ChipManager.call("moveChipsBetweenStacks", moveChipsBetweenStacks_params)
end

--[[
  This is a reference to the chips being processed during a payout. If its nil, there's not a payout
  happening. If it isn't nil, a payout is happening.

  Keeping this reference allows me to track the "creation" and "destruction" of chips during payout
  (such as when all but one chip is taken out of a stack, and when a chip is added to another player's
  stack.
]]
local pot_chips

function onObjectSpawn(object)
  if pot_chips and object.memo and object.memo == "Pot" then
    pot_chips[tostring(object.getValue())][object] = true
  end
end
function onObjectDestroy(object)
  if pot_chips and pot_chips[object] and object.memo and object.memo == "Pot" then
    pot_chips[tostring(object.getValue())][object] = nil
  end
end

--[[
  This handles tracking the value of all the chips a specific player has
  put into the pot.
]]
function adjustCurrentBetValueForId(player_id)
  PLAYER_BETTED_CHIP_MAP[player_id].bet = 0
  for _, chips in pairs(PLAYER_BETTED_CHIP_MAP[player_id].chips) do
    for chip, _ in pairs(chips) do
      local chip_value = chip.getValue() * math.abs(chip.getQuantity())
      PLAYER_BETTED_CHIP_MAP[player_id].bet = PLAYER_BETTED_CHIP_MAP[player_id].bet + chip_value
    end
  end
end

function initializeChipsMapForPlayerId(player_id)
  if not PLAYER_BETTED_CHIP_MAP[player_id] then PLAYER_BETTED_CHIP_MAP[player_id] = {} else return end
  if not PLAYER_BETTED_CHIP_MAP[player_id].bet then PLAYER_BETTED_CHIP_MAP[player_id].bet = 0 end
  if not PLAYER_BETTED_CHIP_MAP[player_id].total_value_in_pot then PLAYER_BETTED_CHIP_MAP[player_id].total_value_in_pot = 0 end
  if not PLAYER_BETTED_CHIP_MAP[player_id].chips then PLAYER_BETTED_CHIP_MAP[player_id].chips = {["1000"] = {}, ["500"] = {}, ["100"] = {}, ["50"] = {}, ["10"] = {}} end
end

-- These handle chips going in/out of the zone.
function onObjectEnterScriptingZone(zone, object)
  if zone ~= PotZone then return end
  if not isChip(object) then return end
  if object.memo == "Pot" then return end
  if not PLAYER_BETTED_CHIP_MAP[object.memo] then return end
  PLAYER_BETTED_CHIP_MAP[object.memo].chips[tostring(object.getValue())][object] = 0
  -- log("Userid " .. object.memo .. " has added $" .. object.getValue()*math.abs(object.getQuantity()) .. " to their bet")
  adjustCurrentBetValueForId(object.memo)
end
function onObjectLeaveScriptingZone(zone, object)
  if zone ~= PotZone then return end
  if not isChip(object) then return end
  if object.memo == "Pot" then return end
  if not PLAYER_BETTED_CHIP_MAP[object.memo] then return end
  PLAYER_BETTED_CHIP_MAP[object.memo].chips[tostring(object.getValue())][object] = nil
  -- log("Userid " .. object.memo .. " has added -$" .. object.getValue()*math.abs(object.getQuantity()) .. " to their bet")
  adjustCurrentBetValueForId(object.memo)
end

-- These handle chips being added/removed from a stack
function onObjectEnterContainer(container, enter_object)
  if not PLAYER_BETTED_CHIP_MAP[container.memo] then return end
  if isBettedChip(container) or isBettedChip(enter_object) then
    if enter_object.memo == "Pot" then return end
    PLAYER_BETTED_CHIP_MAP[container.memo].chips[tostring(container.getValue())][enter_object] = nil
    adjustCurrentBetValueForId(container.memo)
  end
  -- log("Userid " .. enter_object.memo .. " has added $" .. enter_object.getValue()*math.abs(enter_object.getQuantity()) .. " to an existing stack now equaling $" .. container.getValue()*math.abs(container.getQuantity()))
end
function onObjectLeaveContainer(container, leave_object)
  if not PLAYER_BETTED_CHIP_MAP[container.memo] then return end
  if isBettedChip(container) or isBettedChip(leave_object) then
    if leave_object.memo == "Pot" then return end
    adjustCurrentBetValueForId(container.memo)
  end
-- log("Userid " .. leave_object.memo .. " has removed -$" .. leave_object.getValue()*math.abs(leave_object.getQuantity()) .. " from an existing stack now equaling $" .. container.getValue()*math.abs(container.getQuantity()))
end