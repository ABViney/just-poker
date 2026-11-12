USERS = {}

function init(params)
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
end

function getUserById(user_id)
  return USERS[user_id]
end

function clear()
  USERS = {}
end