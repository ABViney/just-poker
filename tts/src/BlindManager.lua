local PlayerZones

local BigBlind
BigBlindPosition = 0

local SmallBlind
SmallBlindPosition = 0

local DealerButton
DealerBlindPosition = 0

function init(params)
  PlayerManager = params.Services.PlayerManager

  PlayerZones = params.Zones.PlayerZones
  
  BigBlind     = params.Objects.big_blind
  SmallBlind   = params.Objects.small_blind
  DealerButton = params.Objects.dealer_button
  log("BlindManager initialized")
end

--[[
    Set the blinds based on the current_hand field of the table

    "current_hand": {
      "id": string,
      "count": int,
      "button": int,
      "big_blind": int,
      "small_blind": int,
      "started_at": string
    }
--]]
function configureBlindsFromCurrentHand(current_hand)
  -- Todo: Move blinds to position based on Button
  DealerButton.setName("Dealer")
  BigBlind.setName("$" .. current_hand.big_blind)
  BigBlind.memo = current_hand.big_blind
  SmallBlind.setName("$" .. current_hand.small_blind)
  SmallBlind.memo = current_hand.small_blind
end

function configureButtonsFromTable(table)
  configureBlindsFromCurrentHand(table.current_hand)

  giveDealerButtonTo(PlayerManager.call("getPlayerByPosition", table.button_position))
  DealerButtonPosition = table.button_position

  giveSmallBlindTo(PlayerManager.call("getPlayerByPosition", table.small_blind_position))
  SmallBlindPosition = table.small_blind_position

  giveBigBlindTo(PlayerManager.call("getPlayerByPosition", table.big_blind_position))
  BigBlindPosition = table.big_blind_position
end

--[[
  Configure the blinds from parsed data.
--]]
function configureButtonsFromHandStart(data)
  log("Configuring buttons")
  BigBlind.setName("$" .. data.big_blind_cost)
  BigBlind.memo = data.big_blind_cost
  SmallBlind.setName("$" .. data.small_blind_cost)
  SmallBlind.memo = data.small_blind_cost

  giveDealerButtonTo(PlayerManager.call("getPlayerByPosition", data.button_position))
  DealerButtonPosition = data.button_position

  giveSmallBlindTo(PlayerManager.call("getPlayerByPosition", data.small_blind_position))
  SmallBlindPosition = data.small_blind_position

  giveBigBlindTo(PlayerManager.call("getPlayerByPosition", data.big_blind_position))
  BigBlindPosition = data.big_blind_position
end

-- TODO: Getting an error on initialization over trying to index a nil value.
-- Non-breaking. Button still ends up in the right place, just makes an ugly error message.
function giveDealerButtonTo(player)
  local position = player.zones.blind_zone.getPosition()
  local rotation = player.zones.blind_zone.getRotation()
  rotation.y = rotation.y + 90
  DealerButton.setRotationSmooth(rotation, false, true)
  DealerButton.setPositionSmooth(position, false, false)
  DealerButton.setLock(false)
end

--[[
    Set the Small blind to the blind position for that seat
    
    color: Red|Orange|Yellow|Green|Teal|Blue|Purple|Pink
--]]
function giveSmallBlindTo(player)
  local position = player.zones.blind_zone.getPosition()
  local rotation = player.zones.blind_zone.getRotation()
  rotation.y = rotation.y + 90
  SmallBlind.setRotationSmooth(rotation, false, true)
  SmallBlind.setPositionSmooth(position, false, false)
  SmallBlind.setLock(false)
end

--[[
    Set the Big blind to the blind position for that seat
    
    color: Red|Orange|Yellow|Green|Teal|Blue|Purple|Pink
--]]
function giveBigBlindTo(player)
  local position = player.zones.blind_zone.getPosition()
  local rotation = player.zones.blind_zone.getRotation()
  rotation.y = rotation.y + 90
  BigBlind.setRotationSmooth(rotation, false, true)
  BigBlind.setPositionSmooth(position, false, false)
  BigBlind.setLock(false)
end

function lockButtons()
  DealerButton.setLock(true)
  SmallBlind.setLock(true)
  BigBlind.setLock(true)
end