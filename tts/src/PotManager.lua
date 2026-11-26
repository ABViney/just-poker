local ChipManager
local PotZone
local PotStackZone
local onTurnEnd_params

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