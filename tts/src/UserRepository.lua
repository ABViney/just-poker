USERS = {}

function init(params)
  if params.Data.UserRepository then
    local data = JSON.decode(params.Data.UserRepository)
    for user_id, user in pairs(data) do
      USERS[user_id] = {
        user_id      = user.user_id,
        display_name = user.display_name,
        user_type    = user.user_type,
        auth_token   = user.auth_token
      }
    end
  end
  log("UserRepository initialized")
end

--[[
  Adds a user to this repository. Assumes the information is valid.

  params = {
    userDTO    = {
      user_id      = string,
      auth_token   = string,
      display_name = string,
      user_type    = "game_master"|"bot"|"human",
      twitch_id    = string
    }

    auth_token = string
  }
]]
function addUser(params)
  local userDTO = params.userDTO
  USERS[userDTO.user_id] = {
    user_id      = userDTO.user_id,
    display_name = userDTO.display_name,
    user_type    = userDTO.user_type,
    auth_token   = params.auth_token
  }
  local log_message = logString("Added "..userDTO.display_name.." ["..userDTO.user_id.."] to repository.", "UserRepository.addUser", "[INFO]", false, true)
  log(log_message)
end

function getUserById(user_id)
  return USERS[user_id]
end

function clear()
  USERS = {}
end

function serialize()
  return JSON.encode(USERS)
end