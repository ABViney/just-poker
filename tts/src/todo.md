Todo:
- [x] Can I consolidate logic for moving chips between stacks (seen in animate player and payout pot) to one location?
- [x] Implement chip_exchange for bots
- [x] Figure out what the "start next hand" request looks like for poker server
- [ ] Do... something for game end
- [x] Implement chip_exchange for players

-- Game Master UI
- [x] Add section for setting player count and adding players
- [x] Config for game dto

-- Players
- [x] Determine if a player is a human or bot
- [x] Associate an auth token with a player if they are a human
- [x] If a player is a human--and it is their turn--derive a PlayerActionDTO from their state
- [x] Implement Chip Exchange for players
- [x] Provide a UI to the current human player whose turn it is that informs them of their bet and intent


- [x] Add UI presented to the player who's turn it is that updates with their recognized state
- [x] Facilitate game creation, config, and starting from the GameMaster UI
  - [ ] Add buttons to mark players in game as players in the tournament
- [x] Add UI for dealer to start hand


- [ ] Refactor onSave/onLoad to support continuing an already in-progress game
- [ ] Add button to reset board to current gamestate
  - [ ] Automate resetting the board if a divergence in state is found
- [ ] Fix players revealing their hand outside of a showdown
- [ ] Add a button for the dealer to press that triggers payout after the winning hand(s) is decided
- [ ] Output hand details in chat upon payout
- [ ] Check that event IDs from the server are consecutive
- [ ] Improve trace logging. Refactor to utilize the external logging server
- [ ] Improve broadcast notification/player turn indicator.