# MoveGuard: server-side movement anti-cheat for Roblox

`MoveGuard.luau` is the movement anti-cheat from **Breachpoint**, a 5v5 tactical shooter on Roblox. I have been working on the systems seen in Breachpoint since May 2026, and so anything seen in Breachpoint is a combination of a number of systems I have created myself for separate projects. 

Roblox lets each client simulate its own character, so an exploited client can speed hack, teleport or walk through walls. MoveGuard is the server's check on that. It runs about 10 times a second per player and watches every human player's root part. It does this without trusting the client, and without punishing players for lag or for the game's own movement mechanics.

## What it detects

- **Speed:** distance covered over a rolling 1-second window, compared with that player's real top speed: base speed × sprint × any active speed boosts, plus slack. It has to fail three windows in a row, never on a single sample.
- **Teleports:** a single jump between samples that's longer than the body could have travelled in the time it had.
- **Noclip:** a straight line from the last clear position that passes through a solid wall. To count, all of these must be true:
  - the line is blocked at body height and at head height, in both directions;
  - it enters through one face and leaves through the opposite face;
  - there's no way around within reach. Probes along the wall and two-leg detours rule out corner cuts and door jambs.
  - the wall cells it crosses are still standing in the destructible-wall system.
- **Barriers:** crossing the prep-phase barrier or the map boundary.

## What it deliberately lets through

| Legitimate movement | How MoveGuard handles it |
|---|---|
| Spawns, respawns and round resets | A short grace period on every new body |
| Any server-side `CFrame`/`PivotTo` of the root, or server-created movers | Checks pause, then restart cleanly |
| Vaults, climbs and window dives | No noclip check within vault reach, extra speed allowance |
| Rappelling | No noclip check, plus a separate speed allowance on the rope |
| Knockback and explosions | Taking damage or a new status gives a moment of extra room |
| Movement gadgets | A per-operator grace period after each use |
| Seats, anchored bodies (drone views, death), server-owned bodies | Skipped |
| Lag spikes | A body that froze while its velocity said it was moving may catch up |

## How it responds

1. **Wait:** every flag is held for 0.35 s, in case a late-arriving explanation (a vault or a gadget) clears it.
2. **Rubber band:** the player goes back to their last legitimate position, and it's logged (rate-limited).
3. **Kick:** only for repeated strong evidence inside a time window. Anything lag can also produce never counts as strong.

Kicks can be switched off with a config flag. I ship it with live kicks off for the first release so I can watch for false positives first. It never bans.

## Results

- **Offline test harness on three real maps:** 0 false positives across 1,920 tight, corner-cutting paths through every doorway, standing and crouched, with jitter and simulated 0.8 s lag freezes. It caught 2× speed, a 60-stud blink and a 25-stud blink from standing.
- **Live in Roblox Studio:**
  - 0 false flags over about 3,000 samples of normal play: spawns, round resets, drones, server teleports.
  - A client-side 60-stud teleport was flagged and rubber-banded.
  - A 45 studs/s speed hack was flagged within about 1.5 s.
- **Cost:** about 35 µs per server tick on average with one player, measured in Studio.

## Tooling

- **`MoveGuard.debug()`:** returns counters, per-player state and recent events.
- **`MoveGuard.tune(key, value)`:** changes any threshold at runtime. Every threshold lives in one `CFG` table.
- **`MoveGuard.simulate()`:** pushes a fake flag through the full response, to test the rubber band and kick path without an exploit.
- **`MoveGuard.allow(player, seconds)`:** an explicit exemption for any other server-side teleport.

## Dependencies

It's taken from a full game, so it requires a few of that game's modules. It's here to read, not to drop in as is.

| Module | What MoveGuard uses it for |
|---|---|
| `Shared.Combatants` | Iterating players and AI bots (bots are skipped) |
| `Shared.Config` | Movement speed values |
| `Shared.Tags` | CollectionService tag and attribute names (barricades, reinforced walls, prep barrier) |
| `Server.DestructionService` | Whether a destructible wall cell is still standing at a point |
| `Server.Events` | A "gadget used" signal |

To adapt it to another game, swap those for your own equivalents. The detection logic itself is self-contained.
