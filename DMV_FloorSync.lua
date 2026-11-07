-- DMV_FloorSync.lua
--
-- Floor-aware party/raid blips.
--
-- The 1.12 client (even with ClassicAPI) gives an addon only two facts about
-- another group member inside an instance:
--   * their 3D world position (UnitPosition), and only while they are inside
--	   the client's object sync window;
--   * their zone-level area ID (C_Map.GetBestMapForUnit / UNIT_AREA_CHANGED),
--	   which is the same for every floor of a dungeon.
-- No API reports another unit's subzone, WMO group or minimap text, and
-- DMV's floor transitions depend on exactly that information (plus the
-- unit's full movement history). So no client-side function can compute
-- another player's floor with certainty.
--
-- This module therefore resolves a member's floor from two sources, in
-- order of authority. Members whose floor is unknown (typically players
-- without DMV) use the legacy display: drawn only while the viewer looks at
-- their own floor, and only while inside the client's position range.
--
--   1. "sync"   - the member runs DMV and broadcasts the floor their own DMV
--				   shows (addon message, prefix DMVF). Exact, apart from the
--				   network delay at the moment they change floor.
--   2. "layout" - the dungeon layout settles it on its own: single-floor
--				   maps, and maps whose floors are separate instance copies
--				   (Scarlet Monastery wings), where any member we can see
--				   must be on our floor.

DMV_FS = DMV_FS or {}
local FS = DMV_FS

local PREFIX		  = "DMVF"
local PROTO			  = "1"
local TICK			  = 0.2		-- seconds between ticker passes
local HEARTBEAT		  = 10		-- resend own state at least this often
local STALE			  = 25		-- remote state expires after this long
local MIN_SEND_GAP	  = 0.5		-- coalesce floor flapping on stairs
local QUERY_GAP		  = 5		-- min seconds between our queries
local REPLY_GAP		  = 2		-- min seconds between replies to queries
local POS_GAP		  = 1.0		-- min seconds between position updates (party)
local POS_GAP_RAID	  = 2.0		-- same, in raids larger than 10
local POS_MOVE		  = 2		-- yards moved before a new position is sent
local POS_IDLE		  = 5		-- resend position this often while standing still
local POS_STALE		  = 8		-- remote position expires after this long
local POS_NEAR		  = 70		-- yards: members closer than this see us natively

-- Maps whose floors are separate instance copies: anyone visible is on our
-- floor. Only list a map here when EVERY floor is its own instance.
DMV_SeparateInstanceFloors = DMV_SeparateInstanceFloors or {
	[189] = true, -- Scarlet Monastery: Graveyard / Library / Armory / Cathedral
}

-- Overview floors: a floor whose map art also covers other floors. Members
-- on any listed floor are drawn there too. Naxxramas floor 5 contains all
-- four quarters (every quarter boss also has a floor-5 marker).
DMV_OverviewFloors = DMV_OverviewFloors or {
	[533] = { [5] = { 1, 2, 3, 4 } },
}

local function FloorVisibleOn(mapID, unitFloor, viewedFloor)
	if unitFloor == viewedFloor then return true end
	local ov = DMV_OverviewFloors[mapID]
	local list = ov and ov[viewedFloor]
	if not list then return false end
	for i = 1, table.getn(list) do
		if list[i] == unitFloor then return true end
	end
	return false
end
FS.FloorVisibleOn = FloorVisibleOn

FS.remote	  = FS.remote or {}   -- [name] = { map, floor, t }
FS.remotePos  = FS.remotePos or {} -- [name] = { map, y, x, z, t }
FS.lastPos	  = -1000
FS.sentMap	  = nil
FS.sentFloor  = nil
FS.lastSend   = -1000
FS.lastQuery  = -1000
FS.lastReply  = -1000
FS.pendingAt  = nil
FS.pendingQ   = nil
FS.elapsed	  = 0

local function Now() return GetTime() end

local function Arg(v, globalName)
	if v ~= nil then return v end
	return getglobal(globalName)
end

-- Own state
-- DMV_FloorMapRects is static, so counts are cached (this runs per group
-- member per frame while the map is open).
local floorCounts = {}
local function FloorCount(mapID)
	local n = floorCounts[mapID]
	if n then return n end
	local rects = DMV_FloorMapRects and DMV_FloorMapRects[mapID]
	if not rects then return 0 end
	n = 0
	for _ in pairs(rects) do n = n + 1 end
	floorCounts[mapID] = n
	return n
end
FS.FloorCount = FloorCount

-- Returns mapID, floor of the dungeon the player is physically in, or nil.
-- Uses DMV's per-loading-screen instance cache: this runs per group member
-- per refresh in Scarlet Monastery.
function DMV_FS_GetOwnState()
	local instanceType, mapID
	if DMV_GetInstanceCached then
		instanceType, mapID = DMV_GetInstanceCached()
	else
		local _
		_, instanceType, _, _, _, _, _, mapID = GetInstanceInfo()
	end
	if instanceType ~= "party" and instanceType ~= "raid" then return nil end
	if not mapID or not (DMV_DungeonByMapID and DMV_DungeonByMapID[mapID]) then return nil end
	local floor = DMV_GetActualFloor and DMV_GetActualFloor()
	if not floor or floor == 0 then return nil end
	return mapID, floor
end

local function GroupChannel()
	if GetNumRaidMembers() > 0 then return "RAID" end
	if GetNumPartyMembers() > 0 then return "PARTY" end
	return nil
end

-- Calls fn(unit) for every group member except the player.
local function ForEachGroupUnit(fn)
	local n = GetNumRaidMembers()
	if n > 0 then
		for i = 1, n do
			local u = "raid" .. i
			if not UnitIsUnit(u, "player") then fn(u) end
		end
	else
		for i = 1, GetNumPartyMembers() do fn("party" .. i) end
	end
end
FS.ForEachGroupUnit = ForEachGroupUnit

local function Send(text)
	local ch = GroupChannel()
	if not ch or not SendAddonMessage then return false end
	-- "|" is an escape character in chat text; never put it in a message.
	local ok = pcall(SendAddonMessage, PREFIX, text, ch)
	return ok
end

function DMV_FS_SendState(force)
	local t = Now()
	if not force and (t - FS.lastSend) < MIN_SEND_GAP then
		FS.pendingAt = FS.lastSend + MIN_SEND_GAP
		return
	end
	local map, floor = DMV_FS_GetOwnState()
	map = map or 0
	floor = floor or 0
	-- Older versions appended a third "trust" field; receivers treat it as
	-- optional, so both formats are understood in either direction.
	local sent = Send(PROTO .. ":S:" .. map .. ":" .. floor)
	-- Record the attempt even on failure so a rejected send is not retried every tick.
	FS.lastSend = t
	if sent then
		FS.sentMap   = map
		FS.sentFloor = floor
	end
	FS.pendingAt = nil
end

-- Position broadcast: lets group members draw our blip beyond the ~100 yard
-- range in which the client knows other players' positions. Integer yards.
local function Round(v) return math.floor(v + 0.5) end

-- Live sync entry for `name` on `map` (nil when missing, stale or elsewhere).
local function PeerEntry(name, map, t)
	local e = name and FS.remote[name]
	if e and e.map == map and (t - e.t) <= STALE then return e end
	return nil
end

-- Is a DMV user in our instance too far away to see us natively? Only
-- members whose DMV has reported a floor here can use a position message;
-- players without DMV, offline members and members outside the instance
-- never count, so they cannot keep everyone broadcasting.
function FS.SomeoneFar(py, px, map)
	local t = Now()
	local anyPeer = false
	for name in pairs(FS.remote) do
		if PeerEntry(name, map, t) then anyPeer = true; break end
	end
	if not anyPeer then return false end
	local far = false
	local n2 = POS_NEAR * POS_NEAR
	ForEachGroupUnit(function(u)
		if far then return end
		if not PeerEntry(UnitName(u), map, t) or not UnitIsConnected(u) then return end
		local uy, ux = UnitPosition(u)
		if not uy then far = true; return end
		local dy, dx = uy - py, ux - px
		if dy * dy + dx * dx > n2 then far = true end
	end)
	return far
end

function DMV_FS_SendPosition(t, map)
	local py, px, pz = UnitPosition("player")
	if not py then return end
	-- Skip entirely while every DMV user in the group is well inside client
	-- range: they already see our real position. POS_NEAR stays far below
	-- the ~100 yd visibility edge so slight range asymmetry cannot drop our blip.
	if not FS.SomeoneFar(py, px, map) then
		FS.posY = nil -- force a send as soon as someone drifts away
		return
	end
	local gap = (GetNumRaidMembers() > 10) and POS_GAP_RAID or POS_GAP
	if (t - FS.lastPos) < gap then return end
	local ry, rx, rz = Round(py), Round(px), Round(pz or 0)
	local moved = FS.posY == nil or math.abs(ry - FS.posY) >= POS_MOVE
		or math.abs(rx - FS.posX) >= POS_MOVE or math.abs(rz - FS.posZ) >= POS_MOVE
	if not moved and (t - FS.lastPos) < POS_IDLE then return end
	FS.lastPos = t
	if Send(PROTO .. ":P:" .. map .. ":" .. ry .. ":" .. rx .. ":" .. rz) then
		FS.posY, FS.posX, FS.posZ = ry, rx, rz
	end
end

-- Last synced position of a member, or nil if missing/stale/other map.
function DMV_FS_GetSyncedPosition(name, mapID)
	local e = name and FS.remotePos[name]
	if not e then return nil end
	if (Now() - e.t) > POS_STALE then FS.remotePos[name] = nil; return nil end
	if e.map ~= mapID then return nil end
	return e.y, e.x, e.z
end

function DMV_FS_SendQuery()
	local t = Now()
	if (t - FS.lastQuery) < QUERY_GAP then
		FS.pendingQ = FS.lastQuery + QUERY_GAP
		return
	end
	if Send(PROTO .. ":Q") then FS.lastQuery = t end
	FS.pendingQ = nil
end

-- Incoming messages
function DMV_FS_OnAddonMessage(prefix, msg, channel, sender)
	if not FS.active or prefix ~= PREFIX or not msg or not sender then return end
	-- Only group traffic: DMV never sends on other channels.
	if channel ~= "PARTY" and channel ~= "RAID" then return end
	if sender == UnitName("player") then return end
	local _, _, ver, kind, rest = string.find(msg, "^(%d+):(%a):?(.*)$")
	if ver ~= PROTO then return end
	if kind == "Q" then
		local t = Now()
		if (t - FS.lastReply) >= REPLY_GAP then
			FS.lastReply = t
			DMV_FS_SendState(true)
		end
	elseif kind == "P" then
		local _, _, map, y, x, z = string.find(rest or "", "^(%d+):(%-?%d+):(%-?%d+):(%-?%d+)$")
		map, y, x, z = tonumber(map), tonumber(y), tonumber(x), tonumber(z)
		if not map or not y or not x or not z then return end
		-- Positions arrive continuously; update the sender's entry in place.
		local e = FS.remotePos[sender]
		if not e then e = {}; FS.remotePos[sender] = e end
		e.map, e.y, e.x, e.z, e.t = map, y, x, z, Now()
	elseif kind == "S" then
		-- The optional third field is the old "trust" flag; it is ignored.
		local _, _, map, floor = string.find(rest or "", "^(%d+):(%d+):?(%d*)$")
		map, floor = tonumber(map), tonumber(floor)
		if not map or not floor then return end
		if map == 0 or floor == 0 then
			-- The member left the instance: drop their floor and their last
			-- broadcast position, or a frozen blip would stay until it expires.
			FS.remote[sender] = nil
			FS.remotePos[sender] = nil
		else
			local e = FS.remote[sender]
			if not e then e = {}; FS.remote[sender] = e end
			e.map, e.floor, e.t = map, floor, Now()
		end
	end
end

-- Valid synced floor for a member name in the given map, or nil.
function DMV_FS_GetSyncedFloor(name, mapID)
	local e = name and FS.remote[name]
	if not e then return nil end
	if (Now() - e.t) > STALE then FS.remote[name] = nil; return nil end
	if e.map ~= mapID then return nil end
	return e.floor
end

-- Decision
-- Returns floor, source for a group member (by name), or nil when the floor
-- is not known with enough confidence. Unknown floors use the legacy display.
function DMV_FS_GetUnitFloor(name, mapID)
	if not mapID then return nil end
	if FloorCount(mapID) <= 1 then return 1, "layout" end
	if DMV_SeparateInstanceFloors[mapID] then
		local _, own = DMV_FS_GetOwnState()
		if own then return own, "layout" end
	end
	local floor = DMV_FS_GetSyncedFloor(name, mapID)
	if floor then return floor, "sync" end
	return nil
end

-- Should a blip for the member `name` be drawn on `viewedFloor`?
-- remoteOnly: the position came from the member's broadcast, not the client.
function DMV_FS_ShouldShowUnit(name, mapID, viewedFloor, actualFloor, remoteOnly)
	local f
	if remoteOnly then
		f = DMV_FS_GetSyncedFloor(name, mapID)
		if not f and FloorCount(mapID) == 1 then f = 1 end
	else
		f = DMV_FS_GetUnitFloor(name, mapID)
	end
	if f then return FloorVisibleOn(mapID, f, viewedFloor) end
	-- Unknown floor (e.g. member without DMV, within client range): assumed
	-- to be on the player's floor, so drawn wherever the player's floor is.
	return FloorVisibleOn(mapID, actualFloor, viewedFloor)
end

-- Ticker: own-state and position broadcast
function DMV_FS_Tick()
	if not GroupChannel() then return end
	local t = Now()
	local map, floor = DMV_FS_GetOwnState()
	if not map then return end

	if map ~= FS.sentMap or floor ~= FS.sentFloor then
		DMV_FS_SendState(false)
	elseif FS.pendingAt and t >= FS.pendingAt then
		DMV_FS_SendState(true)
	elseif (t - FS.lastSend) >= HEARTBEAT then
		DMV_FS_SendState(true)
	end
	if FS.pendingQ and t >= FS.pendingQ then DMV_FS_SendQuery() end
	DMV_FS_SendPosition(t, map)
end

local function PruneRemote()
	local keep = {}
	ForEachGroupUnit(function(u)
		local n = UnitName(u)
		if n then keep[n] = true end
	end)
	for name in pairs(FS.remote) do
		if not keep[name] then FS.remote[name] = nil end
	end
	for name in pairs(FS.remotePos) do
		if not keep[name] then FS.remotePos[name] = nil end
	end
end

-- Event-driven lifecycle: no OnUpdate handler while inactive.
local frame = CreateFrame("Frame", "DMV_FloorSyncFrame")
FS.frame = frame
FS.active = false

local function ActiveMap()
	if not GroupChannel() then return nil end
	local _, kind, _, _, _, _, _, map = GetInstanceInfo()
	if kind ~= "party" and kind ~= "raid" then return nil end
	if map and DMV_DungeonByMapID and DMV_DungeonByMapID[map] then return map end
	return nil
end

local function ResetSession()
	FS.remote, FS.remotePos = {}, {}
	FS.posY, FS.posX, FS.posZ = nil, nil, nil
	FS.sentMap, FS.sentFloor = nil, nil
	FS.lastSend, FS.lastQuery, FS.lastReply, FS.lastPos = -1000, -1000, -1000, -1000
	FS.pendingAt, FS.pendingQ, FS.readyAt = nil, nil, nil
	FS.elapsed = 0
end

local function Stop()
	local wasActive = FS.active
	FS.active, FS.activeMap = false, nil
	frame:SetScript("OnUpdate", nil)
	-- Invalidate our last floor once on exit; no retry or timer while asleep.
	if wasActive and GroupChannel() then Send(PROTO .. ":S:0:0") end
	ResetSession()
end

local function OnUpdate(self, elapsed)
	elapsed = tonumber(elapsed) or tonumber(getglobal("arg1")) or 0
	FS.elapsed = FS.elapsed + elapsed
	if FS.elapsed < TICK then return end
	FS.elapsed = 0
	-- Finite settling delay only while grouped inside a supported instance.
	if FS.readyAt and Now() < FS.readyAt then return end
	FS.readyAt = nil
	DMV_FS_Tick()
end

local function Refresh(forceReset, delay)
	local map = ActiveMap()
	if not map then Stop(); return end
	if not FS.active or FS.activeMap ~= map or forceReset then
		ResetSession()
		FS.active, FS.activeMap = true, map
		FS.readyAt = Now() + (delay or 1)
		FS.pendingAt, FS.pendingQ = FS.readyAt, FS.readyAt
		frame:SetScript("OnUpdate", OnUpdate)
	end
end
FS.Refresh = Refresh

frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("RAID_ROSTER_UPDATE")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("ZONE_CHANGED_INDOORS")
frame:RegisterEvent("ZONE_CHANGED")

frame:SetScript("OnEvent", function(self, event, a1, a2, a3, a4)
	event = event or getglobal("event")
	if event == "CHAT_MSG_ADDON" then
		DMV_FS_OnAddonMessage(Arg(a1, "arg1"), Arg(a2, "arg2"), Arg(a3, "arg3"), Arg(a4, "arg4"))
	elseif event == "PLAYER_LEAVING_WORLD" or event == "PLAYER_LOGOUT" then
		Stop()
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- Fires on login/reload too; wait for DMV's own floor initialization.
		Refresh(true, 2)
	elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
		Refresh(false, 1)
		if FS.active then
			PruneRemote()
			FS.pendingAt = FS.pendingAt or (Now() + 1)
			FS.pendingQ = FS.pendingQ or (Now() + 1)
		end
	elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED" then
		Refresh(false, 2)
	end
end)

-- No slash wrapper or menu entries: sync is automatic.
