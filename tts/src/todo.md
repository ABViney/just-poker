Todo:
- [x] Can I consolidate logic for moving chips between stacks (seen in animate player and payout pot) to one location?
- [x] Implement chip_exchange for bots
- [x] Figure out what the "start next hand" request looks like for poker server
- [ ] Do... something for game end
- [x] Implement chip_exchange for players

-- Game Master UI
- [ ] Add section for setting player count and adding players
- [ ] Config for game dto

-- Players
- [ ] Determine if a player is a human or bot
- [ ] Associate an auth token with a player if they are a human
- [ ] If a player is a human--and it is their turn--derive a PlayerActionDTO from their state
- [ ] Implement Chip Exchange for players
- [ ] Provide a UI to the current human player whose turn it is that informs them of their bet and intent


- [ ] Add UI presented to the player who's turn it is that updates with their recognized state
- [ ] Facilitate game creation, config, and starting from the GameMaster UI
  - [ ] Add buttons to mark players in game as players in the tournament
- [ ] Add UI for dealer to start hand
