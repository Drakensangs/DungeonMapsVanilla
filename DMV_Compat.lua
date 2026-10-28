-- DMV_Compat.lua

-- WorldMap Window fallback
-- When ShaguTweaks's WorldMap Window module is not active, DMV applies a
-- window mode transform so that Magnify compatibility works correctly.

DMV_WINDOW_SCALE = 1

function DMV_GetWindowScale()
	return (DMV_Settings and DMV_Settings.windowScale) or 1
end

function DMV_SetWindowScale(val)
	val = math.max(0.5, math.min(1.0, val))
	if DMV_Settings then DMV_Settings.windowScale = val end
	DMV_WINDOW_SCALE = val
	if WorldMapFrame and WorldMapFrame:IsVisible() then
		WorldMapFrame:SetScale(DMV_WINDOW_SCALE)
	end
end


local function DMV_NeedsWindowFallback()
	if pfUI and pfUI.map then return false end
	return not (ShaguTweaks and ShaguTweaks.WorldMapWindowActive == true)
end

local DMV_WindowFallbackInstalled = false

local function DMV_ApplyWindowFallback()
	if not DMV_NeedsWindowFallback() then return end
	if not WorldMapFrame or not WorldMapButton then return end

	-- Remove WorldMapFrame from the full-screen UI panel system so it behaves
	-- as a plain window (chat remains usable while the map is open).
	UIPanelWindows["WorldMapFrame"] = { area = "center" }

	-- Replace ToggleWorldMap with a simple Show/Hide so the map no longer
	-- triggers the full-screen panel blackout.
	if not DMV_WindowFallbackInstalled then
		local origToggle = ToggleWorldMap
		function ToggleWorldMap()
			if WorldMapFrame:IsShown() then
				WorldMapFrame:Hide()
			else
				WorldMapFrame:Show()
			end
		end
	end

	-- Re-apply scale and layout on every map open so it survives other
	-- addons resetting the frame (mirrors ShaguTweaks's OnShow hook).
	-- Centering is deferred one frame via OnUpdate so it runs after
	-- ShowUIPanel (called by the stock OnShow) has finished repositioning.
	if not DMV_WindowFallbackInstalled then
		local oldOnShow = WorldMapFrame:GetScript("OnShow")
		WorldMapFrame:SetScript("OnShow", function()
			if oldOnShow then oldOnShow() end
			WorldMapFrame:EnableKeyboard(false)
			WorldMapFrame:SetScale(DMV_WINDOW_SCALE)
			WorldMapFrame:SetScript("OnUpdate", function()
				WorldMapFrame:SetScript("OnUpdate", nil)
				WorldMapFrame:ClearAllPoints()
				WorldMapFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
			end)
		end)

		WorldMapFrame:SetMovable(true)
		WorldMapFrame:EnableMouse(true)

		local oldOnMouseDown = WorldMapFrame:GetScript("OnMouseDown")
		WorldMapFrame:SetScript("OnMouseDown", function()
			WorldMapFrame:StartMoving()
			if oldOnMouseDown then oldOnMouseDown() end
		end)
		local oldOnMouseUp = WorldMapFrame:GetScript("OnMouseUp")
		WorldMapFrame:SetScript("OnMouseUp", function()
			WorldMapFrame:StopMovingOrSizing()
			if oldOnMouseUp then oldOnMouseUp() end
		end)
	end

	DMV_WindowFallbackInstalled = true

	-- Register with UISpecialFrames so Escape closes the map.
	local alreadyRegistered = false
	for i = 1, table.getn(UISpecialFrames) do
		if UISpecialFrames[i] == "WorldMapFrame" then
			alreadyRegistered = true
			break
		end
	end
	if not alreadyRegistered then
		table.insert(UISpecialFrames, "WorldMapFrame")
	end

	-- Initial frame layout.
	WorldMapFrame:SetScale(DMV_WINDOW_SCALE)
	WorldMapFrame:ClearAllPoints()
	WorldMapFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	WorldMapFrame:SetWidth(WorldMapButton:GetWidth() + 15)
	WorldMapFrame:SetHeight(WorldMapButton:GetHeight() + 55)
	if BlackoutWorld then BlackoutWorld:Hide() end

	-- Reposition the scroll frame to match what Magnify's HandleAddons does
	-- when ShaguTweaks is loaded (-48 offset instead of the XML default -70).
	-- Without this the map canvas overflows the frame chrome at top and bottom.
	if WorldMapFrameScrollFrame then
		WorldMapFrameScrollFrame:SetPoint("TOP", WorldMapFrame, "TOP", 0, -48)
	end

	-- Prevent scroll wheel events from falling through WorldMapFrame to the
	-- game camera. Vanilla WorldMapFrame does not consume scroll events by
	-- default when run as a window rather than a full-screen frame.
	WorldMapFrame:EnableMouseWheel(true)
	WorldMapFrame:SetScript("OnMouseWheel", function() end)
end

-- Magnify
local function DMV_ApplyMagnifyCompat()
	if not IsAddOnLoaded("Magnify") then return end

	-- pfUI's map module manages WorldMapFrame sizing itself; yielding to it
	-- avoids a conflict where DMV's window fallback overrides pfUI's scale.
	if not (pfUI and pfUI.map) then
		DMV_ApplyWindowFallback()
	end

	-- 1. Arrow
	-- Use Magnify's WorldMapArrow texture on DMV_PlayerArrow.
	-- SetRotation (ClassicAPI backport): positive = counter-clockwise.
	-- GetPlayerFacing(): positive = clockwise.
	-- Both are clockwise in WoW's convention, so pass facing directly.
	-- Size follows Magnify's arrow_scale, inverse-scaled with map zoom.

	local magnifyTexture = "Interface\\AddOns\\Magnify\\assets\\WorldMapArrow"
	local arrowTextureSet = false

	local origUpdateArrow = DMV_UpdatePlayerArrow
	DMV_UpdatePlayerArrow = function()
		origUpdateArrow()

		if not DMV_PlayerArrow or not DMV_PlayerArrow:IsShown() then return end

		if not arrowTextureSet and DMV_PlayerArrow.tex then
			DMV_PlayerArrow.tex:SetTexture(magnifyTexture)
			arrowTextureSet = true
		end

		local mapScale = (WorldMapDetailFrame and WorldMapDetailFrame:GetScale()) or 1
		local baseSize = 24 * ((Magnify_Settings and Magnify_Settings["arrow_scale"]) or 1)
		DMV_PlayerArrow:SetSize(baseSize / mapScale, baseSize / mapScale)

		local facing = (GetPlayerFacing and GetPlayerFacing()) or 0
		DMV_PlayerArrow.tex:SetRotation(facing)
	end

	-- 2. Scroll wheel
	-- DMV_ClickFrame may not exist at PLAYER_ENTERING_WORLD if the player logs
	-- in outside a dungeon, it is created lazily inside DMV_CreateFrames which
	-- only runs when a dungeon map is first shown. We therefore install the
	-- wheel handler by hooking DMV_ShowFrames, which is always called before
	-- DMV_ClickFrame is made visible.
	--
	-- Magnify's cursor-centred zoom math is inlined here so we never need to
	-- call WorldMapFrameScrollFrame_OnMouseWheel() with a wrong 'this'.
	-- DMV_Container is a child of WorldMapDetailFrame and follows it
	-- automatically when it is scaled/scrolled.

	local function DMV_InstallWheelHandler()
		if not DMV_ClickFrame then return end
		DMV_ClickFrame:SetScript("OnMouseWheel", function(self, delta)
			local sf = WorldMapFrameScrollFrame
			if not sf or not WorldMapDetailFrame then return end

			local oldScrollH = sf:GetHorizontalScroll()
			local oldScrollV = sf:GetVerticalScroll()

			local cursorX, cursorY = GetCursorPosition()
			local effScale = sf:GetEffectiveScale()
			cursorX = cursorX / effScale
			cursorY = cursorY / effScale

			local frameX = cursorX - sf:GetLeft()
			local frameY = sf:GetTop() - cursorY

			local oldScale = WorldMapDetailFrame:GetScale()
			local newScale = oldScale + delta * (MAGNIFY_ZOOM_STEP or 0.2)
			newScale = math.max((MAGNIFY_MIN_ZOOM or 1.0), newScale)
			newScale = math.min((MAGNIFY_MAX_ZOOM or 4.0), newScale)

			WorldMapDetailFrame:SetScale(newScale)

			local maxX = ((WorldMapDetailFrame:GetWidth() * newScale) - sf:GetWidth()) / newScale
			local maxY = ((WorldMapDetailFrame:GetHeight() * newScale) - sf:GetHeight()) / newScale
			sf.zoomedIn = newScale > (MAGNIFY_MIN_ZOOM or 1.0)
			sf.maxX = maxX
			sf.maxY = maxY

			local centerX = -oldScrollH + frameX / oldScale
			local centerY =  oldScrollV + frameY / oldScale
			local newScrollH = centerX - frameX / newScale
			local newScrollV = centerY - frameY / newScale

			newScrollH = math.min(math.max(0, newScrollH), maxX)
			newScrollV = math.min(math.max(0, newScrollV), maxY)

			sf:SetHorizontalScroll(-newScrollH)
			sf:SetVerticalScroll(newScrollV)
		end)
	end

	local DMV_FlashTicker = CreateFrame("Frame")
	DMV_FlashTicker:Hide()
	DMV_FlashTicker:SetScript("OnUpdate", function()
		this.Elapsed = this.Elapsed + arg1
		if this.Elapsed > MAGNIFY_PLAYER_FLASH_INTERVAL then
			this.Elapsed = 0
			if this.Flashes < MAGNIFY_PLAYER_FLASH_COUNT then
				this.Flashes = this.Flashes + 1
				if DMV_PlayerArrow then
					DMV_PlayerArrow:SetAlpha(DMV_PlayerArrow:GetAlpha() == 1 and 0 or 1)
				end
			else
				this.Flashes = 0
				if DMV_PlayerArrow then DMV_PlayerArrow:SetAlpha(1) end
				this:Hide()
			end
		end
	end)

	local function DMV_FlashPlayerArrow()
		if not DMV_PlayerArrow then return end
		if Magnify_Settings and Magnify_Settings["arrow_flash"] then
			DMV_FlashTicker.Elapsed = 0
			DMV_FlashTicker.Flashes = 0
			DMV_FlashTicker:Show()
		else
			DMV_PlayerArrow:SetAlpha(1)
		end
	end

	local origShow = DMV_ShowFrames
	DMV_ShowFrames = function(...)
		origShow(...)
		DMV_InstallWheelHandler()
		DMV_FlashPlayerArrow()
	end

	-- 3. Strata: raise DMV controls above Magnify's scroll frame
	-- Called once now (in case we are already in a dungeon) and again inside
	-- DMV_ShowFrames via the hook above on subsequent opens.
	local function RaiseControls()
		local targets = {
			DMV_ClickFrame,
			DMV_LevelDropDown,
			DMV_LevelUpButton,
			DMV_LevelDownButton,
			DMV_BossPinDropDown,
			DMV_PlayerArrow,
			getglobal("DMV_LevelDropDownButton"),
			getglobal("DMV_BossPinDropDownButton"),
		}
		for _, w in ipairs(targets) do
			if w then w:SetFrameStrata("FULLSCREEN_DIALOG") end
		end
	end
	RaiseControls()

	-- 4. Area frame: suppress hover text while dungeon map is visible
	if WorldMapFrameAreaFrame and not DMV_AreaFrameCompatInstalled then
		DMV_AreaFrameCompatInstalled = true
		local savedOnUpdate = WorldMapFrameAreaFrame:GetScript("OnUpdate")

		local origShowArea = DMV_ShowFrames
		DMV_ShowFrames = function(...)
			origShowArea(...)
			if WorldMapFrameAreaFrame then
				WorldMapFrameAreaFrame:SetScript("OnUpdate", nil)
				WorldMapFrameAreaFrame:Hide()
			end
		end

		local origHideArea = DMV_HideFrames
		DMV_HideFrames = function(...)
			origHideArea(...)
			if WorldMapFrameAreaFrame then
				WorldMapFrameAreaFrame:SetScript("OnUpdate", savedOnUpdate)
			end
		end
	end
	-- 5. Party/raid blips: inverse-scale with map zoom
	-- Blips are children of DMV_Container which lives inside WorldMapDetailFrame,
	-- so they inherit its scale.  Resize them each update to counteract that.
	local origUpdateBlips = DMV_UpdatePartyBlips
	DMV_UpdatePartyBlips = function(...)
		origUpdateBlips(...)
		local mapScale = (WorldMapDetailFrame and WorldMapDetailFrame:GetScale()) or 1
		local scaledSize = BLIP_SIZE / mapScale
		for _, blip in pairs(DMV_PartyBlips) do
			if blip and blip:IsShown() then
				blip:SetSize(scaledSize, scaledSize)
			end
		end
	end
end

-- ShaguTweaks (no Magnify)
if not IsAddOnLoaded("Magnify") then
	DMV_ApplyWindowFallback()

	local function DMV_DisableWheelResize()
		if not DMV_ClickFrame then return end
		if DMV_ClickFrame._wheelOverridden then return end
		DMV_ClickFrame:SetScript("OnMouseWheel", nil)
		DMV_ClickFrame._wheelOverridden = true
	end

	local origShow = DMV_ShowFrames
	DMV_ShowFrames = function(...)
		origShow(...)
		DMV_DisableWheelResize()
	end
end

-- Coordinates
-- When Magnify is loaded, DMV feeds its existing MagnifyCoordsFrame (cursor)
-- and MagnifyPlayerFrame (player) with dungeon aware values, since
-- GetPlayerMapPosition returns 0,0 inside instances.
-- When Magnify is NOT loaded, DMV creates its own identical coordinate frames
-- anchored and styled the same way, and disables them outside dungeon view.
-- Disable DMV's coord frames when Magnify is loaded (Magnify provides its own).
local function DMV_ApplyCoordCompat()
	if not IsAddOnLoaded("Magnify") then return end
	DMV_CoordsDisabled = true
	if DMV_CoordsFrame		 then DMV_CoordsFrame:Hide()	   end
	if DMV_PlayerCoordsFrame then DMV_PlayerCoordsFrame:Hide() end
end

-- ModernMapMarkers
-- MMM's filter and find dropdowns are only relevant on the world map.
-- Hide them while the dungeon map is visible and restore them on close.
-- DMV's window-mode transform shifts WorldMapFrame, so MMM's dropdown anchors
-- land in the wrong place. Reposition MMMFilterDropdown (TOPRIGHT of
-- WorldMapFrame) after restoring the map; MMMFindDropdown stays anchored to
-- MMMFilterDropdown:BOTTOMRIGHT as MMM intends.
-- MMMFilterDropdown anchor offsets (TOPRIGHT of WorldMapFrame).
local DMV_MMM_FILTER_X = -9
local DMV_MMM_FILTER_Y = -56

local function DMV_RepositionMMMDropdowns()
	if not MMMFilterDropdown then return end
	MMMFilterDropdown:ClearAllPoints()
	MMMFilterDropdown:SetPoint("TOPRIGHT", WorldMapFrame, "TOPRIGHT", DMV_MMM_FILTER_X, DMV_MMM_FILTER_Y)
	if MMMFindDropdown then
		MMMFindDropdown:ClearAllPoints()
		MMMFindDropdown:SetPoint("TOPRIGHT", MMMFilterDropdown, "BOTTOMRIGHT", 0, 0)
	end
end

local function DMV_ApplyMMMCompat()
	if not IsAddOnLoaded("ModernMapMarkers") then return end

	local origShow = DMV_ShowFrames
	DMV_ShowFrames = function(...)
		origShow(...)
		if MMMFilterDropdown then MMMFilterDropdown:Hide() end
		if MMMFindDropdown   then MMMFindDropdown:Hide()   end
	end

	local origHide = DMV_HideFrames
	DMV_HideFrames = function(...)
		origHide(...)
		if MMMFilterDropdown then MMMFilterDropdown:Show() end
		if MMMFindDropdown   then MMMFindDropdown:Show()   end
		DMV_RepositionMMMDropdowns()
	end

	-- Reposition once now in case the player logs in outside a dungeon.
	DMV_RepositionMMMDropdowns()
end

-- pfUI
-- When pfUI's map module is active it skins the world map dropdowns.  DMV's
-- own dropdowns need the same treatment.  The "Switch to current zone" and
-- "Reveal Unexplored Areas" checkboxes also need repositioning because DMV
-- shifts the map frame layout.
local function DMV_ApplypfUICompat()
	if not (pfUI and pfUI.map) then return end

	-- Grey out and disable DMV's World Map Slider when pfUI is enabled
	if DMV_WindowScaleSlider then
		DMV_WindowScaleSlider:Disable()
		if DMV_WindowScaleSliderLow then DMV_WindowScaleSliderLow:SetVertexColor(0.5, 0.5, 0.5) end
		if DMV_WindowScaleSliderHigh then DMV_WindowScaleSliderHigh:SetVertexColor(0.5, 0.5, 0.5) end
	end

	local origCreateOptions = DMV_CreateInterfaceOptionsPanel
	if origCreateOptions and not DMV_OptionsPanelPfUIHooked then
		DMV_OptionsPanelPfUIHooked = true
		DMV_CreateInterfaceOptionsPanel = function()
			origCreateOptions()
			if DMV_WindowScaleSlider then
				DMV_WindowScaleSlider:Disable()
				if DMV_WindowScaleSliderLow then DMV_WindowScaleSliderLow:SetVertexColor(0.5, 0.5, 0.5) end
				if DMV_WindowScaleSliderHigh then DMV_WindowScaleSliderHigh:SetVertexColor(0.5, 0.5, 0.5) end
			end
		end
	end

	if not pfUI.api or not pfUI.api.SkinDropDown then return end

	if DMV_LevelDropDown	then pfUI.api.SkinDropDown(DMV_LevelDropDown) end
	if DMV_BossPinDropDown	then pfUI.api.SkinDropDown(DMV_BossPinDropDown) end

	-- Ensure the Dungeon Markers dropdown is closed on startup/login so its 
	-- contents are not opened by default when pfUI is active.
	if DMV_HideMarkerList then
		DMV_HideMarkerList()
	end

	if pfUI.api.CreateBackdrop then
		if DMV_MarkerList then pfUI.api.CreateBackdrop(DMV_MarkerList) end
		if DMV_AreaList then pfUI.api.CreateBackdrop(DMV_AreaList) end
	end

	local pfUI_MenuOffsetY = -12

	-- Hook or adjust toggle functions to apply the offset position
	local origToggleMarkerList = DMV_ToggleMarkerList
	if origToggleMarkerList then
		DMV_ToggleMarkerList = function()
			origToggleMarkerList()
			if DMV_MarkerList and DMV_MarkerList:IsShown() then
				local point, relTo, relPoint, x, y = DMV_MarkerList:GetPoint()
				DMV_MarkerList:SetPoint(point, relTo, relPoint, x or 0, (y or 0) + pfUI_MenuOffsetY)
			end
		end
	end

	local origToggleAreaList = DMV_ToggleAreaList
	if origToggleAreaList then
		DMV_ToggleAreaList = function()
			origToggleAreaList()
			if DMV_AreaList and DMV_AreaList:IsShown() then
				local point, relTo, relPoint, x, y = DMV_AreaList:GetPoint()
				DMV_AreaList:SetPoint(point, relTo, relPoint, x or 0, (y or 0) + pfUI_MenuOffsetY)
			end
		end
	end

	local pfUI_CoordsOffsetY = -5

	if DMV_CoordsFrame then
		local point, relTo, relPoint, x, y = DMV_CoordsFrame:GetPoint()
		if point then
			DMV_CoordsFrame:ClearAllPoints()
			DMV_CoordsFrame:SetPoint(point, relTo, relPoint, x or 10, (y or -24) + pfUI_CoordsOffsetY)
		end
	end

	if DMV_PlayerCoordsFrame then
		local point, relTo, relPoint, x, y = DMV_PlayerCoordsFrame:GetPoint()
		if point then
			DMV_PlayerCoordsFrame:ClearAllPoints()
			DMV_PlayerCoordsFrame:SetPoint(point, relTo, relPoint, x or -10, (y or -24) + pfUI_CoordsOffsetY)
		end
	end

	-- Reposition "Switch to current zone" (pfUI_map_autozoneswitch).
	local switchBtn = pfUI_map_autozoneswitch
	if switchBtn then
		switchBtn:ClearAllPoints()
		switchBtn:SetPoint("TOPLEFT", WorldMapFrame, "TOPLEFT", 339, -13)
	end

	-- Reposition "Reveal Unexplored Areas" (pfUI.mapreveal.onmap).
	local revealBtn = pfUI.mapreveal and pfUI.mapreveal.onmap
	if revealBtn then
		revealBtn:ClearAllPoints()
		revealBtn:SetPoint("TOPLEFT", WorldMapFrame, "TOPLEFT", 206, -27)
	end
end

-- Atlas priming fix
-- Atlas initialises its boss-list scroll frame to fit whatever dungeon is
-- opened first. If that dungeon has only a few bosses the scroll frame stays
-- short, clipping all subsequent dungeons. The fix is to silently open a
-- known large dungeon once at login so the scroll frame is sized to its 
-- maximum before the player ever interacts with Atlas.
-- Based on the ModernMapMarkers fix. If it is present in the load order it 
-- will run its own copy, so we skip ours to avoid priming twice.
local function DMV_ApplyAtlasPrimingFix()
	if IsAddOnLoaded("ModernMapMarkers") then return end
	if not Atlas_Refresh or not AtlasOptions then return end

	-- Respect AtlasSortBy: prime under continent sort (mode 1) so the
	-- type/zone indices are stable, then restore the original mode.
	local savedSortBy = AtlasOptions.AtlasSortBy
	local savedType   = AtlasOptions.AtlasType
	local savedZone   = AtlasOptions.AtlasZone

	if savedSortBy and savedSortBy ~= 1 then
		AtlasOptions.AtlasSortBy = 1
		if Atlas_PopulateDropdowns then Atlas_PopulateDropdowns() end
	end

	AtlasOptions.AtlasType = 1
	AtlasOptions.AtlasZone = 7
	Atlas_Refresh()

	if savedSortBy and savedSortBy ~= 1 then
		AtlasOptions.AtlasSortBy = savedSortBy
		if Atlas_PopulateDropdowns then Atlas_PopulateDropdowns() end
	end
	AtlasOptions.AtlasType = savedType
	AtlasOptions.AtlasZone = savedZone
end

local function DMV_ScheduleAtlasPriming()
	if not AtlasFrame then return end
	local primerFrame = CreateFrame("Frame")
	primerFrame.timer = 0
	primerFrame:SetScript("OnUpdate", function()
		this.timer = this.timer + arg1
		if this.timer >= 0.5 then
			this:SetScript("OnUpdate", nil)
			DMV_ApplyAtlasPrimingFix()
		end
	end)
end

-- Atlas AutoSelect fix
-- When "Auto-Select Instance Map" is enabled in Atlas options, Atlas_AutoSelect
-- runs on AtlasFrame:Show() and overwrites the AtlasType/AtlasZone that
-- DMV_OpenAtlasBoss just set, causing Atlas to display the wrong map (e.g.
-- Ruins of Ahn'Qiraj instead of Temple of Ahn'Qiraj).
--
-- The fix wraps DMV_OpenAtlasBoss: temporarily disable AtlasAutoSelect before
-- AtlasFrame is shown so the correct map is preserved, then restore the
-- original setting when AtlasFrame is closed.
local function DMV_ApplyAtlasAutoSelectFix()
	if not DMV_OpenAtlasBoss then return end
	local orig = DMV_OpenAtlasBoss
	DMV_OpenAtlasBoss = function(atlasMapKey)
		if not AtlasOptions then return orig(atlasMapKey) end
		local savedAutoSelect = AtlasOptions.AtlasAutoSelect
		if savedAutoSelect then
			AtlasOptions.AtlasAutoSelect = false
		end
		local result = orig(atlasMapKey)
		if savedAutoSelect and AtlasFrame then
			AtlasFrame:HookScript("OnHide", function()
				AtlasOptions.AtlasAutoSelect = true
			end)
		end
		return result
	end
end

-- pfQuest
-- pfQuest pins are parented to WorldMapButton and keyed by zone. When DMV
-- swaps in a dungeon/raid map the zone resolves to nil but pfQuest's
-- WORLD_MAP_UPDATE handler only hides pins for continent view, not for
-- instance maps it can't resolve. The pins bleed into the dungeon overlay.
-- Fix: hide all pfMap worldmap pins on DMV open, restore on DMV close.
local function DMV_ApplypfQuestCompat()
	if not pfMap or not pfMap.pins then return end

	local origShow = DMV_ShowFrames
	DMV_ShowFrames = function(...)
		for i = 1, table.getn(pfMap.pins) do
			if pfMap.pins[i] then pfMap.pins[i]:Hide() end
		end
		return origShow(...)
	end

	local origHide = DMV_HideFrames
	DMV_HideFrames = function(...)
		local result = origHide(...)
		-- Trigger pfQuest to re-evaluate and redraw pins for the current zone.
		if pfMap.UpdateNodes then pfMap:UpdateNodes() end
		return result
	end
end

-- Atlas strata
-- AtlasFrame is raised to FULLSCREEN_DIALOG (toplevel) in DMV_OpenAtlasBoss,
-- placing it above pins and Magnify's WorldMapFrameAreaFrame while leaving
-- TOOLTIP free for item tooltips.  No further compat needed here.
--local function DMV_ApplyAtlasStrataFix()
--end

local compatFrame = CreateFrame("Frame")
compatFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
compatFrame:SetScript("OnEvent", function()
	DMV_WINDOW_SCALE = DMV_GetWindowScale()
	DMV_ApplyMagnifyCompat()
	DMV_ApplyAtlasAutoSelectFix()
	DMV_ScheduleAtlasPriming()
	DMV_ApplyMMMCompat()
	DMV_ApplypfUICompat()
	DMV_ApplyCoordCompat()
	DMV_ApplypfQuestCompat()
end)
