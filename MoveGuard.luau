--!strict
-- MoveGuard: the server's check on where players' bodies go. Each client
-- simulates its own character (Roblox gives it the physics), so a modified
-- client can outrun its operator, blink across the map or walk through
-- walls. About 10 times a second MoveGuard samples every human player's
-- HumanoidRootPart (AI bots are the server's own: skipped) and looks for:
--
--   speed     ground covered over a 1 s window (never one sample) beyond the
--             operator's top speed (base x sprint 1.45 x speed boosts) plus
--             generous slack, three windows in a row
--   teleport  one jump between samples beyond what that speed allows in the
--             time the body had (a lag spike shows first as a body that stops
--             moving while its velocity says it's moving: its catch-up is
--             allowed for; a body at rest that jumps isn't)
--   noclip    the straight line from the last clear spot runs through a
--             solid wall: at body AND head height, both ways (neither end
--             inside the wall), in through one face and out through the
--             opposite one, with no way round near enough for the time the
--             body had (probes along the wall, and two-leg detours beside the
--             line: a corner cut, a door jamb, the end of a wall never counts;
--             a lone probe slipping through a seam isn't an opening), through
--             cells still standing. Reinforced walls, an active prep barrier
--             and the map boundary weigh most.
--
-- Legitimate moves let through (see Server.MovementService, Client.Movement,
-- Server.OperatorService.spawn, Server.StatusService):
--   * spawning, respawning, round resets, the server placing a body
--     (CharacterAdded; any server-side CFrame / PivotTo of the root; a
--     server-made mover - LinearVelocity, AlignPosition... - in the body;
--     MoveGuard.allow for anything else): checks pause, then start afresh
--   * vault, climb, window dive (the server's Action "vault" / "vaultWindow"
--     / "climb"): no ordinary-wall noclip within a vault's reach, extra room
--     for speed; rappel (the character's Rappelling flag, corners and all)
--     and a second after it: no ordinary-wall noclip
--   * falling (only upward and sideways movement is measured), knockback and
--     blasts (taking damage or a new status gives extra room for a moment)
--   * speed boosts (Dashing, Hologram: StatusService), gadgets that move the
--     body (MOVE_GADGET_OPS: a gadget use or GadgetActive pauses the checks)
--   * drone / camera views (the body doesn't move), seats, an anchored body
--     (prep drone lock, death), a body the server owns, lag spikes
--
-- Response, softest first. A flag is held verdictDelay (a vault, gadget or
-- server move whose news arrives a moment after the movement explains it
-- away); then the body goes back to where it last was legitimately (rubber
-- band) and it's logged (warn, rate-limited). Ignoring the correction is
-- evidence too. Only repeated strong evidence kicks (noclip and big
-- teleports while moving, crossing a barrier, refusing correction after
-- correction): never what lag can also produce (speed, a jump or a wall
-- crossed right after the body sat still), never in Studio unless tuned
-- to, never a ban.
--
-- Studio: ServerStorage.BPDebug:Invoke("call", "MoveGuard", "debug") returns
-- the counters, each player's state and the last events; "tune" sets a
-- threshold ("call", "MoveGuard", "tune", "speedSlack", 0.4); "simulate"
-- pushes a fake flag through the response; "allow" exempts a player.

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Combatants = require(ReplicatedStorage.Shared.Combatants)
local Config = require(ReplicatedStorage.Shared.Config)
local Tags = require(ReplicatedStorage.Shared.Tags)

local DestructionService = require(script.Parent.DestructionService)
local Events = require(script.Parent.Events)

local MoveGuard = {}

local STUDIO = RunService:IsStudio()
-- (offline tests drive the clock and can listen in: MoveGuard._test)
local clock = os.clock
local trace: ((...any) -> ())? = nil

-- Thresholds (Studio: MoveGuard.tune(key, value)).
local CFG = {
	enabled = true,
	sampleHz = 10, -- samples a second, per player

	-- speed
	sprintMult = 1.45, -- Client.WeaponController's SPRINT_MULT
	speedWindow = 1.0, -- seconds of movement one verdict looks at
	speedSlack = 0.25, -- share over top speed allowed
	speedSlackStuds = 4, -- and this many studs per window on top
	speedStrikes = 3, -- windows in a row over the limit before it's a flag
	boostLinger = 1.0, -- a speed boost still counts this long after it ends

	-- teleport
	teleportFactor = 1.6, -- jump allowed: top speed x time since the body last moved x this
	teleportSlack = 10, -- plus this many studs
	lagWindow = 1.0, -- the longest pause counted as time the body could have been moving
	bigTeleport = 40, -- a jump this long is strong evidence...
	pauseBefore = 0.4, -- ...unless the body sat still this long first (a lag spike's catch-up: noclip too)

	-- noclip
	noclipMinMove = 0.6, -- studs across before the line is tested
	headRise = 1.5, -- the second line, this far above the first
	probeStepMax = 1.6, -- widest spacing of the "way round?" probes (a body needs 2)
	probesMax = 8, -- probes per side; a wider search gives no verdict
	clearMaxAge = 1.0, -- seconds the line's near end may be held
	rayHops = 6, -- see-through things (glass, bodies, gaps in a wall) a ray may pass
	barrierSettle = 2.0, -- seconds into prep before crossing a barrier counts

	-- exemptions
	spawnGrace = 3.0, -- a new body (from when its root exists)
	serverMoveGrace = 1.5, -- the server set the root's CFrame
	vaultGrace = 0.6, -- after a vault / climb / dive ends
	vaultReach = 10, -- studs a vault can carry you (beyond: no exemption)
	vaultBonus = 8, -- extra studs for speed / teleport while vaulting
	rappelGrace = 1.0, -- after letting go of the rope
	rappelSpeedMult = 1.6, -- top speed counts this much more on a rope (sprinting along a wall, wrapping a corner)
	rappelBonus = 8, -- extra studs for speed / teleport on a rope
	gadgetGrace = 2.5, -- after a body-moving gadget (MOVE_GADGET_OPS default)
	moverGrace = 1.0, -- after a server-made mover leaves the body
	relaxGrace = 1.5, -- after damage or a new status (knockback, blasts)
	relaxBonus = 12, -- extra studs then
	pingSlackMax = 0.5, -- seconds of ping counted as extra time to move

	-- verdicts
	verdictDelay = 0.35, -- a flag waits this long for an explanation
	claimLead = 0.75, -- an explanation may start this long before the flag

	-- response
	rubberBand = true,
	settleMin = 0.6, -- seconds a corrected body gets to come back
	decayEvery = 15, -- one point of evidence fades every this many seconds
	kickScore = 12, -- evidence to kick...
	kickStrong = 3, -- ...with at least this many strong flags...
	kickWindow = 120, -- ...in this many seconds
	kickInStudio = false,
	-- live servers: off for the first release (a rubber band, the log and the
	-- counters only), so real-world false positives show before anyone is
	-- kicked; tune it on once the counters look clean
	kickLive = false,
	ignoredStrong = 4, -- corrections ignored in a row before that's strong evidence
	logGap = 2, -- seconds between log lines per player
}
MoveGuard.config = CFG

-- Evidence per kind (3 and up is strong: it can lead to a kick). What a bad
-- connection can also produce (speed and jumps after a pause, a correction
-- that arrives late) is never strong: lag gets a rubber band, not a kick.
local WEIGHTS: { [string]: number } = {
	speed = 1,
	teleport = 2,
	ignored = 2,
	bigTeleport = 3,
	noclip = 3,
	reinforced = 4,
	barrier = 4,
	boundary = 4,
}
local STRONG = 3

-- StatusService's speed-ups (SPEED_MODIFIERS above 1): their default
-- multiplier when the status carries no magnitude.
local BOOSTS: { [string]: number } = { Dashing = 2.6, Hologram = 1.15 }
-- Statuses during which the body is driven by a gadget: no checks.
local EXEMPT_STATUS: { [string]: boolean } = { Dashing = true, Hologram = true }
-- Operators whose gadget moves (or swaps, or zips) the body: seconds of no
-- checks after each use (Events.gadgetUsed) and while GadgetActive is on.
-- (Their kits aren't in the mirror: tune here if one moves the body
-- differently.)
local MOVE_GADGET_OPS: { [string]: number } = {
	grapple = 3.0, -- Grapple Hook: zips to a ledge, window or hatch
	charger = 2.5, -- Shoulder Dash
	mirror = 2.5, -- Hologram Double (driving it, then back)
	twin = 2.5, -- Twin Frame (swapping bodies)
}
-- Body movers only the server can have put in a character (a client's
-- instances don't replicate): while one is in, the server drives the body.
local MOVERS: { [string]: boolean } = {
	LinearVelocity = true,
	AlignPosition = true,
	VectorForce = true,
	LineForce = true,
	BodyVelocity = true,
	BodyPosition = true,
	BodyForce = true,
	BodyThrust = true,
	RocketPropulsion = true,
}
local VAULT_ACTIONS: { [string]: boolean } = { vault = true, vaultWindow = true, climb = true }

local FASTEST = math.max(table.unpack(Config.WalkSpeedBySpeed))

-- still: how long the body had shown no movement (the speed window counts
-- it as time it may have moved unseen: a lag spike). stale: the same, but
-- only while its velocity said it was moving - a body at rest gets none (the
-- teleport and noclip checks use this, so a blink from standing is seen).
type Sample = { t: number, p: Vector3, cap: number, still: number, stale: number }
-- paused: the body sat still just before (a lag spike's catch-up looks the
-- same): never strong evidence
type Pending = { kind: string, at: number, to: Vector3, detail: string, paused: boolean? }
type State = {
	player: Player,
	char: Model?,
	root: BasePart?,
	hum: Humanoid?,
	charConns: { RBXScriptConnection },
	conns: { RBXScriptConnection },
	samples: { Sample },
	prev: Sample?,
	lastChangeT: number, -- last sample that moved, or was at rest (no velocity)
	lastMoveT: number, -- last sample whose position changed
	clearPos: Vector3?,
	clearT: number,
	clearStill: number,
	good: Vector3?,
	speedStrikes: number,
	graceUntil: number,
	vaultUntil: number,
	vaultFrom: Vector3?,
	rappelUntil: number,
	gadgetUntil: number,
	relaxUntil: number,
	movers: number,
	marks: { full: number, vault: number, rappel: number, relax: number },
	pending: Pending?,
	settle: { pos: Vector3, at: number, untilT: number }?,
	ignoredRun: number,
	selfMoveAt: number,
	selfMovePos: Vector3?,
	score: number,
	scoreT: number,
	strong: { number },
	lastLog: number,
	lastEvent: string?,
	sigN: number,
	sigT: number,
}

local states: { [Player]: State } = {}

-- Studio counters ---------------------------------------------------------------------------------

local counters = {
	ticks = 0,
	samples = 0,
	lines = 0, -- noclip lines tested
	rays = 0,
	flagged = {} :: { [string]: number }, -- held for a verdict
	acted = {} :: { [string]: number }, -- rubber-banded
	explained = 0, -- held flags a late exemption explained away
	exempt = {} :: { [string]: number }, -- samples skipped, by reason
	rubberBands = 0,
	kicks = 0,
	wouldKick = 0,
	serverMoves = 0,
	tickMicros = 0,
	tickMicrosMax = 0,
}
local recent: { string } = {}
local cframeNoisy = false

local function bump(t: { [string]: number }, key: string)
	if STUDIO then
		t[key] = (t[key] or 0) + 1
	end
end

local function note(line: string)
	table.insert(recent, string.format("%.1f %s", clock(), line))
	if #recent > 40 then
		table.remove(recent, 1)
	end
end

-- Geometry ------------------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function v3(p: Vector3): string
	return string.format("(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z)
end

-- Segment against an oriented box (slab test), as Shared.MoveGeo does.
local function segHitsBox(a: Vector3, b: Vector3, cf: CFrame, size: Vector3): boolean
	local o = cf:PointToObjectSpace(a)
	local d = cf:VectorToObjectSpace(b - a)
	local t0, t1 = 0, 1
	local half = size / 2
	for _, ax in { "X", "Y", "Z" } do
		local oa: number = (o :: any)[ax]
		local da: number = (d :: any)[ax]
		local ha: number = (half :: any)[ax]
		if math.abs(da) < 1e-9 then
			if oa < -ha or oa > ha then
				return false
			end
		else
			local ta, tb = (-ha - oa) / da, (ha - oa) / da
			if ta > tb then
				ta, tb = tb, ta
			end
			t0 = math.max(t0, ta)
			t1 = math.min(t1, tb)
			if t0 > t1 then
				return false
			end
		end
	end
	return true
end

local groupPairs: { [string]: boolean } = {}
local function collidable(a: string, b: string): boolean
	local key = tostring(a) .. "|" .. tostring(b)
	local known = groupPairs[key]
	if known == nil then
		local ok, res = pcall(function()
			return PhysicsService:CollisionGroupsAreCollidable(a, b)
		end)
		known = not ok or res == true
		groupPairs[key] = known
	end
	return known
end

-- Rays see solid, colliding things only (RespectCanCollide; the collision
-- group of the body, so debris and drone-only blocks are passed), never a
-- body or the terrain.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true
rayParams.IgnoreWater = true
local rayTick = -1
local tickId = 0

local function prepareRays(group: string)
	if rayTick ~= tickId then
		rayTick = tickId
		local list: { Instance } = { workspace.Terrain }
		for _, who in Combatants.all() do
			local c = who.Character
			if c then
				table.insert(list, c)
			end
		end
		rayParams.FilterDescendantsInstances = list
	end
	rayParams.CollisionGroup = group
end

-- What a ray hit counts as: "wall", "reinforced", or nil (passed: glass,
-- ladders, gadgets, bodies, floors / hatches / barricades, destroyed cells).
local function solidKind(part: Instance, at: Vector3): string?
	if not part:IsA("BasePart") or part:IsA("TrussPart") then
		return nil
	end
	if part:GetAttribute("Glass") == true or part:GetAttribute(Tags.Attr.DeviceId) ~= nil then
		return nil
	end
	local parent = part.Parent
	if parent and parent:IsA("Model") and parent:FindFirstChildOfClass("Humanoid") then
		return nil
	end
	if part:GetAttribute(Tags.Attr.SurfaceId) ~= nil then
		local s = DestructionService.getSurface(part)
		if s then
			if s.kind ~= "wall" or not DestructionService.isSolidAt(s, at) then
				return nil
			end
			return if s.reinforced then "reinforced" else "wall"
		end
	end
	-- (a destructible surface nobody has touched yet: by its tags)
	if CollectionService:HasTag(part, Tags.Barricade) or CollectionService:HasTag(part, Tags.Hatch) or CollectionService:HasTag(part, Tags.SoftFloor) then
		return nil
	end
	return if part:GetAttribute(Tags.Attr.Reinforced) == true then "reinforced" else "wall"
end

-- The first solid thing along origin -> origin + dir: (result, kind) or nil.
local function solidHit(origin: Vector3, dir: Vector3): (RaycastResult?, string?)
	local total = dir.Magnitude
	if total < 1e-3 then
		return nil, nil
	end
	local unit = dir / total
	local from = origin
	local left = total
	for _ = 1, CFG.rayHops do
		if STUDIO then
			counters.rays += 1
		end
		local hit = workspace:Raycast(from, unit * left, rayParams)
		if hit == nil then
			return nil, nil
		end
		local kind = solidKind(hit.Instance, hit.Position)
		if kind then
			return hit, kind
		end
		-- pass it: on from just inside it (a ray never sees the part it
		-- starts in)
		local step = (hit.Position - from).Magnitude + 0.05
		left -= step
		if left <= 0.01 then
			return nil, nil
		end
		from += unit * step
	end
	return nil, nil
end

-- Does the line a -> b go through a wall the body couldn't have gone round?
-- `path`: the furthest the body could have gone in the time it had (a way
-- round is within half of that of where the line crosses). Returns "wall" /
-- "reinforced", "inside" (b seems to be in a wall: wait and see), or nil.
local function throughWall(a: Vector3, b: Vector3, path: number): (string?, Instance?)
	local margin = path / 2
	local y = math.max(a.Y, b.Y)
	local A = Vector3.new(a.X, y, a.Z)
	local B = Vector3.new(b.X, y, b.Z)
	local d = B - A
	if STUDIO then
		counters.lines += 1
	end
	local hit, kind = solidHit(A, d)
	if hit == nil then
		return nil, nil
	end
	-- a wall faces sideways (not a floor, a ramp, a step's nose)
	local n = flat(hit.Normal)
	if n.Magnitude < 0.6 then
		return nil, nil
	end
	local back = solidHit(B, -d)
	if back == nil then
		return "inside", nil
	end
	-- in through one face of a wall and out through the opposite one (a
	-- corner or a door jamb cut on the way round meets faces at an angle)
	local nb = flat(back.Normal)
	if nb.Magnitude < 0.6 or n.Unit:Dot(nb.Unit) > -0.7 then
		return nil, nil
	end
	-- head height too (open there: a window, a low wall, a table)
	local up = Vector3.new(0, CFG.headRise, 0)
	local hit2, kind2 = solidHit(A + up, d)
	if hit2 == nil then
		return nil, nil
	end
	if solidHit(B + up, -d) == nil then
		return "inside", nil
	end
	-- no way round: the same line shifted along the wall, both ways, is
	-- blocked too at every step out to `margin` (a door, a corner or the end
	-- of the wall would open one). An opening is at least a stud wide: a
	-- probe that slips through alone (a seam between two wall parts, or one
	-- that starts inside the end of a wall meeting this one) isn't one.
	local steps = math.ceil(margin / 0.8)
	if steps > CFG.probesMax and margin / CFG.probesMax > CFG.probeStepMax then
		return nil, nil -- (too far to search: no verdict)
	end
	steps = math.min(steps, CFG.probesMax)
	local step = margin / steps
	local along = Vector3.new(n.Z, 0, -n.X).Unit
	local half = along * 0.5
	for k = 1, steps do
		for _, sgn in { -1, 1 } do
			local off = along * (sgn * k * step)
			if solidHit(A + off, d) == nil and (solidHit(A + off - half, d) == nil or solidHit(A + off + half, d) == nil) then
				return nil, nil
			end
		end
	end
	-- nor a short detour: a <- W -> b clear for a waypoint W beside the line,
	-- no longer than the body could have gone (catches a corner or jamb cut
	-- the parallel probes miss, whatever way the faces it hit were turned)
	local len = d.Magnitude
	local side = Vector3.new(-d.Z, 0, d.X) / len
	local budget = path * 1.2 + 1
	for _, w in { 0.75, 1.5, 2.5, 4, 6 } do
		for _, sgn in { -1, 1 } do
			for _, at in { 0.5, 0.25, 0.75 } do
				local W = A + d * at + side * (sgn * w)
				if (W - A).Magnitude + (B - W).Magnitude <= budget and solidHit(A, W - A) == nil and solidHit(W, B - W) == nil then
					return nil, nil
				end
			end
		end
	end
	return (if kind == "reinforced" or kind2 == "reinforced" then "reinforced" else "wall"), hit.Instance
end

-- Prep barriers and the map's boundary: walls rays can't see (CanQuery off).
local blockerList: { BasePart } = {}
local blockerMap: Instance? = nil
local blockersDirty = true
local phase = ""
local prepSince = 0

local function blockers(): { BasePart }
	local map = workspace:FindFirstChild("Map")
	if blockersDirty or map ~= blockerMap then
		blockersDirty = false
		blockerMap = map
		table.clear(blockerList)
		for _, b in CollectionService:GetTagged(Tags.PrepBarrier) do
			if b:IsA("BasePart") then
				table.insert(blockerList, b)
			end
		end
		if map then
			for _, c in map:GetChildren() do
				if c.Name == "Boundary" and c:IsA("BasePart") then
					table.insert(blockerList, c)
				end
			end
		end
	end
	return blockerList
end

-- The barrier / boundary the line a -> b crosses, if any.
local function crossesBlocker(a: Vector3, b: Vector3, group: string, now: number): (string?, BasePart?)
	for _, part in blockers() do
		if part.Parent == nil or not part.CanCollide or not collidable(part.CollisionGroup, group) then
			continue
		end
		local barrier = CollectionService:HasTag(part, Tags.PrepBarrier)
		if barrier and (phase ~= "Prep" or now - prepSince < CFG.barrierSettle) then
			continue
		end
		if segHitsBox(a, b, part.CFrame, part.Size) then
			return (if barrier then "barrier" else "boundary"), part
		end
	end
	return nil, nil
end

-- Speed ----------------------------------------------------------------------------------------------

-- The fastest this player's body may go right now (studs / s, sprint
-- included): the operator's base speed with any speed boost, or whatever
-- the server set the Humanoid to, if that's more.
local function topSpeed(player: Player, hum: Humanoid): number
	local base = player:GetAttribute("BaseSpeed")
	local speed = if typeof(base) == "number" then base else FASTEST
	local serverNow = workspace:GetServerTimeNow()
	for name, default in BOOSTS do
		local ends = player:GetAttribute("St_" .. name)
		if typeof(ends) == "number" and ends > serverNow - CFG.boostLinger then
			local m = player:GetAttribute("StM_" .. name)
			speed *= math.max(1, if typeof(m) == "number" then m else default)
		end
	end
	local moveSpeed = player:GetAttribute("MoveSpeed")
	return math.max(speed, hum.WalkSpeed, if typeof(moveSpeed) == "number" then moveSpeed else 0) * CFG.sprintMult
end

local function pingOf(player: Player): number
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	return if ok and typeof(ping) == "number" then math.clamp(ping, 0, CFG.pingSlackMax) else 0.1
end

-- State -----------------------------------------------------------------------------------------------

-- Start measuring afresh from the next sample.
local function rebase(st: State)
	table.clear(st.samples)
	st.prev = nil
	st.clearPos = nil
	st.speedStrikes = 0
end

local function markFull(st: State, now: number)
	st.marks.full = now
end

local function graceFor(st: State, seconds: number, now: number)
	st.graceUntil = math.max(st.graceUntil, now + seconds)
	markFull(st, now)
end

local function gadgetBusy(st: State, now: number): boolean
	if now < st.gadgetUntil then
		return true
	end
	local player = st.player
	local op = player:GetAttribute("Operator")
	if player:GetAttribute("GadgetActive") == true and typeof(op) == "string" and MOVE_GADGET_OPS[op] then
		return true
	end
	local serverNow = workspace:GetServerTimeNow()
	for name in EXEMPT_STATUS do
		local ends = player:GetAttribute("St_" .. name)
		if typeof(ends) == "number" and ends > serverNow then
			return true
		end
	end
	return false
end

local function vaulting(st: State, pos: Vector3, now: number): boolean
	local from = st.vaultFrom
	return now < st.vaultUntil and from ~= nil and flat(pos - from).Magnitude <= CFG.vaultReach
end

local function rappelling(st: State, now: number): boolean
	local char = st.char
	return now < st.rappelUntil or (char ~= nil and char:GetAttribute("Rappelling") == true)
end

-- Response ------------------------------------------------------------------------------------------

local function log(st: State, line: string, force: boolean?)
	note(st.player.Name .. " " .. line)
	st.lastEvent = line
	local now = clock()
	if force or now - st.lastLog >= CFG.logGap then
		st.lastLog = now
		warn(string.format("[MoveGuard] %s (%d): %s", st.player.Name, st.player.UserId, line))
	end
end

-- Puts the body back at `to`, keeping its facing.
local function rubberBand(st: State, to: Vector3, now: number)
	local root = st.root
	if root == nil or root.Parent == nil or not CFG.rubberBand then
		return
	end
	st.selfMoveAt = now
	st.selfMovePos = to
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = CFrame.new(to) * root.CFrame.Rotation
	local settleFor = math.max(CFG.settleMin, pingOf(st.player) * 2 + 0.3)
	st.settle = { pos = to, at = now, untilT = now + settleFor }
	if STUDIO then
		counters.rubberBands += 1
	end
end

local function decayed(st: State, now: number): number
	st.score = math.max(0, st.score - (now - st.scoreT) / CFG.decayEvery)
	st.scoreT = now
	return st.score
end

-- A flag stands: rubber band, log, evidence, maybe a kick.
local function act(st: State, p: Pending, now: number)
	bump(counters.acted, p.kind)
	local weight = WEIGHTS[p.kind] or 1
	if p.paused then
		weight = math.min(weight, STRONG - 1)
	end
	if p.kind == "ignored" then
		-- (one late correction is lag; a client that keeps refusing them isn't)
		st.ignoredRun += 1
		if st.ignoredRun >= CFG.ignoredStrong then
			weight = STRONG
		end
	end
	decayed(st, now)
	st.score += weight
	if weight >= STRONG then
		table.insert(st.strong, now)
	end
	while #st.strong > 0 and now - st.strong[1] > CFG.kickWindow do
		table.remove(st.strong, 1)
	end
	log(st, string.format("%s: %s; back to %s (evidence %.1f, strong %d)", p.kind, p.detail, v3(p.to), st.score, #st.strong))
	rubberBand(st, p.to, now)
	rebase(st)
	if st.score >= CFG.kickScore and #st.strong >= CFG.kickStrong then
		if (STUDIO and not CFG.kickInStudio) or (not STUDIO and not CFG.kickLive) then
			counters.wouldKick += 1
			log(st, if STUDIO then "WOULD KICK (Studio: tune kickInStudio to really kick)" else "WOULD KICK (kickLive is off)", true)
			st.score = 0
			table.clear(st.strong)
			return
		end
		if STUDIO then
			counters.kicks += 1
		end
		log(st, "kicked: repeated impossible movement", true)
		st.player:Kick("Disconnected: your character kept moving in ways the game doesn't allow. If that wasn't you, rejoin.")
	end
end

-- Hold a flag for a moment: an exemption whose news arrives late may still
-- explain it.
local function flag(st: State, kind: string, detail: string, to: Vector3?, now: number, paused: boolean?)
	if to == nil then
		rebase(st)
		return
	end
	bump(counters.flagged, kind)
	st.pending = { kind = kind, at = now, to = to, detail = detail .. (if paused then " (after a pause)" else ""), paused = paused }
end

local function explained(st: State, p: Pending): boolean
	local since = p.at - CFG.claimLead
	local m = st.marks
	if m.full >= since then
		return true
	end
	if p.kind == "noclip" and (m.vault >= since or m.rappel >= since) then
		return true
	end
	if (p.kind == "speed" or p.kind == "teleport") and (m.vault >= since or m.relax >= since) then
		return true
	end
	return false
end

-- Why this sample can't be judged (and the checks start afresh), or nil.
local function skipReason(st: State, root: BasePart, hum: Humanoid, now: number): string?
	if root.Anchored then
		return "anchored"
	end
	if hum.SeatPart ~= nil then
		return "seat"
	end
	local ok, owner = pcall(function()
		return root:GetNetworkOwner()
	end)
	if ok and owner ~= st.player then
		return "serverOwned"
	end
	if st.movers > 0 then
		return "mover"
	end
	if now < st.graceUntil then
		return "grace"
	end
	if gadgetBusy(st, now) then
		return "gadget"
	end
	return nil
end

-- One sample ------------------------------------------------------------------------------------------

local bindCharacter: (st: State, char: Model?) -> ()

local function step(st: State, now: number)
	local player = st.player
	if player.Character ~= st.char then
		bindCharacter(st, player.Character)
	end
	local char, hum = st.char, st.hum
	local root = st.root
	if char ~= nil and (root == nil or root.Parent ~= char) then
		-- (the root arrives a moment after the body: the spawn grace runs
		-- from then, as the server places it)
		local r = char:FindFirstChild("HumanoidRootPart")
		if r and r:IsA("BasePart") and r ~= root then
			root = r
			st.root = r
			graceFor(st, CFG.spawnGrace, now)
			table.insert(st.charConns, r:GetPropertyChangedSignal("CFrame"):Connect(function()
				MoveGuard._serverMoved(st)
			end))
		end
	end
	if char == nil or root == nil or hum == nil or root.Parent ~= char or hum.Health <= 0 then
		st.pending = nil
		st.settle = nil
		rebase(st)
		return
	end
	local skip = skipReason(st, root, hum, now)
	if skip then
		markFull(st, now)
	end

	-- a flag waiting for its verdict
	local p = st.pending
	if p then
		if explained(st, p) then
			st.pending = nil
			if STUDIO then
				counters.explained += 1
			end
			note(player.Name .. " " .. p.kind .. " explained away")
			rebase(st)
		elseif now - p.at >= CFG.verdictDelay then
			st.pending = nil
			act(st, p, now)
		end
		return
	end
	if skip then
		bump(counters.exempt, skip)
		rebase(st)
		return
	end
	local pos = root.Position

	-- just corrected: did the body come back?
	local settle = st.settle
	if settle then
		if now < settle.untilT then
			return
		end
		st.settle = nil
		local away = flat(pos - settle.pos).Magnitude
		local allowed = topSpeed(player, hum) * (now - settle.at) + 6
		if away > allowed then
			act(st, { kind = "ignored", at = now, to = settle.pos, detail = string.format("%.1f studs from the correction", away) }, now)
			return
		end
		st.ignoredRun = 0
		rebase(st)
	end

	if STUDIO then
		counters.samples += 1
	end
	local cap = topSpeed(player, hum)
	local prev = st.prev
	if prev == nil then
		local s: Sample = { t = now, p = pos, cap = cap, still = 0, stale = 0 }
		st.prev = s
		table.insert(st.samples, s)
		st.lastChangeT = now
		st.lastMoveT = now
		st.good = pos
		st.clearPos = pos
		st.clearT = now
		st.clearStill = 0
		return
	end
	local moved = pos - prev.p
	local changed = moved.Magnitude > 0.05
	-- time the body may have been moving unseen: no movement while its
	-- velocity said it was moving (a lag spike) - not a body at rest
	local still = now - st.lastChangeT
	-- and how long it had shown no movement at all (rest or lag)
	local rawStill = now - st.lastMoveT
	local paused = rawStill >= CFG.pauseBefore + (now - prev.t)
	local atRest = not changed and flat(root.AssemblyLinearVelocity).Magnitude < 1.5
	if changed or atRest then
		st.lastChangeT = now
	end
	if changed then
		st.lastMoveT = now
	end
	local sample: Sample = { t = now, p = pos, cap = cap, still = if changed then 0 else rawStill, stale = if changed or atRest then 0 else still }
	local relaxed = now < st.relaxUntil
	local inVault = vaulting(st, pos, now)
	local onRope = rappelling(st, now)
	local ping = pingOf(player)
	local bonus = (if relaxed then CFG.relaxBonus else 0) + (if inVault then CFG.vaultBonus else 0) + (if onRope then CFG.rappelBonus else 0)
	local ropeMult = if onRope then CFG.rappelSpeedMult else 1

	-- 1. teleport: one jump, against the time the body had to make it
	local capNow = math.max(cap, prev.cap)
	local had = (now - prev.t) + math.min(still, CFG.lagWindow) + ping
	local allowJump = capNow * ropeMult * had * CFG.teleportFactor + CFG.teleportSlack + bonus
	local across = flat(moved).Magnitude
	local upward = math.max(0, moved.Y)
	if across > allowJump or upward > allowJump then
		local big = math.max(across, upward) >= CFG.bigTeleport
		flag(st, if big then "bigTeleport" else "teleport", string.format("%.1f studs across, %.1f up in %.2fs (allowed %.1f)", across, upward, now - prev.t, allowJump), st.good, now, paused)
		return
	end

	-- 2. prep barrier / map boundary (walls rays can't see)
	local crossed, blocker = crossesBlocker(prev.p, pos, root.CollisionGroup, now)
	if crossed and blocker then
		flag(st, crossed, "through the " .. crossed .. " " .. blocker:GetFullName(), st.good, now)
		return
	end

	-- 3. noclip: from the last clear spot to here
	local inside = false
	local a = st.clearPos
	if atRest and a and flat(pos - a).Magnitude < CFG.noclipMinMove then
		-- (resting there: the body is at the line's near end now)
		st.clearT, st.clearStill = now, 0
	end
	if a == nil or now - st.clearT > CFG.clearMaxAge then
		-- (held too long: start the line here, remembering how long the body
		-- has sat still - a lag spike's catch-up may follow)
		st.clearPos, st.clearT, st.clearStill = pos, now, sample.stale
	elseif flat(pos - a).Magnitude >= CFG.noclipMinMove then
		prepareRays(root.CollisionGroup)
		-- the furthest the body could have gone in the time it had: a way
		-- round (through an opening, past the end of the wall) is within half
		-- of that of where the line crosses
		local path = capNow * ((now - st.clearT) + math.min(st.clearStill, CFG.lagWindow) + ping) * (1 + CFG.speedSlack) + 1
		local verdict, part = throughWall(a, pos, path)
		if trace then
			trace("noclip", a, pos, now - st.clearT, st.clearStill, path, verdict)
		end
		if verdict == "inside" then
			-- (keep the near end: the far one will come out of the wall; and
			-- this is no spot to put anyone back to)
			inside = true
		elseif verdict and not (verdict == "wall" and (inVault or onRope)) then
			local kind = if verdict == "reinforced" then "reinforced" else "noclip"
			flag(st, kind, string.format("through %s from %s to %s", if part then part:GetFullName() else "a wall", v3(a), v3(pos)), a, now, paused)
			return
		else
			st.clearPos, st.clearT, st.clearStill = pos, now, sample.stale
		end
	end

	-- 4. speed over the window
	table.insert(st.samples, sample)
	local samples = st.samples
	local horizon = now - CFG.speedWindow
	while #samples >= 2 and samples[2].t <= horizon do
		table.remove(samples, 1)
	end
	local old = samples[1]
	if old and old ~= sample and old.t <= horizon then
		local top = 0
		for _, s in samples do
			top = math.max(top, s.cap)
		end
		local elapsed = (now - old.t) + math.min(old.still, CFG.lagWindow) + ping
		local allowed = top * ropeMult * elapsed * (1 + CFG.speedSlack) + CFG.speedSlackStuds + bonus
		local d = pos - old.p
		local covered = math.max(flat(d).Magnitude, d.Y)
		if covered > allowed then
			st.speedStrikes += 1
			if st.speedStrikes >= CFG.speedStrikes then
				flag(st, "speed", string.format("%.1f studs in %.2fs (allowed %.1f at %.1f studs/s)", covered, now - old.t, allowed, top), old.p, now)
				return
			end
		else
			st.speedStrikes = 0
		end
	end

	st.prev = sample
	if not inside then
		st.good = pos
	end
end

-- Players and bodies ------------------------------------------------------------------------------------

-- The server put the root somewhere (a spawn, a reset, a kit): start afresh.
-- (Not our own rubber band; and if the engine ever fired this for the
-- client's own movement, it switches itself off rather than blind us.)
function MoveGuard._serverMoved(st: State)
	if cframeNoisy then
		return
	end
	local now = clock()
	local root = st.root
	local mine = st.selfMovePos
	if mine and root and now - st.selfMoveAt < 0.5 and (root.Position - mine).Magnitude < 1 then
		return
	end
	if now - st.sigT > 2 then
		st.sigT = now
		st.sigN = 0
	end
	st.sigN += 1
	if st.sigN > 40 then
		cframeNoisy = true
		warn("[MoveGuard] the root's CFrame signal fires for client movement here: server-move detection is off (spawns, movers and MoveGuard.allow still exempt)")
		return
	end
	if STUDIO then
		counters.serverMoves += 1
	end
	graceFor(st, CFG.serverMoveGrace, now)
end

bindCharacter = function(st: State, char: Model?)
	for _, c in st.charConns do
		c:Disconnect()
	end
	table.clear(st.charConns)
	st.char = char
	st.root = nil
	st.hum = nil
	st.movers = 0
	st.pending = nil
	st.settle = nil
	st.rappelUntil = 0
	rebase(st)
	local now = clock()
	graceFor(st, CFG.spawnGrace, now)
	if char == nil then
		return
	end
	st.hum = char:FindFirstChildOfClass("Humanoid")
	local function moverIn(d: Instance): boolean
		return MOVERS[d.ClassName] == true
	end
	for _, d in char:GetDescendants() do
		if moverIn(d) then
			st.movers += 1
		end
	end
	table.insert(st.charConns, char.DescendantAdded:Connect(function(d)
		if d:IsA("Humanoid") and st.hum == nil then
			st.hum = d
		elseif moverIn(d) then
			st.movers += 1
			markFull(st, clock())
		end
	end))
	table.insert(st.charConns, char.DescendantRemoving:Connect(function(d)
		if moverIn(d) then
			st.movers = math.max(0, st.movers - 1)
			graceFor(st, CFG.moverGrace, clock())
		end
	end))
	-- rappel: the server's flag (MovementService), and a moment after it
	table.insert(st.charConns, char:GetAttributeChangedSignal("Rappelling"):Connect(function()
		local t = clock()
		st.marks.rappel = t
		if char:GetAttribute("Rappelling") ~= true then
			st.rappelUntil = t + CFG.rappelGrace
		end
	end))
	-- hurt: knockback and blasts get room for a moment
	local hum = st.hum
	if hum then
		local last = hum.Health
		table.insert(st.charConns, hum.HealthChanged:Connect(function(h)
			if h < last then
				local t = clock()
				st.relaxUntil = math.max(st.relaxUntil, t + CFG.relaxGrace)
				st.marks.relax = t
			end
			last = h
		end))
	end
end

local function watch(player: Player)
	if states[player] or Combatants.isBot(player) then
		return
	end
	local st: State = {
		player = player,
		char = nil,
		root = nil,
		hum = nil,
		charConns = {},
		conns = {},
		samples = {},
		prev = nil,
		lastChangeT = 0,
		lastMoveT = 0,
		clearPos = nil,
		clearT = 0,
		clearStill = 0,
		good = nil,
		speedStrikes = 0,
		graceUntil = 0,
		vaultUntil = 0,
		vaultFrom = nil,
		rappelUntil = 0,
		gadgetUntil = 0,
		relaxUntil = 0,
		movers = 0,
		marks = { full = -math.huge, vault = -math.huge, rappel = -math.huge, relax = -math.huge },
		pending = nil,
		settle = nil,
		ignoredRun = 0,
		selfMoveAt = -math.huge,
		selfMovePos = nil,
		score = 0,
		scoreT = clock(),
		strong = {},
		lastLog = -math.huge,
		lastEvent = nil,
		sigN = 0,
		sigT = 0,
	}
	states[player] = st
	table.insert(st.conns, player.AttributeChanged:Connect(function(name: string)
		local now = clock()
		if name == "Action" then
			-- vault, climb, window dive (MovementService -> ActionService)
			local kind = player:GetAttribute("Action")
			if typeof(kind) == "string" and VAULT_ACTIONS[kind] then
				local length = player:GetAttribute("ActionLength")
				st.vaultUntil = now + (if typeof(length) == "number" then math.min(length, 1.2) else 1) + CFG.vaultGrace
				local root = st.root
				st.vaultFrom = if root then root.Position else nil
				st.marks.vault = now
			end
		elseif name == "GadgetActive" then
			local op = player:GetAttribute("Operator")
			local grace = if typeof(op) == "string" then MOVE_GADGET_OPS[op] else nil
			if grace then
				st.gadgetUntil = math.max(st.gadgetUntil, now + grace)
				markFull(st, now)
			end
		elseif string.sub(name, 1, 3) == "St_" then
			if player:GetAttribute(name) ~= nil then
				-- a status landed (a knock, a slow, a boost): room for a moment
				st.relaxUntil = math.max(st.relaxUntil, now + CFG.relaxGrace)
				st.marks.relax = now
				if EXEMPT_STATUS[string.sub(name, 4)] then
					markFull(st, now)
				end
			elseif EXEMPT_STATUS[string.sub(name, 4)] then
				st.gadgetUntil = math.max(st.gadgetUntil, now + CFG.gadgetGrace)
			end
		elseif name == "Downed" then
			-- (the body goes down / gets up: its root height changes)
			st.relaxUntil = math.max(st.relaxUntil, now + CFG.relaxGrace)
			st.marks.relax = now
		end
	end))
end

local function unwatch(player: Player)
	local st = states[player]
	if st == nil then
		return
	end
	for _, c in st.charConns do
		c:Disconnect()
	end
	for _, c in st.conns do
		c:Disconnect()
	end
	states[player] = nil
end

-- Public --------------------------------------------------------------------------------------------------

-- Other server code about to move a player in a way MoveGuard can't see
-- (a CFrame / PivotTo of the root and server-made movers are seen): no
-- checks for `seconds`, then they start afresh.
function MoveGuard.allow(player: Player, seconds: number?, reason: string?)
	local st = states[player]
	if st then
		graceFor(st, seconds or 2, clock())
		st.pending = nil
		if reason then
			note(player.Name .. " allowed: " .. reason)
		end
	end
end

-- Studio: change a threshold. ("call", "MoveGuard", "tune", key, value)
function MoveGuard.tune(key: string, value: any): any
	local current = (CFG :: any)[key]
	if current == nil then
		return "unknown key " .. tostring(key)
	end
	if typeof(value) ~= typeof(current) then
		return "wants a " .. typeof(current)
	end
	(CFG :: any)[key] = value
	return value
end

local function findPlayer(who: any): Player?
	if typeof(who) == "Instance" and who:IsA("Player") then
		return who
	end
	if typeof(who) == "string" then
		return Players:FindFirstChild(who) :: Player?
	end
	local first = Players:GetPlayers()[1]
	return first
end

-- Studio: push a fake flag of `kind` through the response for a player
-- (default: the first one), as if it had just been seen: tests the rubber
-- band, the log and the kick path without a modified client.
function MoveGuard.simulate(who: any, kind: string?): string
	if not STUDIO then
		return "Studio only"
	end
	local player = findPlayer(who)
	local st = if player then states[player] else nil
	if st == nil or st.root == nil then
		return "no such player with a body"
	end
	local k = kind or "noclip"
	local root = st.root :: BasePart
	local to = st.good or root.Position
	st.pending = { kind = k, at = clock() - CFG.verdictDelay, to = to, detail = "simulated" }
	st.marks.full = -math.huge
	return "flagged " .. k .. " for " .. (player :: Player).Name
end

-- Studio: forget evidence and counters.
function MoveGuard.reset(): string
	for _, st in states do
		st.score = 0
		table.clear(st.strong)
	end
	for key, value in counters do
		if typeof(value) == "number" then
			(counters :: any)[key] = 0
		else
			table.clear(value :: any)
		end
	end
	table.clear(recent)
	return "reset"
end

-- Studio: what MoveGuard is doing. ("call", "MoveGuard", "debug")
function MoveGuard.debug(): { [string]: any }?
	if not STUDIO then
		return nil
	end
	local now = clock()
	local players = {}
	for player, st in states do
		local root = st.root
		players[player.Name] = {
			alive = root ~= nil and root.Parent ~= nil,
			position = if root then v3(root.Position) else nil,
			topSpeed = if st.hum then math.floor(topSpeed(player, st.hum :: Humanoid) * 10 + 0.5) / 10 else nil,
			evidence = math.floor(decayed(st, now) * 10 + 0.5) / 10,
			strongFlags = #st.strong,
			grace = math.max(0, math.floor((st.graceUntil - now) * 10 + 0.5) / 10),
			vaulting = now < st.vaultUntil,
			rappelling = rappelling(st, now),
			gadget = gadgetBusy(st, now),
			movers = st.movers,
			pending = if st.pending then (st.pending :: Pending).kind else nil,
			settling = st.settle ~= nil,
			speedStrikes = st.speedStrikes,
			lastEvent = st.lastEvent,
		}
	end
	local avg = if counters.ticks > 0 then counters.tickMicros / counters.ticks else 0
	return {
		enabled = CFG.enabled,
		cframeSignalNoisy = cframeNoisy,
		phase = phase,
		counters = {
			ticks = counters.ticks,
			samples = counters.samples,
			linesTested = counters.lines,
			rays = counters.rays,
			flagged = table.clone(counters.flagged),
			acted = table.clone(counters.acted),
			explained = counters.explained,
			exempt = table.clone(counters.exempt),
			rubberBands = counters.rubberBands,
			kicks = counters.kicks,
			wouldKick = counters.wouldKick,
			serverMoves = counters.serverMoves,
			avgTickMicros = math.floor(avg),
			maxTickMicros = math.floor(counters.tickMicrosMax),
		},
		players = players,
		recent = table.clone(recent),
	}
end

function MoveGuard.init()
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(unwatch)

	-- a gadget that moves the body: no checks for a moment
	Events.gadgetUsed:connect(function(p: any)
		local st = states[p]
		local op = if st then p:GetAttribute("Operator") else nil
		local grace = if typeof(op) == "string" then MOVE_GADGET_OPS[op] else nil
		if st and grace then
			st.gadgetUntil = math.max(st.gadgetUntil, clock() + grace)
			markFull(st, clock())
		end
	end)

	-- the round's phase: prep barriers count once prep has settled; the map
	-- (and its barriers) may be rebuilt for each round
	local function onPhase()
		local ph = workspace:GetAttribute("Phase")
		phase = if typeof(ph) == "string" then ph else ""
		if phase == "Prep" then
			prepSince = clock()
		end
		blockersDirty = true
	end
	workspace:GetAttributeChangedSignal("Phase"):Connect(onPhase)
	onPhase()

	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		local interval = 1 / math.max(CFG.sampleHz, 1)
		if acc < interval then
			return
		end
		acc = math.min(acc - interval, interval)
		if not CFG.enabled then
			return
		end
		local started = os.clock()
		local t0 = clock()
		tickId += 1
		for _, st in states do
			local ok, err = pcall(step, st, t0)
			if not ok then
				-- (one bad sample never stops the others; start that player afresh)
				st.pending = nil
				rebase(st)
				if STUDIO then
					warn("[MoveGuard] " .. tostring(err))
				end
			end
		end
		if STUDIO then
			local us = (os.clock() - started) * 1e6
			counters.ticks += 1
			counters.tickMicros += us
			counters.tickMicrosMax = math.max(counters.tickMicrosMax, us)
		end
	end)
end

-- (offline tests: the sampler driven with their own clock and positions)
MoveGuard._test = {
	step = step,
	watch = watch,
	states = states,
	throughWall = throughWall,
	counters = counters,
	setClock = function(fn: () -> number)
		clock = fn
	end,
	setTrace = function(fn: ((...any) -> ())?)
		trace = fn
	end,
}

return MoveGuard
