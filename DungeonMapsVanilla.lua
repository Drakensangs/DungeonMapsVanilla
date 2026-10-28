-- DungeonMapsVanilla.lua

local DMV_Frames = {}
local DMV_Textures = {}
local DMV_CurrentDungeon = nil
local DMV_InstanceBrowseMode = nil   -- "dungeon", "raid", or nil
local DMV_InstanceContinentID = nil  -- selected ID in continent dropdown
local DMV_InstanceZoneID = nil		 -- selected ID in zone dropdown
local DMV_CurrentFloor = 1
local DMV_Initialized = false
local DMV_Visible = false
local DMV_ClickFrame = nil
local DMV_Container = nil
local DMV_BossPins = {}
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

-- Format a resolved item cache entry { name, quality } as a colored [Name] string.
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
local DMV_PlayerArrowTicker = nil
local ARROW_SIZE = 24

local function SafeShow(frame)
	if frame then frame:Show() end
end

local function GetContinentDropdown()
	return WorldMapContinentDropdown or WorldMapContinentDropDown
end

local function GetZoneDropdown()
	return WorldMapZoneDropdown or WorldMapZoneDropDown
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

-- Player arrow in dungeons and raids
-- Uses vanilla SetMapToCurrentZone() + GetPlayerMapPosition("player")
local function DMV_CreatePlayerArrow()
	if DMV_PlayerArrow then return end
	if not DMV_Container then return end

	local arrow = CreateFrame("Frame", "DMV_PlayerArrow", DMV_Container)
	arrow:SetSize(ARROW_SIZE, ARROW_SIZE)
	arrow:SetFrameLevel(DMV_Container:GetFrameLevel() + 20)
	arrow:Hide()

	-- Arrow texture: use the minimap arrow atlas if available, else a fallback
	local tex = arrow:CreateTexture(nil, "OVERLAY")
	tex:SetAllPoints(arrow)

	-- Try to use the MinimapArrow atlas (available via ClassicAPI's SetAtlas backport)
	local ok = pcall(function() tex:SetAtlas("MinimapArrow", false) end)
	if not ok or not tex:GetTexture() then
		-- Fallback: use a simple arrow-like texture
		tex:SetTexture("Interface\\Minimap\\MinimapArrow")
	end
	tex:SetVertexColor(1, 1, 1)

	arrow.tex = tex
	arrow:EnableMouse(true)

	arrow:SetScript("OnEnter", function(self)
		local x, y = self:GetCenter()
		local parentX = DMV_Container:GetCenter()
		if x > parentX then
			WorldMapTooltip:SetOwner(self, "ANCHOR_LEFT")
		else
			WorldMapTooltip:SetOwner(self, "ANCHOR_RIGHT")
		end
		WorldMapTooltip:SetText(UnitName("player"))
		WorldMapTooltip:Show()
	end)

	arrow:SetScript("OnLeave", function(self)
		WorldMapTooltip:Hide()
	end)

	DMV_PlayerArrow = arrow
end

function DMV_UpdatePlayerArrow()
	if not DMV_PlayerArrow then return end
	if not DMV_Container then return end
	if not DMV_CurrentDungeon then DMV_PlayerArrow:Hide(); return end
	if DMV_PreviewMode then DMV_PlayerArrow:Hide(); return end
	if DMV_CurrentFloor ~= DMV_ActualFloor then DMV_PlayerArrow:Hide(); return end

	local posY, posX = UnitPosition("player")
	if not posY or not posX then DMV_PlayerArrow:Hide(); return end

	local _, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
	if not instanceMapID then DMV_PlayerArrow:Hide(); return end

	local floorRects = DMV_FloorMapRects and DMV_FloorMapRects[instanceMapID]
	local rect = floorRects and floorRects[DMV_CurrentFloor]
	if not rect or not rect.locLeft then DMV_PlayerArrow:Hide(); return end

	local width  = rect.locLeft - rect.locRight
	local height = rect.locTop  - rect.locBottom

	if width == 0 or height == 0 then DMV_PlayerArrow:Hide(); return end

	local mapX = (rect.locLeft - posY) / width  * 100
	local mapY = (rect.locTop  - posX) / height * 100

	-- Expose for third-party addons (e.g. Magnify player coordinate display).
	DMV_LastPlayerMapPos = { x = mapX, y = mapY }

	if mapX < 0 or mapX > 100 or mapY < 0 or mapY > 100 then
		DMV_LastPlayerMapPos = nil
		DMV_PlayerArrow:Hide(); return
	end

	-- Write directly into Magnify's player coordinate display if present.
	-- Magnify's updater uses GetPlayerMapPosition which returns 0,0 in instances.
	if MagnifyPlayerFrame and MagnifyPlayerFrame.text then
		MagnifyPlayerFrame.text:SetText(string.format("Player: %.1f / %.1f", mapX, mapY))
	end

	-- Use the actual canvas size for pixel placement.
	-- The map tiles (1024x768) are scaled to fit WorldMapDetailFrame (1002x668).
	local canvas = GetMapCanvas()
	local canvasW = canvas:GetWidth()
	local canvasH = canvas:GetHeight()

	local px =  (mapX / 100) * canvasW
	local py = -(mapY / 100) * canvasH

	DMV_PlayerArrow:ClearAllPoints()
	DMV_PlayerArrow:SetPoint("CENTER", DMV_Container, "TOPLEFT", px, py)

	local facing = GetPlayerFacing and GetPlayerFacing() or 0
	if DMV_PlayerArrow.tex.SetRotation then
		DMV_PlayerArrow.tex:SetRotation(facing)
	end

	DMV_PlayerArrow:Show()
end

-- Party member blips
DMV_PartyBlips = {}
BLIP_SIZE = 8

local BLIP_TEX_PARTY = "Interface\\AddOns\\DungeonMapsVanilla\\Assets\\partymember"
local BLIP_TEX_RAID  = "Interface\\AddOns\\DungeonMapsVanilla\\Assets\\raidmember"

local function DMV_GetOrCreateBlip(i)
	if DMV_PartyBlips[i] then return DMV_PartyBlips[i] end
	if not DMV_Container then return nil end

	local blip = CreateFrame("Frame", "DMV_PartyBlip"..i, DMV_Container)
	blip:SetSize(BLIP_SIZE, BLIP_SIZE)
	blip:SetFrameStrata("FULLSCREEN_DIALOG")
	blip:Hide()

	local tex = blip:CreateTexture(nil, "OVERLAY")
	tex:SetAllPoints(blip)
	tex:SetTexture(BLIP_TEX_PARTY)
	blip.tex = tex

	blip:EnableMouse(true)
	blip:SetScript("OnEnter", function(self)
		if self.unit then
			WorldMapTooltip:SetOwner(self, "ANCHOR_RIGHT")
			WorldMapTooltip:SetText(UnitName(self.unit) or "")
			WorldMapTooltip:Show()
		end
	end)
	blip:SetScript("OnLeave", function() WorldMapTooltip:Hide() end)

	DMV_PartyBlips[i] = blip
	return blip
end

function DMV_UpdatePartyBlips()
	if not DMV_Container then return end
	local showParty = not (DMV_Settings and DMV_Settings.showPartyBlips == false)
	local showRaid  = not (DMV_Settings and DMV_Settings.showRaidBlips  == false)
	if not showParty and not showRaid then
		for i = 1, 40 do if DMV_PartyBlips[i] then DMV_PartyBlips[i]:Hide() end end
		return
	end
	if not DMV_CurrentDungeon or DMV_PreviewMode then
		for i = 1, 40 do if DMV_PartyBlips[i] then DMV_PartyBlips[i]:Hide() end end
		return
	end
	if DMV_CurrentFloor ~= DMV_ActualFloor then
		for i = 1, 40 do if DMV_PartyBlips[i] then DMV_PartyBlips[i]:Hide() end end
		return
	end

	local _, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
	if not instanceMapID then return end

	local floorRects = DMV_FloorMapRects and DMV_FloorMapRects[instanceMapID]
	local rect = floorRects and floorRects[DMV_CurrentFloor]
	if not rect or not rect.locLeft then
		for i = 1, 40 do if DMV_PartyBlips[i] then DMV_PartyBlips[i]:Hide() end end
		return
	end

	local width  = rect.locLeft - rect.locRight
	local height = rect.locTop  - rect.locBottom
	if width == 0 or height == 0 then return end

	local canvas = GetMapCanvas()
	local canvasW = canvas:GetWidth()
	local canvasH = canvas:GetHeight()

	local units = {}
	local numRaid = GetNumRaidMembers()
	if numRaid > 0 then
		local playerSubgroup = nil
		local playerIndex = UnitInRaid("player")
		if playerIndex then
			playerSubgroup = select(3, GetRaidRosterInfo(playerIndex + 1))
		end
		for i = 1, numRaid do
			local unit = "raid"..i
			if not UnitIsUnit(unit, "player") then
				local subgroup = select(3, GetRaidRosterInfo(i))
				local isPartyMember = (subgroup == playerSubgroup)
				if (isPartyMember and showParty) or (not isPartyMember and showRaid) then
					units[#units + 1] = { unit = unit, sameParty = isPartyMember }
				end
			end
		end
	else
		if showParty then
			local numParty = GetNumPartyMembers()
			for i = 1, numParty do
				units[#units + 1] = { unit = "party"..i, sameParty = true }
			end
		end
	end

	for i = #units + 1, 40 do
		if DMV_PartyBlips[i] then DMV_PartyBlips[i]:Hide() end
	end

	for i, entry in ipairs(units) do
		local blip = DMV_GetOrCreateBlip(i)
		if not blip then break end
		local posY, posX = UnitPosition(entry.unit)
		if not posY or not posX then blip:Hide() else
			local mapX = (rect.locLeft - posY) / width  * 100
			local mapY = (rect.locTop  - posX) / height * 100
			if mapX < 0 or mapX > 100 or mapY < 0 or mapY > 100 then
				blip:Hide()
			else
				blip.unit = entry.unit
				blip.tex:SetTexture(entry.sameParty and BLIP_TEX_PARTY or BLIP_TEX_RAID)
				local _, class = UnitClass(entry.unit)
				local color = class and RAID_CLASS_COLORS[class]
				if color then
					blip.tex:SetVertexColor(color.r, color.g, color.b, 1)
				else
					blip.tex:SetVertexColor(1, 1, 1, 1)
				end
				blip:ClearAllPoints()
				blip:SetPoint("CENTER", DMV_Container, "TOPLEFT",
					(mapX / 100) * canvasW, -(mapY / 100) * canvasH)
				blip:Show()
			end
		end
	end
end


local function DMV_StartArrowUpdates()
	DMV_CreatePlayerArrow()
	if not DMV_PlayerArrow then return end
	if DMV_PlayerArrow:GetScript("OnUpdate") then return end
	DMV_PlayerArrow:SetScript("OnUpdate", function(self, elapsed)
		if DMV_Visible and DMV_CurrentDungeon and not DMV_PreviewMode then
			DMV_UpdatePlayerArrow()
			DMV_UpdatePartyBlips()
		end
	end)
	DMV_PlayerArrowTicker = true
end

local function DMV_StopArrowUpdates()
	if DMV_PlayerArrow then
		DMV_PlayerArrow:SetScript("OnUpdate", nil)
		DMV_PlayerArrow:Hide()
	end
	for i = 1, 40 do
		if DMV_PartyBlips[i] then DMV_PartyBlips[i]:Hide() end
	end
	DMV_PlayerArrowTicker = nil
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
		if button == "RightButton" then
			DMV_HideFrames()
		elseif button == "LeftButton" then
			if DMV_CalibMode and DMV_Container then
				local csc = DMV_Container:GetEffectiveScale()
				local mx, my = GetCursorPosition()
				mx, my = mx / csc, my / csc
				local dx = mx - DMV_Container:GetLeft()
				local dy = DMV_Container:GetTop() - my
				local x = dx / (MAP_W * DMV_MapScale) * 100
				local y = dy / (MAP_H * DMV_MapScale) * 100
				print(string.format("|cff00ff00DMV calib|r: x=%.1f, y=%.1f", x, y))
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

	-- Up arrow button (goes to lower index = higher floor number, matching 3.3.5a)
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
						DMV_LevelDropDown_SetFloor(floors[i - 1], i - 1)
						break
					end
				end
			end
		end
	end)
	upBtn:Hide()
	DMV_LevelUpButton = upBtn

	-- Down arrow button
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
						DMV_LevelDropDown_SetFloor(floors[i + 1], i + 1)
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

	local coordUpdater = CreateFrame("Frame")
	coordUpdater:SetScript("OnUpdate", function()
		if DMV_CoordsDisabled then return end
		if not DMV_CoordsFrame or not DMV_CoordsFrame:IsShown() then return end

		local df = GetMapCanvas()
		if df then
			local cx, cy = GetCursorPosition()
			local scale  = df:GetEffectiveScale()
			cx = cx / scale
			cy = cy / scale
			local left	 = df:GetLeft()
			local top	 = df:GetTop()
			local width  = df:GetWidth()
			local height = df:GetHeight()
			if left and top and width > 0 and height > 0 then
				local nx = (cx - left) / width
				local ny = (top - cy)  / height
				if nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 then
					DMV_CoordsFrame.text:SetText(string.format("Cursor: %.1f / %.1f", nx * 100, ny * 100))
				else
					DMV_CoordsFrame.text:SetText("Cursor: N/A")
				end
			end
		end

		if DMV_LastPlayerMapPos then
			DMV_PlayerCoordsFrame.text:SetText(string.format("Player: %.1f / %.1f",
				DMV_LastPlayerMapPos.x, DMV_LastPlayerMapPos.y))
		else
			DMV_PlayerCoordsFrame.text:SetText("Player: N/A")
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

	DMV_CurrentDungeon = dungeonName
	DMV_CurrentFloor = floor
end

-- Floor button display
-- Apply a floor selection from the dropdown or arrow buttons.
function DMV_LevelDropDown_SetFloor(floorNum, dropdownIndex)
	if not DMV_CurrentDungeon then return end
	DMV_SetTextures(DMV_CurrentDungeon, floorNum)
	DMV_UpdateFloorButtons()
	DMV_UpdatePlayerArrow()
	DMV_UpdatePartyBlips()
	if DMV_HideBossPins then DMV_HideBossPins() end
	if DMV_ShowBossPins then DMV_ShowBossPins() end
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

-- Called when the player picks an entry from the dropdown.
function DMV_LevelDropDown_OnClick()
	local floors = DMV_CurrentDungeon and DMV_DungeonFloors[DMV_CurrentDungeon]
	if not floors then return end
	local idx = this:GetID()
	local floorNum = floors[idx]
	if floorNum then
		DMV_LevelDropDown_SetFloor(floorNum, idx)
	end
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
				local idx = this:GetID()
				local floorNum = currentFloors and currentFloors[idx]
				if floorNum then
					DMV_HideAreaList()
					if IsShiftKeyDown() and not DMV_PreviewMode then
						-- Force the current floor to the selected one, correcting
						-- any mismatch caused by a crash that prevented a proper save.
						local _, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
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
						DMV_LevelDropDown_SetFloor(floorNum, idx)
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

local function DMV_MarkerRow_OnClick()
	local item = DMV_MarkerItems[this:GetID()]
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
	if DMV_Visible then
		DMV_HideBossPins()
		DMV_ShowBossPins()
	end
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

-- Kept for compatibility with existing callers.
function DMV_UpdateBossPinDropDown()
	DMV_RefreshMarkerList()
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
	AtlasFrame:SetFrameStrata("FULLSCREEN_DIALOG")
	AtlasFrame:Show()
	return true
end

-- AtlasLoot integration: open the loot page for a specific boss.
-- The module may load asynchronously, so retry the sub-category/boss
-- selection until the module data is available (bounded).
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
	local delayFrame = CreateFrame("Frame")
	delayFrame.timer = 0
	delayFrame:SetScript("OnUpdate", function()
		delayFrame.timer = delayFrame.timer + arg1
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
local DMV_BOSS_PIN_TEXTURE		= "Interface\\Addons\\DungeonMapsVanilla\\Assets\\boss.tga"
local DMV_BOSS_PIN_TEXTURE_ALT	  = "Interface\\Addons\\DungeonMapsVanilla\\Assets\\quest.tga"
local DMV_BOSS_PIN_TEXTURE_LOOT   = "Interface\\Addons\\DungeonMapsVanilla\\Assets\\loot.tga"
local DMV_BOSS_PIN_TEXTURE_OBJECT = "Interface\\Addons\\DungeonMapsVanilla\\Assets\\object.tga"

-- Boss pins: markers that open AtlasLoot on click
local function DMV_CreateBossPin(pinIndex)
	local pin = CreateFrame("Frame", "DMV_BossPin" .. pinIndex, DMV_Container)
	pin:SetSize(DMV_BOSS_PIN_SIZE, DMV_BOSS_PIN_SIZE)
	pin:SetFrameLevel(DMV_Container:GetFrameLevel() + 15)
	pin:SetFrameStrata("FULLSCREEN_DIALOG")
	pin:EnableMouse(true)

	local icon = pin:CreateTexture(nil, "OVERLAY")
	icon:SetAllPoints(pin)
	icon:SetTexture(DMV_BOSS_PIN_TEXTURE)
	pin.icon = icon

	local highlight = pin:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints(pin)
	highlight:SetTexture(DMV_BOSS_PIN_TEXTURE)
	highlight:SetBlendMode("ADD")
	highlight:SetAlpha(0)
	pin.highlight = highlight

	-- AtlasLoot boss number, shown in calib mode
	local label = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("LEFT", pin, "RIGHT", 1, 0)
	label:SetTextColor(1, 0.9, 0.2)
	label:Hide()
	pin.label = label

	pin.bossName = ""
	pin.comment = nil
	pin.atlasKey = nil
	pin.atlasBossIndex = nil
	pin.atlasEntries = nil
	pin.instanceMapID = nil
	pin.bossOrdinal = nil

	pin.removed = false

	pin:SetScript("OnEnter", function(self)
		local baseSize = (self.altTexture or self.lootTexture or self.objectTexture) and DMV_BOSS_PIN_SIZE_ALT or DMV_BOSS_PIN_SIZE
		local newSize = baseSize * DMV_BOSS_HOVER_MULT
		self:SetWidth(newSize)
		self:SetHeight(newSize)
		self.highlight:SetAlpha(DMV_BOSS_HOVER_ALPHA)
		WorldMapTooltip:SetOwner(self, "ANCHOR_RIGHT")
		WorldMapTooltip:AddLine(self.bossName, 1, 0.82, 0)
		if self.comment then
			local filtered = DMV_FilterCommentByFaction(self.comment)
			if filtered then
				local resolved = DMV_ResolveCommentItems(filtered)
				local commentText = "|cff999999" .. string.gsub(resolved, "|r", "|r|cff999999")
				WorldMapTooltip:AddLine(commentText)
			end
		end
		if DMV_CalibMode then
			WorldMapTooltip:AddLine("AtlasLoot #" .. tostring(self.atlasBossIndex), 0.6, 0.8, 1)
			if self.removed then
				WorldMapTooltip:AddLine(L["Marker removed"], 1, 0.4, 0.4)
			else
				WorldMapTooltip:AddLine(L["Marker move"], 0.7, 0.7, 0.7)
				WorldMapTooltip:AddLine(L["Marker reset"], 0.7, 0.7, 0.7)
				WorldMapTooltip:AddLine(L["Marker remove"], 0.7, 0.7, 0.7)
			end
		end
		WorldMapTooltip:Show()
	end)
	pin:SetScript("OnLeave", function(self)
		local baseSize = (self.altTexture or self.lootTexture or self.objectTexture) and DMV_BOSS_PIN_SIZE_ALT or DMV_BOSS_PIN_SIZE
		self:SetWidth(baseSize)
		self:SetHeight(baseSize)
		self.highlight:SetAlpha(0)
		WorldMapTooltip:Hide()
	end)

	pin:SetScript("OnMouseDown", function(self, button)
		if button == "RightButton" then
			DMV_HideFrames()
			return
		end
		if button ~= "LeftButton" then return end
		if DMV_CalibMode then
			if IsControlKeyDown() and self.instanceMapID and self.bossOrdinal then
				if not DMV_GlobalSettings.bossPinOverrides then DMV_GlobalSettings.bossPinOverrides = {} end
				local inst = DMV_GlobalSettings.bossPinOverrides[self.instanceMapID]
				if not inst then inst = {}; DMV_GlobalSettings.bossPinOverrides[self.instanceMapID] = inst end
				local e = inst[self.bossOrdinal]
				if not e then e = {}; inst[self.bossOrdinal] = e end
				e.removed = not e.removed
				print(string.format("|cff00ff00DMV calib|r: %s %s", self.bossName,
					e.removed and "|cffff4040removed|r" or "|cff40ff40restored|r"))
				DMV_HideBossPins()
				DMV_ShowBossPins()
				return
			end
			if IsShiftKeyDown() and self.instanceMapID and self.bossOrdinal then
				local inst = DMV_GlobalSettings.bossPinOverrides
					and DMV_GlobalSettings.bossPinOverrides[self.instanceMapID]
				if inst then inst[self.bossOrdinal] = nil end
				print(string.format("|cff00ff00DMV calib|r: %s - position reset (place it on the correct floor)",
					self.bossName))
				DMV_HideBossPins()
				DMV_ShowBossPins()
				return
			end
			self.isDragging = true
			self:SetScript("OnUpdate", function(s)
				local csc = DMV_Container:GetEffectiveScale()
				local mx, my = GetCursorPosition()
				mx, my = mx / csc, my / csc
				local maxX = MAP_W * DMV_MapScale
				local maxY = MAP_H * DMV_MapScale
				local dx = math.max(0, math.min(maxX, mx - DMV_Container:GetLeft()))
				local dy = math.max(0, math.min(maxY, DMV_Container:GetTop() - my))
				s:ClearAllPoints()
				s:SetPoint("CENTER", DMV_Container, "TOPLEFT", dx, -dy)
				s.calibX = dx / maxX * 100
				s.calibY = dy / maxY * 100
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
						print(string.format("|cff00ff00DMV calib|r: %s -> x=%.1f, y=%.1f, floor %d (saved)",
							s.bossName, x, y, DMV_CurrentFloor))
					end
				end
			end)
		elseif self.atlasKey and self.atlasEntries then
			-- Multiple boss entries under the same atlas key: pick one at random.
			local idx = self.atlasEntries[math.random(#self.atlasEntries)]
			if AtlasLoot_ShowBossLoot and idx and idx ~= 0 then
				DMV_OpenAtlasLootBoss(self.atlasKey, idx)
			else
				DMV_OpenAtlasBoss(self.atlasKey)
			end
		elseif self.atlasKey then
			-- If AtlasLoot is present, open Atlas to the dungeon and show
			-- boss loot. Otherwise just open Atlas to the dungeon map.
			if AtlasLoot_ShowBossLoot and self.atlasBossIndex and self.atlasBossIndex ~= 0 then
				DMV_OpenAtlasLootBoss(self.atlasKey, self.atlasBossIndex)
			else
				DMV_OpenAtlasBoss(self.atlasKey)
			end
		end
	end)

	DMV_BossPins[pinIndex] = pin
	return pin
end

function DMV_HideBossPins()
	for _, pin in ipairs(DMV_BossPins) do
		pin:Hide()
	end
end

-- Reverse map: dungeon texture folder name > instanceMapID (built lazily
-- from DMV_DungeonByMapID). Used in preview mode where GetInstanceInfo()
-- returns the player's real location, not the previewed dungeon.
local DMV_DungeonNameToId = nil
local function DMV_GetInstanceIdForDungeon(name)
	if not name then return nil end
	if not DMV_DungeonNameToId then
		DMV_DungeonNameToId = {}
		if DMV_DungeonByMapID then
			for id, folder in pairs(DMV_DungeonByMapID) do
				if DMV_DungeonNameToId[folder] == nil then
					DMV_DungeonNameToId[folder] = id
				end
			end
		end
	end
	return DMV_DungeonNameToId[name]
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
		local iname   = C_Item.GetItemNameByID(id)
		local quality = C_Item.GetItemQualityByID(id)
		if iname then
			DMV_NameCache[idStr] = { iname, quality or 1 }
			return DMV_NameCache[idStr]
		end
		C_Item.RequestLoadItemDataByID(id)
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
DMV_ResolveCommentItems = function(comment)
	return string.gsub(comment, "([noqi])(%d+)", function(prefix, digits)
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

function DMV_ShowBossPins()
	if not DMV_Settings then return end
	if not DMV_Settings.bossPins and not DMV_Settings.bossPinAlt
	   and not DMV_Settings.bossPinLoot and not DMV_Settings.bossPinObject then return end
	if not DMV_Container then return end
	if not DMV_Markers then return end

	DMV_HideBossPins()

	local instanceMapID
	if DMV_PreviewMode then
		instanceMapID = DMV_GetInstanceIdForDungeon(DMV_CurrentDungeon)
	else
		local _, _, _, _, _, _, _, iid = GetInstanceInfo()
		instanceMapID = iid
	end
	if not instanceMapID then return end
	local data = DMV_Markers[instanceMapID]
	if not data then return end

	local overrides = DMV_GlobalSettings.bossPinOverrides and DMV_GlobalSettings.bossPinOverrides[instanceMapID]

	local pinIndex = 0
	for ordinal, boss in ipairs(data) do
		local name, x, y, floor, atlasKey, atlasBossIndex, comment =
			boss[1], boss[2], boss[3], boss[4], boss[5], boss[6], boss[7]
		if name then name = name:gsub('L%["([^"]+)"%]', function(k) return L and L[k] or k end) end
		if comment then comment = comment:gsub('L%["([^"]+)"%]', function(k) return L and L[k] or k end) end
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
		if (not removed or DMV_CalibMode)
		   and x and y and floorOK
		   and x >= 0 and y >= 0 and x <= 100 and y <= 100 then
			local px = (x / 100) * MAP_W * DMV_MapScale
			local py = -(y / 100) * MAP_H * DMV_MapScale
			local displayName = name or ""
			local useAltTexture = false
			local useLootTexture = false
			local useObjectTexture = false
			local pinFaction = nil  -- nil = no faction, "A" = Alliance, "H" = Horde
			local excludeIfAtlas = false
			-- Parse type/faction prefixes in any order. "!" selects quest pins;
			-- "L "/"O " select loot/object pins, with the letter also
			-- accepted directly before an encoded ID. Requiring a delimiter or
			-- ID token prevents ordinary names (e.g. "Lord...") being misread.
			local prefixDone = false
			while not prefixDone do
				local ch = string.sub(displayName, 1, 1)
				if ch == "!" then
					useAltTexture = true
					useLootTexture = false
					useObjectTexture = false
					displayName = string.sub(displayName, 2)
				elseif ch == "L" and (string.sub(displayName, 2, 2) == " "
					or string.match(displayName, "^L[noqi]%d+")) then
					useAltTexture = false
					useLootTexture = true
					useObjectTexture = false
					if string.sub(displayName, 2, 2) == " " then
						displayName = string.sub(displayName, 3)
					else
						displayName = string.sub(displayName, 2)
					end
				elseif ch == "O" and (string.sub(displayName, 2, 2) == " "
					or string.match(displayName, "^O[noqi]%d+")) then
					useAltTexture = false
					useLootTexture = false
					useObjectTexture = true
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
			-- Resolve ID-based names: n<id> = NPC, o<id> = object, q<id> = quest.
			-- Anything after the ID (e.g. " / n3865") is kept and appended.
			local pfx, digits, remainder = string.match(displayName, "^([noqi])(%d+)(.*)")
			if pfx and digits then
				local idStr   = pfx .. digits
				local resolved = DMV_ResolveIDName(idStr)
				local base
				if type(resolved) == "table" then
					if pfx == "q" then
						base = DMV_FormatQuestText(resolved)
					else
						base = DMV_FormatItemText(resolved)
					end
				else
					base = resolved or ("(" .. idStr .. ")")
				end
				-- Recursively resolve any further IDs in the remainder.
				local tail = DMV_ResolveCommentItems(remainder)
				displayName = base .. tail
			end
			local factionFilter = DMV_Settings.bossFaction or "all"
			local factionOK = (factionFilter == "all")
				or (pinFaction == nil)
				or (factionFilter == "Alliance" and pinFaction == "Alliance")
				or (factionFilter == "Horde"	and pinFaction == "Horde")
			if excludeIfAtlas and not Atlas_Refresh then
				-- skip pin; only shown when Atlas is present
			elseif useAltTexture and not DMV_Settings.bossPinAlt then
				-- skip quest pins when disabled
			elseif useLootTexture and not DMV_Settings.bossPinLoot then
				-- skip loot pins when disabled
			elseif useObjectTexture and not DMV_Settings.bossPinObject then
				-- skip object pins when disabled
			elseif not useAltTexture and not useLootTexture and not useObjectTexture
				and not DMV_Settings.bossPins then
				-- skip regular boss pins when disabled
			elseif not factionOK then
				-- skip
			else

			pinIndex = pinIndex + 1
			local pin = DMV_BossPins[pinIndex] or DMV_CreateBossPin(pinIndex)
			pin:ClearAllPoints()
			pin:SetPoint("CENTER", DMV_Container, "TOPLEFT", px, py)
			pin.bossName = displayName
			pin.comment = comment
			pin.atlasKey = atlasKey
			if type(atlasBossIndex) == "table" then
				pin.atlasEntries = atlasBossIndex
				pin.atlasBossIndex = nil
			else
				pin.atlasEntries = nil
				pin.atlasBossIndex = atlasBossIndex
			end
			pin.instanceMapID = instanceMapID
			pin.bossOrdinal = ordinal
			pin.removed = removed
			pin.altTexture = useAltTexture
			pin.lootTexture = useLootTexture
			pin.objectTexture = useObjectTexture
			local tex = useObjectTexture and DMV_BOSS_PIN_TEXTURE_OBJECT
				or (useLootTexture and DMV_BOSS_PIN_TEXTURE_LOOT
				or (useAltTexture and DMV_BOSS_PIN_TEXTURE_ALT or DMV_BOSS_PIN_TEXTURE))
			pin.icon:SetTexture(tex)
			pin.highlight:SetTexture(tex)
			local pinSize = (useAltTexture or useLootTexture or useObjectTexture)
				and DMV_BOSS_PIN_SIZE_ALT or DMV_BOSS_PIN_SIZE
			pin:SetSize(pinSize, pinSize)
			if removed then
				pin.icon:SetDesaturated(true)
				pin.icon:SetVertexColor(1, 0.3, 0.3)
			else
				pin.icon:SetDesaturated(false)
				pin.icon:SetVertexColor(1, 1, 1)
			end
			if DMV_CalibMode then
				pin.label:SetText(tostring(atlasBossIndex))
				pin.label:Show()
			else
				pin.label:Hide()
			end
			pin:Show()
			end -- else (pin not skipped by setting)
		end
	end
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
		DMV_UpdateBossPinDropDown()
		if not DMV_Settings or DMV_Settings.showMarkersDropdown ~= false then
			DMV_BossPinDropDown:Show()
		end
	end
	pcall(DMV_HideBossPins)
	pcall(DMV_ShowBossPins)
	if not DMV_CoordsDisabled and (not DMV_Settings or DMV_Settings.showCoords ~= false) then
		if DMV_CoordsFrame		 then DMV_CoordsFrame:Show()	   end
		if DMV_PlayerCoordsFrame then DMV_PlayerCoordsFrame:Show() end
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

	SafeShow(GetContinentDropdown())
	SafeShow(GetZoneDropdown())
	if DMV_CoordsFrame		 then DMV_CoordsFrame:Hide()	   end
	if DMV_PlayerCoordsFrame then DMV_PlayerCoordsFrame:Hide() end
	DMV_Visible = false

	if DMV_PreviewMode then
		DMV_CurrentDungeon = nil
		DMV_PreviewMode = false
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
			if DMV_Settings then DMV_Settings.activeTransition = nil end
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
		end
	else
		-- Player has left all dungeons. Wipe persisted floor memory so a
		-- future visit starts fresh instead of restoring a stale floor.
		DMV_LastKnownFloor = {}
		if DMV_Settings then
			DMV_Settings.logoutSnapshot  = nil
			DMV_Settings.activeTransition = nil
		end
		DMV_CurrentDungeon = nil
		DMV_HideFrames()
	end
end

-- Event handler: Zone changed indoors (floor switching)
local DMV_TransitionElapsed = 0
local DMV_TRANSITION_INTERVAL = 0.1  -- 10 checks per second

function DMV_StartTransitionTicker()
	if DMV_TransitionFrame then return end
	DMV_TransitionFrame = CreateFrame("Frame", "DMV_TransitionFrame")
	DMV_TransitionFrame:SetScript("OnUpdate", function(self, elapsed)
		DMV_TransitionElapsed = DMV_TransitionElapsed + elapsed
		if DMV_TransitionElapsed >= DMV_TRANSITION_INTERVAL then
			DMV_TransitionElapsed = 0
			local _, instanceType = GetInstanceInfo()
			if instanceType == "party" or instanceType == "raid" then
				DMV_DetectFloorFromPosition()
			end
		end
	end)
end

function DMV_StopTransitionTicker()
	if DMV_TransitionFrame then
		DMV_TransitionFrame:SetScript("OnUpdate", nil)
		DMV_TransitionFrame = nil
		DMV_TransitionElapsed = 0
	end
end

-- Detect the correct floor by checking which rect's coordinate bounds
-- contain the player's current world position. This handles dungeons where
-- subzone names don't change between floors.
-- Resolve the dungeon the player is physically inside (never the previewed one).
function DMV_GetRealDungeon()
	local _, instanceType, _, _, _, _, _, instanceMapID = GetInstanceInfo()
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
		DMV_InstanceBrowseMode	= nil
		DMV_InstanceContinentID = nil
		DMV_InstanceZoneID		= nil
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

function DMV_DetectFloorFromPosition()
	if not DMV_GetRealDungeon() then return end
	local _, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
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
			local function checkAxis(prev, cur, threshold, dir)
				if not threshold then return nil end
				dir = dir or "gt"
				if dir == "lt" then
					return prev >= threshold and cur < threshold
				elseif dir == "eq" then
					return math.abs(cur - threshold) < 0.01
				else -- "gt"
					return prev <= threshold and cur > threshold
				end
			end

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
					local norm = sz:gsub(" ", ""):gsub("'", "'")
					local resolvedSubzone = (L and L[t.subzone] and L[t.subzone] ~= "") and L[t.subzone] or t.subzone
					local tNorm = resolvedSubzone:gsub(" ", ""):gsub("'", "'")
					if norm ~= tNorm and sz ~= resolvedSubzone then inBounds = false end
				end

				if inBounds then
					local toFloor = t.toFloor
					-- Save transition to SavedVariables so the correct floor
					-- is immediately available when the map is opened.
					if not DMV_Settings then DMV_Settings = {} end
					DMV_Settings.activeTransition = {
						instanceMapID = instanceMapID,
						floor		  = toFloor,
						posX		  = posX,
						posY		  = posY,
					}
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

	-- Collect all non-empty candidate strings as a set for transition matching.
	local candidateSet = {}
	for _, subzone in ipairs(candidates) do
		if subzone and subzone ~= "" then
			candidateSet[subzone] = true
			candidateSet[subzone:gsub(" ", "")] = true
			candidateSet[subzone:gsub(" ", ""):gsub("'", "'")] = true
		end
	end

	-- Check DMV_FloorTransitions for subzone trigger entries (subzoneMode ~= "condition").
	-- These respect fromFloor just like coordinate transitions.
	local _, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
	local transitions = DMV_FloorTransitions and instanceMapID and DMV_FloorTransitions[instanceMapID]
	if transitions then
		for _, t in ipairs(transitions) do
			local tSubzone = t.subzone
			if tSubzone and L and L[tSubzone] and L[tSubzone] ~= "" then
				tSubzone = L[tSubzone]
			end
			if tSubzone
			   and t.subzoneMode ~= "condition"
			   and (not t.fromFloor or t.fromFloor == DMV_ActualFloor)
			   and candidateSet[tSubzone] then
				local toFloor = t.toFloor
				if toFloor ~= DMV_ActualFloor then
					if not DMV_Settings then DMV_Settings = {} end
					DMV_Settings.activeTransition = {
						instanceMapID = instanceMapID,
						floor		  = toFloor,
					}
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
-- Items: one SetHyperlink call per OnUpdate frame on a hidden GameTooltip,
-- identical to MobInfo2/aux populate_wdb.  After the queue drains, a sweep
-- reads GetItemNameByID for anything that didn't fire GET_ITEM_INFO_RECEIVED.
local DMV_PRELOAD_WINDOW = 32

-- Generic (n/o/q) queue
local DMV_PreloadQueue	 = nil	 -- array of idStr e.g. "n11324"
local DMV_PreloadPending = 0

local function DMV_PreloadGeneric_Next()
	if not DMV_PreloadQueue then return end
	while DMV_PreloadPending < DMV_PRELOAD_WINDOW
			and table.getn(DMV_PreloadQueue) > 0 do
		local idStr = DMV_PreloadQueue[table.getn(DMV_PreloadQueue)]
		local prefix = string.sub(idStr, 1, 1)
		local id	 = tonumber(string.sub(idStr, 2))
		-- skip if already in DMV_NameCache (synchronous hit on a prior pass)
		if DMV_NameCache[idStr] then
			DMV_PreloadQueue[table.getn(DMV_PreloadQueue)] = nil
		else
			local ok
			if prefix == "n" then
				-- peek first; may already be in the client cache
				local info = C_CreatureInfo.GetCreatureInfoByID(id)
				if info and info.name then
					DMV_NameCache[idStr] = info.name
					DMV_PreloadQueue[table.getn(DMV_PreloadQueue)] = nil
				else
					DMV_PreloadPending = DMV_PreloadPending + 1
					ok = C_CreatureInfo.RequestLoadCreatureByID(id)
					DMV_PreloadQueue[table.getn(DMV_PreloadQueue)] = nil
					if not ok then
						DMV_PreloadPending = DMV_PreloadPending - 1
						break  -- pending set full; wait for a slot
					end
				end
			elseif prefix == "o" then
				local info = C_GameObjectInfo.GetGameObjectInfoByID(id)
				if info and info.name then
					DMV_NameCache[idStr] = info.name
					DMV_PreloadQueue[table.getn(DMV_PreloadQueue)] = nil
				else
					DMV_PreloadPending = DMV_PreloadPending + 1
					ok = C_GameObjectInfo.RequestLoadGameObjectByID(id)
					DMV_PreloadQueue[table.getn(DMV_PreloadQueue)] = nil
					if not ok then
						DMV_PreloadPending = DMV_PreloadPending - 1
						break
					end
				end
			elseif prefix == "q" then
				local details = C_QuestLog.GetQuestDetails(id)
				if details and details.title then
					DMV_NameCache[idStr] = { details.title, details.level or 0 }
					DMV_PreloadQueue[table.getn(DMV_PreloadQueue)] = nil
				else
					DMV_PreloadPending = DMV_PreloadPending + 1
					ok = C_QuestLog.RequestLoadQuestByID(id)
					DMV_PreloadQueue[table.getn(DMV_PreloadQueue)] = nil
					if not ok then
						DMV_PreloadPending = DMV_PreloadPending - 1
						break
					end
				end
			else
				DMV_PreloadQueue[table.getn(DMV_PreloadQueue)] = nil
			end
		end
	end
	if DMV_PreloadQueue and table.getn(DMV_PreloadQueue) == 0 then
		DMV_PreloadQueue = nil
	end
end

-- Item queue
-- Hidden GameTooltip used to force the client to load item data into the WDB,
-- matching MobInfo2's MI2_ItemCacheTooltip/aux populate_wdb technique.
local DMV_ItemCacheTooltip = CreateFrame("GameTooltip", "DMV_ItemCacheTooltip", UIParent, "GameTooltipTemplate")
DMV_ItemCacheTooltip:Hide()

local DMV_ItemPreloadQueue = nil  -- array of raw item IDs (numbers)

local function DMV_PreloadItems_Start()
	if not DMV_ItemPreloadQueue or table.getn(DMV_ItemPreloadQueue) == 0 then return end

	local idx = 1
	DMV_ItemCacheTooltip:SetOwner(UIParent, "ANCHOR_NONE")

	local frame = CreateFrame("Frame")
	frame:SetScript("OnUpdate", function()
		if idx > table.getn(DMV_ItemPreloadQueue) then
			-- Queue drained. Sweep for items that didn't fire GET_ITEM_INFO_RECEIVED.
			frame:SetScript("OnUpdate", nil)
			DMV_ItemCacheTooltip:Hide()
			for _, itemID in ipairs(DMV_ItemPreloadQueue) do
				local idStr = "i" .. itemID
				if not DMV_NameCache[idStr] then
					local iname   = C_Item.GetItemNameByID(itemID)
					local quality = C_Item.GetItemQualityByID(itemID)
					if iname then
						DMV_NameCache[idStr] = { iname, quality or 1 }
					end
				end
			end
			DMV_ItemPreloadQueue = nil
			return
		end
		local itemID = DMV_ItemPreloadQueue[idx]
		local idStr  = "i" .. itemID
		if not DMV_NameCache[idStr] and not C_Item.IsItemDataCachedByID(itemID) then
			DMV_ItemCacheTooltip:SetHyperlink("item:" .. itemID)
		end
		idx = idx + 1
	end)
end

-- Collect all IDs from DungeonData and kick off both queues
local function DMV_WarmupCache()
	if not DMV_Markers then return end

	local seenGeneric = {}
	local seenItem	  = {}
	local genericQueue = {}
	local itemQueue    = {}

	for _, data in pairs(DMV_Markers) do
		for _, boss in ipairs(data) do
			-- name field: strip !, A , H  prefixes then check for ID prefix
			local name = boss[1]
			if name then
				name = string.gsub(name, "^!+", "")
				name = string.gsub(name, "^[AH] ", "")
				-- Scan all n/o/q/i tokens from the name field (there may be
				-- multiple, e.g. "n3864 / n3865").
				for p, d in string.gmatch(name, "([noq])(%d+)") do
					local idStr = p .. d
					if not seenGeneric[idStr] then
						seenGeneric[idStr] = true
						genericQueue[table.getn(genericQueue) + 1] = idStr
					end
				end
				for d in string.gmatch(name, "i(%d+)") do
					local id = tonumber(d)
					if id and not seenItem[id] then
						seenItem[id] = true
						itemQueue[table.getn(itemQueue) + 1] = id
					end
				end
			end
			-- comment field: scan for all n/o/q/i <id> tokens
			local comment = boss[7]
			if comment then
				for prefix, digits in string.gmatch(comment, "([noqi])(%d+)") do
					if prefix == "i" then
						local id = tonumber(digits)
						if id and not seenItem[id] then
							seenItem[id] = true
							itemQueue[table.getn(itemQueue) + 1] = id
						end
					else
						local idStr = prefix .. digits
						if not seenGeneric[idStr] then
							seenGeneric[idStr] = true
							genericQueue[table.getn(genericQueue) + 1] = idStr
						end
					end
				end
			end
		end
	end

	if table.getn(genericQueue) > 0 then
		DMV_PreloadQueue   = genericQueue
		DMV_PreloadPending = 0
		DMV_PreloadGeneric_Next()
	end

	if table.getn(itemQueue) > 0 then
		DMV_ItemPreloadQueue = itemQueue
		DMV_PreloadItems_Start()
	end
end

-- Main event frame
local EventFrame = CreateFrame("Frame", "DMV_EventFrame", UIParent)

EventFrame:RegisterEvent("ADDON_LOADED") -- fires for both Atlas and DungeonMapsVanilla
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
	if event == "ADDON_LOADED" and arg1 == "Atlas" then
		-- When AtlasFrame is closed, restore its frame level to the default (0)
		-- so subsequent non-DMV opens are unaffected.
		AtlasFrame:HookScript("OnHide", function()
			AtlasFrame:SetFrameStrata("MEDIUM")
		end)
	elseif event == "ADDON_LOADED" and arg1 == "DungeonMapsVanilla" then
		if not DMV_Settings then DMV_Settings = {} end
		if DMV_Settings.bossPins	== nil then DMV_Settings.bossPins	 = true end
		if DMV_Settings.bossPinAlt	== nil then DMV_Settings.bossPinAlt  = true end
		if DMV_Settings.bossPinLoot == nil then DMV_Settings.bossPinLoot = true end
		if DMV_Settings.bossPinObject == nil then DMV_Settings.bossPinObject = true end
		if DMV_Settings.bossFaction == nil then DMV_Settings.bossFaction = "all" end
		if DMV_Settings.overlayScale == nil then DMV_Settings.overlayScale = 1.0 end
		if DMV_Settings.showPartyBlips == nil then DMV_Settings.showPartyBlips = true end
		if DMV_Settings.showRaidBlips  == nil then DMV_Settings.showRaidBlips  = true end
		if not DMV_GlobalSettings then DMV_GlobalSettings = {} end
		if DMV_GlobalSettings.bossPinOverrides == nil then DMV_GlobalSettings.bossPinOverrides = {} end
	elseif event == "PLAYER_ENTERING_WORLD" then
		DMV_CreateInterfaceOptionsPanel()
		-- Reset faction cache so it re-queries once the player is in world.
		DMV_PlayerFaction = nil
		-- Restore floor snapshot saved at logout/reload so DMV_OnEnterWorld
		-- picks up the correct floor via DMV_LastKnownFloor.
		local snap = DMV_Settings and DMV_Settings.logoutSnapshot
		if snap and snap.instanceMapID and snap.floor then
			DMV_LastKnownFloor[snap.instanceMapID] = snap.floor
		end
		DMV_OnEnterWorld()
		-- Clear the snapshot after consuming it so a fresh login to a
		-- different dungeon is not affected by stale data.
		if DMV_Settings then DMV_Settings.logoutSnapshot = nil end
		-- Start the background transition ticker; it self-gates via GetInstanceInfo().
		DMV_StartTransitionTicker()
		-- Warm up the name cache so all pin names and item comment tokens
		-- are resolved before the player can open the map.
		DMV_WarmupCache()
	elseif event == "PLAYER_LOGOUT" then
		-- Stop the ticker and wipe transition data when logging out.
		DMV_StopTransitionTicker()
		if not DMV_Settings then DMV_Settings = {} end
		local _, instanceType, _, _, _, _, _, instanceMapID = GetInstanceInfo()
		if (instanceType == "party" or instanceType == "raid") and instanceMapID then
			local posY, posX = UnitPosition("player")
			DMV_Settings.logoutSnapshot = {
				instanceMapID = instanceMapID,
				floor		  = DMV_ActualFloor,
				posX		  = posX,
				posY		  = posY,
			}
		else
			DMV_Settings.logoutSnapshot = nil
			DMV_Settings.activeTransition = nil
		end
	elseif event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED" or event == "MINIMAP_UPDATE_ZOOM" then
		DMV_OnZoneChanged()
		-- If the player has left the dungeon, wipe the active transition.
		local _, instanceType = GetInstanceInfo()
		if instanceType ~= "party" and instanceType ~= "raid" then
			if DMV_Settings then DMV_Settings.activeTransition = nil end
		end
	elseif event == "WORLD_MAP_UPDATE" then
		-- If the player manually navigated the world map (continent/zone/zoom)
		-- while the dungeon overlay is visible, hide the overlay so the selected
		-- map shows through. DMV_OnMapShow will restore it when the map is
		-- reopened or when the player navigates back to the dungeon.
		if DMV_Visible then
			if GetCurrentMapContinent() ~= -1 then
				DMV_HideFrames()
			else
				local mapZone = GetCurrentMapZone()
				if mapZone and mapZone ~= GetRealZoneText() then
					DMV_HideFrames()
				end
			end
		end
	elseif event == "CREATURE_DATA_LOAD_RESULT" then
		-- arg1 = creatureID, arg2 = success (1 or nil)
		if DMV_PreloadPending and DMV_PreloadPending > 0 then
			DMV_PreloadPending = DMV_PreloadPending - 1
		end
		if arg1 then
			local idStr = "n" .. arg1
			if arg2 then
				local info = C_CreatureInfo.GetCreatureInfoByID(arg1)
				DMV_NameCache[idStr] = (info and info.name) or idStr
			else
				DMV_NameCache[idStr] = idStr  -- load failed; use raw string
			end
			if DMV_Visible and DMV_CurrentDungeon then pcall(DMV_ShowBossPins) end
		end
		DMV_PreloadGeneric_Next()
	elseif event == "GAMEOBJECT_DATA_LOAD_RESULT" then
		-- arg1 = gameObjectID, arg2 = success (1 or nil)
		if DMV_PreloadPending and DMV_PreloadPending > 0 then
			DMV_PreloadPending = DMV_PreloadPending - 1
		end
		if arg1 then
			local idStr = "o" .. arg1
			if arg2 then
				local info = C_GameObjectInfo.GetGameObjectInfoByID(arg1)
				DMV_NameCache[idStr] = (info and info.name) or idStr
			else
				DMV_NameCache[idStr] = idStr
			end
			if DMV_Visible and DMV_CurrentDungeon then pcall(DMV_ShowBossPins) end
		end
		DMV_PreloadGeneric_Next()
	elseif event == "QUEST_DATA_LOAD_RESULT" then
		-- arg1 = questID, arg2 = success (1 or nil)
		if DMV_PreloadPending and DMV_PreloadPending > 0 then
			DMV_PreloadPending = DMV_PreloadPending - 1
		end
		if arg1 then
			local idStr = "q" .. arg1
			if arg2 then
				local details = C_QuestLog.GetQuestDetails(arg1)
				if details and details.title then
					DMV_NameCache[idStr] = { details.title, details.level or 0 }
				else
					DMV_NameCache[idStr] = idStr
				end
			else
				DMV_NameCache[idStr] = idStr
			end
			if DMV_Visible and DMV_CurrentDungeon then pcall(DMV_ShowBossPins) end
		end
		DMV_PreloadGeneric_Next()
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		-- arg1 = itemID, arg2 = success (1 or nil)
		if arg1 and arg2 then
			local idStr = "i" .. arg1
			local iname   = C_Item.GetItemNameByID(arg1)
			local quality = C_Item.GetItemQualityByID(arg1)
			if iname then
				DMV_NameCache[idStr] = { iname, quality or 1 }
				if WorldMapTooltip:IsShown() then
					WorldMapTooltip:Hide()
				end
			end
		end
	end
end)

-- Hook WorldMapFrame: show overlay when map opens in a dungeon.
-- Load the active transition floor first so the correct floor is shown
-- immediately. Also restores actual floor if the player was browsing.
-- Uses both HookScript (for clients that preserve the chain) and a polling
-- fallback via DMV_OnMapVisibilityChanged for clients like Magnify that
-- replace OnShow with SetScript, breaking HookScript chains.
local function DMV_OnMapShow()
	if not DMV_Initialized then DMV_CreateFrames() end

	-- If CurrentDungeon was wiped because the map was closed during a preview
	-- session, re-detect from GetInstanceInfo so a real dungeon is restored.
	if not DMV_CurrentDungeon then
		local _, instanceType, _, _, _, _, _, instanceMapID = GetInstanceInfo()
		if (instanceType == "party" or instanceType == "raid") and instanceMapID then
			local entry = DMV_DungeonByMapID[instanceMapID]
			if entry then
				DMV_CurrentDungeon = entry[1]
				if not DMV_ActualFloor or DMV_ActualFloor == 0 then
					DMV_ActualFloor = DMV_LastKnownFloor[instanceMapID] or 1
				end
			end
		end
	end

	if DMV_CurrentDungeon then
		local _, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
		local tr = DMV_Settings and DMV_Settings.activeTransition
		if tr and tr.instanceMapID == instanceMapID and tr.floor then
			if tr.floor ~= DMV_ActualFloor then
				DMV_LastKnownFloor[instanceMapID] = tr.floor
				DMV_ActualFloor = tr.floor
			end
		end
		-- Always re-apply textures so any stale preview dungeon is cleared.
		DMV_SetTextures(DMV_CurrentDungeon, DMV_ActualFloor or DMV_CurrentFloor)
		DMV_ShowFrames()
	end
end

local function DMV_OnMapHide()
	DMV_Visible = false
	-- Both custom dropdowns are parented independently of the map's normal
	-- dropdown pool, so explicitly close them whenever the world map closes.
	if DMV_HideAreaList then DMV_HideAreaList() end
	if DMV_HideMarkerList then DMV_HideMarkerList() end
	if DMV_ClickFrame then DMV_ClickFrame:Hide() end
	DMV_StopArrowUpdates()

	-- If the map was closed while showing a preview dungeon (browse mode),
	-- hide the frames and restore the real map so it shows correctly on next open.
	if DMV_PreviewMode then
		DMV_HideFrames()
		SetMapToCurrentZone()
	end

	-- Clear instance browse mode; it is transient UI state that must not
	-- persist across map open/close cycles.
	DMV_InstanceBrowseMode	= nil
	DMV_InstanceContinentID = nil
	DMV_InstanceZoneID		= nil

	-- Re-initialize the zone dropdown so it reverts to real zones rather
	-- than the stale dungeon/raid list from browse mode.
	local zoneDD = GetZoneDropdown()
	if zoneDD then
		UIDropDownMenu_Initialize(zoneDD, WorldMapZoneDropDown_Initialize)
	end
end

WorldMapFrame:HookScript("OnShow", DMV_OnMapShow)
WorldMapFrame:HookScript("OnHide", DMV_OnMapHide)

-- Polling fallback: detect map open/close each ticker tick so that addons
-- which overwrite WorldMapFrame's OnShow via SetScript (e.g. Magnify) do not
-- silently prevent DMV_OnMapShow from running.
-- Polling fallback frame: always running, low cost (IsShown is cheap).
-- Catches map open/close events even when addons like Magnify overwrite
-- WorldMapFrame's OnShow/OnHide scripts via SetScript.
DMV_MapWasVisible = false
local DMV_MapPollFrame = CreateFrame("Frame", "DMV_MapPollFrame")
DMV_MapPollFrame:SetScript("OnUpdate", function()
	local visible = WorldMapFrame:IsShown()
	if visible and not DMV_MapWasVisible then
		DMV_MapWasVisible = true
		if not DMV_Visible then
			DMV_OnMapShow()
		end
	elseif not visible and DMV_MapWasVisible then
		DMV_MapWasVisible = false
		DMV_OnMapHide()
	end
end)

-- Instance browser in continent/zone dropdowns
-- Adds "Dungeons" and "Raids" entries to the continent dropdown.
-- Selecting one populates the zone dropdown with a sorted list of
-- instance names; selecting an instance enters preview mode for it.

-- "dungeon", "raid", or nil when a real continent is selected.
-- (DMV_InstanceBrowseMode/ContinentID/ZoneID declared at top of file)

-- Build sorted { mapID, displayName } list for dungeons or raids.
local function DMV_BuildInstanceList(raidsOnly)
	local list = {}
	for mapID, entry in pairs(DMV_DungeonByMapID) do
		local isRaid = entry[3]
		if (raidsOnly and isRaid) or (not raidsOnly and not isRaid) then
			list[#list + 1] = { mapID = mapID, name = entry[2] }
		end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

-- Hook continent dropdown to append Dungeons / Raids entries.
local _origContinentsInit = WorldMapContinentsDropDown_Initialize
WorldMapContinentsDropDown_Initialize = function()
	_origContinentsInit()
	local continentDD = WorldMapContinentDropDown or WorldMapContinentDropdown
	local continents = { GetMapContinents() }
	local numContinents = #continents
	local dungeonID = numContinents + 1
	local raidID	= numContinents + 2

	local info = {}
	info.text = L["Dungeons"]
	info.func = function()
		DMV_InstanceBrowseMode = "dungeon"
		DMV_InstanceZoneID = nil
		DMV_InstanceContinentID = dungeonID
		UIDropDownMenu_SetSelectedID(continentDD, dungeonID)
		local zoneDD = WorldMapZoneDropDown or WorldMapZoneDropdown
		if zoneDD then
			UIDropDownMenu_Initialize(zoneDD, WorldMapZoneDropDown_Initialize)
		end
	end
	UIDropDownMenu_AddButton(info)

	info = {}
	info.text = L["Raids"]
	info.func = function()
		DMV_InstanceBrowseMode = "raid"
		DMV_InstanceZoneID = nil
		DMV_InstanceContinentID = raidID
		UIDropDownMenu_SetSelectedID(continentDD, raidID)
		local zoneDD = WorldMapZoneDropDown or WorldMapZoneDropdown
		if zoneDD then
			UIDropDownMenu_Initialize(zoneDD, WorldMapZoneDropDown_Initialize)
		end
	end
	UIDropDownMenu_AddButton(info)

end

-- Hook zone dropdown to show instance names when a category is selected.
local _origZoneInit = WorldMapZoneDropDown_Initialize
WorldMapZoneDropDown_Initialize = function()
	if not DMV_InstanceBrowseMode then
		_origZoneInit()
		return
	end
	local zoneDD = WorldMapZoneDropDown or WorldMapZoneDropdown
	local list = DMV_BuildInstanceList(DMV_InstanceBrowseMode == "raid")
	for i, entry in ipairs(list) do
		local mapID   = entry.mapID
		local entryID = i
		local info = {}
		info.text = entry.name
		info.func = function()
			local folder = DMV_DungeonByMapID[mapID] and DMV_DungeonByMapID[mapID][1]
			if not folder then return end
			DMV_InstanceZoneID = entryID
			UIDropDownMenu_SetSelectedID(zoneDD, entryID)
			DMV_HideFrames()
			DMV_PreviewMode = true
			DMV_SetTextures(folder, 1)
			if WorldMapFrame:IsVisible() then
				DMV_ShowFrames()
			end
		end
		UIDropDownMenu_AddButton(info)
	end
end

-- Clicking a real continent clears instance browse mode.
local _origContinentClick = WorldMapContinentButton_OnClick
WorldMapContinentButton_OnClick = function()
	DMV_InstanceBrowseMode = nil
	DMV_InstanceContinentID = nil
	DMV_InstanceZoneID = nil
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
	DMV_OptionsPanelCreated = true

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
	DMV_WindowScaleSliderLow:SetText("0.50")
	DMV_WindowScaleSliderHigh:SetText("1.00")
	DMV_WindowScaleSliderText:SetText("")

	local valueText = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	valueText:SetPoint("TOP", slider, "BOTTOM", 0, -2)
	slider.valueText = valueText

	slider:SetScript("OnValueChanged", function(self, val)
		if self.updating then return end
		val = math.floor(val / 0.05 + 0.5) * 0.05
		valueText:SetText(string.format("%.2f", val))
		DMV_SetWindowScale(val)
	end)

	local blipCheck = CreateFrame("CheckButton", "DMV_PartyBlipCheck", panel, "UICheckButtonTemplate")
	blipCheck:SetPoint("TOPLEFT", 12, -120)
	DMV_PartyBlipCheckText:SetText(L["Opt2"])
	blipCheck:SetScript("OnClick", function(self)
		if DMV_Settings then DMV_Settings.showPartyBlips = self:GetChecked() and true or false end
		if DMV_UpdatePartyBlips then DMV_UpdatePartyBlips() end
	end)

	local raidBlipCheck = CreateFrame("CheckButton", "DMV_RaidBlipCheck", panel, "UICheckButtonTemplate")
	raidBlipCheck:SetPoint("TOPLEFT", 12, -148)
	DMV_RaidBlipCheckText:SetText(L["Opt2b"])
	raidBlipCheck:SetScript("OnClick", function(self)
		if DMV_Settings then DMV_Settings.showRaidBlips = self:GetChecked() and true or false end
		if DMV_UpdatePartyBlips then DMV_UpdatePartyBlips() end
	end)

	local markerCheck = CreateFrame("CheckButton", "DMV_ShowMarkersCheck", panel, "UICheckButtonTemplate")
	markerCheck:SetPoint("TOPLEFT", 12, -176)
	DMV_ShowMarkersCheckText:SetText(L["Opt3"])
	markerCheck:SetScript("OnClick", function(self)
		if DMV_Settings then DMV_Settings.showMarkersDropdown = self:GetChecked() and true or false end
		if DMV_BossPinDropDown then
			if DMV_Settings and DMV_Settings.showMarkersDropdown ~= false then
				if WorldMapFrame:IsVisible() and DMV_BossPinDropDown:IsVisible() ~= nil then
					DMV_BossPinDropDown:Show()
				end
			else
				DMV_BossPinDropDown:Hide()
			end
		end
	end)

	local coordCheck = CreateFrame("CheckButton", "DMV_ShowCoordsCheck", panel, "UICheckButtonTemplate")
	coordCheck:SetPoint("TOPLEFT", 12, -204)
	DMV_ShowCoordsCheckText:SetText(L["Opt4"])
	coordCheck:SetScript("OnClick", function(self)
		if DMV_Settings then DMV_Settings.showCoords = self:GetChecked() and true or false end
		if not DMV_CoordsDisabled then
			local show = DMV_Settings and DMV_Settings.showCoords ~= false
			if DMV_CoordsFrame		 then DMV_CoordsFrame[show and "Show" or "Hide"](DMV_CoordsFrame) end
			if DMV_PlayerCoordsFrame then DMV_PlayerCoordsFrame[show and "Show" or "Hide"](DMV_PlayerCoordsFrame) end
		end
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
		if not DMV_CoordsDisabled then
			if DMV_CoordsFrame		 then DMV_CoordsFrame:Show() end
			if DMV_PlayerCoordsFrame then DMV_PlayerCoordsFrame:Show() end
		end
	end

	InterfaceOptions_AddCategory(panel)
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
		if DMV_Visible then
			DMV_HideBossPins(); DMV_ShowBossPins()
		end
		print(L["Calib Reset2"])
	elseif msg == "calib" then
		DMV_CalibMode = not DMV_CalibMode
		if DMV_Visible then
			DMV_HideBossPins(); DMV_ShowBossPins()
		end
		if DMV_CalibMode then
			print(L["Calib On"])
		else
			print(L["Calib Off"])
		end
	elseif msg == "arrow" then
		local posY, posX, posZ = UnitPosition("player")
		local _, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
		print(string.format("  posZ=%.4f", posZ or 0))
		local floorRects = DMV_FloorMapRects and DMV_FloorMapRects[instanceMapID]
		local rect = floorRects and floorRects[DMV_CurrentFloor]
		if rect and not rect.locLeft then rect = nil end
		print(string.format("|cff00ff00DMV Arrow|r: posY=%.4f posX=%.4f instanceMapID=%s floor=%s",
			posY or 0, posX or 0, tostring(instanceMapID), tostring(DMV_CurrentFloor)))
		if rect then
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
			tostring(DMV_Visible), tostring(DMV_PlayerArrowTicker ~= nil),
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
		print("  ArrowTicker: " .. tostring(DMV_PlayerArrowTicker ~= nil))
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