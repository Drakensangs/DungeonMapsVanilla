-- DungeonMapsVanilla.lua

local L = DMV_L
local DMV_Frames = {}
local DMV_Textures = {}
local DMV_CurrentDungeon = nil
local DMV_InstanceBrowseMode = nil   -- "dungeon", "raid", or nil
local DMV_InstanceZoneID = nil		 -- selected ID in zone dropdown
local DMV_CurrentFloor = 1
local DMV_Initialized = false
local DMV_Visible = false
local DMV_ClickFrame = nil
local DMV_Container = nil
local DMV_BossPins = {}
DMV_BossPinList = DMV_BossPins	-- read by DMV_Compat (Magnify mouse clipping)
-- Cache for names resolved from IDs via ClassicAPI.
-- Key: raw ID string e.g. "n11324", "o8417313", "q20183", "i19019"
-- Value: resolved name string once loaded, or false while pending.
local DMV_NameCache = {}

-- Item rarity colors.
local DMV_ITEM_QUALITY_COLORS = {
	[0] = "ff9d9d9d", -- Poor
	[1] = "ffffffff", -- Common
	[2] = "ff1eff00", -- Uncommon
	[3] = "ff0070dd", -- Rare
	[4] = "ffa335ee", -- Epic
	[5] = "ffff8000", -- Legendary
	[6] = "ffe6cc80", -- Artifact
}

-- Forward declarations (defined further down).
local DMV_ResolveIDName
local DMV_FormatItemText
local DMV_FormatQuestText
local DMV_ResolveCommentItems
local DMV_CalibMode = false
local DMV_MapScale = 0.99
local DMV_LastKnownFloor = {}
local DMV_ActualFloor = 1   -- The floor the player is physically on (may differ from DMV_CurrentFloor when browsing)
local DMV_PrevPos = { x = nil, y = nil, z = nil }
local DMV_PreviewMode = false
local DMV_TransitionFrame = nil  -- background OnUpdate frame for transition detection

-- Dungeon map is 4x3 tiles of 256x256 = 1024x768
local TILE_SIZE = 256
local MAP_COLS = 4
local MAP_ROWS = 3
local MAP_W = TILE_SIZE * MAP_COLS  -- 1024
local MAP_H = TILE_SIZE * MAP_ROWS  -- 768

-- Player arrow
local DMV_PlayerArrow = nil
local ARROW_SIZE = 24
local DMV_PlayerMapPosBuf = { x = 0, y = 0 }

-- Markers, member blips and the player arrow are frames that only handle
-- the mouse (tooltips, clicks, calibration drags). They sit in the
-- FULLSCREEN_DIALOG strata, above DMV_ClickFrame, at these levels above
-- DMV_Container: markers < member blips < the player's own arrow.
local PIN_LEVEL, BLIP_LEVEL, ARROW_LEVEL = 15, 18, 20

-- Everything those frames show is drawn by one frame, DMV_OverlayDraw, in
-- fixed draw layers. The client always draws a frame's layers in this
-- order, so the stacking cannot depend on frame levels, which the 1.12
-- client renumbers on its own ("compression") and which Magnify's scroll
-- frame does not honour:
--   BACKGROUND markers, BORDER marker hover glow, ARTWORK member blips,
--   OVERLAY the player arrow (and the calibration labels).
-- DMV_OverlayDraw keeps DMV_Container's strata (the world map's), so any
-- window raised above the world map (Atlas, dropdown menus) is always
-- drawn over the markers, blips and arrow.
local DRAW_LEVEL = 15
local DMV_OverlayDraw = nil

local function DMV_GetOverlayDraw()
	if DMV_OverlayDraw then return DMV_OverlayDraw end
	local f = CreateFrame("Frame", "DMV_OverlayDraw", DMV_Container)
	f:SetAllPoints(DMV_Container)
	f:SetFrameLevel(DMV_Container:GetFrameLevel() + DRAW_LEVEL)
	f:EnableMouse(false)
	DMV_OverlayDraw = f
	return f
end

-- A texture (or font string) drawn by DMV_OverlayDraw on top of `owner`.
-- Textures cover the owner. Shown or hidden through DMV_BindImages.
local function DMV_CreateOverlayRegion(owner, layer, isText)
	local draw = DMV_GetOverlayDraw()
	local r
	if isText then
		r = draw:CreateFontString(nil, layer, "GameFontNormalSmall")
	else
		r = draw:CreateTexture(nil, layer)
		r:SetAllPoints(owner)
	end
	if not owner:IsShown() then r:Hide() end
	return r
end

-- The images of a marker, blip or arrow frame follow the frame's own shown
-- state: the frame's Show and Hide are wrapped (on that frame only), so
-- every caller keeps both in step. onShow / onHide show and hide the
-- images. The frame and DMV_OverlayDraw have the same parents, so a closed
-- map hides both. OnShow/OnHide are not used for this: the client does not
-- send OnHide to a frame that a script hides while its window is closing.
local function DMV_BindImages(owner, onShow, onHide)
	local show, hide = owner.Show, owner.Hide
	owner.dmvImagesShown = owner:IsShown() and true or false
	owner.Show = function(self)
		show(self)
		if not owner.dmvImagesShown then
			owner.dmvImagesShown = true
			onShow()
		end
	end
	owner.Hide = function(self)
		hide(self)
		if owner.dmvImagesShown then
			owner.dmvImagesShown = false
			onHide()
		end
	end
end

-- Run `fn` after a frame script. ClassicAPI's intrinsic postcall binding
-- survives other addons replacing the handler with SetScript; without it
-- (older ClassicAPI) a plain HookScript is used. Returns true when the
-- postcall binding was used.
function DMV_HookScriptPost(frame, script, fn)
	if LE_SCRIPT_BINDING_TYPE_INTRINSIC_POSTCALL then
		frame:HookScript(script, fn, LE_SCRIPT_BINDING_TYPE_INTRINSIC_POSTCALL)
		return true
	end
	frame:HookScript(script, fn)
	return false
end

-- Report an error through the error handler instead of hiding it.
local function DMV_SafeCall(fn)
	local ok, err = pcall(fn)
	if not ok then
		local handler = geterrorhandler and geterrorhandler()
		if handler then handler(err) end
	end
end

local function GetContinentDropdown()
	return WorldMapContinentDropdown or WorldMapContinentDropDown
end

local function GetZoneDropdown()
	return WorldMapZoneDropdown or WorldMapZoneDropDown
end

-- Leave instance browse mode (real continent/zone shown in the dropdowns).
local function DMV_ClearBrowseState()
	DMV_InstanceBrowseMode = nil
	DMV_InstanceZoneID = nil
end

-- Show Dungeons/Raids in the continent dropdown while browsing instances.
local function DMV_ApplyBrowseModeText(continentDD)
	if not continentDD then return end
	if DMV_InstanceBrowseMode == "dungeon" then
		UIDropDownMenu_SetText(L["Dungeons"], continentDD)
	elseif DMV_InstanceBrowseMode == "raid" then
		UIDropDownMenu_SetText(L["Raids"], continentDD)
	end
end

-- Select the active instance (DMV_InstanceZoneID) in the zone dropdown.
local function DMV_ApplyInstanceZoneText(zoneDD, list)
	local selectedEntry = DMV_InstanceZoneID and list[DMV_InstanceZoneID]
	if zoneDD and selectedEntry then
		UIDropDownMenu_SetSelectedID(zoneDD, DMV_InstanceZoneID)
		UIDropDownMenu_SetText(selectedEntry.name, zoneDD)
	end
end

-- Find the map canvas frame
local function GetMapCanvas()
	if WorldMapDetailFrame then return WorldMapDetailFrame end
	if WorldMapButton then return WorldMapButton end
	if WorldMapFrame.ScrollContainer then return WorldMapFrame.ScrollContainer end
	return WorldMapFrame
end

local DMV_SCALE_MIN, DMV_SCALE_MAX = 0.5, 1.0

local function DMV_ClampScale(s)
	if s < DMV_SCALE_MIN then return DMV_SCALE_MIN end
	if s > DMV_SCALE_MAX then return DMV_SCALE_MAX end
	return s
end

-- Apply user configured scale to the overlay container
function DMV_ApplyContainerLayout()
	if not DMV_Container then return end
	if not DMV_Settings then DMV_Settings = {} end
	local s = DMV_ClampScale(DMV_Settings.overlayScale or 1.0)
	DMV_Container:SetScale(s)
	DMV_Container:ClearAllPoints()
	local canvas = GetMapCanvas()
	DMV_Container:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, 0)
end

-- Generate texture path for a dungeon tile
function DMV_GetTexturePath(dungeonName, floor, tileIndex)
	return "Interface\\AddOns\\DungeonMapsVanilla\\Maps\\" .. dungeonName .. "\\" .. dungeonName .. floor .. "_" .. tileIndex
end

-- Calibration readout for a point dx, dy (DMV_Container units from its top
-- left). Markers use their own coordinate system (percent of the 1024x768
-- tile grid x DMV_MapScale); the coordinate display and the arrow use percent
-- of the visible canvas. Both are printed, labelled, so DungeonData values
-- are not confused with the on-screen coordinates.
local function DMV_CalibCoordsText(dx, dy)
	local canvas = GetMapCanvas()
	return string.format("marker x=%.1f, y=%.1f  (map x=%.1f, y=%.1f)",
		dx / (MAP_W * DMV_MapScale) * 100, dy / (MAP_H * DMV_MapScale) * 100,
		dx / canvas:GetWidth() * 100, dy / canvas:GetHeight() * 100)
end

-- Player arrow in dungeons and raids.
-- Positioned from UnitPosition("player") and the floor's DMV_FloorMapRects entry
-- (GetPlayerMapPosition returns 0,0 inside instances).
local function DMV_CreatePlayerArrow()
	if DMV_PlayerArrow then return end
	if not DMV_Container then return end

	-- Takes the mouse above the markers and member blips. Its image is in
	-- DMV_OverlayDraw's top layer, so it is drawn on top of theirs.
	local arrow = CreateFrame("Frame", "DMV_PlayerArrow", DMV_Container)
	arrow:SetSize(ARROW_SIZE, ARROW_SIZE)
	arrow:SetFrameStrata("FULLSCREEN_DIALOG")
	arrow:SetFrameLevel(DMV_Container:GetFrameLevel() + ARROW_LEVEL)
	arrow:Hide()

	-- Arrow texture: use the minimap arrow atlas if available, else a fallback
	local tex = DMV_CreateOverlayRegion(arrow, "OVERLAY")

	-- Try to use the MinimapArrow atlas (available via ClassicAPI's SetAtlas backport)
	local ok = pcall(function() tex:SetAtlas("MinimapArrow", false) end)
	if not ok or not tex:GetTexture() then
		-- Fallback: use a simple arrow-like texture
		tex:SetTexture("Interface\\Minimap\\MinimapArrow")
	end
	tex:SetVertexColor(1, 1, 1)

	arrow.tex = tex
	arrow:EnableMouse(true)

	arrow:SetScript("OnEnter", function()
		arrow.hovered = true
		DMV_ShowUnitTooltip(arrow)
	end)

	arrow:SetScript("OnLeave", function()
		arrow.hovered = false
		WorldMapTooltip:Hide()
	end)
	DMV_BindImages(arrow, function() tex:Show() end, function() tex:Hide() end)
	arrow:SetScript("OnHide", function()
		if arrow.hovered then
			arrow.hovered = false
			WorldMapTooltip:Hide()
		end
	end)

	DMV_PlayerArrow = arrow
	-- Keeps the mouse order and Atlas on top (both defined below).
	DMV_ApplyOverlayLevels()
end

-- Instance cache: the instance can only change behind a loading screen, so
-- GetInstanceInfo() is read once per PLAYER_ENTERING_WORLD instead of every
-- frame. Until the first refresh it is read live.
local DMV_InstCacheValid, DMV_InstCacheType, DMV_InstCacheMapID = false, nil, nil

function DMV_RefreshInstanceCache()
	local _, instanceType, _, _, _, _, _, instanceMapID = GetInstanceInfo()
	DMV_InstCacheType, DMV_InstCacheMapID = instanceType, instanceMapID
	DMV_InstCacheValid = true
end

-- Returns instanceType, instanceMapID.
function DMV_GetInstanceCached()
	if not DMV_InstCacheValid then DMV_RefreshInstanceCache() end
	return DMV_InstCacheType, DMV_InstCacheMapID
end

-- Forget the player's map position. Called on every path that does not draw
-- the arrow (another floor, preview, map closed, off the map), so the player
-- coordinates never keep showing an old value.
local function DMV_ClearPlayerMapPos()
	DMV_LastPlayerMapPos = nil
end

-- Atlas opened from a marker is raised to FULLSCREEN_DIALOG, the strata of
-- DMV's mouse frames. Raise it above them again whenever DMV moves or adds
-- one, so the mouse over the Atlas window goes to Atlas, not to a marker
-- under it. Only while the Atlas window DMV opened is shown, and only when
-- one of DMV's frames is not already below it: every Raise makes the client
-- re-sort the strata, and this also runs on every world map update.
local DMV_RAISE_CONTROLS = {
	"DMV_ClickFrame", "DMV_LevelDropDown", "DMV_LevelDropDownButton",
	"DMV_LevelUpButton", "DMV_LevelDownButton",
	"DMV_BossPinDropDown", "DMV_BossPinDropDownButton",
}

local function DMV_AboveLevel(f, level)
	return f and f:GetFrameStrata() == "FULLSCREEN_DIALOG" and f:GetFrameLevel() >= level
end

local function DMV_AnyFrameAbove(level)
	if DMV_AboveLevel(DMV_PlayerArrow, level) then return true end
	for i = 1, table.getn(DMV_PartyBlips) do
		if DMV_AboveLevel(DMV_PartyBlips[i], level) then return true end
	end
	for _, pin in pairs(DMV_BossPins) do
		if DMV_AboveLevel(pin, level) then return true end
	end
	for i = 1, table.getn(DMV_RAISE_CONTROLS) do
		if DMV_AboveLevel(getglobal(DMV_RAISE_CONTROLS[i]), level) then return true end
	end
	return false
end

function DMV_RaiseAtlas()
	local af = AtlasFrame
	if af and af.DMV_OnTop and af.Raise and af:IsVisible()
		and DMV_AnyFrameAbove(af:GetFrameLevel()) then
		af:Raise()
	end
end

-- Put the marker, member blip and player arrow frames back at their levels
-- above DMV_Container (they decide which one gets the mouse). On the 1.12
-- client SetFrameStrata also moves a frame back to its parent's level + 1.
-- Only levels that differ are set: every change makes the client re-sort
-- the strata.
local function DMV_SetLevel(f, level)
	if f:GetFrameLevel() ~= level then f:SetFrameLevel(level) end
end

-- True while the mouse order still holds: DMV_ClickFrame < every marker <
-- every member blip < the player arrow. The client may renumber levels on
-- its own (keeping their order); that must not be undone on every map
-- update, or each update would push DMV above a raised Atlas window again.
local function DMV_OverlayLevelsInOrder()
	local below = -1
	local click = DMV_ClickFrame
	if click and click:GetFrameStrata() == "FULLSCREEN_DIALOG" then below = click:GetFrameLevel() end
	local top = below
	for _, pin in pairs(DMV_BossPins) do
		local l = pin:GetFrameLevel()
		if l <= below then return false end
		if l > top then top = l end
	end
	below = top
	for i = 1, table.getn(DMV_PartyBlips) do
		local l = DMV_PartyBlips[i]:GetFrameLevel()
		if l <= below then return false end
		if l > top then top = l end
	end
	if DMV_PlayerArrow and DMV_PlayerArrow:GetFrameLevel() <= top then return false end
	return true
end

function DMV_ApplyOverlayLevels()
	local c = DMV_Container
	if not c then return end
	if DMV_OverlayLevelsInOrder() then
		DMV_RaiseAtlas()
		return
	end
	local base = c:GetFrameLevel()
	for _, pin in pairs(DMV_BossPins) do DMV_SetLevel(pin, base + PIN_LEVEL) end
	for i = 1, table.getn(DMV_PartyBlips) do DMV_SetLevel(DMV_PartyBlips[i], base + BLIP_LEVEL) end
	if DMV_PlayerArrow then DMV_SetLevel(DMV_PlayerArrow, base + ARROW_LEVEL) end
	DMV_RaiseAtlas()
end

local function DMV_HidePlayerArrow()
	DMV_ClearPlayerMapPos()
	if DMV_PlayerArrow then DMV_PlayerArrow:Hide() end
end

function DMV_UpdatePlayerArrow()
	local arrow = DMV_PlayerArrow
	if not arrow or not DMV_Container then return end
	if not DMV_Visible or not DMV_CurrentDungeon or DMV_PreviewMode then DMV_HidePlayerArrow(); return end

	local _, instanceMapID = DMV_GetInstanceCached()
	if not instanceMapID then DMV_HidePlayerArrow(); return end

	-- Drawn on the player's own floor, and on an overview floor whose map
	-- also covers it (Naxxramas floor 5), as member blips are.
	if DMV_CurrentFloor ~= DMV_ActualFloor
	   and not (DMV_FS and DMV_FS.FloorVisibleOn
				and DMV_FS.FloorVisibleOn(instanceMapID, DMV_ActualFloor, DMV_CurrentFloor)) then
		DMV_HidePlayerArrow(); return
	end

	local posY, posX = UnitPosition("player")
	if not posY or not posX then DMV_HidePlayerArrow(); return end

	local floorRects = DMV_FloorMapRects and DMV_FloorMapRects[instanceMapID]
	local rect = floorRects and floorRects[DMV_CurrentFloor]
	if not rect or not rect.locLeft then DMV_HidePlayerArrow(); return end

	local width  = rect.locLeft - rect.locRight
	local height = rect.locTop  - rect.locBottom

	if width == 0 or height == 0 then DMV_HidePlayerArrow(); return end

	local mapX = (rect.locLeft - posY) / width  * 100
	local mapY = (rect.locTop  - posX) / height * 100

	if mapX < 0 or mapX > 100 or mapY < 0 or mapY > 100 then
		DMV_HidePlayerArrow(); return
	end

	-- Read by DMV's player coordinate display and by third-party addons.
	-- One table is reused because this runs every frame while the map is open.
	DMV_PlayerMapPosBuf.x = mapX
	DMV_PlayerMapPosBuf.y = mapY
	DMV_LastPlayerMapPos = DMV_PlayerMapPosBuf

	-- No frame level is set here. The arrow's image is in DMV_OverlayDraw's
	-- top layer, and setting a level every frame fought the client's own
	-- level renumbering (Atlas window lag, arrow over Atlas).

	-- Map percentages are relative to the visible canvas (WorldMapDetailFrame,
	-- 1002x668); the 1024x768 tile grid overhangs it, as stock map tiles do.
	local canvas = GetMapCanvas()
	local px =  (mapX / 100) * canvas:GetWidth()
	local py = -(mapY / 100) * canvas:GetHeight()

	-- Anchor and rotation are only touched when they change.
	if not arrow.px or math.abs(px - arrow.px) > 0.01 or math.abs(py - arrow.py) > 0.01 then
		arrow:ClearAllPoints()
		arrow:SetPoint("CENTER", DMV_Container, "TOPLEFT", px, py)
		arrow.px, arrow.py = px, py
	end

	local facing = GetPlayerFacing and GetPlayerFacing() or 0
	if facing ~= arrow.facing and arrow.tex.SetRotation then
		arrow.tex:SetRotation(facing)
		arrow.facing = facing
	end

	arrow:Show()
end

-- Party member blips
DMV_PartyBlips = {}
DMV_BLIP_SIZE = 8

local BLIP_TEX_PARTY = "Interface\\AddOns\\DungeonMapsVanilla\\Assets\\partymember"
local BLIP_TEX_RAID  = "Interface\\AddOns\\DungeonMapsVanilla\\Assets\\raidmember"
-- Member blips are fully refreshed (roster, names, floors, textures,
-- visibility) at 20 Hz. In between, the blips already shown only follow
-- their members' positions (DMV_MovePartyBlips), every frame like the arrow.
local BLIP_REFRESH   = 0.05
local BLIP_MOVE_EPS  = 0.1	-- re-anchor a blip only after it moved this many screen pixels
local DMV_BlipElapsed = 0	-- time since the last blip refresh

-- Set by the last full refresh, read by DMV_MovePartyBlips: the number of
-- blip slots in use and the floor rect / canvas size they were placed with.
local DMV_BlipMoveCount = 0
local DMV_BlipLocLeft, DMV_BlipLocTop, DMV_BlipW, DMV_BlipH = 0, 0, 1, 1
local DMV_BlipCanvasW, DMV_BlipCanvasH, DMV_BlipEps = 0, 0, BLIP_MOVE_EPS

-- Unit tokens and per-frame work lists, built once and reused every frame.
local DMV_RAID_UNITS, DMV_PARTY_UNITS = {}, {}
for i = 1, 40 do DMV_RAID_UNITS[i] = "raid" .. i end
for i = 1, 4 do DMV_PARTY_UNITS[i] = "party" .. i end
local DMV_BlipUnits, DMV_BlipSameParty, DMV_RaidSubgroups = {}, {}, {}
-- Class per unit token. A token only changes owner on a roster change, so
-- this is cleared on every roster refresh; unknown classes are retried.
local DMV_UnitClassCache = {}

-- Raid roster cache: subgroups and the player's own row are re-read only when
-- the roster changes (RAID_ROSTER_UPDATE / PARTY_MEMBERS_CHANGED / entering
-- the world), not every frame while the map is open.
local DMV_RosterDirty = true
local DMV_RosterNumRaid, DMV_RosterPlayerIndex, DMV_RosterPlayerSubgroup = 0, nil, nil

local function DMV_RefreshRosterCache()
	local numRaid = GetNumRaidMembers()
	local playerName = UnitName("player")
	local playerIndex, playerSubgroup = nil, nil
	for i = 1, numRaid do
		local name, _, subgroup = GetRaidRosterInfo(i)
		DMV_RaidSubgroups[i] = subgroup
		-- Unit tokens can lag behind the roster while it is being rebuilt, so
		-- the roster name is checked as well.
		if not playerIndex and (UnitIsUnit(DMV_RAID_UNITS[i], "player")
				or (name and name == playerName)) then
			playerIndex, playerSubgroup = i, subgroup
		end
	end
	for i = numRaid + 1, 40 do DMV_RaidSubgroups[i] = nil end
	for k in pairs(DMV_UnitClassCache) do DMV_UnitClassCache[k] = nil end
	DMV_RosterNumRaid = numRaid
	DMV_RosterPlayerIndex, DMV_RosterPlayerSubgroup = playerIndex, playerSubgroup
	-- Without the player's own row every member would get the raid texture
	-- and the player a blip under the arrow: read the roster again next time.
	DMV_RosterDirty = numRaid > 0 and not playerIndex
end

local DMV_RosterEventFrame = CreateFrame("Frame", "DMV_RosterEventFrame")
DMV_RosterEventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
DMV_RosterEventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
DMV_RosterEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
DMV_RosterEventFrame:SetScript("OnEvent", function()
	DMV_RosterDirty = true
	DMV_BlipElapsed = BLIP_REFRESH	-- redraw the blips on the next frame
end)

-- Tooltip listing every group member under the cursor (player arrow
-- included), as the stock world map does for stacked party members.
function DMV_ShowUnitTooltip(owner)
	local text
	local arrow = DMV_PlayerArrow
	if arrow and arrow:IsVisible() and (arrow == owner or (MouseIsOver and MouseIsOver(arrow))) then
		text = UnitName("player")
	end
	for i = 1, table.getn(DMV_PartyBlips) do
		local blip = DMV_PartyBlips[i]
		if blip:IsVisible() and blip.name
		   and (blip == owner or (MouseIsOver and MouseIsOver(blip))) then
			text = text and (text .. "\n" .. blip.name) or blip.name
		end
	end
	if not text then WorldMapTooltip:Hide(); return end
	local x = owner:GetCenter()
	local parentX = DMV_Container:GetCenter()
	WorldMapTooltip:SetOwner(owner, (x and parentX and x > parentX) and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
	WorldMapTooltip:SetText(text)
	WorldMapTooltip:Show()
end

local function DMV_GetOrCreateBlip(i)
	if DMV_PartyBlips[i] then return DMV_PartyBlips[i] end
	if not DMV_Container then return nil end

	-- Takes the mouse above the markers (container +15), below the player
	-- arrow (+20). Its image is in DMV_OverlayDraw's ARTWORK layer.
	local blip = CreateFrame("Frame", "DMV_PartyBlip"..i, DMV_Container)
	blip:SetSize(DMV_BLIP_SIZE, DMV_BLIP_SIZE)
	blip:SetFrameStrata("FULLSCREEN_DIALOG")
	blip:SetFrameLevel(DMV_Container:GetFrameLevel() + BLIP_LEVEL)
	blip:Hide()

	local tex = DMV_CreateOverlayRegion(blip, "ARTWORK")
	tex:SetTexture(BLIP_TEX_PARTY)
	blip.tex = tex

	blip:EnableMouse(true)
	blip:SetScript("OnEnter", function()
		blip.hovered = true
		DMV_ShowUnitTooltip(blip)
	end)
	blip:SetScript("OnLeave", function()
		blip.hovered = false
		WorldMapTooltip:Hide()
	end)
	DMV_BindImages(blip, function() tex:Show() end, function() tex:Hide() end)
	blip:SetScript("OnHide", function()
		blip.live = false
		if blip.hovered then
			blip.hovered = false
			WorldMapTooltip:Hide()
		end
	end)

	DMV_PartyBlips[i] = blip
	DMV_ApplyOverlayLevels()
	return blip
end

local function DMV_HideBlips(fromIndex)
	fromIndex = fromIndex or 1
	for i = fromIndex, table.getn(DMV_PartyBlips) do
		local blip = DMV_PartyBlips[i]
		blip.live = false
		blip:Hide()
	end
	if DMV_BlipMoveCount >= fromIndex then DMV_BlipMoveCount = fromIndex - 1 end
end

-- Between full refreshes: move the blips that are shown from the client's
-- own position of their member (live). Nothing else is read or changed, so
-- this costs one UnitPosition per shown blip, and a re-anchor only when it
-- moved. Blips placed from a DMV broadcast are left to the full refresh
-- (broadcasts arrive at most once a second).
local function DMV_MovePartyBlips()
	local n = DMV_BlipMoveCount
	if n == 0 then return end
	local left, top, width, height = DMV_BlipLocLeft, DMV_BlipLocTop, DMV_BlipW, DMV_BlipH
	local canvasW, canvasH, moveEps = DMV_BlipCanvasW, DMV_BlipCanvasH, DMV_BlipEps
	local abs = math.abs
	for i = 1, n do
		local blip = DMV_PartyBlips[i]
		if blip and blip.live then
			local posY, posX = UnitPosition(blip.unit)
			if posY and posX then
				-- Same arithmetic as the full refresh.
				local mapX = (left - posY) / width  * 100
				local mapY = (top  - posX) / height * 100
				if mapX >= 0 and mapX <= 100 and mapY >= 0 and mapY <= 100 then
					local px, py = (mapX / 100) * canvasW, -(mapY / 100) * canvasH
					if abs(px - blip.px) > moveEps or abs(py - blip.py) > moveEps then
						blip:ClearAllPoints()
						blip:SetPoint("CENTER", DMV_Container, "TOPLEFT", px, py)
						blip.px, blip.py = px, py
					end
				end
			end
		end
	end
end

function DMV_UpdatePartyBlips()
	if not DMV_Container then return end
	if not DMV_Visible or not DMV_CurrentDungeon or DMV_PreviewMode then DMV_HideBlips(); return end
	local showParty = not (DMV_Settings and DMV_Settings.showPartyBlips == false)
	local showRaid  = not (DMV_Settings and DMV_Settings.showRaidBlips  == false)
	if not showParty and not showRaid then DMV_HideBlips(); return end

	-- Without the floor-sync module the old rule applies: members are only
	-- drawn while the player views their own floor. With it, each member is
	-- drawn on the floor they are known to be on (see DMV_FloorSync.lua).
	local shouldShow = DMV_FS_ShouldShowUnit
	local syncedPos = DMV_FS_GetSyncedPosition
	if not shouldShow and DMV_CurrentFloor ~= DMV_ActualFloor then DMV_HideBlips(); return end

	local _, instanceMapID = DMV_GetInstanceCached()
	if not instanceMapID then DMV_HideBlips(); return end

	local floorRects = DMV_FloorMapRects and DMV_FloorMapRects[instanceMapID]
	local rect = floorRects and floorRects[DMV_CurrentFloor]
	if not rect or not rect.locLeft then DMV_HideBlips(); return end

	local width  = rect.locLeft - rect.locRight
	local height = rect.locTop  - rect.locBottom
	if width == 0 or height == 0 then DMV_HideBlips(); return end

	local canvas = GetMapCanvas()
	local canvasW = canvas:GetWidth()
	local canvasH = canvas:GetHeight()
	-- Movement threshold in canvas units: constant on screen at any zoom.
	local moveEps = BLIP_MOVE_EPS / (canvas:GetScale() or 1)

	-- Collect the units to draw. The player's subgroup is taken from the
	-- roster row whose unit is the player, so UnitInRaid's index base
	-- does not matter.
	local numUnits = 0
	if DMV_RosterDirty then DMV_RefreshRosterCache() end
	local numRaid = DMV_RosterNumRaid
	if numRaid > 0 then
		local playerIndex, playerSubgroup = DMV_RosterPlayerIndex, DMV_RosterPlayerSubgroup
		for i = 1, numRaid do
			if i ~= playerIndex then
				local isPartyMember = (DMV_RaidSubgroups[i] == playerSubgroup)
				if (isPartyMember and showParty) or (not isPartyMember and showRaid) then
					numUnits = numUnits + 1
					DMV_BlipUnits[numUnits] = DMV_RAID_UNITS[i]
					DMV_BlipSameParty[numUnits] = isPartyMember
				end
			end
		end
	elseif showParty then
		for i = 1, GetNumPartyMembers() do
			numUnits = numUnits + 1
			DMV_BlipUnits[numUnits] = DMV_PARTY_UNITS[i]
			DMV_BlipSameParty[numUnits] = true
		end
	end

	DMV_HideBlips(numUnits + 1)

	-- Geometry for DMV_MovePartyBlips until the next full refresh.
	DMV_BlipLocLeft, DMV_BlipLocTop, DMV_BlipW, DMV_BlipH = rect.locLeft, rect.locTop, width, height
	DMV_BlipCanvasW, DMV_BlipCanvasH, DMV_BlipEps = canvasW, canvasH, moveEps
	DMV_BlipMoveCount = numUnits

	for i = 1, numUnits do
		local unit = DMV_BlipUnits[i]
		local blip = DMV_GetOrCreateBlip(i)
		if not blip then DMV_BlipMoveCount = i - 1; break end
		local name = UnitName(unit)
		local posY, posX = UnitPosition(unit)
		local remoteOnly = false
		if not posY or not posX then
			posY, posX = nil, nil
			-- Out of client range: use the position the member's DMV broadcast,
			-- unless the member has gone offline since.
			if syncedPos and name and UnitIsConnected(unit) then
				posY, posX = syncedPos(name, instanceMapID)
				remoteOnly = posY ~= nil
			end
		end
		local mapX, mapY
		if posY and posX and (not shouldShow
				or shouldShow(name, instanceMapID, DMV_CurrentFloor, DMV_ActualFloor, remoteOnly)) then
			mapX = (rect.locLeft - posY) / width  * 100
			mapY = (rect.locTop  - posX) / height * 100
			if mapX < 0 or mapX > 100 or mapY < 0 or mapY > 100 then mapX = nil end
		end
		if not mapX then
			blip.live = false
			blip:Hide()
		else
			-- A blip slot can be reassigned to another member when the
			-- roster changes, so unit, type and class are all compared;
			-- texture and color are only touched when one of them differs.
			local isParty = DMV_BlipSameParty[i] and true or false
			if blip.isParty ~= isParty then
				blip.tex:SetTexture(isParty and BLIP_TEX_PARTY or BLIP_TEX_RAID)
				blip.isParty = isParty
			end
			local class = DMV_UnitClassCache[unit]
			if not class then
				local _, c = UnitClass(unit)
				class = c or false
				if c then DMV_UnitClassCache[unit] = c end
			end
			if blip.class ~= class then
				local color = class and RAID_CLASS_COLORS[class]
				if color then
					blip.tex:SetVertexColor(color.r, color.g, color.b, 1)
				else
					blip.tex:SetVertexColor(1, 1, 1, 1)
				end
				blip.class = class
			end
			blip.unit = unit
			local nameChanged = blip.name ~= name
			blip.name = name
			local px, py = (mapX / 100) * canvasW, -(mapY / 100) * canvasH
			if not blip.px or math.abs(px - blip.px) > moveEps or math.abs(py - blip.py) > moveEps then
				blip:ClearAllPoints()
				blip:SetPoint("CENTER", DMV_Container, "TOPLEFT", px, py)
				blip.px, blip.py = px, py
			end
			blip.live = not remoteOnly
			blip:Show()
			-- Slot now shows another member: refresh the open tooltip.
			if nameChanged and blip.hovered then DMV_ShowUnitTooltip(blip) end
		end
	end
end


-- The refresh ticker lives on its own frame. It used to sit on the player
-- arrow, but the arrow is hidden while viewing another floor, and hidden
-- frames never run OnUpdate, so member blips froze on non-player floors.
local DMV_RefreshTicker = nil

local function DMV_StartArrowUpdates()
	DMV_CreatePlayerArrow()
	if not DMV_PlayerArrow then return end
	if not DMV_RefreshTicker then
		DMV_RefreshTicker = CreateFrame("Frame", "DMV_RefreshTicker")
		DMV_RefreshTicker:SetScript("OnUpdate", function(self, elapsed)
			-- Positional elapsed (ClassicAPI) or the legacy arg1 global.
			elapsed = tonumber(elapsed) or tonumber(arg1) or 0
			if DMV_Visible and DMV_CurrentDungeon and not DMV_PreviewMode then
				DMV_UpdatePlayerArrow()
				DMV_BlipElapsed = DMV_BlipElapsed + elapsed
				if DMV_BlipElapsed >= BLIP_REFRESH then
					DMV_BlipElapsed = 0
					DMV_UpdatePartyBlips()
				else
					DMV_MovePartyBlips()
				end
			end
		end)
	end
	DMV_BlipElapsed = BLIP_REFRESH	-- draw the blips on the first tick
	DMV_RefreshTicker:Show()
end

-- Forget the hover state of the arrow and the blips, and close their
-- tooltip. They are hidden together here when the map closes, from the
-- map's own OnHide, and a frame hidden while its window is already closing
-- gets no OnHide of its own, so the tooltip would otherwise stay open.
local function DMV_ClearUnitHover()
	local any = false
	local arrow = DMV_PlayerArrow
	if arrow and arrow.hovered then arrow.hovered = false; any = true end
	for i = 1, table.getn(DMV_PartyBlips) do
		local blip = DMV_PartyBlips[i]
		if blip.hovered then blip.hovered = false; any = true end
	end
	if any then WorldMapTooltip:Hide() end
end

local function DMV_StopArrowUpdates()
	if DMV_RefreshTicker then DMV_RefreshTicker:Hide() end
	DMV_HidePlayerArrow()
	DMV_HideBlips()
	DMV_ClearUnitHover()
end

-- Create the overlay frames
function DMV_CreateFrames()
	local canvas = GetMapCanvas()
	local baseLevel = canvas:GetFrameLevel()

	-- Scale factor
	local scale = 1
	local tileW = TILE_SIZE * scale
	local tileH = TILE_SIZE * scale

	-- Container frame for overlay and click interception
	local container = CreateFrame("Frame", "DMV_Container", canvas)
	container:SetSize(MAP_W * scale, MAP_H * scale)
	container:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, 0)
	container:SetFrameLevel(baseLevel + 100)
	DMV_Container = container

	-- 12 tile frames inside container
	for i = 1, 12 do
		local col = (i - 1) % MAP_COLS
		local row = math.floor((i - 1) / MAP_COLS)

		local frame = CreateFrame("Frame", "DMV_Frame" .. i, container)
		frame:SetSize(tileW, tileH)
		frame:SetPoint("TOPLEFT", container, "TOPLEFT", col * tileW, -row * tileH)

		local tex = frame:CreateTexture(nil, "OVERLAY")
		tex:SetAllPoints(frame)

		DMV_Frames[i] = frame
		DMV_Textures[i] = tex
	end

	-- Click frame: intercepts right-click BEFORE it reaches the map,
	local clickFrame = CreateFrame("Frame", "DMV_ClickFrame", container)
	clickFrame:SetAllPoints(container)
	clickFrame:SetFrameLevel(baseLevel + 110)
	clickFrame:EnableMouse(true)

	clickFrame:SetScript("OnMouseDown", function(self, button)
		button = button or arg1
		if button == "RightButton" then
			local realDungeon = DMV_GetRealDungeon()
			-- Stage 1: If we are browsing a different map/preview while physically inside a dungeon/raid,
			-- return to the real active instance and synchronize both Continent and Zone dropdown menus.
			if realDungeon and DMV_CurrentDungeon ~= realDungeon then
				local _, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
				local floor = (instanceMapID and DMV_LastKnownFloor[instanceMapID]) or DMV_ActualFloor or 1
				DMV_PreviewMode = false
				
				-- Determine if real instance is a raid (entry[3] is true for raids) and sync browse mode
				local entry = DMV_DungeonByMapID[instanceMapID]
				local isRaid = entry and entry[3] or false
				DMV_InstanceBrowseMode = isRaid and "raid" or "dungeon"
				
				local list = DMV_BuildInstanceList(isRaid)
				DMV_InstanceZoneID = nil
				for i, item in ipairs(list) do
					if item.mapID == instanceMapID then
						DMV_InstanceZoneID = i
						break
					end
				end

				DMV_SetTextures(realDungeon, floor)
				if WorldMapFrame:IsVisible() then
					DMV_ShowFrames()
				end

				-- Explicitly fix the Continent dropdown text/selection to match Dungeons or Raids
				local continentDD = GetContinentDropdown()
				if continentDD and WorldMapContinentsDropDown_Initialize then
					UIDropDownMenu_Initialize(continentDD, WorldMapContinentsDropDown_Initialize)
					local continents = { GetMapContinents() }
					local targetID = isRaid and (#continents + 2) or (#continents + 1)
					UIDropDownMenu_SetSelectedID(continentDD, targetID)
					UIDropDownMenu_SetText(isRaid and L["Raids"] or L["Dungeons"], continentDD)
				end

				-- Explicitly restore the Zone dropdown text and selection to the real instance
				local zoneDD = GetZoneDropdown()
				if zoneDD and DMV_InstanceZoneID then
					UIDropDownMenu_Initialize(zoneDD, WorldMapZoneDropDown_Initialize)
					DMV_ApplyInstanceZoneText(zoneDD, list)
				end
			else
				-- Stage 2: If we are already on our actual dungeon map (or outside a dungeon),
				-- right-clicking clears everything and returns the map to the continent/world view.
				DMV_HideFrames()
				DMV_CurrentDungeon = nil
				DMV_PreviewMode = false
				DMV_ClearBrowseState()
				
				if SetMapToCurrentZone then
					SetMapToCurrentZone()
				end

				-- Reset Continent dropdown to the player's current continent
				local continentDD = GetContinentDropdown()
				if continentDD and WorldMapContinentsDropDown_Initialize then
					UIDropDownMenu_Initialize(continentDD, WorldMapContinentsDropDown_Initialize)
					local continent = GetCurrentMapContinent()
					if continent and continent > 0 then
						UIDropDownMenu_SetSelectedID(continentDD, continent)
						UIDropDownMenu_SetText(select(continent, GetMapContinents()) or "", continentDD)
					end
				end

				-- Reset Zone dropdown intelligently based on where the player physically is
				local zoneDD = GetZoneDropdown()
				if zoneDD then
					UIDropDownMenu_Initialize(zoneDD, WorldMapZoneDropDown_Initialize)

					local currentZone = GetCurrentMapZone()
					if currentZone and currentZone > 0 then
						-- Player is outside in a real zone: restore current zone selection and text
						UIDropDownMenu_SetSelectedID(zoneDD, currentZone)
						UIDropDownMenu_SetText(GetZoneText() or "", zoneDD)
					else
						-- Player is inside a dungeon instance: wipe selection and force text blank
						zoneDD.selectedID = nil
						UIDropDownMenu_SetSelectedID(zoneDD, 0)
						UIDropDownMenu_SetText("", zoneDD)
					end
				end
			end
		elseif button == "LeftButton" then
			if DMV_CalibMode and DMV_Container then
				local csc = DMV_Container:GetEffectiveScale()
				local mx, my = GetCursorPosition()
				mx, my = mx / csc, my / csc
				local dx = mx - DMV_Container:GetLeft()
				local dy = DMV_Container:GetTop() - my
				print("|cff00ff00DMV calib|r: " .. DMV_CalibCoordsText(dx, dy))
			end
		end
	end)

	clickFrame:Hide()
	DMV_ClickFrame = clickFrame

	-- Floor dropdown matching the Continent/Zone dropdowns in size and style.
	local dd = CreateFrame("Frame", "DMV_LevelDropDown", WorldMapFrame, "UIDropDownMenuTemplate")
	dd:SetFrameStrata(WorldMapFrame:GetFrameStrata())
	dd:SetFrameLevel(baseLevel + 120)
	local ddBtn = getglobal("DMV_LevelDropDownButton")
	if ddBtn then
		ddBtn:SetFrameLevel(baseLevel + 122)
		-- Use a dedicated menu so Areas has the same row font, spacing,
		-- checkmarks, and backdrop as the custom Dungeon Markers menu.
		ddBtn:SetScript("OnClick", function() DMV_ToggleAreaList() end)
	end
	UIDropDownMenu_SetWidth(120, dd)
	UIDropDownMenu_SetButtonWidth(125, dd)
	dd:ClearAllPoints()
	dd:SetPoint("TOPRIGHT", WorldMapFrame, "TOPRIGHT", -50, -14)
	dd:Hide()
	DMV_LevelDropDown = dd

	-- "FLOOR" label above the dropdown, identical anchor to CONTINENT/ZONE labels.
	local ddHeader = dd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ddHeader:SetPoint("TOPLEFT", dd, "TOPLEFT", 20, 10)
	ddHeader:SetText(FLOOR or L["Floor"])
	dd.header = ddHeader

	-- Up arrow: previous entry in the floor list (as in 3.3.5a)
	local upBtn = CreateFrame("Button", "DMV_LevelUpButton", WorldMapFrame)
	upBtn:SetSize(16, 16)
	upBtn:SetPoint("TOPLEFT", dd, "TOPRIGHT", -10, 8)
	upBtn:SetFrameLevel(baseLevel + 121)
	upBtn:SetNormalTexture("Interface\\AddOns\\DungeonMapsVanilla\\Assets\\Arrow-Up-Up")
	upBtn:SetPushedTexture("Interface\\AddOns\\DungeonMapsVanilla\\Assets\\Arrow-Up-Down")
	upBtn:SetDisabledTexture("Interface\\AddOns\\DungeonMapsVanilla\\Assets\\Arrow-Up-Disabled")
	upBtn:SetScript("OnClick", function()
		if DMV_CurrentFloor and DMV_CurrentDungeon then
			local floors = DMV_DungeonFloors[DMV_CurrentDungeon]
			if floors then
				for i, f in ipairs(floors) do
					if f == DMV_CurrentFloor and i > 1 then
						DMV_LevelDropDown_SetFloor(floors[i - 1])
						break
					end
				end
			end
		end
	end)
	upBtn:Hide()
	DMV_LevelUpButton = upBtn

	-- Down arrow: next entry in the floor list
	local downBtn = CreateFrame("Button", "DMV_LevelDownButton", WorldMapFrame)
	downBtn:SetSize(16, 16)
	downBtn:SetPoint("BOTTOMLEFT", dd, "BOTTOMRIGHT", -10, 2)
	downBtn:SetFrameLevel(baseLevel + 121)
	downBtn:SetNormalTexture("Interface\\AddOns\\DungeonMapsVanilla\\Assets\\Arrow-Down-Up")
	downBtn:SetPushedTexture("Interface\\AddOns\\DungeonMapsVanilla\\Assets\\Arrow-Down-Down")
	downBtn:SetDisabledTexture("Interface\\AddOns\\DungeonMapsVanilla\\Assets\\Arrow-Down-Disabled")
	downBtn:SetScript("OnClick", function()
		if DMV_CurrentFloor and DMV_CurrentDungeon then
			local floors = DMV_DungeonFloors[DMV_CurrentDungeon]
			if floors then
				for i, f in ipairs(floors) do
					if f == DMV_CurrentFloor and i < #floors then
						DMV_LevelDropDown_SetFloor(floors[i + 1])
						break
					end
				end
			end
		end
	end)
	downBtn:Hide()
	DMV_LevelDownButton = downBtn

	-- Dungeon Markers dropdown
	local bpDd = CreateFrame("Frame", "DMV_BossPinDropDown", WorldMapFrame, "UIDropDownMenuTemplate")
	bpDd:SetPoint("TOPRIGHT", WorldMapFrame, "TOPLEFT", 220, -14)
	bpDd:SetFrameStrata(WorldMapFrame:GetFrameStrata())
	bpDd:SetFrameLevel(baseLevel + 120)
	local bpDdBtn = getglobal("DMV_BossPinDropDownButton")
	if bpDdBtn then bpDdBtn:SetFrameLevel(baseLevel + 122) end
	UIDropDownMenu_SetWidth(120, bpDd)
	UIDropDownMenu_SetButtonWidth(125, bpDd)
	UIDropDownMenu_SetText(L["Filter Markers"], bpDd)

	local bpDdHeader = bpDd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	bpDdHeader:SetPoint("TOPLEFT", bpDd, "TOPLEFT", 20, 10)
	bpDdHeader:SetText(L["Markers"])
	bpDd.header = bpDdHeader

	-- Dungeon Markers uses its own private list frame (DMV_MarkerList), NOT the
	-- shared DropDownList1, so floor changes/Areas refreshes can never touch it.
	if bpDdBtn then
		bpDdBtn:SetScript("OnClick", function()
			DMV_ToggleMarkerList()
		end)
	end

	bpDd:Hide()
	DMV_BossPinDropDown = bpDd
	DMV_CreateMarkerList()

	DMV_Initialized = true
	DMV_ApplyContainerLayout()

	-- Create player arrow now that the container exists
	DMV_CreatePlayerArrow()

	-- Coordinate display frames, anchored to WorldMapDetailFrame.
	-- Shown only while the dungeon map is visible.
	local coordAnchor = GetMapCanvas() or WorldMapFrame

	local cursorFrame = CreateFrame("Frame", "DMV_CoordsFrame", WorldMapFrame)
	cursorFrame:SetWidth(120)
	cursorFrame:SetHeight(20)
	cursorFrame:SetFrameStrata("FULLSCREEN_DIALOG")
	cursorFrame:SetPoint("BOTTOMLEFT", coordAnchor, "BOTTOMLEFT", 10, -24)
	local cursorText = cursorFrame:CreateFontString(nil, "OVERLAY", "GameFontWhite")
	cursorText:SetTextColor(1, 0.82, 0)
	cursorText:SetAllPoints()
	cursorText:SetJustifyH("LEFT")
	cursorFrame.text = cursorText
	cursorFrame:Hide()
	DMV_CoordsFrame = cursorFrame

	local playerFrame = CreateFrame("Frame", "DMV_PlayerCoordsFrame", WorldMapFrame)
	playerFrame:SetWidth(120)
	playerFrame:SetHeight(20)
	playerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
	playerFrame:SetPoint("BOTTOMRIGHT", coordAnchor, "BOTTOMRIGHT", -10, -24)
	local playerText = playerFrame:CreateFontString(nil, "OVERLAY", "GameFontWhite")
	playerText:SetTextColor(1, 0.82, 0)
	playerText:SetAllPoints()
	playerText:SetJustifyH("RIGHT")
	playerFrame.text = playerText
	playerFrame:Hide()
	DMV_PlayerCoordsFrame = playerFrame

	-- Runs on the cursor coordinate frame, which is only shown while the
	-- dungeon map is displayed with coordinates enabled. Text is only
	-- rewritten when the rounded value changes.
	-- The cursor is measured in DMV_Container's space, the same space the
	-- arrow and blips are placed in, so both readouts agree at any
	-- overlayScale (the container is scaled, the canvas is not).
	local lastCX, lastCY, lastPX, lastPY = false, false, false, false
	cursorFrame:SetScript("OnUpdate", function()
		local c = DMV_Container
		local df = GetMapCanvas()
		if c and df then
			local cx, cy = GetCursorPosition()
			local scale  = c:GetEffectiveScale()
			cx = cx / scale
			cy = cy / scale
			local left	 = c:GetLeft()
			local top	 = c:GetTop()
			local width  = df:GetWidth()
			local height = df:GetHeight()
			if left and top and width > 0 and height > 0 then
				local nx = (cx - left) / width
				local ny = (top - cy)  / height
				if nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 then
					local kx, ky = math.floor(nx * 1000 + 0.5), math.floor(ny * 1000 + 0.5)
					if kx ~= lastCX or ky ~= lastCY then
						lastCX, lastCY = kx, ky
						cursorText:SetText(string.format("%s: %.1f / %.1f", L["Cursor"], nx * 100, ny * 100))
					end
				elseif lastCX ~= nil then
					lastCX, lastCY = nil, nil
					cursorText:SetText(L["Cursor"] .. ": " .. NOT_APPLICABLE)
				end
			end
		end

		if DMV_LastPlayerMapPos then
			local x, y = DMV_LastPlayerMapPos.x, DMV_LastPlayerMapPos.y
			local kx, ky = math.floor(x * 10 + 0.5), math.floor(y * 10 + 0.5)
			if kx ~= lastPX or ky ~= lastPY then
				lastPX, lastPY = kx, ky
				playerText:SetText(string.format("%s: %.1f / %.1f", PLAYER, x, y))
			end
		elseif lastPX ~= nil then
			lastPX, lastPY = nil, nil
			playerText:SetText(PLAYER .. ": " .. NOT_APPLICABLE)
		end
	end)
end

-- Set textures for a given dungeon and floor
function DMV_SetTextures(dungeonName, floor)
	if not DMV_Initialized then
		DMV_CreateFrames()
	end

	for i = 1, 12 do
		local path = DMV_GetTexturePath(dungeonName, floor, i)
		DMV_Textures[i]:SetTexture(path)
	end

	if dungeonName ~= DMV_CurrentDungeon or floor ~= DMV_CurrentFloor then
		-- The blips' geometry belongs to the old map: hold them still and
		-- run a full refresh on the next frame.
		DMV_BlipMoveCount = 0
		DMV_BlipElapsed = BLIP_REFRESH
	end
	DMV_CurrentDungeon = dungeonName
	DMV_CurrentFloor = floor
end

-- Apply a floor selection from the Areas list or the arrow buttons.
function DMV_LevelDropDown_SetFloor(floorNum)
	if not DMV_CurrentDungeon then return end
	DMV_SetTextures(DMV_CurrentDungeon, floorNum)
	DMV_UpdateFloorButtons()
	DMV_UpdatePlayerArrow()
	DMV_UpdatePartyBlips()
	DMV_ShowBossPins()
end

-- Populate and show/hide the floor dropdown, mirroring WorldMapLevelDropDown_Update.
function DMV_UpdateFloorButtons()
	if not DMV_LevelDropDown then return end
	local floors = DMV_CurrentDungeon and DMV_DungeonFloors[DMV_CurrentDungeon]
	if not floors or #floors <= 1 then
		CloseDropDownMenus()
		DMV_LevelDropDown:Hide()
		if DMV_LevelUpButton then DMV_LevelUpButton:Hide() end
		if DMV_LevelDownButton then DMV_LevelDownButton:Hide() end
		return
	end

	-- Keep the standard dropdown control for its Blizzard style label and
	-- arrow, but populate the menu through DMV_AreaList (not DropDownList1).
	UIDropDownMenu_SetWidth(120, DMV_LevelDropDown)
	local names = DMV_FloorNames[DMV_CurrentDungeon]
	for i, f in ipairs(floors) do
		if f == DMV_CurrentFloor then
			DMV_LevelDropDown.selectedID = i
			UIDropDownMenu_SetText((names and names[i]) or ("Floor " .. f), DMV_LevelDropDown)
			break
		end
	end
	if DMV_RefreshAreaList then DMV_RefreshAreaList() end

	DMV_LevelDropDown:Show()
	if DMV_LevelUpButton then DMV_LevelUpButton:Show() end
	if DMV_LevelDownButton then DMV_LevelDownButton:Show() end
end

-- Refresh only the Areas dropdown's selected label and, if its own menu is
-- open, its visible checkmarks. Vanilla dropdowns share DropDownList1, so never
-- assume that list belongs to Areas just because it is visible.
local function DMV_UpdateFloorButtonsLive()
	if not DMV_LevelDropDown then return end
	local floors = DMV_CurrentDungeon and DMV_DungeonFloors[DMV_CurrentDungeon]
	if not floors then return end

	local names = DMV_FloorNames[DMV_CurrentDungeon]
	for i, floorNum in ipairs(floors) do
		if floorNum == DMV_CurrentFloor then
			-- Set the frame state and displayed label without reading from the
			-- shared dropdown button pool (which may belong to another menu).
			DMV_LevelDropDown.selectedID = i
			UIDropDownMenu_SetText((names and names[i]) or ("Floor " .. floorNum), DMV_LevelDropDown)
			break
		end
	end

	if DMV_RefreshAreaList then DMV_RefreshAreaList() end
end

-- Areas: dedicated dropdown list
-- Use the same private-list layout as Dungeon Markers rather than Blizzard's
-- shared DropDownList button pool, whose default font and row sizing differ.
local DMV_AREA_ROW_H = 16

function DMV_HideAreaList()
	if DMV_AreaList then DMV_AreaList:Hide() end
end

function DMV_RefreshAreaList()
	local list = DMV_AreaList
	if not list then return end
	local floors = DMV_CurrentDungeon and DMV_DungeonFloors[DMV_CurrentDungeon] or {}
	local names = DMV_CurrentDungeon and DMV_FloorNames[DMV_CurrentDungeon]
	local count = table.getn(floors)

	-- Create rows as needed; keep existing rows to avoid repeatedly creating
	-- frames as the selected dungeon changes.
	for i = 1, count do
		local row = list.rows[i]
		if not row then
			row = CreateFrame("Button", "DMV_AreaListButton" .. i, list)
			row:SetID(i)
			row:SetHeight(DMV_AREA_ROW_H)
			row:SetPoint("TOPLEFT", list, "TOPLEFT", 15, -15 - (i - 1) * DMV_AREA_ROW_H)
			row:SetPoint("RIGHT", list, "RIGHT", -15, 0)
			local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			text:SetPoint("LEFT", row, "LEFT", 30, 0)
			text:SetJustifyH("LEFT")
			row.text = text
			local check = row:CreateTexture(nil, "ARTWORK")
			check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
			check:SetWidth(24); check:SetHeight(24)
			check:SetPoint("LEFT", row, "LEFT", 6, 0)
			row.check = check
			local hl = row:CreateTexture(nil, "BACKGROUND")
			hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
			hl:SetBlendMode("ADD")
			hl:SetAllPoints(row)
			row:SetHighlightTexture(hl)
			row:SetScript("OnClick", function()
				local currentFloors = DMV_CurrentDungeon and DMV_DungeonFloors[DMV_CurrentDungeon]
				local idx = row:GetID()
				local floorNum = currentFloors and currentFloors[idx]
				if floorNum then
					DMV_HideAreaList()
					if IsShiftKeyDown() and not DMV_PreviewMode then
						-- Force the current floor to the selected one, correcting
						-- any mismatch caused by a crash that prevented a proper save.
						local _, instanceMapID = DMV_GetInstanceCached()
						if instanceMapID then
							DMV_ActualFloor = floorNum
							DMV_LastKnownFloor[instanceMapID] = floorNum
							if DMV_Settings then
								DMV_Settings.logoutSnapshot = {
									instanceMapID = instanceMapID,
									floor		  = floorNum,
								}
							end
							DMV_ApplyRealFloorChange(floorNum)
						end
					else
						DMV_LevelDropDown_SetFloor(floorNum)
						DMV_UpdateFloorButtonsLive()
					end
					PlaySound("igMainMenuOptionCheckBoxOn")
				end
			end)
			list.rows[i] = row
		end
		row:SetID(i)
		row.text:SetText((names and names[i]) or ("Floor " .. floors[i]))
		if floors[i] == DMV_CurrentFloor then row.check:Show() else row.check:Hide() end
		row:Show()
	end
	for i = count + 1, table.getn(list.rows) do
		if list.rows[i] then list.rows[i]:Hide() end
	end

	local width = 140
	for i = 1, count do
		local w = (list.rows[i].text:GetStringWidth() or 80) + 70
		if w > width then width = w end
	end
	list:SetWidth(width)
	list:SetHeight(30 + count * DMV_AREA_ROW_H)
end

function DMV_CreateAreaList()
	if DMV_AreaList then return end
	local list = CreateFrame("Button", "DMV_AreaList")
	list:SetFrameStrata("FULLSCREEN_DIALOG")
	list:SetToplevel(true)
	list:EnableMouse(true)
	list:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	list.rows = {}
	list:SetWidth(140)
	list:SetHeight(30)
	list:SetScript("OnShow", function() DMV_RefreshAreaList() end)
	list:Hide()
	DMV_AreaList = list
	tinsert(UISpecialFrames, "DMV_AreaList")
end

function DMV_ToggleAreaList()
	if not DMV_AreaList then DMV_CreateAreaList() end
	local list = DMV_AreaList
	if list:IsShown() then
		list:Hide()
		PlaySound("igMainMenuOptionCheckBoxOn")
		return
	end
	DMV_HideMarkerList()
	CloseDropDownMenus()
	DMV_RefreshAreaList()
	list:ClearAllPoints()
	list:SetPoint("TOPLEFT", "DMV_LevelDropDownLeft", "BOTTOMLEFT", 8, 22)
	list:Show()
	PlaySound("igMainMenuOptionCheckBoxOn")
end

-- Dungeon Markers: dedicated dropdown list
-- Completely independent of Blizzard's shared DropDownList1/2 button pool.
local DMV_MarkerItems = {
	{ kind = "allmarkers",	text = L["AllMarkers"] },
	{ kind = "header",		text = L["MarkerTypes"] },
	{ kind = "toggle",		text = L["BossMarkers"],	key = "bossPins" },
	{ kind = "toggle",		text = L["QuestMarkers"],	key = "bossPinAlt" },
	{ kind = "toggle",		text = L["LootMarkers"],	key = "bossPinLoot" },
	{ kind = "toggle",		text = L["ObjectMarkers"],	key = "bossPinObject" },
	{ kind = "header",		text = FACTION, },
	{ kind = "faction",		text = L["ShowAll"],		value = "all" },
	{ kind = "faction",		text = "|cFF2592C5" .. FACTION_ALLIANCE .. "|r", value = "Alliance" },
	{ kind = "faction",		text = "|cFFE32A19" .. FACTION_HORDE .. "|r",	 value = "Horde" },
}
local DMV_MARKER_ROW_H = 16

local function DMV_MarkerItemChecked(item)
	local st = DMV_Settings or {}
	if item.kind == "allmarkers" then
		return (st.bossPins or st.bossPinAlt or st.bossPinLoot or st.bossPinObject) and true or false
	end
	if item.kind == "toggle" then return st[item.key] and true or false end
	if item.kind == "faction" then return (st.bossFaction or "all") == item.value end
	return false
end

-- Refresh checkmarks purely from DMV_Settings. Safe to call at any time.
function DMV_RefreshMarkerList()
	local list = DMV_MarkerList
	if not list then return end
	for i, item in ipairs(DMV_MarkerItems) do
		local row = list.rows[i]
		if row and row.check then
			if DMV_MarkerItemChecked(item) then row.check:Show() else row.check:Hide() end
		end
	end
end

local function DMV_MarkerRow_OnClick(self)
	-- Classic 1.12's legacy script runner supplies the clicked frame as `this`.
	-- ClassicAPI's modern positional runner supplies it as `self`. Support both.
	local button = self or this
	if not button then return end
	local item = DMV_MarkerItems[button:GetID()]
	if not item then return end
	if not DMV_Settings then DMV_Settings = {} end
	if item.kind == "allmarkers" then
		local enable = not DMV_MarkerItemChecked(item)
		DMV_Settings.bossPins	   = enable
		DMV_Settings.bossPinAlt    = enable
		DMV_Settings.bossPinLoot   = enable
		DMV_Settings.bossPinObject = enable
	elseif item.kind == "toggle" then
		DMV_Settings[item.key] = not DMV_Settings[item.key]
	elseif item.kind == "faction" then
		DMV_Settings.bossFaction = item.value
	end
	if DMV_Visible then DMV_ShowBossPins() end
	DMV_RefreshMarkerList()
end

function DMV_CreateMarkerList()
	if DMV_MarkerList then return end
	local list = CreateFrame("Button", "DMV_MarkerList")
	list:SetFrameStrata("FULLSCREEN_DIALOG")
	list:SetToplevel(true)
	list:EnableMouse(true)
	list:SetBackdrop({
		-- Identical to Blizzard's DropDownList1Backdrop (UIDropDownMenu.xml).
		bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	list.rows = {}

	local width = 140
	for i, item in ipairs(DMV_MarkerItems) do
		local row = CreateFrame("Button", "DMV_MarkerListButton" .. i, list)
		row:SetID(i)
		row:SetHeight(DMV_MARKER_ROW_H)
		row:SetPoint("TOPLEFT", list, "TOPLEFT", 15, -15 - (i - 1) * DMV_MARKER_ROW_H)
		row:SetPoint("RIGHT", list, "RIGHT", -15, 0)

		local text = row:CreateFontString(nil, "ARTWORK",
			item.kind == "header" and "GameFontNormalSmall" or "GameFontHighlightSmall")
		-- Option rows line up with the checked-item text column; the header
		-- ("Faction") sits flush with the checkmark column instead, like
		-- Blizzard's own title rows.
		local textX = (item.kind == "header") and 3 or 30
		text:SetPoint("LEFT", row, "LEFT", textX, 0)
		text:SetJustifyH("LEFT")
		text:SetText(item.text)
		row.text = text
		local w = (text:GetStringWidth() or 80) + 70
		if w > width then width = w end

		if item.kind ~= "header" then
			local check = row:CreateTexture(nil, "ARTWORK")
			check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
			check:SetWidth(24); check:SetHeight(24)
			check:SetPoint("LEFT", row, "LEFT", 6, 0)
			check:Hide()
			row.check = check

			local hl = row:CreateTexture(nil, "BACKGROUND")
			hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
			hl:SetBlendMode("ADD")
			hl:SetAllPoints(row)
			row:SetHighlightTexture(hl)
			row:SetScript("OnClick", DMV_MarkerRow_OnClick)
		else
			row:EnableMouse(false)
		end
		list.rows[i] = row
	end
	list:SetWidth(width)
	list:SetHeight(30 + table.getn(DMV_MarkerItems) * DMV_MARKER_ROW_H)
	list:SetScript("OnShow", function()
		DMV_RefreshMarkerList()
	end)
	list:Hide()
	DMV_MarkerList = list
	tinsert(UISpecialFrames, "DMV_MarkerList")
end

function DMV_HideMarkerList()
	if DMV_MarkerList then DMV_MarkerList:Hide() end
end

function DMV_ToggleMarkerList()
	if not DMV_MarkerList then DMV_CreateMarkerList() end
	local list = DMV_MarkerList
	if list:IsShown() then
		list:Hide()
		PlaySound("igMainMenuOptionCheckBoxOn")
		return
	end
	-- Close the Areas list and any Blizzard dropdown so menus don't overlap.
	DMV_HideAreaList()
	CloseDropDownMenus()
	list:ClearAllPoints()
	-- Match vanilla ToggleDropDownMenu: anchor to the control's left texture,
	-- not its arrow button, using the same offsets as the Areas menu.
	list:SetPoint("TOPLEFT", "DMV_BossPinDropDownLeft", "BOTTOMLEFT", 8, 22)
	list:Show()
	PlaySound("igMainMenuOptionCheckBoxOn")
end

-- Opening any Blizzard dropdown (Areas, Continent, Zone...) closes ours.
local _DMV_origToggleDropDownMenu = ToggleDropDownMenu
ToggleDropDownMenu = function(a1, a2, a3, a4, a5, a6, a7, a8, a9)
	DMV_HideMarkerList()
	DMV_HideAreaList()
	return _DMV_origToggleDropDownMenu(a1, a2, a3, a4, a5, a6, a7, a8, a9)
end


-- Atlas integration: open Atlas to the map page for a dungeon.
-- atlasMapKey must match a key in AtlasMaps (e.g. "ShadowfangKeep", "SMArmory").
-- Atlas has no programmatic scroll-to-boss, so opening the correct map page 
-- is what is being done.
function DMV_OpenAtlasBoss(atlasMapKey)
	if not atlasMapKey then return false end
	-- Detect Atlas by its globals. AtlasMaps is defined in AtlasMaps.lua,
	-- ATLAS_DROPDOWNS and Atlas_Refresh in Atlas.lua, all non-local globals.
	if not AtlasMaps or not AtlasMaps[atlasMapKey] then return false end
	if not ATLAS_DROPDOWNS or not Atlas_Refresh then return false end
	PlaySound("igCharacterInfoOpen")

	-- Atlas_BuildReverseMap and Atlas_DropdownReverseMap are both local to
	-- Atlas.lua and unreachable from here. Iterate ATLAS_DROPDOWNS directly.
	local foundType, foundZone
	for typeIdx, zoneList in pairs(ATLAS_DROPDOWNS) do
		for zoneIdx, mapKey in pairs(zoneList) do
			if mapKey == atlasMapKey then
				foundType = typeIdx
				foundZone = zoneIdx
				break
			end
		end
		if foundType then break end
	end

	if not foundType then return false end

	AtlasOptions.AtlasType = foundType
	AtlasOptions.AtlasZone = foundZone
	Atlas_Refresh()
	-- Raise Atlas above the world map, and put its own strata back when it
	-- closes so later non-DMV opens are unaffected. The hook is installed
	-- here rather than on Atlas's ADDON_LOADED, which normally fires before
	-- DMV has loaded (Atlas is not a dependency).
	if not AtlasFrame.DMV_StrataHooked then
		AtlasFrame.DMV_StrataHooked = true
		AtlasFrame:HookScript("OnHide", function()
			AtlasFrame.DMV_OnTop = nil
			if AtlasFrame.DMV_SavedStrata then
				AtlasFrame:SetFrameStrata(AtlasFrame.DMV_SavedStrata)
				AtlasFrame.DMV_SavedStrata = nil
			end
		end)
	end
	-- The strata is only changed when it differs: on the 1.12 client
	-- SetFrameStrata also drops the frame to its parent's level + 1, which
	-- would put an Atlas window that is already open (a second marker click)
	-- under DMV's marker frames.
	if AtlasFrame:GetFrameStrata() ~= "FULLSCREEN_DIALOG" then
		if not AtlasFrame.DMV_SavedStrata then
			AtlasFrame.DMV_SavedStrata = AtlasFrame:GetFrameStrata()
		end
		AtlasFrame:SetFrameStrata("FULLSCREEN_DIALOG")
	end
	AtlasFrame:Show()
	AtlasFrame.DMV_OnTop = true
	DMV_RaiseAtlas()
	return true
end

-- AtlasLoot integration: open the loot page for a specific boss.
-- The module may load asynchronously, so retry the sub-category/boss
-- selection until the module data is available (bounded).
local DMV_AtlasLootDelayFrame = nil

function DMV_OpenAtlasLootBoss(instanceKey, bossIndex)
	-- AtlasLootBossButtons[instanceKey][bossIndex] > dataID string
	-- AtlasLoot_ShowBossLoot(dataID, bossDisplayText, pFrame)
	-- pFrame = AtlasFrame anchors the loot panel inside the Atlas window.
	if not AtlasLoot_ShowBossLoot or not AtlasLootBossButtons then
		print("|cff00ff00DMV|r: AtlasLoot |cffff0000not installed|r")
		return
	end

	local buttons = AtlasLootBossButtons[instanceKey]
	if not buttons then
		print("|cff00ff00DMV|r: AtlasLoot - unknown instance: " .. tostring(instanceKey))
		return
	end

	local dataID = buttons[bossIndex]
	if not dataID or dataID == "" then
		print("|cff00ff00DMV|r: AtlasLoot - no loot for this index")
		return
	end

	-- Open Atlas to the correct dungeon map first so the loot panel has a
	-- visible parent to anchor to, then display the boss loot inside it.
	local bossText = (AtlasLoot_TableNames and AtlasLoot_TableNames[dataID] and AtlasLoot_TableNames[dataID][1]) or dataID
	DMV_OpenAtlasBoss(instanceKey)
	-- Delay slightly so Atlas finishes its refresh before the loot panel opens.
	-- One frame is reused for every click (frames are never freed).
	local delayFrame = DMV_AtlasLootDelayFrame
	if not delayFrame then
		delayFrame = CreateFrame("Frame")
		DMV_AtlasLootDelayFrame = delayFrame
	end
	delayFrame.timer = 0
	delayFrame:SetScript("OnUpdate", function(self, elapsed)
		-- Positional elapsed (ClassicAPI) or the legacy arg1 global.
		elapsed = tonumber(elapsed) or tonumber(arg1) or 0
		delayFrame.timer = delayFrame.timer + elapsed
		if delayFrame.timer >= 0.1 then
			delayFrame:SetScript("OnUpdate", nil)
			AtlasLoot_ShowBossLoot(dataID, bossText, AtlasFrame)
		end
	end)
end

local DMV_BOSS_PIN_SIZE		   = 32
local DMV_BOSS_PIN_SIZE_ALT    = 16
local DMV_BOSS_HOVER_MULT	   = 1.15
local DMV_BOSS_HOVER_ALPHA	   = 0.5
local DMV_BOSS_PIN_TEXTURE		= "Interface\\AddOns\\DungeonMapsVanilla\\Assets\\boss.tga"
local DMV_BOSS_PIN_TEXTURE_ALT	  = "Interface\\AddOns\\DungeonMapsVanilla\\Assets\\quest.tga"
local DMV_BOSS_PIN_TEXTURE_LOOT   = "Interface\\AddOns\\DungeonMapsVanilla\\Assets\\loot.tga"
local DMV_BOSS_PIN_TEXTURE_OBJECT = "Interface\\AddOns\\DungeonMapsVanilla\\Assets\\object.tga"

-- The marker whose tooltip is open (nil when none).
local DMV_HoveredPin = nil

local function DMV_PinBaseSize(pin)
	return (pin.altTexture or pin.lootTexture or pin.objectTexture) and DMV_BOSS_PIN_SIZE_ALT or DMV_BOSS_PIN_SIZE
end

-- Size a marker for its type and hover state; only resized on change.
local function DMV_ApplyPinSize(pin)
	local size = DMV_PinBaseSize(pin)
	if pin.hovered then size = size * DMV_BOSS_HOVER_MULT end
	if pin.size ~= size then
		pin:SetWidth(size)
		pin:SetHeight(size)
		pin.size = size
	end
end

-- (Re)build the open marker tooltip from the pin's current fields.
local function DMV_ShowPinTooltip(pin)
	WorldMapTooltip:SetOwner(pin, "ANCHOR_RIGHT")
	WorldMapTooltip:AddLine(pin.bossName, 1, 0.82, 0)
	if pin.comment then
		local filtered = DMV_FilterCommentByFaction(pin.comment)
		if filtered then
			local resolved = DMV_ResolveCommentItems(filtered)
			local commentText = "|cff999999" .. string.gsub(resolved, "|r", "|r|cff999999")
			WorldMapTooltip:AddLine(commentText)
		end
	end
	if DMV_CalibMode then
		WorldMapTooltip:AddLine("AtlasLoot #" .. tostring(pin.atlasBossIndex), 0.6, 0.8, 1)
		if pin.removed then
			WorldMapTooltip:AddLine(L["Marker removed"], 1, 0.4, 0.4)
		else
			WorldMapTooltip:AddLine(L["Marker move"], 0.7, 0.7, 0.7)
			WorldMapTooltip:AddLine(L["Marker reset"], 0.7, 0.7, 0.7)
			WorldMapTooltip:AddLine(L["Marker remove"], 0.7, 0.7, 0.7)
		end
	end
	WorldMapTooltip:Show()
end

-- Rebuild the open marker tooltip, e.g. after a name in it was resolved.
local function DMV_RefreshPinTooltip()
	local pin = DMV_HoveredPin
	if pin and pin.hovered and pin:IsVisible() then DMV_ShowPinTooltip(pin) end
end

-- End a calibration drag without saving anything.
local function DMV_CancelPinDrag(pin)
	if pin.isDragging then
		pin.isDragging = false
		pin:SetScript("OnUpdate", nil)
		pin.px = nil	-- the drag moved it: re-anchor on the next refresh
	end
end

-- Hidden mid-drag (map closed, floor changed): drop the drag, otherwise
-- the pin would be saved wherever the cursor is when it shows again.
-- Hover state is dropped too, so a reused pin never keeps the hover size
-- or its glow. Runs from the pin's OnHide, and for every pin when the map
-- closes, so it does not depend on the client sending OnHide to the
-- frames inside a closing window.
local function DMV_ResetPinInteraction(pin)
	if pin.highlight then pin.highlight:Hide() end
	DMV_CancelPinDrag(pin)
	if pin.hovered then
		pin.hovered = false
		DMV_ApplyPinSize(pin)
		if DMV_HoveredPin == pin then
			DMV_HoveredPin = nil
			WorldMapTooltip:Hide()
		end
	end
end

function DMV_ResetPinsOnMapHide()
	for i = 1, table.getn(DMV_BossPins) do DMV_ResetPinInteraction(DMV_BossPins[i]) end
end

-- Boss pins: markers that open AtlasLoot on click
local function DMV_CreateBossPin(pinIndex)
	-- Takes the mouse below the member blips (+18) and the player arrow
	-- (+20). Its images are drawn by DMV_OverlayDraw: the icon in the bottom
	-- layer, the hover glow above every marker icon.
	local pin = CreateFrame("Frame", "DMV_BossPin" .. pinIndex, DMV_Container)
	pin:SetSize(DMV_BOSS_PIN_SIZE, DMV_BOSS_PIN_SIZE)
	pin:SetFrameStrata("FULLSCREEN_DIALOG")
	pin:SetFrameLevel(DMV_Container:GetFrameLevel() + PIN_LEVEL)
	pin:EnableMouse(true)
	pin.size = DMV_BOSS_PIN_SIZE

	local icon = DMV_CreateOverlayRegion(pin, "BACKGROUND")
	icon:SetTexture(DMV_BOSS_PIN_TEXTURE)
	pin.icon = icon

	-- Hover glow: shown only while the marker is hovered.
	local highlight = DMV_CreateOverlayRegion(pin, "BORDER")
	highlight:SetTexture(DMV_BOSS_PIN_TEXTURE)
	highlight:SetBlendMode("ADD")
	highlight:SetAlpha(DMV_BOSS_HOVER_ALPHA)
	highlight:Hide()
	pin.highlight = highlight
	pin.texPath = DMV_BOSS_PIN_TEXTURE

	-- AtlasLoot boss number, shown in calib mode (pin.labelOn)
	local label = DMV_CreateOverlayRegion(pin, "OVERLAY", true)
	label:SetPoint("LEFT", pin, "RIGHT", 1, 0)
	label:SetTextColor(1, 0.9, 0.2)
	label:Hide()
	pin.label = label
	pin.labelOn = false

	pin.bossName = ""
	pin.comment = nil
	pin.atlasKey = nil
	pin.atlasBossIndex = nil
	pin.atlasEntries = nil
	pin.instanceMapID = nil
	pin.bossOrdinal = nil
	pin.isDMVPin = true

	pin.removed = false

	pin:SetScript("OnEnter", function()
		pin.hovered = true
		DMV_HoveredPin = pin
		DMV_ApplyPinSize(pin)
		highlight:Show()
		DMV_ShowPinTooltip(pin)
	end)
	pin:SetScript("OnLeave", function()
		pin.hovered = false
		if DMV_HoveredPin == pin then DMV_HoveredPin = nil end
		DMV_ApplyPinSize(pin)
		highlight:Hide()
		WorldMapTooltip:Hide()
	end)
	DMV_BindImages(pin,
		function()
			icon:Show()
			if pin.labelOn then label:Show() end
		end,
		function()
			icon:Hide()
			label:Hide()
			highlight:Hide()
		end)
	pin:SetScript("OnHide", function() DMV_ResetPinInteraction(pin) end)

	pin:SetScript("OnMouseDown", function(self, button)
		button = button or arg1
		if button == "RightButton" then
			DMV_HideFrames()
			return
		end
		if button ~= "LeftButton" then return end
		if DMV_CalibMode then
			if IsControlKeyDown() and pin.instanceMapID and pin.bossOrdinal then
				if not DMV_GlobalSettings.bossPinOverrides then DMV_GlobalSettings.bossPinOverrides = {} end
				local inst = DMV_GlobalSettings.bossPinOverrides[pin.instanceMapID]
				if not inst then inst = {}; DMV_GlobalSettings.bossPinOverrides[pin.instanceMapID] = inst end
				local e = inst[pin.bossOrdinal]
				if not e then e = {}; inst[pin.bossOrdinal] = e end
				e.removed = not e.removed
				print(string.format("|cff00ff00DMV calib|r: %s %s", pin.bossName,
					e.removed and "|cffff4040removed|r" or "|cff40ff40restored|r"))
				DMV_ShowBossPins()
				return
			end
			if IsShiftKeyDown() and pin.instanceMapID and pin.bossOrdinal then
				local inst = DMV_GlobalSettings.bossPinOverrides
					and DMV_GlobalSettings.bossPinOverrides[pin.instanceMapID]
				if inst then inst[pin.bossOrdinal] = nil end
				print(string.format("|cff00ff00DMV calib|r: %s - position reset (place it on the correct floor)",
					pin.bossName))
				DMV_ShowBossPins()
				return
			end
			pin.isDragging = true
			pin:SetScript("OnUpdate", function(self, elapsed)
				-- The new ClassicAPI runner passes (self, elapsed) positionally;
				-- the old 1.12 runner set `this` as a global with no parameters.
				local s = self or pin
				local csc = DMV_Container:GetEffectiveScale()
				local mx, my = GetCursorPosition()
				mx, my = mx / csc, my / csc
				local maxX = MAP_W * DMV_MapScale
				local maxY = MAP_H * DMV_MapScale
				local dx = math.max(0, math.min(maxX, mx - DMV_Container:GetLeft()))
				local dy = math.max(0, math.min(maxY, DMV_Container:GetTop() - my))
				s:ClearAllPoints()
				s:SetPoint("CENTER", DMV_Container, "TOPLEFT", dx, -dy)
				s.px = nil
				s.calibX = dx / maxX * 100
				s.calibY = dy / maxY * 100
				s.calibDX, s.calibDY = dx, dy
				if not IsMouseButtonDown("LeftButton") then
					s.isDragging = false
					s:SetScript("OnUpdate", nil)
					if s.calibX and s.instanceMapID and s.bossOrdinal then
						local x = tonumber(string.format("%.1f", s.calibX))
						local y = tonumber(string.format("%.1f", s.calibY))
						if not DMV_GlobalSettings.bossPinOverrides then DMV_GlobalSettings.bossPinOverrides = {} end
						local inst = DMV_GlobalSettings.bossPinOverrides[s.instanceMapID]
						if not inst then inst = {}; DMV_GlobalSettings.bossPinOverrides[s.instanceMapID] = inst end
						inst[s.bossOrdinal] = { x, y, DMV_CurrentFloor }
						-- The saved override is in marker units; the map
						-- percentages are printed beside it, as for map clicks.
						print(string.format("|cff00ff00DMV calib|r: %s -> %s, floor %d (saved)",
							s.bossName, DMV_CalibCoordsText(s.calibDX, s.calibDY), DMV_CurrentFloor))
					end
				end
			end)
		elseif pin.atlasKey and pin.atlasEntries then
			-- Multiple boss entries under the same atlas key: pick one at random.
			local idx = pin.atlasEntries[math.random(#pin.atlasEntries)]
			if AtlasLoot_ShowBossLoot and idx and idx ~= 0 then
				DMV_OpenAtlasLootBoss(pin.atlasKey, idx)
			else
				DMV_OpenAtlasBoss(pin.atlasKey)
			end
		elseif pin.atlasKey then
			-- If AtlasLoot is present, open Atlas to the dungeon and show
			-- boss loot. Otherwise just open Atlas to the dungeon map.
			if AtlasLoot_ShowBossLoot and pin.atlasBossIndex and pin.atlasBossIndex ~= 0 then
				DMV_OpenAtlasLootBoss(pin.atlasKey, pin.atlasBossIndex)
			else
				DMV_OpenAtlasBoss(pin.atlasKey)
			end
		end
	end)

	DMV_BossPins[pinIndex] = pin
	DMV_ApplyOverlayLevels()
	return pin
end

-- Hide markers from index `fromIndex` (default: all of them).
local function DMV_HidePinsFrom(fromIndex)
	for i = fromIndex or 1, table.getn(DMV_BossPins) do
		DMV_BossPins[i]:Hide()
	end
end

function DMV_HideBossPins()
	DMV_HidePinsFrom(1)
end

-- Look up the instanceMapID for a dungeon texture folder name in
-- DMV_DungeonByMapID (folder names are unique). Used in preview mode, where
-- GetInstanceInfo() returns the player's real location, not the previewed one.
local function DMV_GetInstanceIdForDungeon(name)
	if not name then return nil end
	if DMV_DungeonByMapID then
		for id, entry in pairs(DMV_DungeonByMapID) do
			if entry[1] == name then
				return id
			end
		end
	end
	return nil
end

-- Resolve a name from a prefixed ID string.
-- Returns the name string if cached, nil if the request is still pending.
-- As a side effect, issues the appropriate RequestLoad call on first encounter.
DMV_ResolveIDName = function(idStr)
	local cached = DMV_NameCache[idStr]
	if cached then return cached end		-- already resolved
	if cached == false then return nil end	-- pending, already requested

	-- Mark as pending immediately to avoid duplicate requests.
	DMV_NameCache[idStr] = false

	local prefix = string.sub(idStr, 1, 1)
	local id = tonumber(string.sub(idStr, 2))
	if not id then
		DMV_NameCache[idStr] = idStr  -- bad format, use raw string
		return idStr
	end

	if prefix == "n" then
		local info = C_CreatureInfo.GetCreatureInfoByID(id)
		if info and info.name then
			DMV_NameCache[idStr] = info.name
			return info.name
		end
		C_CreatureInfo.RequestLoadCreatureByID(id)
	elseif prefix == "o" then
		local info = C_GameObjectInfo.GetGameObjectInfoByID(id)
		if info and info.name then
			DMV_NameCache[idStr] = info.name
			return info.name
		end
		C_GameObjectInfo.RequestLoadGameObjectByID(id)
	elseif prefix == "q" then
		local details = C_QuestLog.GetQuestDetails(id)
		if details and details.title then
			DMV_NameCache[idStr] = { details.title, details.level or 0 }
			return DMV_NameCache[idStr]
		end
		C_QuestLog.RequestLoadQuestByID(id)
	elseif prefix == "i" then
		-- On a cache miss GetItemNameByID itself starts the load, and
		-- GET_ITEM_INFO_RECEIVED fires when the item arrives.
		local iname = C_Item.GetItemNameByID(id)
		if iname then
			DMV_NameCache[idStr] = { iname, C_Item.GetItemQualityByID(id) or 1 }
			return DMV_NameCache[idStr]
		end
	else
		-- Unknown prefix, use the raw string.
		DMV_NameCache[idStr] = idStr
		return idStr
	end

	-- The RequestLoad* call above may have fired the result event synchronously
	-- (when the data was already in the client cache), in which case the event
	-- handler already populated DMV_NameCache. Recheck before returning nil.
	local resolved = DMV_NameCache[idStr]
	if resolved then return resolved end

	return nil  -- genuinely pending; will refresh via event
end

DMV_FormatItemText = function(entry)
	local iname, quality = entry[1], entry[2]
	local color = DMV_ITEM_QUALITY_COLORS[quality] or DMV_ITEM_QUALITY_COLORS[1]
	return "|c" .. color .. "[" .. iname .. "]|r"
end

DMV_FormatQuestText = function(entry)
	local title, level = entry[1], entry[2]
	local color = GetDifficultyColor(level and level > 0 and level or UnitLevel("player"))
	local hex = string.format("ff%02x%02x%02x",
		math.floor(color.r * 255 + 0.5),
		math.floor(color.g * 255 + 0.5),
		math.floor(color.b * 255 + 0.5))
	local levelStr = level and level > 0 and ("[" .. level .. "] ") or ""
	return "|c" .. hex .. levelStr .. title .. "|r"
end

-- Filter a comment string by faction. Segments separated by "|n" that begin
-- with "!A " are shown only to Alliance; "!H " only to Horde. Segments with
-- no faction prefix are shown to everyone. Returns the filtered string with
-- "|n" re-joined between the surviving segments, or nil if nothing survives.
DMV_PlayerFaction = nil
function DMV_GetFaction()
	if not DMV_PlayerFaction then
		local f = UnitFactionGroup("player")
		if f == "Alliance" or f == "Horde" then
			DMV_PlayerFaction = f
		end
	end
	return DMV_PlayerFaction
end

function DMV_FilterCommentByFaction(comment)
	if not comment then return nil end
	local faction = DMV_GetFaction()
	local parts = {}
	-- split on |n
	for segment in string.gmatch(comment .. "|n", "(.-)|n") do
		local prefix = string.sub(segment, 1, 3)
		if prefix == "!A " then
			if not faction or faction == "Alliance" then
				parts[#parts + 1] = string.sub(segment, 4)
			end
		elseif prefix == "!H " then
			if not faction or faction == "Horde" then
				parts[#parts + 1] = string.sub(segment, 4)
			end
		else
			parts[#parts + 1] = segment
		end
	end
	if #parts == 0 then return nil end
	return table.concat(parts, "|n")
end

-- Replace n/o/q/i <id> tokens in a comment string with resolved names.
-- Items are formatted as colored [Name]; others as plain name text.
-- Tokens still pending are left as is and will resolve on next hover.
-- A token directly after "|" is a "|n" line break followed by a number
-- (e.g. "|n5 i19975"), not an ID, and is left untouched.
DMV_ResolveCommentItems = function(comment)
	return string.gsub(comment, "(|?)([noqi])(%d+)", function(pipe, prefix, digits)
		if pipe ~= "" then return pipe .. prefix .. digits end
		local idStr = prefix .. digits
		local entry = DMV_NameCache[idStr]
		if type(entry) == "table" then
			if prefix == "q" then
				return DMV_FormatQuestText(entry)
			else
				return DMV_FormatItemText(entry)
			end
		elseif type(entry) == "string" then
			-- npc/object: plain name
			return entry
		elseif entry == false then
			return idStr  -- still pending
		else
			-- First encounter: kick off the request and leave token for now.
			DMV_ResolveIDName(idStr)
			return idStr
		end
	end)
end

local function DMV_PinMatchesFloor(pinFloor, currentFloor)
	if type(pinFloor) == "table" then
		for _, floorNum in ipairs(pinFloor) do
			if floorNum == currentFloor then return true end
		end
		return false
	end
	return pinFloor == currentFloor
end

-- Translate L["..."] tokens embedded in marker data strings.
local function DMV_TranslateTokens(str)
	if not str then return nil end
	return (string.gsub(str, 'L%["([^"]+)"%]', function(k) return L[k] or k end))
end

-- Marker data parsed once per instance: translations applied and the
-- type/faction prefixes and ID token split off. Only the ID name lookup
-- (which resolves asynchronously) and the settings filters run per refresh.
local DMV_ParsedMarkers = {}

local function DMV_GetParsedMarkers(instanceMapID)
	local parsed = DMV_ParsedMarkers[instanceMapID]
	if parsed then return parsed end
	local data = DMV_Markers and DMV_Markers[instanceMapID]
	if not data then return nil end
	parsed = {}
	for ordinal, boss in ipairs(data) do
		local displayName = DMV_TranslateTokens(boss[1]) or ""
		local useAltTexture, useLootTexture, useObjectTexture = false, false, false
		local pinFaction = nil  -- nil = no faction, "Alliance" or "Horde"
		local excludeIfAtlas = false
		-- Parse type/faction prefixes in any order. "!" selects quest pins;
		-- "L "/"O " select loot/object pins, with the letter also
		-- accepted directly before an encoded ID. Requiring a delimiter or
		-- ID token prevents ordinary names (e.g. "Lord...") being misread.
		local prefixDone = false
		while not prefixDone do
			local ch = string.sub(displayName, 1, 1)
			if ch == "!" then
				useAltTexture, useLootTexture, useObjectTexture = true, false, false
				displayName = string.sub(displayName, 2)
			elseif ch == "L" and (string.sub(displayName, 2, 2) == " "
				or string.match(displayName, "^L[noqi]%d+")) then
				useAltTexture, useLootTexture, useObjectTexture = false, true, false
				if string.sub(displayName, 2, 2) == " " then
					displayName = string.sub(displayName, 3)
				else
					displayName = string.sub(displayName, 2)
				end
			elseif ch == "O" and (string.sub(displayName, 2, 2) == " "
				or string.match(displayName, "^O[noqi]%d+")) then
				useAltTexture, useLootTexture, useObjectTexture = false, false, true
				if string.sub(displayName, 2, 2) == " " then
					displayName = string.sub(displayName, 3)
				else
					displayName = string.sub(displayName, 2)
				end
			elseif ch == "A" and string.sub(displayName, 2, 2) == " " then
				pinFaction = "Alliance"
				displayName = string.sub(displayName, 3)
			elseif ch == "H" and string.sub(displayName, 2, 2) == " " then
				pinFaction = "Horde"
				displayName = string.sub(displayName, 3)
			elseif ch == "E" and string.sub(displayName, 2, 2) == " " then
				excludeIfAtlas = true
				displayName = string.sub(displayName, 3)
			else
				prefixDone = true
			end
		end
		-- ID-based names: n<id> = NPC, o<id> = object, q<id> = quest,
		-- i<id> = item. Anything after the ID (e.g. " / n3865") is kept.
		local pfx, digits, remainder = string.match(displayName, "^([noqi])(%d+)(.*)")
		parsed[ordinal] = {
			name = displayName,
			idPrefix = pfx,
			idStr = pfx and (pfx .. digits) or nil,
			remainder = remainder,
			x = boss[2], y = boss[3], floor = boss[4],
			atlasKey = boss[5], atlasBossIndex = boss[6],
			comment = DMV_TranslateTokens(boss[7]),
			alt = useAltTexture, loot = useLootTexture, object = useObjectTexture,
			faction = pinFaction, excludeIfAtlas = excludeIfAtlas,
		}
	end
	DMV_ParsedMarkers[instanceMapID] = parsed
	return parsed
end

-- Current display name of a parsed marker (ID names resolve asynchronously).
local function DMV_MarkerDisplayName(m)
	if not m.idStr then return m.name end
	local resolved = DMV_ResolveIDName(m.idStr)
	local base
	if type(resolved) == "table" then
		if m.idPrefix == "q" then
			base = DMV_FormatQuestText(resolved)
		else
			base = DMV_FormatItemText(resolved)
		end
	else
		base = resolved or ("(" .. m.idStr .. ")")
	end
	-- Resolve any further IDs in the remainder.
	return base .. (DMV_ResolveCommentItems(m.remainder))
end

-- Draw the markers for the displayed floor. Markers are updated in place
-- and only surplus ones are hidden, so a refresh never hides the marker
-- under the cursor (which would flicker its tooltip).
function DMV_ShowBossPins()
	local st = DMV_Settings
	if not DMV_Container then return end
	if not st or not DMV_Markers or not (st.bossPins or st.bossPinAlt or st.bossPinLoot or st.bossPinObject) then
		DMV_HidePinsFrom(1); return
	end

	local instanceMapID
	if DMV_PreviewMode and DMV_CurrentDungeon then
		instanceMapID = DMV_GetInstanceIdForDungeon(DMV_CurrentDungeon)
	else
		local _, iid = DMV_GetInstanceCached()
		instanceMapID = iid
	end
	local data = instanceMapID and DMV_GetParsedMarkers(instanceMapID)
	if not data then DMV_HidePinsFrom(1); return end

	local overrides = DMV_GlobalSettings and DMV_GlobalSettings.bossPinOverrides
		and DMV_GlobalSettings.bossPinOverrides[instanceMapID]
	local factionFilter = st.bossFaction or "all"
	local atlasLoaded = Atlas_Refresh ~= nil

	local pinIndex = 0
	for ordinal, m in ipairs(data) do
		local x, y, floor = m.x, m.y, m.floor
		local ov = overrides and overrides[ordinal]
		local removed = false
		local placed = false
		if ov then
			if ov[1] and ov[2] then x, y = ov[1], ov[2]; placed = true end
			if ov[3] then floor = ov[3] end
			removed = ov.removed and true or false
		end
		-- A pin may target one floor (number) or several floors (table).
		-- Overrides still replace the configured floor list with one floor.
		local floorOK
		if DMV_CalibMode then
			floorOK = (not placed) or DMV_PinMatchesFloor(floor, DMV_CurrentFloor)
		else
			floorOK = DMV_PinMatchesFloor(floor, DMV_CurrentFloor)
		end
		local factionOK = (factionFilter == "all") or (m.faction == nil) or (factionFilter == m.faction)
		local typeOK
		if m.alt then typeOK = st.bossPinAlt
		elseif m.loot then typeOK = st.bossPinLoot
		elseif m.object then typeOK = st.bossPinObject
		else typeOK = st.bossPins end

		if (not removed or DMV_CalibMode)
		   and x and y and floorOK
		   and x >= 0 and y >= 0 and x <= 100 and y <= 100
		   and typeOK and factionOK
		   and not (m.excludeIfAtlas and not atlasLoaded) then
			local px = (x / 100) * MAP_W * DMV_MapScale
			local py = -(y / 100) * MAP_H * DMV_MapScale
			local displayName = DMV_MarkerDisplayName(m)

			pinIndex = pinIndex + 1
			local pin = DMV_BossPins[pinIndex] or DMV_CreateBossPin(pinIndex)
			local changed = pin.bossName ~= displayName or pin.comment ~= m.comment
				or pin.removed ~= removed or pin.bossOrdinal ~= ordinal
			if pin.px ~= px or pin.py ~= py then
				pin:ClearAllPoints()
				pin:SetPoint("CENTER", DMV_Container, "TOPLEFT", px, py)
				pin.px, pin.py = px, py
			end
			pin.bossName = displayName
			pin.comment = m.comment
			pin.atlasKey = m.atlasKey
			if type(m.atlasBossIndex) == "table" then
				pin.atlasEntries = m.atlasBossIndex
				pin.atlasBossIndex = nil
			else
				pin.atlasEntries = nil
				pin.atlasBossIndex = m.atlasBossIndex
			end
			pin.instanceMapID = instanceMapID
			pin.bossOrdinal = ordinal
			pin.removed = removed
			pin.altTexture = m.alt
			pin.lootTexture = m.loot
			pin.objectTexture = m.object
			local tex = m.object and DMV_BOSS_PIN_TEXTURE_OBJECT
				or (m.loot and DMV_BOSS_PIN_TEXTURE_LOOT
				or (m.alt and DMV_BOSS_PIN_TEXTURE_ALT or DMV_BOSS_PIN_TEXTURE))
			if pin.texPath ~= tex then
				pin.icon:SetTexture(tex)
				pin.highlight:SetTexture(tex)
				pin.texPath = tex
			end
			DMV_ApplyPinSize(pin)
			if removed then
				pin.icon:SetDesaturated(true)
				pin.icon:SetVertexColor(1, 0.3, 0.3)
			else
				pin.icon:SetDesaturated(false)
				pin.icon:SetVertexColor(1, 1, 1)
			end
			-- The label is drawn by DMV_OverlayDraw, so it is shown here only
			-- for a pin that is already shown; pin:Show() shows it otherwise.
			pin.labelOn = DMV_CalibMode and true or false
			if pin.labelOn then
				pin.label:SetText(tostring(m.atlasBossIndex))
				if pin.dmvImagesShown then pin.label:Show() end
			else
				pin.label:Hide()
			end
			pin:Show()
			if changed and pin.hovered and DMV_HoveredPin == pin then DMV_ShowPinTooltip(pin) end
		end
	end
	DMV_HidePinsFrom(pinIndex + 1)
end

-- Show the dungeon map overlay
function DMV_ShowFrames()
	if not DMV_Initialized then DMV_CreateFrames() end
	if not DMV_Initialized then return end

	DMV_ApplyContainerLayout()

	for i = 1, 12 do
		DMV_Frames[i]:Show()
	end
	if DMV_ClickFrame then DMV_ClickFrame:Show() end

	-- Set visible and start arrow BEFORE anything that could error
	DMV_Visible = true
	if not DMV_PreviewMode then
		DMV_StartArrowUpdates()
		DMV_UpdatePlayerArrow()
	end

	DMV_UpdateFloorButtons()
	if DMV_BossPinDropDown then
		DMV_RefreshMarkerList()
		if not DMV_Settings or DMV_Settings.showMarkersDropdown ~= false then
			DMV_BossPinDropDown:Show()
		end
	end
	-- A marker data error must not stop the rest of the map from showing,
	-- but it is still reported.
	DMV_SafeCall(DMV_ShowBossPins)
	DMV_ApplyOverlayLevels()
	DMV_UpdateCoordsVisibility()
end

-- The coordinate frames are children of WorldMapFrame, so they must be
-- hidden explicitly whenever the dungeon map is not displayed.
function DMV_UpdateCoordsVisibility()
	local show = DMV_Visible and (not DMV_Settings or DMV_Settings.showCoords ~= false)
	if DMV_CoordsFrame then
		if show then DMV_CoordsFrame:Show() else DMV_CoordsFrame:Hide() end
	end
	if DMV_PlayerCoordsFrame then
		if show then DMV_PlayerCoordsFrame:Show() else DMV_PlayerCoordsFrame:Hide() end
	end
end

-- Hide the dungeon map overlay
function DMV_HideFrames()
	if not DMV_Initialized then return end

	for i = 1, 12 do
		DMV_Frames[i]:Hide()
	end
	if DMV_ClickFrame then DMV_ClickFrame:Hide() end
	DMV_HideBossPins()
	if DMV_LevelDropDown then CloseDropDownMenus(); DMV_LevelDropDown:Hide() end
	DMV_HideAreaList()
	if DMV_LevelUpButton then DMV_LevelUpButton:Hide() end
	if DMV_LevelDownButton then DMV_LevelDownButton:Hide() end
	if DMV_BossPinDropDown then DMV_BossPinDropDown:Hide() end
	DMV_HideMarkerList()

	-- Hide and stop arrow updates
	DMV_StopArrowUpdates()

	if DMV_CoordsFrame		 then DMV_CoordsFrame:Hide()	   end
	if DMV_PlayerCoordsFrame then DMV_PlayerCoordsFrame:Hide() end
	DMV_Visible = false

	if DMV_PreviewMode then
		DMV_CurrentDungeon = nil
		DMV_PreviewMode = false
		SetMapToCurrentZone()
	end
end

-- Leaving an instance never closes the world map while outside, so 
-- DMV_OnMapHide never gets the chance to clear the instance browse state that 
-- DMV_OnMapShow set while inside the dungeon.
-- The stale state made the hooked WorldMapZoneDropDown_Initialize keep
-- listing instances, and Blizzard's SetSelectedID(GetCurrentMapZone()) then
-- picked whatever instance sat at the real zone's index. Mirror the cleanup
-- DMV_OnMapHide performs outside instances.
function DMV_ResetBrowseStateOnInstanceExit()
	if not DMV_InstanceBrowseMode and not DMV_InstanceZoneID then return end
	DMV_ClearBrowseState()
	local zoneDD = GetZoneDropdown()
	if zoneDD then
		zoneDD.selectedID = nil
		UIDropDownMenu_Initialize(zoneDD, WorldMapZoneDropDown_Initialize)
	end
end

-- Event handler: Player enters world or instance
function DMV_OnEnterWorld()
	DMV_PreviewMode = false
	local _, instanceType, _, _, _, _, _, instanceMapID = GetInstanceInfo()
	if instanceType == "party" or instanceType == "raid" then
		local dungeonName = DMV_DungeonByMapID[instanceMapID] and DMV_DungeonByMapID[instanceMapID][1]
		if dungeonName then
			DMV_PrevPos.x = nil
			DMV_PrevPos.y = nil
			DMV_PrevPos.z = nil
			local savedFloor = DMV_LastKnownFloor[instanceMapID]
			local floor = savedFloor or 1

			-- Only apply the default floor when there is no saved floor for
			-- this dungeon. If a saved floor exists (e.g. restored from the
			-- logout snapshot), honour it and skip the default override so
			-- the last-saved floor is preserved across relogs.
			if not savedFloor then
				local rects = DMV_FloorMapRects and DMV_FloorMapRects[instanceMapID]
				if rects then
					for floorNum, rect in pairs(rects) do
						if rect.default then
							floor = floorNum
							break
						end
					end
				end
			end

			DMV_ActualFloor = floor
			DMV_LastKnownFloor[instanceMapID] = floor
			DMV_SetTextures(dungeonName, floor)
			if WorldMapFrame:IsVisible() then
				DMV_ShowFrames()
			end
		else
			DMV_CurrentDungeon = nil
			DMV_HideFrames()
			DMV_ResetBrowseStateOnInstanceExit()
		end
	else
		-- Player has left all dungeons. Wipe persisted floor memory so a
		-- future visit starts fresh instead of restoring a stale floor.
		DMV_LastKnownFloor = {}
		if DMV_Settings then DMV_Settings.logoutSnapshot = nil end
		DMV_CurrentDungeon = nil
		DMV_HideFrames()
		DMV_ResetBrowseStateOnInstanceExit()
	end
end

-- Background ticker for coordinate-based floor transitions
-- (subzone-name transitions are handled on ZONE_CHANGED* events).
local DMV_TransitionElapsed = 0
local DMV_TRANSITION_INTERVAL = 0.1  -- 10 checks per second

-- The ticker only runs while the player is inside a supported dungeon/raid.
-- Entering or leaving an instance always passes through a loading screen
-- (PLAYER_ENTERING_WORLD), which is where it is started or stopped, so the
-- per-tick GetInstanceInfo() gate is no longer needed.
local DMV_TransitionTickerRunning = false

local function DMV_TransitionOnUpdate(self, elapsed)
	-- Positional elapsed (ClassicAPI) or the legacy arg1 global.
	elapsed = tonumber(elapsed) or tonumber(arg1) or 0
	DMV_TransitionElapsed = DMV_TransitionElapsed + elapsed
	if DMV_TransitionElapsed >= DMV_TRANSITION_INTERVAL then
		DMV_TransitionElapsed = 0
		DMV_DetectFloorFromPosition()
	end
end

function DMV_StartTransitionTicker()
	if DMV_TransitionTickerRunning then return end
	if not DMV_TransitionFrame then
		DMV_TransitionFrame = CreateFrame("Frame", "DMV_TransitionFrame")
	end
	DMV_TransitionElapsed = 0
	DMV_TransitionFrame:SetScript("OnUpdate", DMV_TransitionOnUpdate)
	DMV_TransitionTickerRunning = true
end

function DMV_StopTransitionTicker()
	if DMV_TransitionFrame then
		DMV_TransitionFrame:SetScript("OnUpdate", nil)
	end
	DMV_TransitionElapsed = 0
	DMV_TransitionTickerRunning = false
end

-- Start the ticker in supported instances, stop it everywhere else.
function DMV_UpdateTransitionTickerState()
	local instanceType, instanceMapID = DMV_GetInstanceCached()
	if (instanceType == "party" or instanceType == "raid")
			and instanceMapID and DMV_DungeonByMapID[instanceMapID]
			and DMV_FloorTransitions and DMV_FloorTransitions[instanceMapID] then
		DMV_StartTransitionTicker()
	else
		DMV_StopTransitionTicker()
	end
end

-- The floor the player is physically on (read by DMV_FloorSync.lua).
function DMV_GetActualFloor()
	return DMV_ActualFloor
end

-- Resolve the dungeon the player is physically inside (never the previewed one).
function DMV_GetRealDungeon()
	local instanceType, instanceMapID = DMV_GetInstanceCached()
	if instanceType ~= "party" and instanceType ~= "raid" then return nil end
	local entry = instanceMapID and DMV_DungeonByMapID[instanceMapID]
	return entry and entry[1]
end

-- Apply a real floor change. If another dungeon is being previewed, leave the
-- preview first and switch the map back to the player's own dungeon.
function DMV_ApplyRealFloorChange(toFloor)
	local realDungeon = DMV_GetRealDungeon()
	if not realDungeon then return end
	if DMV_PreviewMode then
		if DMV_HideMarkerList then DMV_HideMarkerList() end
		CloseDropDownMenus()
		DMV_HideFrames()
		DMV_ClearBrowseState()
		SetMapToCurrentZone()
		local zoneDD = WorldMapZoneDropDown or WorldMapZoneDropdown
		if zoneDD then
			UIDropDownMenu_Initialize(zoneDD, WorldMapZoneDropDown_Initialize)
		end
		DMV_SetTextures(realDungeon, toFloor)
		if WorldMapFrame:IsVisible() then DMV_ShowFrames() end
		return
	end
	DMV_SetTextures(realDungeon, toFloor)
	DMV_UpdateFloorButtonsLive()
	if DMV_Visible then
		DMV_ShowFrames()
	end
end

-- Did one axis cross its threshold between two samples? nil = axis unused.
local function DMV_CheckAxis(prev, cur, threshold, dir)
	if not threshold then return nil end
	if dir == "lt" then
		return prev >= threshold and cur < threshold
	elseif dir == "eq" then
		return math.abs(cur - threshold) < 0.01
	else -- "gt" (default)
		return prev <= threshold and cur > threshold
	end
end

-- Compare area names ignoring spaces and curly vs straight apostrophes.
local function DMV_NormalizeAreaName(s)
	s = string.gsub(s, " ", "")
	s = string.gsub(s, "\226\128\153", "'")	-- U+2019 right single quotation mark
	s = string.gsub(s, "\226\128\152", "'")	-- U+2018 left single quotation mark
	return s
end

-- Fire coordinate-based floor transitions (DMV_FloorTransitions) when the
-- player's world position crosses a threshold since the previous sample.
function DMV_DetectFloorFromPosition()
	if not DMV_GetRealDungeon() then return end
	local _, instanceMapID = DMV_GetInstanceCached()
	if not instanceMapID then return end

	local transitions = DMV_FloorTransitions and DMV_FloorTransitions[instanceMapID]
	if not transitions then return end

	local posY, posX, posZ = UnitPosition("player")
	if not posY or not posX then return end

	local prevX = DMV_PrevPos.x
	local prevY = DMV_PrevPos.y
	local prevZ = DMV_PrevPos.z

	-- Need a previous position to detect crossings
	if not prevX then
		DMV_PrevPos.x = posX
		DMV_PrevPos.y = posY
		DMV_PrevPos.z = posZ
		return
	end

	for _, t in ipairs(transitions) do
		if not t.fromFloor or t.fromFloor == DMV_ActualFloor then

			-- Detect crossing on the primary axis (up to two may be specified;
			-- both must be crossed for the transition to fire).
			local checkAxis = DMV_CheckAxis
			local r1, r2 = nil, nil
			local axisCount = 0

			if t.x then
				r1 = checkAxis(prevX, posX, t.x, t.xDir)
				axisCount = axisCount + 1
			end
			if t.y then
				local r = checkAxis(prevY, posY, t.y, t.yDir)
				if axisCount == 0 then r1 = r else r2 = r end
				axisCount = axisCount + 1
			end
			if t.z then
				if posZ and prevZ then
					local r = checkAxis(prevZ, posZ, t.z, t.zDir)
					if axisCount == 0 then r1 = r else r2 = r end
					axisCount = axisCount + 1
				end
			end

			local crossed = (r1 == true) and (r2 == nil or r2 == true)

			if crossed then
				-- Check bounding region if specified
				local inBounds = true
				if t.xMin and posX < t.xMin then inBounds = false end
				if t.xMax and posX > t.xMax then inBounds = false end
				if t.yMin and posY < t.yMin then inBounds = false end
				if t.yMax and posY > t.yMax then inBounds = false end
				if t.zMin and posZ and posZ < t.zMin then inBounds = false end
				if t.zMax and posZ and posZ > t.zMax then inBounds = false end
				if t.subzone and t.subzoneMode == "condition" then
					local sz = GetMinimapZoneText() or GetSubZoneText() or GetZoneText() or ""
					-- t.subzone is already translated (DungeonData uses L[...]).
					if sz ~= t.subzone
					   and DMV_NormalizeAreaName(sz) ~= DMV_NormalizeAreaName(t.subzone) then
						inBounds = false
					end
				end

				if inBounds then
					local toFloor = t.toFloor
					-- Update prevPos BEFORE returning so the next tick does
					-- not re-evaluate this same crossing with a stale position
					-- and inadvertently chain into the next transition.
					DMV_PrevPos.x = posX
					DMV_PrevPos.y = posY
					DMV_PrevPos.z = posZ
					if toFloor ~= DMV_ActualFloor then
						DMV_LastKnownFloor[instanceMapID] = toFloor
						DMV_ActualFloor = toFloor
						DMV_ApplyRealFloorChange(toFloor)
					end
					return
				end
			end
		end
	end

	-- Update prevPos at the end so the next tick compares from here.
	DMV_PrevPos.x = posX
	DMV_PrevPos.y = posY
	DMV_PrevPos.z = posZ
end

function DMV_OnZoneChanged()
	if not DMV_GetRealDungeon() then return end

	-- Try multiple text sources and both raw and space-stripped keys.
	local candidates = {
		GetMinimapZoneText(),
		GetSubZoneText(),
		GetZoneText(),
	}

	-- Collect all non-empty candidate strings as a set for transition matching,
	-- both raw and normalised (no spaces, straight apostrophes).
	local candidateSet = {}
	for _, subzone in ipairs(candidates) do
		if subzone and subzone ~= "" then
			candidateSet[subzone] = true
			candidateSet[DMV_NormalizeAreaName(subzone)] = true
		end
	end

	-- Check DMV_FloorTransitions for subzone trigger entries (subzoneMode ~= "condition").
	-- These respect fromFloor just like coordinate transitions.
	-- t.subzone is already translated (DungeonData uses L[...]).
	local _, instanceMapID = DMV_GetInstanceCached()
	local transitions = DMV_FloorTransitions and instanceMapID and DMV_FloorTransitions[instanceMapID]
	if transitions then
		for _, t in ipairs(transitions) do
			local tSubzone = t.subzone
			if tSubzone
			   and t.subzoneMode ~= "condition"
			   and (not t.fromFloor or t.fromFloor == DMV_ActualFloor)
			   and (candidateSet[tSubzone] or candidateSet[DMV_NormalizeAreaName(tSubzone)]) then
				local toFloor = t.toFloor
				if toFloor ~= DMV_ActualFloor then
					DMV_LastKnownFloor[instanceMapID] = toFloor
					DMV_ActualFloor = toFloor
					DMV_ApplyRealFloorChange(toFloor)
				end
				return
			end
		end
	end

	-- Subzone name didn't match anything, fall back to position-based detection.
	DMV_DetectFloorFromPosition()
end

-- Cache warmup: MobInfo2 Enhanced style preload for all pin IDs in DungeonData.
-- NPCs/objects/quests: sliding window of concurrent RequestLoad* calls.
-- Each result event calls DMV_PreloadGeneric_Next to keep the window full.
-- Window size matches MobInfo2's MI2_CREATURE_WINDOW (32).
-- Items: one C_Item.GetItemNameByID per OnUpdate frame; on a cache miss it
-- starts the load itself and GET_ITEM_INFO_RECEIVED fires when it lands.
local DMV_PRELOAD_WINDOW  = 32
-- The server silently drops queries for quests it will not send (invalid
-- IDs, quests the character can never take), so no result event ever comes.
-- Requests still unanswered after this many seconds give up their slot.
local DMV_PRELOAD_TIMEOUT = 30

-- Every ID DungeonData references, built once from the static data.
local DMV_RefGeneric, DMV_RefItems, DMV_RefIDs = nil, nil, nil

local function DMV_BuildReferencedIDs()
	if DMV_RefIDs then return end
	DMV_RefGeneric, DMV_RefItems, DMV_RefIDs = {}, {}, {}
	local function addGeneric(idStr)
		if not DMV_RefIDs[idStr] then
			DMV_RefIDs[idStr] = true
			DMV_RefGeneric[table.getn(DMV_RefGeneric) + 1] = idStr
		end
	end
	local function addItem(digits)
		local id = tonumber(digits)
		if id and not DMV_RefIDs["i" .. id] then
			DMV_RefIDs["i" .. id] = true
			DMV_RefItems[table.getn(DMV_RefItems) + 1] = id
		end
	end
	if not DMV_Markers then return end
	for _, data in pairs(DMV_Markers) do
		for _, boss in ipairs(data) do
			-- name field: strip !, A , H  prefixes then check for ID prefix
			local name = boss[1]
			if name then
				name = string.gsub(name, "^!+", "")
				name = string.gsub(name, "^[AH] ", "")
				-- Scan all n/o/q/i tokens from the name field (there may be
				-- multiple, e.g. "n3864 / n3865").
				for p, d in string.gmatch(name, "([noq])(%d+)") do addGeneric(p .. d) end
				for d in string.gmatch(name, "i(%d+)") do addItem(d) end
			end
			-- comment field: scan for all n/o/q/i <id> tokens (same rule as
			-- DMV_ResolveCommentItems: a token right after "|" is not an ID)
			local comment = boss[7]
			if comment then
				for pipe, prefix, digits in string.gmatch(comment, "(|?)([noqi])(%d+)") do
					if pipe ~= "" then
						-- "|n" line break followed by a number
					elseif prefix == "i" then
						addItem(digits)
					else
						addGeneric(prefix .. digits)
					end
				end
			end
		end
	end
end

-- True for IDs DMV itself references or has asked for. Result events for
-- other addons' lookups are ignored: they are not cached and do not trigger
-- marker redraws.
local function DMV_IsTrackedID(idStr)
	DMV_BuildReferencedIDs()
	return DMV_RefIDs[idStr] or DMV_NameCache[idStr] == false
end

-- Generic (n/o/q) queue
local DMV_PreloadQueue	  = nil	 -- array of idStr e.g. "n11324"
local DMV_PreloadPending  = 0	 -- preload requests still waiting for a result
local DMV_PreloadInFlight = {}	 -- [idStr] = GetTime() of the request
local DMV_PreloadTimedOut = {}	 -- [idStr] = true: gave up this session
local DMV_PreloadBusy	  = false
local DMV_PreloadWatchdog = nil	 -- frame shown while requests are in flight

-- Called from the *_DATA_LOAD_RESULT handlers. Only results for requests the
-- preload itself issued free a window slot; results for lazy lookups or other
-- addons' requests must not.
local function DMV_PreloadGeneric_Done(idStr)
	if DMV_PreloadInFlight[idStr] then
		DMV_PreloadInFlight[idStr] = nil
		DMV_PreloadPending = DMV_PreloadPending - 1
		if DMV_PreloadPending <= 0 and DMV_PreloadWatchdog then DMV_PreloadWatchdog:Hide() end
	end
end

local DMV_PreloadGeneric_Next

local function DMV_StartPreloadWatchdog()
	if not DMV_PreloadWatchdog then
		local f = CreateFrame("Frame")
		f.elapsed = 0
		f:SetScript("OnUpdate", function(self, elapsed)
			elapsed = tonumber(elapsed) or tonumber(arg1) or 0
			f.elapsed = f.elapsed + elapsed
			if f.elapsed < 1 then return end
			f.elapsed = 0
			local now = GetTime()
			local expired = false
			for idStr, t in pairs(DMV_PreloadInFlight) do
				if now - t >= DMV_PRELOAD_TIMEOUT then
					DMV_PreloadTimedOut[idStr] = true
					expired = true
				end
			end
			if expired then
				for idStr in pairs(DMV_PreloadTimedOut) do DMV_PreloadGeneric_Done(idStr) end
				DMV_PreloadGeneric_Next()
			end
			if DMV_PreloadPending <= 0 then f:Hide() end
		end)
		DMV_PreloadWatchdog = f
	end
	DMV_PreloadWatchdog:Show()
end

-- Issue one request and track it. Returns false if it was not accepted.
-- RequestLoadQuestByID returns nothing, so a quest request counts as accepted.
local function DMV_PreloadRequest(prefix, id, idStr)
	DMV_PreloadInFlight[idStr] = GetTime()	-- before the call: a cache hit fires the event synchronously
	DMV_PreloadPending = DMV_PreloadPending + 1
	local ok = true
	if prefix == "n" then
		ok = C_CreatureInfo.RequestLoadCreatureByID(id)
	elseif prefix == "o" then
		ok = C_GameObjectInfo.RequestLoadGameObjectByID(id)
	else
		C_QuestLog.RequestLoadQuestByID(id)
	end
	if not ok then
		DMV_PreloadGeneric_Done(idStr)	-- bad input or the engine's pending set is full
		return false
	end
	if DMV_PreloadInFlight[idStr] then DMV_StartPreloadWatchdog() end
	return true
end

DMV_PreloadGeneric_Next = function()
	-- A synchronous result event re-enters here; the running loop already
	-- re-checks the window on every pass, so the nested call can return.
	if DMV_PreloadBusy then return end
	DMV_PreloadBusy = true
	local queue = DMV_PreloadQueue
	while queue and DMV_PreloadPending < DMV_PRELOAD_WINDOW and table.getn(queue) > 0 do
		local n = table.getn(queue)
		local idStr = queue[n]
		queue[n] = nil
		local prefix = string.sub(idStr, 1, 1)
		local id	 = tonumber(string.sub(idStr, 2))
		-- Skip IDs already resolved, in flight or given up; otherwise peek the
		-- client cache before sending a request.
		if not DMV_NameCache[idStr] and not DMV_PreloadInFlight[idStr]
		   and not DMV_PreloadTimedOut[idStr] and id then
			if prefix == "n" then
				local info = C_CreatureInfo.GetCreatureInfoByID(id)
				if info and info.name then
					DMV_NameCache[idStr] = info.name
				elseif not DMV_PreloadRequest(prefix, id, idStr) then
					-- Not accepted: retry it last, after the next result event
					-- (or the next loading screen if nothing is in flight).
					table.insert(queue, 1, idStr)
					break
				end
			elseif prefix == "o" then
				local info = C_GameObjectInfo.GetGameObjectInfoByID(id)
				if info and info.name then
					DMV_NameCache[idStr] = info.name
				elseif not DMV_PreloadRequest(prefix, id, idStr) then
					table.insert(queue, 1, idStr)
					break
				end
			elseif prefix == "q" then
				local details = C_QuestLog.GetQuestDetails(id)
				if details and details.title then
					DMV_NameCache[idStr] = { details.title, details.level or 0 }
				else
					DMV_PreloadRequest(prefix, id, idStr)
				end
			end
		end
	end
	if queue and table.getn(queue) == 0 and DMV_PreloadQueue == queue then
		DMV_PreloadQueue = nil
	end
	DMV_PreloadBusy = false
end

-- Item queue
local DMV_ItemPreloadQueue = nil  -- array of raw item IDs (numbers)
local DMV_ItemPreloadIdx   = 1
local DMV_ItemPreloadFrame = nil  -- one reusable driver frame

local function DMV_ItemPreload_OnUpdate()
	local queue = DMV_ItemPreloadQueue
	if not queue or DMV_ItemPreloadIdx > table.getn(queue) then
		DMV_ItemPreloadFrame:SetScript("OnUpdate", nil)
		DMV_ItemPreloadQueue = nil
		return
	end
	local itemID = queue[DMV_ItemPreloadIdx]
	DMV_ItemPreloadIdx = DMV_ItemPreloadIdx + 1
	local idStr = "i" .. itemID
	if not DMV_NameCache[idStr] then
		-- A cache miss starts the load; GET_ITEM_INFO_RECEIVED caches the name.
		local iname = C_Item.GetItemNameByID(itemID)
		if iname then
			DMV_NameCache[idStr] = { iname, C_Item.GetItemQualityByID(itemID) or 1 }
		end
	end
end

local function DMV_PreloadItems_Start()
	if not DMV_ItemPreloadQueue or table.getn(DMV_ItemPreloadQueue) == 0 then return end
	DMV_ItemPreloadIdx = 1
	if not DMV_ItemPreloadFrame then
		DMV_ItemPreloadFrame = CreateFrame("Frame")
	end
	DMV_ItemPreloadFrame:SetScript("OnUpdate", DMV_ItemPreload_OnUpdate)
end

-- Kick off both queues for every referenced ID that is not resolved yet.
local function DMV_WarmupCache()
	DMV_BuildReferencedIDs()

	-- This runs on every loading screen. A queue that is still draining is
	-- kept (and resumed if a rejected request left nothing in flight), and
	-- IDs that are already resolved are not queued again.
	if DMV_PreloadQueue then
		if DMV_PreloadPending == 0 then DMV_PreloadGeneric_Next() end
	else
		local pending = {}
		for i = 1, table.getn(DMV_RefGeneric) do
			local idStr = DMV_RefGeneric[i]
			if not DMV_NameCache[idStr] and not DMV_PreloadTimedOut[idStr] then
				pending[table.getn(pending) + 1] = idStr
			end
		end
		if table.getn(pending) > 0 then
			DMV_PreloadQueue = pending
			DMV_PreloadGeneric_Next()
		end
	end

	if not DMV_ItemPreloadQueue then
		local pending = {}
		for i = 1, table.getn(DMV_RefItems) do
			if not DMV_NameCache["i" .. DMV_RefItems[i]] then pending[table.getn(pending) + 1] = DMV_RefItems[i] end
		end
		if table.getn(pending) > 0 then
			DMV_ItemPreloadQueue = pending
			DMV_PreloadItems_Start()
		end
	end
end

-- Marker redraw after name lookups resolve. Lookups can complete dozens of
-- times per frame during warmup, so redraws are merged into one per frame.
-- An open marker tooltip is rebuilt too, so names in its comment appear.
local DMV_PinRefreshFrame = CreateFrame("Frame")
DMV_PinRefreshFrame:Hide()
DMV_PinRefreshFrame:SetScript("OnUpdate", function()
	DMV_PinRefreshFrame:Hide()
	if DMV_Visible and DMV_CurrentDungeon then
		DMV_SafeCall(DMV_ShowBossPins)
		DMV_RefreshPinTooltip()
	end
end)

local function DMV_QueuePinRefresh()
	if DMV_Visible and DMV_CurrentDungeon then DMV_PinRefreshFrame:Show() end
end

-- Result of a creature/object/quest lookup.
local function DMV_OnGenericResult(idStr, name)
	if not DMV_IsTrackedID(idStr) then return end
	DMV_NameCache[idStr] = name or idStr	-- failed lookups keep the raw token
	DMV_PreloadTimedOut[idStr] = nil
	DMV_PreloadGeneric_Done(idStr)
	DMV_QueuePinRefresh()
end

-- Main event frame
local EventFrame = CreateFrame("Frame", "DMV_EventFrame", UIParent)

EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
EventFrame:RegisterEvent("PLAYER_LOGOUT")
EventFrame:RegisterEvent("ZONE_CHANGED_INDOORS")
EventFrame:RegisterEvent("ZONE_CHANGED")
EventFrame:RegisterEvent("MINIMAP_UPDATE_ZOOM")
EventFrame:RegisterEvent("WORLD_MAP_UPDATE")
EventFrame:RegisterEvent("CREATURE_DATA_LOAD_RESULT")
EventFrame:RegisterEvent("GAMEOBJECT_DATA_LOAD_RESULT")
EventFrame:RegisterEvent("QUEST_DATA_LOAD_RESULT")
EventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")

EventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
	-- Keep working with both ClassicAPI's positional dispatcher and the
	-- original 1.12 dispatcher, which exposes event payloads as globals.
	event = event or _G.event
	if arg1 == nil then arg1 = _G.arg1 end
	if arg2 == nil then arg2 = _G.arg2 end

	if event == "ADDON_LOADED" and arg1 == "DungeonMapsVanilla" then
		if not DMV_Settings then DMV_Settings = {} end
		if DMV_Settings.bossPins	== nil then DMV_Settings.bossPins	 = true end
		if DMV_Settings.bossPinAlt	== nil then DMV_Settings.bossPinAlt  = true end
		if DMV_Settings.bossPinLoot == nil then DMV_Settings.bossPinLoot = true end
		if DMV_Settings.bossPinObject == nil then DMV_Settings.bossPinObject = true end
		if DMV_Settings.bossFaction == nil then DMV_Settings.bossFaction = "all" end
		if DMV_Settings.overlayScale == nil then DMV_Settings.overlayScale = 1.0 end
		if DMV_Settings.showPartyBlips == nil then DMV_Settings.showPartyBlips = true end
		if DMV_Settings.showRaidBlips  == nil then DMV_Settings.showRaidBlips  = true end
		-- No longer used (the live floor and the logout snapshot cover it).
		DMV_Settings.activeTransition = nil
		if not DMV_GlobalSettings then DMV_GlobalSettings = {} end
		if DMV_GlobalSettings.bossPinOverrides == nil then DMV_GlobalSettings.bossPinOverrides = {} end
		-- ADDON_LOADED is the reliable point at which the addon's code and
		-- saved variables are ready. PLAYER_ENTERING_WORLD remains a retry.
		DMV_CreateInterfaceOptionsPanel()
	elseif event == "PLAYER_ENTERING_WORLD" then
		DMV_CreateInterfaceOptionsPanel()
		-- Reset faction cache so it re-queries once the player is in world.
		DMV_PlayerFaction = nil
		-- Restore floor snapshot saved at logout/reload so DMV_OnEnterWorld
		-- picks up the correct floor via DMV_LastKnownFloor.
		DMV_RefreshInstanceCache()
		local snap = DMV_Settings and DMV_Settings.logoutSnapshot
		if snap and snap.instanceMapID and snap.floor then
			DMV_LastKnownFloor[snap.instanceMapID] = snap.floor
		end
		DMV_OnEnterWorld()
		-- Clear the snapshot after consuming it so a fresh login to a
		-- different dungeon is not affected by stale data.
		if DMV_Settings then DMV_Settings.logoutSnapshot = nil end
		-- Run the transition ticker only inside a supported dungeon/raid.
		DMV_UpdateTransitionTickerState()
		-- Warm up the name cache so all pin names and item comment tokens
		-- are resolved before the player can open the map.
		DMV_WarmupCache()
	elseif event == "PLAYER_LOGOUT" then
		-- Stop the ticker when logging out.
		DMV_StopTransitionTicker()
		if not DMV_Settings then DMV_Settings = {} end
		local instanceType, instanceMapID = DMV_GetInstanceCached()
		if (instanceType == "party" or instanceType == "raid") and instanceMapID then
			DMV_Settings.logoutSnapshot = {
				instanceMapID = instanceMapID,
				floor		  = DMV_ActualFloor,
			}
		else
			DMV_Settings.logoutSnapshot = nil
		end
	elseif event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED" or event == "MINIMAP_UPDATE_ZOOM" then
		DMV_OnZoneChanged()
	elseif event == "WORLD_MAP_UPDATE" then
		-- Maintain spoofed continent dropdown text during browse mode
		if DMV_InstanceBrowseMode then
			DMV_ApplyBrowseModeText(GetContinentDropdown())
		end

		-- If the player manually navigated the world map (continent/zone/zoom)
		-- while the dungeon overlay is visible, hide the overlay so the selected
		-- map shows through. DMV_OnMapShow will restore it when the map is
		-- reopened or when the player navigates back to the dungeon.
		-- Inside an instance (continent -1) it only stays if no zone index is
		-- set. GetCurrentMapZone() returns 0 for "no zone", and 0 is true in Lua.
		if DMV_Visible then
			if GetCurrentMapContinent() ~= -1 or (GetCurrentMapZone() or 0) > 0 then
				DMV_HideFrames()
			end
		end
	elseif event == "CREATURE_DATA_LOAD_RESULT" then
		-- arg1 = creatureID, arg2 = success (1 or nil)
		if arg1 then
			local info = arg2 and C_CreatureInfo.GetCreatureInfoByID(arg1)
			DMV_OnGenericResult("n" .. arg1, info and info.name)
		end
		DMV_PreloadGeneric_Next()
	elseif event == "GAMEOBJECT_DATA_LOAD_RESULT" then
		-- arg1 = gameObjectID, arg2 = success (1 or nil)
		if arg1 then
			local info = arg2 and C_GameObjectInfo.GetGameObjectInfoByID(arg1)
			DMV_OnGenericResult("o" .. arg1, info and info.name)
		end
		DMV_PreloadGeneric_Next()
	elseif event == "QUEST_DATA_LOAD_RESULT" then
		-- arg1 = questID, arg2 = success (1 or nil)
		if arg1 then
			local idStr = "q" .. arg1
			local details = arg2 and C_QuestLog.GetQuestDetails(arg1)
			if details and details.title then
				DMV_OnGenericResult(idStr, { details.title, details.level or 0 })
			else
				DMV_OnGenericResult(idStr, nil)
			end
		end
		DMV_PreloadGeneric_Next()
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		-- arg1 = itemID, arg2 = success (1 or nil)
		if arg1 and arg2 then
			local idStr = "i" .. arg1
			if DMV_IsTrackedID(idStr) then
				local iname = C_Item.GetItemNameByID(arg1)
				if iname then
					DMV_NameCache[idStr] = { iname, C_Item.GetItemQualityByID(arg1) or 1 }
					-- Redraws the markers and an open marker tooltip.
					DMV_QueuePinRefresh()
				end
			end
		end
	end
end)

-- Hook WorldMapFrame: show overlay when map opens in a dungeon.
-- Also restores actual floor if the player was browsing.
local function DMV_OnMapShow()
	if not DMV_Initialized then DMV_CreateFrames() end

	local instanceType, instanceMapID = DMV_GetInstanceCached()

	-- Auto-detect and populate dropdowns when physically inside an instance
	if (instanceType == "party" or instanceType == "raid") and instanceMapID then
		local entry = DMV_DungeonByMapID[instanceMapID]
		if entry then
			DMV_CurrentDungeon = entry[1]
			DMV_InstanceBrowseMode = entry[3] and "raid" or "dungeon"

			-- Find current instance ID in the sorted list
			local list = DMV_BuildInstanceList(DMV_InstanceBrowseMode == "raid")
			for i, item in ipairs(list) do
				if item.mapID == instanceMapID then
					DMV_InstanceZoneID = i
					break
				end
			end
		end
	end

	if DMV_CurrentDungeon then
		DMV_SetTextures(DMV_CurrentDungeon, DMV_ActualFloor or DMV_CurrentFloor)
		DMV_ShowFrames()

		-- Force update dropdown labels for active instance
		local continentDD = GetContinentDropdown()
		if continentDD then
			local modeText = (DMV_InstanceBrowseMode == "raid") and L["Raids"] or L["Dungeons"]
			UIDropDownMenu_SetText(modeText, continentDD)
		end

		if DMV_InstanceZoneID then
			DMV_ApplyInstanceZoneText(GetZoneDropdown(), DMV_BuildInstanceList(DMV_InstanceBrowseMode == "raid"))
		end
	end
end

local function DMV_OnMapHide()
	DMV_Visible = false
	DMV_ResetPinsOnMapHide()
	DMV_UpdateCoordsVisibility()
	if DMV_HideAreaList then DMV_HideAreaList() end
	if DMV_HideMarkerList then DMV_HideMarkerList() end
	if DMV_ClickFrame then DMV_ClickFrame:Hide() end
	DMV_StopArrowUpdates()

	if DMV_PreviewMode then
		DMV_HideFrames()
		SetMapToCurrentZone()
	end

	-- Only clear browse mode if NOT physically inside a dungeon or raid
	local instanceType = DMV_GetInstanceCached()
	if instanceType ~= "party" and instanceType ~= "raid" then
		DMV_ClearBrowseState()

		local zoneDD = GetZoneDropdown()
		if zoneDD then
			UIDropDownMenu_Initialize(zoneDD, WorldMapZoneDropDown_Initialize)
		end
	end
end

-- Each map open and close is handled exactly once, whichever path sees it.
local DMV_MapOpen = false

local function DMV_MapShown()
	if DMV_MapOpen then return end
	DMV_MapOpen = true
	DMV_OnMapShow()
end

local function DMV_MapHidden()
	if not DMV_MapOpen then return end
	DMV_MapOpen = false
	DMV_OnMapHide()
end

-- Runs after WorldMapFrame's own OnShow/OnHide (so after the stock code has
-- set the map to the current zone). The postcall binding survives addons
-- that replace these scripts with SetScript (e.g. Magnify), so no polling
-- is needed. Without it, a poll frame catches opens and closes that the
-- plain hooks miss.
local DMV_MapHooksPostcall = DMV_HookScriptPost(WorldMapFrame, "OnShow", DMV_MapShown)
DMV_HookScriptPost(WorldMapFrame, "OnHide", DMV_MapHidden)

if not DMV_MapHooksPostcall then
	local DMV_MapPollFrame = CreateFrame("Frame", "DMV_MapPollFrame")
	DMV_MapPollFrame:SetScript("OnUpdate", function()
		if WorldMapFrame:IsVisible() then DMV_MapShown() else DMV_MapHidden() end
	end)
end

-- Instance browser in continent/zone dropdowns
-- Adds "Dungeons" and "Raids" entries to the continent dropdown.
-- Selecting one populates the zone dropdown with a sorted list of
-- instance names; selecting an instance enters preview mode for it.

-- Browse state lives in DMV_InstanceBrowseMode ("dungeon", "raid" or nil)
-- and DMV_InstanceZoneID, declared at the top of the file.

-- Sorted { mapID, name } list for dungeons or raids. DMV_DungeonByMapID is
-- static, so each list is built once; callers must not modify it.
local DMV_InstanceLists = {}

function DMV_BuildInstanceList(raidsOnly)
	local key = raidsOnly and "raid" or "dungeon"
	local list = DMV_InstanceLists[key]
	if list then return list end
	list = {}
	for mapID, entry in pairs(DMV_DungeonByMapID) do
		local isRaid = entry[3]
		if (raidsOnly and isRaid) or (not raidsOnly and not isRaid) then
			list[#list + 1] = { mapID = mapID, name = entry[2] }
		end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	DMV_InstanceLists[key] = list
	return list
end

-- Hook continent dropdown to append Dungeons / Raids entries and safely reset state when on real continents
local _origContinentsInit = WorldMapContinentsDropDown_Initialize
WorldMapContinentsDropDown_Initialize = function()
	local currentContinent = GetCurrentMapContinent()
	local continents = { GetMapContinents() }
	local numContinents = #continents

	-- If the user is currently looking at a real physical continent and has NOT selected an instance yet,
	-- clear the uncommitted browse mode so the zone dropdown resets properly.
	if currentContinent and currentContinent > 0 and currentContinent <= numContinents and not DMV_InstanceZoneID then
		DMV_ClearBrowseState()
	end

	_origContinentsInit()
	
	local continentDD = GetContinentDropdown()
	local dungeonID = numContinents + 1
	local raidID	= numContinents + 2
	
	-- Add a Dungeons or Raids category entry to the continent dropdown.
	local function AddCategory(mode, label, categoryID)
		local info = {}
		info.text = label
		info.func = function()
			DMV_InstanceBrowseMode = mode
			DMV_InstanceZoneID = nil

			local zoneDD = GetZoneDropdown()
			if zoneDD then
				zoneDD.selectedID = nil
				UIDropDownMenu_SetSelectedID(zoneDD, nil)
				UIDropDownMenu_SetText("", zoneDD)
				UIDropDownMenu_Initialize(zoneDD, WorldMapZoneDropDown_Initialize)
			end

			UIDropDownMenu_SetSelectedID(continentDD, categoryID)
			UIDropDownMenu_SetText(label, continentDD)
		end
		info.checked = (DMV_InstanceBrowseMode == mode)
		UIDropDownMenu_AddButton(info)
	end
	AddCategory("dungeon", L["Dungeons"], dungeonID)
	AddCategory("raid", L["Raids"], raidID)

	if DMV_InstanceBrowseMode == "dungeon" then
		UIDropDownMenu_SetSelectedID(continentDD, dungeonID)
		UIDropDownMenu_SetText(L["Dungeons"], continentDD)
	elseif DMV_InstanceBrowseMode == "raid" then
		UIDropDownMenu_SetSelectedID(continentDD, raidID)
		UIDropDownMenu_SetText(L["Raids"], continentDD)
	end
end

-- Real continents are left unchecked while browsing by the
-- UIDropDownMenu_SetSelectedID(continentDD, dungeonID/raidID) calls above:
-- that refresh redraws every checkmark from the selected ID.

-- Hook zone dropdown to show instance names when a category is selected and manage checkmarks
local _origZoneInit = WorldMapZoneDropDown_Initialize
WorldMapZoneDropDown_Initialize = function()
	if not DMV_InstanceBrowseMode then
		_origZoneInit()
		return
	end

	local zoneDD = GetZoneDropdown()
	local list = DMV_BuildInstanceList(DMV_InstanceBrowseMode == "raid")

	-- If no instance has been selected yet, clear selectedID so UIDropDownMenu doesn't check item 1
	if not DMV_InstanceZoneID then
		zoneDD.selectedID = nil
	end

	for i, entry in ipairs(list) do
		local mapID   = entry.mapID
		local entryID = i
		local info = {}
		info.text = entry.name

		-- STRICT CHECKMARK CONTROL: Only checked if an instance is explicitly selected
		info.checked = (DMV_InstanceZoneID ~= nil and DMV_InstanceZoneID == entryID)

		info.func = function()
			local folder = DMV_DungeonByMapID[mapID] and DMV_DungeonByMapID[mapID][1]
			if not folder then return end
			DMV_InstanceZoneID = entryID
			UIDropDownMenu_SetSelectedID(zoneDD, entryID)

			DMV_HideFrames()
			DMV_PreviewMode = true

			-- Switch to opposite continent so vanilla player arrow stays hidden
			local currentContinent = GetCurrentMapContinent()
			if currentContinent == 1 then
				SetMapZoom(2)
			else
				SetMapZoom(1)
			end

			-- Restore Continent and Zone dropdown texts right after SetMapZoom resets them
			DMV_ApplyBrowseModeText(GetContinentDropdown())

			UIDropDownMenu_SetSelectedID(zoneDD, entryID)
			UIDropDownMenu_SetText(entry.name, zoneDD)

			DMV_SetTextures(folder, 1)
			if WorldMapFrame:IsVisible() then
				DMV_ShowFrames()
			end
		end
		UIDropDownMenu_AddButton(info)
	end

	-- Populate label text if an instance is active
	DMV_ApplyInstanceZoneText(zoneDD, list)
end

-- Clicking a real continent clears instance browse mode.
local _origContinentClick = WorldMapContinentButton_OnClick
WorldMapContinentButton_OnClick = function()
	DMV_ClearBrowseState()
	_origContinentClick()
end

-- Slash command: /dmv
DMV_CommandHint = L["Hint"]

DMV_CommandList = {
	{ cmd = "/dmv debug",		desc = L["Debug"] },
	{ cmd = "/dmv arrow",		desc = L["Arrow"] },
	{ cmd = "/dmv calib",		desc = L["Calib"] },
	{ cmd = "/dmv calib reset", desc = L["Calib Reset1"] },
}

-- Interface Options Panel
local DMV_OptionsPanelCreated = false
function DMV_CreateInterfaceOptionsPanel()
	if DMV_OptionsPanelCreated then return end
	if not InterfaceOptions_AddCategory then return end

	local panel = CreateFrame("Frame")
	panel.name = "DungeonMapsVanilla"

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("DungeonMapsVanilla")

	local scaleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	scaleLabel:SetPoint("TOPLEFT", 16, -56)
	scaleLabel:SetText(L["Opt1"])

	local slider = CreateFrame("Slider", "DMV_WindowScaleSlider", panel, "OptionsSliderTemplate")
	slider:SetPoint("TOPLEFT", 16, -80)
	slider:SetWidth(260)
	slider:SetMinMaxValues(0.5, 1.0)
	slider:SetValueStep(0.05)
	if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
	if DMV_WindowScaleSliderLow then DMV_WindowScaleSliderLow:SetText("0.50") end
	if DMV_WindowScaleSliderHigh then DMV_WindowScaleSliderHigh:SetText("1.00") end
	if DMV_WindowScaleSliderText then DMV_WindowScaleSliderText:SetText("") end

	local valueText = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	valueText:SetPoint("TOP", slider, "BOTTOM", 0, -2)
	slider.valueText = valueText

	slider:SetScript("OnValueChanged", function(self, val)
		local control = self or this or slider
		if val == nil then val = _G.arg1 end
		if control.updating then return end
		val = math.floor(val / 0.05 + 0.5) * 0.05
		valueText:SetText(string.format("%.2f", val))
		DMV_SetWindowScale(val)
	end)

	local blipCheck = CreateFrame("CheckButton", "DMV_PartyBlipCheck", panel, "UICheckButtonTemplate")
	blipCheck:SetPoint("TOPLEFT", 12, -120)
	if DMV_PartyBlipCheckText then
		DMV_PartyBlipCheckText:SetText(L["Opt2"])
	else
		local label = blipCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		label:SetPoint("LEFT", blipCheck, "RIGHT", 4, 0)
		label:SetText(L["Opt2"])
	end
	blipCheck:SetScript("OnClick", function(self)
		local control = self or this or blipCheck
		if DMV_Settings then DMV_Settings.showPartyBlips = control:GetChecked() and true or false end
		if DMV_UpdatePartyBlips then DMV_UpdatePartyBlips() end
	end)

	local raidBlipCheck = CreateFrame("CheckButton", "DMV_RaidBlipCheck", panel, "UICheckButtonTemplate")
	raidBlipCheck:SetPoint("TOPLEFT", 12, -148)
	if DMV_RaidBlipCheckText then
		DMV_RaidBlipCheckText:SetText(L["Opt2b"])
	else
		local label = raidBlipCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		label:SetPoint("LEFT", raidBlipCheck, "RIGHT", 4, 0)
		label:SetText(L["Opt2b"])
	end
	raidBlipCheck:SetScript("OnClick", function(self)
		local control = self or this or raidBlipCheck
		if DMV_Settings then DMV_Settings.showRaidBlips = control:GetChecked() and true or false end
		if DMV_UpdatePartyBlips then DMV_UpdatePartyBlips() end
	end)

	local markerCheck = CreateFrame("CheckButton", "DMV_ShowMarkersCheck", panel, "UICheckButtonTemplate")
	markerCheck:SetPoint("TOPLEFT", 12, -176)
	if DMV_ShowMarkersCheckText then
		DMV_ShowMarkersCheckText:SetText(L["Opt3"])
	else
		local label = markerCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		label:SetPoint("LEFT", markerCheck, "RIGHT", 4, 0)
		label:SetText(L["Opt3"])
	end
	markerCheck:SetScript("OnClick", function(self)
		local control = self or this or markerCheck
		if DMV_Settings then DMV_Settings.showMarkersDropdown = control:GetChecked() and true or false end
		if DMV_BossPinDropDown then
			if DMV_Settings and DMV_Settings.showMarkersDropdown ~= false then
				if DMV_Visible then
					DMV_BossPinDropDown:Show()
				end
			else
				DMV_BossPinDropDown:Hide()
			end
		end
	end)

	local coordCheck = CreateFrame("CheckButton", "DMV_ShowCoordsCheck", panel, "UICheckButtonTemplate")
	coordCheck:SetPoint("TOPLEFT", 12, -204)
	if DMV_ShowCoordsCheckText then
		DMV_ShowCoordsCheckText:SetText(L["Opt4"])
	else
		local label = coordCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		label:SetPoint("LEFT", coordCheck, "RIGHT", 4, 0)
		label:SetText(L["Opt4"])
	end
	coordCheck:SetScript("OnClick", function(self)
		local control = self or this or coordCheck
		if DMV_Settings then DMV_Settings.showCoords = control:GetChecked() and true or false end
		DMV_UpdateCoordsVisibility()
	end)

	local cmdHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	cmdHeader:SetPoint("TOPLEFT", 16, -248)
	cmdHeader:SetText("Commands")

	for i, entry in ipairs(DMV_CommandList) do
		local cmdText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		cmdText:SetPoint("TOPLEFT", 16, -248 - (i * 18))
		cmdText:SetText(entry.cmd .. " - " .. entry.desc)
	end

	local hintText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hintText:SetPoint("TOPLEFT", 16, -248 - (#DMV_CommandList * 18) - 24)
	hintText:SetWidth(350)
	hintText:SetJustifyH("LEFT")
	hintText:SetText(DMV_CommandHint)

	panel.refresh = function()
		slider.updating = true
		local v = DMV_GetWindowScale()
		slider:SetValue(v)
		valueText:SetText(string.format("%.2f", v))
		slider.updating = false
		blipCheck:SetChecked(DMV_Settings and DMV_Settings.showPartyBlips ~= false)
		raidBlipCheck:SetChecked(DMV_Settings and DMV_Settings.showRaidBlips ~= false)
		markerCheck:SetChecked(DMV_Settings and DMV_Settings.showMarkersDropdown ~= false)
		coordCheck:SetChecked(DMV_Settings and DMV_Settings.showCoords ~= false)
	end

	panel.okay   = function() end
	panel.cancel = function() end
	panel.default = function()
		DMV_SetWindowScale(1)
		if DMV_Settings then DMV_Settings.showPartyBlips = true end
		if DMV_Settings then DMV_Settings.showRaidBlips = true end
		if DMV_Settings then DMV_Settings.showMarkersDropdown = true end
		if DMV_Settings then DMV_Settings.showCoords = true end
		panel.refresh()
		if DMV_UpdatePartyBlips then DMV_UpdatePartyBlips() end
		DMV_UpdateCoordsVisibility()
	end

	InterfaceOptions_AddCategory(panel)
	DMV_OptionsPanelCreated = true
end

-- Cleanup uncommitted browse mode when closing menus or clicking away on real continents
local DMV_DropdownCleanupFrame = CreateFrame("Frame", "DMV_DropdownCleanupFrame", WorldMapFrame)
DMV_DropdownCleanupFrame:RegisterEvent("WORLD_MAP_UPDATE")
DMV_DropdownCleanupFrame:SetScript("OnEvent", function()
	if DMV_InstanceBrowseMode and not DMV_InstanceZoneID then
		if not DropDownList1:IsShown() and not DropDownList2:IsShown() then
			local currentContinent = GetCurrentMapContinent()
			local continents = { GetMapContinents() }
			if currentContinent and currentContinent > 0 and currentContinent <= #continents then
				DMV_ClearBrowseState()

				local zoneDD = GetZoneDropdown()
				if zoneDD and _origZoneInit then
					UIDropDownMenu_Initialize(zoneDD, _origZoneInit)
					local zone = GetCurrentMapZone()
					if zone and zone > 0 then
						UIDropDownMenu_SetSelectedID(zoneDD, zone)
					else
						UIDropDownMenu_SetSelectedID(zoneDD, 0)
					end
					UIDropDownMenu_SetText(GetZoneText() or "", zoneDD)
				end
			end
		end
	end
end)

-- True when the dungeon overlay is hidden and a real world/continent/zone map
-- is displayed (continent 0 = both continents, >0 = continent or zone).
function DMV_IsOnRealWorldMap()
	if DMV_Visible then return false end
	local continent = GetCurrentMapContinent()
	return continent ~= nil and continent >= 0
end

-- Force WorldMapZoomOutButton to invoke the working right-click handler
if WorldMapZoomOutButton then
	local origZoomOnClick = WorldMapZoomOutButton:GetScript("OnClick")
	WorldMapZoomOutButton:SetScript("OnClick", function()
		-- If the player is inside a dungeon but has navigated to a real world map
		-- (a continent or zone, e.g. Kalimdor > Desolace) the overlay is hidden and
		-- the vanilla zoom-out (zone -> continent -> world) must be used instead.
		local onRealMap = DMV_IsOnRealWorldMap()
		-- If we are browsing or previewing a map...
		if DMV_InstanceBrowseMode or DMV_PreviewMode or (DMV_CurrentDungeon and not onRealMap) then
			-- Run the overlay's right-click handler (DMV_ClickFrame exists from
			-- the first map open on).
			local rightClickScript = DMV_ClickFrame and DMV_ClickFrame:GetScript("OnMouseDown")
			if rightClickScript then
				rightClickScript(DMV_ClickFrame, "RightButton")
				return
			end
		end

		-- Fall back to default WoW Zoom Out button behavior if not browsing
		if origZoomOnClick then
			origZoomOnClick()
		else
			WorldMapZoomOutButton_OnClick()
		end
	end)
end

-- Directly enforce Zoom Out button state when opening the map or inside an instance
local function DMV_UpdateZoomOutButton()
	if not WorldMapZoomOutButton then return end

	local isInside = IsInInstance and IsInInstance()
	local isBrowsing = (DMV_InstanceBrowseMode ~= nil) or DMV_PreviewMode

	-- If inside an instance or browsing, ensure the button is usable
	if isBrowsing then
		WorldMapZoomOutButton:Enable()
	elseif isInside and DMV_CurrentDungeon then
		if DMV_IsOnRealWorldMap() then
			-- Viewing a real map from inside a dungeon: mirror vanilla behaviour.
			-- Nothing to zoom out to from the both-continents view.
			if GetCurrentMapContinent() == 0 then
				WorldMapZoomOutButton:Disable()
			else
				WorldMapZoomOutButton:Enable()
			end
		else
			WorldMapZoomOutButton:Enable()
		end
	end
end

-- Re-evaluate the button on every map change (runs after the main
-- WORLD_MAP_UPDATE handler, which hides the overlay when navigating away).
local DMV_ZoomOutStateFrame = CreateFrame("Frame", "DMV_ZoomOutStateFrame", WorldMapFrame)
DMV_ZoomOutStateFrame:RegisterEvent("WORLD_MAP_UPDATE")
DMV_ZoomOutStateFrame:SetScript("OnEvent", function()
	DMV_UpdateZoomOutButton()
end)

-- Hook WorldMapFrame OnShow to guarantee button state on open
DMV_HookScriptPost(WorldMapFrame, "OnShow", DMV_UpdateZoomOutButton)

-- Also hook default update function as a secondary check
local _origWorldMapFrame_Update = WorldMapFrame_Update
WorldMapFrame_Update = function()
	if _origWorldMapFrame_Update then
		_origWorldMapFrame_Update()
	end
	DMV_UpdateZoomOutButton()
end

SLASH_DMV1 = "/dmv"
SlashCmdList["DMV"] = function(msg)
	if msg == "calib reset" then
		local instanceMapID
		if DMV_PreviewMode then
			instanceMapID = DMV_GetInstanceIdForDungeon(DMV_CurrentDungeon)
		else
			instanceMapID = select(8, GetInstanceInfo())
		end
		if instanceMapID and DMV_GlobalSettings.bossPinOverrides then
			DMV_GlobalSettings.bossPinOverrides[instanceMapID] = nil
		end
		if DMV_Visible then DMV_ShowBossPins() end
		print(L["Calib Reset2"])
	elseif msg == "calib" then
		DMV_CalibMode = not DMV_CalibMode
		if DMV_Visible then DMV_ShowBossPins() end
		if DMV_CalibMode then
			print(L["Calib On"])
		else
			print(L["Calib Off"])
		end
	elseif msg == "arrow" then
		local posY, posX, posZ = UnitPosition("player")
		local _, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
		local floorRects = DMV_FloorMapRects and DMV_FloorMapRects[instanceMapID]
		local rect = floorRects and floorRects[DMV_CurrentFloor]
		if rect and not rect.locLeft then rect = nil end
		print(string.format("|cff00ff00DMV Arrow|r: posY=%.4f posX=%.4f instanceMapID=%s floor=%s",
			posY or 0, posX or 0, tostring(instanceMapID), tostring(DMV_CurrentFloor)))
		print(string.format("  posZ=%.4f", posZ or 0))
		if rect and posY and posX then
			local width  = rect.locLeft - rect.locRight
			local height = rect.locTop  - rect.locBottom
			local mapX = (rect.locLeft - posY) / width  * 100
			local mapY = (rect.locTop  - posX) / height * 100
			print(string.format("  locLeft=%.4f locRight=%.4f locTop=%.4f locBottom=%.4f",
				rect.locLeft, rect.locRight, rect.locTop, rect.locBottom))
			print(string.format("  width=%.4f height=%.4f", width, height))
			print(string.format("  mapXY: x=%.2f%% y=%.2f%%", mapX, mapY))
		else
			print("  no rect for instanceMapID=" .. tostring(instanceMapID) .. " floor=" .. tostring(DMV_CurrentFloor))
		end
		print(string.format("  Visible=%s Ticker=%s Arrow=%s",
			tostring(DMV_Visible), tostring(DMV_RefreshTicker ~= nil and DMV_RefreshTicker:IsShown() ~= nil),
			DMV_PlayerArrow and (DMV_PlayerArrow:IsShown() and "shown" or "hidden") or "nil"))
	elseif msg == "debug" then
		local canvas = GetMapCanvas()
		local _, instanceType, _, _, _, _, _, mapID = GetInstanceInfo()
		print("|cff00ff00DMV Debug:|r")
		print("  CurrentDungeon: " .. tostring(DMV_CurrentDungeon))
		print("  CurrentFloor: " .. tostring(DMV_CurrentFloor))
		print("  Visible: " .. tostring(DMV_Visible))
		print("  Canvas: " .. string.format("%.0f", canvas:GetWidth()) .. "x" .. string.format("%.0f", canvas:GetHeight()))
		print("  InstanceType: " .. tostring(instanceType) .. "  MapID: " .. tostring(mapID))
		print("  Subzone: " .. tostring(GetMinimapZoneText()))
		if DMV_CurrentDungeon then
			print("  TexturePath: " .. DMV_GetTexturePath(DMV_CurrentDungeon, DMV_CurrentFloor, 1))
		end
		if DMV_Initialized and DMV_Frames[1] then
			print("  Frame1 size: " .. string.format("%.1f", DMV_Frames[1]:GetWidth()) .. "x" .. string.format("%.1f", DMV_Frames[1]:GetHeight()))
			print("  Texture1 loaded: " .. tostring(DMV_Textures[1]:GetTexture()))
		end
		print("  Arrow: " .. (DMV_PlayerArrow and (DMV_PlayerArrow:IsShown() and "visible" or "hidden") or "not created"))
		print("  ArrowTicker: " .. tostring(DMV_RefreshTicker ~= nil and DMV_RefreshTicker:IsShown() ~= nil))
	else
		-- Bare /dmv: print available commands.
		print("|cff00ff00DungeonMapsVanilla|r")
		print(L["Commands"])
		for _, entry in ipairs(DMV_CommandList) do
			print("  |cffffff00" .. entry.cmd .. "|r - " .. entry.desc)
		end
		print(DMV_CommandHint)
	end
end
