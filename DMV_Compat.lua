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
	-- Centering is deferred one frame so it runs after the stock OnShow has
	-- finished repositioning.
	if not DMV_WindowFallbackInstalled then
		local centerDelay = CreateFrame("Frame")
		centerDelay:Hide()
		centerDelay:SetScript("OnUpdate", function()
			centerDelay:Hide()
			WorldMapFrame:ClearAllPoints()
			WorldMapFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
		end)

		DMV_HookScriptPost(WorldMapFrame, "OnShow", function()
			WorldMapFrame:EnableKeyboard(false)
			WorldMapFrame:SetScale(DMV_WINDOW_SCALE)
			centerDelay:Show()
		end)

		WorldMapFrame:SetMovable(true)
		WorldMapFrame:EnableMouse(true)

		WorldMapFrame:HookScript("OnMouseDown", function()
			WorldMapFrame:StartMoving()
		end)
		WorldMapFrame:HookScript("OnMouseUp", function()
			WorldMapFrame:StopMovingOrSizing()
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
	-- GetPlayerFacing() and texture:SetRotation() both measure angles
	-- counter-clockwise, so facing is passed directly.
	-- Size follows Magnify's arrow_scale, inverse-scaled with map zoom.

	local magnifyTexture = "Interface\\AddOns\\Magnify\\assets\\WorldMapArrow"
	local arrowTextureSet = false

	local origUpdateArrow = DMV_UpdatePlayerArrow
	local arrowSize = nil
	DMV_UpdatePlayerArrow = function()
		origUpdateArrow()

		local arrow = DMV_PlayerArrow
		if not arrow or not arrow:IsShown() then return end

		if not arrowTextureSet and arrow.tex then
			arrow.tex:SetTexture(magnifyTexture)
			arrowTextureSet = true
			if arrow.tex.SetRotation then
				arrow.facing = (GetPlayerFacing and GetPlayerFacing()) or 0
				arrow.tex:SetRotation(arrow.facing)
			end
		end

		local mapScale = (WorldMapDetailFrame and WorldMapDetailFrame:GetScale()) or 1
		local size = 24 * ((Magnify_Settings and Magnify_Settings["arrow_scale"]) or 1) / mapScale
		if size ~= arrowSize then
			arrow:SetSize(size, size)
			arrowSize = size
		end
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
			delta = delta or arg1
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

	-- The arrow's image is drawn by DMV_OverlayDraw, not by the arrow frame,
	-- so the flash fades the image (arrow.tex) directly. The on/off state is
	-- kept here rather than read back from the texture.
	local function SetArrowImageAlpha(a)
		local tex = DMV_PlayerArrow and DMV_PlayerArrow.tex
		if tex then tex:SetAlpha(a) end
	end

	local DMV_FlashTicker = CreateFrame("Frame")
	DMV_FlashTicker:Hide()
	DMV_FlashTicker:SetScript("OnUpdate", function(self, elapsed)
		-- New ClassicAPI runner passes (self, elapsed) positionally.
		-- Fall back to legacy globals for older runner compatibility.
		self = self or DMV_FlashTicker
		elapsed = tonumber(elapsed) or tonumber(arg1) or 0
		self.Elapsed = self.Elapsed + elapsed
		if self.Elapsed > MAGNIFY_PLAYER_FLASH_INTERVAL then
			self.Elapsed = 0
			if self.Flashes < MAGNIFY_PLAYER_FLASH_COUNT then
				self.Flashes = self.Flashes + 1
				self.dimmed = not self.dimmed
				SetArrowImageAlpha(self.dimmed and 0 or 1)
			else
				self.Flashes = 0
				self.dimmed = false
				SetArrowImageAlpha(1)
				self:Hide()
			end
		end
	end)

	local function DMV_FlashPlayerArrow()
		if not DMV_PlayerArrow then return end
		if Magnify_Settings and Magnify_Settings["arrow_flash"] then
			DMV_FlashTicker.Elapsed = 0
			DMV_FlashTicker.Flashes = 0
			DMV_FlashTicker.dimmed = false
			SetArrowImageAlpha(1)
			DMV_FlashTicker:Show()
		else
			DMV_FlashTicker:Hide()
			DMV_FlashTicker.dimmed = false
			SetArrowImageAlpha(1)
		end
	end

	local origShow = DMV_ShowFrames
	DMV_ShowFrames = function(...)
		local wasShown = DMV_ClickFrame and DMV_ClickFrame:IsShown()
		origShow(...)
		DMV_InstallWheelHandler()
		if not wasShown then DMV_FlashPlayerArrow() end
		if WorldMapZoomOutButton and not DMV_IsOnRealWorldMap() then
			WorldMapZoomOutButton:Enable()
		end
	end

	-- 3. Strata: raise DMV controls above Magnify's scroll frame
	-- Called once now (in case we are already in a dungeon) and again on
	-- every WORLD_MAP_UPDATE while the map is open.
	local function RaiseControls()
		local targets = {
			DMV_ClickFrame,
			DMV_LevelDropDown,
			DMV_LevelUpButton,
			DMV_LevelDownButton,
			DMV_BossPinDropDown,
			getglobal("DMV_LevelDropDownButton"),
			getglobal("DMV_BossPinDropDownButton"),
		}
		for _, w in ipairs(targets) do
			if w and w:GetFrameStrata() ~= "FULLSCREEN_DIALOG" then w:SetFrameStrata("FULLSCREEN_DIALOG") end
		end
		if DMV_ApplyOverlayLevels then DMV_ApplyOverlayLevels() end
	end
	RaiseControls()
	
	-- Ensure controls and mouse responsiveness persist on continent/map updates
	local updateEventFrame = CreateFrame("Frame")
	updateEventFrame:RegisterEvent("WORLD_MAP_UPDATE")
	updateEventFrame:SetScript("OnEvent", function()
		if WorldMapFrame and WorldMapFrame:IsShown() then
			RaiseControls()
			if DMV_ClickFrame then
				DMV_ClickFrame:EnableMouse(true)
			end
		end
	end)

	-- 4. Area frame: suppress hover text while dungeon map is visible
	if WorldMapFrameAreaFrame and not DMV_AreaFrameCompatInstalled then
		DMV_AreaFrameCompatInstalled = true
		local savedOnUpdate = WorldMapFrameAreaFrame:GetScript("OnUpdate")

		local areaHiddenByDMV = false

		local origShowArea = DMV_ShowFrames
		DMV_ShowFrames = function(...)
			origShowArea(...)
			if WorldMapFrameAreaFrame then
				WorldMapFrameAreaFrame:SetScript("OnUpdate", nil)
				if WorldMapFrameAreaFrame:IsShown() then areaHiddenByDMV = true end
				WorldMapFrameAreaFrame:Hide()
			end
		end

		local origHideArea = DMV_HideFrames
		DMV_HideFrames = function(...)
			origHideArea(...)
			if WorldMapFrameAreaFrame then
				WorldMapFrameAreaFrame:SetScript("OnUpdate", savedOnUpdate)
				if areaHiddenByDMV then
					areaHiddenByDMV = false
					WorldMapFrameAreaFrame:Show()
				end
			end
		end
	end
	-- 5. Party/raid blips: inverse-scale with map zoom
	-- Blips are children of DMV_Container which lives inside WorldMapDetailFrame,
	-- so they inherit its scale. They are resized (all of them, shown or not)
	-- only when the zoom changes or new blips have been created.
	local origUpdateBlips = DMV_UpdatePartyBlips
	local blipScale, blipCount = nil, 0
	DMV_UpdatePartyBlips = function(...)
		origUpdateBlips(...)
		local mapScale = (WorldMapDetailFrame and WorldMapDetailFrame:GetScale()) or 1
		local n = table.getn(DMV_PartyBlips)
		if mapScale ~= blipScale or n ~= blipCount then
			local scaledSize = DMV_BLIP_SIZE / mapScale
			for i = 1, n do DMV_PartyBlips[i]:SetSize(scaledSize, scaledSize) end
			blipScale, blipCount = mapScale, n
		end
	end

	-- 6. Mouse clipping while zoomed
	-- Zooming scales WorldMapDetailFrame past the edges of Magnify's scroll
	-- frame. The overflow is not drawn but still receives the mouse, so the
	-- full-size DMV_ClickFrame (FULLSCREEN_DIALOG) would cover the dropdowns
	-- and buttons around the map. DMV_ClickFrame is therefore kept to the
	-- visible part of the overlay, and markers, blips and the player arrow
	-- take mouse input only while they are inside the visible area.
	local sf = WorldMapFrameScrollFrame
	if not sf then return end

	local function ScreenRect(f)
		local l, b, r, t = f:GetLeft(), f:GetBottom(), f:GetRight(), f:GetTop()
		if not (l and b and r and t) then return nil end
		local s = f:GetEffectiveScale()
		return l * s, b * s, r * s, t * s
	end

	local function ClipClickFrame(vl, vb, vr, vt)
		local c = DMV_Container
		local cl, cb, cr, ct = ScreenRect(c)
		if not cl then return false end
		local s = c:GetEffectiveScale()
		local l, r = math.max(cl, vl), math.min(cr, vr)
		local b, t = math.max(cb, vb), math.min(ct, vt)
		DMV_ClickFrame:ClearAllPoints()
		DMV_ClickFrame:SetPoint("TOPLEFT", c, "TOPLEFT", (l - cl) / s, (t - ct) / s)
		DMV_ClickFrame:SetWidth(math.max(0, r - l) / s)
		DMV_ClickFrame:SetHeight(math.max(0, t - b) / s)
		return true
	end

	-- vl == nil (not zoomed in): everything is in view, so re-enable the mouse
	-- on hidden frames too, in case they were disabled while zoomed in.
	local function ClipMouse(f, vl, vb, vr, vt)
		if not f then return end
		if not vl then f:EnableMouse(true) return end
		if not f:IsShown() then return end
		local l, b, r, t = ScreenRect(f)
		if not l then return end
		f:EnableMouse(l < vr and r > vl and b < vt and t > vb)
	end

	local function ClipMarkers(vl, vb, vr, vt)
		for _, pin in ipairs(DMV_BossPinList) do ClipMouse(pin, vl, vb, vr, vt) end
		for _, blip in pairs(DMV_PartyBlips) do ClipMouse(blip, vl, vb, vr, vt) end
		ClipMouse(DMV_PlayerArrow, vl, vb, vr, vt)
	end

	-- The click frame is re-clipped only when zoom or scroll changes. Markers
	-- move on their own, so they are checked every 0.1 s while zoomed in, and
	-- once more when not zoomed in so all of them take the mouse again.
	local clipFrame = CreateFrame("Frame", nil, WorldMapFrame)
	clipFrame:Hide()
	local lastH, lastV, lastZoom, lastScale
	local markerElapsed, wasZoomed = 0, false
	clipFrame:SetScript("OnUpdate", function(self, elapsed)
		elapsed = tonumber(elapsed) or tonumber(arg1) or 0
		if not DMV_ClickFrame or not DMV_ClickFrame:IsShown() or not DMV_Container then return end

		local h, v = sf:GetHorizontalScroll(), sf:GetVerticalScroll()
		local zoom, scale = WorldMapDetailFrame:GetScale(), DMV_Container:GetScale()
		local viewChanged = h ~= lastH or v ~= lastV or zoom ~= lastZoom or scale ~= lastScale
		local zoomed = zoom > (MAGNIFY_MIN_ZOOM or 1.0)
		markerElapsed = markerElapsed + elapsed
		local checkMarkers = (zoomed and markerElapsed >= 0.1) or (wasZoomed and not zoomed)
		if not viewChanged and not checkMarkers then return end

		local vl, vb, vr, vt = ScreenRect(sf)
		if not vl then return end
		if viewChanged and ClipClickFrame(vl, vb, vr, vt) then
			lastH, lastV, lastZoom, lastScale = h, v, zoom, scale
		end
		if checkMarkers then
			markerElapsed = 0
			if zoomed then ClipMarkers(vl, vb, vr, vt) else ClipMarkers() end
			wasZoomed = zoomed
		end
	end)

	local origShowClip = DMV_ShowFrames
	DMV_ShowFrames = function(...)
		origShowClip(...)
		lastH = nil			-- force a re-clip on the next frame
		markerElapsed = 0.1
		wasZoomed = true	-- one marker pass even when not zoomed
		clipFrame:Show()
	end

	local origHideClip = DMV_HideFrames
	DMV_HideFrames = function(...)
		local result = origHideClip(...)
		clipFrame:Hide()
		return result
	end
end

-- No Magnify (ShaguTweaks, pfUI or the stock map)
-- Runs on the first PLAYER_ENTERING_WORLD, when every addon is loaded, so
-- ShaguTweaks's window mode (and pfUI's map module) can be detected.
local function DMV_ApplyNoMagnifyCompat()
	if IsAddOnLoaded("Magnify") then return end
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
-- DMV shows its own cursor and player coordinate frames (styled like
-- Magnify's) while the dungeon map is displayed, following DMV's "Show
-- Coordinates" option.
-- Magnify's coordinate frames cannot be shared: inside instances
-- GetPlayerMapPosition returns 0,0, and Magnify's updaters (one per layout
-- pass) write "Player: N/A" every frame, overwriting anything DMV writes.
-- While the dungeon map is shown, Magnify's two frames are therefore hidden
-- and DMV's are placed exactly where Magnify's are (anchored to them, so
-- they follow Magnify's own repositioning). Magnify's frames are shown again
-- when the dungeon map closes, only if DMV hid them.
local function DMV_ApplyCoordCompat()
	if not IsAddOnLoaded("Magnify") then return end

	local hiddenByDMV = {}

	local function Restore()
		for f in pairs(hiddenByDMV) do
			hiddenByDMV[f] = nil
			f:Show()
		end
	end

	-- Either frame may be missing (older Magnify builds).
	local function HideMagnify(f)
		if f and f:IsShown() then
			f:Hide()
			hiddenByDMV[f] = true
		end
	end

	-- Anchor a DMV frame onto Magnify's matching frame. A Magnify frame
	-- without a position (unknown Magnify build) falls back to the corner of
	-- Magnify's scroll frame that Magnify uses.
	local function Dock(dmvFrame, magFrame, corner, x)
		if not dmvFrame then return end
		if magFrame and magFrame:GetPoint() then
			dmvFrame:ClearAllPoints()
			dmvFrame:SetAllPoints(magFrame)
		elseif WorldMapFrameScrollFrame then
			dmvFrame:ClearAllPoints()
			dmvFrame:SetPoint(corner, WorldMapFrameScrollFrame, corner, x, -24)
		end
	end

	local function Sync()
		-- DMV_ClickFrame is shown exactly while the dungeon map is displayed.
		if not (DMV_ClickFrame and DMV_ClickFrame:IsShown()) then Restore() return end
		local magCoords, magPlayer = getglobal("MagnifyCoordsFrame"), getglobal("MagnifyPlayerFrame")
		HideMagnify(magCoords)
		HideMagnify(magPlayer)
		Dock(DMV_CoordsFrame, magCoords, "BOTTOMLEFT", 10)
		Dock(DMV_PlayerCoordsFrame, magPlayer, "BOTTOMRIGHT", -10)
	end

	-- Options panel toggles go through DMV_UpdateCoordsVisibility; showing
	-- the map goes through DMV_ShowFrames (wrapped last, so the docking runs
	-- after every other compat layer, pfUI's coordinate offset included).
	local origUpdate = DMV_UpdateCoordsVisibility
	DMV_UpdateCoordsVisibility = function(...)
		origUpdate(...)
		Sync()
	end

	local origShow = DMV_ShowFrames
	DMV_ShowFrames = function(...)
		origShow(...)
		Sync()
	end

	local origHide = DMV_HideFrames
	DMV_HideFrames = function(...)
		local result = origHide(...)
		Restore()
		return result
	end
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

	local filterHidden, findHidden = false, false

	local origShow = DMV_ShowFrames
	DMV_ShowFrames = function(...)
		origShow(...)
		if MMMFilterDropdown and MMMFilterDropdown:IsShown() then
			filterHidden = true
			MMMFilterDropdown:Hide()
		end
		if MMMFindDropdown and MMMFindDropdown:IsShown() then
			findHidden = true
			MMMFindDropdown:Hide()
		end
	end

	local origHide = DMV_HideFrames
	DMV_HideFrames = function(...)
		origHide(...)
		if filterHidden and MMMFilterDropdown then MMMFilterDropdown:Show() end
		if findHidden and MMMFindDropdown then MMMFindDropdown:Show() end
		filterHidden, findHidden = false, false
		DMV_RepositionMMMDropdowns()
	end

	-- Reposition once now in case the player logs in outside a dungeon.
	DMV_RepositionMMMDropdowns()
end

-- pfUI
-- When pfUI's map module is active it skins the world map dropdowns.  DMV's
-- own dropdowns need the same treatment. The "Switch to current zone" and
-- "Reveal Unexplored Areas" checkboxes also need repositioning.
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

	local pfUI_MenuOffsetY = -12

	local function SkinCustomList(list)
		if not list or list._pfUISkinned then return end
		list._pfUISkinned = true
		if pfUI.api.CreateBackdrop then
			pfUI.api.CreateBackdrop(list)
		end
	end

	local pfUISkinApplied = false

	local function ApplypfUISkinOnce()
		if pfUISkinApplied then return end
		pfUISkinApplied = true

		if DMV_LevelDropDown   then pfUI.api.SkinDropDown(DMV_LevelDropDown,   nil, nil, nil, true) end
		if DMV_BossPinDropDown then pfUI.api.SkinDropDown(DMV_BossPinDropDown, nil, nil, nil, true) end

		SkinCustomList(DMV_MarkerList)
		SkinCustomList(DMV_AreaList)

		if DMV_HideMarkerList then DMV_HideMarkerList() end

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
	end

	local origShow = DMV_ShowFrames
	DMV_ShowFrames = function(...)
		origShow(...)
		ApplypfUISkinOnce()
		SkinCustomList(DMV_AreaList)
	end

	local origToggleMarkerList = DMV_ToggleMarkerList
	if origToggleMarkerList then
		DMV_ToggleMarkerList = function()
			origToggleMarkerList()
			SkinCustomList(DMV_MarkerList)
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
			SkinCustomList(DMV_AreaList)
			if DMV_AreaList and DMV_AreaList:IsShown() then
				local point, relTo, relPoint, x, y = DMV_AreaList:GetPoint()
				DMV_AreaList:SetPoint(point, relTo, relPoint, x or 0, (y or 0) + pfUI_MenuOffsetY)
			end
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
	primerFrame:SetScript("OnUpdate", function(self, elapsed)
		-- New ClassicAPI runner passes (self, elapsed) positionally.
		-- Fall back to legacy globals for older runner compatibility.
		self = self or primerFrame
		elapsed = tonumber(elapsed) or tonumber(arg1) or 0
		self.timer = self.timer + elapsed
		if self.timer >= 0.5 then
			self:SetScript("OnUpdate", nil)
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
	local restorePending = false
	local hooked = false

	local function Restore()
		if restorePending then
			restorePending = false
			if AtlasOptions then AtlasOptions.AtlasAutoSelect = true end
		end
	end

	DMV_OpenAtlasBoss = function(atlasMapKey)
		if not AtlasOptions then return orig(atlasMapKey) end
		if AtlasOptions.AtlasAutoSelect then
			AtlasOptions.AtlasAutoSelect = false
			restorePending = true
		end
		local result = orig(atlasMapKey)
		if restorePending then
			if AtlasFrame and not hooked then
				hooked = true
				AtlasFrame:HookScript("OnHide", Restore)
			end
			-- Atlas was not opened (no matching map): restore right away.
			if not (AtlasFrame and AtlasFrame:IsShown()) then Restore() end
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
-- pfQuest's quest display dropdown ("All Quests", pfQuestMapDropdown) is a
-- child of WorldMapButton, so DMV's overlay normally covers it, but Magnify
-- moves it onto WorldMapFrame at FULLSCREEN_DIALOG, above the dungeon map.
-- It only applies to the world map, so it is hidden the same way.
local function DMV_ApplypfQuestCompat()
	if not pfMap or not pfMap.pins then return end

	-- Only what DMV hid is restored (DMV_HideFrames also runs on every
	-- loading screen and map change), so a route layer the player turned off
	-- in pfQuest stays off, and a dropdown pfQuest did not create or show
	-- stays hidden.
	local pinsHidden, routeHidden, dropdownHidden = false, false, false

	local origShow = DMV_ShowFrames
	DMV_ShowFrames = function(...)
		for i = 1, table.getn(pfMap.pins) do
			if pfMap.pins[i] then pfMap.pins[i]:Hide() end
		end
		pinsHidden = true
		local layer = pfQuest and pfQuest.route and pfQuest.route.drawlayer
		if layer and layer:IsShown() then
			layer:Hide()
			routeHidden = true
		end
		local dropdown = getglobal("pfQuestMapDropdown")
		if dropdown and dropdown:IsShown() then
			dropdown:Hide()
			dropdownHidden = true
		end
		return origShow(...)
	end

	local origHide = DMV_HideFrames
	DMV_HideFrames = function(...)
		local result = origHide(...)
		-- Re-show the route drawlayer so pfQuest's own WORLD_MAP_UPDATE handler
		-- can take over. Without this, pfQuest never sees it as needing a restore.
		if routeHidden then
			routeHidden = false
			local layer = pfQuest and pfQuest.route and pfQuest.route.drawlayer
			if layer then layer:Show() end
		end
		-- pfQuest's OnShow re-reads its tracking setting into the dropdown.
		if dropdownHidden then
			dropdownHidden = false
			local dropdown = getglobal("pfQuestMapDropdown")
			if dropdown then dropdown:Show() end
		end
		if pinsHidden then
			pinsHidden = false
			if pfMap.UpdateNodes then pfMap:UpdateNodes() end
		end
		return result
	end
end

-- Questie
-- Call Questie:Toggle() to disable Questie while the dungeon overlay is shown
-- and re-enable it when the overlay is hidden. Toggle() clears all notes and
-- sets IsQuestieActive = false, which stops DRAW_NOTES from placing any icons.
-- Questie is only switched back on if DMV switched it off, so a player who
-- disabled Questie keeps it disabled (DMV_HideFrames also runs on every
-- loading screen).
local function DMV_ApplyQuestieCompat()
	if not IsAddOnLoaded("!Questie") then return end

	local disabledByDMV = false

	local origShow = DMV_ShowFrames
	DMV_ShowFrames = function(...)
		if IsQuestieActive then
			Questie:Toggle()
			disabledByDMV = true
		end
		return origShow(...)
	end

	local origHide = DMV_HideFrames
	DMV_HideFrames = function(...)
		local result = origHide(...)
		if disabledByDMV then
			disabledByDMV = false
			if not IsQuestieActive then Questie:Toggle() end
		end
		return result
	end
end

-- Apply every compat layer once, on the first PLAYER_ENTERING_WORLD (all
-- addons and saved variables are loaded by then). PLAYER_ENTERING_WORLD fires
-- on every loading screen, and these functions wrap DMV functions and create
-- frames, so running them again would stack duplicate wrappers.
local compatFrame = CreateFrame("Frame")
compatFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
compatFrame:SetScript("OnEvent", function()
	compatFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
	DMV_WINDOW_SCALE = DMV_GetWindowScale()
	DMV_ApplyNoMagnifyCompat()
	DMV_ApplyMagnifyCompat()
	DMV_ApplyAtlasAutoSelectFix()
	DMV_ScheduleAtlasPriming()
	DMV_ApplyMMMCompat()
	DMV_ApplypfUICompat()
	DMV_ApplyCoordCompat()
	DMV_ApplypfQuestCompat()
	DMV_ApplyQuestieCompat()
end)
