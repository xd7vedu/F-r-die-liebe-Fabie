-- Elevate thread identity so we can require game modules from a LocalScript
pcall(function() setthreadidentity(2) end)

_G.MockTradeBuild = "2026-07-04-blockfix"

if _G.MockTradeRunning then
    _G.MockTradeRunning = false
    task.wait(0.1)
end
_G.MockTradeRunning = true
_G._guiLocked = false

-- Destroy old GUI (Players not yet defined here — done below after service init)

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

-- Destroy old GUI instance if re-executing
local _oldGui = Players.LocalPlayer:WaitForChild("PlayerGui"):FindFirstChild("MockTradeControl")
if _oldGui then _oldGui:Destroy() end

local CONFIG = {
    PARTNER_NAME               = "blueprint",
    PARTNER_USER_ID            = 0,
    AUTO_ACCEPT_DELAY          = 1.5,
    AUTO_CONFIRM_DELAY         = 2.5,
    SPECTATOR_COUNT            = 0,
    NEGOTIATION_LOCK           = 5,
    CONFIRMATION_LOCK_PER_ITEM = 3,
    REACTIONS_PER_SECOND       = 2,
    REMOVE_SENT_PETS           = true,
    RECEIVE_PETS               = true,
    PARTNER_TAG                = "",  -- force a tag for mock partner: "founder" / "developer" / "staff" / "influencer" / "" = use real rank
    SELF_BADGE_TAG             = "",  -- founder / developer / staff / influencer / ""
}

-- ═══ Cloud Saves (Firebase Realtime Database) ═════════════════════════════════
-- Paste your RTDB URL here after setup (e.g. https://yourname-default-rtdb.firebaseio.com).
-- SAVES_FIREBASE_AUTH is optional — only needed if your rules require ?auth=<secret>.
_G.SAVES_FIREBASE_URL  = _G.SAVES_FIREBASE_URL  or "https://blueprint-saves-default-rtdb.firebaseio.com"
_G.SAVES_FIREBASE_AUTH = _G.SAVES_FIREBASE_AUTH or ""
-- Sections register their state here: _G._saveHooks[key] = { label=..., save=fn()->table, load=fn(table) }
_G._saveHooks = _G._saveHooks or {}
-- Fixed display order for the category checkboxes in the Saves GUI.
_G._saveOrder = { "keybinds", "toggles", "fakeprofile", "inventory" }

-- Toggles & settings: the whole CONFIG table plus a few _G flags. Restores the underlying
-- state; some toggle button visuals only re-sync after reopening the GUI (noted to the user).
_G._saveHooks.toggles = {
    label = "Toggles & settings",
    save = function()
        local t = {}
        for k, v in pairs(CONFIG) do t[k] = v end
        t.__manualBlock = _G._manualBlockMode
        t.__antiBotter  = _G._antiBotterMode
        t.__blockKey    = _G._blockKey
        t.__guiScale    = _G._guiScale
        return t
    end,
    load = function(t)
        if type(t) ~= "table" then return end
        for k, v in pairs(t) do
            if type(k) == "string" and k:sub(1, 2) ~= "__" then CONFIG[k] = v end
        end
        if t.__manualBlock ~= nil then _G._manualBlockMode = t.__manualBlock end
        if t.__antiBotter  ~= nil then _G._antiBotterMode  = t.__antiBotter end
        if t.__blockKey then _G._blockKey = t.__blockKey end
    end,
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")

-- Safe pcall wrapper that logs errors to console
local function safeCall(fn)
    local ok, err = pcall(fn)
    if not ok then warn("[MockTrade] " .. tostring(err)) end
end

-- UI factory: collapses Instance.new + property assignments into one call.
-- Parent is always applied last (Roblox best practice — avoids reparent churn).
local function mk(class, props)
    local o = Instance.new(class)
    if props then
        local parent = props.Parent
        props.Parent = nil
        for k, v in pairs(props) do o[k] = v end
        if parent then o.Parent = parent end
    end
    return o
end

local Fsys        = require(ReplicatedStorage:WaitForChild("Fsys"))
local load              = Fsys.load
local UIManager         = load("UIManager")
local ClientData        = load("ClientData")
local TableUtil   = load("TableUtil")
local InventoryDB = load("InventoryDB")
local SharedConstants = load("SharedConstants")
local KindDB         = load("KindDB")
local RouterClient_  = load("RouterClient")
local DownloadClient = load("DownloadClient")
local PetRigs        = load("new:PetRigs")
local IDB            = load("InventoryDB")
local AnimMgr        = load("AnimationManager")
local AilmentsClient = load("new:AilmentsClient")
local AilmentsDB     = load("new:AilmentsDB")

if UIManager.wait_for_initialization then
    UIManager:wait_for_initialization()
else
    task.wait(2)
end

local TradeApp        = UIManager.apps.TradeApp
local BackpackApp     = UIManager.apps.BackpackApp
local TradeHistoryApp = UIManager.apps.TradeHistoryApp

-- ════════════════════════════════════════════════════════════════════════
--  Auto Offer Pets engine. UI is built onto Misc Page 2 via _G._aoBuildControls.
--  Wrapped in an IIFE so its ~20 helpers use their OWN register budget (0 main-chunk cost).
--  realAdd captured here (before our trade hooks) so it's the pristine game function.
-- ════════════════════════════════════════════════════════════════════════
do
local function _aoEngine()
local AO = { enabled=false, running=false, speed=1, min=2, max=2, confirm=false }
local AO_MAX_PETS, AO_MIN_RARITY = 8, 3
local VIM = game:GetService("VirtualInputManager")
local LockTracker = (function() local ok,m = pcall(load,"BackpackLockTracker") return ok and m or nil end)()
local realAdd = TradeApp._add_item_to_my_offer

local function tradeActive()
    local ok, st = pcall(function() return TradeApp:_get_local_trade_state() end)
    if ok and st and st.current_stage then return true end
    local s2 = TradeApp.local_trade_state
    return s2 ~= nil and s2.current_stage ~= nil
end
local function getMyOffer()
    local ok, offer = pcall(function() return (TradeApp:_get_my_offer()) end)
    if ok and offer then return offer end
    return nil
end
local function getMyOfferCount()
    local o = getMyOffer()
    return (o and o.items) and #o.items or 0
end
local function lockGoing()
    local lc = TradeApp.lock_countdown
    if lc and lc.is_going then
        local ok, going = pcall(function() return lc:is_going() end)
        if ok then return going end
    end
    return false
end
-- Real game lock duration (seconds) for the current stage — the exact time you must
-- wait before the offer unlocks. Negotiation = negotiation_lock_time; confirmation =
-- clamp(confirmation_lock_time_per_item * total_item_count, 5, 15). See TradeApp:_get_lock_time.
local function lockTime()
    local ok, t = pcall(function() return TradeApp:_get_lock_time() end)
    if ok and type(t) == "number" and t > 0 then return t end
    return 15  -- safe upper bound (game clamps the confirmation lock to <= 15s)
end

local function fireConnections(sig)
    if not (sig and getconnections) then return end
    local ok, conns = pcall(getconnections, sig)
    if not (ok and conns) then return end
    for _, c in ipairs(conns) do
        pcall(function() if c.Enable then c:Enable() end end)
        pcall(function() c:Fire() end)
        pcall(function() if c.Function then c.Function() end end)
    end
end
local function realClickAt(x, y)
    pcall(function() VIM:SendMouseMoveEvent(x, y, game) end)
    task.wait(0.03)
    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, true,  game, 1) end)
    task.wait(0.04)
    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, false, game, 1) end)
end
local function fireEvent(b, name)
    local ok, signal = pcall(function() return b[name] end)
    if ok and signal then
        pcall(function() fireConnections(signal) end)
        pcall(function() if firesignal then firesignal(signal) end end)
    end
end
local function pressButton(b)
    if not b then return end
    fireEvent(b, "MouseButton1Down")
    fireEvent(b, "MouseButton1Up")
    fireEvent(b, "MouseButton1Click")
    fireEvent(b, "Activated")
    pcall(function()
        local c = b.AbsolutePosition + b.AbsoluteSize * 0.5
        realClickAt(c.X, c.Y)
    end)
end
local function buttonLabel(b)
    local label = ((b:IsA("TextButton") or b:IsA("TextLabel")) and b.Text) or ""
    if label == "" then
        for _, tl in ipairs(b:GetDescendants()) do
            if tl:IsA("TextLabel") and tl.Visible and tl.Text ~= "" then label = tl.Text; break end
        end
    end
    return label or ""
end
local SCAM_BAD = { "cancel", "decline", "go back", "no thanks", "report" }
local function looksNegative(s)
    s = tostring(s):lower()
    for _, b in ipairs(SCAM_BAD) do if s:find(b, 1, true) then return true end end
    return false
end
local function isOnScreen(o)
    if not o.Visible then return false end
    if o:IsA("GuiObject") and (o.AbsoluteSize.X < 4 or o.AbsoluteSize.Y < 4) then return false end
    local p = o.Parent
    while p and p:IsA("GuiObject") do
        if not p.Visible then return false end
        p = p.Parent
    end
    return true
end
local function tryDismiss(g)
    if not (g:IsA("ScreenGui") and g.Enabled) then return false end
    if g.Name == "MockTradeControl" or g.Name == "_AOFakeCursor" then return false end
    local shown = false
    for _, d in ipairs(g:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton"))
           and (d.Text or ""):lower():find("scam", 1, true) and isOnScreen(d) then
            shown = true; break
        end
    end
    if not shown then return false end
    for _, b in ipairs(g:GetDescendants()) do
        if (b:IsA("TextButton") or b:IsA("ImageButton"))
           and isOnScreen(b) and not looksNegative(buttonLabel(b)) then
            pressButton(b)
            return true
        end
    end
    return false
end
local function dismissScamDialog()
    local roots = {}
    local plg = Players.LocalPlayer:FindFirstChild("PlayerGui")
    if plg then table.insert(roots, plg) end
    pcall(function() if gethui then table.insert(roots, gethui()) end end)
    pcall(function() table.insert(roots, game:GetService("CoreGui")) end)
    for _, root in ipairs(roots) do
        local done = false
        pcall(function()
            for _, g in ipairs(root:GetChildren()) do
                if tryDismiss(g) then done = true; break end
            end
        end)
        if done then return end
    end
end

local function doOffer()
    if AO.running then return end
    AO.running = true
    task.spawn(function()
        local function w(t) task.wait(t / math.max(0.1, AO.speed)) end
        if not tradeActive() then AO.running = false; return end

        local inventory; pcall(function() inventory = ClientData.get("inventory") end)
        local pets = inventory and inventory.pets
        if not pets then AO.running = false; return end

        local offered = {}
        local o = getMyOffer()
        if o and o.items then for _, it in ipairs(o.items) do offered[it.unique] = true end end

        local function rarityOk(p)
            local db = InventoryDB.pets[p.kind]
            local r = (db and db.rarity)
            if r == nil and p.properties then r = p.properties.rarity end
            if r == nil then return true end
            if type(r) == "number" then return r >= AO_MIN_RARITY end
            r = tostring(r):lower()
            return not (r == "common" or r == "uncommon")
        end
        local function tradeable(p)
            local db = InventoryDB.pets[p.kind]
            if db and (db.not_tradeable or db.untradeable or db.not_tradable or db.cannot_trade) then return false end
            if p.not_tradeable or p.untradeable or p.not_tradable then return false end
            local pr = p.properties
            if pr and (pr.not_tradeable or pr.untradeable or pr.cannot_trade) then return false end
            return true
        end
        local function locked(p)
            if LockTracker and LockTracker.is_locked then
                local ok, isL = pcall(LockTracker.is_locked, p)
                if ok then return isL and true or false end
            end
            return p.locked == true or (p.properties and p.properties.locked == true) or false
        end

        local petList = {}
        for uid, p in pairs(pets) do
            if p and p.unique and p.category == "pets"
               and not offered[uid] and rarityOk(p) and tradeable(p) and not locked(p) then
                table.insert(petList, p)
            end
        end
        if #petList == 0 and not AO.confirm then AO.running = false; return end

        for i = #petList, 2, -1 do
            local j = math.random(1, i)
            petList[i], petList[j] = petList[j], petList[i]
        end

        local lo = math.min(AO.min, AO.max)
        local hi = math.max(AO.min, AO.max)
        local freeSlots = math.max(0, AO_MAX_PETS - getMyOfferCount())
        local target = math.min(math.random(lo, hi), freeSlots, #petList)
        if target <= 0 and not AO.confirm then AO.running = false; return end
        local addedCount = 0

        local vp = game.Workspace.CurrentCamera.ViewportSize
        local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")

        local cursorGui, cursor
        local curX, curY = vp.X * 0.82, vp.Y * 0.72
        pcall(function()
            cursorGui = Instance.new("ScreenGui")
            cursorGui.Name = "_AOFakeCursor"
            cursorGui.ResetOnSpawn = false
            cursorGui.DisplayOrder = 999
            cursorGui.IgnoreGuiInset = true
            cursorGui.Parent = playerGui
            cursor = Instance.new("ImageLabel", cursorGui)
            cursor.Size = UDim2.new(0, 72, 0, 72)
            cursor.BackgroundTransparency = 1
            cursor.Image = "rbxasset://textures/Cursors/KeyboardMouse/ArrowCursor.png"
            cursor.ZIndex = 100
            cursor.Position = UDim2.new(0, curX, 0, curY)
        end)

        local function setPos(x, y)
            pcall(function() if cursor then cursor.Position = UDim2.new(0, x, 0, y) end end)
        end
        local function buildFrameMap()
            local map = {}
            pcall(function()
                for uid in pairs(BackpackApp.button_by_unique or {}) do
                    local target = BackpackApp.content:FindFirstChild(uid, true)
                    if target and target:IsA("GuiObject") then map[uid] = target end
                end
            end)
            return map
        end
        local _frameMap = {}
        local _lastHoveredUid = nil
        local _tooltipTargetX, _tooltipTargetY = 0, 0
        local _origTooltipRefresh = nil
        local function getItemDataUnderCursor(cx, cy)
            for uid, frame in pairs(_frameMap) do
                if frame and frame.Visible then
                    local abs = frame.AbsolutePosition
                    local sz  = frame.AbsoluteSize
                    if cx >= abs.X and cx <= abs.X + sz.X and cy >= abs.Y and cy <= abs.Y + sz.Y then
                        local btnData = BackpackApp.button_by_unique[uid]
                        local itemData = btnData and btnData.item_data
                        if itemData then return uid, itemData end
                    end
                end
            end
            return nil, nil
        end
        local function patchTooltipRefresh()
            local innerTooltip = BackpackApp.tooltip and BackpackApp.tooltip.tooltip
            if not innerTooltip then return end
            if _origTooltipRefresh then return end
            _origTooltipRefresh = innerTooltip.refresh
            innerTooltip.refresh = function(self, ...)
                _origTooltipRefresh(self, ...)
                local container = self:get_container()
                if container then
                    container.AnchorPoint = Vector2.new(0, 0)
                    container.Position = UDim2.fromOffset(_tooltipTargetX + 52, _tooltipTargetY + 8)
                end
            end
        end
        local function unpatchTooltipRefresh()
            local innerTooltip = BackpackApp.tooltip and BackpackApp.tooltip.tooltip
            if innerTooltip and _origTooltipRefresh then
                innerTooltip.refresh = _origTooltipRefresh
                _origTooltipRefresh = nil
            end
        end
        local function updateHoverTooltip(cx, cy)
            pcall(function()
                local uid, itemData = getItemDataUnderCursor(cx, cy)
                if uid then
                    _tooltipTargetX, _tooltipTargetY = cx, cy
                    if uid ~= _lastHoveredUid then
                        _lastHoveredUid = uid
                        unpatchTooltipRefresh()
                        BackpackApp.tooltip:_hide_no_refresh()
                        patchTooltipRefresh()
                        BackpackApp.tooltip:_show_item_data(itemData)
                    end
                else
                    if _lastHoveredUid then
                        _lastHoveredUid = nil
                        unpatchTooltipRefresh()
                        BackpackApp.tooltip:hide()
                    end
                end
            end)
        end
        local function glideTo(sx, sy, tx, ty)
            local steps = math.random(10, 16)
            for s = 1, steps do
                local t = s / steps
                t = t < 0.5 and 2*t*t or -1+(4-2*t)*t
                local cx = sx + (tx-sx)*t
                local cy = sy + (ty-sy)*t
                setPos(cx, cy)
                updateHoverTooltip(cx, cy)
                w(0.012 + math.random()*0.008)
            end
            setPos(tx, ty)
            updateHoverTooltip(tx, ty)
        end
        local function extractFrame(d)
            if not d then return nil end
            if typeof(d) == "Instance" and d:IsA("GuiObject") then return d end
            if typeof(d) == "table" then
                for _, key in ipairs({"frame","instance","button","object"}) do
                    local v = d[key]
                    if v and typeof(v) == "Instance" and v:IsA("GuiObject") then return v end
                end
                for _, v in pairs(d) do
                    if typeof(v) == "Instance" and v:IsA("GuiObject") then return v end
                end
            end
        end
        local function findButton(unique)
            local f = extractFrame(BackpackApp.button_by_unique and BackpackApp.button_by_unique[unique])
            if f then return f end
            local c = BackpackApp.content
            if not c then return nil end
            for _, child in ipairs(c:GetChildren()) do
                if child.Name == unique then
                    for _, desc in ipairs(child:GetDescendants()) do
                        if (desc:IsA("ImageButton") or desc:IsA("TextButton")) and desc.AbsoluteSize.X > 8 then return desc end
                    end
                    return child
                end
            end
            for _, desc in ipairs(c:GetDescendants()) do
                if desc.Name == unique and desc:IsA("GuiObject") then return desc end
            end
        end
        local function scrollToAndGetPos(frame)
            local scroll = BackpackApp.scroll
            if scroll and scroll:IsA("ScrollingFrame") then
                local sY = scroll.AbsoluteSize.Y
                local cY = scroll.CanvasPosition.Y
                local btnTop = (frame.AbsolutePosition.Y - scroll.AbsolutePosition.Y) + cY
                local btnH   = frame.AbsoluteSize.Y
                local tgt = math.max(0, math.min(btnTop - sY*0.5 + btnH*0.5, scroll.CanvasSize.Y.Offset - sY))
                local diff = tgt - cY
                if math.abs(diff) > 5 then
                    local midX = scroll.AbsolutePosition.X + scroll.AbsoluteSize.X * 0.5
                    local midY = scroll.AbsolutePosition.Y + sY * 0.5
                    glideTo(curX, curY, midX, midY)
                    curX, curY = midX, midY
                    local steps = math.max(4, math.min(12, math.ceil(math.abs(diff) / 50)))
                    for s = 1, steps do
                        local t = s / steps
                        t = t < 0.5 and 2*t*t or -1+(4-2*t)*t
                        scroll.CanvasPosition = Vector2.new(0, cY + diff * t)
                        w(0.035)
                    end
                    scroll.CanvasPosition = Vector2.new(0, tgt)
                    RunService.RenderStepped:Wait()
                    RunService.RenderStepped:Wait()
                    w(0.1)
                end
            end
            local abs = frame.AbsolutePosition
            local sz  = frame.AbsoluteSize
            return abs.X + sz.X*0.5, abs.Y + sz.Y*0.5
        end
        local function clearSearch()
            pcall(function()
                if BackpackApp.search_bar then BackpackApp.search_bar.search_param = nil end
                local tb = BackpackApp.instance.Frame.Header.InsetSpace.Search.TextBox
                if tb then tb.Text = "" end
                BackpackApp:refresh_rendered_items()
            end)
        end

        for i = 1, #petList do
            if not AO.enabled then break end
            if not tradeActive() then break end
            if addedCount >= target then break end
            if getMyOfferCount() >= AO_MAX_PETS then break end
            local pet = petList[i]

            local petName = pet.kind or ""
            pcall(function()
                local e = InventoryDB.pets[pet.kind]
                if e and e.name then petName = e.name end
            end)

            local addBtnX, addBtnY = vp.X * 0.3, vp.Y * 0.6
            pcall(function()
                local btn = TradeApp.my_negotiation_offer_pane:get_add_item_button_if_exists()
                if btn and btn:IsA("GuiObject") then
                    addBtnX = btn.AbsolutePosition.X + btn.AbsoluteSize.X * 0.5
                    addBtnY = btn.AbsolutePosition.Y + btn.AbsoluteSize.Y * 0.5
                end
            end)
            glideTo(curX, curY, addBtnX, addBtnY)
            curX, curY = addBtnX, addBtnY
            w(0.12)
            setPos(curX, curY + 2) w(0.05) setPos(curX, curY)
            w(0.2)

            UIManager.set_app_visibility('BackpackApp', true)
            w(0.35)

            local searchX, searchY = vp.X * 0.5, vp.Y * 0.15
            pcall(function()
                local tb = BackpackApp.instance.Frame.Header.InsetSpace.Search.TextBox
                if tb then
                    searchX = tb.AbsolutePosition.X + tb.AbsoluteSize.X * 0.5
                    searchY = tb.AbsolutePosition.Y + tb.AbsoluteSize.Y * 0.5
                end
            end)
            glideTo(curX, curY, searchX, searchY)
            curX, curY = searchX, searchY
            w(0.08)

            for ci = 1, #petName do
                local typed = petName:sub(1, ci)
                pcall(function()
                    if BackpackApp.search_bar then BackpackApp.search_bar.search_param = typed end
                    local tb = BackpackApp.instance.Frame.Header.InsetSpace.Search.TextBox
                    if tb then tb.Text = typed end
                    BackpackApp:refresh_rendered_items()
                end)
                w(0.05 + math.random() * 0.04)
            end
            w(0.4 + math.random() * 0.3)

            _frameMap = buildFrameMap()
            w(0.12)

            local slotX, slotY = vp.X * 0.5, vp.Y * 0.4
            local frame = findButton(pet.unique)
            if frame then slotX, slotY = scrollToAndGetPos(frame) end
            glideTo(curX, curY, slotX, slotY)
            curX, curY = slotX, slotY

            _frameMap = buildFrameMap()
            _lastHoveredUid = nil
            updateHoverTooltip(slotX, slotY)
            w(0.55 + math.random() * 0.2)

            unpatchTooltipRefresh()
            pcall(function() BackpackApp.tooltip:hide() end)
            _lastHoveredUid = nil
            w(0.08)

            setPos(curX, curY + 2) w(0.05) setPos(curX, curY)
            w(0.08)

            unpatchTooltipRefresh()
            clearSearch()
            UIManager.set_app_visibility('BackpackApp', false)
            w(0.15)

            local before = getMyOfferCount()
            local origPick = BackpackApp.pick_item
            BackpackApp.pick_item = function()
                BackpackApp.pick_item = origPick
                return pet
            end
            -- Call the LIVE add method: routes to the original for real trades,
            -- and to the mock add (mockState.trade.sender_offer) during a showcase trade.
            local liveAdd = TradeApp._add_item_to_my_offer or realAdd
            pcall(function() liveAdd(TradeApp) end)
            if BackpackApp.pick_item ~= origPick then BackpackApp.pick_item = origPick end

            if getMyOfferCount() > before then addedCount = addedCount + 1 end

            local dx, dy = curX + math.random(-20, 20), curY + math.random(5, 25)
            glideTo(curX, curY, dx, dy); curX, curY = dx, dy
            w(0.5 + math.random() * 0.4)
        end

        if AO.confirm then
            local function stageNow()
                local ok, s = pcall(function() return TradeApp:_get_current_trade_stage() end)
                return ok and s or nil
            end
            local function findActionButton(word)
                local guis = {}
                local t = playerGui and playerGui:FindFirstChild("TradeApp")
                if t then table.insert(guis, t) end
                for _, g in ipairs(playerGui and playerGui:GetChildren() or {}) do
                    if g:IsA("ScreenGui") and g.Name:lower():find("trade") and g ~= t then table.insert(guis, g) end
                end
                for _, g in ipairs(guis) do
                    for _, d in ipairs(g:GetDescendants()) do
                        if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible and d.AbsoluteSize.X > 20 then
                            if buttonLabel(d):lower():find(word) then return d end
                        end
                    end
                end
                return nil
            end
            local function waitForActionButton(word, timeout)
                local b, g = findActionButton(word), 0
                while not b and AO.confirm and tradeActive() and g < timeout do
                    task.wait(0.2); g = g + 0.2
                    b = findActionButton(word)
                end
                return b
            end
            local function clickButton(b, fbX, fbY)
                local tx, ty = fbX, fbY
                if b then
                    tx = b.AbsolutePosition.X + b.AbsoluteSize.X * 0.5
                    ty = b.AbsolutePosition.Y + b.AbsoluteSize.Y * 0.5
                end
                glideTo(curX, curY, tx, ty); curX, curY = tx, ty
                w(0.12)
                setPos(curX, curY + 2) w(0.05) setPos(curX, curY)
                w(0.1)
            end

            if tradeActive() and stageNow() == "negotiation" then
                local cap, g = lockTime() + 2, 0   -- wait the real negotiation lock, + small buffer
                while AO.confirm and tradeActive() and stageNow() == "negotiation" and lockGoing() and g < cap do
                    task.wait(0.2); g = g + 0.2
                end
                local b = waitForActionButton("accept", 12)
                if tradeActive() and stageNow() == "negotiation" then
                    clickButton(b, vp.X * 0.5, vp.Y * 0.86)
                    pcall(function() TradeApp:_on_accept_pressed(TradeApp) end)
                    dismissScamDialog()
                end
            end

            local waited = 0
            while AO.confirm and tradeActive() and stageNow() ~= "confirmation" and waited < 300 do
                task.wait(0.25); waited = waited + 0.25
            end

            if AO.confirm and tradeActive() and stageNow() == "confirmation" then
                local cap, guard = lockTime() + 3, 0   -- wait the real confirmation lock, + small buffer
                while AO.confirm and tradeActive() and lockGoing() and guard < cap do
                    task.wait(0.2); guard = guard + 0.2
                end
                local b = waitForActionButton("confirm", 12)
                if tradeActive() and stageNow() == "confirmation" then
                    clickButton(b, vp.X * 0.5, vp.Y * 0.86)
                    pcall(function() TradeApp:_on_confirm_pressed(TradeApp) end)
                    dismissScamDialog()
                    task.wait(0.4); dismissScamDialog()
                end
            end
        end

        glideTo(curX, curY, vp.X * 0.82, vp.Y * 0.72)
        w(0.2)
        pcall(function() if cursorGui then cursorGui:Destroy() end end)
        AO.running = false
    end)
end

-- auto-run when a real trade opens while the toggle is on
task.spawn(function()
    local wasActive = false
    while true do
        local active = tradeActive()
        if AO.enabled and active and not wasActive then doOffer() end
        wasActive = active
        task.wait(0.5)
    end
end)
-- continuously dismiss scam popups while Accept+Confirm is on
task.spawn(function()
    while true do
        if AO.confirm then dismissScamDialog() end
        task.wait(0.25)
    end
end)

-- Build the compact Auto-Offer controls onto a parent frame (Misc Page 2).
-- Styled to match the Self-Badge section: FredokaOne, UICorner+UIStroke, same ON/OFF palette.
_G._aoBuildControls = function(parent)
    local GRN,GRNT,GRNS = Color3.fromRGB(30,80,50),  Color3.fromRGB(80,255,130), Color3.fromRGB(0,255,100)
    local RED,REDT,REDS = Color3.fromRGB(80,30,30),  Color3.fromRGB(255,90,90),  Color3.fromRGB(255,60,60)
    local PURP          = Color3.fromRGB(190,34,230)
    local NEUT,NEUTT    = Color3.fromRGB(40,40,52),  Color3.fromRGB(225,225,235)
    local function corner(o) Instance.new("UICorner", o).CornerRadius = UDim.new(0,3) end
    local function border(o,c) mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=c, Thickness=0.7, Transparency=0.4, Parent=o}) end

    -- Section header (matches "Self Badge")
    mk("TextLabel", {Size=UDim2.new(1,0,0,11), Position=UDim2.new(0,0,0,34), BackgroundTransparency=1, Text="Auto Offer", Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=PURP, TextXAlignment=Enum.TextXAlignment.Left, ZIndex=7, Parent=parent})

    -- Row A: two toggles side by side
    local rowA = mk("Frame", {Size=UDim2.new(1,0,0,15), Position=UDim2.new(0,0,0,48), BackgroundTransparency=1, ZIndex=7, Parent=parent})
    local function mkToggle(posx, onText, offText, get)
        local b = mk("TextButton", {Size=UDim2.new(0.5,-2,1,0), Position=UDim2.new(posx, posx>0 and 2 or 0,0,0), BackgroundColor3=RED, Text=offText, Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=REDT, ZIndex=7, Parent=rowA})
        corner(b)
        local st = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=REDS, Thickness=0.7, Transparency=0.3, Parent=b})
        local function ref()
            local on = get()
            b.Text = on and onText or offText
            b.BackgroundColor3 = on and GRN or RED
            b.TextColor3 = on and GRNT or REDT
            st.Color = on and GRNS or REDS
        end
        ref()
        return b, ref
    end
    local offerBtn, refOffer = mkToggle(0,   "Offer: ON",   "Offer: OFF",   function() return AO.enabled end)
    offerBtn.MouseButton1Click:Connect(function() AO.enabled = not AO.enabled; refOffer(); if AO.enabled and tradeActive() then doOffer() end end)
    local acBtn, refAC = mkToggle(0.5, "Confirm: ON",  "Confirm: OFF",  function() return AO.confirm end)
    acBtn.MouseButton1Click:Connect(function() AO.confirm = not AO.confirm; refAC() end)

    -- Row B: speed selector
    mk("TextLabel", {Size=UDim2.new(0,32,0,14), Position=UDim2.new(0,0,0,67), BackgroundTransparency=1, Text="Speed", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=NEUTT, TextXAlignment=Enum.TextXAlignment.Left, ZIndex=7, Parent=parent})
    local speedBtns = {}
    local function refSpeed()
        for _,e in ipairs(speedBtns) do
            local on = e.v == AO.speed
            e.b.BackgroundColor3 = on and PURP or NEUT
            e.b.TextColor3 = on and Color3.fromRGB(255,255,255) or NEUTT
        end
    end
    for i,v in ipairs({1,2,3,5}) do
        local sb = mk("TextButton", {Size=UDim2.new(0,18,0,14), Position=UDim2.new(0,33+(i-1)*21,0,67), BackgroundColor3=NEUT, Text=v.."x", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=NEUTT, ZIndex=7, Parent=parent})
        corner(sb); border(sb, PURP)
        table.insert(speedBtns, {b=sb, v=v})
        sb.MouseButton1Click:Connect(function() AO.speed = v; refSpeed() end)
    end
    refSpeed()

    -- Row C: Min / Max steppers side by side (each group fits in half of the 118px inner width)
    local function mkStepper(px, nm, get, set)
        mk("TextLabel", {Size=UDim2.new(0,16,0,14), Position=UDim2.new(0,px,0,86), BackgroundTransparency=1, Text=nm, Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=NEUTT, TextXAlignment=Enum.TextXAlignment.Left, ZIndex=7, Parent=parent})
        local minus = mk("TextButton", {Size=UDim2.new(0,13,0,14), Position=UDim2.new(0,px+16,0,86), BackgroundColor3=NEUT, Text="-", Font=Enum.Font.FredokaOne, TextSize=11, TextColor3=NEUTT, ZIndex=7, Parent=parent})
        corner(minus); border(minus, PURP)
        local val = mk("TextLabel", {Size=UDim2.new(0,13,0,14), Position=UDim2.new(0,px+29,0,86), BackgroundTransparency=1, Text=tostring(get()), Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=Color3.fromRGB(220,235,255), ZIndex=7, Parent=parent})
        local plus = mk("TextButton", {Size=UDim2.new(0,13,0,14), Position=UDim2.new(0,px+42,0,86), BackgroundColor3=NEUT, Text="+", Font=Enum.Font.FredokaOne, TextSize=11, TextColor3=NEUTT, ZIndex=7, Parent=parent})
        corner(plus); border(plus, PURP)
        local function rd() val.Text = tostring(get()) end
        minus.MouseButton1Click:Connect(function() set(get()-1); rd() end)
        plus.MouseButton1Click:Connect(function() set(get()+1); rd() end)
        return rd
    end
    local rdMax
    local rdMin = mkStepper(0, "Min", function() return AO.min end, function(v)
        AO.min = math.clamp(v,1,AO_MAX_PETS); if AO.max < AO.min then AO.max = AO.min; if rdMax then rdMax() end end
    end)
    rdMax = mkStepper(61, "Max", function() return AO.max end, function(v)
        AO.max = math.clamp(v,1,AO_MAX_PETS); if AO.min > AO.max then AO.min = AO.max; rdMin() end
    end)
end
end
_aoEngine()
end

_G._userInfoCache = _G._userInfoCache or {}
function _G._prefetchUserInfo(userId)
    if userId <= 0 or _G._userInfoCache[userId] then return end
    task.spawn(function()
        pcall(function()
            local UserService = game:GetService("UserService")
            local info = UserService:GetUserInfosByUserIdsAsync({ userId })
            if info and info[1] then
                _G._userInfoCache[userId] = _G._userInfoCache[userId] or {}
                _G._userInfoCache[userId].username    = info[1].Username
                _G._userInfoCache[userId].displayName = info[1].DisplayName
            end
        end)
        pcall(function()
            local img, ready
            repeat
                img, ready = game.Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
                if not ready then task.wait(1) end
            until ready
            _G._userInfoCache[userId] = _G._userInfoCache[userId] or {}
            _G._userInfoCache[userId].thumbnail = img
        end)
    end)
end

-- Push cached username/thumbnail into the open profile header, retrying until the
-- prefetch fills (or the user navigates to a different profile). `want` is
-- "username" or "thumbnail". Calling set_header_info is what updates the visible UI.
function _G._applyCachedHeader(self, want)
    _G._prefetchUserInfo(self.user_id)  -- ensure a fetch is in flight for this user
    task.spawn(function()
        for _ = 1, 150 do  -- poll up to ~15s; apply only while this profile is the active one
            local c = _G._userInfoCache[self.user_id]
            if c and self.app and self.app.player_profile == self then
                if want == "username" and c.username then
                    self.username     = c.username
                    self.display_name = c.displayName or c.username
                    self.app:set_header_info({ username = self.username })
                    return
                elseif want == "thumbnail" and c.thumbnail then
                    self.image_id = c.thumbnail
                    self.app:set_header_info({ profile_icon = c.thumbnail })
                    return
                end
            end
            task.wait(0.1)
        end
    end)
end

-- Patch PlayerProfile immediately — must happen before any PlayerProfile.new()
-- call so _load_user_info and is_page_empty are fixed from the first profile open
do
    local ok, PlayerProfile = pcall(load, "PlayerProfile")
    if ok and PlayerProfile then
        -- Guard _load_user_info against nil UserService result (userId=0 or invalid)
        if PlayerProfile._load_user_info then
            local _orig = PlayerProfile._load_user_info
            PlayerProfile._load_user_info = function(self, ...)
                if not self.user_id or self.user_id <= 0 then return end
                -- Online players load instantly from their Player object — keep original
                -- (it also sets the in_trade button state). Offline presets: cache + retry.
                if self.player then return _orig(self, ...) end
                _G._applyCachedHeader(self, "username")
            end
        end
        if PlayerProfile._load_profile_pic then
            local _orig = PlayerProfile._load_profile_pic
            PlayerProfile._load_profile_pic = function(self, ...)
                if not self.user_id or self.user_id <= 0 then return end
                if self.player then return _orig(self, ...) end
                _G._applyCachedHeader(self, "thumbnail")
            end
        end
        -- Guard is_page_empty against nil profile_data and nil stickers per page
        if PlayerProfile.is_page_empty then
            local _orig = PlayerProfile.is_page_empty
            PlayerProfile.is_page_empty = function(self, page)
                if not self.profile_data then return true end
                local pages = self.profile_data.pages
                if pages then
                    local pageData = pages[page] or pages[tostring(page)]
                    if pageData then
                        for _, slotData in pairs(pageData) do
                            if slotData and next(slotData) then return false end
                        end
                    end
                end
                local stickers = self.profile_data.stickers
                if stickers == nil then return true end
                return not (stickers[page] and next(stickers[page]))
            end
        end
    end
end

-- Fake trade records injected into GetTradeHistory results
local _mockTradeHistory = {}  -- newest first

-- Hook _get_trade_history to inject mock records
do
    local _origGetTradeHistory = TradeHistoryApp._get_trade_history
    TradeHistoryApp._get_trade_history = function(self, useCached)
        local real = _origGetTradeHistory(self, useCached) or {}
        if #_mockTradeHistory == 0 then return real end
        -- Combine real + mock then sort oldest-first (ascending timestamp)
        -- so that after _refresh reverses it, newest appears at top
        local combined = {}
        for _, r in ipairs(real) do table.insert(combined, r) end
        for _, r in ipairs(_mockTradeHistory) do table.insert(combined, r) end
        table.sort(combined, function(a, b)
            return (a.timestamp or 0) < (b.timestamp or 0)
        end)
        return combined
    end
end

if not TradeApp then
    warn("[MockTrade] TradeApp not found — aborting")
    return
end

-- FAKE PET SPAWNER (for receiving mock trade items)
-- Hoisted outside do block so _addToInventory can access them
local _spawnerPets   = {}
-- Newness groups matching the real game's ordering (from blueprint.lua)
-- Higher = appears first in backpack. Each group decrements so newest appears top.
local _newnessGroups = {
    mega_neon_flyable_rideable = 990000,
    mega_neon_flyable          = 980000,
    mega_neon_rideable         = 970000,
    mega_neon                  = 960000,
    neon_flyable_rideable      = 950000,
    neon_flyable               = 940000,
    neon_rideable              = 930000,
    neon                       = 920000,
    flyable_rideable           = 910000,
    flyable                    = 900000,
    rideable                   = 890000,
    regular                    = 880000,
}

local function _getPropertyGroup(props)
    local isMega  = props.mega_neon or false
    local isNeon  = props.neon      or false
    local canFly  = props.flyable   or false
    local canRide = props.rideable  or false
    if isMega then
        if canFly and canRide then return "mega_neon_flyable_rideable"
        elseif canFly  then return "mega_neon_flyable"
        elseif canRide then return "mega_neon_rideable"
        else return "mega_neon" end
    elseif isNeon then
        if canFly and canRide then return "neon_flyable_rideable"
        elseif canFly  then return "neon_flyable"
        elseif canRide then return "neon_rideable"
        else return "neon" end
    else
        if canFly and canRide then return "flyable_rideable"
        elseif canFly  then return "flyable"
        elseif canRide then return "rideable"
        else return "regular" end
    end
end

-- Pet name generator (from blueprint.lua)
local _petNamesByType = {}
local _namePrefixes = {"★","☆","♡","☁️","✨","🍓","🌸","🍯","☕","🌙","🌈","❄️","🫧","🍬","🍪","🥛"}
local _nameWords    = {"Shadow","Blaze","Frost","Thunder","Moon","Star","Sky","Ocean","River","Storm",
    "Ember","Ash","Dusk","Dawn","Night","Day","Sun","Wind","Rain","Snow","Ice","Fire",
    "Nova","Cosmo","Galaxy","Orbit","Comet","Meteor","Aurora","Nebula","Crystal","Gem",
    "Ruby","Sapphire","Emerald","Diamond","Gold","Silver","Mystic","Magic","Enchant"}

local function generatePetName(petId)
    if petId and not _petNamesByType[petId] then _petNamesByType[petId] = {} end
    local name; local attempts = 0
    repeat
        local word = _nameWords[math.random(1, #_nameWords)]
        if math.random(1, 3) == 1 then
            name = _namePrefixes[math.random(1, #_namePrefixes)] .. word
        else
            name = word .. " " .. _namePrefixes[math.random(1, #_namePrefixes)]
        end
        attempts = attempts + 1
    until not (petId and _petNamesByType[petId][name]) or attempts > 100
    if petId and attempts <= 100 then _petNamesByType[petId][name] = true end
    return name
end

-- Hoisted helpers used by _addToInventory and spawner internals
local function updateData(key, fn)
    local d = ClientData.get(key)
    local c = table.clone(d)
    local result = fn(c)
    pcall(function() setthreadidentity(2) end)
    ClientData.predict(key, result)
    pcall(function() setthreadidentity(8) end)
end
local function findIdx(arr, pred)
    for i,v in pairs(arr) do if pred(v,i) then return i end end
end

do

local function _setupPetHandler()
    local ok, EP = pcall(load, "EquippedPets")
    if not ok or not EP then return end

    -- 1. Allow equipping 2 pets at once
    EP.get_max_equip_count = function() return 2 end

    -- 2. Fake pets never count as "equipped" so they don't block real slots
    local _origIsEquipped = EP.is_equipped
    if _origIsEquipped then
        EP.is_equipped = function(item)
            if item and item.unique and _spawnerPets[item.unique] then return false end
            return _origIsEquipped(item)
        end
    end

    -- 3. For equip-slot counting only, fake pets don't fill real slots.
    local _origGetMyEquipped = EP.get_my_equipped
    if _origGetMyEquipped then
        EP.get_my_equipped = function(...)
            -- Return full list including spawned pets so UI shows main/alt buttons
            return _origGetMyEquipped(...)
        end
    end
    -- Only filter for slot-count checks via a separate helper
    EP._get_real_equipped_count = function()
        local result = _origGetMyEquipped and _origGetMyEquipped() or {}
        local count = 0
        for _, wrapper in ipairs(result) do
            if not _spawnerPets[wrapper.pet_unique] then
                count = count + 1
            end
        end
        return count
    end

    -- Hook ClientData.get so subscription_manager ALWAYS contains equip_2x_pets,
    local function _getExpiry() return os.time() + 60 * 60 * 24 * 25 end

    local _origGet = ClientData.get
    ClientData.get = function(key, ...)
        local data = _origGet(key, ...)
        if key == "subscription_manager" then
            data = data or {}
            -- Always overwrite so expiry is always fresh and days-left is correct
            data.equip_2x_pets = { expiration = _getExpiry() }
        end
        return data
    end

    -- Hook get_server for alt accounts / observers
    local _origGetServer = ClientData.get_server
    if _origGetServer then
        ClientData.get_server = function(player, key, ...)
            local data = _origGetServer(player, key, ...)
            if key == "subscription_manager" and player == Players.LocalPlayer then
                data = data or {}
                data.equip_2x_pets = { expiration = _getExpiry() }
            end
            return data
        end
    end

    pcall(function()
        local id = (get_thread_identity and get_thread_identity()) or 8
        setthreadidentity(2)
        local sm = ClientData.get("subscription_manager") or {}
        ClientData.predict("subscription_manager", sm)
        ClientData.update("subscription_manager", sm)
        setthreadidentity(id)
    end)

    -- 5. Hook CertificateApp so the cert popup shows the correct Pet Handler text
    task.defer(function()
        pcall(function()
            local certApp = UIManager.apps and UIManager.apps.CertificateApp
            if not certApp then return end
            local orig = certApp.display_certificate
            certApp.display_certificate = function(self, sub_id, sub_data)
                if sub_id == "equip_2x_pets" then
                    local sm = ClientData.get("subscription_manager") or {}
                    local expiry = sm.equip_2x_pets and sm.equip_2x_pets.expiration
                    local dateStr = expiry
                        and DateTime.fromUnixTimestamp(expiry):FormatLocalTime("ll", "en-us")
                        or ""
                    self.expiration_date.Text = dateStr; self.body.CertificateName.Text = "PET HANDLER"
                    self.certificate_description.Text = "Certified to equip and care for multiple pets simultaneously."
                    self.certificate_icon.Image = "rbxassetid://135693406849779"; self.player_name.Text = Players.LocalPlayer.Name
                    self.UIManager.set_app_visibility(self.ClassName, true)
                else
                    return orig(self, sub_id, sub_data)
                end
            end
        end)
    end)
end
_setupPetHandler()

local _equippedPets  = {} -- up to 2 slots: [1] and [2]
local _equippedPet   = nil -- kept for compatibility (points to most recently equipped)
local _currentRideId = nil
local _rideAnimTrack = nil
local _ailmentsCache = {}

-- Use the real game PetNeonHelper — it has correct timing for mega neon
local PetNeonHelper = load("PetNeonHelper")

local petModels = {}
local function getPetModel(kind)
    if petModels[kind] then return petModels[kind]:Clone() end
    local p = DownloadClient.promise_download_copy("Pets", kind)
    if p then local m=p:expect(); petModels[kind]=m; return m:Clone() end
end
local function applyNeonToModel(petModel, petData)
    local pm = petModel:FindFirstChild("PetModel"); if not pm then return end
    local entry = IDB and IDB.pets and IDB.pets[petData.id]; if not entry then return end
    if petData.properties.mega_neon and entry.mega_neon_parts then
        if entry.neon_parts then pcall(function() PetNeonHelper.apply_neon(pm, entry.neon_parts) end) end
        -- Use the real game PetNeonHelper.precache + step_mega_neon exactly like the blueprint script
        -- (these are real game functions with correct timing built in)
        task.spawn(function()
            local kindData = KindDB[petData.id] or KindDB[petData.kind]
            if not kindData or not kindData.mega_neon_parts then return end
            local cache = { cached_colors = nil, cached_parts = nil }
            pcall(function() PetNeonHelper.precache(cache, kindData, pm) end)
            while petModel.Parent do
                pcall(function() PetNeonHelper.step_mega_neon(cache, pm, kindData) end)
                RunService.RenderStepped:Wait()
            end
        end)
    elseif petData.properties.neon and entry.neon_parts then
        pcall(function() PetNeonHelper.apply_neon(pm, entry.neon_parts) end)
    end
end
local function addWrapper(w)
    updateData("pet_char_wrappers", function(t) w.unique=#t+1; w.index=#t+1; t[#t+1]=w; return t end)
end
local function addState(s)
    updateData("pet_state_managers", function(t) t[#t+1]=s; return t end)
end
local function removeWrapper(uid)
    updateData("pet_char_wrappers", function(t)
        local i=findIdx(t,function(w) return w.pet_unique==uid end)
        if i then table.remove(t,i); for j,w in pairs(t) do w.unique=j; w.index=j end end; return t
    end)
end
local function removeState(uid)
    local pet=_spawnerPets[uid]; if not pet or not pet.model then return end
    updateData("pet_state_managers", function(t)
        local i=findIdx(t,function(s) return s.char==pet.model end)
        if i then table.remove(t,i) end; return t
    end)
end
local function clearPetStates(uid)
    local pet=_spawnerPets[uid]; if not pet or not pet.model then return end
    updateData("pet_state_managers", function(t)
        local i=findIdx(t,function(s) return s.char==pet.model end)
        if i then local u=table.clone(t); u[i]=table.clone(u[i]); u[i].states={}; return u end; return t
    end)
end
local function setPetState(uid, stateId)
    local pet=_spawnerPets[uid]; if not pet or not pet.model then return end
    updateData("pet_state_managers", function(t)
        local i=findIdx(t,function(s) return s.char==pet.model end)
        if i then local u=table.clone(t); u[i]=table.clone(u[i]); u[i].states={{id=stateId}}; return u end; return t
    end)
end
local function clearPlayerStates()
    updateData("state_manager", function(s) local u=table.clone(s); u.states={}; u.is_sitting=false; return u end)
end
local function setPlayerState(stateId)
    updateData("state_manager", function(s) local u=table.clone(s); u.states={{id=stateId}}; u.is_sitting=true; return u end)
end
local function attachRideConstraint(petModel)
    local char=Players.LocalPlayer.Character; if not char or not char.PrimaryPart then return false end
    local ridePos=petModel:FindFirstChild("RidePosition",true); if not ridePos then return false end
    local att = mk("Attachment", {Parent=ridePos, Position=Vector3.new(0,1.237,0), Name="SourceAttachment"})
    local rc = mk("RigidConstraint", {Name="StateConnection"})
    rc.Attachment0=att; rc.Attachment1=char.PrimaryPart.RootAttachment; rc.Parent=char; return true
end
local function dismount()
    if not _currentRideId then return end
    local pet=_spawnerPets[_currentRideId]
    if pet and pet.model then
        if _rideAnimTrack then _rideAnimTrack:Stop(); _rideAnimTrack:Destroy(); _rideAnimTrack=nil end
        local sa=pet.model:FindFirstChild("SourceAttachment",true); if sa then sa:Destroy() end
        local char=Players.LocalPlayer.Character
        if char then for _,p in pairs(char:GetDescendants()) do if p:IsA("BasePart") and p:GetAttribute("HaveMass") then p.Massless=false end end end
        clearPetStates(_currentRideId); clearPlayerStates(); pet.model:ScaleTo(1)
    end
    _currentRideId=nil
end
local function mount(uid, playerState, petState)
    local pet=_spawnerPets[uid]; if not pet or not pet.model then return end
    local char=Players.LocalPlayer.Character
    if not char or not char.PrimaryPart or not char:FindFirstChild("Humanoid") then return end
    dismount(); _currentRideId=uid
    setPetState(uid,petState); setPlayerState(playerState)
    pet.model:ScaleTo(2); attachRideConstraint(pet.model)
    _rideAnimTrack=char.Humanoid.Animator:LoadAnimation(AnimMgr.get_track("PlayerRidingPet"))
    char.Humanoid.Sit=true
    for _,p in pairs(char:GetDescendants()) do if p:IsA("BasePart") and p.Massless==false then p.Massless=true; p:SetAttribute("HaveMass",true) end end
    _rideAnimTrack:Play()
end

-- Ailments hook
local _origGetServer = ClientData.get_server
ClientData.get_server = function(player, key, ...)
    local data = _origGetServer(player, key, ...)
    if key=="ailments_manager" and player==Players.LocalPlayer then
        local ad = data and table.clone(data) or {}; ad.ailments = ad.ailments or {}
        for petId in pairs(_spawnerPets) do
            if not _ailmentsCache[petId] then
                local types={}; for kind in pairs(AilmentsDB) do if kind~="at_work" and kind~="mystery" and kind~="walking" then table.insert(types,kind) end end
                local pa={}; local used={}
                for i=1,math.min(math.random(2,4),#types) do
                    local k; repeat k=types[math.random(1,#types)] until not used[k]; used[k]=true
                    pa[HttpService:GenerateGUID(false)]={components={},created_timestamp=os.time(),kind=k,progress=0,rate=0,rate_timestamp=os.time(),sort_order=i*100}
                end
                _ailmentsCache[petId]=pa
            end
            ad.ailments[petId]=_ailmentsCache[petId]
        end
        return ad
    end
    return data
end

local function doUnequip(item)
    local pet=_spawnerPets[item.unique]; if not pet then return end
    if _currentRideId==item.unique then dismount() end
    removeWrapper(item.unique); removeState(item.unique)
    if pet.model then pet.model:Destroy(); pet.model=nil end
    if _equippedPet and _equippedPet.unique==item.unique then _equippedPet=nil end
    for i=#_equippedPets,1,-1 do
        if _equippedPets[i].unique==item.unique then table.remove(_equippedPets,i) end
    end
    _ailmentsCache[item.unique]=nil

    -- Rebalance FollowOffset for remaining pets after unequip
    task.defer(function()
        pcall(function()
            local wrappers = ClientData.get("pet_char_wrappers") or {}
            local idx = 0
            for _, w in ipairs(wrappers) do
                if w.controller == Players.LocalPlayer then
                    idx = idx + 1
                    local sp = _spawnerPets[w.pet_unique]
                    local m = sp and sp.model
                    if m then
                        local offset
                        if idx == 1 then offset = Vector3.new(3.5, 0, 0)
                        elseif idx == 2 then offset = Vector3.new(-3.5, 0, 0)
                        else offset = Vector3.new(0, 0, 3.5 * (idx-1)) end
                        m:SetAttribute("FollowOffset", offset)
                    end
                end
            end
        end)
    end)

    safeCall(function()
        setthreadidentity(2)
        local em=ClientData.get("equip_manager") or {}; local pets=em.pets or {}
        for i=#pets,1,-1 do if pets[i] and pets[i].unique==item.unique then table.remove(pets,i) end end
        em.pets=pets; ClientData.update("equip_manager",em); setthreadidentity(8)
    end)
end

local function doEquip(item)
    -- Don't equip same pet twice
    if _spawnerPets[item.unique] and _spawnerPets[item.unique].model then return end
    -- Allow up to 2 equipped pets (pet handler)
    if #_equippedPets >= 2 then
        doUnequip(_equippedPets[1])
    end
    safeCall(function()
        local EP=load("EquippedPets")
        if EP and not EP._spinnerHooked then
            EP._spinnerHooked=true
            -- Allow 2 slots (pet handler)
            EP.get_max_equip_count=function() return 2 end
            -- Spawned pets return false for is_equipped so they don't block the equip button
            local _origIE=EP.is_equipped
            if _origIE then EP.is_equipped=function(it) if _spawnerPets[it and it.unique] then return false end; return _origIE(it) end end
            -- Do NOT filter get_my_equipped — UI needs spawned pets in the list
            -- to show the main/alt interaction buttons
        end
    end)
    local model=getPetModel(item.kind); if not model then return end
    model.Parent=workspace
    applyNeonToModel(model, item)
    _spawnerPets[item.unique].model=model; _equippedPet=item
    table.insert(_equippedPets, item)

    -- Set FollowOffset so pets stand on opposite sides (matches reference script)
    pcall(function()
        local slotIndex = 0
        for _, sp in pairs(_spawnerPets) do
            if sp.model and sp.data then slotIndex = slotIndex + 1 end
        end
        local offset
        if slotIndex <= 1 then offset = Vector3.new(3.5, 0, 0)
        else offset = Vector3.new(-3.5, 0, 0) end
        local kindEntry = IDB and IDB.pets and IDB.pets[item.id or item.kind]
        if kindEntry and kindEntry.follow_offset_scale then
            offset = offset * kindEntry.follow_offset_scale
        end
        model:SetAttribute("FollowOffset", offset)
    end)
    local entry=IDB and IDB.pets and IDB.pets[item.id]
    local trickCount=entry and entry.tricks and #entry.tricks or 0
    local resolvedId=(entry and entry._base_kind) or item.id
    task.defer(function()
        local rpName = (item.properties.rp_name and item.properties.rp_name ~= "")
            and item.properties.rp_name or generatePetName(item.id or item.kind)
        -- Store name back on item so it persists
        item.properties.rp_name = rpName

        addWrapper({
            char               = model,
            mega_neon          = item.properties.mega_neon or false,
            neon               = item.properties.neon or false,
            player             = Players.LocalPlayer,
            entity_controller  = Players.LocalPlayer,
            controller         = Players.LocalPlayer,
            rp_name            = rpName,
            pet_trick_level    = math.max(item.properties.pet_trick_level or 0, trickCount),
            pet_unique         = item.unique,
            pet_id             = resolvedId,
            location           = { full_destination_id = "housing", destination_id      = "housing", house_owner         = Players.LocalPlayer, },
            pet_progression    = { age              = item.properties.age or math.random(1, 6), xp               = item.properties.xp or 0, friendship_level = item.properties.friendship_level or 0, percentage       = math.random(0, 99) / 100, },
            are_colors_sealed  = false,
            is_pet             = true,
        })

        addState({
            char                  = model,
            player                = Players.LocalPlayer,
            store_key             = "pet_state_managers",
            is_sitting            = false,
            chars_connected_to_me = {},
            states                = {},
        })

        task.wait(0.15)

        pcall(function() AilmentsClient.on_ailments_changed(Players.LocalPlayer) end)

        -- Force nametag by triggering a predict update on pet_char_wrappers
        -- CharWrapperClient listens to this and re-renders the name above the pet
        task.wait(0.1)
        safeCall(function()
            updateData("pet_char_wrappers", function(wrappers)
                for _, w in pairs(wrappers) do
                    if w.pet_unique == item.unique then
                        w.rp_name = item.properties.rp_name or ""
                    end
                end
                return wrappers
            end)
        end)

        safeCall(function()
            setthreadidentity(2)
            local em   = ClientData.get("equip_manager") or {}
            local pets = em.pets or {}
            for i = #pets, 1, -1 do
                if pets[i] and pets[i].unique == item.unique then
                    table.remove(pets, i)
                end
            end
            table.insert(pets, item)
            em.pets = pets
            -- predict updates UI instantly; update tells server
            ClientData.predict("equip_manager", em)
            ClientData.update("equip_manager", em)
            setthreadidentity(8)
        end)
    end)
end

-- Tricks — mirror the logic from the reference script exactly
task.spawn(function()
    safeCall(function()
        if type(setthreadidentity)=="function" then setthreadidentity(2) end
        local PA  = load("PetActions")
        local AM  = load("AnimationManager")
        local PEM = load("PetEntityManager")
        local IDB2 = load("InventoryDB")
        if not PA or not PA.do_trick then return end
        local origDoTrick = PA.do_trick
        PA.do_trick = function(wrapper)
            if not (wrapper and _spawnerPets and _spawnerPets[wrapper.pet_unique]) then
                return origDoTrick(wrapper)
            end
            local entry = IDB2.pets[wrapper.pet_id]
            if not entry or not entry.tricks or #entry.tricks == 0 then return end
            local buttons = {}
            for i, trick in ipairs(entry.tricks) do
                if (wrapper.pet_trick_level or 0) < i then
                    buttons[i] = { layout_order=i, text="???", button_state="inactive" }
                else
                    buttons[i] = { layout_order=i, text=trick[1] }
                end
            end
            task.spawn(function()
                local chosen = UIManager.apps.DialogApp:dialog({ dialog_type="ScrollingButtonsDialog", header="SELECT TRICK", buttons=buttons, exit_button=true, cells_per_row=2, padding=10 })
                if not chosen or chosen=="cancel" then return end
                local te = entry.tricks[chosen]; if not te then return end
                local tn = te[1]; local ak = te[2] or tn
                local char = wrapper.char
                local pm = char:FindFirstChild("PetModel")
                local ac = pm and pm:FindFirstChildOfClass("AnimationController")
                local anim = (ac and ac:FindFirstChildOfClass("Animator"))
                    or char:FindFirstChildWhichIsA("Animator", true)
                if not anim then return end
                local at = AM.get_track(ak) or AM.get_track(tn)
                if not at then return end
                -- Fire original to play windup on server
                pcall(function() origDoTrick(wrapper) end)
                task.wait(3)
                pcall(function() UIManager.apps.FocusPetApp:release_focus() end)
                safeCall(function()
                    local sp = _spawnerPets[wrapper.pet_unique]
                    if sp and sp._activeTrickTrack then
                        pcall(function() sp._activeTrickTrack:Stop(0.1) end)
                        sp._activeTrickTrack = nil
                    end
                    local track = anim:LoadAnimation(at)
                    track:Play()
                    if sp then sp._activeTrickTrack = track end
                    task.spawn(function()
                        local lp = Players.LocalPlayer
                        local lpChar = lp and lp.Character
                        local lastPos = lpChar and lpChar:FindFirstChild("HumanoidRootPart") and lpChar.HumanoidRootPart.Position
                        local t = 0
                        while t < 15 do
                            task.wait(0.1); t = t + 0.1
                            if not track.IsPlaying then break end
                            local entity = PEM and PEM.get_pet_entity(char)
                            if entity and entity.move_state and entity.move_state.is_moving then
                                track:Stop(0.2); break
                            end
                            lpChar = lp and lp.Character
                            local hrp = lpChar and lpChar:FindFirstChild("HumanoidRootPart")
                            if hrp and lastPos then
                                if (hrp.Position - lastPos).Magnitude > 1.5 then
                                    track:Stop(0.2); break
                                end
                            end
                            if hrp then lastPos = hrp.Position end
                        end
                        if sp then sp._activeTrickTrack = nil end
                    end)
                end)
            end)
        end
    end)
end)

if not _G._mockTradeRouterHooked then
    _G._mockTradeRouterHooked = true
    local oldGet = RouterClient_.get
    RouterClient_.get = function(name)
        if name=="ToolAPI/Equip" then return {InvokeServer=function(_,uid,meta) if _spawnerPets[uid] then doEquip(_spawnerPets[uid].data); return true,{action="equip",is_server=true} end; return oldGet(name):InvokeServer(uid,meta) end}
        elseif name=="ToolAPI/Unequip" then return {InvokeServer=function(_,uid) if _spawnerPets[uid] then doUnequip(_spawnerPets[uid].data); return true,{action="unequip",is_server=true} end; return oldGet(name):InvokeServer(uid) end}
        elseif name=="AdoptAPI/RidePet" then return {InvokeServer=function(_,pd) if _spawnerPets[pd.pet_unique] then mount(pd.pet_unique,"PlayerRidingPet","PetBeingRidden"); return true end; return oldGet(name):InvokeServer(pd) end}
        elseif name=="AdoptAPI/FlyPet" then return {InvokeServer=function(_,pd) if _spawnerPets[pd.pet_unique] then mount(pd.pet_unique,"PlayerFlyingPet","PetBeingFlown"); return true end; return oldGet(name):InvokeServer(pd) end}
        elseif name=="AdoptAPI/ExitSeatStates" then return {FireServer=function() if _currentRideId then dismount(); return true end; return oldGet(name):FireServer() end}
        elseif name=="SettingsAPI/SetPetRoleplayName" then return {InvokeServer=function(_, petUniqueId, newName)
            -- Only intercept spawned pets; real pets go to server
            if not _spawnerPets[petUniqueId] then
                return oldGet(name):InvokeServer(petUniqueId, newName)
            end
            -- Update wrapper rp_name so nametag re-renders
            updateData("pet_char_wrappers", function(wrappers)
                for i, w in pairs(wrappers) do
                    if w.pet_unique == petUniqueId then
                        local cw = table.clone(w)
                        cw.rp_name = newName
                        wrappers[i] = cw
                        break
                    end
                end
                return wrappers
            end)
            updateData("inventory", function(inv)
                if inv.pets and inv.pets[petUniqueId] then
                    inv.pets[petUniqueId].properties.rp_name = newName
                end
                return inv
            end)
            -- Update our local cache
            if _spawnerPets[petUniqueId] and _spawnerPets[petUniqueId].data then
                _spawnerPets[petUniqueId].data.properties.rp_name = newName
            end
            return true
        end}
        end; return oldGet(name)
    end
end

-- _spinnerCreate: called by the Spin tab claim flow to add a pet to inventory
_G._spinnerCreate = function(id, props)
    local uid = HttpService:GenerateGUID(false)
    local item = KindDB and KindDB[id]
    if not item then return nil end
    local newPet = {
        unique = uid, category = "pets", id = id,
        kind = item.kind or id, newness_order = math.random(1, 900000),
        properties = props or {},
    }
    local inv = ClientData.get("inventory")
    if inv and inv.pets then
        inv.pets[uid] = newPet
        _spawnerPets[uid] = {data = newPet, model = nil}
        pcall(function() UIManager.apps.BackpackApp:refresh_rendered_items() end)
    end
    return newPet
end

end -- FAKE PET SPAWNER do block

-- _addToInventory/_removeFromInventory hoisted to file scope so trade completion can call them
-- Exact port of reference script's CreateInventoryItem
local _nextToyOrder = 60000
local function _addToInventory(item)
    local itemId = item.id or item.kind
    local itemKindData = KindDB and KindDB[itemId]
    if not itemKindData then
        warn("[Spawner] KindDB entry not found: " .. tostring(itemId))
        return nil
    end

    local uniqueId = item.unique or HttpService:GenerateGUID(false)
    local properties = item.properties or {}
    local newnessValue

    if properties._newness_order then
        newnessValue = properties._newness_order
        properties._newness_order = nil
    else
        local groupKey = _getPropertyGroup(properties)
        _newnessGroups[groupKey] = _newnessGroups[groupKey] - 1
        newnessValue = _newnessGroups[groupKey]
    end

    if not properties.ailments_completed then
        properties.ailments_completed = 0
    end
    if properties.rp_name == "__no_name__" then
        properties.rp_name = ""
    elseif not properties.rp_name or properties.rp_name == "" then
        properties.rp_name = generatePetName(itemId)
    end

    -- Verify InventoryDB also has this kind (needed by BackpackCategoryButtons + PracticeDogHider)
    local inventoryKindData = InventoryDB and InventoryDB.pets and InventoryDB.pets[itemId]
    if not inventoryKindData then
        -- Try KindDB kind field as fallback
        local kindKey = itemKindData.kind or itemId
        inventoryKindData = InventoryDB and InventoryDB.pets and InventoryDB.pets[kindKey]
        if inventoryKindData then
            itemId = kindKey
        else
            warn("[Spawner] InventoryDB.pets entry not found: " .. tostring(itemId))
            return nil
        end
    end

    local itemData = {
        unique        = uniqueId,
        category      = "pets",
        id            = itemId,
        kind          = itemId,
        newness_order = newnessValue,
        properties    = properties,
    }

    -- Write directly to live inventory (exact reference pattern)
    local identity = (get_thread_identity and get_thread_identity()) or 8
    setthreadidentity(2)
    local inventory = ClientData.get("inventory")
    if inventory and inventory["pets"] then
        inventory["pets"][uniqueId] = itemData
    end
    setthreadidentity(identity)

    _spawnerPets[uniqueId] = { data = itemData, model = nil }

    task.defer(function()
        pcall(function() UIManager.apps.BackpackApp:refresh_rendered_items() end)
    end)

    return itemData
end

-- Cloud-save hook: spawned fake inventory (best-effort — re-runs _addToInventory on load).
_G._saveHooks.inventory = {
    label = "Spawned inventory",
    save = function()
        local list = {}
        for _, entry in pairs(_spawnerPets) do
            local d = entry and entry.data
            if d and (d.id or d.kind) then
                local props = {}
                if type(d.properties) == "table" then
                    for k, v in pairs(d.properties) do
                        local tv = type(v)
                        if (tv == "string" or tv == "number" or tv == "boolean") and tostring(k):sub(1,1) ~= "_" then
                            props[k] = v
                        end
                    end
                end
                table.insert(list, { id = d.id, kind = d.kind, properties = props })
            end
        end
        return list
    end,
    load = function(t)
        if type(t) ~= "table" then return end
        task.spawn(function()
            for _, spec in ipairs(t) do
                pcall(function() _addToInventory({ id = spec.id, kind = spec.kind, properties = spec.properties or {} }) end)
                task.wait()
            end
        end)
    end,
}

local function _removeFromInventory(uid)
    local identity = (get_thread_identity and get_thread_identity()) or 8
    setthreadidentity(2)
    local inventory = ClientData.get("inventory")
    if inventory and inventory.pets then
        inventory.pets[uid] = nil
    end
    setthreadidentity(identity)
    if _spawnerPets[uid] then
        if _spawnerPets[uid].model then _spawnerPets[uid].model:Destroy() end
        _spawnerPets[uid] = nil
    end
    -- Remove from BackpackApp hidden items so BackpackItemHider doesn't hit nil
    pcall(function()
        local ba = UIManager and UIManager.apps and UIManager.apps.BackpackApp
        if ba and ba.hidden_items then
            for tag, tbl in pairs(ba.hidden_items) do
                if type(tbl) == "table" then tbl[uid] = nil end
            end
        end
        if ba and ba.remove_item_unique_hidden then
            ba:remove_item_unique_hidden(uid, "MockTradeApp")
        end
    end)
    removeWrapper(uid)
end

-- The game's search checks rp_name (our random names like "Frost") which causes
task.defer(function()
    local BackpackApp = UIManager.apps.BackpackApp
    if not BackpackApp then return end

    -- Guard check_if_item_hidden against nil items (fake pets removed from inventory
    -- but still referenced in hidden_items table causes BackpackItemHider crash)
    -- Guard check_if_item_hidden against nil
    if BackpackApp.check_if_item_hidden then
        local _origCheckHidden = BackpackApp.check_if_item_hidden
        BackpackApp.check_if_item_hidden = function(self, item_data)
            if not item_data then return false end
            local ok, result = pcall(_origCheckHidden, self, item_data)
            return ok and result or false
        end
    end

    -- Guard _render_category_async so any remaining crashes don't break the backpack
    if BackpackApp._render_category_async then
        local _origRender = BackpackApp._render_category_async
        BackpackApp._render_category_async = function(self, ...)
            local ok, err = pcall(_origRender, self, ...)
            if not ok and not tostring(err):find("event_name") and not tostring(err):find("is_hidden_from_backpack") then
                warn("[BackpackApp] _render_category_async:", err)
            end
        end
    end

    if not BackpackApp.is_filtered_out then return end
    local _origFilteredOut = BackpackApp.is_filtered_out
    BackpackApp.is_filtered_out = function(self, item_data)
        if item_data and item_data.properties and _spawnerPets[item_data.unique] then
            local savedRpName = item_data.properties.rp_name
            -- Temporarily swap rp_name with the real pet species name for search matching
            local realName = IDB and IDB.pets
                and IDB.pets[item_data.id]
                and IDB.pets[item_data.id].name
                or savedRpName
            item_data.properties.rp_name = realName
            local result = _origFilteredOut(self, item_data)
            item_data.properties.rp_name = savedRpName -- restore immediately
            return result
        end
        return _origFilteredOut(self, item_data)
    end
end)

local mockState = {
    active               = false,
    trade                = nil,
    isAddingItem         = false,
    tradeCompleting      = false,
    scamWarningShown     = false,
    blockedTradeRequests = {},
    tradeHistory         = {},
    addedTradeIds        = {},
    originalFunctions    = {},
    spectatorLoop        = nil,   -- coroutine handle for spectator simulation
    spectatorReactionsEnabled = true,
}
_G._mockState = mockState  -- so the Auto-Offer engine can skip our mock showcase trades

-- De-confirm both offers and bump the offer version (revert to negotiation stage).
local function resetTradeNegotiation()
    mockState.trade.sender_offer.negotiated    = false
    mockState.trade.recipient_offer.negotiated = false
    if mockState.trade.current_stage == "confirmation" then
        mockState.trade.current_stage             = "negotiation"
        mockState.trade.sender_offer.confirmed    = false
        mockState.trade.recipient_offer.confirmed = false
    end
    mockState.trade.offer_version = mockState.trade.offer_version + 1
end

local function storeOriginalFunctions()
    local funcs = {
        "_get_local_trade_state",
        "_overwrite_local_trade_state",
        "_change_local_trade_state",
        "_get_my_offer",
        "_get_partner_offer",
        "_get_my_player",
        "_get_partner",
        "_get_current_trade_stage",
        "_on_accept_pressed",
        "_on_confirm_pressed",
        "_on_unaccept_pressed",
        "_decline_trade",
        "_add_item_to_my_offer",
        "_remove_item_from_my_offer",
        "_lock_trade_for_appropriate_time",
        "_get_lock_time",
        "refresh_all",
        "_evaluate_trade_fairness",
        "_show_scam_victim_warning",
        "_show_scam_perpetrator_warning",
    }
    for _, name in ipairs(funcs) do
        if TradeApp[name] then
            mockState.originalFunctions[name] = TradeApp[name]
        end
    end
end
storeOriginalFunctions()

local stopSpectatorAndReactionLoops  -- hoisted so it's visible outside this do block
local startSpectatorLoop             -- hoisted so it's visible outside this do block
do

-- Cached references grabbed from _initialize_spectate's upvalues
-- u467 = ReactionFrame, u468 = ReactionTemplate (detached), u41 = reaction asset IDs
local _reactionFrame    = nil
local _reactionTemplate = nil

-- Hook _initialize_spectate so we capture the exact template and frame
-- that the real game uses — same upvalues as u483 in TradeApp source
local _origInitSpectate = TradeApp._initialize_spectate
TradeApp._initialize_spectate = function(self, ...)
    local result = _origInitSpectate(self, ...)
    safeCall(function()
        _reactionFrame    = self.spectate_frame:FindFirstChild("ReactionFrame")
        -- Template was detached (Parent = nil) by _initialize_spectate
        if _reactionFrame then
            -- Try to find it still parented (race condition window)
            _reactionTemplate = _reactionFrame:FindFirstChild("ReactionTemplate")
            if not _reactionTemplate then
                -- Reconstruct matching the real ReactionTemplate exactly
                _reactionTemplate                        = Instance.new("ImageLabel")
                _reactionTemplate.Name                   = "ReactionTemplate"; _reactionTemplate.BackgroundTransparency = 1
                _reactionTemplate.ImageTransparency      = 1; _reactionTemplate.Size                   = UDim2.fromScale(0, 0)
                _reactionTemplate.Position               = UDim2.fromScale(0, 0); _reactionTemplate.AnchorPoint            = Vector2.new(0.5, 0.5)
                _reactionTemplate.ZIndex                 = 5
            end
        end
    end)
    return result
end

local _Spring  = load('Spring')
local _Promise = load('package:Promise')

-- The real template size from the actual GUI asset.
local REACTION_SIZE = UDim2.fromOffset(48, 48)

local function _spawnReaction(imageId)
    -- Use the captured frame from _initialize_spectate, same as u467/u468 in source
    local rf = _reactionFrame
    local tmpl = _reactionTemplate

    -- Fallback: search GUI tree (covers case where trade opened before hook fired)
    if not rf and TradeApp.spectate_frame then
        rf = TradeApp.spectate_frame:FindFirstChild("ReactionFrame")
    end
    if not rf then
        local tradeGui = Players.LocalPlayer.PlayerGui:FindFirstChild("TradeApp")
        if tradeGui then
            for _, desc in ipairs(tradeGui:GetDescendants()) do
                if desc.Name == "ReactionFrame" and desc:IsA("Frame") then
                    rf = desc
                    break
                end
            end
        end
    end
    if not rf then return end

    -- Clone from template exactly like u483 does
    local emoji
    if tmpl then
        emoji = tmpl:Clone()
    else
        emoji = Instance.new("ImageLabel")
        emoji.BackgroundTransparency = 1
        emoji.AnchorPoint            = Vector2.new(0.5, 0.5)
    end

    -- Set up exactly as u483 does in the source
    emoji.Image             = imageId; emoji.Parent            = rf           -- parent FIRST like u483 does
    emoji.ImageTransparency = 1; emoji.Size              = UDim2.fromScale(0, 0)  -- start at 0 size, tween to real size

    -- Tween in — matches u16.new(u470, TweenInfo.new(0.4, Sine, In), {ImageTransparency=0, Size=u468.Size})
    TweenService:Create(emoji, TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.In), { ImageTransparency = 0, Size              = REACTION_SIZE, }):Play()

    local rng       = Random.new()
    local totalDur  = rng:NextNumber(2, 3.5)
    local vertSpeed = rng:NextNumber(0.23, 0.29)
    local fadeStart = totalDur * rng:NextNumber(0.65, 0.8)
    local damping   = rng:NextNumber(0.35, 0.45)
    local frequency = rng:NextNumber(1.1, 1.25)
    local xGoal     = rng:NextNumber(0.1, 0.9)

    -- Spring starts at -0.5 (off-screen left) exactly like u477 in source
    -- this is what creates the "drizzy" sideways drift entry effect
    local spring = _Spring.new(damping, frequency, -0.5)
    spring:set_goal(xGoal)

    -- Position starts at bottom of ReactionFrame — emoji floats upward
    emoji.Position = UDim2.fromScale(-0.5, 1.0)

    local startTick = tick()
    local active    = {}

    local promise = _Promise.fromEvent(RunService.Heartbeat, function(dt)
        local elapsed = tick() - startTick
        if totalDur <= elapsed then return true end
        spring:update(dt)
        -- Exactly matches u470.Position = UDim2.fromScale(v482, v481) in source
        local newY = emoji.Position.Y.Scale - vertSpeed * dt
        local newX = spring:get_position()
        emoji.Position = UDim2.fromScale(newX, newY)
        if fadeStart <= elapsed then
            emoji.ImageTransparency = (elapsed - fadeStart) / (totalDur - fadeStart)
        end
        return false
    end)

    promise:finally(function()
        if emoji and emoji.Parent then emoji:Destroy() end
    end)
end

do
    -- Reactions now come from CloudValues, same as TradeApp uses
    local _reactions = nil
    pcall(function()
        local CloudValues = require(game.ReplicatedStorage.ClientModules.CloudValues)
        local r = CloudValues:getValue("player_chat", "trade_spectate_reactions")
        if type(r) == "table" and #r > 0 then _reactions = r end
    end)
    if not _reactions then
        _reactions = { "rbxassetid://14265113844", "rbxassetid://14265113687", "rbxassetid://14263448076", "rbxassetid://14265134988", "rbxassetid://14265113338", "rbxassetid://14265113443", "rbxassetid://14265113556", }
    end
    _G.EmojiSystem = {
        reactions = _reactions,
        _active   = {}
    }
end

_G.EmojiSystem.display = function(index)
    local r = _G.EmojiSystem.reactions
    if not r or not r[index] then return end
    if not mockState.active or not mockState.trade or not mockState.spectatorReactionsEnabled then return end
    if not mockState.trade.subscriber_count or mockState.trade.subscriber_count < 1 then return end
    pcall(_spawnReaction, r[index])
end

task.spawn(function()
    while true do
        task.wait(1 / CONFIG.REACTIONS_PER_SECOND)
        local r = _G.EmojiSystem and _G.EmojiSystem.reactions
        if r and #r > 0 and mockState.active and mockState.trade
            and mockState.spectatorReactionsEnabled
            and mockState.trade.subscriber_count and mockState.trade.subscriber_count > 0 then
            _G.EmojiSystem.display(math.random(1, #r))
        end
    end
end)
-- Always ramps 1, 2, 3 first (or 1, 2 if target < 3).
local _spectatorLoopId = 0  -- incremented each time loop starts, old loops self-invalidate

startSpectatorLoop = function()
    _spectatorLoopId = _spectatorLoopId + 1
    local myId = _spectatorLoopId
    mockState.spectatorLoop = true

    task.spawn(function()
        local current = 0

        local function applyCount()
            if myId ~= _spectatorLoopId then return end  -- stale loop, discard
            if mockState.trade then
                mockState.trade.subscriber_count = current
                pcall(function() TradeApp:_overwrite_local_trade_state(mockState.trade) end)
                pcall(function() TradeApp:refresh_all() end)
                pcall(function()
                    if TradeApp.spectate_frame then
                        TradeApp.spectate_frame.Visible = current > 0
                        if current > 0 then
                            TradeApp:_update_spectator_count(mockState.trade)
                        end
                    end
                end)
            end
        end

        while myId == _spectatorLoopId and mockState.spectatorLoop and mockState.active do
            local target = CONFIG.SPECTATOR_COUNT

            if target <= 0 then
                if current > 0 then
                    current = 0
                    applyCount()
                end
                task.wait(2)
                continue
            end

            task.wait(math.random(3, 7))
            if myId ~= _spectatorLoopId or not mockState.spectatorLoop or not mockState.active then break end
            target = CONFIG.SPECTATOR_COUNT

            local driftFloor = math.max(1, target - math.floor(target * 0.4))

            if current < math.min(3, target) then
                current = current + 1
            elseif current < target then
                local choices = {-1, 1, 1, 1}
                current = math.clamp(current + choices[math.random(1, #choices)], driftFloor, target)
            else
                local choices = {-2, -1, -1, 1, 1}
                local next = current + choices[math.random(1, #choices)]
                if next > target then next = current - 1 end
                current = math.clamp(next, driftFloor, target)
            end

            applyCount()
        end
    end)
end

stopSpectatorAndReactionLoops = function()
    mockState.spectatorLoop = false
end

end -- SPECTATOR SIMULATION do block

local mockPartner

local function createMockPartner()
    return setmetatable({ Name        = CONFIG.PARTNER_NAME, DisplayName = CONFIG.PARTNER_NAME, UserId      = CONFIG.PARTNER_USER_ID or 0, }, {
        __index = function(_, k)
            if k == "Parent" then return Players end
            if k == "IsA" then return function(_, cls) return cls == "Player" end end
        end,
        __tostring = function() return CONFIG.PARTNER_NAME end,
    })
end

local function createMockTrade()
    return {
        trade_id                    = "MOCK_" .. tick(),
        sender                      = Players.LocalPlayer,
        recipient                   = mockPartner,
        sender_offer                = {
            items       = {},
            player_name = Players.LocalPlayer.Name,
            negotiated  = false,
            confirmed   = false,
        },
        recipient_offer             = {
            items       = {},
            player_name = CONFIG.PARTNER_NAME,
            negotiated  = false,
            confirmed   = false,
        },
        current_stage               = "negotiation",
        offer_version               = 1,
        sender_has_trade_license    = true,
        recipient_has_trade_license = true,
        busy_indicators             = {},
        subscriber_count            = 0,  -- spectator loop ramps from 0
    }
end

-- GROUP RANK BADGE HOOK
local _cachedPartnerRank = 0

task.spawn(function()
    local ok, GroupRankHelper = pcall(load, "GroupRankHelper")
    if not ok or not GroupRankHelper then return end

    -- Keep get_rank_from_player hook as fallback
    local _origGetRankFromPlayer = GroupRankHelper.get_rank_from_player
    GroupRankHelper.get_rank_from_player = function(player, groupId)
        if mockState.active and mockState.trade then
            return _cachedPartnerRank
        end
        return _origGetRankFromPlayer(player, groupId)
    end
end)

-- Hook ClientData.get_server so promise_get_verified_status returns the right tag
do
    local _origGetServer = ClientData.get_server
    ClientData.get_server = function(player, key, ...)
        -- Self badge: inject in ALL contexts (trades, nametag, profile, everywhere)
        if key == "player_tags" and CONFIG.SELF_BADGE_TAG and CONFIG.SELF_BADGE_TAG ~= "" then
            local reqId = player and (type(player) == "table" and player.UserId or
                          (type(player) == "userdata" and player.UserId))
            if reqId and reqId == Players.LocalPlayer.UserId then
                return { CONFIG.SELF_BADGE_TAG }
            end
        end
        -- player_tags: return tag for mock partner
        if key == "player_tags" and mockState.active and mockState.trade then
            local partnerId = player and (type(player) == "table" and player.UserId or
                              (type(player) == "userdata" and player.UserId))
            -- PARTNER_TAG: inject for any queried player during mock trade
            -- (covers the case where PARTNER_USER_ID isn't resolved yet)
            if CONFIG.PARTNER_TAG and CONFIG.PARTNER_TAG ~= "" and partnerId then
                return { CONFIG.PARTNER_TAG }
            end
            if partnerId and partnerId == CONFIG.PARTNER_USER_ID and CONFIG.PARTNER_USER_ID ~= 0 then
                -- Fall back to cached rank from GroupRankHelper
                local GRH = pcall(load, "GroupRankHelper") and load("GroupRankHelper")
                if GRH and _cachedPartnerRank and _cachedPartnerRank > 0 then
                    local tagOk, tag = pcall(function() return GRH.get_tag_from_rank(_cachedPartnerRank) end)
                    if tagOk and tag then
                        local iconOk, icon = pcall(function() return GRH.get_icon_from_tag(tag) end)
                        if iconOk and icon then
                            return { tag }
                        end
                    end
                end
                return {}
            end
        end

        -- in_active_trade: tell PlayerProfileApp our mock partner is in a trade with us
        -- so it shows "Suggest" button instead of "Trade" on their profile
        if key == "in_active_trade" and mockState.active and mockState.trade then
            local partnerId = player and (type(player) == "table" and player.UserId or
                              (type(player) == "userdata" and player.UserId))
            if partnerId and partnerId == CONFIG.PARTNER_USER_ID then
                return true
            end
        end

        return _origGetServer(player, key, ...)
    end
end

-- _chatIntroShown declared here so it's visible to both hookTradeFunctions and the render hook
local _chatIntroShown = false
-- Per-trade intro dedup state lives on _G (avoids adding main-chunk locals; see render hook below)
_G._introSeen = _G._introSeen or {}

-- HOOK TRADEAPP FUNCTIONS
local function notifyProfileAppTradeState(active)
    safeCall(function()
        local ProfileApp = UIManager.apps.PlayerProfileApp
        if not ProfileApp then return end
        if not (ProfileApp.player_profile and ProfileApp.player) then return end
        if ProfileApp.player.UserId ~= CONFIG.PARTNER_USER_ID then return end
        local inTradeWithMe = false
        if active then
            safeCall(function()
                inTradeWithMe = TradeApp:_get_partner() ~= nil
            end)
        end
        ProfileApp:set_header_info({ in_trade         = active, in_trade_with_me = inTradeWithMe, })
    end)
end

local function hookTradeFunctions()
task.spawn(function()
    task.wait(0.1)
    local PlayerText = load('new:PlayerText')
    if not PlayerText then return end
    local original_can_i_chat = PlayerText.can_i_chat_with_player
    local original_can_use_emojis = PlayerText.can_player_use_emojis
    PlayerText.can_i_chat_with_player = function(player, ...)
        if mockState.active then return true end
        return original_can_i_chat(player, ...)
    end
    PlayerText.can_player_use_emojis = function(...)
        if mockState.active then return true end
        return original_can_use_emojis(...)
    end
end)

    TradeApp._get_local_trade_state = function(self)
        if mockState.active and mockState.trade then
            return TableUtil.deep_copy(mockState.trade)
        end
        return mockState.originalFunctions._get_local_trade_state(self)
    end

    TradeApp._overwrite_local_trade_state = function(self, newState)
        if mockState.active then
            if newState then
                -- Capture old state BEFORE overwriting so _on_local_trade_state_changed
                local oldState = self.local_trade_state
                mockState.trade              = newState
                self.local_trade_state       = newState
                mockState.trade.subscriber_count = mockState.trade.subscriber_count or 0
                if self._on_local_trade_state_changed then
                    self:_on_local_trade_state_changed(newState, newState)
                end
                if self.refresh_all then self:refresh_all() end
            else
                mockState.trade  = nil; mockState.active = false
                mockState.scamWarningShown = false
                self.local_trade_state = nil
                lastAddedHighTier = nil
                _chatIntroShown = false
                stopSpectatorAndReactionLoops()
                _stopAutoChatLoop()
                notifyProfileAppTradeState(false)
                -- Sync CONFIG from textbox in case user changed name during trade
                task.defer(function()
                    if partnerBox and partnerBox.Text ~= "" then
                        updatePartnerFromUsername(partnerBox.Text)
                    end
                end)
            end
        else
            return mockState.originalFunctions._overwrite_local_trade_state(self, newState)
        end
    end

    TradeApp._get_my_offer = function(self)
        local state = self:_get_local_trade_state()
        if mockState.active and state then
            if Players.LocalPlayer == state.sender then
                return state.sender_offer, "sender_offer"
            else
                return state.recipient_offer, "recipient_offer"
            end
        end
        return mockState.originalFunctions._get_my_offer(self)
    end

    TradeApp._get_partner_offer = function(self)
        local state = self:_get_local_trade_state()
        if mockState.active and state then
            if Players.LocalPlayer == state.sender then
                return state.recipient_offer, "recipient_offer"
            else
                return state.sender_offer, "sender_offer"
            end
        end
        return mockState.originalFunctions._get_partner_offer(self)
    end

    TradeApp._get_my_player = function(self)
        if mockState.active and mockState.trade then
            return Players.LocalPlayer
        end
        return mockState.originalFunctions._get_my_player(self)
    end

    TradeApp._get_partner = function(self)
        if mockState.active and mockState.trade then
            return mockPartner
        end
        return mockState.originalFunctions._get_partner(self)
    end

    TradeApp._get_current_trade_stage = function(self)
        if mockState.active and mockState.trade then
            return mockState.trade.current_stage
        end
        return mockState.originalFunctions._get_current_trade_stage(self)
    end

    local function recursiveMerge(target, source)
        for k, v in pairs(source) do
            if type(v) == "table" and type(target[k]) == "table" then
                recursiveMerge(target[k], v)
            else
                target[k] = v
            end
        end
        return target
    end

    TradeApp._change_local_trade_state = function(self, changes, useReplace)
        if mockState.active then
            local current = self:_get_local_trade_state()
            local merged  = useReplace and changes or recursiveMerge(current, changes)
            self:_overwrite_local_trade_state(merged)
        else
            return mockState.originalFunctions._change_local_trade_state(self, changes, useReplace)
        end
    end

    TradeApp._get_lock_time = function(self)
        if mockState.active and mockState.trade then
            if self:_get_current_trade_stage() == "negotiation" then
                return CONFIG.NEGOTIATION_LOCK or 5
            end
            local count = #mockState.trade.sender_offer.items + #mockState.trade.recipient_offer.items
            return math.clamp((CONFIG.CONFIRMATION_LOCK_PER_ITEM or 3) * count, 5, 15)
        end
        return mockState.originalFunctions._get_lock_time(self)
    end

    TradeApp._lock_trade_for_appropriate_time = function(self)
        if mockState.active then
            if self.lock_countdown then
                self.lock_countdown:stop()
                self.lock_countdown:set_duration(self:_get_lock_time())
                self.lock_countdown:start()
            end
        else
            return mockState.originalFunctions._lock_trade_for_appropriate_time(self)
        end
    end

    TradeApp._on_accept_pressed = function(self)
        if mockState.active and mockState.trade then
            local _, key = self:_get_my_offer()

            mockState.trade[key].negotiated = true
            mockState.trade.offer_version = (mockState.trade.offer_version or 1) + 1
            TradeApp:_overwrite_local_trade_state(mockState.trade)
            self:refresh_all()

            -- Partner accepts after delay, then enter confirmation
            task.delay(CONFIG.AUTO_ACCEPT_DELAY, function()
                if not mockState.active or not mockState.trade then return end
                local partnerKey = (key == "sender_offer") and "recipient_offer" or "sender_offer"
                mockState.trade[partnerKey].negotiated = true
                mockState.trade.offer_version = (mockState.trade.offer_version or 1) + 1

                if mockState.trade.sender_offer.negotiated and mockState.trade.recipient_offer.negotiated then
                    mockState.trade.current_stage = "confirmation"
                    TradeApp:_overwrite_local_trade_state(mockState.trade)
                    if TradeApp.refresh_all then TradeApp:refresh_all() end

                    -- Fire fairness check and countdown directly — do not rely on
                    pcall(function() TradeApp:_evaluate_trade_fairness() end)
                    if TradeApp.lock_countdown then
                        TradeApp.lock_countdown:stop()
                        TradeApp.lock_countdown:set_duration(TradeApp:_get_lock_time())
                        TradeApp.lock_countdown:start()
                    end
                else
                    TradeApp:_overwrite_local_trade_state(mockState.trade)
                    if TradeApp.refresh_all then TradeApp:refresh_all() end
                end
            end)
        else
            return mockState.originalFunctions._on_accept_pressed(self)
        end
    end

    TradeApp._on_unaccept_pressed = function(self) --PLACEHOLDER
        if mockState.active and mockState.trade then
            local _, key = self:_get_my_offer()
            self:_change_local_trade_state({ [key] = { negotiated = false } })
            self:refresh_all()
        else
            return mockState.originalFunctions._on_unaccept_pressed(self)
        end
    end

    TradeApp._on_confirm_pressed = function(self)
        if mockState.active and mockState.trade then
            local _, key = self:_get_my_offer()
            mockState.trade[key].confirmed = true
            mockState.trade.offer_version = (mockState.trade.offer_version or 1) + 1
            TradeApp:_overwrite_local_trade_state(mockState.trade)
            self:refresh_all()

            task.delay(CONFIG.AUTO_CONFIRM_DELAY, function()
                if not mockState.active or not mockState.trade then return end
                local partnerKey = (key == "sender_offer") and "recipient_offer" or "sender_offer"
                mockState.trade[partnerKey].confirmed = true
                mockState.trade.offer_version = (mockState.trade.offer_version or 1) + 1
                TradeApp:_overwrite_local_trade_state(mockState.trade)
                if TradeApp.refresh_all then TradeApp:refresh_all() end

                -- Both confirmed — spin the arrow exactly like the real game does
                -- (TradeApp source: refresh_all detects both confirmed and calls
                pcall(function() TradeApp:_set_confirmation_arrow_rotating(true) end)

                -- Real game processes on server for ~3s before closing
                -- Mirror that delay so it feels identical
                task.wait(3)
                if not mockState.active then return end

                -- Capture offers BEFORE clearing trade state
                local myOffer      = mockState.trade.sender_offer
                local partnerOffer = mockState.trade.recipient_offer
                if mockState.trade.recipient == Players.LocalPlayer then
                    myOffer, partnerOffer = partnerOffer, myOffer
                end

                -- Stop arrow, close trade, show success hint
                pcall(function() TradeApp:_set_confirmation_arrow_rotating(false) end)
                stopSpectatorAndReactionLoops()
                mockState.active = false
                mockState.trade  = nil
                TradeApp.local_trade_state = nil
                UIManager.set_app_visibility("TradeApp", false)
                -- Sync CONFIG from textbox in case user changed name during trade
                task.defer(function()
                    if partnerBox and partnerBox.Text ~= "" then
                        updatePartnerFromUsername(partnerBox.Text)
                    end
                end)

                -- Apply trade results to inventory:
                -- Remove items we gave away, add items we received

                -- Remove our sent items from inventory (only if toggle is ON)
                if CONFIG.REMOVE_SENT_PETS and myOffer then
                    for _, item in ipairs(myOffer.items or {}) do
                        safeCall(function()
                            updateData("inventory", function(inv)
                                if inv.pets then inv.pets[item.unique] = nil end
                                return inv
                            end)
                        end)
                    end
                end

                -- Add partner's items to our inventory (only if toggle is ON)
                if CONFIG.RECEIVE_PETS and partnerOffer then
                    for _, item in ipairs(partnerOffer.items or {}) do
                        local ok, err = pcall(function()
                            local newItem = {
                                unique     = HttpService:GenerateGUID(false),
                                category   = "pets",
                                kind       = item.kind,
                                id         = item.kind,
                                newness_order = math.random(1, 900000),
                                properties = { neon               = item.properties and item.properties.neon      or false, mega_neon          = item.properties and item.properties.mega_neon or false, flyable            = item.properties and item.properties.flyable   or false, rideable           = item.properties and item.properties.rideable  or false, age                = item.properties and item.properties.age       or 1, ailments_completed = 0, pet_trick_level    = 0, rp_name            = generatePetName(item.kind), },
                            }
                            _addToInventory(newItem)
                        end)
                    end
                end

                pcall(function() UIManager.apps.BackpackApp:refresh_rendered_items() end)

                -- Record this mock trade in history so it appears in Trade History
                safeCall(function()
                    local LocalPlayer = Players.LocalPlayer
                    local record = {
                        trade_id        = "MOCK_" .. HttpService:GenerateGUID(false),
                        timestamp       = os.time(),
                        sender_user_id  = LocalPlayer.UserId,
                        sender_name     = LocalPlayer.Name,
                        recipient_user_id = CONFIG.PARTNER_USER_ID,
                        recipient_name  = CONFIG.PARTNER_NAME,
                        sender_items    = myOffer   and myOffer.items   or {},
                        recipient_items = partnerOffer and partnerOffer.items or {},
                        reported        = false,
                        reverted        = nil,
                    }
                    -- Check for duplicate (same trade_id)
                    local isDupe = false
                    for _, existing in ipairs(_mockTradeHistory) do
                        if existing.trade_id == record.trade_id then isDupe = true; break end
                    end
                    if not isDupe then
                        table.insert(_mockTradeHistory, 1, record)
                        -- Bust the real cached history so it refetches from server on next open
                        if TradeHistoryApp then
                            TradeHistoryApp.cached_trade_history = nil
                        end
                    end
                end)

                -- Store AMVgg value for auto spin using already-cached value display calc
                do
                    local val = _G._lastPartnerAmvgg or 0
                    if val > 0 then
                        local spins = math.floor(val / 0.1 + 0.5)
                        if _G._maxSpinsEnabled then
                            spins = math.min(spins, _G._maxSpinsValue)
                        end
                        if spins > 0 then
                            _G._autoSpinPending = (_G._autoSpinPending or 0) + spins
                            _G._autoSpinTriggered = false
                            _G._autoSpinWaitingForTrade = true
                            -- remember how many pets partner gave so we wait for all of them
                            _G._autoSpinRequiredPets = partnerOffer and #partnerOffer.items or 1
                        end
                    end
                end

                -- "The trade was successful!" hint shown by real game after completion
                local HintApp = UIManager.apps.HintApp
                if HintApp then
                    HintApp:hint({ text       = "The trade was successful!", length     = 5, overridable = true, yields     = false, })
                end
            end)
        else
            return mockState.originalFunctions._on_confirm_pressed(self)
        end
    end

    TradeApp._add_item_to_my_offer = function(self)
        if mockState.active and mockState.trade then
            if mockState.isAddingItem then return end
            mockState.isAddingItem = true
            if not TradeApp.can_suggest_removal_items then
                TradeApp.can_suggest_removal_items = {}
            end
            local pickedItem = BackpackApp:pick_item({
                keep_cached_scroll_positions_on_open = true,
                allow_callback = function() return true end,
            })
            if pickedItem then
                -- Locked pets can't be traded — mirror the game's locked-pet dialog and bail
                -- (the real _add_item_to_my_offer blocks this; our mock version has to too).
                local isLocked = false
                pcall(function()
                    if _G._mockLockTracker == nil then
                        local ok, m = pcall(load, "BackpackLockTracker")
                        _G._mockLockTracker = (ok and m) or false
                    end
                    local lt = _G._mockLockTracker
                    if lt and lt.is_locked then isLocked = lt.is_locked(pickedItem) and true or false end
                end)
                if not isLocked then
                    isLocked = (pickedItem.locked == true)
                        or (pickedItem.properties and pickedItem.properties.locked == true) or false
                end
                if isLocked then
                    mockState.isAddingItem = false
                    pcall(function()
                        UIManager.apps.DialogApp:dialog({
                            text  = "You can't trade that item!",
                            right = "Okay",
                        })
                    end)
                    return
                end
                local already = false
                for _, item in ipairs(mockState.trade.sender_offer.items) do
                    if item.unique == pickedItem.unique then already = true; break end
                end
                if not already and #mockState.trade.sender_offer.items < 18 then
                    table.insert(mockState.trade.sender_offer.items, pickedItem)
                    resetTradeNegotiation()
                    TradeApp.can_suggest_removal_items[pickedItem.unique] = pickedItem
                    self:_overwrite_local_trade_state(mockState.trade)
                    self:_lock_trade_for_appropriate_time()
                    if BackpackApp.set_item_unique_hidden then
                        BackpackApp:set_item_unique_hidden(pickedItem.unique, self.ClassName)
                    end
                    mockState.scamWarningShown = false
                end
            end
            mockState.isAddingItem = false
        else
            return mockState.originalFunctions._add_item_to_my_offer(self)
        end
    end

    TradeApp._remove_item_from_my_offer = function(self, item)
        if mockState.active and mockState.trade then
            local items = mockState.trade.sender_offer.items
            for i, v in ipairs(items) do
                if v.unique == item.unique then
                    table.remove(items, i); break
                end
            end
            resetTradeNegotiation()
            self:_overwrite_local_trade_state(mockState.trade)
            self:_lock_trade_for_appropriate_time()
            if BackpackApp.reset_hidden_item_tag then
                BackpackApp:reset_hidden_item_tag(self.ClassName)
            end
            if TradeApp.can_suggest_removal_items then
                TradeApp.can_suggest_removal_items[item.unique] = nil
            end
        else
            return mockState.originalFunctions._remove_item_from_my_offer(self, item)
        end
    end

    -- Allow fairness evaluation and scam warnings during mock trades
    TradeApp._evaluate_trade_fairness = function(self)
        if mockState.scamWarningShown then return end
        return mockState.originalFunctions._evaluate_trade_fairness(self)
    end

    TradeApp._show_scam_victim_warning = function(self)
        if mockState.scamWarningShown then return end
        mockState.scamWarningShown = true
        return mockState.originalFunctions._show_scam_victim_warning(self)
    end

    TradeApp._show_scam_perpetrator_warning = function(self)
        if mockState.scamWarningShown then return end
        mockState.scamWarningShown = true
        return mockState.originalFunctions._show_scam_perpetrator_warning(self)
    end

    -- Keep spectate_frame visible when we have fake spectators
    -- _toggle_spectate(false) is called for non-spectators and hides it
    local _origToggleSpectate = TradeApp._toggle_spectate
    if _origToggleSpectate then
        TradeApp._toggle_spectate = function(self, spectating, ...)
            _origToggleSpectate(self, spectating, ...)
            if not spectating and mockState.active and mockState.trade
                and (mockState.trade.subscriber_count or 0) > 0 then
                if self.spectate_frame then
                    self.spectate_frame.Visible = true
                end
            end
        end
    end

    TradeApp._decline_trade = function(self, skipFireServer)
        if mockState.active then
            stopSpectatorAndReactionLoops()
            mockState.active           = false; mockState.trade            = nil
            mockState.scamWarningShown = false
            self.local_trade_state     = nil
            lastAddedHighTier          = nil
            _chatIntroShown            = false
            if self.lock_countdown then self.lock_countdown:stop() end
            UIManager.set_app_visibility("TradeApp", false)
            pcall(notifyProfileAppTradeState, false)
        else
            return mockState.originalFunctions._decline_trade(self, skipFireServer)
        end
    end
end

hookTradeFunctions()

-- Fix: intro fires exactly once per trade (old==new trick prevents game's own
-- _clear_chat + _show_intro_message from firing on every state update)
do
    local _startupShownForTrade = nil
    local _origShowIntro = TradeApp._show_intro_message
    if _origShowIntro then
        TradeApp._show_intro_message = function(self, ...)
            local result = _origShowIntro(self, ...)
            local state = self:_get_local_trade_state()
            local tid = state and state.trade_id
            if tid and _startupShownForTrade ~= tid then
                _startupShownForTrade = tid
            end
            return result
        end
    end
end

-- Block trade partner keybind (B key while in a mock or real trade)
do
    local _blockBindActive = true
    local UIS = game:GetService("UserInputService")
    _G._blockKey = _G._blockKey or "J"   -- configurable; the Mo-layout button sets this to "B"
    UIS.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode.Name ~= (_G._blockKey or "J") then return end
        if not _blockBindActive then return end

        -- Get partner from mock trade or real trade state
        local target = nil
        pcall(function()
            if mockState.active and mockState.trade then
                -- Mock trade: use PARTNER_USER_ID to find real Player
                local partnerId = CONFIG.PARTNER_USER_ID
                if partnerId and partnerId ~= 0 then
                    target = Players:GetPlayerByUserId(partnerId)
                end
                if not target then
                    local partnerName = CONFIG.PARTNER_NAME
                    if partnerName and partnerName ~= "" then
                        target = Players:FindFirstChild(partnerName)
                    end
                end
            else
                -- Real trade: read active trade state
                local ts = ClientData.get("trade")
                if ts then
                    -- sender/recipient are Player objects
                    local partner
                    if ts.sender == Players.LocalPlayer then
                        partner = ts.recipient
                    else
                        partner = ts.sender
                    end
                    if partner and partner ~= Players.LocalPlayer then
                        target = partner
                    end
                end
            end
        end)

        if not target then return end

        -- Brief cooldown so holding B doesn't spam
        _blockBindActive = false
        task.delay(2, function() _blockBindActive = true end)

        -- silentBlockPlayer lives in Misc tab scope, accessed via _G
        local fn = _G._silentBlockPlayer
        if fn then
            task.spawn(fn, target)
        end
    end)
end

-- Force the admin nametag to show immediately on execution.
task.spawn(function()
    task.wait(0.5)
    -- Nudge char_wrappers so CharWrapperClient re-queries player_tags for all players
    pcall(function()
        local identity = get_thread_identity and get_thread_identity() or 8
        setthreadidentity(2)
        local wrappers = ClientData.get("char_wrappers") or {}
        local nudged = {}
        for i, w in ipairs(wrappers) do
            nudged[i] = table.clone(w)
        end
        ClientData.predict("char_wrappers", nudged)
        setthreadidentity(identity)
    end)
    -- Also nudge pet_char_wrappers for pet nametags
    pcall(function()
        local identity = get_thread_identity and get_thread_identity() or 8
        setthreadidentity(2)
        local wrappers = ClientData.get("pet_char_wrappers") or {}
        local nudged = {}
        for i, w in ipairs(wrappers) do
            nudged[i] = table.clone(w)
        end
        ClientData.predict("pet_char_wrappers", nudged)
        setthreadidentity(identity)
    end)
    task.wait(0.1)
    -- Trigger AilmentsClient refresh which also causes nametag re-render
    pcall(function()
        local AC = load("new:AilmentsClient")
        if AC and AC.on_ailments_changed then
            AC.on_ailments_changed(Players.LocalPlayer)
        end
    end)
end)

-- VERIFIED FRIEND HOOK
local CONFIG_VERIFIED_FRIEND = true

do
    local FriendsClient = load("FriendsClient")
    if FriendsClient and FriendsClient.promise_get_is_friends_with then
        local _origIsFriends = FriendsClient.promise_get_is_friends_with
        FriendsClient.promise_get_is_friends_with = function(userId, ...)
            if CONFIG_VERIFIED_FRIEND and mockState.active then
                -- Return true for the partner regardless of whether UserId is resolved yet.
                if userId == CONFIG.PARTNER_USER_ID
                    or CONFIG.PARTNER_USER_ID == 0 then
                    local Promise = load("package:Promise")
                    return Promise.resolve(true)
                end
            end
            return _origIsFriends(userId, ...)
        end
    end
end

-- AUTO-DECLINE INCOMING TRADE REQUESTS DURING MOCK TRADE
task.spawn(function()
    task.wait(2) -- wait for TradeApp to finish initialising its connections
    local RouterClient = load("RouterClient")
    local remote = RouterClient.get_event("TradeAPI/TradeRequestReceived")
    if not remote then return end

    local ok, connections = pcall(getconnections, remote.OnClientEvent)
    if not ok or not connections then return end

    -- Add our handler BEFORE the original ones fire
    remote.OnClientEvent:Connect(function(requestingPlayer)
        if mockState.active then
            -- Disable originals so they don't also show a dialog
            for _, c in ipairs(connections) do
                pcall(function() c:Disable() end)
            end
            safeCall(function()
                RouterClient.get("TradeAPI/AcceptOrDeclineTradeRequest"):InvokeServer(requestingPlayer, false)
            end)
        end
        -- When not active, do nothing — originals handle it normally
    end)

    -- Re-enable originals whenever mock trade ends
    local _origDecline = TradeApp._decline_trade
    TradeApp._decline_trade = function(self, ...)
        for _, c in ipairs(connections) do
            pcall(function() c:Enable() end)
        end
        return _origDecline(self, ...)
    end
end)

-- BACKPACK / PROFILE SUGGESTION SYSTEM
-- Built from scratch using TradeApp source only.
do -- BACKPACK SUGGESTION
-- try_suggest_item   — checks backpack_access, requests it if nil
local RouterClient = load("RouterClient")
local DialogApp    = UIManager.apps.DialogApp

-- Suppress the game's "Trade request from <user> has expired!" popups when the Misc Page-2
-- toggle is on. The game spams these while we auto-decline lots of incoming requests during a
-- mock trade. Match on the text (username varies) and just swallow it — the game doesn't use
-- the return value. Only expired-trade dialogs match, so our own dialogs are unaffected.
if DialogApp and DialogApp.dialog and not DialogApp._expiredHooked then
    DialogApp._expiredHooked = true
    local _origDialog = DialogApp.dialog
    DialogApp.dialog = function(self, opts, ...)
        if _G._hideExpiredDialogs and type(opts) == "table" then
            local txt = (tostring(opts.text or "") .. " " .. tostring(opts.header or "")):lower()
            if txt:find("expired", 1, true) then
                return "Okay"
            end
        end
        return _origDialog(self, opts, ...)
    end
end

-- The fake trade_partner_inventory injected during a mock trade.
local mockPartnerInventory = nil

-- Per-trade profile cache so we only fetch once per partner
local profileCache = {}

-- Extract collection pets from a profile object.
-- Shape: { pages = { { widgets = { { data = { widget_kind, widget_data } } } } } }
local function parseProfilePets(data)
    local pets = {}
    local pages = data and (data.pages or (data.profile and data.profile.pages))
    if not pages then return pets end
    for _, page in ipairs(pages) do
        for _, widget in ipairs(page.widgets or {}) do
            local wd = widget.data
            if wd and wd.widget_kind == "collection" then
                for _, item in ipairs((wd.widget_data and wd.widget_data.items) or {}) do
                    if item.kind then table.insert(pets, item) end
                end
            end
        end
    end
    return pets
end

-- Pull the partner's collection pets. For a FAKE partner (not a real player in this server)
-- we read their GENERATED profile directly, so the suggest backpack always matches the
-- collection shown on their profile page. Real, in-server players use the server FetchProfile.
local function fetchProfilePets(userId)
    if profileCache[userId] then return profileCache[userId] end
    local pets = {}
    local inServer = false
    pcall(function() inServer = Players:GetPlayerByUserId(userId) ~= nil end)

    if not inServer and _G._genRandomProfile then
        safeCall(function() pets = parseProfilePets(_G._genRandomProfile(userId)) end)
    end
    if #pets == 0 then
        safeCall(function()
            local data = RouterClient.get("PlayerProfileAPI/FetchProfile"):InvokeServer(userId)
            pets = parseProfilePets(data)
        end)
    end

    profileCache[userId] = pets
    return pets
end
_G._fetchProfilePets = fetchProfilePets

-- Convert profile pet list into a trade_partner_inventory shaped table.
-- Each entry gets a fresh unique so the suggestion system can key on it.
local function buildPartnerInventory(pets)
    local inv = { pets = {} }
    for _, pet in ipairs(pets) do
        if InventoryDB.pets and InventoryDB.pets[pet.kind] then
            local uid = HttpService:GenerateGUID(false)
            local props = pet.properties or {}
            inv.pets[uid] = {
                unique     = uid,
                category   = "pets",
                kind       = pet.kind,
                id         = pet.kind,
                properties = { neon               = props.neon       or false, mega_neon          = props.mega_neon  or false, flyable            = props.flyable    or false, rideable           = props.rideable   or false, age                = props.age        or 1, ailments_completed = 0, },
            }
        end
    end
    return inv
end

-- _get_suggestible_items is called by suggest_item (source line 1241) to populate
-- the BackpackApp picker. Return our fake inventory during mock trades.
mockState.originalFunctions._get_suggestible_items = TradeApp._get_suggestible_items
TradeApp._get_suggestible_items = function(self)
    if mockState.active and mockState.trade then
        return mockPartnerInventory or { pets = {} }
    end
    return mockState.originalFunctions._get_suggestible_items(self)
end

-- try_suggest_item is called when the player presses the Suggest button
mockState.originalFunctions.try_suggest_item = TradeApp.try_suggest_item
TradeApp.try_suggest_item = function(self)
    if not mockState.active or not mockState.trade then
        return mockState.originalFunctions.try_suggest_item(self)
    end

    -- Already granted — go straight to picker
    if TradeApp.backpack_access == true then
        TradeApp:suggest_item()
        return
    end

    -- backpack_access == false means partner denied — match real behaviour
    if TradeApp.backpack_access == false then
        if UIManager.apps.HintApp then
            UIManager.apps.HintApp:hint({ text = "Backpack access denied.", length = 3, overridable = true, yields = false, })
        end
        return
    end

    -- backpack_access == nil — request not sent yet
    if UIManager.apps.HintApp then
        UIManager.apps.HintApp:hint({ text = "Backpack access requested..", length = 3, overridable = true, yields = false, })
    end

    task.spawn(function()
        local partner = TradeApp:_get_partner()
        if not partner then return end

        -- Fetch and build fake inventory from profile
        local pets = fetchProfilePets(partner.UserId)
        mockPartnerInventory = buildPartnerInventory(pets)

        -- Always fill with a large random inventory on top of whatever the profile has.
        -- Players should always look like they have a big backpack regardless of profile.
        do
            local function addFakePet(kind, props)
                if not (InventoryDB.pets and InventoryDB.pets[kind]) then return end
                local uid = HttpService:GenerateGUID(false)
                mockPartnerInventory.pets[uid] = {
                    unique     = uid, category = "pets",
                    kind       = kind, id = kind, properties = props,
                }
            end

            -- Weighted flag picker (same logic as _FAKE_INV_FLAG_WEIGHTS but inline)
            local function randFlags(noNeon)
                local r = math.random()
                local N, M, F, R
                if r < 0.28 then     F=true;  R=true  -- FR (most common)
                elseif r < 0.42 then F=true;  R=false -- F only
                elseif r < 0.54 then F=false; R=false -- no pot
                elseif r < 0.60 then F=false; R=true  -- R only
                elseif r < 0.68 then F=true;  R=true;  N=true  -- neon FR
                elseif r < 0.72 then F=false; R=false; N=true  -- neon no-pot
                elseif r < 0.75 then F=true;  R=false; N=true  -- neon F
                elseif r < 0.78 then F=true;  R=true;  M=true  -- mega FR
                else                 F=false; R=false; M=true  -- mega no-pot
                end
                if noNeon then N=false; M=false end
                return {
                    neon=N or false, mega_neon=M or false,
                    flyable=F or false, rideable=R or false,
                    age=math.random(1,6), ailments_completed=0,
                }
            end

            -- Starter/common eggs to exclude (not valuable)
            local STARTER_EGGS = {
                ["starter_egg"]=true, ["cracked_egg"]=true, ["pet_egg"]=true,
                ["royal_egg"]=true, ["safari_egg"]=true, ["jungle_egg"]=true,
                ["farm_egg"]=true, ["aussie_egg"]=true, ["fossil_egg"]=true,
                ["ocean_egg"]=true, ["woodland_egg"]=true, ["mythic_egg"]=true,
                ["star_egg"]=true, ["gift_egg"]=true,
            }
            -- Build pools: pets + rare/event eggs separately
            local allKinds = {}
            local eggKinds = {}
            local nameToKind = {}
            if KindDB then
                for kindId, entry in pairs(KindDB) do
                    local name = entry.name or entry.display_name
                    if name then
                        local nameLow = name:lower()
                        local invOk = not (InventoryDB and InventoryDB.pets) or
                                      InventoryDB.pets[kindId] ~= nil
                        if invOk then
                            nameToKind[nameLow] = kindId
                            if nameLow:find("egg") then
                                if not STARTER_EGGS[kindId] then
                                    table.insert(eggKinds, kindId)
                                end
                            else
                                table.insert(allKinds, kindId)
                            end
                        end
                    end
                end
            end
            -- Fallback
            if #allKinds == 0 and InventoryDB and InventoryDB.pets then
                for kindId, entry in pairs(InventoryDB.pets) do
                    if entry.name then
                        local nameLow = entry.name:lower()
                        nameToKind[nameLow] = kindId
                        if nameLow:find("egg") and not STARTER_EGGS[kindId] then
                            table.insert(eggKinds, kindId)
                        elseif not nameLow:find("egg") then
                            table.insert(allKinds, kindId)
                        end
                    end
                end
            end
            -- Shuffle both pools
            for i = #allKinds, 2, -1 do
                local j = math.random(1, i)
                allKinds[i], allKinds[j] = allKinds[j], allKinds[i]
            end
            for i = #eggKinds, 2, -1 do
                local j = math.random(1, i)
                eggKinds[i], eggKinds[j] = eggKinds[j], eggKinds[i]
            end

            -- High-tier legendaries (12–25, stacks of 1–5)
            local highTiers = {
                "Shadow Dragon","Bat Dragon","Frost Dragon","Giraffe","Blazing Lion",
                "African Wild Dog","Owl","Parrot","Crow","Evil Unicorn","Balloon Unicorn",
                "Dalmatian","Arctic Reindeer","Kangaroo","Turtle","Giant Panda","Hedgehog",
                "Cow","Chocolate Chip Bat Dragon","Flamingo","Peppermint Penguin",
                "Strawberry Shortcake Bat Dragon","Monkey King","Undead Jousting Horse",
                "Goose","Mermicorn","Cabbit","Yeti","Zombie Buffalo","Mini Pig",
                "Haetae","Cryptid","Jekyll Hydra","Orchid Butterfly","Criosphinx",
            }
            for i = #highTiers, 2, -1 do
                local j = math.random(1, i)
                highTiers[i], highTiers[j] = highTiers[j], highTiers[i]
            end
            local htAdded = 0
            local htTarget = math.random(20, 40)
            for _, name in ipairs(highTiers) do
                if htAdded >= htTarget then break end
                local kindId = nameToKind[name:lower()]
                if not kindId then
                    for n, id in pairs(nameToKind) do
                        if n:find(name:lower(), 1, true) then kindId = id; break end
                    end
                end
                if kindId then
                    local r2 = math.random()
                    local copies = r2 < 0.30 and 1 or r2 < 0.58 and 2 or r2 < 0.78 and 3 or r2 < 0.92 and 4 or r2 < 0.97 and 5 or 6
                    for _ = 1, copies do addFakePet(kindId, randFlags()) end
                    htAdded = htAdded + 1
                end
            end

            -- Random filler pets: 100–160, heavy stacking
            local fillerTarget = math.random(100, 160)
            for i = 1, math.min(fillerTarget, #allKinds) do
                local kindId = allKinds[i]
                local flags = randFlags()
                if math.random() < 0.25 then flags.flyable = false; flags.rideable = false end
                addFakePet(kindId, flags)
                -- 40% chance extra copy (stacking)
                if math.random() < 0.40 then addFakePet(kindId, randFlags()) end
                -- 20% chance third copy
                if math.random() < 0.20 then addFakePet(kindId, randFlags()) end
                -- 5% chance fourth copy
                if math.random() < 0.05 then addFakePet(kindId, randFlags()) end
            end

            -- Event/rare eggs only (no starter eggs): 10–30
            if #eggKinds > 0 then
                local eggTarget = math.random(10, 30)
                for i = 1, math.min(eggTarget, #eggKinds) do
                    local kindId = eggKinds[i]
                    local r2 = math.random()
                    local copies = r2 < 0.45 and 1 or r2 < 0.75 and 2 or r2 < 0.90 and 3 or 4
                    for _ = 1, copies do
                        addFakePet(kindId, { neon=false, mega_neon=false, flyable=false, rideable=false, age=1, ailments_completed=0 })
                    end
                end
            end
        end

        -- Small delay to simulate network round-trip
        task.wait(0.8)
        if not mockState.active then return end

        TradeApp.backpack_access = true

        -- Show the same dialog the real game shows (source line 1213)
        local res = UIManager.apps.DialogApp:dialog({ text  = string.format( "%s has granted you access to view their backpack! Make a suggestion now?", CONFIG.PARTNER_NAME), left  = "Cancel", right = "Suggest", })
        if res == "Suggest" then
            TradeApp:suggest_item()
        end
    end)
end

-- suggest_item is called once access is granted (source line 1239).
-- Opens the BackpackApp picker with inventory_override set to the fake partner inventory.
mockState.originalFunctions.suggest_item = TradeApp.suggest_item
TradeApp.suggest_item = function(self, preselected)
    if not mockState.active or not mockState.trade then
        return mockState.originalFunctions.suggest_item(self, preselected)
    end

    local partner = TradeApp:_get_partner()
    if not partner then return end

    -- pick_item with inventory_override mirrors source line 1248
    local picked = preselected or BackpackApp:pick_item({
        title_override     = string.format("%s'S BACKPACK", CONFIG.PARTNER_NAME:upper()),
        inventory_override = mockPartnerInventory or { pets = {} },
        force_no_filters   = true,
        friendship_hidden  = true,
        allow_callback     = function(item)
            -- Don't allow items already in the partner's offer (source line 1251)
            for _, existing in ipairs(mockState.trade.recipient_offer.items) do
                if existing.unique == item.unique then return false end
            end
            return true
        end,
    })

    if not picked then return end

    -- Ensure chat is open so suggestion card and message are visible
    if not TradeApp.negotiation_chat.Visible then
        TradeApp:toggle_chat_visibility(true)
    end

    -- _render_suggestion (TradeApp source line 1004):
    if not mockPartnerInventory then mockPartnerInventory = { pets = {} } end
    mockPartnerInventory.pets[picked.unique] = mockPartnerInventory.pets[picked.unique] or {
        unique     = picked.unique,
        category   = picked.category or "pets",
        kind       = picked.kind,
        id         = picked.kind,
        properties = picked.properties or {},
    }
    safeCall(function()
        TradeApp:_render_suggestion(picked.unique, partner)
    end)

    -- After 1.5s the partner "accepts" — matches _render_suggestion_finalized(source 1128)
    task.delay(1.5, function()
        if not mockState.active or not mockState.trade then return end

        -- Mark suggestion card as accepted
        safeCall(function()
            TradeApp:_render_suggestion_finalized(picked.unique, true, partner)
        end)

        -- Insert into recipient_offer exactly like _on_local_trade_state_changed does
        -- when it detects a new item in the partner offer (source line 778)
        local petName = picked.kind
        pcall(function() petName = InventoryDB.pets[picked.kind].name end)

        local petItem = {
            category   = "pets",
            kind       = picked.kind,
            unique     = picked.unique,
            properties = { neon               = picked.properties and picked.properties.neon      or false, mega_neon          = picked.properties and picked.properties.mega_neon or false, flyable            = picked.properties and picked.properties.flyable   or false, rideable           = picked.properties and picked.properties.rideable  or false, age                = picked.properties and picked.properties.age       or 1, ailments_completed = 0, },
        }

        table.insert(mockState.trade.recipient_offer.items, petItem)
        TradeApp.can_suggest_removal_items[petItem.unique] = petItem
        mockState.trade.sender_offer.negotiated    = false; mockState.trade.recipient_offer.negotiated = false
        mockState.trade.offer_version = mockState.trade.offer_version + 1
        TradeApp:_overwrite_local_trade_state(mockState.trade)
        if TradeApp._lock_trade_for_appropriate_time then
            TradeApp:_lock_trade_for_appropriate_time()
        end
        TradeApp:_render_message_in_trade_chat(nil,
            string.format("%s added %s.", CONFIG.PARTNER_NAME, petName), true)
    end)
end

-- Clear suggestion state when the trade ends (the nil path of _overwrite_local_trade_state)
-- We patch the already-hooked function to also clear our state
local _existingOverwrite = TradeApp._overwrite_local_trade_state
TradeApp._overwrite_local_trade_state = function(self, newState)
    if not newState then
        mockPartnerInventory      = nil
        TradeApp.backpack_access  = nil
    end
    return _existingOverwrite(self, newState)
end

end -- BACKPACK SUGGESTION do block

-- PROFILE SUGGESTION HOOK
local _PlayerProfileApp = UIManager.apps.PlayerProfileApp

local function hookProfileWidgetItems()
    if not _PlayerProfileApp then return end
    if not mockState.active or not mockState.trade then return end

    local profileApp = _PlayerProfileApp
    if not profileApp.player_profile then return end

    local profileUserId = profileApp.player_profile.user_id
    if profileUserId ~= mockState.trade.recipient.UserId then return end

    local slotCount = 0
    for _ in pairs(profileApp.slots or {}) do slotCount = slotCount + 1 end

    -- Wire the Suggest button on the profile header
    safeCall(function()
        if profileApp.trade_button and profileApp.trade_button.instance then
            local btn = profileApp.trade_button.instance
            if not btn:GetAttribute("_mockSuggestHooked") then
                btn:SetAttribute("_mockSuggestHooked", true)
                btn.Activated:Connect(function()
                    if not mockState.active then return end
                    if not profileApp.player_profile then return end
                    if profileApp.player_profile.user_id ~= CONFIG.PARTNER_USER_ID then return end
                    UIManager.set_app_visibility("PlayerProfileApp", false)
                    UIManager.set_app_visibility("TradeApp", true)
                    task.defer(function()
                        pcall(function() TradeApp:try_suggest_item() end)
                    end)
                end)
            end
        end
    end)

    -- Walk all slots looking for CollectionPlayerProfileWidget
    for _, slot in pairs(profileApp.slots or {}) do
        local widget = slot.widget
        if widget and widget.ClassName == "CollectionPlayerProfileWidget" then
            local items = widget.save_data and widget.save_data.items or {}
            local itemInstances = widget.item_instances or {}

            for idx, itemBtn in pairs(itemInstances) do
                if itemBtn:IsA("ImageButton") and not itemBtn:GetAttribute("_mockHooked") then
                    itemBtn:SetAttribute("_mockHooked", true)
                    local item = items[idx]
                    if item and item.kind then
                        itemBtn.MouseButton1Click:Connect(function()
                            if not mockState.active or not mockState.trade then return end

                            local petDbEntry = InventoryDB.pets and InventoryDB.pets[item.kind]
                            local displayName = item.properties and item.properties.custom_name
                                or (petDbEntry and petDbEntry.name)
                                or item.kind

                            local response = UIManager.apps.DialogApp:dialog({
                                dialog_type = "ItemPreviewDialog",
                                item        = item,
                                text        = string.format(
                                    "Add suggestion for %s's %s?",
                                    CONFIG.PARTNER_NAME, displayName),
                                right = "Suggest",
                                left  = "Cancel",
                            })

                            if response ~= "Suggest" then return end

                            if not mockPartnerInventory then
                                mockPartnerInventory = { pets = {} }
                            end
                            mockPartnerInventory.pets[item.unique] = {
                                unique     = item.unique,
                                category   = item.category or "pets",
                                kind       = item.kind,
                                id         = item.kind,
                                properties = { neon      = item.properties and item.properties.neon      or false, mega_neon = item.properties and item.properties.mega_neon or false, flyable   = item.properties and item.properties.flyable   or false, rideable  = item.properties and item.properties.rideable  or false, age       = item.properties and item.properties.age       or 1, ailments_completed = 0, },
                            }
                            TradeApp.backpack_access = true

                            UIManager.set_app_visibility("PlayerProfileApp", false)
                            if not TradeApp.negotiation_chat.Visible then
                                TradeApp:toggle_chat_visibility(true)
                            end

                            TradeApp:suggest_item(mockPartnerInventory.pets[item.unique])
                        end)
                    end
                end
            end
        end
    end
end

if _PlayerProfileApp then
    task.spawn(function()
        while true do
            task.wait(0.3)
            if not mockState.active then continue end
            local profileApp = _PlayerProfileApp
            if not profileApp.instance.Enabled then continue end
            if not profileApp.player_profile then continue end
            hookProfileWidgetItems()
        end
    end)

    -- Hook enable_profile_editing so the Suggest button appears when the mock
    -- partner's profile is opened during a trade.  We temporarily swap self.player
    -- to mockPartner so the real enable_profile_editing picks the TRADE_VISIBLE
    -- layout (shrinks the name label, shows the action button) without affecting
    -- real player profiles.
    local _origEnableEditing = _PlayerProfileApp.enable_profile_editing
    _PlayerProfileApp.enable_profile_editing = function(self, editing, ...)
        local isMockPartner = mockState.active
            and self.player_profile
            and self.player_profile.user_id == CONFIG.PARTNER_USER_ID

        if isMockPartner and not editing then
            local origPlayer = self.player
            self.player = mockPartner
            _origEnableEditing(self, editing, ...)
            self.player = origPlayer
            -- Force the header to show "Suggest" state (in_trade_with_me = true)
            safeCall(function()
                self:set_header_info({
                    in_trade         = true,
                    in_trade_with_me = true,
                })
            end)
        else
            _origEnableEditing(self, editing, ...)
        end
    end

    -- Hook open_player_profile_for_user_id so that opening the mock partner's
    -- profile during a trade automatically triggers the enable_profile_editing
    -- hook (via on_load_call) once the profile has finished loading, which sets
    -- the TRADE_VISIBLE layout and shows the Suggest button in the header.
    local _origSuggestOpen = _PlayerProfileApp.open_player_profile_for_user_id
    if _origSuggestOpen then
        _PlayerProfileApp.open_player_profile_for_user_id = function(self, userId, ...)
            local result = _origSuggestOpen(self, userId, ...)
            if mockState.active and userId == CONFIG.PARTNER_USER_ID then
                self:on_load_call(function()
                    safeCall(function()
                        self:enable_profile_editing(false)
                    end)
                end)
            end
            return result
        end
    end
end

-- SUGGEST REMOVAL HOOK
local _origRenderMessage = TradeApp._render_message_in_trade_chat
TradeApp._render_message_in_trade_chat = function(self, player, message, isPartner, ...)
    -- Deduplicate the intro system messages. They can fire twice and in varying order during
    -- mock trade init, so show each UNIQUE intro line exactly once per trade — order-independent.
    -- (The old single-flag logic dropped whichever line arrived after "change what trade chat",
    --  which is why the intro sometimes didn't fully show.)
    if mockState.active and type(message) == "string"
        and (message:find("chatting with")
            or message:find("change what trade chat")
            or message:find("system messages disabled")) then
        if _G._introTradeRef ~= mockState.trade then
            _G._introTradeRef = mockState.trade
            _G._introSeen = {}
        end
        if _G._introSeen[message] then return end
        _G._introSeen[message] = true
    end
    local result = _origRenderMessage(self, player, message, isPartner, ...)

    -- Detect the "You want X to remove Y" message fired by the real slot Activated
    if mockState.active and mockState.trade
        and type(message) == "string"
        and message:find("You want .+ to remove .+ from their offer") then

        -- Find which item was requested — it's the most recently flagged unique
        local petName = message:match("to remove (.+) from their offer")
        if petName then
            task.delay(1.5, function()
                if not mockState.active or not mockState.trade then return end
                local items = mockState.trade.recipient_offer.items
                for i = #items, 1, -1 do
                    local item = items[i]
                    local name = item.kind
                    pcall(function() name = InventoryDB.pets[item.kind].name end)
                    if name:lower() == petName:lower() then
                        local unique = item.unique
                        table.remove(items, i)
                        if TradeApp.can_suggest_removal_items then
                            TradeApp.can_suggest_removal_items[unique] = nil
                        end
                        resetTradeNegotiation()
                        TradeApp:_overwrite_local_trade_state(mockState.trade)
                        if TradeApp._lock_trade_for_appropriate_time then
                            TradeApp:_lock_trade_for_appropriate_time()
                        end
                        _origRenderMessage(self, nil,
                            string.format("%s removed %s.", CONFIG.PARTNER_NAME, name),
                            true)
                        break
                    end
                end
            end)
        end
    end

    return result
end

local function addPetToPartnerOffer(petName, flags)
    if not mockState.active or not mockState.trade then return false end
    if mockState.trade.current_stage == "confirmation" then return false end
    if #mockState.trade.recipient_offer.items >= 18 then return false end
    if not TradeApp.can_suggest_removal_items then
        TradeApp.can_suggest_removal_items = {}
    end

    -- Show the partner "picking" busy indicator for 1 second
    local partnerId = tostring(mockState.trade.recipient.UserId)
    mockState.trade.busy_indicators = mockState.trade.busy_indicators or {}
    mockState.trade.busy_indicators[partnerId] = { picking = true }
    pcall(function() TradeApp:_update_busy_indicators(mockState.trade) end)

    for cn, ct in pairs(InventoryDB) do
        if cn == "pets" then
            for id, item in pairs(ct) do
                local nameLower    = item.name:lower()
                local nameClean    = nameLower:gsub("%s+", "")
                local inputLower   = petName:lower()
                local inputClean   = inputLower:gsub("%s+", "")
                if nameLower == inputLower or nameClean == inputClean then
                    local uuid    = HttpService:GenerateGUID()
                    -- Eggs don't support flyable/rideable/neon/mega_neon flags
                    local isEgg   = item.name:lower():find("egg") ~= nil
                    local petItem = {
                        category   = "pets",
                        kind       = id,
                        unique     = uuid,
                        properties = { flyable            = not isEgg and flags.F or false, rideable           = not isEgg and flags.R or false, neon               = not isEgg and flags.N or false, mega_neon          = not isEgg and flags.M or false, age                = 1, ailments_completed = 0, },
                    }
                    task.wait(1)
                    if not mockState.active or not mockState.trade then return false end
                    -- Clear the busy indicator before adding
                    mockState.trade.busy_indicators[partnerId] = nil
                    pcall(function() TradeApp:_update_busy_indicators(mockState.trade) end)
                    table.insert(mockState.trade.recipient_offer.items, petItem)
                    TradeApp.can_suggest_removal_items[uuid] = petItem
                    mockState.trade.sender_offer.negotiated    = false; mockState.trade.recipient_offer.negotiated = false
                    mockState.trade.offer_version = mockState.trade.offer_version + 1
                    TradeApp:_overwrite_local_trade_state(mockState.trade)
                    if TradeApp._lock_trade_for_appropriate_time then
                        TradeApp:_lock_trade_for_appropriate_time()
                    end
                    if TradeApp._render_message_in_trade_chat then
                        TradeApp:_render_message_in_trade_chat(nil, CONFIG.PARTNER_NAME .. " added " .. item.name .. ".", true)
                    end
                    mockState.scamWarningShown = false
                    return true
                end
            end
        end
    end
    return false
end

local function removeLatestPetFromPartnerOffer()
    if not mockState.active or not mockState.trade then return end
    local items = mockState.trade.recipient_offer.items
    if #items == 0 then return end
    local removed = table.remove(items)
    if TradeApp.can_suggest_removal_items and removed then
        TradeApp.can_suggest_removal_items[removed.unique] = nil
    end
    resetTradeNegotiation()
    TradeApp:_overwrite_local_trade_state(mockState.trade)
    if TradeApp._lock_trade_for_appropriate_time then
        TradeApp:_lock_trade_for_appropriate_time()
    end
end

local HIGH_TIER_PETS = {
    "Bat Dragon",
    "Shadow Dragon",
    "Giraffe",
    "Frost Dragon",
    "Owl",
    "Parrot",
    "Crow",
    "Balloon Unicorn",
    "African Wild Dog",
    "Giant Panda",
    "Haetae",
    "Cryptid",
    "Evil Unicorn",
    "Blazing Lion",
    "Hedgehog",
    "Orchid Butterfly",
    "Diamond Butterfly",
    "Dalmatian",
    "Arctic Reindeer",
    "Jekyll Hydra",
    "Mini Pig",
    "Hot Doggo",
    "Pelican",
    "Cow",
    "Mermicorn",
    "Strawberry Shortcake Bat Dragon",
    "Cabbit",
    "Chocolate Chip Bat Dragon",
    "Turtle",
    "Peppermint Penguin",
    "Goose",
    "Monkey King",
    "Undead Jousting Horse",
    "Flamingo",
    "Kangaroo",
}

-- Tiered high tier list: each entry has a max neon level
-- "default" = normal only, "neon" = neon max, "any" = mega neon allowed
local HIGH_TIER_PETS_TIERED = {
    { name = "Bat Dragon",                      max = "default" },
    { name = "Shadow Dragon",                   max = "default" },
    { name = "Giraffe",                         max = "default" },
    { name = "Frost Dragon",                    max = "neon"    },
    { name = "Owl",                             max = "neon"    },
    { name = "Parrot",                          max = "neon"    },
    { name = "Crow",                            max = "neon"    },
    { name = "Balloon Unicorn",                 max = "neon"    },
    { name = "African Wild Dog",                max = "neon"    },
    { name = "Giant Panda",                     max = "neon"    },
    { name = "Haetae",                          max = "neon"    },
    { name = "Cryptid",                         max = "neon"    },
    { name = "Evil Unicorn",                    max = "neon"    },
    { name = "Blazing Lion",                    max = "neon"    },
    { name = "Hedgehog",                        max = "neon"    },
    { name = "Orchid Butterfly",                max = "any"     },
    { name = "Diamond Butterfly",               max = "any"     },
    { name = "Dalmatian",                       max = "any"     },
    { name = "Arctic Reindeer",                 max = "any"     },
    { name = "Jekyll Hydra",                    max = "any"     },
    { name = "Mini Pig",                        max = "any"     },
    { name = "Hot Doggo",                       max = "any"     },
    { name = "Pelican",                         max = "any"     },
    { name = "Cow",                             max = "any"     },
    { name = "Mermicorn",                       max = "any"     },
    { name = "Strawberry Shortcake Bat Dragon", max = "any"     },
    { name = "Cabbit",                          max = "any"     },
    { name = "Chocolate Chip Bat Dragon",       max = "any"     },
    { name = "Turtle",                          max = "any"     },
    { name = "Peppermint Penguin",              max = "any"     },
    { name = "Goose",                           max = "any"     },
    { name = "Monkey King",                     max = "any"     },
    { name = "Undead Jousting Horse",           max = "any"     },
    { name = "Flamingo",                        max = "any"     },
    { name = "Kangaroo",                        max = "any"     },
}

local _useTieredList = false  -- toggled in Misc tab

-- Flags for the pet add buttons — defined here so addRandomHighTier can use them
local activeFlags = { F = false, R = false, N = false, M = false }

-- All possible flag combinations with weighted probability
-- More common ones (FR, NFR, MFR) appear more often
local RANDOM_FLAG_COMBOS = {
    { F=false, R=false, N=false, M=false }, -- Normal
    { F=true,  R=false, N=false, M=false }, -- Fly
    { F=false, R=true,  N=false, M=false }, -- Ride
    { F=true,  R=true,  N=false, M=false }, -- FR
    { F=true,  R=true,  N=false, M=false }, -- FR (weighted extra)
    { F=false, R=false, N=true,  M=false }, -- Neon
    { F=true,  R=false, N=true,  M=false }, -- NF
    { F=false, R=true,  N=true,  M=false }, -- NR
    { F=true,  R=true,  N=true,  M=false }, -- NFR
    { F=true,  R=true,  N=true,  M=false }, -- NFR (weighted extra)
    { F=false, R=false, N=false, M=true  }, -- Mega
    { F=true,  R=false, N=false, M=true  }, -- MF
    { F=false, R=true,  N=false, M=true  }, -- MR
    { F=true,  R=true,  N=false, M=true  }, -- MFR
    { F=true,  R=true,  N=false, M=true  }, -- MFR (weighted extra)
}

-- Tracks the last pet name picked by addRandomHighTier (set immediately,
local lastAddedHighTier = nil

local function addRandomHighTier()
    if not mockState.active or not mockState.trade then return end

    if _useTieredList then
        -- Tiered mode: pick pet respecting per-pet max neon level
        local shuffled = {}
        for _, entry in ipairs(HIGH_TIER_PETS_TIERED) do
            if entry.name ~= lastAddedHighTier then
                table.insert(shuffled, entry)
            end
        end
        TableUtil.shuffle(shuffled)
        for _, entry in ipairs(shuffled) do
            -- Build flags based on max tier (keys are F/R/N/M)
            local flags
            if entry.max == "default" then
                local pool = {}
                for _, fc in ipairs(RANDOM_FLAG_COMBOS) do
                    if not fc.N and not fc.M then table.insert(pool, fc) end
                end
                flags = pool[math.random(1, #pool)]
            elseif entry.max == "neon" then
                local pool = {}
                for _, fc in ipairs(RANDOM_FLAG_COMBOS) do
                    if not fc.M then table.insert(pool, fc) end
                end
                flags = pool[math.random(1, #pool)]
            else
                flags = RANDOM_FLAG_COMBOS[math.random(1, #RANDOM_FLAG_COMBOS)]
            end
            lastAddedHighTier = entry.name
            if addPetToPartnerOffer(entry.name, flags) then return end
        end
    else
        -- Normal mode: plain random from HIGH_TIER_PETS
        local shuffled = {}
        for _, v in ipairs(HIGH_TIER_PETS) do
            if v ~= lastAddedHighTier then
                table.insert(shuffled, v)
            end
        end
        TableUtil.shuffle(shuffled)
        local flags = RANDOM_FLAG_COMBOS[math.random(1, #RANDOM_FLAG_COMBOS)]
        for _, name in ipairs(shuffled) do
            lastAddedHighTier = name
            if addPetToPartnerOffer(name, flags) then return end
        end
    end
    lastAddedHighTier = nil
    warn("[MockTrade] No high tier pet names matched InventoryDB")
end

local function updatePartnerFromUsername(username)
    -- Block updates while a trade is active OR a trade request dialog is pending
    -- so the in-trade username never gets overwritten by keybind selections
    if mockState.active or _tradeRequestPending then return end
    CONFIG.PARTNER_NAME = username
    CONFIG.PARTNER_USER_ID = 0
    mockPartner = createMockPartner()
    -- Async lookup runs in background so UI doesn't freeze
    task.spawn(function()
        local ok, userId = pcall(function()
            return Players:GetUserIdFromNameAsync(username)
        end)
        if mockState.active or _tradeRequestPending then return end
        if CONFIG.PARTNER_NAME ~= username then return end -- user changed name again
        CONFIG.PARTNER_USER_ID = (ok and userId) and userId or 0
        mockPartner = createMockPartner()
    end)
end

local _tradeRequestPending = false
local function initializeMockTrade()
    if mockState.active then return end
    if _tradeRequestPending then return end
    _tradeRequestPending = true

    -- Reset cached rank so stale badge from previous trade never carries over
    _cachedPartnerRank = 0

    mockPartner = createMockPartner()

    local DialogApp = UIManager.apps.DialogApp
    if DialogApp then
        task.spawn(function()
            pcall(function() setthreadidentity(2) end)
            local ok, response = pcall(function()
                -- Fetch rank synchronously right now so badge is always correct and instant
                local _dialogHeader = nil
                -- Friend badge takes priority if verified friend toggle is on
                if CONFIG_VERIFIED_FRIEND then
                    safeCall(function()
                        local GRH = load("GroupRankHelper")
                        if GRH then
                            local icon = GRH.get_icon_from_tag("friend")
                            if icon then
                                _dialogHeader = { text = "Verified Friend", icon = icon }
                            end
                        end
                    end)
                end
                -- Group rank badge (only if friend badge not set)
                if not _dialogHeader and CONFIG.PARTNER_USER_ID ~= 0 then
                    safeCall(function()
                        local GRH = load("GroupRankHelper")
                        if not GRH then return end
                        local rank = GRH.get_rank_from_user_id(CONFIG.PARTNER_USER_ID)
                        if not rank or rank == 0 then return end
                        _cachedPartnerRank = rank
                        local tag = GRH.get_tag_from_rank(rank)
                        local icon = tag and GRH.get_icon_from_tag(tag)
                        if tag and icon then
                            _dialogHeader = { text = "Verified " .. tag:sub(1,1):upper() .. tag:sub(2), icon = icon, }
                        end
                    end)
                end
                return DialogApp:dialog({ text   = CONFIG.PARTNER_NAME .. " sent you a trade request", left   = "Decline", right  = "Accept", handle = "trade_request", header = _dialogHeader, })
            end)
            _tradeRequestPending = false
            if not ok or response ~= "Accept" then
                return
            end

            mockState.isAddingItem     = false; mockState.tradeCompleting  = false
            mockState.scamWarningShown = false; mockState.trade            = createMockTrade()
            mockState.active           = true
            notifyProfileAppTradeState(true)

            if not TradeApp.can_suggest_removal_items then
                TradeApp.can_suggest_removal_items = {}
            end

            TradeApp:_overwrite_local_trade_state(mockState.trade)
            UIManager.set_app_visibility("TradeApp", true)

            task.spawn(function()
                task.wait(0.2)
                if TradeApp.refresh_all then TradeApp:refresh_all() end
                -- Always show intro message
                pcall(function() if TradeApp._show_intro_message then TradeApp:_show_intro_message() end end)
                _G._autoSpinWaitingForTrade = false  -- new trade opened, auto spin can now fire
                -- Force spectate frame and ReactionFrame visible for fake reactions
                safeCall(function()
                    local sf = TradeApp.spectate_frame
                    if sf then
                        sf.Visible = true
                        local rf = sf:FindFirstChild("ReactionFrame")
                        if rf then rf.Visible = true end
                        -- Hide the close/emoji buttons so it doesnt look weird
                        local closeBtn = sf:FindFirstChild("Close")
                        if closeBtn then closeBtn.Visible = false end
                        local emojiFrame = sf:FindFirstChild("EmojiFrame")
                        if emojiFrame then emojiFrame.Visible = false end
                    end
                end)
            end)

            if CONFIG.SPECTATOR_COUNT > 0 then
                startSpectatorLoop()
            end
            if _autoChatEnabled then _startAutoChatLoop() end
        end)
    else
        mockState.isAddingItem     = false; mockState.tradeCompleting  = false
        mockState.scamWarningShown = false; mockState.trade            = createMockTrade()
        mockState.active           = true
        notifyProfileAppTradeState(true)

        if not TradeApp.can_suggest_removal_items then
            TradeApp.can_suggest_removal_items = {}
        end

        TradeApp:_overwrite_local_trade_state(mockState.trade)
        UIManager.set_app_visibility("TradeApp", true)

        task.spawn(function()
            task.wait(0.2)
            if TradeApp.refresh_all then TradeApp:refresh_all() end
            pcall(function() if TradeApp._show_intro_message then TradeApp:_show_intro_message() end end)
        end)

        if CONFIG.SPECTATOR_COUNT > 0 then
            startSpectatorLoop()
        end
        if _autoChatEnabled then _startAutoChatLoop() end
    end
end

-- PREFIX FLAGS (Pets tab)

local currentTab        = "Control"
local tabFrames         = {}
local tabButtons        = {}
local hasShownAnimation = {}
local playerListButtons = {}

local controlGui = mk("ScreenGui", {Name="MockTradeControl", ResetOnSpawn=false, DisplayOrder=10, Enabled=true, Parent=Players.LocalPlayer:WaitForChild("PlayerGui")})
_G._controlGui = controlGui

local blackFrame = mk("Frame", {Name="BlackFrame", Size=UDim2.new(0, 136, 0, 306), Position=UDim2.new(0, 202, 0.5, -153), BackgroundColor3=Color3.new(0, 0, 0), BorderSizePixel=0, ZIndex=0, Parent=controlGui})
Instance.new("UICorner", blackFrame).CornerRadius = UDim.new(0, 7)

local mainFrame = Instance.new("Frame")
_G._tradeGuiMainFrame = mainFrame  -- expose for spin tab dropdown
mainFrame.Size             = UDim2.new(0, 130, 0, 300); mainFrame.Position         = UDim2.new(0, 205, 0.5, -150)
mainFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 40); mainFrame.BorderSizePixel  = 0
mainFrame.ZIndex           = 1; mainFrame.Parent           = controlGui
Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 5)
local mainUIScale = mk("UIScale", {Scale=1, Parent=mainFrame})
local mainStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=1.5, Parent=mainFrame})

-- Jump / spring button toggles the GUI on/off completely
UserInputService.JumpRequest:Connect(function()
    controlGui.Enabled = not controlGui.Enabled
end)

local titleLabel = mk("TextLabel", {Size=UDim2.new(1, 0, 0, 13), Position=UDim2.new(0, 0, 0, 1), BackgroundTransparency=1, Text="edu.mlr on Discord", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190,34,230), Parent=mainFrame})
local titleStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Contextual, Color=Color3.new(0, 0, 0), Thickness=0.7, Parent=titleLabel})

local tabContainer = mk("Frame", {Size=UDim2.new(0.94, 0, 0, 13), Position=UDim2.new(0.03, 0, 0, 16), BackgroundTransparency=1, Parent=mainFrame})

local animatePlayerList  -- forward declaration, defined after Players tab build
local refreshPlayerList  -- forward declaration

local function setActiveTab(tabName)
    if currentTab == tabName then return end
    currentTab = tabName
    for name, data in pairs(tabButtons) do
        local isActive = name == tabName
        TweenService:Create(data.button, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundColor3 = isActive and Color3.fromRGB(50, 50, 60) or Color3.fromRGB(40, 40, 50) }):Play()
        local targetColor     = isActive and Color3.fromRGB(190,34,230) or Color3.fromRGB(80, 80, 80)
        local targetThickness = isActive and 1.0 or 0.7
        TweenService:Create(data.stroke, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Color = targetColor, Thickness = targetThickness }):Play()
        if isActive then
            local fadeIn = TweenService:Create(data.stroke, TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Color     = targetColor:Lerp(Color3.fromRGB(255, 255, 255), 0.25), Thickness = 1.3 })
            fadeIn:Play()
            fadeIn.Completed:Connect(function()
                TweenService:Create(data.stroke, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Color = targetColor, Thickness = 1.0 }):Play()
            end)
        end
    end
    for name, frame in pairs(tabFrames) do
        frame.Visible = name == tabName
    end
    if tabName == "Players" and not hasShownAnimation[tabName] then
        hasShownAnimation[tabName] = true
        animatePlayerList()
    end
end

local tabs = { "Control", "Players", "Misc" }
-- Tab icon asset ids (image icons + text; text hides when 5+ tabs are active)
local ICON_IDS = { Control=7059346386, Players=7992557371, Misc=109065241613994, Spin=125246450296582, Anti=14939023900, Chat=14895333477, Spawn=13001190578 }

for i, tabName in ipairs(tabs) do
    local tabButton = mk("TextButton", {Size=UDim2.new(1 / #tabs - 0.02, 0, 1, 0), Position=UDim2.new((i - 1) * (1 / #tabs), 0, 0, 0), BackgroundColor3=i == 1 and Color3.fromRGB(50, 50, 60) or Color3.fromRGB(40, 40, 50), BackgroundTransparency=0.2, Text="", Font=Enum.Font.FredokaOne, TextSize=5, TextColor3=Color3.fromRGB(255, 255, 255), Parent=tabContainer})
    Instance.new("UICorner", tabButton).CornerRadius = UDim.new(0, 3)
    local tabContent = mk("Frame", {AnchorPoint=Vector2.new(0.5,0.5), Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0,0,0,12), AutomaticSize=Enum.AutomaticSize.X, BackgroundTransparency=1, Parent=tabButton})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,2), SortOrder=Enum.SortOrder.LayoutOrder, Parent=tabContent})
    local tabIcon = mk("ImageLabel", {Size=UDim2.new(0,11,0,11), BackgroundTransparency=1, Image="rbxthumb://type=Asset&id="..ICON_IDS[tabName].."&w=150&h=150", ScaleType=Enum.ScaleType.Fit, LayoutOrder=1, Parent=tabContent})
    local tabLabel = mk("TextLabel", {Size=UDim2.new(0,0,0,11), AutomaticSize=Enum.AutomaticSize.X, BackgroundTransparency=1, Text=tabName, Font=Enum.Font.FredokaOne, TextSize=5, TextColor3=Color3.fromRGB(255,255,255), LayoutOrder=2, Parent=tabContent})
    local tabStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=i == 1 and Color3.fromRGB(190,34,230) or Color3.fromRGB(80, 80, 80), Thickness=i == 1 and 1.0 or 0.7, Transparency=0.3, Parent=tabButton})
    tabButtons[tabName] = { button = tabButton, stroke = tabStroke, icon = tabIcon, label = tabLabel }

    local tabFrame = Instance.new("Frame")
    tabFrame.Size     = UDim2.new(0.9, 0, 1, -33)
    tabFrame.Position = UDim2.new(0.05, 0, 0, 33)
    tabFrame.BackgroundTransparency = 1; tabFrame.Visible               = i == 1
    tabFrame.Parent                = mainFrame
    tabFrames[tabName] = tabFrame

    tabButton.MouseButton1Click:Connect(function() setActiveTab(tabName) end)
end

local _spawnTabEnabled = false
local _antiTabEnabled  = false
local _chatTabEnabled  = false

-- Returns the ordered list of currently active tabs
local function _getActiveTabs()
    local t = { "Control", "Players", "Misc" }
    if _antiTabEnabled  then table.insert(t, "Anti")  end
    if _chatTabEnabled  then table.insert(t, "Chat")  end
    if _spawnTabEnabled then table.insert(t, "Spawn") end
    return t
end

-- Rebuild all visible tab button sizes/positions
local function _rebuildTabPositions()
    local active = _getActiveTabs()
    local n = #active
    local iconOnly = n >= 5   -- crowded: center the icon, hide the text
    for idx, name in ipairs(active) do
        local data = tabButtons[name]
        if data then
            data.button.Size     = UDim2.new(1/n - 0.02, 0, 1, 0)
            data.button.Position = UDim2.new((idx-1)*(1/n), 0, 0, 0)
            if data.label then data.label.Visible = not iconOnly end
        end
    end
end

local function _addOptionalTab(name, icon, color)
    if tabButtons[name] then return end
    local active = _getActiveTabs()
    local n = #active
    local idx = 0
    for i, v in ipairs(active) do if v == name then idx = i end end
    local tabButton = mk("TextButton", {BackgroundColor3=Color3.fromRGB(40,40,50), BackgroundTransparency=0.2, Text="", Font=Enum.Font.FredokaOne, TextSize=5, TextColor3=Color3.fromRGB(255,255,255), Parent=tabContainer})
    Instance.new("UICorner", tabButton).CornerRadius = UDim.new(0,3)
    local tabContent = mk("Frame", {AnchorPoint=Vector2.new(0.5,0.5), Position=UDim2.new(0.5,0,0.5,0), Size=UDim2.new(0,0,0,12), AutomaticSize=Enum.AutomaticSize.X, BackgroundTransparency=1, Parent=tabButton})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0,2), SortOrder=Enum.SortOrder.LayoutOrder, Parent=tabContent})
    local tabIcon = mk("ImageLabel", {Size=UDim2.new(0,11,0,11), BackgroundTransparency=1, Image="rbxthumb://type=Asset&id="..(ICON_IDS[name] or 0).."&w=150&h=150", ScaleType=Enum.ScaleType.Fit, LayoutOrder=1, Parent=tabContent})
    local tabLabel = mk("TextLabel", {Size=UDim2.new(0,0,0,11), AutomaticSize=Enum.AutomaticSize.X, BackgroundTransparency=1, Text=name, Font=Enum.Font.FredokaOne, TextSize=5, TextColor3=Color3.fromRGB(255,255,255), LayoutOrder=2, Parent=tabContent})
    local tabStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=color or Color3.fromRGB(80,80,80), Thickness=0.7, Transparency=0.3, Parent=tabButton})
    tabButtons[name] = { button = tabButton, stroke = tabStroke, icon = tabIcon, label = tabLabel }
    tabButton.MouseButton1Click:Connect(function() setActiveTab(name) end)
    _rebuildTabPositions()
end

local function _removeOptionalTab(name)
    local data = tabButtons[name]
    if data then data.button:Destroy(); tabButtons[name] = nil end
    if currentTab == name then setActiveTab("Misc") end
    if tabFrames[name] then tabFrames[name].Visible = false end
    _rebuildTabPositions()
end

local function _setSpawnTabVisible(enabled)
    _spawnTabEnabled = enabled
    if enabled then
        _addOptionalTab("Spawn", "🐾", Color3.fromRGB(80,80,80))
    else
        _removeOptionalTab("Spawn")
    end
end

local function _setAntiTabVisible(enabled)
    _antiTabEnabled = enabled
    if enabled then
        _addOptionalTab("Anti", "🛡️", Color3.fromRGB(220,50,50))
    else
        _removeOptionalTab("Anti")
    end
end

local function _setChatTabVisible(enabled)
    if enabled then
        _addOptionalTab("Chat", "💬", Color3.fromRGB(60,120,200))
    else
        _removeOptionalTab("Chat")
    end
end

-- Pre-create Spawn and Anti tab frames (hidden by default)
do
    local spawnFrame = mk("Frame", {Size=UDim2.new(0.9,0,1,-33), Position=UDim2.new(0.05,0,0,33), BackgroundTransparency=1, Visible=false, Parent=mainFrame})
    tabFrames["Spawn"] = spawnFrame
end
do
    local antiFrame = mk("Frame", {Size=UDim2.new(0.9,0,1,-33), Position=UDim2.new(0.05,0,0,33), BackgroundTransparency=1, Visible=false, Parent=mainFrame})
    tabFrames["Anti"] = antiFrame
end
do
    local chatFrame = mk("Frame", {Size=UDim2.new(0.9,0,1,-33), Position=UDim2.new(0.05,0,0,33), BackgroundTransparency=1, Visible=false, Parent=mainFrame})
    tabFrames["Chat"] = chatFrame
end

do
    local spinTabFrame = mk("Frame", {Size=UDim2.new(0.9, 0, 1, -33), Position=UDim2.new(0.05, 0, 0, 33), BackgroundTransparency=1, Visible=false, Parent=mainFrame})
    tabFrames["Spin"] = spinTabFrame
end

local partnerBox, partnerStroke
do
local controlFrame = tabFrames["Control"]
local controlLayout = mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0, 2), Parent=controlFrame})

local pulsationTweens = {}

local function createSettingRow(labelText, defaultValue, parent)
    local heading = mk("TextLabel", {Size=UDim2.new(1, 0, 0, 9), BackgroundTransparency=1, Text="  " .. labelText, Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=parent})
    local box = mk("TextBox", {Size=UDim2.new(1, 0, 0, 15), BackgroundColor3=Color3.fromRGB(20, 18, 35), BackgroundTransparency=0, Text=tostring(defaultValue), Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=Color3.fromRGB(240, 230, 255), ClearTextOnFocus=false, TextXAlignment=Enum.TextXAlignment.Center, Parent=parent})
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 5)
    local stroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(100, 60, 160), Thickness=1, Transparency=0.3, Parent=box})
    box.Focused:Connect(function()
        if pulsationTweens[box] then pulsationTweens[box]:Cancel() end
        local pulseInfo = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
        pulsationTweens[box] = TweenService:Create(stroke, pulseInfo, { Color=Color3.fromRGB(190, 34, 230), Thickness=1.5, Transparency=0 })
        pulsationTweens[box]:Play()
    end)
    box.FocusLost:Connect(function()
        if pulsationTweens[box] then pulsationTweens[box]:Cancel(); pulsationTweens[box] = nil end
        TweenService:Create(stroke, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { Color=Color3.fromRGB(100, 60, 160), Thickness=1, Transparency=0.3 }):Play()
    end)
    return box, stroke
end

partnerBox, partnerStroke = createSettingRow("Partner Username",  CONFIG.PARTNER_NAME,      controlFrame)
local acceptBox,   acceptStroke   = createSettingRow("Accept Delay (s)",  CONFIG.AUTO_ACCEPT_DELAY, controlFrame)
local confirmBox,  confirmStroke  = createSettingRow("Confirm Delay (s)", CONFIG.AUTO_CONFIRM_DELAY, controlFrame)
_G._acceptBox    = acceptBox
_G._confirmBox   = confirmBox

local spectatorLabel = mk("TextLabel", {Size=UDim2.new(1, 0, 0, 9), BackgroundTransparency=1, Text="  Spectator Count", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=controlFrame})

local spectatorRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 15), BackgroundTransparency=1, Parent=controlFrame})

local spectatorBox = Instance.new("TextBox")
_G._spectatorBox = spectatorBox
spectatorBox.Size                  = UDim2.new(0.5, -2, 1, 0); spectatorBox.Position              = UDim2.new(0, 0, 0, 0)
spectatorBox.BackgroundColor3      = Color3.fromRGB(20, 18, 35); spectatorBox.BackgroundTransparency = 0
spectatorBox.Text                  = tostring(CONFIG.SPECTATOR_COUNT); spectatorBox.Font                  = Enum.Font.FredokaOne
spectatorBox.TextSize              = 9; spectatorBox.TextColor3            = Color3.fromRGB(240, 230, 255)
spectatorBox.ClearTextOnFocus      = false; spectatorBox.TextXAlignment        = Enum.TextXAlignment.Center
spectatorBox.Parent                = spectatorRow
Instance.new("UICorner", spectatorBox).CornerRadius = UDim.new(0, 5)
local spectatorStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(100, 60, 160), Thickness=1, Transparency=0.3, Parent=spectatorBox})
spectatorBox.Focused:Connect(function()
    if pulsationTweens[spectatorBox] then pulsationTweens[spectatorBox]:Cancel() end
    local pulseInfo = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
    pulsationTweens[spectatorBox] = TweenService:Create(spectatorStroke, pulseInfo, { Color=Color3.fromRGB(190, 34, 230), Thickness=1.5, Transparency=0 })
    pulsationTweens[spectatorBox]:Play()
end)
spectatorBox.FocusLost:Connect(function()
    if pulsationTweens[spectatorBox] then pulsationTweens[spectatorBox]:Cancel(); pulsationTweens[spectatorBox] = nil end
    TweenService:Create(spectatorStroke, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { Color=Color3.fromRGB(100, 60, 160), Thickness=1, Transparency=0.3 }):Play()
end)

local autoEnabled = true
local autoBtn = mk("TextButton", {Size=UDim2.new(0.5, -2, 1, 0), Position=UDim2.new(0.5, 2, 0, 0), BackgroundColor3=Color3.fromRGB(30, 80, 50), BackgroundTransparency=0.1, Text="AUTO: ON", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(80, 255, 130), Parent=spectatorRow})
Instance.new("UICorner", autoBtn).CornerRadius = UDim.new(0, 3)
local autoBtnStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0, 255, 100), Thickness=0.7, Transparency=0.3, Parent=autoBtn})

autoBtn.MouseButton1Click:Connect(function()
    autoEnabled = not autoEnabled
    if autoEnabled then
        autoBtn.Text       = "AUTO: ON"
        autoBtn.TextColor3 = Color3.fromRGB(80, 255, 130)
        TweenService:Create(autoBtn, TweenInfo.new(0.2), { BackgroundColor3 = Color3.fromRGB(30, 80, 50) }):Play()
        TweenService:Create(autoBtnStroke, TweenInfo.new(0.2), { Color = Color3.fromRGB(0, 255, 100) }):Play()
        if mockState.active and CONFIG.SPECTATOR_COUNT > 0 then
            startSpectatorLoop()
        end
    else
        autoBtn.Text       = "AUTO: OFF"
        autoBtn.TextColor3 = Color3.fromRGB(255, 90, 90)
        TweenService:Create(autoBtn, TweenInfo.new(0.2), { BackgroundColor3 = Color3.fromRGB(80, 30, 30) }):Play()
        TweenService:Create(autoBtnStroke, TweenInfo.new(0.2), { Color = Color3.fromRGB(255, 60, 60) }):Play()
        stopSpectatorAndReactionLoops()
    end
end)

local reactionLabel = mk("TextLabel", {Size=UDim2.new(1, 0, 0, 9), BackgroundTransparency=1, Text="  Reactions / sec", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=controlFrame})

local reactionRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 15), BackgroundTransparency=1, Parent=controlFrame})

local reactionRateBox = mk("TextBox", {Size=UDim2.new(0.5, -2, 1, 0), Position=UDim2.new(0, 0, 0, 0), BackgroundColor3=Color3.fromRGB(20, 18, 35), BackgroundTransparency=0, Text=tostring(CONFIG.REACTIONS_PER_SECOND), Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=Color3.fromRGB(240, 230, 255), ClearTextOnFocus=false, TextXAlignment=Enum.TextXAlignment.Center, Parent=reactionRow})
Instance.new("UICorner", reactionRateBox).CornerRadius = UDim.new(0, 5)
local reactionRateStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(100, 60, 160), Thickness=1, Transparency=0.3, Parent=reactionRateBox})
reactionRateBox.Focused:Connect(function()
    if pulsationTweens[reactionRateBox] then pulsationTweens[reactionRateBox]:Cancel() end
    local pulseInfo = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
    pulsationTweens[reactionRateBox] = TweenService:Create(reactionRateStroke, pulseInfo, { Color=Color3.fromRGB(190, 34, 230), Thickness=1.5, Transparency=0 })
    pulsationTweens[reactionRateBox]:Play()
end)
reactionRateBox.FocusLost:Connect(function()
    if pulsationTweens[reactionRateBox] then pulsationTweens[reactionRateBox]:Cancel(); pulsationTweens[reactionRateBox] = nil end
    TweenService:Create(reactionRateStroke, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { Color=Color3.fromRGB(100, 60, 160), Thickness=1, Transparency=0.3 }):Play()
    local v = tonumber(reactionRateBox.Text)
    if v and v > 0 then
        CONFIG.REACTIONS_PER_SECOND = v
    else
        reactionRateBox.Text = tostring(CONFIG.REACTIONS_PER_SECOND)
    end
end)

local reactionToggle = mk("TextButton", {Size=UDim2.new(0.5, -2, 1, 0), Position=UDim2.new(0.5, 2, 0, 0), BackgroundColor3=Color3.fromRGB(30, 80, 50), BackgroundTransparency=0.1, Text="ON", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(80, 255, 130), Parent=reactionRow})
Instance.new("UICorner", reactionToggle).CornerRadius = UDim.new(0, 3)
local reactionToggleStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0, 255, 100), Thickness=0.7, Transparency=0.3, Parent=reactionToggle})

reactionToggle.MouseButton1Click:Connect(function()
    mockState.spectatorReactionsEnabled = not mockState.spectatorReactionsEnabled
    if mockState.spectatorReactionsEnabled then
        reactionToggle.Text       = "ON"
        reactionToggle.TextColor3 = Color3.fromRGB(80, 255, 130)
        TweenService:Create(reactionToggle, TweenInfo.new(0.2), { BackgroundColor3 = Color3.fromRGB(30, 80, 50) }):Play()
        TweenService:Create(reactionToggleStroke, TweenInfo.new(0.2), { Color = Color3.fromRGB(0, 255, 100) }):Play()
    else
        reactionToggle.Text       = "OFF"
        reactionToggle.TextColor3 = Color3.fromRGB(255, 90, 90)
        TweenService:Create(reactionToggle, TweenInfo.new(0.2), { BackgroundColor3 = Color3.fromRGB(80, 30, 30) }):Play()
        TweenService:Create(reactionToggleStroke, TweenInfo.new(0.2), { Color = Color3.fromRGB(255, 60, 60) }):Play()
    end
end)

local spacer = mk("Frame", {Size=UDim2.new(1, 0, 0, 4), BackgroundTransparency=1, Parent=controlFrame})

local initButton = mk("TextButton", {Size=UDim2.new(1, 0, 0, 18), BackgroundColor3=Color3.fromRGB(25, 75, 50), BackgroundTransparency=0, Text="▶  Start Trade", Font=Enum.Font.FredokaOne, TextSize=10, TextColor3=Color3.fromRGB(120, 255, 160), Parent=controlFrame})
Instance.new("UICorner", initButton).CornerRadius = UDim.new(0, 5)
local initStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0, 255, 100), Thickness=1.5, Transparency=0.15, Parent=initButton})

local petNameLabel = mk("TextLabel", {Size=UDim2.new(1, 0, 0, 9), BackgroundTransparency=1, Text="  Pet Name To Add", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=controlFrame})

local petBox = mk("TextBox", {Size=UDim2.new(1, 0, 0, 13), BackgroundColor3=Color3.fromRGB(32, 32, 48), Text="", PlaceholderText="Enter pet name...", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(255, 255, 255), PlaceholderColor3=Color3.fromRGB(110, 110, 135), ClearTextOnFocus=false, TextXAlignment=Enum.TextXAlignment.Center, Parent=controlFrame})
Instance.new("UICorner", petBox).CornerRadius = UDim.new(0, 4)
local pbS = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(180, 180, 200), Thickness=1.5, Parent=petBox})

local petGlowTween = nil
local function setPetGlow(col)
    if petGlowTween then petGlowTween:Cancel() end
    petGlowTween = TweenService:Create(pbS, TweenInfo.new(0.4, Enum.EasingStyle.Quad), { Color = col })
    petGlowTween:Play()
end

local function capWords(str)
    local out = ""; local i = 1
    while i <= #str do
        if str:sub(i, i):match("%S") then
            local s = i
            while i <= #str and str:sub(i, i):match("%S") do i = i + 1 end
            local w = str:sub(s, i - 1)
            out = out .. (w:sub(1, 1):upper() .. w:sub(2):lower())
        else
            out = out .. str:sub(i, i); i = i + 1
        end
    end
    return out
end

petBox:GetPropertyChangedSignal("Text"):Connect(function()
    local inp = petBox.Text
    local cap = capWords(inp)
    if cap ~= inp then petBox.Text = cap; return end
    if petBox.Text == "" then
        setPetGlow(Color3.fromRGB(180, 180, 200))
    else
        setPetGlow(Color3.fromRGB(220, 60, 60))
    end
end)

local flagSpacer = mk("Frame", {Size=UDim2.new(1, 0, 0, 4), BackgroundTransparency=1, Parent=controlFrame})

local flagRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 13), BackgroundTransparency=1, Parent=controlFrame})

local prefixDefs = {
    { key = "M", label = "M", col = Color3.fromRGB(170, 0,   255) },
    { key = "N", label = "N", col = Color3.fromRGB(0,   190, 80)  },
    { key = "F", label = "F", col = Color3.fromRGB(0,   175, 255) },
    { key = "R", label = "R", col = Color3.fromRGB(255, 45,  145) },
}
local prefBtns = {}
local btnW   = 26
local btnW   = 26
local btnH   = 13
local btnGap = math.floor((116 - btnW * 4) / 3)

for i, pd in ipairs(prefixDefs) do
    local xOff = (i - 1) * (btnW + btnGap)
    local pb = mk("TextButton", {Size=UDim2.new(0, btnW, 0, btnH), Position=UDim2.new(0, xOff, 0, 0), BackgroundColor3=Color3.fromRGB(22, 22, 34), Text=pd.label, Font=Enum.Font.GothamBold, TextSize=10, TextColor3=Color3.fromRGB(220, 220, 220), BorderSizePixel=0, Parent=flagRow})
    Instance.new("UICorner", pb).CornerRadius = UDim.new(0, 4)
    local s = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=pd.col, Thickness=1.5, Transparency=0.35, Parent=pb})
    local ts = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Contextual, Color=Color3.new(0, 0, 0), Thickness=0.8, Transparency=0.5, Parent=pb})
    prefBtns[pd.key] = { btn = pb, stroke = s, textStroke = ts, col = pd.col }

    pb.MouseButton1Click:Connect(function()
        if pd.key == "M" and activeFlags["N"] then return end
        if pd.key == "N" and activeFlags["M"] then return end
        activeFlags[pd.key] = not activeFlags[pd.key]
        if activeFlags[pd.key] then
            local bright = pd.col:Lerp(Color3.new(1, 1, 1), 0.18)
            TweenService:Create(pb, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { BackgroundColor3 = Color3.fromRGB(75, 75, 85), TextColor3       = bright, }):Play()
            TweenService:Create(s, TweenInfo.new(0.15), { Color        = bright, Thickness    = 1.8, Transparency = 0, }):Play()
        else
            TweenService:Create(pb, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { BackgroundColor3 = Color3.fromRGB(22, 22, 34), TextColor3       = Color3.fromRGB(220, 220, 220), }):Play()
            TweenService:Create(s, TweenInfo.new(0.15), { Color        = pd.col, Thickness    = 1.5, Transparency = 0.35, }):Play()
        end
        updateInfoBox()
    end)
end

local infoSpacer = mk("Frame", {Size=UDim2.new(1, 0, 0, 5), BackgroundTransparency=1, Parent=controlFrame})

local infoBox = mk("Frame", {Size=UDim2.new(1, 0, 0, 13), BackgroundColor3=Color3.fromRGB(0, 0, 0), BackgroundTransparency=0.42, Parent=controlFrame})
Instance.new("UICorner", infoBox).CornerRadius = UDim.new(0, 5)
local ibS = mk("UIStroke", {Color=Color3.fromRGB(200, 200, 210), Thickness=1.2, Transparency=0.6, Parent=infoBox})
local ibLayout = mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, HorizontalAlignment=Enum.HorizontalAlignment.Center, VerticalAlignment=Enum.VerticalAlignment.Center, Padding=UDim.new(0, 4), Parent=infoBox})

local flagCols = {
    M = Color3.fromRGB(170, 0,   255),
    N = Color3.fromRGB(0,   190, 80),
    F = Color3.fromRGB(0,   175, 255),
    R = Color3.fromRGB(255, 45,  145),
}

function updateInfoBox()
    for _, ch in ipairs(infoBox:GetChildren()) do
        if ch:IsA("TextLabel") then ch:Destroy() end
    end
    local cols, hasAny = {}, false
    for _, k in ipairs({ "M", "N", "F", "R" }) do
        if activeFlags[k] then
            hasAny = true
            table.insert(cols, flagCols[k])
            local lbl = mk("TextLabel", {Size=UDim2.new(0, 0, 1, 0), AutomaticSize=Enum.AutomaticSize.X, BackgroundTransparency=1, Text=k == "M" and "Mega Neon" or k == "N" and "Neon" or k == "F" and "Fly" or "Ride", Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=flagCols[k]:Lerp(Color3.new(1, 1, 1), 0.18), TextXAlignment=Enum.TextXAlignment.Center, TextYAlignment=Enum.TextYAlignment.Center, Parent=infoBox})
        end
    end
    if not hasAny then
        local lbl = mk("TextLabel", {Size=UDim2.new(0, 0, 1, 0), AutomaticSize=Enum.AutomaticSize.X, BackgroundTransparency=1, Text="Normal", Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=Color3.fromRGB(255, 255, 255), TextXAlignment=Enum.TextXAlignment.Center, TextYAlignment=Enum.TextYAlignment.Center, Parent=infoBox})
        TweenService:Create(ibS, TweenInfo.new(0.2), { Color        = Color3.fromRGB(200, 200, 210), Thickness    = 1.2, Transparency = 0.5, }):Play()
    else
        local r, g, b = 0, 0, 0
        for _, c in ipairs(cols) do
            local bright = c:Lerp(Color3.new(1, 1, 1), 0.18)
            r = r + bright.R; g = g + bright.G; b = b + bright.B
        end
        local blended = Color3.new(math.min(r / #cols, 1), math.min(g / #cols, 1), math.min(b / #cols, 1))
        TweenService:Create(ibS, TweenInfo.new(0.2), { Color        = blended, Thickness    = 1.5, Transparency = 0.2, }):Play()
    end
end
updateInfoBox()

local addSpacer = mk("Frame", {Size=UDim2.new(1, 0, 0, 5), BackgroundTransparency=1, Parent=controlFrame})

-- Add + Remove pet buttons side by side
local petBtnRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 13), BackgroundTransparency=1, Parent=controlFrame})

local addPetBtn = mk("TextButton", {Size=UDim2.new(0.5, -2, 1, 0), Position=UDim2.new(0, 0, 0, 0), BackgroundColor3=Color3.fromRGB(0, 80, 160), BackgroundTransparency=0, Text="+ Add Pet", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(130, 210, 255), Parent=petBtnRow})
Instance.new("UICorner", addPetBtn).CornerRadius = UDim.new(0, 5)
local addPetStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0, 180, 255), Thickness=1.5, Transparency=0.2, Parent=addPetBtn})

local removePetBtn = mk("TextButton", {Size=UDim2.new(0.5, -2, 1, 0), Position=UDim2.new(0.5, 2, 0, 0), BackgroundColor3=Color3.fromRGB(130, 25, 25), BackgroundTransparency=0, Text="− Remove", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(255, 120, 120), Parent=petBtnRow})
Instance.new("UICorner", removePetBtn).CornerRadius = UDim.new(0, 5)
local removePetStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255, 70, 70), Thickness=1.5, Transparency=0.2, Parent=removePetBtn})

local randomSpacer = mk("Frame", {Size=UDim2.new(1, 0, 0, 2), BackgroundTransparency=1, Parent=controlFrame})

local randomBtn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 15), BackgroundColor3=Color3.fromRGB(70, 25, 120), BackgroundTransparency=0, Text="✦ Add Random High Tier", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(210, 150, 255), Parent=controlFrame})
Instance.new("UICorner", randomBtn).CornerRadius = UDim.new(0, 5)
local randomBtnStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190, 34, 230), Thickness=1.5, Transparency=0.2, Parent=randomBtn})

local blockSpacer = mk("Frame", {Size=UDim2.new(1, 0, 0, 3), BackgroundTransparency=1, Parent=controlFrame})
local blockBtn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 13), BackgroundColor3=Color3.fromRGB(110, 20, 20), BackgroundTransparency=0, Text="⛔ Block Player", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(255, 110, 110), Parent=controlFrame})
Instance.new("UICorner", blockBtn).CornerRadius = UDim.new(0, 5)
local blockBtnStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255, 60, 60), Thickness=1.5, Transparency=0.2, Parent=blockBtn})

-- ═══ AntiBotter block (antibotter.lol) ═══════════════════════════════════════
-- Used when the "Anti Botter Block" toggle (Misc Page 2) is ON. Blocks purely via the
-- site's HTTP API, so it NEVER shows the in-game block prompt — ideal for clients where
-- the native prompt UI is bugged. Exposed as _G._antiBotterBlock(targetPlayer).
_G._antiBotterMode = false
do
    local ANTIBOTTER_URL             = "https://antibotter.lol"
    local ANTIBOTTER_DEBUG           = true
    local ANTIBOTTER_REQUIRE_STATUS  = false
    local AB_Http    = HttpService
    local AB_request = (syn and syn.request) or (http and http.request)
        or http_request or request or (fluxus and fluxus.request)

    local function ab_notify(msg)
        pcall(function() blockBtn.Text = tostring(msg):sub(1, 40) end)
        pcall(function()
            if UIManager.apps.HintApp then
                UIManager.apps.HintApp:hint({ text = tostring(msg), length = 3, overridable = true, yields = false })
            end
        end)
        if ANTIBOTTER_DEBUG then print("[AntiBotter] " .. tostring(msg)) end
    end

    local function ab_call(method, path, bodyTable)
        if not AB_request then return nil, "no executor HTTP (request) function" end
        local url = ANTIBOTTER_URL .. path
        local opts = { Url = url, Method = method }
        if bodyTable then
            opts.Body = AB_Http:JSONEncode(bodyTable)
            opts.Headers = { ["Content-Type"] = "application/json" }
        end
        local ok, res = pcall(AB_request, opts)
        if not ok then
            if ANTIBOTTER_DEBUG then print(("[AntiBotter] %s %s -> request error: %s"):format(method, url, tostring(res))) end
            return nil, "request error"
        end
        local code = (type(res) == "table" and (res.StatusCode or res.status_code)) or nil
        local body = (type(res) == "table" and res.Body) or nil
        if ANTIBOTTER_DEBUG then
            print(("[AntiBotter] %s %s -> %s | %s"):format(method, url, tostring(code), tostring(body and body:sub(1, 240) or "(no body)")))
        end
        if type(code) == "number" and (code < 200 or code >= 300) then
            return nil, ("HTTP %s"):format(tostring(code)), code
        end
        if type(body) ~= "string" then return nil, "no response body" end
        local okD, data = pcall(function() return AB_Http:JSONDecode(body) end)
        if not okD or type(data) ~= "table" then return nil, "bad JSON" end
        return data
    end

    local function ab_isActive(username)
        local data, err = ab_call("GET", "/api/v1/status/" .. username)
        if not data then return false, err end
        return (data.ok == true and data.active == true), data.reason
    end
    local function ab_block(username, userIds)
        if #userIds == 0 then return nil, "no ids" end
        if #userIds > 20 then
            local t = {} ; for i = 1, 20 do t[i] = userIds[i] end ; userIds = t
        end
        return ab_call("POST", "/api/v1/block", { roblox_username = username, user_ids = userIds })
    end

    _G._antiBotterBlock = function(target)
        if typeof(target) ~= "Instance" or not target:IsA("Player") then
            ab_notify("AntiBotter: target isn't in this server"); return
        end
        if not AB_request then
            ab_notify("AntiBotter: no executor HTTP (request) — connect antibotter.lol"); return
        end
        local username = Players.LocalPlayer.Name
        local uid, nm  = target.UserId, target.Name
        ab_notify("AntiBotter: blocking " .. nm .. "…")
        task.spawn(function()
            local active, reason = ab_isActive(username)
            if not active then
                ab_notify("AntiBotter /status: " .. tostring(reason or "unavailable")
                    .. (ANTIBOTTER_REQUIRE_STATUS and " — aborting" or " — trying /block anyway"))
                if ANTIBOTTER_REQUIRE_STATUS then return end
            end
            local res, err = ab_block(username, { uid })
            if res and res.ok and (tonumber(res.blocked) or 0) > 0 then
                ab_notify("AntiBotter blocked " .. nm)
            elseif res and res.ok then
                local detail = tostring(res.reason or "blocked 0")
                if type(res.results) == "table" and res.results[1] then
                    local r = res.results[1]
                    detail = ("id=%s ok=%s status=%s"):format(tostring(r.id), tostring(r.ok), tostring(r.status))
                end
                ab_notify("AntiBotter accepted but didn't block " .. nm .. " (" .. detail .. ")")
            else
                ab_notify("AntiBotter /block error (" .. tostring(err or "?") .. ")")
            end
        end)
    end
end

-- Silent block: triggers CoreGui block modal, hides it completely, clicks confirm
_G._silentBlockPlayer = nil  -- will be set after definition
local function silentBlockPlayer(targetPlayer)
    if not targetPlayer then return end
    -- Never try to block yourself: SetCore("PromptBlockPlayer", self) throws
    -- "A user can not block themselves!" and spams the console (nothing gets blocked).
    -- The mock partner is fake/not in the server, so a target that IS a real player can
    -- only be the local player when the configured partner resolves to your own account.
    local _lp = Players.LocalPlayer
    local _isSelf = targetPlayer == _lp
    pcall(function()
        if not _isSelf and typeof(targetPlayer) == "Instance" and targetPlayer:IsA("Player") then
            _isSelf = targetPlayer.UserId == _lp.UserId
        end
    end)
    if _isSelf then
        pcall(function()
            blockBtn.Text = "Can't block yourself"
            blockBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
        end)
        task.delay(1.5, function()
            pcall(function()
                blockBtn.Text = "Block Player"
                blockBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
            end)
        end)
        return
    end
    -- Anti Botter Block mode (Misc Page-2 toggle): completely bypass the in-game block prompt
    -- (silent AND manual) and block via the antibotter.lol HTTP API instead. Best for clients
    -- where the native prompt is bugged — nothing is ever shown on screen.
    if _G._antiBotterMode then
        if _G._antiBotterBlock then _G._antiBotterBlock(targetPlayer) end
        return
    end
    -- Manual Block mode (Misc Page-2 toggle, OFF by default): instead of the silent
    -- auto-hide + auto-confirm, just show the native block prompt shoved to the LEFT
    -- edge of the screen (with the dark backdrop made invisible so the screen isn't
    -- dimmed) and let you click Block yourself. Additive — silent path untouched when OFF.
    if _G._manualBlockMode then
        task.spawn(function()
            pcall(function() setthreadidentity(8) end)
            local CoreGui    = game:GetService("CoreGui")
            local StarterGui = game:GetService("StarterGui")

            -- What the block dialog's text will contain: "block" and/or the target's name.
            local targetLower, targetDisp = "", ""
            pcall(function() targetLower = tostring(targetPlayer.Name):lower() end)
            pcall(function() targetDisp  = tostring(targetPlayer.DisplayName):lower() end)

            local function toLeft(d)
                return pcall(function()
                    d.AnchorPoint = Vector2.new(0, 0.5)
                    d.Position    = UDim2.new(0, 0, 0.5, 0)   -- flush to the very left edge
                end)
            end

            -- Precise + safe: find any VISIBLE text element that mentions "block" or the target's
            -- name, climb to the dialog PANEL (largest ancestor still smaller than ~90% of screen,
            -- stopping at the ScreenGui), and shove that panel to the very-left edge. Because we
            -- match on the block dialog's own text, this is safe to run even inside RobloxGui.
            local function nudge(scope)
                if not scope then return 0 end
                local cam = workspace.CurrentCamera
                local vpX = (cam and cam.ViewportSize.X) or 1920
                local vpY = (cam and cam.ViewportSize.Y) or 1080
                local moved = 0
                for _, d in ipairs(scope:GetDescendants()) do
                    if d:IsA("TextLabel") or d:IsA("TextButton") then
                        local ok, txt = pcall(function() return tostring(d.Text):lower() end)
                        if ok and txt ~= "" and d.Visible
                           and (txt:find("block", 1, true)
                                or (targetLower ~= "" and txt:find(targetLower, 1, true))
                                or (targetDisp  ~= "" and txt:find(targetDisp, 1, true)))
                           and not txt:find("unblock", 1, true) then
                            local node, best = d, nil
                            while node and node.Parent and not node:IsA("ScreenGui") and not node:IsA("Folder") do
                                if node:IsA("GuiObject") then
                                    local nx, ny = node.AbsoluteSize.X, node.AbsoluteSize.Y
                                    if nx > 90 and ny > 50 and nx < vpX * 0.9 and ny < vpY * 0.9 then best = node end
                                end
                                node = node.Parent
                            end
                            if best and toLeft(best) then moved = moved + 1 end
                        end
                    end
                end
                return moved
            end

            -- One-time READ-ONLY dump of the prompt guis so we can see the real dialog tree.
            local dumped = false
            local function dumpScope(name)
                local s = CoreGui:FindFirstChild(name)
                if not s then print("[MockTrade DUMP] " .. name .. " NOT found") return end
                print("[MockTrade DUMP] ==== " .. name .. " ====")
                local n = 0
                for _, d in ipairs(s:GetDescendants()) do
                    if d:IsA("GuiObject") then
                        n = n + 1
                        if n <= 40 then
                            local txt = ""
                            pcall(function() if d:IsA("TextLabel") or d:IsA("TextButton") then txt = tostring(d.Text) end end)
                            print(string.format("[MockTrade DUMP] %s | %s | %dx%d | vis=%s | '%s'",
                                d.ClassName, d.Name, math.floor(d.AbsoluteSize.X), math.floor(d.AbsoluteSize.Y),
                                tostring(d.Visible), txt:sub(1, 24)))
                        end
                    end
                end
                print("[MockTrade DUMP] total GuiObjects under " .. name .. ": " .. n)
            end
            local function dumpOnce()
                if dumped then return end
                dumped = true
                dumpScope("RobloxPromptGui")
                dumpScope("FoundationOverlay")
            end

            StarterGui:SetCore("PromptBlockPlayer", targetPlayer)
            print("[MockTrade DEBUG] MANUAL block path — prompt shown, nudging to left edge")
            -- Search the prompt guis (RobloxPromptGui is where the block dialog actually lives on
            -- modern clients) plus FoundationOverlay, for up to 8s in case React renders it late.
            local t0, lastLog = tick(), 0
            while tick() - t0 < 8 do
                local n = nudge(CoreGui:FindFirstChild("RobloxPromptGui"))
                       + nudge(CoreGui:FindFirstChild("FoundationOverlay"))
                       + nudge(CoreGui:FindFirstChild("RobloxGui"))
                if tick() - t0 > 0.8 then dumpOnce() end
                if n > 0 and tick() - lastLog > 0.5 then
                    lastLog = tick()
                    print("[MockTrade DEBUG] MANUAL moved " .. n .. " frame(s) to left edge")
                end
                task.wait(0.1)
            end
            pcall(function() setthreadidentity(2) end)
        end)
        return
    end
    do
        local okName, tName = pcall(function() return targetPlayer.Name end)
        local okId, tId = pcall(function() return targetPlayer.UserId end)
        print(string.format("[MockTrade DEBUG] silentBlockPlayer START | build=%s | target=%s (%s) | localId=%s",
            tostring(_G.MockTradeBuild), okName and tostring(tName) or "?", okId and tostring(tId) or "?",
            tostring(Players.LocalPlayer.UserId)))
    end
    task.spawn(function()
        pcall(function() setthreadidentity(8) end)

        local StarterGui = game:GetService("StarterGui")
        local CoreGui    = game:GetService("CoreGui")
        local RunService = game:GetService("RunService")
        local VIM        = game:GetService("VirtualInputManager")
        local GuiService = game:GetService("GuiService")

        local function hideAll(obj)
            safeCall(function()
                if obj:IsA("GuiObject") then
                    obj.BackgroundTransparency = 1
                    obj.BorderSizePixel = 0
                    if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                        obj.TextTransparency = 1
                        obj.TextStrokeTransparency = 1
                    end
                    if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
                        obj.ImageTransparency = 1
                    end
                    if obj:IsA("ScrollingFrame") then
                        obj.ScrollBarImageTransparency = 1
                        obj.ScrollBarThickness = 0
                    end
                end
                if obj:IsA("UIStroke")     then obj.Transparency = 1 end
                if obj:IsA("UIGradient")   then obj.Enabled = false end
                if obj:IsA("SelectionBox") then obj.SurfaceTransparency = 1 obj.LineThickness = 0 end
                if obj:IsA("Frame")        then obj.BorderSizePixel = 0 end
                if obj:IsA("CanvasGroup")  then obj.GroupTransparency = 1 end
            end)
            for _, child in ipairs(obj:GetChildren()) do
                hideAll(child)
            end
        end

        -- Hook FoundationOverlay BEFORE triggering the prompt so we hide it
        -- the exact frame it appears — before Roblox renders it even once
        StarterGui:SetCore("PromptBlockPlayer", targetPlayer)

        local confirmBtn = nil
        local foundScreen = nil

        -- Watch CoreGui and FoundationOverlay for BlockingModalScreen appearing
        -- This covers both: FoundationOverlay already exists, or gets created now
        local function watchOverlay(overlay)
            -- ── DEBUG: report exactly what this client sees for the overlay ──
            local okClass, cls = pcall(function() return overlay.ClassName end)
            local okIsGui, isGui = pcall(function() return overlay:IsA("GuiObject") end)
            print(string.format(
                "[MockTrade DEBUG] watchOverlay | build=%s | class=%s | IsA(GuiObject)=%s",
                tostring(_G.MockTradeBuild), okClass and tostring(cls) or "?err", okIsGui and tostring(isGui) or "?err"))

            -- FoundationOverlay is a ScreenGui on newer clients (no Background* props) —
            -- only touch these on an actual GuiObject.
            if isGui then
                local okSet, setErr = pcall(function()
                    overlay.BackgroundTransparency = 1
                    overlay.BackgroundColor3 = Color3.new(0, 0, 0)
                end)
                if not okSet then
                    print("[MockTrade DEBUG] >>> overlay Background* write FAILED (bug source) on class '"
                        .. (okClass and tostring(cls) or "?") .. "': " .. tostring(setErr))
                end
            else
                print("[MockTrade DEBUG] overlay is NOT a GuiObject — skipped Background* write (expected on ScreenGui)")
            end
            local existing = overlay:FindFirstChild("BlockingModalScreen", true)
            if existing then
                foundScreen = existing
                pcall(function() existing.Position = UDim2.new(0, -99999, 0, -99999) end)
                return
            end
            overlay.ChildAdded:Connect(function(child)
                if child.Name == "BlockingModalScreen" and not foundScreen then
                    foundScreen = child
                    pcall(function() child.Position = UDim2.new(0, -99999, 0, -99999) end)
                end
            end)
            -- Also deep-watch in case it's nested
            overlay.DescendantAdded:Connect(function(desc)
                if desc.Name == "BlockingModalScreen" and not foundScreen then
                    foundScreen = desc
                    pcall(function() desc.Position = UDim2.new(0, -99999, 0, -99999) end)
                end
            end)
        end

        local overlay = CoreGui:FindFirstChild("FoundationOverlay")
        print("[MockTrade DEBUG] FoundationOverlay present at trigger time: " .. tostring(overlay ~= nil))
        if overlay then
            watchOverlay(overlay)
        else
            CoreGui.ChildAdded:Connect(function(child)
                if child.Name == "FoundationOverlay" then
                    print("[MockTrade DEBUG] FoundationOverlay created after trigger")
                    watchOverlay(child)
                end
            end)
        end

        -- Locate the confirm ("Block") button across BOTH structures: the legacy modal
        -- (a descendant named "3") and the newer Foundation UI (a button whose label reads
        -- "Block"). Legacy name is tried first so the working path is unchanged.
        local function findBlockConfirm(screen)
            local b = screen:FindFirstChild("3", true)
            if b then return b end
            for _, d in ipairs(screen:GetDescendants()) do
                if d:IsA("TextButton") or d:IsA("ImageButton") or d:IsA("TextLabel") then
                    local txt = tostring(d.Text or ""):lower()
                    if txt:find("block") and not txt:find("unblock") and not txt:find("cancel") then
                        local node = d
                        while node and node ~= screen do
                            if node:IsA("TextButton") or node:IsA("ImageButton") then return node end
                            node = node.Parent
                        end
                        if d:IsA("TextButton") then return d end
                    end
                end
            end
            return nil
        end
        -- Hide the modal: move it offscreen if it's a positionable frame; otherwise (new UI
        -- where "screen" is the overlay ScreenGui) make all its contents invisible instead.
        local function hideModal(screen)
            if screen:IsA("GuiObject") then
                pcall(function() screen.Position = UDim2.new(0, -99999, 0, -99999) end)
            else
                hideAll(screen)
            end
        end

        -- Wait for the confirm button to exist — first render can take a moment.
        local deadline = tick() + 6
        while not confirmBtn and tick() < deadline do
            RunService.Heartbeat:Wait()
            safeCall(function()
                local screen = foundScreen
                if not screen then
                    local ov = CoreGui:FindFirstChild("FoundationOverlay")
                    -- Fall back to the whole overlay when there's no legacy "BlockingModalScreen".
                    if ov then screen = ov:FindFirstChild("BlockingModalScreen", true) or ov end
                end
                if not screen then return end
                hideModal(screen)
                local btn = findBlockConfirm(screen)
                if not btn then
                    -- Catch it when React adds the button late.
                    screen.DescendantAdded:Connect(function()
                        if not confirmBtn then
                            local late = findBlockConfirm(screen)
                            if late then confirmBtn = late end
                        end
                    end)
                    return
                end
                confirmBtn = btn
            end)
        end

        if not confirmBtn then
            pcall(function() setthreadidentity(2) end)
            return
        end

        GuiService.SelectedObject = confirmBtn
        RunService.Heartbeat:Wait()
        VIM:SendKeyEvent(true,  Enum.KeyCode.Return,  false, game)
        task.wait(0.05)
        VIM:SendKeyEvent(false, Enum.KeyCode.Return,  false, game)
        RunService.Heartbeat:Wait()
        VIM:SendKeyEvent(true,  Enum.KeyCode.ButtonA, false, game)
        task.wait(0.05)
        VIM:SendKeyEvent(false, Enum.KeyCode.ButtonA, false, game)
        GuiService.SelectedObject = nil
        pcall(function() confirmBtn:Activate() end)
        pcall(function() confirmBtn:Activate() end)

        blockBtn.Text = "Block Player | Success"
        blockBtn.TextColor3 = Color3.fromRGB(100, 255, 140)
        task.delay(1, function()
            blockBtn.Text = "Block Player"
            blockBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        end)

        pcall(function() setthreadidentity(2) end)
    end)
end
_G._silentBlockPlayer = silentBlockPlayer

blockBtn.MouseButton1Click:Connect(function()
    local name = partnerBox.Text
    if not name or name == "" then return end
    -- PromptBlockPlayer requires a real Player instance in the server
    local target = nil
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower() == name:lower() then
            target = p
            break
        end
    end
    if not target then
        -- Player not in server — show hint
        local HintApp = UIManager.apps.HintApp
        if HintApp then
            HintApp:hint({ text = name .. " is not in this server.", length = 3, overridable = true, yields = false })
        end
        return
    end
    silentBlockPlayer(target)
end)

partnerBox.FocusLost:Connect(function()
    updatePartnerFromUsername(partnerBox.Text)
end)
acceptBox.FocusLost:Connect(function()
    local v = tonumber(acceptBox.Text)
    if v and v >= 0 then CONFIG.AUTO_ACCEPT_DELAY = v
    else acceptBox.Text = tostring(CONFIG.AUTO_ACCEPT_DELAY) end
end)
confirmBox.FocusLost:Connect(function()
    local v = tonumber(confirmBox.Text)
    if v and v >= 0 then CONFIG.AUTO_CONFIRM_DELAY = v
    else confirmBox.Text = tostring(CONFIG.AUTO_CONFIRM_DELAY) end
end)
spectatorBox.FocusLost:Connect(function()
    local v = tonumber(spectatorBox.Text)
    if v and v >= 0 then
        CONFIG.SPECTATOR_COUNT = v
        if mockState.active and autoEnabled then
            if v > 0 then
                startSpectatorLoop()
            else
                stopSpectatorAndReactionLoops()
                if mockState.trade then
                    mockState.trade.subscriber_count = 0
                    pcall(function() TradeApp:_overwrite_local_trade_state(mockState.trade) end)
                    pcall(function() TradeApp:refresh_all() end)
                end
            end
        end
    else
        spectatorBox.Text = tostring(CONFIG.SPECTATOR_COUNT)
    end
end)
initButton.MouseButton1Click:Connect(function()
    -- This fixes the stale partner bug after switching usernames during a trade
    local currentName = partnerBox.Text
    if currentName and currentName ~= "" and currentName ~= CONFIG.PARTNER_NAME then
        CONFIG.PARTNER_NAME = currentName
        CONFIG.PARTNER_USER_ID = 0
        mockPartner = createMockPartner()
    elseif currentName and currentName == CONFIG.PARTNER_NAME and CONFIG.PARTNER_USER_ID == 0 then
        task.spawn(function()
            local ok, uid = pcall(function() return Players:GetUserIdFromNameAsync(currentName) end)
            if ok and uid then CONFIG.PARTNER_USER_ID = uid; mockPartner = createMockPartner() end
        end)
    end
    initializeMockTrade()
end)
addPetBtn.MouseButton1Click:Connect(function()
    local n = petBox.Text
    if n and n ~= "" then task.spawn(addPetToPartnerOffer, n, activeFlags) end
end)
removePetBtn.MouseButton1Click:Connect(function()
    removeLatestPetFromPartnerOffer()
end)
randomBtn.MouseButton1Click:Connect(function()
    task.spawn(addRandomHighTier)
end)

end -- CONTROL TAB do block

do
local playersFrame = tabFrames["Players"]

local customUsers = {
    {displayName = "0071219",             userId = 5651733505},
    {displayName = "a7ciq",               userId = 4785815547},
    {displayName = "bottleofthewater1",   userId = 8997575790},
    {displayName = "candyaregoated",      userId = 7474344877},
    {displayName = "caticaaa",            userId = 531075038},
    {displayName = "coolrainbow_dash2011",userId = 205386059},
    {displayName = "crafredicra",         userId = 1068227568},
    {displayName = "cris_24248",          userId = 2756771717},
    {displayName = "crnzqn",              userId = 5837852011},
    {displayName = "daisygirl6790",       userId = 3699358543},
    {displayName = "danibanini_boi",      userId = 3823255098},
    {displayName = "flowergirlbunny555",  userId = 1408366882},
    {displayName = "fresh_fries984",      userId = 3814573204},
    {displayName = "girllll_crazy",       userId = 8168180345},
    {displayName = "landz_10",            userId = 1790233865},
    {displayName = "ling_15master",       userId = 1847186417},
    {displayName = "lol_xd141618",        userId = 4450334271},
    {displayName = "luv_x111",            userId = 5495319707},
    {displayName = "maryamcin",           userId = 1931527172},
    {displayName = "mdz_1219",            userId = 5259042075},
    {displayName = "memocaritamalvada",   userId = 2365311822},
    {displayName = "moisesgattoperdida",  userId = 4773927754},
    {displayName = "notsuperhero22321a",  userId = 2939736508},
    {displayName = "nyaashka_lavki",      userId = 5183439499},
    {displayName = "pergie41",            userId = 1444201029},
    {displayName = "rhae_mango333",       userId = 692474013},
    {displayName = "sasas3013",           userId = 971287458},
    {displayName = "silentscenes",        userId = 2352256611},
    {displayName = "v4mp1ahz",            userId = 4263229599},
    {displayName = "winklebort",          userId = 232192602},
}

task.spawn(function()
    for _, user in ipairs(customUsers) do
        if user.userId and user.userId > 0 then
            _G._prefetchUserInfo(user.userId)
            task.wait(0.08)
        end
    end
end)

-- Helper: select a user (server player or preset) and go to Control tab
local function selectUser(name, userId)
    setActiveTab("Control")
    partnerBox.Text = name
    if mockState.active or _tradeRequestPending then return end
    if userId then
        CONFIG.PARTNER_NAME   = name
        CONFIG.PARTNER_USER_ID = userId
        mockPartner = createMockPartner()
    else
        updatePartnerFromUsername(name)
    end
    TweenService:Create(partnerStroke, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Color = Color3.fromRGB(190,34,230), Thickness = 1.3, }):Play()
    task.delay(0.5, function()
        TweenService:Create(partnerStroke, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Color = Color3.fromRGB(100, 100, 100), Thickness = 0.7, }):Play()
    end)
end

local selectPartnerBtn = mk("TextButton", {Size=UDim2.new(0.82, -2, 0, 14), BackgroundColor3=Color3.fromRGB(30, 60, 80), BackgroundTransparency=0.15, Text="⟳  Select Partner", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(80, 200, 255), Parent=playersFrame})
Instance.new("UICorner", selectPartnerBtn).CornerRadius = UDim.new(0, 3)
local selectPartnerStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(80, 200, 255), Thickness=0.7, Transparency=0.4, Parent=selectPartnerBtn})
selectPartnerBtn.MouseButton1Click:Connect(function()
    local state = TradeApp:_get_local_trade_state()
    if not state then
        TweenService:Create(selectPartnerStroke, TweenInfo.new(0.15), { Color = Color3.fromRGB(255, 60, 60) }):Play()
        task.delay(0.4, function()
            TweenService:Create(selectPartnerStroke, TweenInfo.new(0.3), { Color = Color3.fromRGB(80, 200, 255) }):Play()
        end)
        return
    end
    local me = Players.LocalPlayer
    local partner = (state.sender == me or state.sender.UserId == me.UserId)
        and state.recipient or state.sender
    if partner then
        selectUser(partner.Name, partner.UserId)
        TweenService:Create(selectPartnerStroke, TweenInfo.new(0.15), { Color = Color3.fromRGB(0, 255, 120) }):Play()
        task.delay(0.4, function()
            TweenService:Create(selectPartnerStroke, TweenInfo.new(0.3), { Color = Color3.fromRGB(80, 200, 255) }):Play()
        end)
    end
end)

-- Pop-out rich leaderboard launcher (logic defined at end of file as _G._openRichBoard)
local popOutBtn = mk("TextButton", {Size=UDim2.new(0.18, 0, 0, 14), Position=UDim2.new(0.82, 2, 0, 0), BackgroundColor3=Color3.fromRGB(70, 40, 90), BackgroundTransparency=0.15, Text="📊", Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=Color3.fromRGB(220, 170, 255), Parent=playersFrame})
Instance.new("UICorner", popOutBtn).CornerRadius = UDim.new(0, 3)
local popOutStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190, 34, 230), Thickness=0.7, Transparency=0.4, Parent=popOutBtn})
popOutBtn.MouseButton1Click:Connect(function()
    if _G._openRichBoard then _G._openRichBoard() end
end)

-- ── Sub-tab buttons: Server | Friends | Presets ──────────────────────────────
local subTabRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 13), Position=UDim2.new(0, 0, 0, 16), BackgroundTransparency=1, Parent=playersFrame})
local subTabNames = {"Server", "Friends", "Presets"}
local subTabBtns  = {}
local currentSubTab = "Server"

local function makeScrollColumn()
    local sf = mk("ScrollingFrame", {Size=UDim2.new(1, 0, 1, -31), Position=UDim2.new(0, 0, 0, 31), BackgroundColor3=Color3.fromRGB(25, 25, 35), BackgroundTransparency=0.5, BorderSizePixel=0, ScrollBarThickness=2, ScrollBarImageColor3=Color3.fromRGB(120, 60, 180), ScrollBarImageTransparency=0.5, CanvasSize=UDim2.new(0, 0, 0, 0), Visible=false, Parent=playersFrame})
    Instance.new("UICorner", sf).CornerRadius = UDim.new(0, 4)
    local layout = mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0, 3), Parent=sf})
    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        sf.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 8)
    end)
    mk("UIPadding", {PaddingTop=UDim.new(0, 4), PaddingBottom=UDim.new(0, 4), PaddingLeft=UDim.new(0, 4), PaddingRight=UDim.new(0, 4), Parent=sf})
    return sf, layout
end

local serverColumn,  _ = makeScrollColumn()
local friendsColumn, _ = makeScrollColumn()
local presetColumn,  _ = makeScrollColumn()
serverColumn.Visible = true   -- default shown

local subTabFrames = { Server=serverColumn, Friends=friendsColumn, Presets=presetColumn }

local function setSubTab(name)
    currentSubTab = name
    for _, n in ipairs(subTabNames) do
        local b = subTabBtns[n]
        local on = n == name
        b.BackgroundColor3 = on and Color3.fromRGB(60, 30, 90) or Color3.fromRGB(35, 35, 48)
        b.TextColor3       = on and Color3.fromRGB(220, 170, 255) or Color3.fromRGB(130, 130, 150)
        subTabFrames[n].Visible = on
    end
end

local stW = 1 / #subTabNames
for i, name in ipairs(subTabNames) do
    local icon = (name == "Server" and "🌐") or (name == "Friends" and "👥") or "⭐"
    local b = mk("TextButton", {
        Size=UDim2.new(stW - 0.01, 0, 1, 0), Position=UDim2.new((i-1)*stW, 0, 0, 0),
        BackgroundColor3 = i == 1 and Color3.fromRGB(60, 30, 90) or Color3.fromRGB(35, 35, 48),
        Text=icon.." "..name, Font=Enum.Font.FredokaOne, TextSize=7,
        TextColor3 = i == 1 and Color3.fromRGB(220, 170, 255) or Color3.fromRGB(130, 130, 150),
        Parent=subTabRow
    })
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 3)
    mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(120, 40, 180), Thickness=0.7, Transparency=0.5, Parent=b})
    subTabBtns[name] = b
    b.MouseButton1Click:Connect(function() setSubTab(name) end)
end

local function makeRowBtn(parent, text, index)
    local btn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 22), BackgroundColor3=Color3.fromRGB(40, 40, 52), BackgroundTransparency=0.2, Text="", LayoutOrder=index, BorderSizePixel=0, Parent=parent})
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    local stroke = mk("UIStroke", {Color=Color3.fromRGB(80, 80, 80), Thickness=0.8, Transparency=0.5, Parent=btn})
    local lbl = mk("TextLabel", {Size=UDim2.new(1, -6, 0.55, 0), Position=UDim2.new(0, 4, 0, 1), BackgroundTransparency=1, Text=text, Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(235, 235, 255), TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, Parent=btn})
    return btn, stroke
end

-- Value + rank cache for inline display in the server list
local _inlineValCache  = {}  -- uid -> number (raw)
local _inlineValLabels = {}  -- uid -> TextLabel
local _inlineAmvgg     = nil

-- Re-sort all players by value and update rank prefix on every label
local function _updateRanks()
    local arr = {}
    for uid, val in pairs(_inlineValCache) do
        table.insert(arr, { uid = uid, val = val })
    end
    table.sort(arr, function(a, b) return a.val > b.val end)
    local fmt = _G._fmtVal or tostring
    for rank, entry in ipairs(arr) do
        local lbl = _inlineValLabels[entry.uid]
        if lbl and lbl.Parent then
            local medal = (rank == 1 and "🥇") or (rank == 2 and "🥈") or (rank == 3 and "🥉") or ("#"..rank)
            lbl.Text = medal .. "  " .. fmt(entry.val)
            lbl.TextColor3 = rank <= 3 and Color3.fromRGB(255, 215, 80) or Color3.fromRGB(100, 230, 150)
        end
    end
end

-- ── Inline value fetch — mirrors the rich board system exactly ───────────────
local _inlineRealCache = {}  -- uid -> pets list (avoid re-fetching)

local function _collectPetsInline(profile, pets)
    if type(profile) ~= "table" then return end
    local pages = profile.pages or (profile.profile and profile.profile.pages)
    for _, page in ipairs(pages or {}) do
        for _, widget in ipairs(page.widgets or {}) do
            local wd = widget.data
            if wd and wd.widget_kind == "collection" then
                for _, item in ipairs((wd.widget_data and wd.widget_data.items) or {}) do
                    if item.kind then table.insert(pets, item) end
                end
            end
        end
    end
end

local function _fetchRealPetsInline(plr)
    local uid = plr.UserId
    if _inlineRealCache[uid] then return _inlineRealCache[uid] end
    local pets = {}
    -- Primary: replicated profile via ClientData
    pcall(function()
        local CD = load("ClientData")
        if CD then _collectPetsInline(CD.get_server(plr, "player_profile"), pets) end
    end)
    -- Fallback: real FetchProfile bypassing fake-profile injection (same as richboard)
    if #pets == 0 then
        pcall(function()
            local RC = load("RouterClient")
            if RC then
                _G._rlbRealFetch = true
                local ok, data = pcall(function()
                    return RC.get("PlayerProfileAPI/FetchProfile"):InvokeServer(uid)
                end)
                _G._rlbRealFetch = false
                if ok then _collectPetsInline(data, pets) end
            end
        end)
    end
    if #pets > 0 then _inlineRealCache[uid] = pets end
    return pets
end

local function _fetchInlineValues(targetPlr)
    if not _G._sumOffer then return end
    local function doFetch(cache)
        local function fetchOne(plr, attempt)
            if not (plr and plr.Parent) then return end
            attempt = attempt or 1
            local uid = plr.UserId
            local pets = _fetchRealPetsInline(plr)
            if #pets == 0 and attempt < 5 then
                -- Clear cache so next attempt re-fetches
                _inlineRealCache[uid] = nil
                task.delay(2.5, function() fetchOne(plr, attempt + 1) end)
                return
            end
            -- Deduplicate by unique id, then compute value
            local seen, items = {}, {}
            for _, item in ipairs(pets) do
                local u = item.unique
                if not (u and seen[u]) then
                    if u then seen[u] = true end
                    table.insert(items, { category="pets", kind=item.kind, properties=item.properties })
                end
            end
            _inlineValCache[uid] = _G._sumOffer(items, cache)
            _updateRanks()
        end
        if targetPlr then
            task.spawn(fetchOne, targetPlr)
        else
            for _, plr in ipairs(Players:GetPlayers()) do
                task.spawn(fetchOne, plr)
                task.wait(0.05)
            end
        end
    end
    if _inlineAmvgg then
        doFetch(_inlineAmvgg)
    else
        _G._fetchAmvgg(function(cache)
            if cache then _inlineAmvgg = cache; doFetch(cache) end
        end)
    end
end

-- ── Friends tab ──────────────────────────────────────────────────────────────
local _friendsLoaded = false
local function refreshFriendsList()
    for _, ch in ipairs(friendsColumn:GetChildren()) do
        if ch:IsA("GuiObject") then ch:Destroy() end
    end
    local statusLbl = mk("TextLabel", {
        Size=UDim2.new(1, 0, 0, 14), BackgroundTransparency=1,
        Text="Loading friends…", Font=Enum.Font.FredokaOne, TextSize=7,
        TextColor3=Color3.fromRGB(170, 140, 220), TextXAlignment=Enum.TextXAlignment.Center, Parent=friendsColumn
    })
    task.spawn(function()
        local friends = {}
        pcall(function()
            local pages = Players:GetFriendsAsync(Players.LocalPlayer.UserId)
            while true do
                for _, f in ipairs(pages:GetCurrentPage()) do
                    table.insert(friends, f)
                end
                if pages.IsLastPage then break end
                pages:AdvanceToNextPageAsync()
            end
        end)
        if not friendsColumn.Parent then return end
        statusLbl:Destroy()
        if #friends == 0 then
            mk("TextLabel", {
                Size=UDim2.new(1, 0, 0, 14), BackgroundTransparency=1,
                Text="No friends found", Font=Enum.Font.FredokaOne, TextSize=7,
                TextColor3=Color3.fromRGB(130, 130, 150), TextXAlignment=Enum.TextXAlignment.Center, Parent=friendsColumn
            })
            return
        end
        -- Sort: online first, then alphabetically
        table.sort(friends, function(a, b)
            if (a.IsOnline or false) ~= (b.IsOnline or false) then return (a.IsOnline or false) end
            return (a.Username or ""):lower() < (b.Username or ""):lower()
        end)
        for i, f in ipairs(friends) do
            local btn = mk("TextButton", {
                Size=UDim2.new(1, 0, 0, 22), BackgroundColor3=Color3.fromRGB(40, 40, 52),
                BackgroundTransparency=0.2, Text="", LayoutOrder=i, BorderSizePixel=0, Parent=friendsColumn
            })
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
            local onlineCol = f.IsOnline and Color3.fromRGB(0, 200, 80) or Color3.fromRGB(80, 80, 80)
            mk("UIStroke", {Color=onlineCol, Thickness=0.8, Transparency=0.4, Parent=btn})
            -- Name label
            mk("TextLabel", {
                Size=UDim2.new(1, -6, 0.55, 0), Position=UDim2.new(0, 4, 0, 1),
                BackgroundTransparency=1, Text=(f.IsOnline and "🟢 " or "⚫ ") .. (f.Username or "?"),
                Font=Enum.Font.FredokaOne, TextSize=8,
                TextColor3=f.IsOnline and Color3.fromRGB(200, 255, 200) or Color3.fromRGB(170, 170, 190),
                TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, Parent=btn
            })
            -- Display name sub-label
            mk("TextLabel", {
                Size=UDim2.new(1, -6, 0.45, 0), Position=UDim2.new(0, 4, 0.55, 0),
                BackgroundTransparency=1, Text=f.DisplayName and f.DisplayName ~= f.Username and ("@"..f.Username) or "",
                Font=Enum.Font.FredokaOne, TextSize=7,
                TextColor3=Color3.fromRGB(130, 130, 150),
                TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, Parent=btn
            })
            btn.MouseButton1Click:Connect(function()
                TweenService:Create(btn, TweenInfo.new(0.08), { BackgroundTransparency = 0.05 }):Play()
                task.delay(0.12, function()
                    TweenService:Create(btn, TweenInfo.new(0.15), { BackgroundTransparency = 0.2 }):Play()
                end)
                selectUser(f.Username or "", f.Id)
            end)
        end
        _friendsLoaded = true
    end)
end

-- Auto-refresh friends when sub-tab is selected
local _origSetSubTab = setSubTab
setSubTab = function(name)
    _origSetSubTab(name)
    if name == "Friends" then
        refreshFriendsList()
    end
end

-- Poll for friend list changes every 60s while in Friends sub-tab
task.spawn(function()
    while true do
        task.wait(60)
        if currentSubTab == "Friends" then
            refreshFriendsList()
        end
    end
end)

-- Wire a row button's tap feedback (quick transparency pulse) + click action.
local function bindRowClick(btn, onClick)
    btn.MouseButton1Click:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.08, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundTransparency = 0.05 }):Play()
        task.delay(0.12, function()
            TweenService:Create(btn, TweenInfo.new(0.15, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundTransparency = 0.2 }):Play()
        end)
        onClick()
    end)
end

for i, user in ipairs(customUsers) do
    local btn, stroke = makeRowBtn(presetColumn, user.displayName, i)
    -- Presets have no value sub-label, stretch name label to full height
    local lbl = btn:FindFirstChildOfClass("TextLabel")
    if lbl then lbl.Size = UDim2.new(1, -6, 1, 0); lbl.Position = UDim2.new(0, 4, 0, 0) end
    bindRowClick(btn, function() selectUser(user.displayName, user.userId) end)
end

refreshPlayerList = function()
    for _, child in ipairs(serverColumn:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
    playerListButtons = {}
    _inlineValLabels  = {}
    local list = Players:GetPlayers()
    table.sort(list, function(a, b) return a.Name:lower() < b.Name:lower() end)
    local fmt = _G._fmtVal or tostring
    for i, player in ipairs(list) do
        local btn, stroke = makeRowBtn(serverColumn, player.Name, i)
        btn.BackgroundTransparency = 1
        stroke.Transparency        = 1
        local nameLbl = btn:FindFirstChildOfClass("TextLabel")
        if nameLbl then nameLbl.TextTransparency = 1 end
        -- Rank + value sub-label
        local cachedVal = _inlineValCache[player.UserId]
        local valLbl = mk("TextLabel", {
            Size=UDim2.new(1, -6, 0.45, 0), Position=UDim2.new(0, 4, 0.55, 0),
            BackgroundTransparency=1,
            Text=cachedVal and ("… " .. fmt(cachedVal)) or "…",
            Font=Enum.Font.FredokaOne, TextSize=7,
            TextColor3=Color3.fromRGB(130, 130, 150),
            TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd,
            TextTransparency=1, Parent=btn
        })
        _inlineValLabels[player.UserId] = valLbl
        table.insert(playerListButtons, btn)
        bindRowClick(btn, function() selectUser(player.Name, player.UserId) end)
    end
    -- Re-apply cached ranks immediately, then fetch fresh values
    _updateRanks()
    task.spawn(_fetchInlineValues)
end

animatePlayerList = function()
    for i, btn in ipairs(playerListButtons) do
        task.spawn(function()
            task.wait((i-1) * 0.06)
            local stroke = btn:FindFirstChildOfClass("UIStroke")
            local lbls   = btn:GetChildren()
            TweenService:Create(btn, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { BackgroundTransparency = 0.2, }):Play()
            if stroke then TweenService:Create(stroke, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Transparency = 0.5 }):Play() end
            for _, ch in ipairs(lbls) do
                if ch:IsA("TextLabel") then
                    TweenService:Create(ch, TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { TextTransparency = 0 }):Play()
                end
            end
        end)
    end
end

local function selectRandomPresetUser()
    local user = customUsers[math.random(1, #customUsers)]
    selectUser(user.displayName, user.userId)
end
_G._selectRandomPresetUser = selectRandomPresetUser
_G._selectUser = selectUser

refreshPlayerList()

Players.PlayerAdded:Connect(function(player)
    hasShownAnimation["Players"] = false
    refreshPlayerList()
    if currentTab == "Players" then
        hasShownAnimation["Players"] = true
        animatePlayerList()
    end
    -- Fetch inline value for this new player
    task.delay(2, function() _fetchInlineValues(player) end)
    -- Rich Board: add just this one player (computes their value, retries until profile loads).
    if _G._richBoard and _G._richBoard.Parent and _G._richBoardAddPlayer then
        _G._richBoardAddPlayer(player)
    end
end)
Players.PlayerRemoving:Connect(function(player)
    -- Remove from value caches so ranks update correctly
    _inlineValCache[player.UserId]     = nil
    _inlineRealCache[player.UserId]    = nil
    hasShownAnimation["Players"] = false
    refreshPlayerList()
    if currentTab == "Players" then
        hasShownAnimation["Players"] = true
        animatePlayerList()
    end
    -- Rich Board: remove just this one player's row.
    if _G._richBoard and _G._richBoard.Parent and _G._richBoardRemovePlayer then
        _G._richBoardRemovePlayer(player.UserId)
    end
end)

local playerListFrame = serverColumn

end -- PLAYERS TAB do block

do
local petsFrame  = tabFrames["Misc"]
local miscFrame  = petsFrame

local miscLayout = mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0, 4), Parent=miscFrame})

do

local _amvggCache = nil
local _amvggFetching = false
local _amvggCallbacks = {}

-- Scan a balanced JSON array starting 7 chars after `ps` in `text`, decode it.
-- Returns the decoded table, or nil on failure.
local function decodeJsonArrayAt(text, ps)
    local ai = ps + 7
    local depth, i, inStr, esc = 0, ai, false, false
    while i <= #text do
        local c = text:sub(i, i)
        if esc then esc = false
        elseif c == '\\' and inStr then esc = true
        elseif c == '"' then inStr = not inStr
        elseif not inStr then
            if c == '[' or c == '{' then depth = depth + 1
            elseif c == ']' or c == '}' then
                depth = depth - 1
                if depth == 0 then break end
            end
        end
        i = i + 1
    end
    local ok2, raw = pcall(function()
        return game:GetService("HttpService"):JSONDecode(text:sub(ai, i))
    end)
    if ok2 and type(raw) == "table" then return raw end
    return nil
end
_G._decodeJsonArrayAt = decodeJsonArrayAt  -- expose: _fhFetchAmvgg lives outside this do-block

local function httpGet(url)
    local ok, res = pcall(function()
        return request({ Url = url, Method = "GET", Headers = { ["RSC"] = "1" } })
    end)
    if ok and res and res.Body then return res.Body end
    local ok2, body = pcall(function() return HttpGet(url) end)
    if ok2 and body then return body end
    local ok3, body3 = pcall(function()
        return game:GetService("HttpService"):GetAsync(url, true)
    end)
    if ok3 and body3 then return body3 end
    return nil
end

local function fetchAmvgg(cb)
    if _amvggCache then cb(_amvggCache) return end
    table.insert(_amvggCallbacks, cb)
    if _amvggFetching then return end
    _amvggFetching = true
    task.spawn(function()
        local ok, text = pcall(httpGet, "https://amvgg.com/values/pets?_rsc=19zvn")
        if not ok or type(text) ~= "string" then
            _amvggFetching = false
            for _, fn in ipairs(_amvggCallbacks) do pcall(fn, nil) end
            _amvggCallbacks = {}
            return
        end
        local ps = text:find('"pets":%[{')
        if not ps then
            _amvggFetching = false
            for _, fn in ipairs(_amvggCallbacks) do pcall(fn, nil) end
            _amvggCallbacks = {}
            return
        end
        local raw = decodeJsonArrayAt(text, ps)
        if not raw then
            _amvggFetching = false
            for _, fn in ipairs(_amvggCallbacks) do pcall(fn, nil) end
            _amvggCallbacks = {}
            return
        end
        local cache = {}
        for _, p in ipairs(raw) do
            if p.name then
                local function n(v) return tonumber(v) or 0 end
                cache[p.name:lower()] = {
                    r            = n(p.fValue),
                    fr           = n(p.regularValue),
                    neon_regular = n(p.npNeonValue),
                    nf           = n(p.nfValue) ~= 0 and n(p.nfValue) or n(p.neonValue),
                    nr           = n(p.nrValue) ~= 0 and n(p.nrValue) or n(p.neonValue),
                    nfr          = n(p.neonValue),
                    mega_regular = n(p.npMegaValue),
                    mf           = n(p.mfValue) ~= 0 and n(p.mfValue) or n(p.megaValue),
                    mr           = n(p.mrValue) ~= 0 and n(p.mrValue) or n(p.megaValue),
                    mfr          = n(p.megaValue),
                }
            end
        end
        _amvggCache = cache
        _amvggFetching = false
        local cbs = _amvggCallbacks
        _amvggCallbacks = {}
        for _, fn in ipairs(cbs) do pcall(fn, cache) end
    end)
end
_G._fetchAmvgg = fetchAmvgg

local function getVariantKey(props)
    if not props then return "r" end
    if props.mega_neon then
        if props.flyable and props.rideable then return "mfr"
        elseif props.flyable  then return "mf"
        elseif props.rideable then return "mr"
        else return "mega_regular" end
    elseif props.neon then
        if props.flyable and props.rideable then return "nfr"
        elseif props.flyable  then return "nf"
        elseif props.rideable then return "nr"
        else return "neon_regular" end
    elseif props.flyable or props.rideable then return "fr"
    else return "r" end
end

local function getPetVal(pd, vk)
    if not pd then return 0 end
    local v = pd[vk] or 0
    if v == 0 then
        if vk == "nf" or vk == "nr"         then v = pd.nfr or 0
        elseif vk == "mf" or vk == "mr"     then v = pd.mfr or 0
        elseif vk == "neon_regular"          then v = pd.nfr or pd.nf or 0
        elseif vk == "mega_regular"          then v = pd.mfr or pd.mf or 0
        elseif vk == "r"                     then v = pd.fr  or 0
        elseif vk == "fr"                    then v = pd.r   or 0 end
    end
    return v
end
_G._getVariantKey = getVariantKey
_G._getPetVal = getPetVal

local function fmtVal(v)
    if v == 0 then return "N/A" end
    if v >= 1e6       then return string.format("%.1fM", v/1e6)
    elseif v >= 1e3   then return string.format("%.1fK", v/1e3)
    elseif v >= 100   then return string.format("%.0f", v)
    elseif v >= 1     then return string.format("%.1f", v)
    else                   return string.format("%.3f", v) end
end
_G._fmtVal = fmtVal

local function sumOffer(items, cache)
    local total = 0
    for _, item in ipairs(items or {}) do
        if item.category == "pets" and item.kind then
            local name = ""
            pcall(function()
                name = (InventoryDB.pets[item.kind] and InventoryDB.pets[item.kind].name) or item.kind
            end)
            local pd = cache[name:lower()]
            if not pd then
                for k, v in pairs(cache) do
                    if k:find(name:lower(), 1, true) then pd = v; break end
                end
            end
            total = total + getPetVal(pd, getVariantKey(item.properties))
        end
    end
    return total
end
_G._sumOffer = sumOffer

local valueHeaderRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 7), BackgroundTransparency=1, Parent=miscFrame})
local valueHeaderLbl = mk("TextLabel", {Size=UDim2.new(1, 0, 1, 0), BackgroundTransparency=1, Text="Trade Values (AMVGG)", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=valueHeaderRow})

local valueRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 14), BackgroundTransparency=1, Parent=miscFrame})

local yourValBox = mk("TextLabel", {Size=UDim2.new(0.5, -2, 1, 0), Position=UDim2.new(0, 0, 0, 0), BackgroundColor3=Color3.fromRGB(16, 24, 50), BackgroundTransparency=0.1, Text="You: —", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(110, 190, 255), TextXAlignment=Enum.TextXAlignment.Center, Parent=valueRow})
Instance.new("UICorner", yourValBox).CornerRadius = UDim.new(0, 3)
local yourValStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(60, 100, 180), Thickness=0.7, Parent=yourValBox})

local partnerValBox = mk("TextLabel", {Size=UDim2.new(0.5, -2, 1, 0), Position=UDim2.new(0.5, 2, 0, 0), BackgroundColor3=Color3.fromRGB(16, 36, 20), BackgroundTransparency=0.1, Text="Them: —", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(90, 230, 120), TextXAlignment=Enum.TextXAlignment.Center, Parent=valueRow})
Instance.new("UICorner", partnerValBox).CornerRadius = UDim.new(0, 3)
local partnerValStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(40, 130, 60), Thickness=0.7, Parent=partnerValBox})

local valueStatusRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 0), BackgroundTransparency=1, Parent=miscFrame})
local valueStatusLbl = mk("TextLabel", {Size=UDim2.new(1, 0, 1, 0), BackgroundTransparency=1, Text="", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(170, 140, 220), TextXAlignment=Enum.TextXAlignment.Center, Parent=valueStatusRow})

local function refreshValues()
    local myOffer, partnerOffer

    if mockState.active and mockState.trade then
        local trade = mockState.trade
        myOffer      = trade.sender_offer
        partnerOffer = trade.recipient_offer
        local recipient = trade.recipient
        if recipient and (recipient == Players.LocalPlayer or
            recipient.UserId == Players.LocalPlayer.UserId) then
            myOffer, partnerOffer = partnerOffer, myOffer
        end
    else
        local ok, state = pcall(function()
            return mockState.originalFunctions._get_local_trade_state(TradeApp)
        end)
        if ok and state then
            if state.sender == Players.LocalPlayer then
                myOffer      = state.sender_offer
                partnerOffer = state.recipient_offer
            else
                myOffer      = state.recipient_offer
                partnerOffer = state.sender_offer
            end
        end
    end

    if not myOffer and not partnerOffer then
        yourValBox.Text     = "You: —"
        partnerValBox.Text  = "Them: —"
        valueStatusLbl.Text = ""
        yourValStroke.Color    = Color3.fromRGB(60, 100, 180)
        partnerValStroke.Color = Color3.fromRGB(40, 130, 60)
        return
    end

    if not _amvggCache then
        valueStatusLbl.Text = "loading values..."
    end

    fetchAmvgg(function(cache)
        if not cache then
            valueStatusLbl.Text = "⚠ failed to load"
            return
        end
        valueStatusLbl.Text = ""
        local myTotal      = sumOffer(myOffer and myOffer.items or {}, cache)
        local partnerTotal = sumOffer(partnerOffer and partnerOffer.items or {}, cache)
        _G._lastPartnerAmvgg = partnerTotal  -- cached for auto spin
        yourValBox.Text    = "You: "  .. fmtVal(myTotal)
        partnerValBox.Text = "Them: " .. fmtVal(partnerTotal)
        if myTotal > 0 and partnerTotal > 0 then
            local ratio = partnerTotal / myTotal
            if ratio >= 0.9 and ratio <= 1.1 then
                yourValStroke.Color    = Color3.fromRGB(0, 255, 100)
                partnerValStroke.Color = Color3.fromRGB(0, 255, 100)
            elseif ratio > 1.1 then
                yourValStroke.Color    = Color3.fromRGB(0, 200, 255)
                partnerValStroke.Color = Color3.fromRGB(0, 200, 255)
            else
                yourValStroke.Color    = Color3.fromRGB(255, 80, 80)
                partnerValStroke.Color = Color3.fromRGB(255, 80, 80)
            end
        else
            yourValStroke.Color    = Color3.fromRGB(60, 100, 180)
            partnerValStroke.Color = Color3.fromRGB(40, 130, 60)
        end
    end)
end

-- Hook _overwrite_local_trade_state for mock trades
local _origOverwriteForValues = TradeApp._overwrite_local_trade_state
TradeApp._overwrite_local_trade_state = function(self, newState)
    local result = _origOverwriteForValues(self, newState)
    task.defer(refreshValues)
    return result
end

-- Also hook the REAL _overwrite_local_trade_state (original) for real trades
local _realOrigOverwrite = mockState.originalFunctions._overwrite_local_trade_state
if _realOrigOverwrite then
    mockState.originalFunctions._overwrite_local_trade_state = function(self, newState)
        local result = _realOrigOverwrite(self, newState)
        task.defer(refreshValues)

        -- Detect real trade completion and queue auto spins
        if _G._autoSpinEnabled and newState and newState.current_stage == "completed" and not mockState.active then
            pcall(function()
                local partnerItems = newState.recipient_offer and newState.recipient_offer.items
                if not partnerItems or #partnerItems == 0 then return end
                local val = _G._lastPartnerAmvgg or 0
                -- recalc from current display value if available
                if val <= 0 then return end
                local spins = math.floor(val / 0.1 + 0.5)
                if _G._maxSpinsEnabled then
                    spins = math.min(spins, _G._maxSpinsValue)
                end
                if spins > 0 then
                    _G._autoSpinPending = (_G._autoSpinPending or 0) + spins
                    _G._autoSpinRequiredPets = #partnerItems
                    _G._autoSpinTriggered = false
                    _G._autoSpinWaitingForTrade = true
                end
            end)
        end

        return result
    end
end

task.spawn(function()
    fetchAmvgg(function() end)
end)

end -- TRADE VALUE DISPLAY do block

do  -- register-relief: scope the misc-tab UI locals so they free before the toggle rows (Volt 200-local limit)
local GUI_SCALE = 1.0
local GUI_BASE_W, GUI_BASE_H = 130, 300

-- Popup GUIs (keybind panel, rich board, etc.) register a UIScale here so they grow with the
-- main GUI instead of staying a fixed size. Register returns the UIScale (already at current scale).
_G._guiScale = _G._guiScale or 1
_G._extraGuiScales = _G._extraGuiScales or {}
_G._registerScaledGui = function(inst)
    if not inst then return nil end
    local s = Instance.new("UIScale")
    s.Scale = _G._guiScale
    s.Parent = inst
    table.insert(_G._extraGuiScales, s)
    return s
end

local function applyGuiScale()
    -- Capture the visual center before changing scale
    local oldVW = math.floor(GUI_BASE_W * mainUIScale.Scale)
    local oldVH = math.floor(GUI_BASE_H * mainUIScale.Scale)
    local cx = mainFrame.AbsolutePosition.X + oldVW / 2
    local cy = mainFrame.AbsolutePosition.Y + oldVH / 2

    mainUIScale.Scale = GUI_SCALE
    local vw = math.floor(GUI_BASE_W * GUI_SCALE)
    local vh = math.floor(GUI_BASE_H * GUI_SCALE)
    local nx = math.floor(cx - vw / 2)
    local ny = math.floor(cy - vh / 2)

    mainFrame.Size     = UDim2.new(0, GUI_BASE_W, 0, GUI_BASE_H)
    mainFrame.Position = UDim2.new(0, nx, 0, ny)
    blackFrame.Size     = UDim2.new(0, vw + 6, 0, vh + 6)
    blackFrame.Position = UDim2.new(0, nx - 3, 0, ny - 3)

    -- Scale registered popup GUIs (keybind panel, rich board, …) to match; prune destroyed ones.
    _G._guiScale = GUI_SCALE
    local live = {}
    for _, s in ipairs(_G._extraGuiScales) do
        if s and s.Parent then
            pcall(function() s.Scale = GUI_SCALE end)
            table.insert(live, s)
        end
    end
    _G._extraGuiScales = live
end

local guiSizeRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 11), BackgroundTransparency=1, Parent=miscFrame})

local guiSizeLabel = mk("TextLabel", {Size=UDim2.new(0.44, -2, 1, 0), BackgroundTransparency=1, Text="GUI Size: 100%", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=guiSizeRow})

local guiSizeDown = mk("TextButton", {Size=UDim2.new(0.17, -1, 1, 0), Position=UDim2.new(0.44, 1, 0, 0), BackgroundColor3=Color3.fromRGB(60, 40, 80), BackgroundTransparency=0.2, Text="−", Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=Color3.fromRGB(190,34,230), Parent=guiSizeRow})
Instance.new("UICorner", guiSizeDown).CornerRadius = UDim.new(0, 3)
local guiSizeDownStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.7, Transparency=0.4, Parent=guiSizeDown})

local guiSizeUp = mk("TextButton", {Size=UDim2.new(0.17, -1, 1, 0), Position=UDim2.new(0.62, 1, 0, 0), BackgroundColor3=Color3.fromRGB(60, 40, 80), BackgroundTransparency=0.2, Text="+", Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=Color3.fromRGB(190,34,230), Parent=guiSizeRow})
Instance.new("UICorner", guiSizeUp).CornerRadius = UDim.new(0, 3)
local guiSizeUpStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.7, Transparency=0.4, Parent=guiSizeUp})

local guiLockBtn = mk("TextButton", {Size=UDim2.new(0.19, -1, 1, 0), Position=UDim2.new(0.80, 1, 0, 0), BackgroundColor3=Color3.fromRGB(40, 40, 60), BackgroundTransparency=0.2, Text="🔓", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(180, 180, 200), Parent=guiSizeRow})
Instance.new("UICorner", guiLockBtn).CornerRadius = UDim.new(0, 3)
local guiLockStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(100, 100, 140), Thickness=0.7, Transparency=0.4, Parent=guiLockBtn})

guiLockBtn.MouseButton1Click:Connect(function()
    _G._guiLocked = not _G._guiLocked
    if _G._guiLocked then
        guiLockBtn.Text             = "🔒"; guiLockBtn.BackgroundColor3 = Color3.fromRGB(30, 60, 40)
        guiLockBtn.TextColor3       = Color3.fromRGB(80, 255, 130)
        guiLockStroke.Color         = Color3.fromRGB(0, 200, 80)
        guiLockStroke.Transparency  = 0.2
    else
        guiLockBtn.Text             = "🔓"; guiLockBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 60)
        guiLockBtn.TextColor3       = Color3.fromRGB(180, 180, 200)
        guiLockStroke.Color         = Color3.fromRGB(100, 100, 140)
        guiLockStroke.Transparency  = 0.4
    end
end)

guiSizeDown.MouseButton1Click:Connect(function()
    GUI_SCALE = math.max(0.5, math.round((GUI_SCALE - 0.1) * 10) / 10)
    guiSizeLabel.Text = string.format("GUI Size: %d%%", math.floor(GUI_SCALE * 100))
    applyGuiScale()
end)
guiSizeUp.MouseButton1Click:Connect(function()
    GUI_SCALE = math.min(3.0, math.round((GUI_SCALE + 0.1) * 10) / 10)
    guiSizeLabel.Text = string.format("GUI Size: %d%%", math.floor(GUI_SCALE * 100))
    applyGuiScale()
end)

local keybindsEnabled = true

local keybindsToggleRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 11), BackgroundTransparency=1, Parent=miscFrame})

local keybindsLabel = mk("TextLabel", {Size=UDim2.new(0.6, -2, 1, 0), Position=UDim2.new(0, 0, 0, 0), BackgroundTransparency=1, Text="Keybinds", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=keybindsToggleRow})

local keybindsToggle = mk("TextButton", {Size=UDim2.new(0.315, 0, 1, 0), Position=UDim2.new(0.685, 0, 0, 0), BackgroundColor3=Color3.fromRGB(30, 80, 50), BackgroundTransparency=0.2, Text="ON", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(80, 255, 130), Parent=keybindsToggleRow})
Instance.new("UICorner", keybindsToggle).CornerRadius = UDim.new(0, 3)
local keybindsToggleStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0, 255, 100), Thickness=0.7, Transparency=0.3, Parent=keybindsToggle})

keybindsToggle.MouseButton1Click:Connect(function()
    keybindsEnabled = not keybindsEnabled
    if keybindsEnabled then
        keybindsToggle.Text       = "ON"
        keybindsToggle.TextColor3 = Color3.fromRGB(80, 255, 130)
        TweenService:Create(keybindsToggle, TweenInfo.new(0.2), { BackgroundColor3 = Color3.fromRGB(30, 80, 50) }):Play()
        TweenService:Create(keybindsToggleStroke, TweenInfo.new(0.2), { Color = Color3.fromRGB(0, 255, 100) }):Play()
    else
        keybindsToggle.Text       = "OFF"
        keybindsToggle.TextColor3 = Color3.fromRGB(255, 90, 90)
        TweenService:Create(keybindsToggle, TweenInfo.new(0.2), { BackgroundColor3 = Color3.fromRGB(80, 30, 30) }):Play()
        TweenService:Create(keybindsToggleStroke, TweenInfo.new(0.2), { Color = Color3.fromRGB(255, 60, 60) }):Play()
    end
end)

-- Reusable ON/OFF config toggle row (green ON / red OFF, same style as the rest of Misc).
-- initialOn seeds the visual; onToggle(newState) is called with the flipped boolean.
local function addConfigToggle(parent, labelText, initialOn, onToggle)
    local row = mk("Frame", {Size=UDim2.new(1,0,0,11), BackgroundTransparency=1, Parent=parent})
    mk("TextLabel", {Size=UDim2.new(0.6,-2,1,0), BackgroundTransparency=1, Text=labelText, Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=row})
    local btn = mk("TextButton", {Size=UDim2.new(0.315,0,1,0), Position=UDim2.new(0.685,0,0,0), BackgroundColor3=Color3.fromRGB(30,80,50), BackgroundTransparency=0.2, Text="ON", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(80,255,130), Parent=row})
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,3)
    local stroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0,255,100), Thickness=0.7, Transparency=0.3, Parent=btn})
    local state = initialOn and true or false
    local function paint()
        btn.Text = state and "ON" or "OFF"
        btn.TextColor3 = state and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
        TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = state and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)}):Play()
        TweenService:Create(stroke, TweenInfo.new(0.2), {Color = state and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)}):Play()
    end
    paint()
    btn.MouseButton1Click:Connect(function()
        state = not state; paint(); if onToggle then onToggle(state) end
    end)
    return btn
end

local receivePetsToggle    = addConfigToggle(miscFrame, "Receive Pets",     CONFIG.RECEIVE_PETS,     function(on) CONFIG.RECEIVE_PETS = on end)
local removeSentToggle     = addConfigToggle(miscFrame, "Remove Sent Pets", CONFIG.REMOVE_SENT_PETS, function(on) CONFIG.REMOVE_SENT_PETS = on end)
local verifiedFriendToggle = addConfigToggle(miscFrame, "Verified Friend",  CONFIG_VERIFIED_FRIEND,  function(on) CONFIG_VERIFIED_FRIEND = on end)

-- PUT YOUR CHAT LIST HERE ↓
local ChatList = {
    "wozu kannst du das boosten",
    "kann ich das wirklich boosten lassen",
    "danke so sehr",
    "omg ty",
    "danke dass du vertrauenswürdig bist",
    "danke",
    "erfüllt das die Voraussetzungen?",
    "könnte ich ein gratis Pet haben",
    "bro bitte",
    "KEIN WEG",
    "ich liebe dich",
    "bro bitte größeres boosting",
    "edu.mlr hat mir ein besseres boosting angeboten",
    "thx",
    "trusted",
    "vouch",
    "TRUSTED OMG",
    "wie bist du so reich geworden?",
    "kann ich nochmal boosten lassen",
    "such dir ein Pet aus meinem Inventar aus",
    "kannst du mich zu meinem dp boosten",
    "erfüllt das die Voraussetzungen?",
    "kannst du mein Pet boosten",
    "folgt denen Leute die sind trusted",
    "kann ich mein Pet boosten lassen",
}
_G._ChatList = ChatList
-- PUT YOUR CHAT LIST HERE ↑

local _autoChatEnabled  = false
local _autoChatLimit    = 0   -- 0 = no limit
local _autoChatSent     = 0
local _autoChatLoopId   = 0

local function _sendAutoChat()
    if not mockState.active or not mockState.trade then return end
    if _autoChatLimit > 0 and _autoChatSent >= _autoChatLimit then return end
    if #ChatList == 0 then return end
    if not (TradeApp and TradeApp._render_message_in_trade_chat) then return end
    if not TradeApp.chat_scrolling_frame or not TradeApp.chat_message_template then return end
    local msg = ChatList[math.random(1, #ChatList)]

    task.spawn(function()
        -- Typing indicator using the same pattern as _initialize_typing_indicator (source line 2443)
        local typingLabel = nil
        safeCall(function()
            local scrollFrame = TradeApp.chat_scrolling_frame
            local template = TradeApp.chat_message_template
            if not scrollFrame or not template then return end

            local atBottom = math.abs(
                scrollFrame.CanvasSize.Y.Offset
                - scrollFrame.AbsoluteSize.Y
                - scrollFrame.CanvasPosition.Y) < 40

            local clone = template:Clone()
            clone.Name = "TypingMessage"; clone.RichText = true
            clone.Text = string.format("<i><b>%s</b> is typing</i>", CONFIG.PARTNER_NAME:lower()); clone.TextColor3 = Color3.fromRGB(150, 150, 150)
            clone.TextSize = 22; clone.TextTransparency = 0
            clone.LayoutOrder = 1; clone.Parent = scrollFrame.Content

            local h = clone.TextBounds.Y
            clone.Size = UDim2.new(1, 0, 0, h)
            scrollFrame.CanvasSize = scrollFrame.CanvasSize + UDim2.new(0, 0, 0, h)
            if atBottom then
                scrollFrame.CanvasPosition = Vector2.new(0,
                    scrollFrame.CanvasSize.Y.Offset - scrollFrame.AbsoluteSize.Y)
            end
            typingLabel = clone
        end)

        -- Animate dots for ~1.8s
        local elapsed, dotTimer, dots = 0, 0, 0
        while elapsed < 1.8 and typingLabel and typingLabel.Parent do
            local dt = task.wait(0.05)
            elapsed = elapsed + dt
            dotTimer = dotTimer + dt
            if dotTimer >= 0.25 then
                dotTimer = dotTimer - 0.25
                dots = (dots % 3) + 1
                safeCall(function()
                    typingLabel.Text = string.format(
                        "<i><b>%s</b> is typing%s</i>",
                        CONFIG.PARTNER_NAME:lower(), string.rep(".", dots))
                end)
            end
        end

        safeCall(function()
            if typingLabel and typingLabel.Parent then
                local h = typingLabel.Size.Y.Offset
                TradeApp.chat_scrolling_frame.CanvasSize =
                    TradeApp.chat_scrolling_frame.CanvasSize - UDim2.new(0, 0, 0, h)
                typingLabel:Destroy()
            end
        end)

        if not mockState.active then return end

        -- Pass mockPartner as player so the function renders their name,
        -- and raw msg as the message string — same as _listen_to_global_chat does
        safeCall(function()
            TradeApp:_render_message_in_trade_chat(mockPartner, msg, true)
        end)
        _autoChatSent = _autoChatSent + 1
    end)
end

local function _startAutoChatLoop()
    _autoChatLoopId = _autoChatLoopId + 1
    local myId = _autoChatLoopId
    _autoChatSent = 0
    task.spawn(function()
        while myId == _autoChatLoopId and _autoChatEnabled and mockState.active do
            task.wait(5)
            if myId ~= _autoChatLoopId or not _autoChatEnabled or not mockState.active then break end
            if _autoChatLimit > 0 and _autoChatSent >= _autoChatLimit then break end
            _sendAutoChat()
        end
    end)
end

local function _stopAutoChatLoop()
    _autoChatLoopId = _autoChatLoopId + 1
end

-- Auto Chat toggle row
local autoChatRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 11), BackgroundTransparency=1, Parent=miscFrame})
local autoChatLabel = mk("TextLabel", {Size=UDim2.new(0.6, -2, 1, 0), BackgroundTransparency=1, Text="Auto Chat", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=autoChatRow})
local autoChatToggle = mk("TextButton", {Size=UDim2.new(0.315, 0, 1, 0), Position=UDim2.new(0.685, 0, 0, 0), BackgroundColor3=Color3.fromRGB(80, 30, 30), BackgroundTransparency=0.2, Text="OFF", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255, 90, 90), Parent=autoChatRow})
Instance.new("UICorner", autoChatToggle).CornerRadius = UDim.new(0, 3)
local autoChatStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255, 60, 60), Thickness=0.7, Transparency=0.3, Parent=autoChatToggle})
autoChatToggle.MouseButton1Click:Connect(function()
    _autoChatEnabled = not _autoChatEnabled
    if _autoChatEnabled then
        autoChatToggle.Text       = "ON"
        autoChatToggle.TextColor3 = Color3.fromRGB(80, 255, 130)
        TweenService:Create(autoChatToggle, TweenInfo.new(0.2), { BackgroundColor3 = Color3.fromRGB(30, 80, 50) }):Play()
        TweenService:Create(autoChatStroke, TweenInfo.new(0.2), { Color = Color3.fromRGB(0, 255, 100) }):Play()
        if mockState.active then _startAutoChatLoop() end
    else
        autoChatToggle.Text       = "OFF"
        autoChatToggle.TextColor3 = Color3.fromRGB(255, 90, 90)
        TweenService:Create(autoChatToggle, TweenInfo.new(0.2), { BackgroundColor3 = Color3.fromRGB(80, 30, 30) }):Play()
        TweenService:Create(autoChatStroke, TweenInfo.new(0.2), { Color = Color3.fromRGB(255, 60, 60) }):Play()
        _stopAutoChatLoop()
    end
end)

local chatLimitRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 11), BackgroundTransparency=1, Parent=miscFrame})
local chatLimitLabel = mk("TextLabel", {Size=UDim2.new(0.6, -2, 1, 0), BackgroundTransparency=1, Text="Chat Limit (0=∞)", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=chatLimitRow})
local chatLimitBox = mk("TextBox", {Size=UDim2.new(0.315, 0, 1, 0), Position=UDim2.new(0.685, 0, 0, 0), BackgroundColor3=Color3.fromRGB(40, 40, 55), BackgroundTransparency=0.2, Text="0", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(190,34,230), PlaceholderText="0", Parent=chatLimitRow})
Instance.new("UICorner", chatLimitBox).CornerRadius = UDim.new(0, 3)
local chatLimitStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.7, Transparency=0.4, Parent=chatLimitBox})
chatLimitBox.FocusLost:Connect(function()
    local v = tonumber(chatLimitBox.Text)
    if v and v >= 0 then
        _autoChatLimit = math.floor(v)
        chatLimitBox.Text = tostring(_autoChatLimit)
    else
        chatLimitBox.Text = tostring(_autoChatLimit)
    end
end)

local testChatBtn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 11), BackgroundColor3=Color3.fromRGB(40, 60, 100), BackgroundTransparency=0.2, Text="Send Random Message", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(120, 180, 255), Parent=miscFrame})
Instance.new("UICorner", testChatBtn).CornerRadius = UDim.new(0, 3)
local testChatStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(80, 140, 255), Thickness=0.7, Transparency=0.4, Parent=testChatBtn})
testChatBtn.MouseButton1Click:Connect(function()
    if not mockState.active or not mockState.trade then
        warn("[MockTrade] AutoChat test: no active trade")
        return
    end
    if #ChatList == 0 then
        warn("[MockTrade] AutoChat test: ChatList is empty")
        return
    end
    local msg = ChatList[math.random(1, #ChatList)]
    warn("[MockTrade] AutoChat test: sending '" .. msg .. "'")
    safeCall(function()
        TradeApp:_render_message_in_trade_chat(mockPartner, msg, true)
    end)
    TweenService:Create(testChatStroke, TweenInfo.new(0.1), { Color = Color3.fromRGB(0, 255, 120) }):Play()
    task.delay(0.4, function()
        TweenService:Create(testChatStroke, TweenInfo.new(0.3), { Color = Color3.fromRGB(80, 140, 255) }):Play()
    end)
end)

local keybindListBtn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 11), BackgroundColor3=Color3.fromRGB(40, 40, 55), BackgroundTransparency=0.1, Text="⌨️ Keybinds", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(180, 180, 220), Parent=miscFrame})
Instance.new("UICorner", keybindListBtn).CornerRadius = UDim.new(0, 3)
local keybindListStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.8, Transparency=0.3, Parent=keybindListBtn})

-- Keybind popup panel — exact same style as misc tab rows, display-only
local keybindPanel = mk("Frame", {Size=UDim2.fromOffset(110, 10), AutomaticSize=Enum.AutomaticSize.Y, BackgroundColor3=Color3.fromRGB(30, 30, 40), BorderSizePixel=0, Visible=false, ZIndex=100, Parent=controlGui})
if _G._registerScaledGui then _G._registerScaledGui(keybindPanel) end  -- grow with the main GUI
Instance.new("UICorner", keybindPanel).CornerRadius = UDim.new(0, 7)
local kpStroke = mk("UIStroke", {Color=Color3.fromRGB(190,34,230), Thickness=1.5, Parent=keybindPanel})
local kpPad = mk("UIPadding", {PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4), PaddingLeft=UDim.new(0,4), PaddingRight=UDim.new(0,4), Parent=keybindPanel})
local kpLayout = mk("UIListLayout", {Padding=UDim.new(0, 2), SortOrder=Enum.SortOrder.LayoutOrder, Parent=keybindPanel})

local function addKeybindEntry(label, defaultKey, order)
    local row = mk("Frame", {Size=UDim2.new(1, 0, 0, 11), BackgroundTransparency=1, LayoutOrder=order, ZIndex=101, Parent=keybindPanel})

    local lbl = mk("TextLabel", {Size=UDim2.new(0.6, -2, 1, 0), Position=UDim2.new(0, 0, 0, 0), BackgroundTransparency=1, Text=label, Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(210, 190, 255), TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, ZIndex=102, Parent=row})

    local keyBtn = mk("TextButton", {Size=UDim2.new(0.315, 0, 1, 0), Position=UDim2.new(0.685, 0, 0, 0), BackgroundColor3=Color3.fromRGB(40, 40, 55), BackgroundTransparency=0.2, BorderSizePixel=0, Text=defaultKey, Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(190,34,230), ZIndex=102, Parent=row})
    Instance.new("UICorner", keyBtn).CornerRadius = UDim.new(0, 3)
    local keyStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.7, Transparency=0.4, Parent=keyBtn})

    local binding = false
    keyBtn.MouseButton1Click:Connect(function()
        if binding then return end
        binding = true
        keyBtn.Text = "..."
        keyBtn.TextColor3 = Color3.fromRGB(255, 200, 50)
        TweenService:Create(keyStroke, TweenInfo.new(0.15), {Color=Color3.fromRGB(255,200,50), Transparency=0}):Play()
        local conn
        conn = UserInputService.InputBegan:Connect(function(input, gpe)
            if gpe then return end
            local keyName = input.KeyCode.Name
            if keyName == "Unknown" then return end
            keyBtn.Text = keyName
            keyBtn.TextColor3 = Color3.fromRGB(190,34,230)
            TweenService:Create(keyStroke, TweenInfo.new(0.15), {Color=Color3.fromRGB(190,34,230), Transparency=0.4}):Play()
            conn:Disconnect()
            binding = false
        end)
    end)
    return keyBtn
end

local addRandomKeyBtn       = addKeybindEntry("Add Random High Tier",  "P", 1)
local startTradeKeyBtn      = addKeybindEntry("Start Trade",           "T", 2)
local partnerAcceptKeyBtn   = addKeybindEntry("Partner Accept",        "Y", 3)
local partnerUnacceptKeyBtn = addKeybindEntry("Partner Unaccept",      "U", 4)
local randomPlayerKeyBtn    = addKeybindEntry("Select Random Player",  "R", 5)
local randomPresetKeyBtn    = addKeybindEntry("Random Preset User",    "H", 6)
local selectPartnerKeyBtn   = addKeybindEntry("Select Trade Partner",  "MB4", 7)
local blockKeyBtn           = addKeybindEntry("Block Player",           (_G._blockKey or "J"), 8)
-- Keep the actual block key in sync when this row is rebound in the panel.
blockKeyBtn:GetPropertyChangedSignal("Text"):Connect(function()
    if blockKeyBtn.Text ~= "..." then _G._blockKey = blockKeyBtn.Text end
end)

local function updateKeybindPanelPos()
    local mf = _G._tradeGuiMainFrame
    if mf then
        local p = mf.AbsolutePosition
        local s = mf.AbsoluteSize
        keybindPanel.Position = UDim2.fromOffset(p.X + s.X + 6, p.Y)
    end
end

keybindListBtn.MouseButton1Click:Connect(function()
    keybindPanel.Visible = not keybindPanel.Visible
    if keybindPanel.Visible then updateKeybindPanelPos() end
end)

-- "Mo layout" keybind preset — exposed as a global so the Misc Page-2 button can apply it
-- (the keyBtn locals are only in scope here). Matches the shared screenshot:
-- Select Partner=P, Add Random Item=R, Start Trade=T, Block Player=B, Random User=G.
_G._applyMoLayout = function()
    selectPartnerKeyBtn.Text = "P"
    addRandomKeyBtn.Text     = "R"
    startTradeKeyBtn.Text    = "T"
    randomPresetKeyBtn.Text  = "G"   -- Random User = Set Random Preset Player
    _G._blockKey = "B"
    blockKeyBtn.Text = "B"
end

-- Cloud-save hook: keybinds (all rebindable keys + the block key).
_G._saveHooks.keybinds = {
    label = "Keybinds",
    save = function()
        return {
            addRandom = addRandomKeyBtn.Text, startTrade = startTradeKeyBtn.Text,
            partnerAccept = partnerAcceptKeyBtn.Text, partnerUnaccept = partnerUnacceptKeyBtn.Text,
            randomPlayer = randomPlayerKeyBtn.Text, randomPreset = randomPresetKeyBtn.Text,
            selectPartner = selectPartnerKeyBtn.Text, block = _G._blockKey or "J",
        }
    end,
    load = function(t)
        if type(t) ~= "table" then return end
        if t.addRandom      then addRandomKeyBtn.Text      = t.addRandom end
        if t.startTrade     then startTradeKeyBtn.Text     = t.startTrade end
        if t.partnerAccept  then partnerAcceptKeyBtn.Text  = t.partnerAccept end
        if t.partnerUnaccept then partnerUnacceptKeyBtn.Text = t.partnerUnaccept end
        if t.randomPlayer   then randomPlayerKeyBtn.Text   = t.randomPlayer end
        if t.randomPreset   then randomPresetKeyBtn.Text   = t.randomPreset end
        if t.selectPartner  then selectPartnerKeyBtn.Text  = t.selectPartner end
        if t.block then _G._blockKey = t.block; blockKeyBtn.Text = t.block end
    end,
}

game:GetService("UserInputService").InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 and keybindPanel.Visible then
        local mp = i.Position; local ap = keybindPanel.AbsolutePosition; local as = keybindPanel.AbsoluteSize
        if not(mp.X>=ap.X and mp.X<=ap.X+as.X and mp.Y>=ap.Y and mp.Y<=ap.Y+as.Y) then
            keybindPanel.Visible = false
        end
    end
end)

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or not keybindsEnabled then return end
    local key = input.KeyCode.Name
    if key == addRandomKeyBtn.Text then
        task.spawn(addRandomHighTier)
    elseif key == partnerAcceptKeyBtn.Text then
        -- Partner Accept (negotiation) OR Partner Confirm (confirmation stage)
        if mockState.active and mockState.trade then
            local _, partnerKey = TradeApp:_get_my_offer()
            local recipientKey = (partnerKey == "sender_offer") and "recipient_offer" or "sender_offer"
            local stage = TradeApp:_get_current_trade_stage()
            if stage == "confirmation" then
                mockState.trade[recipientKey].confirmed = true
            else
                mockState.trade[recipientKey].negotiated = true
            end
            mockState.trade.offer_version = (mockState.trade.offer_version or 1) + 1
            TradeApp:_overwrite_local_trade_state(mockState.trade)
            if TradeApp.refresh_all then TradeApp:refresh_all() end
        end
    elseif key == partnerUnacceptKeyBtn.Text then
        if mockState.active and mockState.trade then
            local _, partnerKey = TradeApp:_get_my_offer()
            local recipientKey = (partnerKey == "sender_offer") and "recipient_offer" or "sender_offer"
            mockState.trade[recipientKey].negotiated = false
            mockState.trade.offer_version = (mockState.trade.offer_version or 1) + 1
            TradeApp:_overwrite_local_trade_state(mockState.trade)
            if TradeApp.refresh_all then TradeApp:refresh_all() end
        end
    elseif key == startTradeKeyBtn.Text then
        local currentName = partnerBox.Text
        if currentName and currentName ~= "" then
            updatePartnerFromUsername(currentName)
        end
        initializeMockTrade()
    elseif key == randomPlayerKeyBtn.Text then
        local playersList = Players:GetPlayers()
        local others = {}
        for _, p in ipairs(playersList) do
            if p ~= Players.LocalPlayer then table.insert(others, p) end
        end
        if #others > 0 then
            local picked = others[math.random(1, #others)]
            if _G._selectUser then _G._selectUser(picked.Name, picked.UserId) end
        end
    elseif key == randomPresetKeyBtn.Text then
        if _G._selectRandomPresetUser then _G._selectRandomPresetUser() end
    end
end)

-- Select trade partner via the Select-Partner keybind (MouseButton4 by default, or a keyboard
-- key like "P" once set, e.g. by the Mo layout).
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or not keybindsEnabled then return end
    local bind = selectPartnerKeyBtn.Text
    local matched = (input.UserInputType.Name == "MouseButton4" and (bind == "MB4" or bind == ""))
                 or (input.KeyCode.Name ~= "Unknown" and input.KeyCode.Name == bind)
    if not matched then return end
    local state = TradeApp:_get_local_trade_state()
    if not state then return end
    local me = Players.LocalPlayer
    local partner = (state.sender == me or state.sender.UserId == me.UserId)
        and state.recipient or state.sender
    if partner then
        selectUser(partner.Name, partner.UserId)
    end
end)

-- Single row: [🍎 Add Random Food (50%)] [◀ (12.5%)] [count (25%)] [▶ (12.5%)]
local _foodCount = 1

local foodRow = mk("Frame", {Size=UDim2.new(1,0,0,11), BackgroundTransparency=1, Parent=miscFrame})

local addFoodBtn = mk("TextButton", {Size=UDim2.new(0.5,-3,1,0), Position=UDim2.new(0,0,0,0), BackgroundColor3=Color3.fromRGB(40,100,60), BackgroundTransparency=0.05, Text="Add Random Food", Font=Enum.Font.FredokaOne, TextSize=6, TextColor3=Color3.fromRGB(160,255,160), BorderSizePixel=0, Parent=foodRow})
Instance.new("UICorner", addFoodBtn).CornerRadius = UDim.new(0,4)
local addFoodStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(80,200,80), Thickness=1.2, Transparency=0.2, Parent=addFoodBtn})

-- Counter: single pill frame with ◀ number ▶ inside
local foodCounterFrame = mk("Frame", {Size=UDim2.new(0.5,-3,1,0), Position=UDim2.new(0.5,3,0,0), BackgroundColor3=Color3.fromRGB(60,30,90), BackgroundTransparency=0.05, BorderSizePixel=0, Parent=foodRow})
Instance.new("UICorner", foodCounterFrame).CornerRadius = UDim.new(0,4)
local foodCounterStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=1.2, Transparency=0.2, Parent=foodCounterFrame})

local foodPrevBtn = mk("TextButton", {Size=UDim2.new(0,16,1,0), Position=UDim2.new(0,0,0,0), BackgroundTransparency=1, Text="◀", Font=Enum.Font.GothamBold, TextSize=7, TextColor3=Color3.fromRGB(210,140,255), BorderSizePixel=0, Parent=foodCounterFrame})

local foodCountBox = mk("TextBox", {Size=UDim2.new(1,-32,1,0), Position=UDim2.new(0,16,0,0), BackgroundTransparency=1, Text="1", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(210,140,255), TextXAlignment=Enum.TextXAlignment.Center, ClearTextOnFocus=false, BorderSizePixel=0, Parent=foodCounterFrame})

local foodNextBtn = mk("TextButton", {Size=UDim2.new(0,16,1,0), Position=UDim2.new(1,-16,0,0), BackgroundTransparency=1, Text="▶", Font=Enum.Font.GothamBold, TextSize=7, TextColor3=Color3.fromRGB(210,140,255), BorderSizePixel=0, Parent=foodCounterFrame})

local function setFoodCount(n)
    _foodCount = math.max(1, math.min(18, n))
    foodCountBox.Text = tostring(_foodCount)
end
foodPrevBtn.MouseButton1Click:Connect(function() setFoodCount(_foodCount - 1) end)
foodNextBtn.MouseButton1Click:Connect(function() setFoodCount(_foodCount + 1) end)
foodCountBox.FocusLost:Connect(function()
    local n = tonumber(foodCountBox.Text)
    if n then setFoodCount(n) else foodCountBox.Text = tostring(_foodCount) end
end)

local _foodBusy = false
local function addRandomFoodToOffer()
    if _foodBusy then return end
    if not mockState.active or not mockState.trade then
        addFoodBtn.Text = "No active trade!"
        task.delay(1.5, function() addFoodBtn.Text = "Add Random Food" end)
        return
    end
    if mockState.trade.current_stage == "confirmation" then return end
    _foodBusy = true

    -- Build list of all food items from InventoryDB
    local foodList = {}
    pcall(function()
        local foodDB = InventoryDB and InventoryDB.food
        if foodDB then
            for id, data in pairs(foodDB) do
                -- Skip untradeable items
                if data.name and not data.not_tradeable and not data.untradeable and not data.not_tradable then
                    table.insert(foodList, {id=id, name=data.name})
                end
            end
        end
    end)
    if #foodList == 0 then
        addFoodBtn.Text = "No food found!"
        task.delay(1.5, function() addFoodBtn.Text = "Add Random Food" end)
        _foodBusy = false; return
    end

    local target   = _foodCount
    local added    = 0
    local partnerId = tostring(mockState.trade.recipient.UserId)

    task.spawn(function()
        for i = 1, target do
            if not mockState.active or not mockState.trade then break end
            if #mockState.trade.recipient_offer.items >= 18 then break end

            -- Show busy indicator
            mockState.trade.busy_indicators = mockState.trade.busy_indicators or {}
            mockState.trade.busy_indicators[partnerId] = { picking = true }
            pcall(function() TradeApp:_update_busy_indicators(mockState.trade) end)

            addFoodBtn.Text = "Adding "..i.."/"..target.."..."

            task.wait(1)

            if not mockState.active or not mockState.trade then break end

            local pick = foodList[math.random(1, #foodList)]
            local uuid = HttpService:GenerateGUID()
            local foodItem = {
                category   = "food",
                kind       = pick.id,
                unique     = uuid,
                properties = { age = 0 },
            }

            mockState.trade.busy_indicators[partnerId] = nil
            pcall(function() TradeApp:_update_busy_indicators(mockState.trade) end)
            table.insert(mockState.trade.recipient_offer.items, foodItem)
            if not TradeApp.can_suggest_removal_items then TradeApp.can_suggest_removal_items = {} end
            TradeApp.can_suggest_removal_items[uuid] = foodItem
            mockState.trade.sender_offer.negotiated    = false
            mockState.trade.recipient_offer.negotiated = false
            mockState.trade.offer_version = mockState.trade.offer_version + 1
            TradeApp:_overwrite_local_trade_state(mockState.trade)
            pcall(function() TradeApp:_lock_trade_for_appropriate_time() end)
            pcall(function() TradeApp:_render_message_in_trade_chat(nil, CONFIG.PARTNER_NAME.." added "..pick.name..".", true) end)
            mockState.scamWarningShown = false
            added = added + 1
        end

        addFoodBtn.Text = added > 0 and ("Added "..added.."!") or "Add Random Food"
        task.delay(1.5, function() addFoodBtn.Text = "Add Random Food" end)
        _foodBusy = false
    end)
end

addFoodBtn.MouseButton1Click:Connect(addRandomFoodToOffer)

-- Preload pet icons button
local preloadBtn = Instance.new("TextButton")
-- Row containing Preload + Setup Live side by side
local preloadSetupRow = mk("Frame", {Size=UDim2.new(1,0,0,11), BackgroundTransparency=1, Parent=miscFrame})

preloadBtn.Size = UDim2.new(0.5,-3,1,0); preloadBtn.Position = UDim2.new(0,0,0,0)
preloadBtn.BackgroundColor3 = Color3.fromRGB(30,60,90)
preloadBtn.BackgroundTransparency = 0.05; preloadBtn.Text = "Preload Pet Icons"
preloadBtn.Font = Enum.Font.FredokaOne; preloadBtn.TextSize = 7
preloadBtn.TextColor3 = Color3.fromRGB(120,200,255); preloadBtn.Parent = preloadSetupRow
Instance.new("UICorner", preloadBtn).CornerRadius = UDim.new(0,4)
local preloadStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(60,140,220), Thickness=1.2, Transparency=0.2, Parent=preloadBtn})

local _preloadBusy = false
preloadBtn.MouseButton1Click:Connect(function()
    if _preloadBusy then return end
    _preloadBusy = true

    task.spawn(function()
        local ContentProvider = game:GetService("ContentProvider")

        -- Collect all pet image IDs from InventoryDB
        local images = {}
        local seen = {}
        pcall(function()
            for id, data in pairs(InventoryDB.pets or {}) do
                local img = data.image or data.thumbnail
                if img and img ~= "" and img ~= "rbxassetid://0" and not seen[img] then
                    seen[img] = true
                    -- Create a temp ImageLabel to preload via PreloadAsync
                    local lbl = mk("ImageLabel", {Image=img})
                    table.insert(images, lbl)
                end
            end
        end)

        local total = #images
        if total == 0 then
            preloadBtn.Text = "No images found!"
            task.delay(2, function()
                preloadBtn.Text = "Preload Pet Icons"
                _preloadBusy = false
            end)
            return
        end

        preloadBtn.Text = "Preloading 0/"..total.."..."

        -- Preload in batches of 20
        local done = 0
        local BATCH = 20
        for i = 1, #images, BATCH do
            local batch = {}
            for j = i, math.min(i + BATCH - 1, #images) do
                table.insert(batch, images[j])
            end
            pcall(function()
                ContentProvider:PreloadAsync(batch)
            end)
            done = done + #batch
            preloadBtn.Text = "Preloading "..done.."/"..total.."..."
            task.wait()
        end

        -- Clean up temp labels
        for _, lbl in ipairs(images) do lbl:Destroy() end

        preloadBtn.Text = "✓ Done! ("..total.." icons)"
        preloadBtn.TextColor3 = Color3.fromRGB(100,255,150)
        task.delay(3, function()
            preloadBtn.Text = "Preload Pet Icons"
            preloadBtn.TextColor3 = Color3.fromRGB(120,200,255)
            _preloadBusy = false
        end)
    end)
end)

local setupLiveBtn = mk("TextButton", {Size=UDim2.new(0.5,-3,1,0), Position=UDim2.new(0.5,3,0,0), BackgroundColor3=Color3.fromRGB(220, 140, 20), BackgroundTransparency=0.05, Text="⚡ Setup Live", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255, 240, 180), Parent=preloadSetupRow})
Instance.new("UICorner", setupLiveBtn).CornerRadius = UDim.new(0, 4)
local setupLiveStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255, 200, 60), Thickness=1.2, Transparency=0.2, Parent=setupLiveBtn})

local setupLiveStatusLbl = mk("TextLabel", {Size=UDim2.new(1, 0, 0, 0), BackgroundTransparency=1, Text="", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(130, 230, 150), TextXAlignment=Enum.TextXAlignment.Center, Parent=miscFrame})

-- Tiered list toggle row
local tieredRow = mk("Frame", {Size=UDim2.new(1,0,0,11), BackgroundTransparency=1, Parent=miscFrame})
local tieredLbl = mk("TextLabel", {Size=UDim2.new(0.65,0,1,0), BackgroundTransparency=1, Text="Tiered High Tier List", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=tieredRow})
local tieredToggleBtn = mk("TextButton", {Size=UDim2.new(0.33,0,1,0), Position=UDim2.new(0.67,0,0,0), BackgroundColor3=Color3.fromRGB(80,30,30), Text="OFF", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255,90,90), BorderSizePixel=0, Parent=tieredRow})
Instance.new("UICorner", tieredToggleBtn).CornerRadius = UDim.new(0,3)
local tieredToggleStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255,60,60), Thickness=0.7, Transparency=0.3, Parent=tieredToggleBtn})
_G._tieredToggleBtn = tieredToggleBtn; _G._tieredToggleStroke = tieredToggleStroke
tieredToggleBtn.MouseButton1Click:Connect(function()
    _useTieredList = not _useTieredList
    tieredToggleBtn.Text             = _useTieredList and "ON"  or "OFF"
    tieredToggleBtn.BackgroundColor3 = _useTieredList and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)
    tieredToggleBtn.TextColor3       = _useTieredList and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
    tieredToggleStroke.Color         = _useTieredList and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)
end)

setupLiveBtn.MouseButton1Click:Connect(function()
    setupLiveBtn.Text = "Setting up..."
    setupLiveBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)

    task.spawn(function()
        local function setStatus(txt)
            setupLiveStatusLbl.Text = txt
        end

        setStatus("Setting delays...")
        CONFIG.AUTO_ACCEPT_DELAY  = 0.5
        CONFIG.AUTO_CONFIRM_DELAY = 0.5
        if _G._acceptBox   then _G._acceptBox.Text   = "0.5" end
        if _G._confirmBox  then _G._confirmBox.Text  = "0.5" end

        CONFIG.SPECTATOR_COUNT = 5
        if _G._spectatorBox then _G._spectatorBox.Text = "5" end

        task.wait(0.2)

        setStatus("Spawning all variants...")
        if _G._setupLiveRunSpawnAllVariants then
            _G._setupLiveRunSpawnAllVariants()
            local t0 = tick()
            local allVBtn = _G._setupLiveSpawnAllVariantsBtn
            if allVBtn then
                repeat task.wait(0.5) until allVBtn.Text == "Spawn All Variants" or tick()-t0 > 60
            end
        end

        task.wait(0.5)

        setStatus("Spawning fake inventory...")
        if _G._setupLiveRunFakeInv then
            _G._setupLiveRunFakeInv()
            local t0 = tick()
            local fInvBtn = _G._setupLiveFakeInvBtn
            if fInvBtn then
                repeat task.wait(0.5) until (fInvBtn.Text == "Spawn Fake Inventory" or fInvBtn.Text:find("Spawned")) or tick()-t0 > 30
            end
        end

        task.wait(0.5)

        setStatus("Spawning fake trade history...")
        if _G._setupLiveRunFakeHistory then
            _G._setupLiveRunFakeHistory()
            local t0 = tick()
            local fHistBtn = _G._setupLiveFakeHistoryBtn
            if fHistBtn then
                repeat task.wait(0.5) until fHistBtn.Text == "Spawn Fake Trade History" or tick()-t0 > 60
            end
        end

        task.wait(0.5)

        setStatus("Spawning fake profile...")
        pcall(function()
            for i, name in ipairs(HIGH_TIER_PETS) do
                if name:lower():find("bat") and name:lower():find("dragon") then
                    if _G._fpSetPet then _G._fpSetPet(i, name) end
                    break
                end
            end
            if _G._fpSetProps then
                _G._fpSetProps({ mega_neon=true, neon=false, flyable=true, rideable=true })
            end
        end)
        if _G._setupLiveRunFakeProfile then
            _G._setupLiveRunFakeProfile()
            local t0 = tick()
            local fProfBtn = _G._setupLiveFakeProfileBtn
            if fProfBtn then
                repeat task.wait(0.5) until fProfBtn.Text == "Spawn Fake Profile" or tick()-t0 > 60
            end
        end

        setStatus("Enabling tabs...")
        if not _useTieredList then
            _useTieredList = true
            pcall(function()
                _G._tieredToggleBtn.Text = "ON"
                _G._tieredToggleBtn.BackgroundColor3 = Color3.fromRGB(30,80,50)
                _G._tieredToggleBtn.TextColor3 = Color3.fromRGB(80,255,130)
                _G._tieredToggleStroke.Color = Color3.fromRGB(0,255,100)
            end)
        end
        if not _chatTabEnabled then
            _chatTabEnabled = true
            _setChatTabVisible(true)
            pcall(function()
                _G._chatToggleBtn.Text = "ON"
                _G._chatToggleBtn.BackgroundColor3 = Color3.fromRGB(30,80,50)
                _G._chatToggleBtn.TextColor3 = Color3.fromRGB(80,255,130)
                _G._chatToggleStroke.Color = Color3.fromRGB(0,255,100)
            end)
        end
        setStatus("✅ Live setup complete!")
        setupLiveBtn.Text = "⚡ Setup Live"
        setupLiveBtn.BackgroundColor3 = Color3.fromRGB(220, 140, 20)
        task.delay(3, function() setupLiveStatusLbl.Text = "" end)
    end)
end)

local _spawnToggleEnabled = true
local spawnToggleRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 11), BackgroundTransparency=1, Parent=miscFrame})

local spawnToggleLbl = mk("TextLabel", {Size=UDim2.new(0.65, 0, 1, 0), BackgroundTransparency=1, Text="Show Spawn Tab", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=spawnToggleRow})

local spawnToggleBtn = mk("TextButton", {Size=UDim2.new(0.33, 0, 1, 0), Position=UDim2.new(0.67, 0, 0, 0), BackgroundColor3=Color3.fromRGB(30,80,50), Text="ON", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(80,255,130), Parent=spawnToggleRow})
Instance.new("UICorner", spawnToggleBtn).CornerRadius = UDim.new(0, 3)
local spawnToggleStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0,255,100), Thickness=0.7, Transparency=0.3, Parent=spawnToggleBtn})
_G._spawnToggleBtn = spawnToggleBtn; _G._spawnToggleStroke = spawnToggleStroke
_setSpawnTabVisible(true)

spawnToggleBtn.MouseButton1Click:Connect(function()
    _spawnToggleEnabled = not _spawnToggleEnabled
    _setSpawnTabVisible(_spawnToggleEnabled)
    spawnToggleBtn.Text             = _spawnToggleEnabled and "ON"  or "OFF"
    spawnToggleBtn.BackgroundColor3 = _spawnToggleEnabled and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)
    spawnToggleBtn.TextColor3       = _spawnToggleEnabled and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
    spawnToggleStroke.Color         = _spawnToggleEnabled and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)
end)
end  -- register-relief: end misc-tab UI scope

local antiToggleRow = mk("Frame", {Size=UDim2.new(1,0,0,11), BackgroundTransparency=1, Parent=miscFrame})
local antiToggleLbl = mk("TextLabel", {Size=UDim2.new(0.65,0,1,0), BackgroundTransparency=1, Text="Show Anti Tab", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=antiToggleRow})
local antiToggleBtn = mk("TextButton", {Size=UDim2.new(0.33,0,1,0), Position=UDim2.new(0.67,0,0,0), BackgroundColor3=Color3.fromRGB(30,80,50), Text="ON", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(80,255,130), Parent=antiToggleRow})
Instance.new("UICorner", antiToggleBtn).CornerRadius = UDim.new(0,3)
local antiToggleStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0,255,100), Thickness=0.7, Transparency=0.3, Parent=antiToggleBtn})
_G._antiToggleBtn = antiToggleBtn; _G._antiToggleStroke = antiToggleStroke
_antiTabEnabled = true; _setAntiTabVisible(true)
antiToggleBtn.MouseButton1Click:Connect(function()
    _antiTabEnabled = not _antiTabEnabled
    _setAntiTabVisible(_antiTabEnabled)
    antiToggleBtn.Text             = _antiTabEnabled and "ON"  or "OFF"
    antiToggleBtn.BackgroundColor3 = _antiTabEnabled and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)
    antiToggleBtn.TextColor3       = _antiTabEnabled and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
    antiToggleStroke.Color         = _antiTabEnabled and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)
end)

local chatToggleRow = mk("Frame", {Size=UDim2.new(1,0,0,11), BackgroundTransparency=1, Parent=miscFrame})
local chatToggleLbl = mk("TextLabel", {Size=UDim2.new(0.65,0,1,0), BackgroundTransparency=1, Text="Show Chat Tab", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=chatToggleRow})
local chatToggleBtn = mk("TextButton", {Size=UDim2.new(0.33,0,1,0), Position=UDim2.new(0.67,0,0,0), BackgroundColor3=Color3.fromRGB(30,80,50), Text="ON", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(80,255,130), Parent=chatToggleRow})
Instance.new("UICorner", chatToggleBtn).CornerRadius = UDim.new(0,3)
local chatToggleStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0,255,100), Thickness=0.7, Transparency=0.3, Parent=chatToggleBtn})
_G._chatToggleBtn = chatToggleBtn; _G._chatToggleStroke = chatToggleStroke
_chatTabEnabled = true; _setChatTabVisible(true)
chatToggleBtn.MouseButton1Click:Connect(function()
    _chatTabEnabled = not _chatTabEnabled
    _setChatTabVisible(_chatTabEnabled)
    chatToggleBtn.Text             = _chatTabEnabled and "ON"  or "OFF"
    chatToggleBtn.BackgroundColor3 = _chatTabEnabled and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)
    chatToggleBtn.TextColor3       = _chatTabEnabled and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
    chatToggleStroke.Color         = _chatTabEnabled and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)
end)

do  -- ===== Misc page system: Page 1 (settings) / Page 2 (Self-Badge) =====
local miscTab = tabFrames["Misc"]

-- Page 2 overlay — starts BELOW the tab buttons (y=30) so the tabs stay visible & clickable
local page2 = mk("Frame", {Name="MiscPage2", Size=UDim2.new(1,0,1,-30), Position=UDim2.new(0,0,0,30), BackgroundColor3=Color3.fromRGB(30,30,40), BorderSizePixel=0, ZIndex=6, Visible=false, Parent=mainFrame})
-- Invisible catcher: a Frame doesn't block input, so this button swallows clicks meant for page-1 buttons underneath
mk("TextButton", {Size=UDim2.new(1,12,1,10), Position=UDim2.new(0,-6,0,-5), BackgroundTransparency=1, Text="", AutoButtonColor=false, ZIndex=6, Parent=page2})
mk("UIPadding", {PaddingTop=UDim.new(0,5), PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,6), Parent=page2})

mk("TextLabel", {Size=UDim2.new(1,0,0,11), Position=UDim2.new(0,0,0,1), BackgroundTransparency=1, Text="Self Badge", Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=Color3.fromRGB(190,34,230), TextXAlignment=Enum.TextXAlignment.Left, ZIndex=7, Parent=page2})

local BADGES = {"founder","developer","staff","influencer"}
local LABELS  = {founder="Founder", developer="Developer", staff="Staff", influencer="Influencer"}
local function isBadge(b) for _,x in ipairs(BADGES) do if x==b then return true end end return false end
local selectedBadge = isBadge(CONFIG.SELF_BADGE_TAG) and CONFIG.SELF_BADGE_TAG or "founder"
local badgeEnabled  = (CONFIG.SELF_BADGE_TAG or "") ~= ""
local function applyBadge() CONFIG.SELF_BADGE_TAG = badgeEnabled and selectedBadge or "" end

-- Single row: [ON/OFF toggle]  [badge dropdown]  side by side
local row = mk("Frame", {Size=UDim2.new(1,0,0,15), Position=UDim2.new(0,0,0,15), BackgroundTransparency=1, ZIndex=7, Parent=page2})

local toggleBtn = mk("TextButton", {Size=UDim2.new(0.42,-2,1,0), BackgroundColor3=Color3.fromRGB(80,30,30), Text="OFF", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(255,90,90), ZIndex=7, Parent=row})
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0,3)
local toggleStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255,60,60), Thickness=0.7, Transparency=0.3, Parent=toggleBtn})

local ddBtn = mk("TextButton", {Size=UDim2.new(0.58,-2,1,0), Position=UDim2.new(0.42,2,0,0), BackgroundColor3=Color3.fromRGB(40,40,52), Text=LABELS[selectedBadge].."  ▾", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(225,225,235), ZIndex=7, Parent=row})
Instance.new("UICorner", ddBtn).CornerRadius = UDim.new(0,3)
mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.7, Transparency=0.4, Parent=ddBtn})

-- Dropdown list (expands under the dropdown button)
local ddList = mk("Frame", {Size=UDim2.new(0.58,-2,0,0), AutomaticSize=Enum.AutomaticSize.Y, Position=UDim2.new(0.42,2,0,17), BackgroundColor3=Color3.fromRGB(40,40,52), BorderSizePixel=0, ZIndex=9, Visible=false, Parent=row})
Instance.new("UICorner", ddList).CornerRadius = UDim.new(0,3)
mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.7, Transparency=0.4, Parent=ddList})
mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Parent=ddList})

local function refreshUI()
    toggleBtn.Text = badgeEnabled and "ON" or "OFF"
    toggleBtn.BackgroundColor3 = badgeEnabled and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)
    toggleBtn.TextColor3 = badgeEnabled and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
    toggleStroke.Color = badgeEnabled and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)
    ddBtn.Text = LABELS[selectedBadge].."  ▾"
end
for i,b in ipairs(BADGES) do
    local opt = mk("TextButton", {Size=UDim2.new(1,0,0,14), BackgroundColor3=Color3.fromRGB(40,40,52), Text=LABELS[b], Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(215,215,225), LayoutOrder=i, ZIndex=10, Parent=ddList})
    opt.MouseButton1Click:Connect(function() selectedBadge=b; applyBadge(); ddList.Visible=false; refreshUI() end)
end
ddBtn.MouseButton1Click:Connect(function() ddList.Visible = not ddList.Visible end)
toggleBtn.MouseButton1Click:Connect(function() badgeEnabled = not badgeEnabled; applyBadge(); refreshUI() end)

-- Auto Offer Pets controls (engine + builder defined near the top of the script)
if _G._aoBuildControls then _G._aoBuildControls(page2) end

-- Manual Block toggle (Page 2). OFF by default; when ON, silentBlockPlayer shows the native
-- block prompt shoved to the LEFT edge of the screen (backdrop hidden) so you click Block
-- yourself, instead of the silent auto-hide + confirm. Read via _G._manualBlockMode.
_G._manualBlockMode = false
mk("TextLabel", {Size=UDim2.new(1,0,0,11), Position=UDim2.new(0,0,0,106), BackgroundTransparency=1, Text="Block", Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=Color3.fromRGB(190,34,230), TextXAlignment=Enum.TextXAlignment.Left, ZIndex=7, Parent=page2})
local mbRow = mk("Frame", {Size=UDim2.new(1,0,0,15), Position=UDim2.new(0,0,0,120), BackgroundTransparency=1, ZIndex=7, Parent=page2})
mk("TextLabel", {Size=UDim2.new(0.6,0,1,0), BackgroundTransparency=1, Text="Manual Block", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(225,225,235), TextXAlignment=Enum.TextXAlignment.Left, ZIndex=7, Parent=mbRow})
local mbToggle = mk("TextButton", {Size=UDim2.new(0.38,0,1,0), Position=UDim2.new(0.62,0,0,0), BackgroundColor3=Color3.fromRGB(80,30,30), Text="OFF", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(255,90,90), ZIndex=7, Parent=mbRow})
Instance.new("UICorner", mbToggle).CornerRadius = UDim.new(0,3)
local mbStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255,60,60), Thickness=0.7, Transparency=0.3, Parent=mbToggle})
mbToggle.MouseButton1Click:Connect(function()
    _G._manualBlockMode = not _G._manualBlockMode
    local on = _G._manualBlockMode
    mbToggle.Text = on and "ON" or "OFF"
    mbToggle.BackgroundColor3 = on and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)
    mbToggle.TextColor3 = on and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
    mbStroke.Color = on and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)
end)

-- Anti Botter Block: when ON, blocking completely skips the in-game prompt (silent AND manual)
-- and blocks via the antibotter.lol HTTP API — so a bugged client never shows a block prompt.
local abRow = mk("Frame", {Size=UDim2.new(1,0,0,15), Position=UDim2.new(0,0,0,138), BackgroundTransparency=1, ZIndex=7, Parent=page2})
mk("TextLabel", {Size=UDim2.new(0.6,0,1,0), BackgroundTransparency=1, Text="Anti Botter Block", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(225,225,235), TextXAlignment=Enum.TextXAlignment.Left, ZIndex=7, Parent=abRow})
local abToggle = mk("TextButton", {Size=UDim2.new(0.38,0,1,0), Position=UDim2.new(0.62,0,0,0), BackgroundColor3=Color3.fromRGB(80,30,30), Text="OFF", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(255,90,90), ZIndex=7, Parent=abRow})
Instance.new("UICorner", abToggle).CornerRadius = UDim.new(0,3)
local abStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255,60,60), Thickness=0.7, Transparency=0.3, Parent=abToggle})
abToggle.MouseButton1Click:Connect(function()
    _G._antiBotterMode = not _G._antiBotterMode
    local on = _G._antiBotterMode
    abToggle.Text = on and "ON" or "OFF"
    abToggle.BackgroundColor3 = on and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)
    abToggle.TextColor3 = on and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
    abStroke.Color = on and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)
end)

-- "Change Keybinds to Mo Layout" button — applies the preset defined on page 1 (via _G._applyMoLayout).
local moLayoutBtn = mk("TextButton", {Size=UDim2.new(1,0,0,14), Position=UDim2.new(0,0,0,158), BackgroundColor3=Color3.fromRGB(40,40,55), BackgroundTransparency=0.1, Text="Change Keybinds to Mo Layout", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(180,180,220), ZIndex=7, Parent=page2})
Instance.new("UICorner", moLayoutBtn).CornerRadius = UDim.new(0,3)
mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.8, Transparency=0.3, Parent=moLayoutBtn})
moLayoutBtn.MouseButton1Click:Connect(function()
    if _G._applyMoLayout then _G._applyMoLayout() end
    moLayoutBtn.Text = "Keybinds set to Mo Layout!"
    moLayoutBtn.TextColor3 = Color3.fromRGB(100,255,140)
    task.delay(1.5, function()
        moLayoutBtn.Text = "Change Keybinds to Mo Layout"
        moLayoutBtn.TextColor3 = Color3.fromRGB(180,180,220)
    end)
end)

-- Saves button — pops out the Cloud Saves GUI (Firebase, keyed by HWID).
local savesBtn = mk("TextButton", {Size=UDim2.new(1,0,0,14), Position=UDim2.new(0,0,0,175), BackgroundColor3=Color3.fromRGB(45,35,60), BackgroundTransparency=0.1, Text="Saves", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(210,180,255), ZIndex=7, Parent=page2})
Instance.new("UICorner", savesBtn).CornerRadius = UDim.new(0,3)
mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.8, Transparency=0.3, Parent=savesBtn})
savesBtn.MouseButton1Click:Connect(function()
    if _G._openSavesBoard then _G._openSavesBoard() end
end)

-- Disable Expired Popups: hides the game's "Trade request from X has expired!" dialogs
-- (which spam while auto-declining requests during a mock trade). Read via _G._hideExpiredDialogs.
_G._hideExpiredDialogs = false
local exRow = mk("Frame", {Size=UDim2.new(1,0,0,15), Position=UDim2.new(0,0,0,192), BackgroundTransparency=1, ZIndex=7, Parent=page2})
mk("TextLabel", {Size=UDim2.new(0.6,0,1,0), BackgroundTransparency=1, Text="Hide Expired Popups", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(225,225,235), TextXAlignment=Enum.TextXAlignment.Left, ZIndex=7, Parent=exRow})
local exToggle = mk("TextButton", {Size=UDim2.new(0.38,0,1,0), Position=UDim2.new(0.62,0,0,0), BackgroundColor3=Color3.fromRGB(80,30,30), Text="OFF", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(255,90,90), ZIndex=7, Parent=exRow})
Instance.new("UICorner", exToggle).CornerRadius = UDim.new(0,3)
local exStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255,60,60), Thickness=0.7, Transparency=0.3, Parent=exToggle})
exToggle.MouseButton1Click:Connect(function()
    _G._hideExpiredDialogs = not _G._hideExpiredDialogs
    local on = _G._hideExpiredDialogs
    exToggle.Text = on and "ON" or "OFF"
    exToggle.BackgroundColor3 = on and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)
    exToggle.TextColor3 = on and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
    exStroke.Color = on and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)
end)

-- Spam Popup: repeatedly shows the "An Adopt Me admin gave you: [pet]" ItemPreviewDialog.
local _spamAdminActive = false
local _spamAdminThread = nil
local _spamAdminMsg    = "An Adopt Me admin gave you: "
local function doSpamAdminDialog()
    while _spamAdminActive do
        pcall(function()
            pcall(setthreadidentity, 2)
            local petName = HIGH_TIER_PETS[math.random(1, #HIGH_TIER_PETS)]
            local petId, kd
            for id, item in pairs(InventoryDB.pets or {}) do
                if item.name and item.name:lower() == petName:lower() then
                    petId = id; kd = KindDB[id]; break
                end
            end
            if not petId or not kd then return end
            local v = math.random(1, 12)
            UIManager.apps.DialogApp:dialog({
                dialog_type = "ItemPreviewDialog",
                text        = _spamAdminMsg .. petName,
                item        = {
                    id = petId, name = petName, category = "pets", kind = kd.kind or petId,
                    properties = {
                        pet_trick_level = math.random(1, 5),
                        neon      = v >= 5 and v <= 8,
                        mega_neon = v >= 1 and v <= 4,
                        flyable   = v == 1 or v == 3 or v == 5 or v == 6 or v == 9 or v == 10,
                        rideable  = v == 1 or v == 2 or v == 5 or v == 7 or v == 9 or v == 11,
                        age       = math.random(1, 900000), ailments_completed = 0, rp_name = ""
                    }
                },
                button = "Okay!", yields = true
            })
            pcall(setthreadidentity, 8)
        end)
        RunService.Heartbeat:Wait()
    end
end
local spamPopupRow = mk("Frame", {Size=UDim2.new(1,0,0,15), Position=UDim2.new(0,0,0,210), BackgroundTransparency=1, ZIndex=7, Parent=page2})
mk("TextLabel", {Size=UDim2.new(0.6,0,1,0), BackgroundTransparency=1, Text="Spam Popup", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(225,225,235), TextXAlignment=Enum.TextXAlignment.Left, ZIndex=7, Parent=spamPopupRow})
local spamPopupToggle = mk("TextButton", {Size=UDim2.new(0.38,0,1,0), Position=UDim2.new(0.62,0,0,0), BackgroundColor3=Color3.fromRGB(80,30,30), Text="OFF", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(255,90,90), ZIndex=7, Parent=spamPopupRow})
Instance.new("UICorner", spamPopupToggle).CornerRadius = UDim.new(0,3)
local spamPopupStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255,60,60), Thickness=0.7, Transparency=0.3, Parent=spamPopupToggle})
spamPopupToggle.MouseButton1Click:Connect(function()
    _spamAdminActive = not _spamAdminActive
    local on = _spamAdminActive
    spamPopupToggle.Text = on and "ON" or "OFF"
    spamPopupToggle.BackgroundColor3 = on and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)
    spamPopupToggle.TextColor3 = on and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
    spamPopupStroke.Color = on and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)
    if on then
        _spamAdminThread = task.spawn(doSpamAdminDialog)
    else
        if _spamAdminThread then task.cancel(_spamAdminThread); _spamAdminThread = nil end
    end
end)

-- Back / forward arrows — the down-arrow decal rotated to point left (+90°) and right (-90°)
-- Arrow decal 153287168 — its UNDERLYING IMAGE asset (153287167) so Rotation renders (rbxthumb won't rotate here)
local ARROW_IMG = "rbxassetid://153287167"
local navBack = mk("ImageButton", {Size=UDim2.new(0,14,0,14), Position=UDim2.new(0.5,-15,1,-15), BackgroundTransparency=1, Image=ARROW_IMG, ImageColor3=Color3.fromRGB(110,110,120), Rotation=90, ScaleType=Enum.ScaleType.Fit, ZIndex=52, Visible=false, Parent=mainFrame})
local navFwd = mk("ImageButton", {Size=UDim2.new(0,14,0,14), Position=UDim2.new(0.5,1,1,-15), BackgroundTransparency=1, Image=ARROW_IMG, ImageColor3=Color3.fromRGB(200,180,255), Rotation=-90, ScaleType=Enum.ScaleType.Fit, ZIndex=52, Visible=false, Parent=mainFrame})

local function setPage(n)
    ddList.Visible = false
    page2.Visible  = (n==2) and miscTab.Visible
    navBack.Visible = miscTab.Visible
    navFwd.Visible  = miscTab.Visible
    navBack.ImageColor3 = (n==2) and Color3.fromRGB(200,180,255) or Color3.fromRGB(110,110,120)
    navFwd.ImageColor3  = (n==1) and Color3.fromRGB(200,180,255) or Color3.fromRGB(110,110,120)
end
navFwd.MouseButton1Click:Connect(function() setPage(2) end)
navBack.MouseButton1Click:Connect(function() setPage(1) end)
miscTab:GetPropertyChangedSignal("Visible"):Connect(function() setPage(1) end)
setPage(1)
refreshUI()
end

end -- MISC TAB do block

do
local spawnFrame = tabFrames["Spawn"]

local _BackpackFavoriteTracker = nil
local _BackpackLockTracker = nil
pcall(function() _BackpackFavoriteTracker = load("BackpackFavoriteTracker") end)
pcall(function() _BackpackLockTracker = load("BackpackLockTracker") end)

local _allPetNames = {}
local _petNameToId = {}
for kindId, entry in pairs(InventoryDB.pets or {}) do
    if entry.name then
        table.insert(_allPetNames, entry.name)
        _petNameToId[entry.name:lower()] = kindId
    end
end
table.sort(_allPetNames, function(a, b) return a:lower() < b:lower() end)

local spawnFlags   = { F = false, R = false, N = false, M = false }
local _spawnAge    = 6  -- default full grown

local _ageOptions = {
    { label = "Newborn",    value = 0 },
    { label = "Junior",     value = 1 },
    { label = "Pre-Teen",   value = 2 },
    { label = "Teen",       value = 3 },
    { label = "Post-Teen",  value = 4 },
    { label = "Full Grown", value = 5 },
    { label = "Luminous",   value = 6 },
}

local function spawnFlagsToProps()
    return { flyable   = spawnFlags.F, rideable  = spawnFlags.R, neon      = spawnFlags.N, mega_neon = spawnFlags.M, age       = _spawnAge, ailments_completed = 0, pet_trick_level    = 0, }
end

local function doSpawnPet(kindId, extraProps)
    -- Otherwise merge onto current spawnFlags
    local props
    if extraProps and extraProps.mega_neon ~= nil then
        props = {}
        for k,v in pairs(extraProps) do props[k] = v end
    else
        props = spawnFlagsToProps()
        if extraProps then for k,v in pairs(extraProps) do props[k] = v end end
    end
    if not props.rp_name or props.rp_name == "" then
        props.rp_name = generatePetName(kindId)
    end
    if not props.age               then props.age               = 1 end
    if not props.ailments_completed then props.ailments_completed = 0 end
    if not props.pet_trick_level   then props.pet_trick_level   = 0 end
    local uid = HttpService:GenerateGUID(false)
    local newItem = {
        unique        = uid,
        category      = "pets",
        kind          = kindId,
        id            = kindId,
        newness_order = math.random(1, 900000),
        properties    = props,
    }
    _addToInventory(newItem)
end

local spawnLayout = mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0, 4), Parent=spawnFrame})

local searchBox = mk("TextBox", {Size=UDim2.new(1, 0, 0, 14), BackgroundColor3=Color3.fromRGB(32, 32, 48), BackgroundTransparency=0.2, Text="", PlaceholderText="Search pet name...", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255, 255, 255), PlaceholderColor3=Color3.fromRGB(120, 120, 140), ClearTextOnFocus=false, TextXAlignment=Enum.TextXAlignment.Left, Parent=spawnFrame})
Instance.new("UICorner", searchBox).CornerRadius = UDim.new(0, 3)
local searchStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=1.0, Transparency=0.3, Parent=searchBox})
local searchPad = mk("UIPadding", {PaddingLeft=UDim.new(0, 4), PaddingRight=UDim.new(0, 4), Parent=searchBox})

local autocompleteFrame = mk("Frame", {Size=UDim2.new(0, 110, 0, 0), BackgroundColor3=Color3.fromRGB(30, 30, 42), BorderSizePixel=0, Visible=false, ZIndex=20, Parent=mainFrame})
Instance.new("UICorner", autocompleteFrame).CornerRadius = UDim.new(0, 3)
local autoStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.7, Transparency=0.3, Parent=autocompleteFrame})
local autoLayout = mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Parent=autocompleteFrame})

local _autoMatches = {}
local _selectedAutoIdx = 0

local function hideAutocomplete()
    autocompleteFrame.Visible = false
    _autoMatches = {}
    _selectedAutoIdx = 0
end

local function applyAutoSelection(idx)
    if not _autoMatches[idx] then return end
    _selectedAutoIdx = idx
    for i, btn in ipairs(autocompleteFrame:GetChildren()) do
        if btn:IsA("TextButton") then
            btn.BackgroundColor3 = (i == idx)
                and Color3.fromRGB(80, 40, 120)
                or  Color3.fromRGB(30, 30, 42)
        end
    end
end

local function commitAutocomplete(idx)
    local name = _autoMatches[idx]
    if not name then return end
    searchBox.Text = name
    hideAutocomplete()
end

local function updateAutocomplete(text)
    for _, c in ipairs(autocompleteFrame:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    _autoMatches = {}
    _selectedAutoIdx = 0

    if text == "" then hideAutocomplete() return end

    local lower = text:lower()
    local matches = {}
    for _, name in ipairs(_allPetNames) do
        if name:lower():sub(1, #lower) == lower then
            table.insert(matches, name)
            if #matches >= 5 then break end
        end
    end
    -- Also do contains search if fewer than 5 prefix matches
    if #matches < 5 then
        for _, name in ipairs(_allPetNames) do
            if name:lower():find(lower, 1, true) and name:lower():sub(1, #lower) ~= lower then
                table.insert(matches, name)
                if #matches >= 5 then break end
            end
        end
    end

    if #matches == 0 then hideAutocomplete() return end

    _autoMatches = matches
    for i, name in ipairs(matches) do
        local btn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 13), BackgroundColor3=Color3.fromRGB(30, 30, 42), BackgroundTransparency=0, Text=name, Font=Enum.Font.FredokaOne, TextSize=6, TextColor3=Color3.fromRGB(220, 220, 255), TextXAlignment=Enum.TextXAlignment.Left, BorderSizePixel=0, ZIndex=21, LayoutOrder=i, Parent=autocompleteFrame})
        local bpad = mk("UIPadding", {PaddingLeft=UDim.new(0, 4), Parent=btn})
        btn.MouseButton1Click:Connect(function()
            commitAutocomplete(i)
        end)
    end

    local absPos = searchBox.AbsolutePosition
    local frameAbsPos = mainFrame.AbsolutePosition
    local relX = absPos.X - frameAbsPos.X
    local relY = absPos.Y - frameAbsPos.Y + searchBox.AbsoluteSize.Y + 2
    local dropH = #matches * 13
    autocompleteFrame.Position = UDim2.new(0, relX, 0, relY); autocompleteFrame.Size     = UDim2.new(0, searchBox.AbsoluteSize.X, 0, dropH)
    autocompleteFrame.Visible  = true
end

searchBox:GetPropertyChangedSignal("Text"):Connect(function()
    updateAutocomplete(searchBox.Text)
end)

UserInputService.InputBegan:Connect(function(input, gpe)
    if not searchBox:IsFocused() then return end
    if input.KeyCode == Enum.KeyCode.Tab then
        if #_autoMatches > 0 then
            local next = (_selectedAutoIdx % #_autoMatches) + 1
            applyAutoSelection(next)
            commitAutocomplete(next)
        end
    elseif input.KeyCode == Enum.KeyCode.Down then
        if #_autoMatches > 0 then
            applyAutoSelection((_selectedAutoIdx % #_autoMatches) + 1)
        end
    elseif input.KeyCode == Enum.KeyCode.Up then
        if #_autoMatches > 0 then
            local prev = _selectedAutoIdx - 1
            if prev < 1 then prev = #_autoMatches end
            applyAutoSelection(prev)
        end
    elseif input.KeyCode == Enum.KeyCode.Return then
        if _selectedAutoIdx > 0 then
            commitAutocomplete(_selectedAutoIdx)
        elseif #_autoMatches > 0 then
            commitAutocomplete(1)
        end
        hideAutocomplete()
    elseif input.KeyCode == Enum.KeyCode.Escape then
        hideAutocomplete()
    end
end)

searchBox.FocusLost:Connect(function()
    task.delay(0.15, hideAutocomplete)
end)

local spawnFlagRow = mk("Frame", {Size=UDim2.new(1, 0, 0, 13), BackgroundTransparency=1, Parent=spawnFrame})

local _spawnFlagDefs = {
    { key="M", col=Color3.fromRGB(170, 0, 255)  },
    { key="N", col=Color3.fromRGB(0, 190, 80)   },
    { key="F", col=Color3.fromRGB(0, 175, 255)  },
    { key="R", col=Color3.fromRGB(255, 45, 145) },
}
local _spawnFlagBtns = {}
local _sfBtnW = 26
local _sfGap  = math.floor((116 - _sfBtnW * 4) / 3)

for i, fd in ipairs(_spawnFlagDefs) do
    local xOff = (i-1) * (_sfBtnW + _sfGap)
    local pb = mk("TextButton", {Size=UDim2.new(0, _sfBtnW, 1, 0), Position=UDim2.new(0, xOff, 0, 0), BackgroundColor3=Color3.fromRGB(32, 32, 48), BackgroundTransparency=0.2, Text=fd.key, Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(220, 220, 255), Parent=spawnFlagRow})
    Instance.new("UICorner", pb).CornerRadius = UDim.new(0, 3)
    local s = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=fd.col, Thickness=0.7, Transparency=0.3, Parent=pb})
    _spawnFlagBtns[fd.key] = { btn=pb, stroke=s, col=fd.col }

    pb.MouseButton1Click:Connect(function()
        if fd.key == "M" and spawnFlags.N then
            spawnFlags.N = false
            local nd = _spawnFlagBtns["N"]
            nd.btn.BackgroundColor3      = Color3.fromRGB(32, 32, 48); nd.btn.BackgroundTransparency = 0.2
            nd.stroke.Color              = nd.col; nd.stroke.Transparency       = 0.3
            nd.stroke.Thickness          = 0.7
        elseif fd.key == "N" and spawnFlags.M then
            spawnFlags.M = false
            local md = _spawnFlagBtns["M"]
            md.btn.BackgroundColor3      = Color3.fromRGB(32, 32, 48); md.btn.BackgroundTransparency = 0.2
            md.stroke.Color              = md.col; md.stroke.Transparency       = 0.3
            md.stroke.Thickness          = 0.7
        end
        spawnFlags[fd.key] = not spawnFlags[fd.key]
        if spawnFlags[fd.key] then
            pb.BackgroundColor3      = Color3.fromRGB(60, 60, 80)
            pb.BackgroundTransparency = 0.1
            s.Color                  = fd.col; s.Transparency           = 0
            s.Thickness              = 1.2
        else
            pb.BackgroundColor3      = Color3.fromRGB(32, 32, 48)
            pb.BackgroundTransparency = 0.2
            s.Color                  = fd.col; s.Transparency           = 0.3
            s.Thickness              = 0.7
        end
    end)
end

local spawnPetBtn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 13), BackgroundColor3=Color3.fromRGB(0, 100, 200), BackgroundTransparency=0.15, Text="Spawn Pet", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255, 255, 255), Parent=spawnFrame})
Instance.new("UICorner", spawnPetBtn).CornerRadius = UDim.new(0, 3)
local spawnPetStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0, 180, 255), Thickness=0.7, Transparency=0.3, Parent=spawnPetBtn})

spawnPetBtn.MouseButton1Click:Connect(function()
    local name = searchBox.Text
    if name == "" then return end
    local kindId = _petNameToId[name:lower()]
    if not kindId then
        local lower = name:lower()
        for n, id in pairs(_petNameToId) do
            if n:find(lower, 1, true) then kindId = id; break end
        end
    end
    if not kindId then
        spawnPetStroke.Color = Color3.fromRGB(255, 60, 60)
        task.delay(0.5, function() spawnPetStroke.Color = Color3.fromRGB(0, 180, 255) end)
        return
    end
    doSpawnPet(kindId)
    spawnPetStroke.Color = Color3.fromRGB(0, 255, 120)
    task.delay(0.4, function() spawnPetStroke.Color = Color3.fromRGB(0, 180, 255) end)
end)

-- Age selector row
local ageRow = mk("Frame", {Size=UDim2.new(1,0,0,13), BackgroundTransparency=1, Parent=spawnFrame})

local agePrevBtn = mk("TextButton", {Size=UDim2.new(0,13,1,0), BackgroundColor3=Color3.fromRGB(32,32,48), BackgroundTransparency=0.2, Text="◀", Font=Enum.Font.GothamBold, TextSize=7, TextColor3=Color3.fromRGB(180,180,220), BorderSizePixel=0, Parent=ageRow})
Instance.new("UICorner", agePrevBtn).CornerRadius = UDim.new(0,3)

local ageLbl = mk("TextButton", {Size=UDim2.new(1,-28,1,0), Position=UDim2.new(0,15,0,0), BackgroundColor3=Color3.fromRGB(32,32,48), BackgroundTransparency=0.2, Text="Luminous (6)", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(220,180,255), BorderSizePixel=0, Parent=ageRow})
Instance.new("UICorner", ageLbl).CornerRadius = UDim.new(0,3)
local ageLblStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.7, Transparency=0.4, Parent=ageLbl})

local ageNextBtn = mk("TextButton", {Size=UDim2.new(0,13,1,0), Position=UDim2.new(1,-13,0,0), BackgroundColor3=Color3.fromRGB(32,32,48), BackgroundTransparency=0.2, Text="▶", Font=Enum.Font.GothamBold, TextSize=7, TextColor3=Color3.fromRGB(180,180,220), BorderSizePixel=0, Parent=ageRow})
Instance.new("UICorner", ageNextBtn).CornerRadius = UDim.new(0,3)

local _ageIdx = 7  -- starts at Luminous (index 7)
local function updateAgeLbl()
    local opt = _ageOptions[_ageIdx]
    ageLbl.Text = opt.label .. " (" .. opt.value .. ")"
    _spawnAge = opt.value
end
updateAgeLbl()
agePrevBtn.MouseButton1Click:Connect(function()
    _ageIdx = _ageIdx > 1 and _ageIdx - 1 or #_ageOptions
    updateAgeLbl()
end)
ageNextBtn.MouseButton1Click:Connect(function()
    _ageIdx = _ageIdx < #_ageOptions and _ageIdx + 1 or 1
    updateAgeLbl()
end)
ageLbl.MouseButton1Click:Connect(function()
    _ageIdx = _ageIdx < #_ageOptions and _ageIdx + 1 or 1
    updateAgeLbl()
end)

local spawnAllVariantsBtn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 13), BackgroundColor3=Color3.fromRGB(100, 30, 180), BackgroundTransparency=0.15, Text="Spawn All Variants", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255, 255, 255), Parent=spawnFrame})
Instance.new("UICorner", spawnAllVariantsBtn).CornerRadius = UDim.new(0, 3)
local spawnAllVStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.7, Transparency=0.3, Parent=spawnAllVariantsBtn})

_G._setupLiveSpawnAllVariantsBtn = spawnAllVariantsBtn
local function _runSpawnAllVariants()
    spawnAllVariantsBtn.Text = "Spawning..."
    spawnAllVStroke.Color = Color3.fromRGB(255, 165, 0)
    task.spawn(function()
        local allSpawnedItems = {}
        local defaultVariants = {
            { name="MFR", mega_neon=true,  neon=false, flyable=true, rideable=true,  age=6 },
            { name="NFR", mega_neon=false, neon=true,  flyable=true, rideable=true,  age=6 },
            { name="FR",  mega_neon=false, neon=false, flyable=true, rideable=true,  age=6 },
        }
        local COPIES_PER_VARIANT = 4
        local allFlagCombos = {
            { mega_neon=false, neon=false, flyable=false, rideable=false },
            { mega_neon=false, neon=false, flyable=true,  rideable=false },
            { mega_neon=false, neon=false, flyable=false, rideable=true  },
            { mega_neon=false, neon=false, flyable=true,  rideable=true  },
            { mega_neon=false, neon=true,  flyable=false, rideable=false },
            { mega_neon=false, neon=true,  flyable=true,  rideable=false },
            { mega_neon=false, neon=true,  flyable=false, rideable=true  },
            { mega_neon=false, neon=true,  flyable=true,  rideable=true  },
            { mega_neon=true,  neon=false, flyable=false, rideable=false },
            { mega_neon=true,  neon=false, flyable=true,  rideable=false },
            { mega_neon=true,  neon=false, flyable=false, rideable=true  },
            { mega_neon=true,  neon=false, flyable=true,  rideable=true  },
        }

        local totalPets = #HIGH_TIER_PETS
        local totalSpawned = 0

        for petIndex, petName in ipairs(HIGH_TIER_PETS) do
            local petId = _petNameToId[petName:lower()]
            if not petId then
                for n, id in pairs(_petNameToId) do
                    if n:find(petName:lower(), 1, true) then petId = id; break end
                end
            end
            if petId then
                for varIdx, variant in ipairs(defaultVariants) do
                    for copy = 1, COPIES_PER_VARIANT do
                        local newness = (totalPets - petIndex) * 20 + (4 - varIdx) * COPIES_PER_VARIANT + (COPIES_PER_VARIANT - copy)
                        local item = _addToInventory({
                            unique     = HttpService:GenerateGUID(false),
                            id         = petId,
                            kind       = petId,
                            category   = "pets",
                            properties = {
                                mega_neon          = variant.mega_neon,
                                neon               = variant.neon,
                                flyable            = variant.flyable,
                                rideable           = variant.rideable,
                                age                = variant.age,
                                trick_level        = 5,
                                ailments_completed = 0,
                                rp_name            = generatePetName(petId),
                                _newness_order     = newness,
                            },
                        })
                        if item then totalSpawned = totalSpawned + 1; table.insert(allSpawnedItems, {item=item, kind=petId}) end
                    end
                end
                for r = 1, 4 do
                    local combo = allFlagCombos[math.random(1, #allFlagCombos)]
                    local newness = (totalPets - petIndex) * 20 - r
                    local item = _addToInventory({
                        unique     = HttpService:GenerateGUID(false),
                        id         = petId,
                        kind       = petId,
                        category   = "pets",
                        properties = {
                            mega_neon          = combo.mega_neon,
                            neon               = combo.neon,
                            flyable            = combo.flyable,
                            rideable           = combo.rideable,
                            age                = math.random(1, 6),
                            trick_level        = math.random(0, 5),
                            ailments_completed = 0,
                            rp_name            = generatePetName(petId),
                            _newness_order     = newness,
                        },
                    })
                    if item then totalSpawned = totalSpawned + 1; table.insert(allSpawnedItems, {item=item, kind=petId}) end
                end
            end
            if petIndex % 10 == 0 then
                task.wait()
            end
        end

        local favouritedCount = 0
        local lockedCount = 0
        local lockedKinds2 = {}
        for _, entry in ipairs(allSpawnedItems) do
            local itemData = entry.item
            local petKind  = entry.kind
            if math.random(1, 100) <= 30 then
                pcall(function()
                    if _BackpackFavoriteTracker and _BackpackFavoriteTracker.set_favorite then
                        _BackpackFavoriteTracker.set_favorite(itemData, true, true)
                        favouritedCount = favouritedCount + 1
                    else
                        local id = (get_thread_identity and get_thread_identity()) or 8
                        setthreadidentity(2)
                        local favs = ClientData.get("backpack_favorites") or {}
                        favs[itemData.unique] = true
                        ClientData.update("backpack_favorites", favs)
                        setthreadidentity(id)
                        favouritedCount = favouritedCount + 1
                    end
                end)
            end
            if not lockedKinds2[petKind] and math.random(1, 100) <= 15 then
                pcall(function()
                    if _BackpackLockTracker and _BackpackLockTracker.set_locked then
                        _BackpackLockTracker.set_locked(itemData, true, true)
                        lockedKinds2[petKind] = true
                        lockedCount = lockedCount + 1
                    else
                        local id = (get_thread_identity and get_thread_identity()) or 8
                        setthreadidentity(2)
                        local locks = ClientData.get("backpack_locks") or {}
                        locks[itemData.unique] = true
                        ClientData.update("backpack_locks", locks)
                        setthreadidentity(id)
                        lockedKinds2[petKind] = true
                        lockedCount = lockedCount + 1
                    end
                end)
            end
        end

        task.defer(function()
            pcall(function() UIManager.apps.BackpackApp:refresh_rendered_items() end)
        end)

        spawnAllVStroke.Color = Color3.fromRGB(0, 255, 120)
        spawnAllVariantsBtn.Text = "Spawned " .. totalSpawned .. " | ♥" .. favouritedCount .. " 🔒" .. lockedCount
        task.delay(3, function()
            spawnAllVariantsBtn.Text = "Spawn All Variants"
            spawnAllVStroke.Color = Color3.fromRGB(190,34,230)
        end)
    end)
end
spawnAllVariantsBtn.MouseButton1Click:Connect(_runSpawnAllVariants)
_G._setupLiveRunSpawnAllVariants = _runSpawnAllVariants






local spawnHighTierBtn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 13), BackgroundColor3=Color3.fromRGB(160, 100, 20), BackgroundTransparency=0.15, Text="Spawn All High Tiers", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255, 255, 255), Parent=spawnFrame})
Instance.new("UICorner", spawnHighTierBtn).CornerRadius = UDim.new(0, 3)
local spawnHTStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255, 180, 0), Thickness=0.7, Transparency=0.3, Parent=spawnHighTierBtn})

spawnHighTierBtn.MouseButton1Click:Connect(function()
    task.spawn(function()
        for _, petName in ipairs(HIGH_TIER_PETS) do
            local kindId = nil
            for id, entry in pairs(InventoryDB.pets or {}) do
                if entry.name and entry.name:lower() == petName:lower() then
                    kindId = id; break
                end
            end
            if kindId then
                doSpawnPet(kindId)
                task.wait(0.05)
            end
        end
    end)
    spawnHTStroke.Color = Color3.fromRGB(0, 255, 120)
    task.delay(0.5, function() spawnHTStroke.Color = Color3.fromRGB(255, 180, 0) end)
end)

local petListBtn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 13), BackgroundColor3=Color3.fromRGB(30, 70, 50), BackgroundTransparency=0.15, Text="Pet List (Browse & Spawn)", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255, 255, 255), Parent=spawnFrame})
Instance.new("UICorner", petListBtn).CornerRadius = UDim.new(0, 3)
local petListStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0, 255, 100), Thickness=0.7, Transparency=0.3, Parent=petListBtn})

petListBtn.MouseButton1Click:Connect(function()
    task.spawn(function()
        local fakeInv = { pets = {} }
        for kindId, entry in pairs(InventoryDB.pets or {}) do
            if entry.name then
                local uid = HttpService:GenerateGUID(false)
                fakeInv.pets[uid] = { unique     = uid, category   = "pets", kind       = kindId, id         = kindId, newness_order = 1, properties = spawnFlagsToProps(), }
            end
        end
        local picked = BackpackApp:pick_item({
            title_override     = "SELECT PET TO SPAWN",
            inventory_override = fakeInv,
            force_no_filters   = true,
            allow_callback     = function() return true end,
        })
        if picked and picked.kind then
            doSpawnPet(picked.kind)
            petListStroke.Color = Color3.fromRGB(0, 255, 120)
            task.delay(0.4, function() petListStroke.Color = Color3.fromRGB(0, 255, 100) end)
        end
    end)
end)

local fakeInvBtn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 13), BackgroundColor3=Color3.fromRGB(90, 50, 160), BackgroundTransparency=0.15, Text="Spawn Fake Inventory", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255, 255, 255), Parent=spawnFrame})
Instance.new("UICorner", fakeInvBtn).CornerRadius = UDim.new(0, 3)
local fakeInvStroke = mk("UIStroke", {Color=Color3.fromRGB(190, 100, 255), Thickness=0.7, Parent=fakeInvBtn})

local FAKE_INV_CATEGORIES = {
    { db = "toys",            category = "toys"            },
    { db = "food",            category = "food"            },
    { db = "gifts",           category = "gifts"           },
    { db = "roleplay",        category = "roleplay"        },
    { db = "stickers",        category = "stickers"        },
    { db = "strollers",       category = "strollers"       },
    { db = "transport",       category = "transport"       },
    { db = "pet_accessories", category = "pet_accessories" },
}

_G._setupLiveFakeInvBtn = fakeInvBtn

-- ─────────────────────────────────────────────────────────────────────────────
-- Fake Inventory: realistic flag weights (mirrors actual Adopt Me trading)
-- FR is the most common real-game combo; megas are rare; plain normals exist too
-- ─────────────────────────────────────────────────────────────────────────────
local _FAKE_INV_FLAG_WEIGHTS = {
    { N=false, M=false, F=true,  R=true,  w=28 }, -- FR         — most common
    { N=false, M=false, F=true,  R=false, w=14 }, -- F only
    { N=false, M=false, F=false, R=false, w=12 }, -- no flags   — newish/non-legendary
    { N=false, M=false, F=false, R=true,  w=6  }, -- R only
    { N=true,  M=false, F=true,  R=true,  w=8  }, -- neon FR
    { N=true,  M=false, F=false, R=false, w=4  }, -- neon plain
    { N=true,  M=false, F=true,  R=false, w=3  }, -- neon F
    { N=false, M=true,  F=true,  R=true,  w=3  }, -- mega FR    — rare
    { N=false, M=true,  F=false, R=false, w=2  }, -- mega plain
}
local _fakeInvFlagTotal = 0
for _, v in ipairs(_FAKE_INV_FLAG_WEIGHTS) do _fakeInvFlagTotal = _fakeInvFlagTotal + v.w end

local function _pickFakeInvFlags(maxLevel)
    local roll = math.random(1, _fakeInvFlagTotal)
    local acc  = 0
    local flags
    for _, v in ipairs(_FAKE_INV_FLAG_WEIGHTS) do
        acc = acc + v.w
        if roll <= acc then
            flags = { neon=v.N, mega_neon=v.M, flyable=v.F, rideable=v.R,
                      age=math.random(1, 6), ailments_completed=0 }
            break
        end
    end
    flags = flags or { neon=false, mega_neon=false, flyable=true, rideable=true,
                       age=math.random(1, 6), ailments_completed=0 }
    -- Respect max neon tier so legendary pet caps make sense
    if maxLevel == "default" then flags.neon = false; flags.mega_neon = false
    elseif maxLevel == "neon" then flags.mega_neon = false end
    return flags
end

local function _runFakeInv()
    fakeInvBtn.Text = "Spawning..."
    fakeInvStroke.Color = Color3.fromRGB(255, 165, 0)
    task.spawn(function()
        local totalSpawned = 0

        -- ── helper: spawn one pet via the working doSpawnPet path ────────────
        local function spawnPet(kindId, flags)
            local ok = pcall(doSpawnPet, kindId, flags)
            if ok then totalSpawned = totalSpawned + 1 end
        end

        -- ── helper: write one non-pet item directly to inventory ─────────────
        local function writeItem(category, kindId)
            local uid = HttpService:GenerateGUID(false)
            pcall(function()
                local id = (get_thread_identity and get_thread_identity()) or 8
                setthreadidentity(2)
                local inv = ClientData.get("inventory")
                if inv then
                    if not inv[category] then inv[category] = {} end
                    inv[category][uid] = {
                        unique        = uid, id = kindId, kind = kindId,
                        category      = category,
                        newness_order = math.random(1, 99999),
                        properties    = {},
                    }
                    totalSpawned = totalSpawned + 1
                end
                setthreadidentity(id)
            end)
        end

        -- ── Step 1: Build pet pools from KindDB (the authority _addToInventory checks)
        -- Cross-validate with InventoryDB.pets so both checks in _addToInventory pass.
        local highTierPool = {}   -- {kindId, max} for legendaries
        local allPetKinds  = {}   -- every non-egg pet kind id

        local nameToKind = {}
        if KindDB then
            for kindId, entry in pairs(KindDB) do
                local name = entry.name or entry.display_name
                if name then
                    local nameLow = name:lower()
                    -- Only include if InventoryDB.pets also knows this kind
                    local invOk = not (InventoryDB and InventoryDB.pets) or
                                  (InventoryDB.pets[kindId] ~= nil)
                    if invOk and not nameLow:find("egg") then
                        nameToKind[nameLow] = kindId
                        table.insert(allPetKinds, kindId)
                    end
                end
            end
        end
        -- Fallback: if KindDB gave nothing, try InventoryDB.pets directly
        if #allPetKinds == 0 and InventoryDB and InventoryDB.pets then
            for kindId, entry in pairs(InventoryDB.pets) do
                if entry.name and not entry.name:lower():find("egg") then
                    nameToKind[entry.name:lower()] = kindId
                    table.insert(allPetKinds, kindId)
                end
            end
        end

        -- Match HIGH_TIER_PETS_TIERED → real kind IDs
        for _, entry in ipairs(HIGH_TIER_PETS_TIERED) do
            local nameLow  = entry.name:lower()
            local realKind = nameToKind[nameLow]
            if not realKind then
                for name, id in pairs(nameToKind) do
                    if name:find(nameLow, 1, true) then realKind = id; break end
                end
            end
            if realKind then
                table.insert(highTierPool, { kind = realKind, max = entry.max })
            end
        end

        -- Shuffle
        for i = #highTierPool, 2, -1 do
            local j = math.random(1, i); highTierPool[i], highTierPool[j] = highTierPool[j], highTierPool[i]
        end
        for i = #allPetKinds, 2, -1 do
            local j = math.random(1, i); allPetKinds[i], allPetKinds[j] = allPetKinds[j], allPetKinds[i]
        end

        -- ── Step 2: Realistic counts ──────────────────────────────────────────
        if #allPetKinds == 0 then
            fakeInvBtn.Text = "No pets in KindDB!"
            fakeInvStroke.Color = Color3.fromRGB(255, 80, 80)
            task.delay(3, function()
                fakeInvBtn.Text = "Spawn Fake Inventory"
                fakeInvStroke.Color = Color3.fromRGB(190, 100, 255)
            end)
            return
        end
        local htCount     = math.random(6, math.min(14, math.max(1, #highTierPool)))
        local fillerCount = math.random(20, 45)   -- random commons/rares

        -- Track per-kind counts for summary label (e.g. "3x Shadow Dragon")
        local kindCounts  = {}  -- kindId -> count
        local kindNames   = {}  -- kindId -> display name
        local function recordSpawn(kindId, flags)
            spawnPet(kindId, flags)
            kindCounts[kindId] = (kindCounts[kindId] or 0) + 1
            if not kindNames[kindId] then
                local e = KindDB and KindDB[kindId]
                kindNames[kindId] = (e and (e.name or e.display_name)) or tostring(kindId)
            end
        end

        -- ── Step 3: High-tier legendaries (with deliberate multi-copies) ──────
        for i = 1, htCount do
            local e = highTierPool[i]
            if not e then break end
            -- Decide how many copies: 1 (55%), 2 (30%), 3 (12%), 4 (3%)
            local r = math.random()
            local copies = r < 0.55 and 1 or r < 0.85 and 2 or r < 0.97 and 3 or 4
            for _ = 1, copies do
                recordSpawn(e.kind, _pickFakeInvFlags(e.max))
            end
            task.wait(0.04)
        end

        -- ── Step 4: Random filler (mix of FR, no-pot, neon etc.) ─────────────
        -- "no pot" = plain flags (flyable=false, rideable=false) already in weights
        local used = {}
        for i = 1, math.min(fillerCount, #allPetKinds) do
            local kindId = allPetKinds[i]
            -- Filler pets: 1 copy most of the time, occasionally 2-3 (stack effect)
            local copies = math.random() < 0.70 and 1 or math.random() < 0.80 and 2 or 3
            for _ = 1, copies do
                recordSpawn(kindId, _pickFakeInvFlags())
            end
            used[kindId] = true
            task.wait(0.03)
        end

        -- ── Step 5: Non-pet categories ────────────────────────────────────────
        for _, catInfo in ipairs(FAKE_INV_CATEGORIES) do
            local dbTable = InventoryDB and InventoryDB[catInfo.db]
            if not dbTable then continue end
            local kindKeys = {}
            for kind in pairs(dbTable) do table.insert(kindKeys, kind) end
            if #kindKeys == 0 then continue end
            for _ = 1, math.random(2, 6) do
                writeItem(catInfo.category, kindKeys[math.random(1, #kindKeys)])
            end
        end

        -- ── Summary label: "42 pets • 3x Shadow Dragon, 2x Frost Dragon…" ────
        pcall(function() UIManager.apps.BackpackApp:refresh_rendered_items() end)
        -- Build short "NxName" list for the top duplicates
        local dupeList = {}
        for kindId, cnt in pairs(kindCounts) do
            if cnt >= 2 then
                table.insert(dupeList, { cnt=cnt, name=kindNames[kindId] })
            end
        end
        table.sort(dupeList, function(a,b) return a.cnt > b.cnt end)
        local summaryParts = {}
        for i = 1, math.min(4, #dupeList) do
            table.insert(summaryParts, dupeList[i].cnt .. "x " .. (dupeList[i].name or "?"))
        end
        local summaryStr = #summaryParts > 0 and (" • " .. table.concat(summaryParts, ", ")) or ""
        fakeInvBtn.Text = totalSpawned .. " pets!" .. summaryStr
        fakeInvStroke.Color = Color3.fromRGB(0, 255, 120)
        task.delay(3, function()
            fakeInvBtn.Text = "Spawn Fake Inventory"
            fakeInvStroke.Color = Color3.fromRGB(190, 100, 255)
        end)
    end)
end
fakeInvBtn.MouseButton1Click:Connect(_runFakeInv)
_G._setupLiveRunFakeInv = _runFakeInv

do
local fakeHistoryStatusLbl = mk("TextLabel", {Size=UDim2.new(1, 0, 0, 9), BackgroundTransparency=1, Text="", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(100, 230, 150), TextXAlignment=Enum.TextXAlignment.Center, Parent=spawnFrame})
Instance.new("UICorner", fakeHistoryStatusLbl).CornerRadius = UDim.new(0, 3)

local fakeHistoryBtn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 13), BackgroundColor3=Color3.fromRGB(180, 100, 20), BackgroundTransparency=0.1, Text="Spawn Fake Trade History", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255, 220, 140), Parent=spawnFrame})
Instance.new("UICorner", fakeHistoryBtn).CornerRadius = UDim.new(0, 3)
local fakeHistoryStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255, 180, 60), Thickness=0.7, Transparency=0.3, Parent=fakeHistoryBtn})

local _fhAmvggCache = nil
local function _fhHttpGet(url)
    local ok, res = pcall(function()
        return request({ Url = url, Method = "GET", Headers = { ["RSC"] = "1" } })
    end)
    if ok and res and res.Body then return res.Body end
    local ok2, body = pcall(function() return HttpGet(url) end)
    if ok2 and body then return body end
    local ok3, body3 = pcall(function()
        return game:GetService("HttpService"):GetAsync(url, true)
    end)
    if ok3 and body3 then return body3 end
    return nil
end

local function _fhFetchAmvgg(cb)
    if _fhAmvggCache then cb(_fhAmvggCache) return end
    task.spawn(function()
        local ok, text = pcall(_fhHttpGet, "https://amvgg.com/values/pets?_rsc=19zvn")
        if not ok or type(text) ~= "string" then cb(nil) return end
        local ps = text:find('"pets":%[{')
        if not ps then cb(nil) return end
        local raw = _G._decodeJsonArrayAt(text, ps)
        if not raw then cb(nil) return end
        local cache = {}
        for _, p in ipairs(raw) do
            if p.name then
                local function n(v) return tonumber(v) or 0 end
                cache[p.name:lower()] = n(p.megaValue)
            end
        end
        _fhAmvggCache = cache
        cb(cache)
    end)
end

local function _fhGetMfrValue(cache, petName)
    if not cache then return 0 end
    local v = cache[petName:lower()] or 0
    if v == 0 then
        for k, val in pairs(cache) do
            if k:find(petName:lower(), 1, true) then v = val break end
        end
    end
    return v
end

local function _fhMakeItem(petName, props)
    local kind = nil
    pcall(function()
        for id, data in pairs(InventoryDB.pets or {}) do
            if data.name and data.name:lower() == petName:lower() then kind = id break end
        end
    end)
    if not kind then return nil end
    return {
        category   = "pets",
        kind       = kind,
        id         = kind,
        unique     = HttpService:GenerateGUID(false),
        properties = props or { neon=false, mega_neon=false, flyable=false, rideable=false, age=1 },
    }
end

local function _fhMakeMFRItem(petName)
    return _fhMakeItem(petName, { neon=false, mega_neon=true, flyable=true, rideable=true, age=1 })
end

local function _fhInjectRecord(senderUserId, senderName, senderItems, recipientUserId, recipientName, recipientItems, timestamp)
    local record = {
        trade_id          = "MOCK_FH_" .. HttpService:GenerateGUID(false),
        timestamp         = timestamp or os.time(),
        sender_user_id    = senderUserId,
        sender_name       = senderName,
        recipient_user_id = recipientUserId,
        recipient_name    = recipientName,
        sender_items      = senderItems   or {},
        recipient_items   = recipientItems or {},
        reported          = false,
        reverted          = nil,
    }
    table.insert(_mockTradeHistory, 1, record)
    if TradeHistoryApp then
        TradeHistoryApp.cached_trade_history = nil
    end
    return record
end

local _fhPartnerNames = {
    "CammyxBoba", "RoplexYoutube", "NotLeah", "TheMeganPlays", "Kellyvault",
    "Rainbowriley321", "hweartsouls", "h3llsang3lx", "Hugso09", "ruthjavxn",
    "bubblesxwrldd", "Barborich2", "Bunzvii", "Sparklingorangelol", "Tr3ndzyy",
    "Cqvrleo", "Themeganplays", "Pradasvogue", "Lionheart_xo", "dwsiredsouls",
    "Xcallmeholly", "Agusmareborn", "Hugeinvestor", "Underthechemtrailss",
}
local _fhUsedNames = {}
local function _fhPickName()
    if #_fhUsedNames >= #_fhPartnerNames then _fhUsedNames = {} end
    local available = {}
    for _, n in ipairs(_fhPartnerNames) do
        local used = false
        for _, u in ipairs(_fhUsedNames) do if u == n then used = true break end end
        if not used then table.insert(available, n) end
    end
    local pick = available[math.random(1, #available)]
    table.insert(_fhUsedNames, pick)
    return pick
end

local _fhRunning = false

_G._setupLiveFakeHistoryBtn = fakeHistoryBtn
local function _runFakeHistory()
    if _fhRunning then return end
    _fhRunning = true
    fakeHistoryBtn.Text             = "Fetching amvgg..."
    fakeHistoryBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
    fakeHistoryStatusLbl.Text       = "⏳ Loading amvgg values..."

    _fhFetchAmvgg(function(cache)
        if not cache then
            fakeHistoryStatusLbl.Text       = "❌ amvgg fetch failed"
            fakeHistoryBtn.Text             = "Spawn Fake Trade History"
            fakeHistoryBtn.BackgroundColor3 = Color3.fromRGB(180, 100, 20)
            _fhRunning = false
            return
        end

        local validPets = {}
        for _, petName in ipairs(HIGH_TIER_PETS) do
            if _fhGetMfrValue(cache, petName) >= 0.1 then
                table.insert(validPets, petName)
            end
        end

        if #validPets == 0 then
            fakeHistoryStatusLbl.Text       = "❌ No pets passed 0.1gg threshold"
            fakeHistoryBtn.Text             = "Spawn Fake Trade History"
            fakeHistoryBtn.BackgroundColor3 = Color3.fromRGB(180, 100, 20)
            _fhRunning = false
            return
        end

        local myUserId   = Players.LocalPlayer.UserId
        local myName     = Players.LocalPlayer.Name
        local tradeCount = math.random(8, 14)

        fakeHistoryBtn.Text       = "Generating " .. tradeCount .. " trades..."
        fakeHistoryStatusLbl.Text = "✅ " .. #validPets .. " valid pets | building " .. tradeCount .. " trades"

        task.spawn(function()
            local now     = os.time()
            local gapSecs = math.random(300, 600)

            for i = 1, tradeCount do
                local partnerName = _fhPickName()
                local partnerId   = math.random(100000000, 999999999)
                local pet1Name    = validPets[math.random(1, #validPets)]
                local pet1Props   = { neon=false, mega_neon=false, flyable=true, rideable=true, age=1 }
                local pet1Item    = _fhMakeItem(pet1Name, pet1Props)
                if not pet1Item then task.wait(0.05) continue end

                -- History displays oldest at bottom, newest at top
                -- So: top = you giving back, below = them giving to you
                local tsB = now - (i - 1) * gapSecs - math.random(0, 60)
                local tsA = tsB + math.random(30, 180)

                -- TRADE B (older): partner gives 1 high-tier to me first
                _fhInjectRecord(
                    partnerId, partnerName,
                    { pet1Item },
                    myUserId, myName,
                    {},
                    tsB
                )

                task.wait(0.04)

                -- TRADE A (newer): I give back same pet + MFR extras
                local myGiveItems = {}
                local returnItem = _fhMakeItem(pet1Name, pet1Props)
                if returnItem then table.insert(myGiveItems, returnItem) end
                for _ = 1, math.random(3, 6) do
                    local mfrItem = _fhMakeMFRItem(validPets[math.random(1, #validPets)])
                    if mfrItem then table.insert(myGiveItems, mfrItem) end
                end

                _fhInjectRecord(
                    myUserId, myName,
                    myGiveItems,
                    partnerId, partnerName,
                    {},
                    tsA
                )

                task.wait(0.04)
            end

            if TradeHistoryApp and UIManager.is_visible("TradeHistoryApp") then
                pcall(function() TradeHistoryApp:_refresh() end)
            end

            fakeHistoryStatusLbl.Text       = "✅ Injected " .. (tradeCount * 2) .. " trade records!"
            fakeHistoryBtn.Text             = "Spawn Fake Trade History"
            fakeHistoryBtn.BackgroundColor3 = Color3.fromRGB(180, 100, 20)
            _fhRunning = false
        end)
    end)
end
fakeHistoryBtn.MouseButton1Click:Connect(_runFakeHistory)
_G._setupLiveRunFakeHistory = _runFakeHistory

end -- fake trade history do

do

-- Get profile constants via CloudValues (PlayerProfileHelper.get_cloud_value reads from "player_profiles" namespace)
local _WIDGETS_PER_PAGE     = 8
local _MAX_PAGES            = 10
local _MAX_COLLECTION_ITEMS = 80
pcall(function()
    local cv = require(game.ReplicatedStorage.ClientModules.CloudValues)
    _WIDGETS_PER_PAGE     = cv:getValue("player_profiles", "widgets_per_page")     or _WIDGETS_PER_PAGE
    _MAX_PAGES            = cv:getValue("player_profiles", "max_pages")            or _MAX_PAGES
    _MAX_COLLECTION_ITEMS = cv:getValue("player_profiles", "max_collection_items") or _MAX_COLLECTION_ITEMS
end)

local _fpRC = Fsys.load("RouterClient")

local _fpIsEnabled  = true
local _fpHookedApps = {}

local _fpUniqueCounter = 0
local function _fpGenerateId()
    _fpUniqueCounter = _fpUniqueCounter + 1
    return string.format("fp_col_%d_%d", tick() * 1000, _fpUniqueCounter)
end

-- selectedFlags (defaults match uploaded script)
local _fpSelectedFlags = {
    mega_neon = true,
    neon      = false,
    flyable   = true,
    rideable  = true,
}

local _fpActivePetKind = "bat_dragon"  -- default

local function _fpGetRealUniques()
    local uniques = {}
    pcall(function()
        local inv = ClientData.get("inventory") or {}
        for uid, item in pairs(inv.pets or {}) do
            if item.kind == _fpActivePetKind then
                table.insert(uniques, { unique = uid, properties = item.properties or {} })
            end
        end
    end)
    return uniques
end

local function _fpBuildProperties()
    local props = {}
    if _fpSelectedFlags.mega_neon then props.mega_neon = true end
    if _fpSelectedFlags.neon and not _fpSelectedFlags.mega_neon then props.neon = true end
    if _fpSelectedFlags.flyable  then props.flyable  = true end
    if _fpSelectedFlags.rideable then props.rideable = true end
    return props
end

-- Exact same as uploaded script: widget_kind = "collection", uses real uniques where available
local function _fpBuildSlotData()
    local realPets = _fpGetRealUniques()
    local props    = _fpBuildProperties()
    local items    = {}
    for i = 1, _MAX_COLLECTION_ITEMS do
        if i <= #realPets then
            items[i] = { kind       = _fpActivePetKind, category   = "pets", unique     = realPets[i].unique, properties = props, }
        else
            items[i] = { kind       = _fpActivePetKind, category   = "pets", unique     = _fpGenerateId(), properties = props, }
        end
    end
    return {
        widget_kind = "collection",
        expanded    = true,
        widget_data = { title = "", items = items },
    }
end

-- hookClientData: exact copy from uploaded script
local function _fpHookClientData()
    if ClientData._fp_cd_hooked then return end
    ClientData._fp_cd_hooked = true
    local originalGet = ClientData.get_server
    ClientData.get_server = function(player, key, ...)
        local result = originalGet(player, key, ...)
        if key == "player_profile" and result then
            if player == Players.LocalPlayer and _fpIsEnabled then
                result.pages = result.pages or {}
                for page = 1, _MAX_PAGES do
                    local pageEntry = nil
                    for _, entry in ipairs(result.pages) do
                        if entry.page_index == page then pageEntry = entry; break end
                    end
                    if not pageEntry then
                        pageEntry = { page_index = page, widgets = {}, stickers = {} }
                        table.insert(result.pages, pageEntry)
                    end
                    pageEntry.widgets = {}
                    for slot = 1, _WIDGETS_PER_PAGE do
                        table.insert(pageEntry.widgets, { slot = slot, data = _fpBuildSlotData() })
                    end
                end
            else
                -- Other player: just ensure stickers field exists, never fake their profile
                if result.pages then
                    for _, page in ipairs(result.pages) do
                        if page.stickers == nil then page.stickers = {} end
                    end
                end
            end
        end
        return result
    end
end

-- hookFetchProfile: intercepts PlayerProfileAPI/FetchProfile to inject fake widgets
-- Response shape from PlayerProfile module: {pages=[{page_index, widgets=[{slot,data}], stickers={}}], properties={}}

-- Patch PlayerProfile methods lazily on first profile open so the module
-- is guaranteed to be fully loaded and cached before we touch it.
-- PlayerProfile patched at top of script (see patch block near TradeApp load)
-- _patchPlayerProfile kept as no-op for compatibility
local _ppPatched = true
local function _patchPlayerProfile() end


-- =====================================================================
-- RANDOM OFFLINE PROFILE GENERATOR
-- Generates a convincing fake profile for offline non-friend players
-- =====================================================================
local _randProfileCache = {}  -- userId -> generated profile, consistent per session

local RAND_ABOUT_TITLES = {
    -- real profiles scraped from server
    "ѕησωу ℓσνє ℓєттєя´💌",
    "—αвσυт мє🦩 §",
    "Abyss",
    "Chat💭",
    "Chat",
    "about me",
    "<— how many SNGF!",
    -- preppy / aesthetic
    "✧ about me ✧",
    "₊˚⊹ hi !!",
    "˖ ° . ✦ info",
    "⋆ ˚｡⋆ notes",
    "♡ read pls",
    "✩ my profile ✩",
    "˚ʚ♡ɞ˚ hi",
    "⊹ ˚. about",
    "✧˖° welcome",
    "₊˚ trading info",
    "♡ ily all ♡",
    "☆ dreamer",
    "✦ collector ✦",
    "꩜ my world",
    "✿ notes !",
    -- neutral / trader
    "about me!!",
    "read b4 trading",
    "hi!!",
    "living doll . . .",
    "my dollhouse",
    "house trader",
    "fair trades only",
    "collector",
    "trader info",
    "pls read!",
    "info!!",
    "trading rules",
    "hi there !!",
    ":", "::", ":::", "",
    "", "", "",
}
local RAND_ABOUT_BODIES = {
    -- ── real scraped from server ──────────────────────────────────────────
    [[ 14.9+ৎ❄️-´                                        💋..αмνgg                                                  🦢ωιηтєя ѕzη ৎ ]],
    [[~єℓνє σηℓу!!! 🍉                 ~ι'м ∂σιηg яαη∂σмѕ ƒσя мєgαѕ! 🍜]],
    [[Minion lover ♡]],
    [[Doing 1 trade of randoms  per .1]],
    [[I DONT WANT HIGHS I SAID DOWNGRADESSSS]],
    [[Sand 2-3 trades flower and leopard 1.5 trades ! PROOF LAST PAGE SNGF]],
    -- ── preppy / aesthetic ────────────────────────────────────────────────
    [[˚ʚ♡ɞ˚ hii !!
everything here is nft ♡
check my wishlist below]],
    [[✧ collector at heart
not lf atm !!
ily all xoxo]],
    [[♡ preppy trader
amvgg vals only pls
no lowballs bestie]],
    [[₊˚⊹ hi gorgeous !!
nft means nft !!
dont ask lol]],
    [[✦ my pets are my babies
not trading them for anything bad
fair only !!]],
    [[˖ ° . ✦ hello !!
house + pet trader
check my wishlist ♡]],
    [[✩ fairy lights & shadow dragons ✩
nft = nft !!
offers below only]],
    [[♡ if ur reading this ur cute
nft unless i say ft
ily bestie]],
    [[⊹ ˚. hi there !!
dreamy pets only ♡
amvgg is life]],
    [[˚ʚ♡ɞ˚ aesthetic trader
pets pw ♡
dm me ur offer]],
    [[✧˖° bakery collector ✧
everything homemade
nft ♡ ily]],
    [[₊˚ cottagecore vibes ₊˚
not in a rush to trade
offers welcome ♡]],
    [[⋆ ˚｡⋆ jellycat lover !!
not lf rn
check back later ♡]],
    [[✦ dollcore aesthetic ✦
my pets are not fs!!
lf below only]],
    [[♡ hi cuties !!
mega collector
amvgg vals plss]],
    -- ── normal trader ─────────────────────────────────────────────────────
    [[i dont offer unless lf
fair trades > ovps
-> elve
-> amvgg]],
    [[:: not for trade
:: dreamy pets
:: looking for]],
    [[everything here is nft
pets pw . .
:: locket
:: looking for]],
    [[reminder: everything here is nft
fair trades only
pets pw . .]],
    [[i dont offer!!
nft means nft
amvgg vals only]],
    [[welcome to my profile
pw :: nft
i dont offer!!]],
    [[looking for:
shadow dragon
bat dragon
giraffe]],
    [[the only vals i follow: amvgg
nft
ft]],
    [[my bakery!
:: best pets
:: toppings
:: in the oven]],
    [[selling fits!
jellycats
m/n glowsticks!]],
    [[i dont offer unless lf
house trader
check wishlist!]],
    [[my dollhouse
pets pw . .
:: locket]],
    [[living doll . . .
my dollhouse
pets pw]],
    [[huge collector
trading daily
check my inv!!]],
    [[shadow + bat = dream combo
all legit no dupes]],
    [[mostly online evenings
hit me with offers!]],
    [[no lowballs pls
amvgg is my bible
dont waste my time lol]],
    [[megas & neons only
no normals pls
dont bother offering]],
    [[all nft unless i say ft
dm before offering]],
    [[nft MEANS nft
vals only: amvgg]],
    [[trading my bat for the right offer
must be fair !!]],
    [[mega collector here
if its mega i probably want it]],
    [[been playing since 2020 !!
never duped never will
all legit]],
    [[active trader
online most days
make me an offer!]],
    [[val list: amvgg only
no elve no overpay
just fair]],
    [[back from break!
lots of stuff to trade
come offer me]],
    [[pls dont offer potions or strollers
pets only ty]],
    [[i follow amvgg values
dont come to me with discord vals lol]],
    [[ft = for trade  nft = not for trade
lf = looking for]],
    [[do NOT offer me neon cows
i have 12 lol]],
    "", "", "", "",
}
local RAND_WISHLIST_TITLES = {
    -- real from server
    "Lf try to pick",
    "ℓσσкιηg ƒσя",
    "goal",
    "lf",
    "::giving eggs ",
    "ℓf☆ﾐ",
    "Retired eggs for",
    -- preppy
    "✧ lf:",
    "♡ dream pets",
    "⊹ wishing for",
    "˚ dream list ˚",
    "✦ want so bad",
    "₊˚ goals !!",
    "♡ obsessed with",
    -- normal
    ":: looking for",
    ":: dreamy pets",
    ":: lf:",
    "looking for:",
    ":: wishlist!!",
    "dream pets",
    "lf:",
    ":: need these!!",
    "want list",
    "goals!!",
    ":: want:",
    "trading for:",
    "", "",
}
local RAND_COLLECTION_TITLES = {
    -- real scraped from server
    "๑ ⸝⸝ νєιℓ ᵎᵎ 🍋 ও 〟",
    "๑ ⸝⸝ νєℓνєт ᵎᵎ 🌈 ও 〟",
    "๑ ⸝⸝ мυѕє ᵎᵎ 🍿 ও 〟",
    "  ๑ ⸝⸝ναυℓт ᵎᵎ 🔒 ও ",
    "festives 🎄",
    "christmas",
    "more xmas yay",
    "incomming",
    "need 1 more trade me",
    "ƒσя тяα∂є!",
    ". . .   ",
    "тєα fσя тєα",
    "FOR RANDOMS >>",
    "FOR LF ONLYYY",
    "H",
    "мιиισиѕ♡o。",
    "🍌☆o。.",
    "вαиαиαѕ",
    "MINIONSS",
    "ѕтαяѕ☆ﾐNFT",
    "۶ 🦄 ৎ",
    "мєgαѕ   ",
    "ƒσя яαη∂σмѕ",
    "1 trade ",
    "۶ 4 αη∂ α∂∂ѕ ৎ",
    "яαη∂σмѕ ƒσя .1+ мєgαѕ   ",
    "2 ultras for 1",
    "pick for shiver ",
    "🌷~ƒανσυяιтєѕ",
    "🌾~ηєσηѕ",
    "ѕησω кιѕѕє∂🧣ৎ",
    -- preppy
    "✧ my babies ✧",
    "♡ fav pets",
    "⊹ ft maybe ♡",
    "˚ best of best ˚",
    "✦ nft forever",
    "₊˚ recents !!",
    "♡ show offs",
    "✩ vault ✩",
    "˖ ° . highlights",
    "♡ my loves (nft)",
    -- normal
    ":: baked",
    ":: recents!!",
    ":: for trade!",
    ":: best pets!!",
    "pets pw . .",
    ":: spookies",
    ":: glowsticks",
    ":: candies",
    ":: megas (more)",
    ":: neons (more)",
    "vanity (nft)",
    ":: profile key!!",
    "my collection",
    ":: show offs",
    ":: stash",
    ":: vault",
    ":: tradeable",
    "ft pets",
    "nft forever",
    "", "",
}

local RAND_COLLECTION_POOL = {}
local RAND_WISHLIST_POOL   = {}
-- Real InventoryDB kind keys (from check_pet_kinds.lua scan)
local _KIND_REAL = {
    ["bat_dragon"]                      = "bat_dragon",
    ["shadow_dragon"]                   = "shadow_dragon",
    ["giraffe"]                         = "giraffe",
    ["frost_dragon"]                    = "frost_dragon",
    ["owl"]                             = "owl",
    ["parrot"]                          = "parrot",
    ["crow"]                            = "crow",
    ["balloon_unicorn"]                 = "summerfest_2024_balloon_unicorn",
    ["african_wild_dog"]                = "ugc_refresh_2023_african_wild_dog",
    ["giant_panda"]                     = "pet_recycler_2025_giant_panda",
    ["haetae"]                          = "lunar_2025_haetae",
    ["cryptid"]                         = "halloween_2025_cryptid",
    ["evil_unicorn"]                    = "evil_unicorn",
    ["blazing_lion"]                    = "lures_2023_blazing_lion",
    ["hedgehog"]                        = "elf_hedgehog",
    ["orchid_butterfly"]                = "butterfly_2025_orchid_butterfly",
    ["diamond_butterfly"]               = "sanctuary_2022_diamond_premium_butterfly",
    ["dalmatian"]                       = "santa_dog",
    ["arctic_reindeer"]                 = "arctic_reindeer",
    ["jekyll_hydra"]                    = "halloween_2024_jekyll_hydra",
    ["mini_pig"]                        = "summerfest_2024_minipig",
    ["hot_doggo"]                       = "summerfest_2023_hotdog_dog",
    ["pelican"]                         = "random_pets_sept_2023_pelican",
    ["cow"]                             = "cow",
    ["mermicorn"]                       = "summerfest_2025_mermicorn",
    ["strawberry_shortcake_bat_dragon"] = "winter_2022_strawberry_shortcake_bat_dragon",
    ["cabbit"]                          = "spring_2025_cabbit",
    ["chocolate_chip_bat_dragon"]       = "winter_2023_chocolate_chip_bat_dragon",
    ["turtle"]                          = "turtle",
    ["peppermint_penguin"]              = "winter_2023_peppermint_penguin",
    ["goose"]                           = "springfest_2023_goose",
    ["monkey_king"]                     = "monkey_king",
    ["undead_jousting_horse"]           = "halloween_2022_undead_jousting_horse",
    ["flamingo"]                        = "flamingo",
    ["kangaroo"]                        = "kangaroo",
}

for _, entry in ipairs(HIGH_TIER_PETS_TIERED) do
    local simpleKind = entry.name:lower():gsub(" ", "_"):gsub("[^%w_]", "")
    local realKind   = _KIND_REAL[simpleKind] or simpleKind
    local maxLevel   = entry.max
    local flags
    if maxLevel == "default" then
        flags = { {F=true,R=true}, {F=true,R=false}, {F=false,R=true}, {F=false,R=false} }
    elseif maxLevel == "neon" then
        flags = {
            {N=true,F=true,R=true}, {N=true,F=true,R=true},
            {N=true,F=false,R=false},
            {F=true,R=true}, {F=false,R=false},
        }
    else -- "any"
        flags = {
            {M=true,F=true,R=true}, {M=true,F=true,R=true},
            {N=true,F=true,R=true}, {N=true,F=true,R=true},
            {N=true,F=false,R=false},
            {F=true,R=true}, {F=false,R=false},
        }
    end
    table.insert(RAND_COLLECTION_POOL, { kind = realKind, flags = flags })
    table.insert(RAND_WISHLIST_POOL,   { kind = realKind, flags = flags })
end

-- ── Real pet kinds scraped from server profiles ───────────────────────────
-- These are verified kind IDs seen in actual player collections
do
    local function addReal(kind, flagPresets)
        -- flagPresets: list of {N,M,F,R} tables representing what real players actually have
        table.insert(RAND_COLLECTION_POOL, { kind=kind, flags=flagPresets })
        table.insert(RAND_WISHLIST_POOL,   { kind=kind, flags=flagPresets })
    end
    local FR   = {{F=true,R=true}}
    local MFR  = {{M=true,F=true,R=true},{F=true,R=true}}
    local NFR  = {{N=true,F=true,R=true},{F=true,R=true},{F=false,R=false}}
    local NP   = {{F=false,R=false},{F=true,R=false}}
    local ANY  = {{M=true,F=true,R=true},{N=true,F=true,R=true},{F=true,R=true},{F=false,R=false}}
    -- from whimses
    addReal("easter_2024_candyfloss_chick",       MFR)
    addReal("salon_revamp_2026_moonbeam_peacock",  MFR)
    addReal("summerfest_2023_hotdog_dog",          MFR)
    addReal("halloween_2024_grim_dragon",          MFR)
    addReal("lny_2023_qiongchi",                   MFR)
    addReal("farm_2023_caterpillar",               MFR)
    addReal("halloween_2023_werewolf",             MFR)
    addReal("flamingo",                            MFR)
    addReal("summerfest_2024_minipig",             MFR)
    addReal("springfest_2023_goose",               MFR)
    addReal("zombie_buffalo",                      MFR)
    addReal("house_pets_2025_siamese_cat",         NFR)
    addReal("easter_2022_sugar_glider",            MFR)
    addReal("space_house_2022_capricorn",          MFR)
    addReal("desert_2024_criosphinx",              MFR)
    addReal("rain_2023_diamond_amazon",            MFR)
    addReal("woodland_2022_fallow_deer",           ANY)
    addReal("sugarfest_2026_latte_kitsune",        MFR)
    addReal("camping_2025_papa_moose",             MFR)
    addReal("summerfest_2023_shark_doggo",         MFR)
    addReal("penguins_2025_vanilla_penguin",       MFR)
    addReal("easter_2022_springer_spaniel_brown",  MFR)
    addReal("subscription_2026_chocolate_dutch_guinea_pig", MFR)
    addReal("winter_2023_harp_seal",               MFR)
    addReal("meerkat",                             MFR)
    addReal("meme_2023_sheeeeep",                  MFR)
    addReal("royal_palace_2022_corgi",             MFR)
    addReal("sofahog_2024_groundhog",              MFR)
    addReal("pride_2022_goat",                     MFR)
    addReal("lunar_2025_haetae",                   NFR)
    -- from Leoegern3
    addReal("elf_hedgehog",                        MFR)
    addReal("winter_2024_royal_mistletroll",       MFR)
    addReal("arctic_reindeer",                     MFR)
    addReal("april_fools_2023_tio_de_nadal",       MFR)
    addReal("fall_2022_pheasant_black",            MFR)
    addReal("snow_2022_diamond_albatross",         MFR)
    addReal("desert_2022_gold_scarab",             MFR)
    addReal("summerfest_2025_sea_slug",            MFR)
    addReal("food_pets_2026_pineapple_owl",        MFR)
    addReal("snow_owl",                            MFR)
    addReal("winter_2022_ram",                     MFR)
    addReal("winter_2022_wooly_rhino",             MFR)
    addReal("winter_2025_frost_phoenix",           MFR)
    addReal("lynx",                                MFR)
    addReal("winter_2024_naughty_mistletroll",     MFR)
    addReal("polar_bear",                          MFR)
    addReal("winter_2022_snowball_pet",            MFR)
    addReal("arctic_fox",                          NFR)
    addReal("reindeer",                            MFR)
    addReal("admin_abuse_2025_sushi_penguin",      NFR)
    addReal("inspector_shepherd_2026_german_shepherd", NFR)
    addReal("elf_shrew",                           MFR)
    -- from schlaud1
    addReal("valentines_2025_cupid_dragon",        MFR)
    addReal("winter_2023_candy_hare",              MFR)
    addReal("valentines_2025_sweetheart_rat",      MFR)
    addReal("panda",                               MFR)
    addReal("musk_ox",                             MFR)
    addReal("ugc_rewards_2023_glacier_moth",       NFR)
    -- from Marln200034
    addReal("frost_dragon",                        FR)
    addReal("winter_2022_strawberry_shortcake_bat_dragon", NFR)
    addReal("yeti",                                MFR)
    addReal("cow",                                 FR)
    addReal("evil_unicorn",                        FR)
    addReal("turtle",                              NFR)
    addReal("llama",                               MFR)
    addReal("parrot",                              FR)
    addReal("sugarfest_2026_candicorn",            MFR)
    addReal("sugarfest_2026_pupcake",              MFR)
    addReal("summer_2026_burger_bear",             MFR)
    -- from Hangyadon7
    addReal("halloween_2022_undead_jousting_horse",MFR)
    addReal("admin_abuse_egg_2026_robot_chicken",  MFR)
    addReal("pride_2023_caelum_cervi",             MFR)
    addReal("house_pets_2025_munchkin_cat",        MFR)
    addReal("aussie_2024_kookaburra",              MFR)
    addReal("penguins_2025_dango_penguins",        MFR)
    addReal("winter_2021_husky",                   MFR)
    addReal("winter_2021_puffin",                  MFR)
    -- from V4LlDCUPlD
    addReal("elephant",                            MFR)
    addReal("winter_2023_christmas_pudding_pup",   MFR)
    addReal("pool_2023_red_sand_dollar",           MFR)
    addReal("japan_2022_leopard_cat",              MFR)
    addReal("dolphin",                             MFR)
    addReal("lny_2023_water_moon_bear",            MFR)
    addReal("danger_2023_blue_ringed_octopus",     MFR)
    addReal("springfest_2023_flower_power_duckling",MFR)
    addReal("winter_2024_frostbite_cub",           MFR)
    addReal("seasia_2023_tarsier",                 MFR)
    addReal("gorilla_fair_2023_gorilla",           MFR)
    addReal("halloween_2023_nightmare_owl",        MFR)
    addReal("lny_2023_water_rabbit",               NFR)
    addReal("halloween_2024_indian_flying_fox",    NFR)
    addReal("halloween_2026_skelicorn",            NFR)
    addReal("sanctuary_2022_red_bucks_butterfly",  NFR)
    addReal("ddlm_2024_grave_owl",                 NFR)
    addReal("sugarfest_2026_white_choccybunny",    NFR)
    addReal("cat_cafe_2026_cattuccino",            NFR)
    addReal("winter_2025_angus_cow",               NFR)
    addReal("butterfly_2025_amber_butterfly",      NFR)
    addReal("sugarfest_2026_gummy_guana",          NFR)
    addReal("sugarfest_2026_milk_choccybunny",     NFR)
    addReal("sugarfest_2026_cocoadile",            NFR)
    addReal("urban_2023_toy_poodle",               NFR)
    -- from Maddiomg20114
    addReal("winter_2025_bunny_swirl",             MFR)
    addReal("basic_egg_2022_alicorn",              MFR)
    addReal("fairytale_egg_2026_blind_mice",       MFR)
    addReal("endangered_2026_sea_turtle",          MFR)
    addReal("summerfest_2024_cow_calf",            MFR)
    addReal("halloween_2026_bolt",                 ANY)
    addReal("sugarfest_2026_gumball_caterpillar",  ANY)
    addReal("valentines_2026_cherub_chipmunk",     ANY)
    addReal("fairytale_egg_2026_little_lamb",      ANY)
    addReal("fairytale_egg_2026_clumpty",          MFR)
    addReal("bees_wagon_2026_violet_friend",       ANY)
    addReal("bees_wagon_2026_sunflower_friend",    ANY)
    addReal("birthday_2026_birthday_butterfly",    ANY)
    addReal("summer_2026_acorn_friend",            ANY)
    addReal("soggy_spring_2026_rubber_ducky",      ANY)
    addReal("ugc_refresh_2023_african_wild_dog",   NFR)
    addReal("winter_2024_fairy_bat_dragon",        MFR)
    addReal("winter_2024_berry_cool_cube",         NFR)
    addReal("toy_monkey",                          NFR)
    -- misc from wishlists
    addReal("ugc_rewards_2023_glacier_moth",       MFR)
    addReal("modular_castles_2023_frost_unicorn",  MFR)
    addReal("winter_2023_peppermint_penguin",      MFR)
    addReal("ugc_refresh_2024_jellyfish",          MFR)
    addReal("summerfest_2023_mackerel_shoal",      MFR)
    addReal("winter_2024_fairy_bat_dragon",        MFR)
    addReal("winter_2023_chocolate_chip_bat_dragon",MFR)
    addReal("sunshine_2024_bush_elephant",         MFR)
    addReal("ugc_refresh_2023_african_wild_dog",   NFR)
    addReal("winter_2023_snow_monkey",             MFR)
    addReal("april_fools_2023_yule_log_dog",       MFR)
    addReal("winter_2022_ice_wolf",                MFR)
    addReal("frost_fury",                          MFR)
    addReal("winter_2021_ice_golem",               MFR)
    addReal("swan",                                MFR)
    addReal("turkey",                              MFR)
    addReal("gibbon_2025_ringmaster_gibbon",       NP)
    addReal("celestial_2024_moonlight_moth",       NP)
    addReal("scottish_2023_highland_cow",          NP)
    addReal("ice_dimension_2025_shiver_wolf",      NP)
    addReal("pool_2023_goldfish",                  NP)
    addReal("frog",                                NP)
    addReal("clownfish",                           NP)
    addReal("springfest_2023_happy_duckling",      MFR)
    addReal("springfest_2023_sunrise_duckling",    NP)
    addReal("seasia_2023_gecko",                   NP)
    addReal("hamstertime_2024_hamster",            NP)
    addReal("summerfest_2024_pink_betta_fish",     NP)
    addReal("winter_2024_great_pyrenees",          NP)
    addReal("winter_2025_maine_coon",              NP)
    addReal("winter_2025_snowball_pug",            NP)
    addReal("danger_2023_puffer_fish",             NP)
    addReal("seasia_2023_binturong",               NP)
    addReal("ice_cream_refresh_2022_king_penguin", NP)
    addReal("japan_2022_koi_carp",                 NP)
    addReal("narwhal",                             NP)
    addReal("sloth",                               NP)
    addReal("penguin",                             NP)
end

local function _randPick(t) return t[math.random(1, #t)] end
local function _randBool(chance) return math.random() < (chance or 0.5) end

local function _randPetItem(pool)
    pool = pool or RAND_COLLECTION_POOL
    local entry = pool[math.random(1, #pool)]
    local flags = _randPick(entry.flags)
    local props = {}
    if flags.M then props.mega_neon = true
    elseif flags.N then props.neon = true end
    if flags.F then props.flyable = true end
    if flags.R then props.rideable = true end
    props.age = math.random(1, 6)
    return { kind       = entry.kind, category   = "pets", unique     = string.format("rp_%d_%d", math.random(100000,999999), math.random(100,999)), properties = props, }
end

local function _buildRandAboutMe()
    -- 20% chance of no title, 30% chance of no body (realistic — lots of blank profiles)
    return {
        widget_kind = "about_me",
        expanded    = false,
        widget_data = { title = _randBool(0.8) and _randPick(RAND_ABOUT_TITLES) or "", body  = _randBool(0.7) and _randPick(RAND_ABOUT_BODIES) or "", },
    }
end

local function _buildRandWishlist()
    local items = {}
    -- Different users want different amounts — some very specific, some long lists
    local wRoll = math.random()
    local count = wRoll < 0.25 and math.random(3, 7)
               or wRoll < 0.65 and math.random(8, 16)
               or math.random(17, 28)
    local usedKinds = {}
    local attempts = 0
    while #items < count and attempts < 60 do
        attempts = attempts + 1
        local entry = RAND_WISHLIST_POOL[math.random(1, #RAND_WISHLIST_POOL)]
        -- 60% chance to deduplicate kind so wishlist feels realistic
        if not usedKinds[entry.kind] or _randBool(0.4) then
            usedKinds[entry.kind] = true
            local flags = _randPick(entry.flags)
            local props = {}
            if flags.M then props.mega_neon = true elseif flags.N then props.neon = true end
            if flags.F then props.flyable = true end
            if flags.R then props.rideable = true end
            table.insert(items, { kind = entry.kind, category = "pets", properties = props })
        end
    end
    return {
        widget_kind = "wishlist",
        expanded    = _randBool(0.65),
        widget_data = { title = _randPick(RAND_WISHLIST_TITLES), items = items },
    }
end

local function _buildRandCollection()
    local items = {}
    -- Vary the size: 15% small (6-12), 40% medium (13-30), 30% large (31-55), 15% huge (56-max)
    local roll = math.random()
    local count
    if roll < 0.15 then
        count = math.random(6, 12)
    elseif roll < 0.55 then
        count = math.random(13, 30)
    elseif roll < 0.85 then
        count = math.random(31, 55)
    else
        count = math.random(56, math.min(75, _MAX_COLLECTION_ITEMS))
    end

    -- 30% chance: mix in lower-tier pets from wishlist pool
    local useWishPool = _randBool(0.3)

    -- No anti-stack: same pet can appear many times (realistic for collectors/farmers)
    -- Some players have like 6x the same pet they're trading
    for _ = 1, count do
        local pool = (useWishPool and _randBool(0.25)) and RAND_WISHLIST_POOL or RAND_COLLECTION_POOL
        local entry = pool[math.random(1, #pool)]
        local flags = _randPick(entry.flags)
        local props = {}
        if flags.M then props.mega_neon = true
        elseif flags.N then props.neon = true end
        -- 25% chance: no-pot (no flyable/rideable regardless of flag pick)
        if _randBool(0.25) then
            props.flyable  = false
            props.rideable = false
        else
            if flags.F then props.flyable  = true end
            if flags.R then props.rideable = true end
        end
        props.age = math.random(1, 6)
        table.insert(items, {
            kind       = entry.kind,
            category   = "pets",
            unique     = string.format("rp_%d_%d", math.random(100000,999999), math.random(100,999)),
            properties = props,
        })
    end
    return {
        widget_kind = "collection",
        expanded    = _randBool(0.75),
        widget_data = { title = _randPick(RAND_COLLECTION_TITLES), items = items },
    }
end

-- Page layout templates — gives each user a distinct feel
local PAGE_LAYOUTS = {
    -- layout 1: about + collection + wishlist
    function() return { _buildRandAboutMe(), _buildRandCollection(), _buildRandWishlist() } end,
    -- layout 2: collection only (no-nonsense trader)
    function() return { _buildRandCollection() } end,
    -- layout 3: wishlist first then collection
    function() return { _buildRandWishlist(), _buildRandCollection() } end,
    -- layout 4: about + wishlist
    function() return { _buildRandAboutMe(), _buildRandWishlist() } end,
    -- layout 5: about only (minimal profile)
    function() return { _buildRandAboutMe() } end,
    -- layout 6: two collections (big collector)
    function() return { _buildRandCollection(), _buildRandCollection() } end,
    -- layout 7: full house (power user)
    function() return { _buildRandAboutMe(), _buildRandCollection(), _buildRandWishlist(), _buildRandCollection() } end,
    -- layout 8: wishlist heavy
    function() return { _buildRandAboutMe(), _buildRandWishlist(), _buildRandWishlist() } end,
    -- layout 9: collection + wishlist + collection
    function() return { _buildRandCollection(), _buildRandWishlist(), _buildRandCollection() } end,
    -- layout 10: three collections (mega trader)
    function() return { _buildRandCollection(), _buildRandCollection(), _buildRandCollection() } end,
    -- layout 11: about + two collections + two wishlists
    function() return { _buildRandAboutMe(), _buildRandCollection(), _buildRandWishlist(), _buildRandWishlist() } end,
    -- layout 12: collection + about + collection (sandwiched)
    function() return { _buildRandCollection(), _buildRandAboutMe(), _buildRandCollection() } end,
}

local function _buildRandPage(pageNum, widgetList)
    local widgets = {}
    for i, data in ipairs(widgetList) do
        if i > _WIDGETS_PER_PAGE then break end
        table.insert(widgets, { slot = i, data = data })
    end
    return { page_index = pageNum, widgets = widgets, stickers = {} }
end

local function _buildRandomOfflineProfile()
    -- Pick a random layout template
    local layout = _randPick(PAGE_LAYOUTS)()
    local pages = { _buildRandPage(1, layout) }
    -- 65% chance of a second page (active traders usually have 2+ pages)
    if _randBool(0.65) then
        local page2layout = _randPick(PAGE_LAYOUTS)()
        table.insert(pages, _buildRandPage(2, page2layout))
    end
    -- 25% chance of a third page (big collectors)
    if #pages >= 2 and _randBool(0.25) then
        local page3layout = _randPick(PAGE_LAYOUTS)()
        table.insert(pages, _buildRandPage(3, page3layout))
    end
    return { properties = {}, pages = pages }
end

local function _getOrGenRandomProfile(userId)
    if not _randProfileCache[userId] then
        -- Seed with userId XOR'd with a salt so different userIds
        -- get genuinely different sequences (not just offset versions)
        local salt = 0x5A3C1F7B
        local seed = bit32 and bit32.bxor(userId % 2^31, salt)
                     or ((userId % 100000) * 31337 + salt) % 2^31
        math.randomseed(seed)
        _randProfileCache[userId] = _buildRandomOfflineProfile()
        math.randomseed(tick() * 1000 + math.random())
    end
    return _randProfileCache[userId]
end
-- Expose so the Suggest backpack (defined earlier) can read a fake partner's GENERATED
-- profile directly, matching the collection shown on their profile page.
_G._genRandomProfile = _getOrGenRandomProfile

-- =====================================================================
-- FetchProfile hook via hookmetamethod
-- RemoteFunction instances are Roblox Instances — you cannot assign
-- properties or overwrite methods on them directly. The old approach
-- (`fetchRemote.InvokeServer = function...`) silently threw inside pcall
-- and never installed. This version uses hookmetamethod(__namecall).
-- =====================================================================
local _fpFetchRemote = nil
pcall(function() _fpFetchRemote = _fpRC.get("PlayerProfileAPI/FetchProfile") end)

local _fpNamecallInstalled = false
local function _fpInstallNamecallHook()
    if _fpNamecallInstalled then return end
    if type(hookmetamethod) ~= "function"
        or type(getnamecallmethod) ~= "function"
        or type(newcclosure) ~= "function" then
        warn("[FakeProfile] executor lacks hookmetamethod/getnamecallmethod/newcclosure — cannot hook FetchProfile")
        return
    end
    if not _fpFetchRemote then
        pcall(function() _fpFetchRemote = _fpRC.get("PlayerProfileAPI/FetchProfile") end)
    end
    if not _fpFetchRemote then
        warn("[FakeProfile] FetchProfile remote not found")
        return
    end
    _fpNamecallInstalled = true
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if self == _fpFetchRemote and getnamecallmethod() == "InvokeServer" then
            -- One-shot bypass: the Rich leaderboard sets this to read the REAL profile
            -- (no fake/random injection) so its AMVGG values are accurate.
            if _G._rlbRealFetch then _G._rlbRealFetch = false; return oldNamecall(self, ...) end
            local userId = (...)
            local lp = Players.LocalPlayer
            -- Own profile + fake mode on: inject full fake collection
            if userId == lp.UserId and _fpIsEnabled then
                local ok, real = pcall(oldNamecall, self, ...)
                local result = (ok and type(real) == "table") and real
                    or { properties = {}, pages = {} }
                result.pages = {}
                for page = 1, _MAX_PAGES do
                    local widgets = {}
                    for slot = 1, _WIDGETS_PER_PAGE do
                        widgets[slot] = { slot = slot, data = _fpBuildSlotData() }
                    end
                    result.pages[page] = {
                        page_index = page,
                        widgets    = widgets,
                        stickers   = {},
                    }
                end
                return result
            end
            -- Other player: try real fetch; on failure or empty content
            -- substitute a generated random profile
            if userId ~= lp.UserId then
                local ok, real = pcall(oldNamecall, self, ...)
                -- Never fabricate a profile for a REAL player who is actually in this server —
                -- show their genuine profile (even if empty). Only offline / not-present users
                -- get a generated random profile.
                local inServer = false
                pcall(function() inServer = Players:GetPlayerByUserId(userId) ~= nil end)
                local hasWidgets = false
                if ok and type(real) == "table" and real.pages then
                    for _, page in ipairs(real.pages) do
                        if page.widgets and #page.widgets > 0 then
                            hasWidgets = true
                            break
                        end
                    end
                end
                -- Only offline players (not in this server) get a generated random profile
                if not inServer and (not ok or type(real) ~= "table" or not hasWidgets) then
                    return _getOrGenRandomProfile(userId)
                end
                -- In-server players or players with real widgets — return as-is
                if ok and type(real) == "table" then
                    for _, page in ipairs(real.pages or {}) do
                        if page.stickers == nil then page.stickers = {} end
                    end
                    return real
                end
                return { properties = {}, pages = {} }
            end
        end
        return oldNamecall(self, ...)
    end))
end

-- Also keep _fpHookFetchProfile as a no-op for compatibility
local function _fpHookFetchProfile() end

-- Install at startup
task.defer(_fpInstallNamecallHook)


-- hookProfileApp: matches current PlayerProfile/PlayerProfileApp structure exactly
local function _fpHookProfileApp(app)
    if not app or _fpHookedApps[app] then return end
    _fpHookedApps[app] = true

    -- Hook on_load_complete — called by PlayerProfile._refresh_profile_data:finally()
    -- At this point profile_data is fully populated and app.player_profile is set
    local orig_on_load = app.on_load_complete
    app.on_load_complete = function(self, ...)
        local result = orig_on_load(self, ...)
        pcall(function()
            if not _fpIsEnabled then return end
            local pp = self.player_profile
            if not pp or not pp.is_my_profile then return end
            -- Inject fake slot data directly into profile_data.pages
            pp.profile_data = pp.profile_data or {}
            pp.profile_data.pages = pp.profile_data.pages or {}
            for page = 1, _MAX_PAGES do
                pp.profile_data.pages[page] = {}
                for slot = 1, _WIDGETS_PER_PAGE do
                    pp.profile_data.pages[page][slot] = _fpBuildSlotData()
                end
            end
            -- Re-render current page slots so changes show immediately
            local curPage = self:get_page()
            for slot = 1, _WIDGETS_PER_PAGE do
                pcall(function() pp:render_slot(curPage, slot) end)
            end
        end)
        return result
    end

    -- Hook open_page to re-inject fake data whenever page changes
    local orig_open_page = app.open_page
    app.open_page = function(self, pageNumber, ...)
        pcall(function()
            if not _fpIsEnabled then return end
            local pp = self.player_profile
            if not pp or not pp.is_my_profile then return end
            pp.profile_data = pp.profile_data or {}
            pp.profile_data.pages = pp.profile_data.pages or {}
            pp.profile_data.pages[pageNumber] = {}
            for slot = 1, _WIDGETS_PER_PAGE do
                pp.profile_data.pages[pageNumber][slot] = _fpBuildSlotData()
            end
        end)
        return orig_open_page(self, pageNumber, ...)
    end
end

-- startWatcher: exact copy from uploaded script
task.spawn(function()
    while task.wait(1) do
        pcall(function()
            if not _fpIsEnabled then return end
            local app = UIManager.apps.PlayerProfileApp
            if app then _fpHookProfileApp(app) end
        end)
    end
end)

-- fireAllSaves: exact copy from uploaded script using raw _fpRC
-- Spawner tab UI (unchanged — same buttons, same pet picker, same flags)
local fakeProfileStatusLbl = mk("TextLabel", {Size=UDim2.new(1,0,0,9), BackgroundTransparency=1, Text="", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(100, 230, 150), TextXAlignment=Enum.TextXAlignment.Center, Parent=spawnFrame})

local fakeProfileBtn = mk("TextButton", {Size=UDim2.new(1,0,0,13), BackgroundColor3=Color3.fromRGB(30,100,160), BackgroundTransparency=0.1, Text="Spawn Fake Profile", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(180,220,255), Parent=spawnFrame})
Instance.new("UICorner", fakeProfileBtn).CornerRadius = UDim.new(0,3)
local fakeProfileStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(80,160,255), Thickness=0.7, Transparency=0.3, Parent=fakeProfileBtn})

local _fpPetIndex = 1
local _fpPetName  = HIGH_TIER_PETS[1]
local fpPetRow = mk("Frame", {Size=UDim2.new(1,0,0,11), BackgroundTransparency=1, Parent=spawnFrame})
local fpPrevBtn = mk("TextButton", {Size=UDim2.new(0.12,0,1,0), BackgroundColor3=Color3.fromRGB(40,40,60), Text="◀", Font=Enum.Font.GothamBold, TextSize=6, TextColor3=Color3.fromRGB(180,180,220), BorderSizePixel=0, Parent=fpPetRow})
Instance.new("UICorner",fpPrevBtn).CornerRadius=UDim.new(0,3)
local fpPetLbl = mk("TextLabel", {Size=UDim2.new(0.76,0,1,0), Position=UDim2.new(0.12,0,0,0), BackgroundTransparency=1, Font=Enum.Font.FredokaOne, TextSize=6, TextColor3=Color3.fromRGB(200,220,255), TextXAlignment=Enum.TextXAlignment.Center, TextTruncate=Enum.TextTruncate.AtEnd, Text=_fpPetName, Parent=fpPetRow})
local fpNextBtn = mk("TextButton", {Size=UDim2.new(0.12,0,1,0), Position=UDim2.new(0.88,0,0,0), BackgroundColor3=Color3.fromRGB(40,40,60), Text="▶", Font=Enum.Font.GothamBold, TextSize=6, TextColor3=Color3.fromRGB(180,180,220), BorderSizePixel=0, Parent=fpPetRow})
Instance.new("UICorner",fpNextBtn).CornerRadius=UDim.new(0,3)
fpPrevBtn.MouseButton1Click:Connect(function()
    _fpPetIndex=(_fpPetIndex-2)%#HIGH_TIER_PETS+1; _fpPetName=HIGH_TIER_PETS[_fpPetIndex]; fpPetLbl.Text=_fpPetName
end)
fpNextBtn.MouseButton1Click:Connect(function()
    _fpPetIndex=_fpPetIndex%#HIGH_TIER_PETS+1; _fpPetName=HIGH_TIER_PETS[_fpPetIndex]; fpPetLbl.Text=_fpPetName
end)

local fpFlagsRow = mk("Frame", {Size=UDim2.new(1,0,0,11), BackgroundTransparency=1, Parent=spawnFrame})
for i,fd in ipairs({{key="mega_neon",label="M",col=Color3.fromRGB(160,80,255)},{key="neon",label="N",col=Color3.fromRGB(0,255,100)},{key="flyable",label="F",col=Color3.fromRGB(0,200,220)},{key="rideable",label="R",col=Color3.fromRGB(255,90,150)}}) do
    local fb = mk("TextButton", {Size=UDim2.new(0.23,0,1,0), Position=UDim2.new((i-1)*0.255,0,0,0), Text=fd.label, Font=Enum.Font.GothamBold, TextSize=7, BackgroundColor3=_fpSelectedFlags[fd.key] and fd.col or Color3.fromRGB(44,48,72), TextColor3=Color3.fromRGB(255,255,255), BorderSizePixel=0, Parent=fpFlagsRow})
    Instance.new("UICorner",fb).CornerRadius=UDim.new(0,3)
    fb.MouseButton1Click:Connect(function()
        if fd.key=="mega_neon" and _fpSelectedFlags.neon then return end
        if fd.key=="neon" and _fpSelectedFlags.mega_neon then return end
        _fpSelectedFlags[fd.key]=not _fpSelectedFlags[fd.key]
        fb.BackgroundColor3=_fpSelectedFlags[fd.key] and fd.col or Color3.fromRGB(44,48,72)
    end)
end

local _fpSaving = false
_G._setupLiveFakeProfileBtn = fakeProfileBtn
_G._fpGetState = function() return _fpPetIndex, _fpPetName, _fpSelectedFlags end
_G._fpSetPet = function(idx, name) _fpPetIndex=idx; _fpPetName=name; fpPetLbl.Text=name end
_G._fpSetProps = function(p)
    _fpSelectedFlags.mega_neon=p.mega_neon; _fpSelectedFlags.neon=p.neon
    _fpSelectedFlags.flyable=p.flyable; _fpSelectedFlags.rideable=p.rideable
end

-- Cloud-save hook: fake profile pet + flags.
_G._saveHooks.fakeprofile = {
    label = "Fake profile",
    save = function()
        return { idx = _fpPetIndex, name = _fpPetName, flags = {
            mega_neon = _fpSelectedFlags.mega_neon, neon = _fpSelectedFlags.neon,
            flyable = _fpSelectedFlags.flyable, rideable = _fpSelectedFlags.rideable } }
    end,
    load = function(t)
        if type(t) ~= "table" then return end
        if t.idx and t.name then _fpPetIndex = t.idx; _fpPetName = t.name; fpPetLbl.Text = t.name end
        if type(t.flags) == "table" then
            _fpSelectedFlags.mega_neon = t.flags.mega_neon; _fpSelectedFlags.neon = t.flags.neon
            _fpSelectedFlags.flyable = t.flags.flyable; _fpSelectedFlags.rideable = t.flags.rideable
        end
    end,
}

local function _runFakeProfile()
    if _fpSaving then return end
    _fpSaving = true
    fakeProfileBtn.Text = "Saving..."; fakeProfileBtn.BackgroundColor3 = Color3.fromRGB(60,60,80)
    -- Resolve pet kind from name
    local petKind = nil
    pcall(function()
        for id, data in pairs(InventoryDB.pets or {}) do
            if data.name and data.name:lower() == _fpPetName:lower() then petKind=id; break end
        end
    end)
    if not petKind then
        fakeProfileStatusLbl.Text = "❌ Pet not found"
        fakeProfileBtn.Text = "Spawn Fake Profile"; fakeProfileBtn.BackgroundColor3 = Color3.fromRGB(30,100,160)
        _fpSaving = false; return
    end
    _fpActivePetKind = petKind
    _fpIsEnabled = true
    -- Install hooks in exact same order as uploaded script
    _fpHookClientData()
    _fpHookFetchProfile()
    pcall(function()
        local app = UIManager.apps.PlayerProfileApp
        if app then _fpHookProfileApp(app) end
    end)
    -- Fire all saves
    task.spawn(function()
        local total = _MAX_PAGES * _WIDGETS_PER_PAGE; local done = 0
        local saveRemote = _fpRC.get("PlayerProfileAPI/SaveProfileSlot")
        for page = 1, _MAX_PAGES do
            for slot = 1, _WIDGETS_PER_PAGE do
                pcall(function() saveRemote:FireServer(page, slot, _fpBuildSlotData()) end)
                done = done + 1; fakeProfileStatusLbl.Text = "Saving "..done.."/"..total.."..."; task.wait()
            end
        end
        -- Open own profile to commit (same as uploaded script)
        pcall(function() UIManager.apps.PlayerProfileApp:open_player_profile_for_user_id(Players.LocalPlayer.UserId) end)
        fakeProfileStatusLbl.Text = "✅ All "..total.." slots filled!"
        fakeProfileBtn.Text = "Spawn Fake Profile"; fakeProfileBtn.BackgroundColor3 = Color3.fromRGB(30,100,160)
        task.delay(2, function() fakeProfileStatusLbl.Text = "" end)
        _fpSaving = false
    end)
end
fakeProfileBtn.MouseButton1Click:Connect(_runFakeProfile)
_G._setupLiveRunFakeProfile = _runFakeProfile

end -- fake profile do

local deleteAllBtn = mk("TextButton", {Size=UDim2.new(1, 0, 0, 13), BackgroundColor3=Color3.fromRGB(120, 20, 20), BackgroundTransparency=0.15, Text="Delete All Spawned", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255, 255, 255), Parent=spawnFrame})
Instance.new("UICorner", deleteAllBtn).CornerRadius = UDim.new(0, 3)
local deleteStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(255, 60, 60), Thickness=0.7, Transparency=0.3, Parent=deleteAllBtn})

deleteAllBtn.MouseButton1Click:Connect(function()
    local toRemove = {}
    for uid in pairs(_spawnerPets) do
        table.insert(toRemove, uid)
    end
    for _, uid in ipairs(toRemove) do
        _removeFromInventory(uid)
    end
    deleteStroke.Color = Color3.fromRGB(0, 255, 120)
    task.delay(0.4, function() deleteStroke.Color = Color3.fromRGB(255, 60, 60) end)
end)

end -- SPAWNER TAB do block

-- ANTI-RAID TAB
do
local antiFrame = tabFrames["Anti"]

local SCAN_INTERVAL = 2
local AUTO_EXCLUDE  = true

local BLACKLISTED_KEYWORDS = {
    "scam","delta","synapse","exploit","krnl","script",
    "freepets","free pets","duped","dupe","dupedpets",
    "botted","botting","raid","raiding",
    "hacked","hacking","hack","cheat",
    "drop trade","droptrade","trust trade","trusttrade",
    "phishing","robux","freerobux","free robux",
    "vedal","xeno","fluxus","arceus",
}

local UNICODE_RANGES = {
    {0x1D400,0x1D419,0x41},{0x1D41A,0x1D433,0x61},{0x1D434,0x1D44D,0x41},{0x1D44E,0x1D467,0x61},
    {0x1D468,0x1D481,0x41},{0x1D482,0x1D49B,0x61},{0x1D5A0,0x1D5B9,0x41},{0x1D5BA,0x1D5D3,0x61},
    {0x1D5D4,0x1D5ED,0x41},{0x1D5EE,0x1D607,0x61},{0x1D670,0x1D689,0x41},{0x1D68A,0x1D6A3,0x61},
    {0x24B6,0x24CF,0x41},{0x24D0,0x24E9,0x61},{0xFF21,0xFF3A,0x41},{0xFF41,0xFF5A,0x61},{0xFF10,0xFF19,0x30},
    {0x1F130,0x1F149,0x41},{0x1F150,0x1F169,0x41},{0x1F170,0x1F189,0x41},
}
local CHAR_MAP = {
    [0x0391]="a",[0x0392]="b",[0x0395]="e",[0x0397]="h",[0x0399]="i",[0x039A]="k",[0x039C]="m",[0x039D]="n",[0x039F]="o",[0x03A1]="p",
    [0x03A3]="s",[0x03A4]="t",[0x03A5]="y",[0x03A7]="x",[0x03B1]="a",[0x03B2]="b",[0x03B5]="e",[0x03B9]="i",[0x03BA]="k",
    [0x03BC]="m",[0x03BD]="n",[0x03BF]="o",[0x03C1]="r",[0x03C3]="s",[0x03C4]="t",[0x03C5]="u",[0x03C7]="x",
    [0x0410]="a",[0x0415]="e",[0x041A]="k",[0x041C]="m",[0x041D]="h",[0x041E]="o",[0x0420]="p",[0x0421]="c",[0x0422]="t",[0x0423]="y",[0x0425]="x",
    [0x0430]="a",[0x0435]="e",[0x043A]="k",[0x043C]="m",[0x043D]="h",[0x043E]="o",[0x0440]="p",[0x0441]="c",[0x0442]="t",[0x0443]="y",[0x0445]="x",
    [0x00C0]="a",[0x00C1]="a",[0x00C2]="a",[0x00C3]="a",[0x00C4]="a",[0x00C5]="a",[0x00C7]="c",[0x00C9]="e",[0x00D1]="n",[0x00D6]="o",[0x00DC]="u",
    [0x00E0]="a",[0x00E1]="a",[0x00E2]="a",[0x00E3]="a",[0x00E4]="a",[0x00E5]="a",[0x00E7]="c",[0x00E9]="e",[0x00F1]="n",[0x00F6]="o",[0x00FC]="u",[0x00DF]="s",
}

local function normalizeCp(cp)
    local s = CHAR_MAP[cp]; if s then return s end
    for _, r in ipairs(UNICODE_RANGES) do
        if cp >= r[1] and cp <= r[2] then return string.char(r[3]+(cp-r[1])) end
    end
end
local function sanitize(text)
    if type(text)~="string" then return "" end
    local out={}
    pcall(function()
        for _,cp in utf8.codes(text) do
            local m=normalizeCp(cp)
            if m then table.insert(out,m)
            elseif cp>=0x20 and cp<0x7F then table.insert(out,string.char(cp)) end
        end
    end)
    return string.lower(string.gsub(table.concat(out),"[^%a%d]",""))
end
local _sanitizedKW={}
for _,kw in ipairs(BLACKLISTED_KEYWORDS) do table.insert(_sanitizedKW,sanitize(kw)) end
local function containsBad(text)
    local c=sanitize(text); if c=="" then return false,nil end
    for _,kw in ipairs(_sanitizedKW) do
        if string.find(c,kw,1,true) then return true,kw end
    end
    return false,nil
end

local _blacklistIds = {}
local GIST_URL = "https://gist.githubusercontent.com/got4access-ops/23ee90f21946f84f602bc920904f07b2/raw/BlacklistedUserIDs"
local function fetchBlacklist()
    task.spawn(function()
        local ok,body = pcall(function()
            if syn and syn.request then return syn.request({Url=GIST_URL,Method="GET"}).Body
            elseif request then return request({Url=GIST_URL,Method="GET"}).Body
            elseif http and http.request then return http.request({url=GIST_URL,method="GET"}).body
            else return game:GetService("HttpService"):GetAsync(GIST_URL,true) end
        end)
        if not ok or not body then return end
        local new={}; local n=0
        for line in string.gmatch(body,"[^\r\n]+") do
            n=n+1; if n==1 then continue end
            local id=tonumber(string.match(line,"^%s*(%d+)%s*$"))
            if id then new[id]=true end
        end
        _blacklistIds=new
    end)
end
fetchBlacklist()
task.spawn(function() while true do task.wait(120); fetchBlacklist() end end)

local _flagged = {}
local _needRefresh = false
local _TradeExcluder = nil
pcall(function() _TradeExcluder = load("TradeExcluder") end)

local function flagPlayer(player, reason)
    if player == Players.LocalPlayer then return end
    local uid = player.UserId
    if not _flagged[uid] then
        _flagged[uid] = {display_name=player.DisplayName, user_name=player.Name, user_id=uid, reasons={}, left=false}
    end
    for _,r in ipairs(_flagged[uid].reasons) do if r==reason then return end end
    table.insert(_flagged[uid].reasons, reason)
    _needRefresh = true
    if AUTO_EXCLUDE and _TradeExcluder then
        pcall(function() _TradeExcluder.trade_was_declined(player); _TradeExcluder.trade_was_declined(player); _TradeExcluder.trade_was_declined(player) end)
    end
end
local function scanPlayer(player)
    if player == Players.LocalPlayer then return end
    if _blacklistIds[player.UserId] then flagPlayer(player, "Blacklisted user ID") end
    local hit,kw = containsBad(player.DisplayName)
    if hit then flagPlayer(player,"Display name: '"..kw.."'") end
    hit,kw = containsBad(player.Name)
    if hit then flagPlayer(player,"Username: '"..kw.."'") end
end
local function scanPetNames()
    local CWC; pcall(function() CWC=load("CharWrapperClient") end)
    if not CWC then return end
    local ok,wrappers = pcall(CWC.get_all_char_wrappers)
    if not ok or not wrappers then return end
    for _,w in pairs(wrappers) do
        if w.pet_unique and w.player and w.player~=Players.LocalPlayer then
            local rp=w.rp_name
            if rp and rp~="" then
                local hit,kw=containsBad(rp)
                if hit then flagPlayer(w.player,"Pet name: '"..kw.."' ("..rp..")") end
            end
        end
    end
end

local antiLayout = mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,3), Parent=antiFrame})

local antiHeaderRow = mk("Frame", {Size=UDim2.new(1,0,0,11), BackgroundTransparency=1, Parent=antiFrame})

local antiStatusLbl = mk("TextLabel", {Size=UDim2.new(0.65,0,1,0), BackgroundTransparency=1, Text="Scanning...", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(170, 140, 220), TextXAlignment=Enum.TextXAlignment.Left, Parent=antiHeaderRow})

local antiCountLbl = mk("TextLabel", {Size=UDim2.new(0.35,0,1,0), Position=UDim2.new(0.65,0,0,0), BackgroundTransparency=1, Text="0 flagged", Font=Enum.Font.FredokaOne, TextSize=6, TextColor3=Color3.fromRGB(255,80,80), TextXAlignment=Enum.TextXAlignment.Right, Parent=antiHeaderRow})

local antiScroll = mk("ScrollingFrame", {Size=UDim2.new(1,0,1,-14), BackgroundColor3=Color3.fromRGB(25,25,35), BackgroundTransparency=0.5, BorderSizePixel=0, ScrollBarThickness=2, ScrollBarImageColor3=Color3.fromRGB(190,34,230), ScrollBarImageTransparency=0.4, CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y, Parent=antiFrame})
Instance.new("UICorner", antiScroll).CornerRadius = UDim.new(0,4)
local antiListLayout = mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,3), Parent=antiScroll})
local antiListPad = mk("UIPadding", {PaddingTop=UDim.new(0,3), PaddingBottom=UDim.new(0,3), PaddingLeft=UDim.new(0,3), PaddingRight=UDim.new(0,3), Parent=antiScroll})

local function refreshAntiUI()
    for _,c in ipairs(antiScroll:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
    local count, order = 0, 0
    for uid, data in pairs(_flagged) do
        count = count + 1; order = order + 1
        local card = mk("Frame", {Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y, BackgroundColor3=Color3.fromRGB(40,40,52), BackgroundTransparency=0.2, LayoutOrder=order, Parent=antiScroll})
        Instance.new("UICorner", card).CornerRadius = UDim.new(0,4)
        local cs = mk("UIStroke", {Color=Color3.fromRGB(80,80,80), Thickness=0.7, Transparency=0.5, Parent=card})
        local cp = mk("UIPadding", {PaddingTop=UDim.new(0,3), PaddingBottom=UDim.new(0,3), PaddingLeft=UDim.new(0,4), PaddingRight=UDim.new(0,4), Parent=card})
        local cl = mk("UIListLayout", {Padding=UDim.new(0,2), SortOrder=Enum.SortOrder.LayoutOrder, Parent=card})

        local nameLbl = mk("TextLabel", {Size=UDim2.new(1,0,0,9), BackgroundTransparency=1, TextColor3=data.left and Color3.fromRGB(150,60,60) or Color3.fromRGB(220,50,50), Font=Enum.Font.FredokaOne, TextSize=7, Text=data.display_name..(data.left and " [LEFT]" or ""), TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, LayoutOrder=1, Parent=card})

        local userLbl = mk("TextLabel", {Size=UDim2.new(1,0,0,7), BackgroundTransparency=1, TextColor3=Color3.fromRGB(150,150,160), Font=Enum.Font.FredokaOne, TextSize=7, Text="@"..data.user_name, TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, LayoutOrder=2, Parent=card})

        for i=1,math.min(#data.reasons,2) do
            local rl = mk("TextLabel", {Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y, BackgroundTransparency=1, TextColor3=Color3.fromRGB(170,170,180), Font=Enum.Font.FredokaOne, TextSize=7, Text="- "..data.reasons[i], TextXAlignment=Enum.TextXAlignment.Left, TextWrapped=true, LayoutOrder=2+i, Parent=card})
        end
        if #data.reasons > 2 then
            local ml = mk("TextLabel", {Size=UDim2.new(1,0,0,6), BackgroundTransparency=1, TextColor3=Color3.fromRGB(190, 34, 230), Font=Enum.Font.FredokaOne, TextSize=7, Text="+"..(#data.reasons-2).." more", TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=5, Parent=card})
        end

        local btnRow = mk("Frame", {Size=UDim2.new(1,0,0,11), BackgroundTransparency=1, LayoutOrder=100, Parent=card})

        local dismissBtn = mk("TextButton", {Size=UDim2.new(0.48,0,1,0), BackgroundColor3=Color3.fromRGB(50,50,60), BackgroundTransparency=0.2, TextColor3=Color3.fromRGB(150,150,160), Font=Enum.Font.FredokaOne, TextSize=7, Text="Dismiss", Parent=btnRow})
        Instance.new("UICorner", dismissBtn).CornerRadius = UDim.new(0,3)

        local blockBtn2 = mk("TextButton", {Size=UDim2.new(0.48,0,1,0), Position=UDim2.new(0.52,0,0,0), BackgroundColor3=Color3.fromRGB(160,30,30), BackgroundTransparency=0.2, TextColor3=Color3.fromRGB(255,255,255), Font=Enum.Font.FredokaOne, TextSize=7, Text="Block", Parent=btnRow})
        Instance.new("UICorner", blockBtn2).CornerRadius = UDim.new(0,3)
        local bs2 = mk("UIStroke", {Color=Color3.fromRGB(255,60,60), Thickness=0.7, Parent=blockBtn2})

        local capturedUid, capturedCard = uid, card
        dismissBtn.MouseButton1Click:Connect(function()
            _flagged[capturedUid] = nil; capturedCard:Destroy(); _needRefresh = true
        end)
        blockBtn2.MouseButton1Click:Connect(function()
            local target = Players:GetPlayerByUserId(capturedUid)
            if target then
                blockBtn2.Text = "..."
                if _G._silentBlockPlayer then _G._silentBlockPlayer(target) end
                task.delay(1.5, function()
                    if blockBtn2.Parent then blockBtn2.Text = "Done"; blockBtn2.TextColor3 = Color3.fromRGB(80,255,130) end
                end)
            else
                blockBtn2.Text = "Gone"
            end
        end)
    end
    antiCountLbl.Text = count > 0 and count.." flagged" or "0 flagged"
    antiCountLbl.TextColor3 = count > 0 and Color3.fromRGB(255,80,80) or Color3.fromRGB(100,255,150)
    antiStatusLbl.Text = count > 0 and "⚠ threats detected" or "✓ monitoring"
    _needRefresh = false
end

-- Expose flagged data + actions so the pop-out Rich Board can mirror this tab.
_G._raidFlagged = _flagged
_G._raidDismiss = function(uid) _flagged[uid] = nil; _needRefresh = true; refreshAntiUI() end

for _, p in ipairs(Players:GetPlayers()) do scanPlayer(p) end
refreshAntiUI()

-- Hook chat messages from all players
local function scanChatMessage(player, text)
    if not player or player == Players.LocalPlayer then return end
    if not text or text == "" then return end
    local hit, kw = containsBad(text)
    if hit then
        flagPlayer(player, "Chat: '"..kw.."'  ("..text:sub(1,40)..")")
        refreshAntiUI()
    end
end

task.spawn(function()
    -- Hook TextChatService.OnIncomingMessage — fires for ALL incoming messages client-side
    pcall(function()
        local TextChatService = game:GetService("TextChatService")
        local orig = TextChatService.OnIncomingMessage
        TextChatService.OnIncomingMessage = function(msg)
            pcall(function()
                if msg and msg.TextSource and msg.Text and msg.Text ~= "" then
                    local player = Players:GetPlayerByUserId(msg.TextSource.UserId)
                    scanChatMessage(player, msg.Text)
                end
            end)
            if orig then return orig(msg) end
        end
    end)

    -- Also hook each TextChannel.MessageReceived as backup
    pcall(function()
        local TextChatService = game:GetService("TextChatService")
        local function hookChannel(ch)
            if ch._antiHooked then return end
            ch._antiHooked = true
            ch.MessageReceived:Connect(function(msg)
                pcall(function()
                    if not msg or not msg.TextSource then return end
                    local player = Players:GetPlayerByUserId(msg.TextSource.UserId)
                    scanChatMessage(player, msg.Text or "")
                end)
            end)
        end
        for _, ch in ipairs(TextChatService:GetDescendants()) do
            if ch:IsA("TextChannel") then hookChannel(ch) end
        end
        TextChatService.DescendantAdded:Connect(function(ch)
            if ch:IsA("TextChannel") then hookChannel(ch) end
        end)
    end)

    -- Hook Players[x].Chatted (fires for proximity/legacy chat)
    local function hookLegacy(player)
        pcall(function()
            player.Chatted:Connect(function(msg)
                scanChatMessage(player, msg)
            end)
        end)
    end
    for _, p in ipairs(Players:GetPlayers()) do
        hookLegacy(p)
    end
    Players.PlayerAdded:Connect(function(p)
        hookLegacy(p)
    end)
end)

Players.PlayerAdded:Connect(function(p)
    scanPlayer(p)
    task.delay(4, function()
        if p.Parent then scanPetNames() end
        if _needRefresh then refreshAntiUI() end
    end)
    if _needRefresh then refreshAntiUI() end
end)
Players.PlayerRemoving:Connect(function(p)
    if _flagged[p.UserId] then _flagged[p.UserId].left = true; _needRefresh = true end
    if _needRefresh then refreshAntiUI() end
end)
task.spawn(function()
    while true do
        task.wait(SCAN_INTERVAL)
        for _, p in ipairs(Players:GetPlayers()) do scanPlayer(p) end
        scanPetNames()
        if _needRefresh then refreshAntiUI() end
    end
end)

end -- ANTI-RAID TAB do block

-- CHAT TAB
do
local chatFrame = tabFrames["Chat"]
if not chatFrame then
    chatFrame = Instance.new("Frame")
    chatFrame.Size = UDim2.new(0.9,0,1,-33); chatFrame.Position = UDim2.new(0.05,0,0,33)
    chatFrame.BackgroundTransparency = 1; chatFrame.Visible = false; chatFrame.Parent = mainFrame
    tabFrames["Chat"] = chatFrame
end

-- Custom-message row at the top: type your own line for the partner to "say", then Send.
local customRow = mk("Frame", {Size=UDim2.new(1,0,0,18), BackgroundTransparency=1, Parent=chatFrame})
local customBox = mk("TextBox", {Size=UDim2.new(1,-30,1,0), BackgroundColor3=Color3.fromRGB(40,40,52), Text="", PlaceholderText="Type a message...", PlaceholderColor3=Color3.fromRGB(120,120,140), Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(235,235,255), TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, ClearTextOnFocus=false, ClipsDescendants=true, BorderSizePixel=0, Parent=customRow})
Instance.new("UICorner", customBox).CornerRadius = UDim.new(0,3)
mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=0.7, Transparency=0.4, Parent=customBox})
mk("UIPadding", {PaddingLeft=UDim.new(0,4), PaddingRight=UDim.new(0,4), Parent=customBox})
local customSendBtn = mk("TextButton", {Size=UDim2.new(0,28,1,0), Position=UDim2.new(1,-28,0,0), BackgroundColor3=Color3.fromRGB(190,34,230), Text="Send", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255,255,255), BorderSizePixel=0, Parent=customRow})
Instance.new("UICorner", customSendBtn).CornerRadius = UDim.new(0,3)
mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(230,120,255), Thickness=0.7, Transparency=0.3, Parent=customSendBtn})

local chatStatusLbl = mk("TextLabel", {Size=UDim2.new(1,0,0,11), Position=UDim2.new(0,0,0,20), BackgroundTransparency=1, Text="Click a message to send", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(140,140,160), TextXAlignment=Enum.TextXAlignment.Left, Parent=chatFrame})
local _cspad = mk("UIPadding", {PaddingLeft=UDim.new(0,3), Parent=chatStatusLbl})

local chatScrollFrame = mk("ScrollingFrame", {Size=UDim2.new(1,0,1,-33), Position=UDim2.new(0,0,0,33), BackgroundTransparency=1, BorderSizePixel=0, ScrollBarThickness=2, ScrollBarImageColor3=Color3.fromRGB(190,34,230), CanvasSize=UDim2.new(0,0,0,0), Parent=chatFrame})
local chatListLayout = mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,3), Parent=chatScrollFrame})
local chatPad = mk("UIPadding", {PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4), PaddingLeft=UDim.new(0,4), PaddingRight=UDim.new(0,4), Parent=chatScrollFrame})
chatListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    chatScrollFrame.CanvasSize = UDim2.new(0,0,0,chatListLayout.AbsoluteContentSize.Y + 8)
end)

local _chatQueue = {}
local _chatQueueRunning = false

local function _runChatQueue()
    if _chatQueueRunning then return end
    _chatQueueRunning = true
    task.spawn(function()
        while #_chatQueue > 0 do
            local item = table.remove(_chatQueue, 1)
            local msg, btn = item.msg, item.btn
            btn.TextColor3 = Color3.fromRGB(255,220,80)

            -- Typing indicator
            local typingLabel = nil
            safeCall(function()
                local scrollFrame = TradeApp.chat_scrolling_frame
                local template = TradeApp.chat_message_template
                if not scrollFrame or not template then return end
                local atBottom = math.abs(scrollFrame.CanvasSize.Y.Offset - scrollFrame.AbsoluteSize.Y - scrollFrame.CanvasPosition.Y) < 40
                local clone = template:Clone()
                clone.Name = "TypingMessage"; clone.RichText = true
                clone.Text = string.format("<i><b>%s</b> is typing</i>", CONFIG.PARTNER_NAME:lower())
                clone.TextColor3 = Color3.fromRGB(150,150,150); clone.TextSize = 22
                clone.TextTransparency = 0; clone.LayoutOrder = 1; clone.Parent = scrollFrame.Content
                local h = clone.TextBounds.Y
                clone.Size = UDim2.new(1,0,0,h)
                scrollFrame.CanvasSize = scrollFrame.CanvasSize + UDim2.new(0,0,0,h)
                if atBottom then scrollFrame.CanvasPosition = Vector2.new(0, scrollFrame.CanvasSize.Y.Offset - scrollFrame.AbsoluteSize.Y) end
                typingLabel = clone
            end)
            local elapsed, dotTimer, dots = 0, 0, 0
            while elapsed < 1.8 and typingLabel and typingLabel.Parent do
                local dt = task.wait(0.05)
                elapsed = elapsed + dt; dotTimer = dotTimer + dt
                if dotTimer >= 0.25 then
                    dotTimer = 0; dots = (dots % 3) + 1
                    typingLabel.Text = string.format("<i><b>%s</b> is typing%s</i>", CONFIG.PARTNER_NAME:lower(), string.rep(".", dots))
                end
            end
            if typingLabel and typingLabel.Parent then
                safeCall(function()
                    local scrollFrame = TradeApp.chat_scrolling_frame
                    scrollFrame.CanvasSize = scrollFrame.CanvasSize - UDim2.new(0,0,0,typingLabel.Size.Y.Offset)
                end)
                typingLabel:Destroy()
            end

            -- Send
            pcall(function()
                local partner = TradeApp:_get_partner()
                if partner then TradeApp:_render_message_in_trade_chat(partner, msg, true) end
            end)
            btn.TextColor3 = Color3.fromRGB(235,235,255)
            chatStatusLbl.Text = #_chatQueue > 0 and (#_chatQueue .. " queued...") or "Sent!"
            chatStatusLbl.TextColor3 = #_chatQueue > 0 and Color3.fromRGB(255,220,80) or Color3.fromRGB(100,255,150)
            if #_chatQueue == 0 then
                task.delay(1.5, function()
                    chatStatusLbl.Text = "Click a message to send"
                    chatStatusLbl.TextColor3 = Color3.fromRGB(140,140,160)
                end)
            end
            task.wait(0.15)
        end
        _chatQueueRunning = false
    end)
end

local function sendChatMessage(msg, btn)
    if not mockState.active or not mockState.trade then
        chatStatusLbl.Text = "No active trade!"
        chatStatusLbl.TextColor3 = Color3.fromRGB(255,100,100)
        task.delay(1.5, function()
            chatStatusLbl.Text = "Click a message to send"
            chatStatusLbl.TextColor3 = Color3.fromRGB(140,140,160)
        end)
        return
    end
    table.insert(_chatQueue, {msg=msg, btn=btn})
    chatStatusLbl.Text = #_chatQueue > 1 and (#_chatQueue .. " queued...") or "Sending..."
    chatStatusLbl.TextColor3 = Color3.fromRGB(255,220,80)
    _runChatQueue()
end

-- Custom-message send: take whatever's typed and make the partner "say" it, then clear.
local function _sendCustomChat()
    local txt = customBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
    if txt == "" then return end
    sendChatMessage(txt, customSendBtn)
    customBox.Text = ""
end
customSendBtn.MouseButton1Click:Connect(_sendCustomChat)
customBox.FocusLost:Connect(function(enterPressed) if enterPressed then _sendCustomChat() end end)

-- Build message buttons using same style as Players tab
local _chatBtns = {}
local function buildChatButtons()
    for _, child in ipairs(chatScrollFrame:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
    _chatBtns = {}
    local _cl = ChatList or _G._ChatList or {}
    for i, msg in ipairs(_cl) do
        local btn = mk("TextButton", {Size=UDim2.new(1,0,0,22), BackgroundColor3=Color3.fromRGB(40,40,52), BackgroundTransparency=0.2, Text="", LayoutOrder=i, BorderSizePixel=0, Parent=chatScrollFrame})
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0,4)
        local stroke = mk("UIStroke", {Color=Color3.fromRGB(80,80,80), Thickness=0.8, Transparency=0.5, Parent=btn})
        local lbl = mk("TextLabel", {Size=UDim2.new(1,-6,1,0), Position=UDim2.new(0,4,0,0), BackgroundTransparency=1, Text=msg, Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(235,235,255), TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, Parent=btn})
        table.insert(_chatBtns, btn)
        btn.MouseButton1Click:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.08, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {BackgroundTransparency=0.05}):Play()
            task.delay(0.12, function()
                TweenService:Create(btn, TweenInfo.new(0.15, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {BackgroundTransparency=0.2}):Play()
            end)
            sendChatMessage(msg, lbl)
        end)
    end
    -- Animate in like player list
    for i, btn in ipairs(_chatBtns) do
        btn.BackgroundTransparency = 1
        local s = btn:FindFirstChildOfClass("UIStroke")
        local l = btn:FindFirstChildOfClass("TextLabel")
        if s then s.Transparency = 1 end
        if l then l.TextTransparency = 1 end
        task.spawn(function()
            task.wait((i-1) * 0.04)
            TweenService:Create(btn, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {BackgroundTransparency=0.2}):Play()
            if s then TweenService:Create(s, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Transparency=0.5}):Play() end
            if l then TweenService:Create(l, TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {TextTransparency=0}):Play() end
        end)
    end
end

buildChatButtons()
end -- CHAT TAB do block

do
local fsysLoad = load  -- our script's load = Fsys.load

-- Spawn a spun pet locally; if a trade is mid-negotiation, push it into the live offer.
local function addSpinPetToTrade(id, props)
    if not _G._spinnerCreate then return end
    local newPet = _G._spinnerCreate(id, props)
    if not newPet then return end
    task.defer(function()
        pcall(function()
            local TradeApp = UIManager and UIManager.apps and UIManager.apps.TradeApp
            local tradeState = TradeApp and TradeApp:_get_local_trade_state()
            if tradeState and tradeState.current_stage == "negotiation" then
                local RouterClient = fsysLoad("RouterClient")
                RouterClient.get("TradeAPI/AddItemToOffer"):FireServer(newPet.unique)
                local myOffer, offerKey = TradeApp:_get_my_offer()
                local items = {}
                for _,v in ipairs(myOffer.items) do table.insert(items,v) end
                table.insert(items, newPet)
                TradeApp:_change_local_trade_state({[offerKey]={items=items}})
                TradeApp:_lock_trade_for_appropriate_time()
                TradeApp:refresh_all()
            end
        end)
    end)
end

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local LocalPlayer      = Players.LocalPlayer
local PlayerGui        = LocalPlayer:WaitForChild("PlayerGui")
local InventoryDB  = (function() local ok,m = pcall(fsysLoad,"InventoryDB")  return ok and m or nil end)()
local DailyLoginDB = (function() local ok,m = pcall(fsysLoad,"DailyLoginDB") return ok and m or nil end)()
local UIManager    = (function() local ok,m = pcall(fsysLoad,"UIManager")    return ok and m or nil end)()

-- Anti-stack: every pet gets a unique hash so they never stack in backpack
do
    local ok, HashHelper = pcall(function()
        return fsysLoad("BackpackItemStackHashHelper")
    end)
    if ok and HashHelper and HashHelper.get_item_data_hash and not HashHelper._antiStackInstalled then
        HashHelper._antiStackInstalled = true
        local _orig = HashHelper.get_item_data_hash
        HashHelper.get_item_data_hash = function(item_data)
            if item_data and item_data.unique then
                return "nostack_" .. item_data.unique
            end
            return _orig(item_data)
        end
    end
end

local InventoryDB  = (function() local ok,m = pcall(fsysLoad,"InventoryDB")  return ok and m or nil end)()
local DailyLoginDB = (function() local ok,m = pcall(fsysLoad,"DailyLoginDB") return ok and m or nil end)()
local UIManager    = (function() local ok,m = pcall(fsysLoad,"UIManager")    return ok and m or nil end)()

local HttpService = game:GetService("HttpService")

-- _G._spinnerCreate is set by our main spawner loadSpawner()
-- _G._spinnerRouterHooked prevents double-hooking
local _spawnerPets = {}  -- spinner's own local reference (populated via _G._spinnerCreate)
local HttpService = game:GetService("HttpService")

task.spawn(function()
    pcall(function()
        if type(setthreadidentity)=="function" then setthreadidentity(2) end
        local PetActions    = fsysLoad("PetActions")
        local AnimMgr       = fsysLoad("AnimationManager")
        local PEM           = fsysLoad("PetEntityManager")
        local UIManager2    = fsysLoad("UIManager")
        local IDB2          = fsysLoad("InventoryDB")
        if not PetActions or not PetActions.do_trick then return end

        local origDoTrick = PetActions.do_trick
        PetActions.do_trick = function(wrapper)
            if not (wrapper and _spawnerPets and _spawnerPets[wrapper.pet_unique]) then
                return origDoTrick(wrapper)
            end
            local entry = IDB2.pets[wrapper.pet_id]
            if not entry or not entry.tricks or #entry.tricks==0 then return end

            local buttons = {}
            for i,trick in ipairs(entry.tricks) do
                local trickLevel = wrapper.pet_trick_level or 0
                if trickLevel < i then
                    buttons[i] = {layout_order=i, text="???", button_state="inactive"}
                else
                    buttons[i] = {layout_order=i, text=trick[1]}
                end
            end

            task.spawn(function()
                local chosen = UIManager2.apps.DialogApp:dialog({ dialog_type  = "ScrollingButtonsDialog", header       = "SELECT TRICK", buttons      = buttons, exit_button  = true, cells_per_row= 2, padding      = 10, })
                if not chosen or chosen=="cancel" then return end
                local trickEntry = entry.tricks[chosen]
                if not trickEntry then return end
                local trickName = trickEntry[1]
                local animKey   = trickEntry[2] or trickName
                local char      = wrapper.char
                local petModel  = char:FindFirstChild("PetModel")
                local animCtrl  = petModel and petModel:FindFirstChildOfClass("AnimationController")
                local animator  = (animCtrl and animCtrl:FindFirstChildOfClass("Animator"))
                              or char:FindFirstChildWhichIsA("Animator",true)
                if not animator then return end
                local animTrack = AnimMgr.get_track(animKey) or AnimMgr.get_track(trickName)
                if not animTrack then return end
                pcall(function() origDoTrick(wrapper) end)
                task.wait(3)
                pcall(function() UIManager2.apps.FocusPetApp:release_focus() end)
                pcall(function()
                    local sp = _spawnerPets[wrapper.pet_unique]
                    if sp and sp._activeTrickTrack then
                        pcall(function() sp._activeTrickTrack:Stop(0.1) end)
                        sp._activeTrickTrack = nil
                    end
                    local track = animator:LoadAnimation(animTrack)
                    track:Play()
                    if sp then sp._activeTrickTrack = track end
                    task.spawn(function()
                        local lp = LocalPlayer
                        local t = 0
                        while t < 15 do
                            task.wait(0.1); t=t+0.1
                            if not track.IsPlaying then break end
                            local lpChar = lp and lp.Character
                            local hrp = lpChar and lpChar:FindFirstChild("HumanoidRootPart")
                            local entity = PEM and PEM.get_pet_entity(char)
                            if entity and entity.move_state and entity.move_state.is_moving then
                                track:Stop(0.2); break
                            end
                        end
                        if sp then sp._activeTrickTrack=nil end
                    end)
                end)
            end)
        end
    end)
end)

local WEEK_LENGTH  = DailyLoginDB and DailyLoginDB.week_length  or 5

local COL_NORMAL = Color3.fromRGB(220, 60, 60)
local COL_GREEN  = Color3.fromRGB(80,  220, 100)
local COL_GREEN2 = Color3.fromRGB(160, 255, 140)

local SCALE_SELECTED = 1.18
local SCALE_NORMAL_V = 1.0
local SCALE_TWEEN    = 0.12
local CARD_GAP       = 8

local function corner(inst, r)
    local c=Instance.new("UICorner") c.CornerRadius=UDim.new(0,r or 8) c.Parent=inst return c
end
local function splitCSV(str)
    local t={}
    for part in (str..","):gmatch("([^,]+),") do
        local s=part:match("^%s*(.-)%s*$") if #s>0 then table.insert(t,s) end
    end
    return t
end

local PREFS = {
    tagline    = "Spin to win your dream pet!",
    spinText   = "SPINNING",
    dialogText = "You got: ",
    showNotebookSpiral = true,
    showEggs           = false,
    randomKinds        = false,
}

local function shuffle(t)
    local s=table.clone(t)
    for i=#s,2,-1 do local j=math.random(i);s[i],s[j]=s[j],s[i] end
    return s
end
local function easeOutQuint(t) return 1-(1-t)^5 end

local petByName={}
local petList={}
if InventoryDB and InventoryDB.pets then
    for id,data in pairs(InventoryDB.pets) do
        if data.name and data.image then
            local e={id=id,name=data.name,image=data.image}
            petByName[data.name:lower()]=e
            table.insert(petList,e)
        end
    end
end
if #petList==0 then
    for _,name in ipairs({"Dog","Cat","Dragon","Unicorn","Griffin","Frost Dragon",
        "Shadow Dragon","Golden Unicorn","Bat Dragon","Turtle","Crow","Evil Unicorn",
        "Giraffe","Neon Dragon","Flamingo"}) do
        local e={id=name:lower():gsub(" ","_"),name=name,image="rbxassetid://0"}
        petByName[name:lower()]=e table.insert(petList,e)
    end
end

local function openApp(app)
    local ok=pcall(function()
        app.instance.Enabled=true
        app.instance.Frame.Visible=true
    end)
    return ok and app.instance.Enabled and app.instance.Frame.Visible
end

local function closeApp(app)
    pcall(function()
        app.instance.Frame.Visible=false
        app.instance.Enabled=false
        if app.days_list then app.days_list.Visible=false end
    end)
end

local function setArrowsVisible(app, visible)
    pcall(function() app.left_button_instance.Parent.Visible=visible end)
    pcall(function() app.right_button_instance.Parent.Visible=visible end)
end

local reelRoot   = nil
local stripFrame = nil

local function destroyReel(app)
    if reelRoot and reelRoot.Parent then reelRoot:Destroy() end
    reelRoot=nil stripFrame=nil
    if app then
        setArrowsVisible(app, true)
        pcall(function() if app.days_list then app.days_list.Visible=true end end)
    end
end

local lastCentredCard = nil

local function setFrameColor(card, color)
    if not card or not card.Parent then return end
    local fi=card:FindFirstChild("FrameImage")
    if fi then fi.ImageColor3=color end
end

local function setCardScale(card, scale, instant)
    if not card or not card.Parent then return end
    local s=card:FindFirstChildOfClass("UIScale")
    if not s then s=Instance.new("UIScale") s.Scale=SCALE_NORMAL_V s.Parent=card end
    if instant then s.Scale=scale
    else TweenService:Create(s,TweenInfo.new(SCALE_TWEEN,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Scale=scale}):Play() end
end

local function updateCentredCard(cards, stripX, vpW, cardW)
    local step=cardW+CARD_GAP
    local centreInStrip=vpW/2-stripX
    local bestIdx,bestDist=nil,math.huge
    for i,card in ipairs(cards) do
        local cc=(i-1)*step+CARD_GAP+cardW/2
        local d=math.abs(cc-centreInStrip)
        if d<bestDist then bestDist=d bestIdx=i end
    end
    local newCard=bestIdx and cards[bestIdx] or nil
    if newCard~=lastCentredCard then
        if lastCentredCard and lastCentredCard.Parent then
            setFrameColor(lastCentredCard,COL_NORMAL)
            setCardScale(lastCentredCard,SCALE_NORMAL_V,false)
        end
        if newCard and newCard.Parent then
            setFrameColor(newCard,COL_GREEN)
            setCardScale(newCard,SCALE_SELECTED,false)
        end
        lastCentredCard=newCard
    else
        if newCard and newCard.Parent then
            local fi=newCard:FindFirstChild("FrameImage")
            if fi then fi.ImageColor3=COL_GREEN:Lerp(COL_GREEN2,(math.sin(tick()*5)+1)/2) end
        end
    end
end

local activeMutations={}  -- populated by control panel mutation buttons

local function buildReel(app, sequence, winnerIdx)
    destroyReel(nil)
    lastCentredCard=nil

    app.days_list.Visible=false
    setArrowsVisible(app,false)

    local dlc=app.days_list_container
    task.wait()
    local vpW=dlc.AbsoluteSize.X
    local vpH=dlc.AbsoluteSize.Y

    reelRoot=Instance.new("Frame")
    reelRoot.Name="SpinnerReelRoot"
    reelRoot.Size=UDim2.new(1,0,1,0)
    reelRoot.Position=UDim2.new(0,0,0,0)
    reelRoot.BackgroundTransparency=1
    reelRoot.BorderSizePixel=0
    reelRoot.ClipsDescendants=true
    reelRoot.ZIndex=10
    reelRoot.Parent=dlc

    local sampleCard=app.day_template:Clone()
    sampleCard.Visible=false sampleCard.Parent=reelRoot
    task.wait()
    local cW=math.max(sampleCard.AbsoluteSize.X,10)
    local cH=math.max(sampleCard.AbsoluteSize.Y,10)
    sampleCard:Destroy()

    local step=cW+CARD_GAP
    local stripW=#sequence*step+CARD_GAP
    local stripY=(vpH-cH)/2

    stripFrame=Instance.new("Frame")
    stripFrame.Name="Strip"
    stripFrame.Size=UDim2.fromOffset(stripW,cH)
    stripFrame.Position=UDim2.fromOffset(0,stripY)
    stripFrame.BackgroundTransparency=1
    stripFrame.BorderSizePixel=0
    stripFrame.ClipsDescendants=false
    stripFrame.ZIndex=11
    stripFrame.Parent=reelRoot

    local cards={}
    for i,pet in ipairs(sequence) do
        local card=app.day_template:Clone()
        card.Name="ReelCard"..i
        card.Size=UDim2.fromOffset(cW,cH)
        card.AnchorPoint=Vector2.new(0.5,0.5)
        card.Position=UDim2.fromOffset((i-1)*step+CARD_GAP+cW/2, cH/2)
        card.Visible=true
        card.ZIndex=12

        for _,child in card:GetChildren() do
            if child:IsA("UIListLayout") or child:IsA("UIGridLayout") then child:Destroy() end
        end

        local mi=card:FindFirstChild("MoneyIcon")
        local gi=card:FindFirstChild("GiftIcon")
        local ii=card:FindFirstChild("ItemIcon")
        local rl=card:FindFirstChild("RewardLabel")
        local rp=card:FindFirstChild("RadialPinstripe")
        local dl=card:FindFirstChild("DayLabel")
        local sl=card:FindFirstChild("StarsLabel")
        local cf=card:FindFirstChild("ClaimedFill")
        local fi=card:FindFirstChild("FrameImage")
        if mi then mi.Visible=false end
        if gi then gi.Visible=false end
        if rp then rp.Visible=false end
        if cf then cf.Visible=false end
        if ii then ii.Visible=true; ii.Image=pet.image end
        if rl then rl.Text=pet.name end
        if dl then dl.Text="REWARD" end  -- show REWARD instead of day number
        if sl then sl.Visible=false end
        if fi then fi.ImageColor3=COL_NORMAL end

        local ok, err = pcall(function()
            local template = game.ReplicatedStorage.Resources.UI_Resources.Templates.TagDisplayTemplate:Clone()
            template.Size     = UDim2.new(1, 0, 0, 15); template.Position = UDim2.new(0, 0, 1, -20)
            template.ZIndex   = card.ZIndex + 3; template.Parent   = card

            for _, child in template:GetChildren() do
                if child:IsA("Frame") or child:IsA("ImageLabel") then
                    child.Visible = false
                end
            end

            local showFly, showRide, showNeon, showMega
            local isWinnerCard = (winnerIdx and i == winnerIdx)
            if PREFS.randomKinds and not isWinnerCard then
                local neonRoll = math.random(3)
                showMega = (neonRoll == 1)
                showNeon = (neonRoll == 2)
                showFly  = (math.random(2) == 1)
                showRide = (math.random(2) == 1)
            else
                showFly  = activeMutations.fly      == true
                showRide = activeMutations.ride     == true
                showNeon = activeMutations.neon     == true
                showMega = activeMutations.megaNeon == true
            end

            local flyPip      = template:FindFirstChild("flyable")
            local ridePip     = template:FindFirstChild("rideable")
            local neonPip     = template:FindFirstChild("neon")
            local megaNeonPip = template:FindFirstChild("mega_neon")
            if flyPip      then flyPip.Visible      = showFly  end
            if ridePip     then ridePip.Visible     = showRide end
            if neonPip     then neonPip.Visible     = showNeon end
            if megaNeonPip then megaNeonPip.Visible = showMega end
        end)
        if not ok then warn("[PetSpinner] pip error: "..tostring(err)) end

        local uiScale = mk("UIScale", {Scale=SCALE_NORMAL_V, Parent=card})

        card.Parent=stripFrame
        cards[i]=card
    end

    return cards,cW,vpW,stripY
end

local isBusy=false
local spinState="idle"  -- "idle" | "spinning" | "claim"
local selectBtn  -- forward declared, set in control panel
local _spinnerPickerFn = nil  -- set when selectBtn is created, called by second backpack button
local function openSpinnerPicker()
    if _spinnerPickerFn then task.spawn(_spinnerPickerFn) end
end

local function doSpin(inputNames, targetName)
    if isBusy then return end
    isBusy=true

    local targetEntry
    if #targetName>0 then
        targetEntry=petByName[targetName:lower()]
                 or {id="custom",name=targetName,image="rbxassetid://0"}
    end

    local fillers={}
    local function isEgg(e) return e.name:lower():find("egg") ~= nil end
    if #inputNames>0 then
        for _,name in ipairs(inputNames) do
            local e=petByName[name:lower()] or {id="custom",name=name,image="rbxassetid://0"}
            if (PREFS.showEggs or not isEgg(e)) and (not targetEntry or e.name:lower()~=targetEntry.name:lower()) then
                table.insert(fillers,e)
            end
        end
    else
        local sh=shuffle(petList)
        for _,e in ipairs(sh) do
            if #fillers>=40 then break end
            if PREFS.showEggs or not isEgg(e) then
                table.insert(fillers,e)
            end
        end
    end

    if not targetEntry then
        if #fillers==0 then
            StatusLbl.Text="No pets in pool!" StatusLbl.TextColor3=Color3.fromRGB(220,80,80)
            SpinBtn.Text="SPIN!" spinState="idle" isBusy=false return
        end
        local idx=math.random(1,#fillers)
        targetEntry=fillers[idx] table.remove(fillers,idx)
    end

    if not UIManager then
        StatusLbl.Text="UIManager not available!" StatusLbl.TextColor3=Color3.fromRGB(220,80,80)
        SpinBtn.Text="SPIN!" spinState="idle" isBusy=false return
    end
    local app=UIManager.apps.DailyLoginApp
    if not app then
        StatusLbl.Text="DailyLoginApp not found!" StatusLbl.TextColor3=Color3.fromRGB(220,80,80)
        SpinBtn.Text="SPIN!" spinState="idle" isBusy=false return
    end

    StatusLbl.Text="Opening Daily Login..."
    StatusLbl.TextColor3=Color3.fromRGB(180,180,180)
    if not openApp(app) then
        StatusLbl.Text="Could not open Daily Login!" StatusLbl.TextColor3=Color3.fromRGB(220,80,80)
        SpinBtn.Text="SPIN!" spinState="idle" isBusy=false return
    end
    task.wait(0.15)

    -- Show admin badge above the DailyLogin dialog
    pcall(function()
        local dlFrame = PlayerGui.DailyLoginApp.Frame
        local old = dlFrame:FindFirstChild("AdminBadge")
        if old then old:Destroy() end

        local badge = mk("Frame", {Name="AdminBadge", Size=UDim2.new(0, 400, 0, 40), AnchorPoint=Vector2.new(0.5, 1), Position=UDim2.new(0.5, 0, 0, -22), BackgroundTransparency=1, BorderSizePixel=0, ZIndex=10, Parent=dlFrame})

        local ICON_SIZE = 28
        local txt = Instance.new("TextLabel", badge)
        txt.Size = UDim2.new(1, 0, 1, 0); txt.Position = UDim2.new(0, 0, 0, 0)
        txt.BackgroundTransparency = 1; txt.RichText = false
        txt.Text = "This feature is exclusive to Uplift Admins"; txt.Font = Enum.Font.FredokaOne
        txt.TextSize = 28; txt.TextColor3 = Color3.fromRGB(255, 255, 255)
        txt.TextScaled = false; txt.ZIndex = 11
        local tStroke = Instance.new("UIStroke", txt)
        tStroke.Color = Color3.new(0,0,0)
        tStroke.Thickness = 1.5

        task.defer(function()
            local tbX = txt.TextBounds.X
            local gap = 8
            local iconL = Instance.new("ImageLabel", badge)
            iconL.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE); iconL.AnchorPoint = Vector2.new(1, 0.5)
            iconL.Position = UDim2.new(0.5, -tbX/2 - gap, 0.5, 0); iconL.BackgroundTransparency = 1
            iconL.Image = "rbxassetid://5269331469"; iconL.ZIndex = 11

            local iconR = Instance.new("ImageLabel", badge)
            iconR.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE); iconR.AnchorPoint = Vector2.new(0, 0.5)
            iconR.Position = UDim2.new(0.5, tbX/2 + gap, 0.5, 0); iconR.BackgroundTransparency = 1
            iconR.Image = "rbxassetid://5269331469"; iconR.ZIndex = 11
        end)

        task.spawn(function()
            while badge and badge.Parent do
                TweenService:Create(txt, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                    {TextColor3=Color3.fromRGB(220,160,255)}):Play()
                task.wait(1.2)
                TweenService:Create(txt, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                    {TextColor3=Color3.fromRGB(255,255,255)}):Play()
                task.wait(1.2)
            end
        end)
    end)
    pcall(function()
        local buttons = PlayerGui.DailyLoginApp.Frame.Body.Buttons
        local claimAd    = buttons:FindFirstChild("ClaimAdButton")
        local milestones = buttons:FindFirstChild("MilestonesButton")
        if claimAd    then claimAd:Destroy() end
        if milestones then milestones:Destroy() end
        local layout = buttons:FindFirstChildOfClass("UIListLayout")
        if layout then layout:Destroy() end
        local h = buttons.AbsoluteSize.Y > 0 and buttons.AbsoluteSize.Y or 48
        buttons.Size = UDim2.new(1, -60, 0, h)
        pcall(function()
            local tagline = PlayerGui.DailyLoginApp.Frame.Body.TaglineArea.Tagline
            tagline.Text = PREFS.tagline
        end)
        pcall(function()
        end)
        local claimBtn = buttons:FindFirstChild("ClaimButton")
        if claimBtn then
            claimBtn.Size        = UDim2.new(1, 0, 1, 0); claimBtn.Position    = UDim2.new(0, 0, 0.5, 0)
            claimBtn.AnchorPoint = Vector2.new(0, 0.5)
        end
    end)

    local LEAD,TRAIL=28,5
    local sequence={}
    local function fillerAt(i)
        if #fillers==0 then return targetEntry end
        return fillers[(i-1)%#fillers+1]
    end
    for i=1,LEAD   do table.insert(sequence,fillerAt(i)) end
    table.insert(sequence,targetEntry)
    for i=1,TRAIL  do table.insert(sequence,fillerAt(LEAD+i)) end

    local winnerSeqIdx=LEAD+1

    pcall(function()
        local cb = PlayerGui.DailyLoginApp.Frame.Body.Buttons.ClaimButton
        cb.Active = false
        cb.AutoButtonColor = false
    end)

    StatusLbl.Text=PREFS.spinText.."."
    StatusLbl.TextColor3=Color3.fromRGB(180,180,180)
    if SpinBtn then
        SpinBtn.Text=PREFS.spinText.."."
        SpinBtn.BackgroundColor3=Color3.fromRGB(20,55,35)
    end

    local dotState=0
    local dotPatterns={PREFS.spinText..".", PREFS.spinText.."..", PREFS.spinText.."..."}
    local dotTimer=0
    local dotAnimConn
    dotAnimConn=RunService.Heartbeat:Connect(function(dt)
        dotTimer=dotTimer+dt
        if dotTimer>=0.4 then
            dotTimer=0
            dotState=(dotState+1)%3
            local txt=dotPatterns[dotState+1]
            StatusLbl.Text=txt
            if SpinBtn then SpinBtn.Text=txt end
            pcall(function()
                PlayerGui.DailyLoginApp.Frame.Body.Buttons.ClaimButton.Face.TextLabel.Text=txt
            end)
        end
    end)

    local cards,cW,vpW,stripY=buildReel(app,sequence,winnerSeqIdx)
    if not stripFrame then
        StatusLbl.Text="Failed to build reel!" StatusLbl.TextColor3=Color3.fromRGB(220,80,80)
        SpinBtn.Text="SPIN!" spinState="idle" isBusy=false return
    end

    local step=cW+CARD_GAP
    local winnerLeft=(winnerSeqIdx-1)*step+CARD_GAP
    local endX=vpW/2-winnerLeft-cW/2
    local startX=vpW/2-CARD_GAP-cW/2

    stripFrame.Position=UDim2.fromOffset(startX,stripY)

    lastCentredCard=nil
    updateCentredCard(cards,startX,vpW,cW)

    local SPIN_DUR=4.0
    local elapsed=0
    local pulseConn,conn

    pulseConn=RunService.Heartbeat:Connect(function()
        if not stripFrame or not stripFrame.Parent then pulseConn:Disconnect() return end
        if lastCentredCard and lastCentredCard.Parent then
            local fi=lastCentredCard:FindFirstChild("FrameImage")
            if fi then fi.ImageColor3=COL_GREEN:Lerp(COL_GREEN2,(math.sin(tick()*5)+1)/2) end
        end
    end)

    conn=RunService.Heartbeat:Connect(function(dt)
        elapsed=elapsed+dt
        local t=math.clamp(elapsed/SPIN_DUR,0,1)

        local eased
        if t<0.55 then
            local t2=t/0.55
            eased=0.55*(t2^3)
        else
            local t2=(t-0.55)/0.45
            eased=0.55+0.45*easeOutQuint(t2)
        end

        local currentX=startX+(endX-startX)*eased
        if stripFrame and stripFrame.Parent then
            stripFrame.Position=UDim2.fromOffset(currentX,stripY)
            updateCentredCard(cards,currentX,vpW,cW)
        end

        if t>=1 then
            conn:Disconnect()
            pulseConn:Disconnect()
            dotAnimConn:Disconnect()

            if stripFrame and stripFrame.Parent then
                stripFrame.Position=UDim2.fromOffset(endX,stripY)
            end

            if lastCentredCard and lastCentredCard~=cards[winnerSeqIdx] then
                setFrameColor(lastCentredCard,COL_NORMAL)
                setCardScale(lastCentredCard,SCALE_NORMAL_V,false)
            end
            lastCentredCard=cards[winnerSeqIdx]
            setFrameColor(lastCentredCard,COL_GREEN)
            setCardScale(lastCentredCard,SCALE_SELECTED,false)

            local s=cards[winnerSeqIdx]:FindFirstChildOfClass("UIScale")
            if s then
                TweenService:Create(s,
                    TweenInfo.new(0.25,Enum.EasingStyle.Back,Enum.EasingDirection.Out,1,true),
                    {Scale=SCALE_SELECTED+0.08}):Play()
            end

            _G._spinnerWinner = targetEntry

            StatusLbl.Text=PREFS.dialogText..targetEntry.name.."!  Click CLAIM!"
            StatusLbl.TextColor3=Color3.fromRGB(190,34,230)

            spinState="claim"
            SpinBtn.Text="CLAIM!"
            SpinBtn.TextColor3=Color3.fromRGB(255,255,255)
            TweenService:Create(SpinBtn,TweenInfo.new(0.2),
                {BackgroundColor3=Color3.fromRGB(30,80,50)}):Play()

            pcall(function()
                local cb = PlayerGui.DailyLoginApp.Frame.Body.Buttons.ClaimButton
                cb.Active = true; cb.AutoButtonColor = true
                cb.Face.TextLabel.Text = "CLAIM!"
            end)
        end
    end)
end

-- CONTROL PANEL (67.lua style)
local mainFrame = tabFrames["Spin"]
local controlGui = nil  -- no standalone ScreenGui needed

local blackFrame = mk("Frame", {Name="BlackFrame", BackgroundTransparency=1, Size=UDim2.new(0,1,0,1), Parent=mainFrame})  -- kept for spinner refs but invisible

-- Tab system (spinner's internal Spin/Prefs sub-tabs)
local tabFrames={}
local currentTab=""
local activeTabPulseTween=nil

local tabContainer = mk("Frame", {Size=UDim2.new(1,0,0,13), Position=UDim2.new(0,0,0,0), BackgroundTransparency=1, Parent=mainFrame})

local tabButtons={}
local tabDefs={{"Spin","✨"},{"Prefs","⚙️"}}

local function setActiveTab(tabName)
    if currentTab==tabName then return end
    if activeTabPulseTween then activeTabPulseTween:Cancel(); activeTabPulseTween=nil end
    currentTab=tabName
    for name,data in pairs(tabButtons) do
        local isActive=name==tabName
        TweenService:Create(data.button,TweenInfo.new(0.25,Enum.EasingStyle.Quint,Enum.EasingDirection.Out),{ BackgroundColor3=isActive and Color3.fromRGB(50,50,60) or Color3.fromRGB(40,40,50) }):Play()
        local targetColor=isActive and Color3.fromRGB(190,34,230) or Color3.fromRGB(80,80,80)
        TweenService:Create(data.stroke,TweenInfo.new(0.25,Enum.EasingStyle.Quint,Enum.EasingDirection.Out),{ Color=targetColor, Thickness=isActive and 1.0 or 0.7 }):Play()
        if isActive then
            local pulseInfo=TweenInfo.new(1.5,Enum.EasingStyle.Sine,Enum.EasingDirection.InOut,-1,true)
            activeTabPulseTween=TweenService:Create(data.stroke,pulseInfo,{ Color=targetColor:Lerp(Color3.fromRGB(255,255,255),0.25), Thickness=1.3 })
            activeTabPulseTween:Play()
        end
    end
    for name,frame in pairs(tabFrames) do frame.Visible=(name==tabName) end
end

for i,def in ipairs(tabDefs) do
    local tabName,icon=def[1],def[2]
    local tabButton = mk("TextButton", {Size=UDim2.new(1/#tabDefs-0.02,0,1,0), Position=UDim2.new((i-1)*(1/#tabDefs),0,0,0), BackgroundColor3=i==1 and Color3.fromRGB(50,50,60) or Color3.fromRGB(40,40,50), BackgroundTransparency=0.2, Text=icon.." "..tabName, Font=Enum.Font.FredokaOne, TextSize=6, TextColor3=Color3.fromRGB(255,255,255), Parent=tabContainer})
    Instance.new("UICorner",tabButton).CornerRadius=UDim.new(0,3)
    local tabStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=i==1 and Color3.fromRGB(190,34,230) or Color3.fromRGB(80,80,80), Thickness=i==1 and 1.0 or 0.7, Transparency=0.3, Parent=tabButton})
    tabButtons[tabName]={button=tabButton,stroke=tabStroke}
    local tabFrame = mk("Frame", {Size=UDim2.new(1,0,1,-15), Position=UDim2.new(0,0,0,15), BackgroundTransparency=1, Visible=i==1, Parent=mainFrame})
    tabFrames[tabName]=tabFrame
    tabButton.MouseButton1Click:Connect(function() setActiveTab(tabName) end)
end

local spinFrame=tabFrames["Spin"]

local petNameLbl = mk("TextLabel", {Size=UDim2.new(1,0,0,9), Position=UDim2.new(0,0,0,-2), BackgroundTransparency=1, Text="Pet Names (comma sep.)", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=spinFrame})

local htBtn = mk("TextButton", {Size=UDim2.new(0,50,0,9), Position=UDim2.new(1,-50,0,-2), BackgroundColor3=Color3.fromRGB(180,120,50), Text="👑 High Tiers", Font=Enum.Font.FredokaOne, TextSize=5, TextColor3=Color3.fromRGB(255,255,255), BorderSizePixel=0, Parent=spinFrame})
Instance.new("UICorner",htBtn).CornerRadius=UDim.new(0,3)

local NamesBox = mk("TextBox", {Size=UDim2.new(1,0,0,16), Position=UDim2.new(0,0,0,9), BackgroundColor3=Color3.fromRGB(40,40,50), Text="", PlaceholderText="e.g. Shadow Dragon, Bat Dragon", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255,255,255), PlaceholderColor3=Color3.fromRGB(110,110,135), ClearTextOnFocus=false, TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, ClipsDescendants=true, BorderSizePixel=0, Parent=spinFrame})
Instance.new("UICorner",NamesBox).CornerRadius=UDim.new(0,4)
do local s=Instance.new("UIStroke") s.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
s.Color=Color3.fromRGB(180,180,200) s.Thickness=1.5 s.Parent=NamesBox
local p=Instance.new("UIPadding") p.PaddingLeft=UDim.new(0,4) p.PaddingRight=UDim.new(0,4) p.Parent=NamesBox end

local targetLbl = mk("TextLabel", {Size=UDim2.new(1,0,0,9), Position=UDim2.new(0,0,0,27), BackgroundTransparency=1, Text="Target Pet (blank = random)", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=spinFrame})

local TargetBox = mk("TextBox", {Size=UDim2.new(1,0,0,16), Position=UDim2.new(0,0,0,37), BackgroundColor3=Color3.fromRGB(40,40,50), Text="", PlaceholderText="e.g. Shadow Dragon", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(255,255,255), PlaceholderColor3=Color3.fromRGB(110,110,135), ClearTextOnFocus=false, TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, ClipsDescendants=true, BorderSizePixel=0, Parent=spinFrame})
Instance.new("UICorner",TargetBox).CornerRadius=UDim.new(0,4)
do local s=Instance.new("UIStroke") s.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
s.Color=Color3.fromRGB(180,180,200) s.Thickness=1.5 s.Parent=TargetBox
local p=Instance.new("UIPadding") p.PaddingLeft=UDim.new(0,4) p.PaddingRight=UDim.new(0,4) p.Parent=TargetBox end

local rndBtn = mk("TextButton", {Size=UDim2.new(1,0,0,14), Position=UDim2.new(0,0,0,59), BackgroundColor3=Color3.fromRGB(40,40,50), BackgroundTransparency=0.2, Text="🎲 Random High Tier Target", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(220,220,255), BorderSizePixel=0, Parent=spinFrame})
Instance.new("UICorner",rndBtn).CornerRadius=UDim.new(0,3)
local rndStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(190,34,230), Thickness=1.0, Transparency=0.4, Parent=rndBtn})

local HighTierPetsRef={
    "Shadow Dragon","Bat Dragon","Frost Dragon","Giraffe","Blazing Lion",
    "African Wild Dog","Owl","Parrot","Crow","Evil Unicorn","Balloon Unicorn",
    "Dalmatian","Arctic Reindeer","Kangaroo","Turtle","Giant Panda","Hedgehog",
    "Cow","Chocolate Chip Bat Dragon","Flamingo","Peppermint Penguin",
    "Strawberry Shortcake Bat Dragon","Fairy Bat Dragon",
}
rndBtn.MouseButton1Click:Connect(function()
    local pick=HighTierPetsRef[math.random(1,#HighTierPetsRef)]
    TargetBox.Text=pick
    TweenService:Create(rndStroke,TweenInfo.new(0.1),{Color=Color3.fromRGB(60,220,110),Thickness=1.5,Transparency=0}):Play()
    task.delay(0.4,function()
        TweenService:Create(rndStroke,TweenInfo.new(0.3),{Color=Color3.fromRGB(190,34,230),Thickness=1.0,Transparency=0.4}):Play()
    end)
end)

StatusLbl=Instance.new("TextLabel")
StatusLbl.Size=UDim2.new(1,0,0,9)
StatusLbl.Position=UDim2.new(0,0,0,129)
StatusLbl.BackgroundTransparency=1
StatusLbl.Text="Ready."
StatusLbl.Font=Enum.Font.FredokaOne
StatusLbl.TextSize=7
StatusLbl.TextColor3=Color3.fromRGB(190,34,230)
StatusLbl.TextXAlignment=Enum.TextXAlignment.Left
StatusLbl.Parent=spinFrame

SpinBtn=Instance.new("TextButton")
SpinBtn.Size=UDim2.new(1,0,0,20)
SpinBtn.Position=UDim2.new(0,0,0,140)
SpinBtn.BackgroundColor3=Color3.fromRGB(30,80,50)
SpinBtn.BackgroundTransparency=0.1
SpinBtn.Text="✨ SPIN!"
SpinBtn.Font=Enum.Font.FredokaOne
SpinBtn.TextSize=9
SpinBtn.TextColor3=Color3.fromRGB(255,255,255)
SpinBtn.BorderSizePixel=0
SpinBtn.Parent=spinFrame
Instance.new("UICorner",SpinBtn).CornerRadius=UDim.new(0,5)
local spinStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(0,255,100), Thickness=1.5, Parent=SpinBtn})

SpinBtn.MouseEnter:Connect(function()
    if spinState=="idle" then
        TweenService:Create(SpinBtn,TweenInfo.new(0.12),{BackgroundColor3=Color3.fromRGB(40,110,65)}):Play()
    end
end)
SpinBtn.MouseLeave:Connect(function()
    if spinState=="idle" then
        TweenService:Create(SpinBtn,TweenInfo.new(0.12),{BackgroundColor3=Color3.fromRGB(30,80,50)}):Play()
    end
end)

local function triggerSpin()
    if spinState=="idle" then
        spinState="spinning"
        task.spawn(function()
            local target = TargetBox.Text:match("^%s*(.-)%s*$") or ""
            doSpin(splitCSV(NamesBox.Text), target)
        end)
    end
end

SpinBtn.MouseButton1Click:Connect(function()
    if spinState=="idle" then
        triggerSpin()
    elseif spinState=="claim" then
        spinState="idle"
        SpinBtn.Text="..."
        SpinBtn.BackgroundColor3=Color3.fromRGB(20,55,35)
        task.spawn(function()
            if type(setthreadidentity)=="function" then setthreadidentity(2)
            elseif type(syn)=="table" and syn.set_thread_identity then syn.set_thread_identity(2)
            elseif type(setthreadcontext)=="function" then setthreadcontext(2) end
            local winner=_G._spinnerWinner
            if not winner then StatusLbl.Text="Error: no winner!"; isBusy=false return end
            pcall(function() PlayerGui.DailyLoginApp.Enabled=false end)
            local appRef=UIManager and UIManager.apps and UIManager.apps.DailyLoginApp
            UIManager.apps.DialogApp:dialog({
                dialog_type="ItemPreviewDialog",
                text=PREFS.dialogText..winner.name.."!",
                button="Claim!",
                item={id=winner.id,kind=winner.id,category="pets",unique="spinner_"..winner.id,image=winner.image,
                    properties={flyable=activeMutations.fly==true,rideable=activeMutations.ride==true,
                        neon=activeMutations.neon==true,mega_neon=activeMutations.megaNeon==true}},
                yields=true,
            })
            pcall(function()
                local props={flyable=activeMutations.fly==true,rideable=activeMutations.ride==true,
                    neon=activeMutations.neon==true,mega_neon=activeMutations.megaNeon==true,
                    age=6,ailments_completed=0,rp_name="",pet_trick_level=0}
                addSpinPetToTrade(winner.id, props)
            end)
            if lastCentredCard then setFrameColor(lastCentredCard,COL_NORMAL); setCardScale(lastCentredCard,SCALE_NORMAL_V,true); lastCentredCard=nil end
            if appRef then destroyReel(appRef); closeApp(appRef) end
            StatusLbl.Text="Ready."
            StatusLbl.TextColor3=Color3.fromRGB(190,34,230)
            SpinBtn.Text="✨ SPIN!"
            TweenService:Create(SpinBtn,TweenInfo.new(0.15),{BackgroundColor3=Color3.fromRGB(30,80,50)}):Play()
            isBusy=false; _G._spinnerWinner=nil
            _G._autoSpinClaimDone = true  -- signal auto spin loop that claim fully finished
        end)
    end
end)

-- AUTO SPIN
_G._autoSpinEnabled  = false
_G._autoSpinPending  = 0     -- number of spins queued from last trade
_G._autoSpinTriggered = false

do -- autoSpin block
local autoSpinBtn = mk("TextButton", {Size=UDim2.new(1,0,0,14), Position=UDim2.new(0,0,0,164), BackgroundColor3=Color3.fromRGB(40,30,70), BackgroundTransparency=0.1, Text="AUTO SPIN: OFF", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(160,130,255), BorderSizePixel=0, Parent=spinFrame})
Instance.new("UICorner", autoSpinBtn).CornerRadius = UDim.new(0,5)
local autoSpinStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(130,80,255), Thickness=1.2, Transparency=0.3, Parent=autoSpinBtn})

autoSpinBtn.MouseButton1Click:Connect(function()
    _G._autoSpinEnabled = not _G._autoSpinEnabled
    if _G._autoSpinEnabled then
        autoSpinBtn.Text = "AUTO SPIN: ON"
        autoSpinBtn.TextColor3 = Color3.fromRGB(120,255,160)
        TweenService:Create(autoSpinBtn, TweenInfo.new(0.2), {BackgroundColor3=Color3.fromRGB(25,65,40)}):Play()
        TweenService:Create(autoSpinStroke, TweenInfo.new(0.2), {Color=Color3.fromRGB(60,220,100),Transparency=0.1}):Play()
    else
        autoSpinBtn.Text = "AUTO SPIN: OFF"
        autoSpinBtn.TextColor3 = Color3.fromRGB(160,130,255)
        TweenService:Create(autoSpinBtn, TweenInfo.new(0.2), {BackgroundColor3=Color3.fromRGB(40,30,70)}):Play()
        TweenService:Create(autoSpinStroke, TweenInfo.new(0.2), {Color=Color3.fromRGB(130,80,255),Transparency=0.3}):Play()
    end
end)

-- Max spins row: toggle + input
_G._maxSpinsEnabled = false
_G._maxSpinsValue   = 8

local maxSpinsRow = mk("Frame", {Size=UDim2.new(1,0,0,11), Position=UDim2.new(0,0,0,180), BackgroundTransparency=1, Parent=spinFrame})

local maxSpinsToggle = mk("TextButton", {Size=UDim2.new(0.55,-2,1,0), BackgroundColor3=Color3.fromRGB(40,30,70), BackgroundTransparency=0.1, Text="Max Spins: OFF", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(160,130,255), BorderSizePixel=0, Parent=maxSpinsRow})
Instance.new("UICorner", maxSpinsToggle).CornerRadius = UDim.new(0,3)
local maxSpinsToggleStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(130,80,255), Thickness=0.7, Transparency=0.4, Parent=maxSpinsToggle})

local maxSpinsBox = mk("TextBox", {Size=UDim2.new(0.45,-2,1,0), Position=UDim2.new(0.55,2,0,0), BackgroundColor3=Color3.fromRGB(40,40,55), BackgroundTransparency=0.2, Text="8", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(200,200,220), TextXAlignment=Enum.TextXAlignment.Center, ClearTextOnFocus=false, BorderSizePixel=0, Parent=maxSpinsRow})
Instance.new("UICorner", maxSpinsBox).CornerRadius = UDim.new(0,3)
local maxSpinsBoxStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=Color3.fromRGB(130,80,255), Thickness=0.7, Transparency=0.5, Parent=maxSpinsBox})

maxSpinsToggle.MouseButton1Click:Connect(function()
    _G._maxSpinsEnabled = not _G._maxSpinsEnabled
    if _G._maxSpinsEnabled then
        maxSpinsToggle.Text = "Max Spins: ON"
        maxSpinsToggle.TextColor3 = Color3.fromRGB(120,255,160)
        TweenService:Create(maxSpinsToggle, TweenInfo.new(0.15), {BackgroundColor3=Color3.fromRGB(25,65,40)}):Play()
        TweenService:Create(maxSpinsToggleStroke, TweenInfo.new(0.15), {Color=Color3.fromRGB(60,220,100),Transparency=0.1}):Play()
    else
        maxSpinsToggle.Text = "Max Spins: OFF"
        maxSpinsToggle.TextColor3 = Color3.fromRGB(160,130,255)
        TweenService:Create(maxSpinsToggle, TweenInfo.new(0.15), {BackgroundColor3=Color3.fromRGB(40,30,70)}):Play()
        TweenService:Create(maxSpinsToggleStroke, TweenInfo.new(0.15), {Color=Color3.fromRGB(130,80,255),Transparency=0.4}):Play()
    end
end)

maxSpinsBox.FocusLost:Connect(function()
    local n = tonumber(maxSpinsBox.Text)
    if n and n >= 1 then
        _G._maxSpinsValue = math.floor(n)
        maxSpinsBox.Text = tostring(_G._maxSpinsValue)
    else
        maxSpinsBox.Text = tostring(_G._maxSpinsValue)
    end
end)

-- Auto spin counter label (shows pending spins)
local autoSpinCountLbl = mk("TextLabel", {Size=UDim2.new(1,0,0,9), Position=UDim2.new(0,0,0,193), BackgroundTransparency=1, Text="Pending spins: 0", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(170, 140, 220), TextXAlignment=Enum.TextXAlignment.Left, Parent=spinFrame})

-- Watch for pending spins and auto-trigger
task.spawn(function()
    while true do
        task.wait(0.5)
        -- Update label
        local _pend = _G._autoSpinPending or 0
        if not _G._autoSpinTriggered then
            -- inner loop manages label when running
            local _status = ""
            if not _G._autoSpinEnabled then _status = " (off)"
            elseif _pend <= 0 then _status = " (done)"
            elseif _G._autoSpinWaitingForTrade then _status = " (waiting for retrade)"
            end
            autoSpinCountLbl.Text = "Pending: ".._pend.._status
        end

        if not _G._autoSpinEnabled then continue end
        if _pend <= 0 then continue end
        if _G._autoSpinTriggered then continue end
        if _G._autoSpinWaitingForTrade then continue end
        if spinState ~= "idle" then continue end

        _G._autoSpinTriggered = true

        task.spawn(function()
            local required = _G._autoSpinRequiredPets or 1

            while (_G._autoSpinPending or 0) > 0 do

                -- STEP 1: Wait for you to add ALL the pets they gave you back into the trade
                local needed = required
                autoSpinCountLbl.Text = "Pending: ".._G._autoSpinPending.." (add "..needed.." pet(s) to trade)"
                local w = 0
                while w < 300 do
                    task.wait(0.5); w = w + 0.5
                    local ts = mockState.trade
                    local items = ts and ts.sender_offer and ts.sender_offer.items
                    if items and #items >= needed then break end
                end
                do
                    local ts = mockState.trade
                    local items = ts and ts.sender_offer and ts.sender_offer.items
                    if not items or #items < needed then break end
                end

                -- 0.5s pause after pets added
                task.wait(0.5)

                -- STEP 2: Fire spin
                spinState = "idle"; isBusy = false
                _G._autoSpinClaimDone = false
                autoSpinCountLbl.Text = "Pending: ".._G._autoSpinPending.." (spinning...)"
                task.wait(0.2)

                -- snapshot my current item count before spin
                local myCountBefore = 0
                pcall(function()
                    local ts = mockState.trade
                    local items = ts and ts.sender_offer and ts.sender_offer.items
                    myCountBefore = items and #items or 0
                end)

                _G._autoSpinPending = _G._autoSpinPending - 1
                if HighTierPetsRef and #HighTierPetsRef > 0 then
                    TargetBox.Text = HighTierPetsRef[math.random(1, #HighTierPetsRef)]
                end
                triggerSpin()

                -- STEP 3: Wait for claim to complete
                -- Primary signal: _autoSpinClaimDone (set when isBusy goes false after dialog)
                -- Fallback signal: my item count increased (claimed pet auto-added to trade)
                autoSpinCountLbl.Text = "Pending: ".._G._autoSpinPending.." (claim the pet!)"
                w = 0
                while w < 120 do
                    task.wait(0.3); w = w + 0.3
                    if _G._autoSpinClaimDone then break end
                    -- fallback: pet was added to my offer = claim done
                    pcall(function()
                        local ts = mockState.trade
                        local items = ts and ts.sender_offer and ts.sender_offer.items
                        if items and #items > myCountBefore then
                            _G._autoSpinClaimDone = true
                        end
                    end)
                end
                spinState = "idle"; isBusy = false
                task.wait(0.3)
            end
            _G._autoSpinTriggered = false
            autoSpinCountLbl.Text = "Pending: 0"
        end)
    end
end)

end -- autoSpin do block
local HighTierPets={
    "Shadow Dragon","Bat Dragon","Frost Dragon","Giraffe","Owl","Parrot","Crow",
    "Evil Unicorn","Arctic Reindeer","Hedgehog","Dalmatian","Turtle","Kangaroo",
    "Lion","Elephant","Rhino","Chocolate Chip Bat Dragon","Cow","Blazing Lion",
    "African Wild Dog","Flamingo","Diamond Butterfly","Mini Pig","Caterpillar",
    "Albino Monkey","Candyfloss Chick","Pelican","Blue Dog","Pink Cat","Haetae",
    "Peppermint Penguin","Winged Tiger","Sugar Glider","Shark Puppy","Goat",
    "Sheeeeep","Lion Cub","Nessie","Frostbite Bear","Balloon Unicorn",
    "Honey Badger","Hot Doggo","Crocodile","Hare","Ram","Yeti","Meetkat",
    "Jellyfish","Happy Clown","Orchid Butterfly","Many Mackerel",
    "Strawberry Shortcake Bat Dragon","Zombie Buffalo","Fairy Bat Dragon",
    "Strawberry Penguin","Frost Unicorn","Papa Moose","Dango Penguins",
    "Monkey King","Cryptid","Diamond Amazon","Arctic Dusk Dragon",
    "Pirate Ghost Capuchin Monkey","Alpaca","Border Collie","Irish Water Spaniel",
    "Mermicorn","Mechapup","Giant Panda","Fallow Deer","Tortuga De La Isla",
    "Glacier Kitsune","Undead Jousting Horse","Jekyll Hydra","Field mouse",
    "Werewolf","Platypus","Snowball Pug","Diamond Hamster","Moose Calf",
    "Bush Elephant","Meerkat","Puffin","Ring-Tailed Lemur","Christmas Pudding Pup",
    "Goose","Cabbit","Unicorn","Pig","Grim Dragon","Frost Fury","Cupid Dragon",
    "Midnight Dragon","Brown Bear","Polar Bear","Groundhog","Dragonfruit Fox",
}

local htList = mk("Frame", {Size=UDim2.fromOffset(128,160)})
do -- htList/flags block
htList.BackgroundColor3=Color3.fromRGB(25,25,35)
htList.BorderSizePixel=0 htList.Visible=false htList.ZIndex=100
htList.Parent=Players.LocalPlayer.PlayerGui:WaitForChild("MockTradeControl")
htList.ClipsDescendants=false
Instance.new("UICorner",htList).CornerRadius=UDim.new(0,5)
local htStroke2 = mk("UIStroke", {Color=Color3.fromRGB(190,34,230)})
htStroke2.Thickness=1.5 htStroke2.Parent=htList

local htScroll=Instance.new("ScrollingFrame")
htScroll.Size=UDim2.new(1,-4,1,-4) htScroll.Position=UDim2.new(0,2,0,2)
htScroll.BackgroundTransparency=1 htScroll.BorderSizePixel=0
htScroll.ScrollBarThickness=3 htScroll.ScrollBarImageColor3=Color3.fromRGB(190,34,230)
htScroll.CanvasSize=UDim2.new(0,0,0,0) htScroll.AutomaticCanvasSize=Enum.AutomaticSize.Y
htScroll.ZIndex=101 htScroll.Parent=htList

local htLayout2 = mk("UIListLayout", {Padding=UDim.new(0,2)})
htLayout2.SortOrder=Enum.SortOrder.LayoutOrder htLayout2.Parent=htScroll
local htPad=Instance.new("UIPadding") htPad.PaddingTop=UDim.new(0,3) htPad.PaddingLeft=UDim.new(0,3)
htPad.PaddingRight=UDim.new(0,3) htPad.Parent=htScroll

local htAllBtn=Instance.new("TextButton")
htAllBtn.Size=UDim2.new(1,0,0,14) htAllBtn.LayoutOrder=0
htAllBtn.BackgroundColor3=Color3.fromRGB(180,120,50)
htAllBtn.Text="⚡ Add ALL" htAllBtn.Font=Enum.Font.FredokaOne htAllBtn.TextSize=7
htAllBtn.TextColor3=Color3.fromRGB(255,255,255) htAllBtn.BorderSizePixel=0
htAllBtn.ZIndex=102 htAllBtn.Parent=htScroll
Instance.new("UICorner",htAllBtn).CornerRadius=UDim.new(0,3)
htAllBtn.MouseButton1Click:Connect(function()
    NamesBox.Text=table.concat(HighTierPets,", ")
    htList.Visible=false
end)

for i,petName in ipairs(HighTierPets) do
    local btn=Instance.new("TextButton")
    btn.Size=UDim2.new(1,0,0,13) btn.LayoutOrder=i
    btn.BackgroundColor3=Color3.fromRGB(40,40,50)
    btn.BackgroundTransparency=0.2
    btn.Text=petName btn.Font=Enum.Font.FredokaOne btn.TextSize=7
    btn.TextColor3=Color3.fromRGB(255,255,255)
    btn.TextXAlignment=Enum.TextXAlignment.Left
    btn.BorderSizePixel=0 btn.ZIndex=102 btn.Parent=htScroll
    Instance.new("UICorner",btn).CornerRadius=UDim.new(0,3)
    local bp=Instance.new("UIPadding") bp.PaddingLeft=UDim.new(0,4) bp.Parent=btn
    btn.MouseButton1Click:Connect(function()
        local cur=NamesBox.Text:match("^%s*(.-)%s*$")
        NamesBox.Text=cur=="" and petName or cur..", "..petName
        htList.Visible=false
    end)
    btn.MouseEnter:Connect(function()
        TweenService:Create(btn,TweenInfo.new(0.1),{BackgroundColor3=Color3.fromRGB(55,55,70)}):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(btn,TweenInfo.new(0.1),{BackgroundColor3=Color3.fromRGB(40,40,50)}):Play()
    end)
end

local function updateHTListPos()
    local mf = _G._tradeGuiMainFrame
    if mf then
        local p = mf.AbsolutePosition
        local s = mf.AbsoluteSize
        htList.Position = UDim2.fromOffset(p.X + s.X + 6, p.Y)
    end
end
htBtn.MouseButton1Click:Connect(function()
    htList.Visible=not htList.Visible
    if htList.Visible then updateHTListPos() end
end)
UserInputService.InputBegan:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 and htList.Visible then
        local mp=i.Position; local ap=htList.AbsolutePosition; local as=htList.AbsoluteSize
        if not(mp.X>=ap.X and mp.X<=ap.X+as.X and mp.Y>=ap.Y and mp.Y<=ap.Y+as.Y) then
            htList.Visible=false
        end
    end
end)

-- FLAGS (on main Spin tab)
local activeMutations=activeMutations or {}
local activeFlags={M=false,N=false,F=false,R=false}

local flagsLbl = mk("TextLabel", {Size=UDim2.new(1,0,0,9), Position=UDim2.new(0,0,0,75), BackgroundTransparency=1, Text="Flags", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(190, 150, 255), TextXAlignment=Enum.TextXAlignment.Left, Parent=spinFrame})

local prefixDefs={
    {key="M",mutKey="megaNeon",label="M",col=Color3.fromRGB(170,0,255)},
    {key="N",mutKey="neon",    label="N",col=Color3.fromRGB(0,190,80)},
    {key="F",mutKey="fly",     label="F",col=Color3.fromRGB(0,175,255)},
    {key="R",mutKey="ride",    label="R",col=Color3.fromRGB(255,45,145)},
}
local prefBtns={}
local btnW=26; local btnH=18
local btnGap=math.floor((116-btnW*4)/3)

for i,pd in ipairs(prefixDefs) do
    local xOff=(i-1)*(btnW+btnGap)
    local pb = mk("TextButton", {Size=UDim2.new(0,btnW,0,btnH), Position=UDim2.new(0,xOff,0,89), BackgroundColor3=Color3.fromRGB(22,22,34)})
    pb.Text=pd.label pb.Font=Enum.Font.GothamBold pb.TextSize=10
    pb.TextColor3=Color3.fromRGB(220,220,220)
    pb.BorderSizePixel=0 pb.Parent=spinFrame
    Instance.new("UICorner",pb).CornerRadius=UDim.new(0,4)
    local s = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border})
    s.Color=pd.col s.Thickness=1.5 s.Transparency=0.35 s.Parent=pb
    local ts = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Contextual})
    ts.Color=Color3.new(0,0,0) ts.Thickness=0.8 ts.Transparency=0.5 ts.Parent=pb
    prefBtns[pd.key]={btn=pb,stroke=s,textStroke=ts,col=pd.col,mutKey=pd.mutKey}
    pb.MouseButton1Click:Connect(function()
        if pd.key=="M" and activeFlags["N"] then return end
        if pd.key=="N" and activeFlags["M"] then return end
        activeFlags[pd.key]=not activeFlags[pd.key]
        activeMutations[pd.mutKey]=activeFlags[pd.key] or nil
        if activeFlags[pd.key] then
            TweenService:Create(pb,TweenInfo.new(0.15,Enum.EasingStyle.Quint),{BackgroundColor3=Color3.fromRGB(75,75,85)}):Play()
            TweenService:Create(s,TweenInfo.new(0.15),{Color=Color3.fromRGB(60,220,110),Thickness=1.8,Transparency=0}):Play()
        else
            TweenService:Create(pb,TweenInfo.new(0.15,Enum.EasingStyle.Quint),{BackgroundColor3=Color3.fromRGB(22,22,34)}):Play()
            TweenService:Create(s,TweenInfo.new(0.15),{Color=pd.col,Thickness=1.5,Transparency=0.35}):Play()
        end
        updateInfoBox()
    end)
end

local infoBox = mk("Frame", {Size=UDim2.new(1,0,0,14), Position=UDim2.new(0,0,0,113), BackgroundColor3=Color3.fromRGB(0,0,0), BackgroundTransparency=0.42, Parent=spinFrame})
Instance.new("UICorner",infoBox).CornerRadius=UDim.new(0,5)
local ibS=Instance.new("UIStroke")
ibS.Color=Color3.fromRGB(200,200,210) ibS.Thickness=1.2 ibS.Transparency=0.6 ibS.Parent=infoBox
local ibLayout = mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, HorizontalAlignment=Enum.HorizontalAlignment.Center, VerticalAlignment=Enum.VerticalAlignment.Center})
ibLayout.Padding=UDim.new(0,4) ibLayout.Parent=infoBox

local flagCols={M=Color3.fromRGB(170,0,255),N=Color3.fromRGB(0,190,80),F=Color3.fromRGB(0,175,255),R=Color3.fromRGB(255,45,145)}

function updateInfoBox()
    for _,ch in ipairs(infoBox:GetChildren()) do if ch:IsA("TextLabel") then ch:Destroy() end end
    local cols,hasAny={},false
    for _,k in ipairs({"M","N","F","R"}) do
        if activeFlags[k] then
            hasAny=true; table.insert(cols,flagCols[k])
            local lbl=Instance.new("TextLabel")
            lbl.Size=UDim2.new(0,0,1,0) lbl.AutomaticSize=Enum.AutomaticSize.X
            lbl.BackgroundTransparency=1
            lbl.Text=k=="M" and "Mega Neon" or k=="N" and "Neon" or k=="F" and "Fly" or "Ride"
            lbl.Font=Enum.Font.FredokaOne lbl.TextSize=9
            lbl.TextColor3=flagCols[k]
            lbl.TextXAlignment=Enum.TextXAlignment.Center lbl.TextYAlignment=Enum.TextYAlignment.Center
            lbl.Parent=infoBox
        end
    end
    if not hasAny then
        local lbl=Instance.new("TextLabel")
        lbl.Size=UDim2.new(0,0,1,0) lbl.AutomaticSize=Enum.AutomaticSize.X
        lbl.BackgroundTransparency=1 lbl.Text="Normal"
        lbl.Font=Enum.Font.FredokaOne lbl.TextSize=9
        lbl.TextColor3=Color3.fromRGB(255,255,255)
        lbl.TextXAlignment=Enum.TextXAlignment.Center lbl.TextYAlignment=Enum.TextYAlignment.Center
        lbl.Parent=infoBox
        TweenService:Create(ibS,TweenInfo.new(0.2),{Color=Color3.fromRGB(200,200,210),Thickness=1.2,Transparency=0.5}):Play()
    else
        local r,g,b=0,0,0
        for _,c in ipairs(cols) do r=r+c.R; g=g+c.G; b=b+c.B end
        TweenService:Create(ibS,TweenInfo.new(0.2),{Color=Color3.new(math.min(r/#cols,1),math.min(g/#cols,1),math.min(b/#cols,1)),Thickness=1.5,Transparency=0.2}):Play()
    end
end
updateInfoBox()
end -- htList do block

do -- prefsFrame block
local prefsFrame=tabFrames["Prefs"]

local pulsationTweens={}
local function makePrefRow(parent, labelText, defaultVal, y)
    local lbl=Instance.new("TextLabel")
    lbl.Size=UDim2.new(1,0,0,8) lbl.Position=UDim2.new(0,0,0,y)
    lbl.BackgroundTransparency=1 lbl.Text=labelText
    lbl.Font=Enum.Font.FredokaOne lbl.TextSize=8
    lbl.TextColor3=Color3.fromRGB(180,180,180)
    lbl.TextXAlignment=Enum.TextXAlignment.Left lbl.Parent=parent

    local box=Instance.new("TextBox")
    box.Size=UDim2.new(1,0,0,14) box.Position=UDim2.new(0,0,0,y+9)
    box.BackgroundColor3=Color3.fromRGB(40,40,50)
    box.BackgroundTransparency=0.2
    box.Text=defaultVal
    box.Font=Enum.Font.FredokaOne lbl.TextSize=8
    box.TextSize=7 box.TextColor3=Color3.fromRGB(255,255,255)
    box.ClearTextOnFocus=false
    box.TextXAlignment=Enum.TextXAlignment.Left
    box.TextTruncate=Enum.TextTruncate.AtEnd
    box.ClipsDescendants=true
    box.BorderSizePixel=0 box.Parent=parent
    Instance.new("UICorner",box).CornerRadius=UDim.new(0,3)
    local pad=Instance.new("UIPadding") pad.PaddingLeft=UDim.new(0,4) pad.Parent=box
    local s = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border})
    s.Color=Color3.fromRGB(80,80,80) s.Thickness=0.7 s.Transparency=0.5 s.Parent=box
    box.Focused:Connect(function()
        if pulsationTweens[box] then pulsationTweens[box]:Cancel() end
        pulsationTweens[box]=TweenService:Create(s,TweenInfo.new(0.8,Enum.EasingStyle.Sine,Enum.EasingDirection.InOut,-1,true),{ Color=Color3.fromRGB(190,34,230), Thickness=1.2, Transparency=0.2 })
        pulsationTweens[box]:Play()
    end)
    box.FocusLost:Connect(function()
        if pulsationTweens[box] then pulsationTweens[box]:Cancel(); pulsationTweens[box]=nil end
        TweenService:Create(s,TweenInfo.new(0.3,Enum.EasingStyle.Quad),{ Color=Color3.fromRGB(80,80,80), Thickness=0.7, Transparency=0.5 }):Play()
    end)
    return box
end

local taglineBox  = makePrefRow(prefsFrame, "Tagline text",   PREFS.tagline,    0)
local spinTxtBox  = makePrefRow(prefsFrame, "Spinning text",  PREFS.spinText,  25)
local dialogTxtBox= makePrefRow(prefsFrame, "Dialog prefix",  PREFS.dialogText,50)

taglineBox.FocusLost:Connect(function()
    if taglineBox.Text~="" then PREFS.tagline=taglineBox.Text end
end)
spinTxtBox.FocusLost:Connect(function()
    if spinTxtBox.Text~="" then PREFS.spinText=spinTxtBox.Text end
end)
dialogTxtBox.FocusLost:Connect(function()
    PREFS.dialogText=dialogTxtBox.Text
end)

local function makeToggleRow(parent, y, labelText, initVal, onChange)
    local row=Instance.new("Frame")
    row.Size=UDim2.new(1,0,0,13) row.Position=UDim2.new(0,0,0,y)
    row.BackgroundTransparency=1 row.Parent=parent
    local lbl=Instance.new("TextLabel")
    lbl.Size=UDim2.new(0.675,0,1,0) lbl.BackgroundTransparency=1
    lbl.Text=labelText lbl.Font=Enum.Font.FredokaOne lbl.TextSize=8
    lbl.TextColor3=Color3.fromRGB(180,180,180)
    lbl.TextXAlignment=Enum.TextXAlignment.Left lbl.Parent=row
    local btn=Instance.new("TextButton")
    btn.Size=UDim2.new(0.315,0,1,0) btn.Position=UDim2.new(0.685,0,0,0)
    btn.BackgroundColor3=initVal and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)
    btn.BackgroundTransparency=0.2
    btn.Text=initVal and "ON" or "OFF"
    btn.Font=Enum.Font.FredokaOne btn.TextSize=7
    btn.TextColor3=initVal and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
    btn.BorderSizePixel=0 btn.Parent=row
    Instance.new("UICorner",btn).CornerRadius=UDim.new(0,3)
    local bStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border, Color=initVal and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)})
    bStroke.Thickness=0.7 bStroke.Transparency=0.3 bStroke.Parent=btn
    local state=initVal
    btn.MouseButton1Click:Connect(function()
        state=not state
        btn.Text=state and "ON" or "OFF"
        btn.TextColor3=state and Color3.fromRGB(80,255,130) or Color3.fromRGB(255,90,90)
        TweenService:Create(btn,TweenInfo.new(0.2),
            {BackgroundColor3=state and Color3.fromRGB(30,80,50) or Color3.fromRGB(80,30,30)}):Play()
        TweenService:Create(bStroke,TweenInfo.new(0.2),
            {Color=state and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,60,60)}):Play()
        onChange(state)
    end)
end

makeToggleRow(prefsFrame, 76, "Notebook Spiral", PREFS.showNotebookSpiral, function(val)
    PREFS.showNotebookSpiral=val
    pcall(function()
        PlayerGui.DailyLoginApp.Frame.Header.NotebookSpiral.Visible=val
    end)
end)

makeToggleRow(prefsFrame, 92, "Show Eggs in Spin", PREFS.showEggs, function(val)
    PREFS.showEggs=val
end)

makeToggleRow(prefsFrame, 108, "Random Filler Kinds", PREFS.randomKinds, function(val)
    PREFS.randomKinds=val
end)

local spinnerBpBtn = nil
makeToggleRow(prefsFrame, 124, "Spin Backpack Button", false, function(val)
    if val then
        task.spawn(function()
            local toolApp, hotbar, openBackpack
            for _=1,20 do
                toolApp = PlayerGui:FindFirstChild("ToolApp", true)
                hotbar = toolApp and toolApp:FindFirstChild("Hotbar", true)
                openBackpack = hotbar and hotbar:FindFirstChild("OpenBackpack", true)
                if openBackpack then break end
                task.wait(0.2)
            end
            if not openBackpack then return end

            local rPos = openBackpack.AbsolutePosition
            local rSz  = openBackpack.AbsoluteSize
            local sz   = math.floor(rSz.X * 0.85)

            spinnerBpBtn = openBackpack:Clone()
            spinnerBpBtn.Name     = "SpinnerOpenBackpack"; spinnerBpBtn.Size     = UDim2.fromOffset(sz, sz)
            spinnerBpBtn.Position = UDim2.fromOffset(rPos.X - sz - 10, rPos.Y + (rSz.Y-sz)/2); spinnerBpBtn.ZIndex   = 20

            pcall(function()
                local CTM = fsysLoad("ColorThemeManager")
                CTM.exclude_instance_from_color_themeing(spinnerBpBtn)
                for _,v in ipairs(spinnerBpBtn:GetDescendants()) do
                    CTM.exclude_instance_from_color_themeing(v)
                end
            end)

            local GREEN = Color3.fromRGB(55, 185, 65)
            local innerColor = spinnerBpBtn:FindFirstChild("InnerColor")
            if innerColor then
                innerColor.ImageColor3 = GREEN
                innerColor:GetPropertyChangedSignal("ImageColor3"):Connect(function()
                    if innerColor.ImageColor3 ~= GREEN then
                        innerColor.ImageColor3 = GREEN
                    end
                end)
            end

            spinnerBpBtn.Parent = hotbar

            -- Find the clickable button inside and hook it
            local _bpDebounce = false
            local function hookClicks(root)
                for _, c in ipairs(root:GetDescendants()) do
                    if c:IsA("ImageButton") or c:IsA("TextButton") then
                        c.MouseButton1Click:Connect(function()
                            if spinState ~= "idle" then return end
                            if _bpDebounce then return end
                            _bpDebounce = true
                            task.spawn(openSpinnerPicker)
                            task.delay(1, function() _bpDebounce = false end)
                        end)
                    end
                end
                if root:IsA("ImageButton") or root:IsA("TextButton") then
                    root.MouseButton1Click:Connect(function()
                        if spinState ~= "idle" then return end
                        if _bpDebounce then return end
                        _bpDebounce = true
                        task.spawn(openSpinnerPicker)
                        task.delay(1, function() _bpDebounce = false end)
                    end)
                end
            end
            hookClicks(spinnerBpBtn)

            task.spawn(function()
                while spinnerBpBtn and spinnerBpBtn.Parent do
                    local op = openBackpack.AbsolutePosition
                    local os = openBackpack.AbsoluteSize
                    spinnerBpBtn.Position = UDim2.fromOffset(op.X - sz - 10, op.Y + (os.Y-sz)/2)
                    task.wait(0.5)
                end
            end)
        end)
    else
        if spinnerBpBtn then spinnerBpBtn:Destroy(); spinnerBpBtn=nil end
    end
end)

local selectedPetUnique = nil
local selectedPetName = "None"

local selectLbl=Instance.new("TextLabel")
selectLbl.Size=UDim2.new(1,0,0,8) selectLbl.Position=UDim2.new(0,0,0,156)
selectLbl.BackgroundTransparency=1 selectLbl.Text="🐾 Boost Pet"
selectLbl.Font=Enum.Font.FredokaOne selectLbl.TextSize=8
selectLbl.TextColor3=Color3.fromRGB(180,180,180)
selectLbl.TextXAlignment=Enum.TextXAlignment.Left selectLbl.Parent=prefsFrame

local selectedLbl=Instance.new("TextLabel")
selectedLbl.Size=UDim2.new(1,0,0,8) selectedLbl.Position=UDim2.new(0,0,0,165)
selectedLbl.BackgroundTransparency=1 selectedLbl.Text="Selected: None"
selectedLbl.Font=Enum.Font.FredokaOne selectedLbl.TextSize=8
selectedLbl.TextColor3=Color3.fromRGB(120,180,255)
selectedLbl.TextXAlignment=Enum.TextXAlignment.Left selectedLbl.Parent=prefsFrame

selectBtn=Instance.new("TextButton")
selectBtn.Size=UDim2.new(1,0,0,14) selectBtn.Position=UDim2.new(0,0,0,175)
selectBtn.BackgroundColor3=Color3.fromRGB(40,40,50)
selectBtn.BackgroundTransparency=0.2
selectBtn.Text="Select Pet..."
selectBtn.Font=Enum.Font.FredokaOne selectBtn.TextSize=7
selectBtn.TextColor3=Color3.fromRGB(200,210,255)
selectBtn.BorderSizePixel=0 selectBtn.Parent=prefsFrame
Instance.new("UICorner",selectBtn).CornerRadius=UDim.new(0,3)
local selStroke = mk("UIStroke", {ApplyStrokeMode=Enum.ApplyStrokeMode.Border})
selStroke.Color=Color3.fromRGB(190,34,230) selStroke.Thickness=0.8
selStroke.Transparency=0.4 selStroke.Parent=selectBtn

local _pickerBody = function()
    pcall(function()
        local BackpackApp = UIManager and UIManager.apps and UIManager.apps.BackpackApp
        if BackpackApp and BackpackApp:is_picking_item() then
            BackpackApp:try_pick_item(nil)
            task.wait(0.1)
        end
        -- so pick_item starts from a clean state (no add button visible)
        if BackpackApp and UIManager.is_visible("BackpackApp") then
            UIManager.set_app_visibility("BackpackApp", false)
            task.wait(0.05)
        end
    end)
    task.spawn(function()
        pcall(function()
            if type(setthreadidentity)=="function" then setthreadidentity(2) end
            local BackpackApp = UIManager and UIManager.apps and UIManager.apps.BackpackApp
            if not BackpackApp then return end

            local frame = BackpackApp.instance.Frame
            local body = frame:FindFirstChild("Body")
            local cats = body and body:FindFirstChild("Categories")
            local scrollComplex = body and body:FindFirstChild("ScrollComplex")

            local origCatsVisible  = cats and cats.Visible
            local origScrollSize   = scrollComplex and scrollComplex.Size
            local origScrollPos    = scrollComplex and scrollComplex.Position

            if cats then cats.Visible=false end

            local scrollComplex = body and body:FindFirstChild("ScrollComplex")
            local origScrollSize = scrollComplex and scrollComplex.Size
            local origScrollPos  = scrollComplex and scrollComplex.Position
            if scrollComplex then
                scrollComplex.Size     = UDim2.new(1, 0, scrollComplex.Size.Y.Scale, scrollComplex.Size.Y.Offset)
                scrollComplex.Position = UDim2.new(0, 0, scrollComplex.Position.Y.Scale, scrollComplex.Position.Y.Offset)
            end

            -- Hook BackpackItemGrid to use more cells per row and smaller size
            local BackpackItemGrid = pcall(fsysLoad, "BackpackItemGrid") and fsysLoad("BackpackItemGrid")
            local origStart      = BackpackItemGrid and BackpackItemGrid.start
            local origCreateCell = BackpackItemGrid and BackpackItemGrid._create_cell
            local origRenderRow  = BackpackItemGrid and BackpackItemGrid.render_row
            if BackpackItemGrid then
                BackpackItemGrid.start = function(self, app)
                    self.backpack_app = app
                    local VerticalGrid = fsysLoad("VerticalGrid")
                    VerticalGrid.start(self, app.scroll, app.content, { row_height    = 76, cells_per_row = 6, padding       = 0, })
                    return self
                end
                BackpackItemGrid._create_cell = function(self, col, order, data)
                    if data.type == "add_item" or data.type == "add_more" then
                        local dummy = mk("Frame", {Size=UDim2.fromOffset(0,0), BackgroundTransparency=1, LayoutOrder=order})
                        return dummy
                    end
                    local btn = self.backpack_app.button_creator[data.type](self.backpack_app.button_creator, data)
                    btn.Size        = UDim2.fromOffset(76, 76); btn.Position    = UDim2.fromOffset((col-1)*76, 0)
                    btn.LayoutOrder = order
                    return btn
                end
                BackpackItemGrid.render_row = function(self, rowIdx, cells)
                    local row = mk("Frame", {Name="Row"..rowIdx, BackgroundTransparency=1, Size=UDim2.new(1, 0, 0, 76)})
                    local base = rowIdx * 6
                    for i, data in ipairs(cells) do
                        self:_create_cell(i, base+i, data).Parent = row
                    end
                    return row
                end
            end

            local destroyedAddBtns = {}
            pcall(function()
                for _,v in ipairs(frame:GetDescendants()) do
                    local n = v.Name:lower()
                    if v:IsA("GuiObject") and (n == "addbutton" or n == "additem" or n:find("^add")) then
                        table.insert(destroyedAddBtns, {inst=v, parent=v.Parent, nextSibling=nil})
                        v.Parent = nil  -- detach without destroying so we can restore
                    end
                end
            end)
            local addBtn = scrollComplex and scrollComplex:FindFirstChild("AddButton", true)
            local origAddVis = addBtn and addBtn.Visible
            if addBtn then addBtn.Visible = false end

            local picked = BackpackApp:pick_item({
                visible_backpack_categories = {"pets"},
                keep_cached_scroll_positions_on_open = false,
                allow_callback = function(item)
                    return item.category == "pets"
                end,
            })

            if cats then cats.Visible = origCatsVisible end
            if scrollComplex and origScrollSize then
                scrollComplex.Size     = origScrollSize
                scrollComplex.Position = origScrollPos
            end
            if BackpackItemGrid and origStart then
                BackpackItemGrid.start       = origStart; BackpackItemGrid._create_cell = origCreateCell
                BackpackItemGrid.render_row  = origRenderRow
            end
            if addBtn then addBtn.Visible = origAddVis end
            for _,entry in ipairs(destroyedAddBtns) do
                pcall(function() entry.inst.Parent = entry.parent end)
            end
            pcall(function() BackpackApp:refresh_rendered_items() end)

            if picked then
                selectedPetUnique = picked.unique
                local IDB = fsysLoad("InventoryDB")
                local entry = IDB and IDB.pets and IDB.pets[picked.id]
                selectedPetName = (entry and entry.name) or picked.id
                selectedLbl.Text = "Selected: "..selectedPetName
                TweenService:Create(selStroke,TweenInfo.new(0.2),{Color=Color3.fromRGB(60,220,110),Thickness=1.5,Transparency=0}):Play()
                task.delay(1, function()
                    TweenService:Create(selStroke,TweenInfo.new(0.3),{Color=Color3.fromRGB(190,34,230),Thickness=0.8,Transparency=0.4}):Play()
                end)
                selectBtn.Text = selectedPetName

                local confirmed = false
                pcall(function()
                    local result = UIManager.apps.DialogApp:dialog({
                        dialog_type  = "ScrollingDialog",
                        use_stacks   = false,
                        items        = { picked },
                        labels       = {
                            { text    = "⚠️ You will NOT lose this pet!", size    = 34, padding = 20, },
                            { text    = "Your pet stays safe in your inventory and will not be affected. Ready to proceed?", size    = 22, padding = 16, },
                        },
                        left         = "Cancel",
                        right        = "Let's Spin!",
                        accept_delay = 2,
                        exit_button  = true,
                    })
                    confirmed = (result == "Yes" or result == "Let's Spin!")
                end)

                if not confirmed then
                    selectedPetUnique = nil
                    selectedPetName   = "None"
                    selectedLbl.Text  = "Selected: None"
                    selectBtn.Text    = "Select Pet..."
                    return
                end

                if spinState == "idle" then
                    spinState = "spinning"
                    task.spawn(function()
                        local target = TargetBox.Text:match("^%s*(.-)%s*$") or ""
                        doSpin(splitCSV(NamesBox.Text), target)
                    end)
                end
            end
        end)
    end)
end
_spinnerPickerFn = _pickerBody
selectBtn.MouseButton1Click:Connect(_pickerBody)

local prefNote=Instance.new("TextLabel")
prefNote.Size=UDim2.new(1,0,0,16) prefNote.Position=UDim2.new(0,0,0,194)
prefNote.BackgroundTransparency=1
prefNote.Text="Text changes apply next spin."
prefNote.Font=Enum.Font.FredokaOne prefNote.TextSize=7
prefNote.TextColor3=Color3.fromRGB(120,120,150)
prefNote.TextXAlignment=Enum.TextXAlignment.Left
prefNote.TextWrapped=true prefNote.Parent=prefsFrame

-- Permanently hide extra buttons and expand ClaimButton whenever app is visible
task.spawn(function()
    local app
    repeat task.wait(0.1) 
        if UIManager then
            local ok,a = pcall(function() return UIManager.apps.DailyLoginApp end)
            if ok and a then app = a end
        end
    until app

    -- Hook claim_depth_button.set_state so it ALWAYS stays "normal" (green)
    -- The real DailyLoginApp calls set_state("cancel") when not claimable — we block that
    task.spawn(function()
        -- Wait for claim_depth_button to be assigned (it's set in app:start())
        local deadline = tick() + 10
        while not app.claim_depth_button and tick() < deadline do task.wait(0.1) end
        pcall(function()
            local db = app.claim_depth_button
            if db and db.set_state then
                local _orig = db.set_state
                db.set_state = function(self, state)
                    -- Block "cancel" (red) — always use "normal" (green)
                    return _orig(self, "normal")
                end
                pcall(function() db:set_state("normal") end)
            end
        end)
    end)
    local function fixButtons()
        pcall(function()
            local buttons = PlayerGui.DailyLoginApp.Frame.Body.Buttons
            local layout = buttons:FindFirstChildOfClass("UIListLayout")
            if layout then layout:Destroy() end
            local claimAd = buttons:FindFirstChild("ClaimAdButton")
            local milestones = buttons:FindFirstChild("MilestonesButton")
            if claimAd then claimAd:Destroy() end
            if milestones then milestones:Destroy() end
            local h = buttons.AbsoluteSize.Y > 0 and buttons.AbsoluteSize.Y or 48
            buttons.Size = UDim2.new(1, -60, 0, h)
            pcall(function()
                local tagline = PlayerGui.DailyLoginApp.Frame.Body.TaglineArea.Tagline
                tagline.Text = PREFS.tagline
            end)
            pcall(function()
            end)
            local claimBtn = buttons:FindFirstChild("ClaimButton")
            if claimBtn then
                claimBtn.Size        = UDim2.new(1, 0, 1, 0); claimBtn.Position    = UDim2.new(0, 0, 0.5, 0)
                claimBtn.AnchorPoint = Vector2.new(0, 0.5)
                -- Green is handled by the claim_depth_button.set_state hook above
                claimBtn.MouseButton1Click:Connect(function()
                    if spinState ~= "claim" then return end
                    if not _G._spinnerWinner then return end
                    spinState = "idle"

                    PlayerGui.DailyLoginApp.Enabled = false

                    task.spawn(function()
                        if type(setthreadidentity)=="function" then setthreadidentity(2)
                        elseif type(syn)=="table" and syn.set_thread_identity then syn.set_thread_identity(2)
                        elseif type(setthreadcontext)=="function" then setthreadcontext(2) end

                        local winner = _G._spinnerWinner
                        local dialogApp = UIManager.apps.DialogApp
                        dialogApp:dialog({
                            dialog_type = "ItemPreviewDialog",
                            text        = PREFS.dialogText..winner.name.."!",
                            button      = "Claim!",
                            item        = {
                                id         = winner.id,
                                kind       = winner.id,
                                category   = "pets",
                                unique     = "spinner_"..winner.id,
                                image      = winner.image,
                                properties = { flyable   = activeMutations.fly      == true, rideable  = activeMutations.ride     == true, neon      = activeMutations.neon     == true, mega_neon = activeMutations.megaNeon == true, }
                            },
                            yields = true,
                        })

                        pcall(function()
                            local props = {
                                flyable           = activeMutations.fly      == true,
                                rideable          = activeMutations.ride     == true,
                                neon              = activeMutations.neon     == true,
                                mega_neon         = activeMutations.megaNeon == true,
                                age               = 6,
                                ailments_completed = 0,
                                rp_name           = "",
                                pet_trick_level   = 0,
                            }
                            addSpinPetToTrade(winner.id, props)
                        end)
                        if lastCentredCard then
                            setFrameColor(lastCentredCard,COL_NORMAL)
                            setCardScale(lastCentredCard,SCALE_NORMAL_V,true)
                            lastCentredCard=nil
                        end
                        local appRef = UIManager and UIManager.apps and UIManager.apps.DailyLoginApp
                        if appRef then destroyReel(appRef); closeApp(appRef) end
                        StatusLbl.Text="Ready."
                        StatusLbl.TextColor3=Color3.fromRGB(190,34,230)
                        SpinBtn.Text="SPIN!"
                        TweenService:Create(SpinBtn,TweenInfo.new(0.15),{BackgroundColor3=Color3.fromRGB(30,80,50)}):Play()
                        isBusy=false
                        _G._spinnerWinner=nil
                    end)
                end)
            end
        end)
    end
    fixButtons()
    app.instance.Frame:GetPropertyChangedSignal("Visible"):Connect(function()
        if app.instance.Frame.Visible then
            task.wait(0.05) fixButtons()
            task.wait(0.1)  fixButtons()
            task.wait(0.2)  fixButtons()
        end
    end)
    pcall(function()
        local claimBtn = PlayerGui.DailyLoginApp.Frame.Body.Buttons.ClaimButton
        claimBtn:GetPropertyChangedSignal("Size"):Connect(function()
            task.wait(0.05)
            fixButtons()
        end)
    end)
end)

end -- prefsFrame do block
end -- SPIN TAB do block

local dragging, dragStart, startPos
mainFrame.InputBegan:Connect(function(input)
    if _G._guiLocked then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging  = true
        dragStart = input.Position
        startPos  = mainFrame.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and not _G._guiLocked and (input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        mainFrame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
        blackFrame.Position = UDim2.new(
            mainFrame.Position.X.Scale, mainFrame.Position.X.Offset - 3,
            mainFrame.Position.Y.Scale, mainFrame.Position.Y.Offset - 3
        )
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

-- =====================================================================
-- POP-OUT RICH LEADERBOARD  (server players ranked by AMVGG profile value)
-- Self-contained: all locals live inside the function scope (no main-chunk
-- register cost). Reads shared helpers/refs from _G.
-- =====================================================================
do
_G._openRichBoard = function()
    local main = _G._tradeGuiMainFrame
    local gui  = _G._controlGui
    if not (main and gui) then return end
    -- toggle off if already open
    if _G._richBoard and _G._richBoard.Parent then
        _G._richBoard:Destroy(); _G._richBoard = nil
        _G._richBoardRefresh = nil; _G._richBoardAddPlayer = nil; _G._richBoardRemovePlayer = nil
        return
    end

    local Players          = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local InventoryDB       = load("InventoryDB")
    local RouterClient      = load("RouterClient")
    local UIManager         = load("UIManager")

    local function new(cls, props, parent)
        local o = Instance.new(cls)
        for k, v in pairs(props) do o[k] = v end
        o.Parent = parent
        return o
    end
    local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 3) }, o) end

    -- Snapshot the main GUI size/position at click time; place beside it.
    -- Build at the main GUI's LOGICAL (unscaled) size, then a UIScale grows the whole board —
    -- frame AND content — by the same factor as the main GUI, so it stays proportional on resize.
    local sz, pos = main.AbsoluteSize, main.AbsolutePosition
    local scale = _G._guiScale or 1
    local W, H = math.floor(sz.X / scale), math.floor(sz.Y / scale)
    local cam = workspace.CurrentCamera
    local screenW = (cam and cam.ViewportSize.X) or 1000
    local bx = pos.X + sz.X + 12                       -- placement uses real (scaled) screen pixels
    if bx + sz.X > screenW then bx = pos.X - sz.X - 12 end
    if bx < 0 then bx = math.max(pos.X + sz.X + 12, 0) end

    -- Shadow frame (exact clone of the main GUI's BlackFrame: 3px larger, black, corner 7)
    local shadow = new("Frame", {
        Name = "RichLeaderboard", Size = UDim2.fromOffset(W + 6, H + 6),
        Position = UDim2.fromOffset(bx - 3, pos.Y - 3),
        BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, ZIndex = 49,
    }, gui)
    _G._richBoard = shadow
    if _G._registerScaledGui then _G._registerScaledGui(shadow) end  -- scale with the main GUI
    corner(shadow, 7)

    -- Main board (matches mainFrame: RGB 30,30,40, corner 5, purple border stroke)
    local board = new("Frame", {
        Name = "Board", Size = UDim2.fromOffset(W, H), Position = UDim2.fromOffset(3, 3),
        BackgroundColor3 = Color3.fromRGB(30, 30, 40), BorderSizePixel = 0, ZIndex = 50,
    }, shadow)
    corner(board, 5)
    new("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = Color3.fromRGB(190, 34, 230), Thickness = 1.5 }, board)

    -- Title bar (draggable)
    local title = new("Frame", {
        Size = UDim2.new(1, 0, 0, 18), BackgroundColor3 = Color3.fromRGB(46, 30, 62),
        BorderSizePixel = 0, ZIndex = 51,
    }, board)
    corner(title, 5)
    new("TextLabel", {
        Size = UDim2.new(1, -24, 1, 0), Position = UDim2.new(0, 6, 0, 0), BackgroundTransparency = 1,
        Text = "🏆 Rich Board", Font = Enum.Font.FredokaOne, TextSize = 9,
        TextColor3 = Color3.fromRGB(235, 200, 255), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 52,
    }, title)
    local closeBtn = new("ImageButton", {
        Size = UDim2.new(0, 10, 0, 10), Position = UDim2.new(1, -15, 0.5, -5),
        BackgroundTransparency = 1, Image = "rbxthumb://type=Asset&id=5107150321&w=150&h=150",
        ImageColor3 = Color3.fromRGB(165, 45, 45), ScaleType = Enum.ScaleType.Fit, ZIndex = 52,
    }, title)

    local list = new("ScrollingFrame", {
        Size = UDim2.new(1, -6, 1, -22), Position = UDim2.new(0, 3, 0, 20),
        BackgroundColor3 = Color3.fromRGB(22, 22, 32), BackgroundTransparency = 0.4, BorderSizePixel = 0,
        ScrollBarThickness = 2, ScrollBarImageColor3 = Color3.fromRGB(120, 120, 120), ScrollBarImageTransparency = 0.5,
        CanvasSize = UDim2.new(0, 0, 0, 0), ZIndex = 51,
    }, board)
    corner(list, 4)
    local layout = new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3) }, list)
    new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, list)
    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        list.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 8)
    end)

    local status = new("TextLabel", {
        Size = UDim2.new(1, -8, 0, 16), Position = UDim2.new(0, 4, 0, 24), BackgroundTransparency = 1,
        Text = "Loading…", Font = Enum.Font.FredokaOne, TextSize = 8, TextColor3 = Color3.fromRGB(170, 170, 190),
        TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 53,
    }, board)

    -- Drag the whole window (shadow root) via the title bar
    local dragging, dragStart, startPos
    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = input.Position; startPos = shadow.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and shadow.Parent and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            shadow.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)

    local fmt = _G._fmtVal or tostring

    -- Total AMVGG value of a player's profile COLLECTION pets, using the SAME calculation
    -- as the Misc-tab value calculator (_G._sumOffer → getPetVal/getVariantKey).
    -- Dedupes by `unique`: the profile collection repeats the same pets across its
    -- paginated widgets, which would otherwise multiply each player's value.
    local function petListValue(pets, cache)
        local seen, items = {}, {}
        for _, item in ipairs(pets or {}) do
            if item.kind then
                local u = item.unique
                if not (u and seen[u]) then
                    if u then seen[u] = true end
                    table.insert(items, { category = "pets", kind = item.kind, properties = item.properties })
                end
            end
        end
        return _G._sumOffer(items, cache)
    end

    -- Fetch a player's REAL profile collection pets. For players in the server the game
    -- reads the replicated profile via ClientData.get_server(player, "player_profile")
    -- (FetchProfile is only used for offline players and returns empty for online ones).
    -- Bypassed FetchProfile is kept as a fallback.
    local ClientData   = load("ClientData")
    local realPetCache = {}
    local function collectPets(profile, pets)
        if type(profile) ~= "table" then return end
        local pages = profile.pages or (profile.profile and profile.profile.pages)
        for _, page in ipairs(pages or {}) do
            for _, widget in ipairs(page.widgets or {}) do
                local wd = widget.data
                if wd and wd.widget_kind == "collection" then
                    for _, item in ipairs((wd.widget_data and wd.widget_data.items) or {}) do
                        if item.kind then table.insert(pets, item) end
                    end
                end
            end
        end
    end
    local function fetchRealPets(plr)
        local uid = plr.UserId
        if realPetCache[uid] then return realPetCache[uid] end
        local pets = {}
        -- Primary: replicated profile (same source the game uses for in-server players)
        pcall(function() collectPets(ClientData.get_server(plr, "player_profile"), pets) end)
        -- Fallback: real FetchProfile, bypassing the fake-profile injection
        if #pets == 0 then
            _G._rlbRealFetch = true
            local ok, data = pcall(function()
                return RouterClient.get("PlayerProfileAPI/FetchProfile"):InvokeServer(uid)
            end)
            _G._rlbRealFetch = false
            if ok then collectPets(data, pets) end
        end
        -- Only cache a NON-empty result. A player who just joined may not have their profile
        -- replicated yet — caching that empty result would lock their value at 0 forever.
        if #pets > 0 then realPetCache[uid] = pets end
        return pets
    end

    local function makeRow(rank, r)
        local row = new("Frame", {
            Size = UDim2.new(1, 0, 0, 20), BackgroundColor3 = Color3.fromRGB(40, 40, 54),
            BackgroundTransparency = 0.15, BorderSizePixel = 0, LayoutOrder = rank, ZIndex = 52,
        }, list)
        corner(row, 3)
        local medal = (rank == 1 and "🥇") or (rank == 2 and "🥈") or (rank == 3 and "🥉") or ("#" .. rank)
        new("TextLabel", {
            Size = UDim2.new(0, 16, 1, 0), Position = UDim2.new(0, 2, 0, 0), BackgroundTransparency = 1,
            Text = medal, Font = Enum.Font.FredokaOne, TextSize = 8, TextColor3 = Color3.fromRGB(235, 215, 150),
            TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 53,
        }, row)
        new("TextLabel", {
            Size = UDim2.new(1, -84, 1, 0), Position = UDim2.new(0, 18, 0, 0), BackgroundTransparency = 1,
            Text = r.name, Font = Enum.Font.FredokaOne, TextSize = 7, TextColor3 = Color3.fromRGB(235, 235, 255),
            TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 53,
        }, row)
        new("TextLabel", {
            Size = UDim2.new(0, 28, 1, 0), Position = UDim2.new(1, -64, 0, 0), BackgroundTransparency = 1,
            Text = fmt(r.value), Font = Enum.Font.FredokaOne, TextSize = 7, TextColor3 = Color3.fromRGB(120, 230, 150),
            TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 53,
        }, row)
        -- Trade button → sends a real trade request to that player
        local tradeBtn = new("TextButton", {
            Size = UDim2.new(0, 15, 0, 15), Position = UDim2.new(1, -32, 0.5, -7.5), BackgroundColor3 = Color3.fromRGB(30, 70, 45),
            Text = "🤝", Font = Enum.Font.FredokaOne, TextSize = 8, TextColor3 = Color3.fromRGB(150, 240, 170), ZIndex = 53,
        }, row)
        corner(tradeBtn, 3)
        tradeBtn.MouseButton1Click:Connect(function()
            if not (r.player and r.player.Parent) then return end
            pcall(function() RouterClient.get("TradeAPI/SendTradeRequest"):FireServer(r.player) end)
            tradeBtn.Text = "✓"
            task.delay(1, function() if tradeBtn.Parent then tradeBtn.Text = "🤝" end end)
        end)
        -- Profile button → opens that player's profile
        local profileBtn = new("TextButton", {
            Size = UDim2.new(0, 15, 0, 15), Position = UDim2.new(1, -16, 0.5, -7.5), BackgroundColor3 = Color3.fromRGB(40, 45, 80),
            Text = "👤", Font = Enum.Font.FredokaOne, TextSize = 8, TextColor3 = Color3.fromRGB(170, 190, 255), ZIndex = 53,
        }, row)
        corner(profileBtn, 3)
        profileBtn.MouseButton1Click:Connect(function()
            pcall(function()
                local PPA = UIManager and UIManager.apps and UIManager.apps.PlayerProfileApp
                if PPA then PPA:open_player_profile_for_user_id(r.uid) end
            end)
        end)
    end

    -- Incremental board: cache each player's value; joins/leaves add/remove ONE row instead of
    -- re-scanning everyone (which flickered and re-fetched all values on every join/leave).
    local boardResults = {}   -- uid -> { name, value, player, uid }
    local boardCache          -- AMVGG value cache, fetched once on open

    local function renderRows()
        for _, c in ipairs(list:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
        local arr = {}
        for _, r in pairs(boardResults) do table.insert(arr, r) end
        table.sort(arr, function(a, b) return a.value > b.value end)
        for rank, r in ipairs(arr) do makeRow(rank, r) end
        status.Visible = (#arr == 0)
        status.Text = (#arr == 0) and "No players found" or ""
    end

    -- Compute one player's value and store their row entry. If their profile hasn't replicated
    -- yet (#pets == 0, e.g. a fresh join), retry a few times so the value fills in once it loads.
    local function setPlayer(plr, render, retries)
        if not (boardCache and shadow.Parent and plr and plr.Parent) then return end
        local pets = {}
        pcall(function() pets = fetchRealPets(plr) or {} end)
        boardResults[plr.UserId] = {
            name   = plr.DisplayName ~= plr.Name and (plr.DisplayName .. " (@" .. plr.Name .. ")") or plr.Name,
            value  = petListValue(pets, boardCache),
            player = plr,
            uid    = plr.UserId,
        }
        if render then renderRows() end
        if #pets == 0 and (retries or 0) < 5 then
            task.delay(2.5, function() setPlayer(plr, true, (retries or 0) + 1) end)
        end
    end

    -- Full scan: only on open. Fetches the AMVGG cache once, computes every player, renders once.
    local function fullScan()
        if not shadow.Parent then return end
        status.Visible = true
        status.Text = "Loading values…"
        _G._fetchAmvgg(function(cache)
            if not shadow.Parent then return end
            if not cache then status.Text = "Failed to load AMVGG values"; return end
            boardCache = cache
            task.spawn(function()
                boardResults = {}
                for _, plr in ipairs(Players:GetPlayers()) do
                    if not shadow.Parent then return end
                    setPlayer(plr, false, 0)
                end
                renderRows()
            end)
        end)
    end

    -- Join → add just this player; Leave → drop just their row. No full re-scan.
    _G._richBoardAddPlayer = function(plr)
        if boardCache then setPlayer(plr, true, 0) else fullScan() end
    end
    _G._richBoardRemovePlayer = function(uid)
        boardResults[uid] = nil
        realPetCache[uid] = nil
        renderRows()
    end
    _G._richBoardRefresh = fullScan   -- kept for any manual full refresh

    closeBtn.MouseButton1Click:Connect(function()
        shadow:Destroy(); _G._richBoard = nil
        _G._richBoardRefresh = nil; _G._richBoardAddPlayer = nil; _G._richBoardRemovePlayer = nil
    end)
    fullScan()
end
end

-- =====================================================================
-- CLOUD SAVES pop-out (Firebase Realtime Database). One "Saves" tab, same shadow/board style
-- as the main GUI. Save chosen categories (keybinds / toggles / fake profile / inventory) to
-- Firebase keyed by HWID; load them back on a later join. Categories come from _G._saveHooks.
-- =====================================================================
do
_G._openSavesBoard = function()
    local main = _G._tradeGuiMainFrame
    local gui  = _G._controlGui
    if not (main and gui) then return end
    if _G._savesBoard and _G._savesBoard.Parent then
        _G._savesBoard:Destroy(); _G._savesBoard = nil; return
    end

    local HttpService = game:GetService("HttpService")
    local AB_request  = (syn and syn.request) or (http and http.request) or http_request or request or (fluxus and fluxus.request)

    local function new(cls, props, parent)
        local o = Instance.new(cls)
        for k, v in pairs(props) do o[k] = v end
        o.Parent = parent; return o
    end
    local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 3) }, o) end

    -- HWID → per-machine save key, sanitized for a Firebase path (no . $ # [ ] /).
    local function getHWID()
        local id
        pcall(function() if gethwid then id = gethwid() end end)
        if not id then pcall(function() id = game:GetService("RbxAnalyticsService"):GetClientId() end) end
        return (tostring(id or "unknown"):gsub("[^%w_%-]", "_"))
    end
    local HWID = getHWID()

    local function fbUrl(path)
        local base = tostring(_G.SAVES_FIREBASE_URL or ""):gsub("/+$", "")
        local u = base .. "/" .. path .. ".json"
        if _G.SAVES_FIREBASE_AUTH and _G.SAVES_FIREBASE_AUTH ~= "" then u = u .. "?auth=" .. _G.SAVES_FIREBASE_AUTH end
        return u
    end
    local function fbReq(method, path, bodyTbl)
        if not AB_request then return nil, "no executor HTTP (request)" end
        if (not _G.SAVES_FIREBASE_URL) or _G.SAVES_FIREBASE_URL:find("YOUR%-PROJECT") then return nil, "set Firebase URL" end
        local opts = { Url = fbUrl(path), Method = method }
        if bodyTbl ~= nil then opts.Body = HttpService:JSONEncode(bodyTbl); opts.Headers = { ["Content-Type"] = "application/json" } end
        local ok, res = pcall(AB_request, opts)
        if not ok then return nil, "request error" end
        local code = (type(res) == "table" and (res.StatusCode or res.status_code)) or 0
        local body = (type(res) == "table" and res.Body) or ""
        if code < 200 or code >= 300 then return nil, "HTTP " .. tostring(code) end
        if body == "" or body == "null" then return {} end
        local okD, data = pcall(function() return HttpService:JSONDecode(body) end)
        if not okD then return nil, "bad JSON" end
        return data
    end

    -- shadow + board (matches rich board; logical size + UIScale so it scales with the GUI)
    local sz, pos = main.AbsoluteSize, main.AbsolutePosition
    local scale = _G._guiScale or 1
    local W, H = math.floor(sz.X / scale), math.floor(sz.Y / scale)
    local cam = workspace.CurrentCamera
    local screenW = (cam and cam.ViewportSize.X) or 1000
    local bx = pos.X + sz.X + 12
    if bx + sz.X > screenW then bx = pos.X - sz.X - 12 end
    if bx < 0 then bx = 0 end

    local shadow = new("Frame", { Name="SavesBoard", Size=UDim2.fromOffset(W+6, H+6), Position=UDim2.fromOffset(bx-3, pos.Y-3), BackgroundColor3=Color3.new(0,0,0), BorderSizePixel=0, ZIndex=49 }, gui)
    _G._savesBoard = shadow
    if _G._registerScaledGui then _G._registerScaledGui(shadow) end
    corner(shadow, 7)
    local board = new("Frame", { Name="Board", Size=UDim2.fromOffset(W, H), Position=UDim2.fromOffset(3,3), BackgroundColor3=Color3.fromRGB(30,30,40), BorderSizePixel=0, ZIndex=50 }, shadow)
    corner(board, 5)
    new("UIStroke", { Color=Color3.fromRGB(190,34,230), Thickness=1.2, Transparency=0.2 }, board)
    new("UIPadding", { PaddingTop=UDim.new(0,4), PaddingLeft=UDim.new(0,5), PaddingRight=UDim.new(0,5), PaddingBottom=UDim.new(0,4) }, board)

    new("TextLabel", { Size=UDim2.new(1,-16,0,13), BackgroundTransparency=1, Text="Saves", Font=Enum.Font.FredokaOne, TextSize=9, TextColor3=Color3.fromRGB(190,34,230), TextXAlignment=Enum.TextXAlignment.Left, ZIndex=51 }, board)
    local closeBtn = new("TextButton", { Size=UDim2.new(0,13,0,13), Position=UDim2.new(1,-13,0,0), BackgroundColor3=Color3.fromRGB(120,30,30), Text="X", Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(255,220,220), ZIndex=51 }, board)
    corner(closeBtn, 3)
    closeBtn.MouseButton1Click:Connect(function() shadow:Destroy(); _G._savesBoard = nil end)

    local nameBox = new("TextBox", { Size=UDim2.new(1,-34,0,14), Position=UDim2.new(0,0,0,16), BackgroundColor3=Color3.fromRGB(40,40,52), Text="", PlaceholderText="Save name…", PlaceholderColor3=Color3.fromRGB(120,120,140), Font=Enum.Font.FredokaOne, TextSize=8, TextColor3=Color3.fromRGB(235,235,255), TextXAlignment=Enum.TextXAlignment.Left, ClearTextOnFocus=false, BorderSizePixel=0, ZIndex=51 }, board)
    corner(nameBox, 3); new("UIPadding", { PaddingLeft=UDim.new(0,4) }, nameBox)
    local saveBtn = new("TextButton", { Size=UDim2.new(0,30,0,14), Position=UDim2.new(1,-30,0,16), BackgroundColor3=Color3.fromRGB(30,80,50), Text="Save", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(120,255,160), ZIndex=51 }, board)
    corner(saveBtn, 3)

    -- category checkboxes (from registered hooks, in fixed order)
    local checks, cy = {}, 33
    for _, key in ipairs(_G._saveOrder or {}) do
        local hook = _G._saveHooks and _G._saveHooks[key]
        if hook then
            local box = new("TextButton", { Size=UDim2.new(0,10,0,10), Position=UDim2.new(0,0,0,cy), BackgroundColor3=Color3.fromRGB(30,80,50), Text="✓", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(150,255,180), ZIndex=51 }, board)
            corner(box, 2)
            new("TextLabel", { Size=UDim2.new(1,-14,0,10), Position=UDim2.new(0,13,0,cy), BackgroundTransparency=1, Text=hook.label or key, Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(200,200,215), TextXAlignment=Enum.TextXAlignment.Left, ZIndex=51 }, board)
            local c = { on = true }; checks[key] = c
            box.MouseButton1Click:Connect(function()
                c.on = not c.on
                box.Text = c.on and "✓" or ""
                box.BackgroundColor3 = c.on and Color3.fromRGB(30,80,50) or Color3.fromRGB(55,40,40)
            end)
            cy = cy + 12
        end
    end

    local status = new("TextLabel", { Size=UDim2.new(1,0,0,9), Position=UDim2.new(0,0,0,cy+1), BackgroundTransparency=1, Text="", Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(170, 140, 220), TextXAlignment=Enum.TextXAlignment.Left, ZIndex=51 }, board)
    local function setStatus(txt, col) status.Text = tostring(txt); status.TextColor3 = col or Color3.fromRGB(160,160,175) end

    local scroll = new("ScrollingFrame", { Size=UDim2.new(1,0,1,-(cy+12)), Position=UDim2.new(0,0,0,cy+12), BackgroundTransparency=1, BorderSizePixel=0, ScrollBarThickness=2, ScrollBarImageColor3=Color3.fromRGB(190,34,230), CanvasSize=UDim2.new(0,0,0,0), ZIndex=51 }, board)
    local sll = new("UIListLayout", { SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,3) }, scroll)
    sll:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        scroll.CanvasSize = UDim2.new(0,0,0, sll.AbsoluteContentSize.Y + 4)
    end)

    local function doLoad(sv)
        if type(sv) ~= "table" or type(sv.cats) ~= "table" then setStatus("Empty save", Color3.fromRGB(255,180,120)); return end
        local applied = {}
        for key, data in pairs(sv.cats) do
            local hook = _G._saveHooks and _G._saveHooks[key]
            if hook and hook.load then pcall(hook.load, data); table.insert(applied, hook.label or key) end
        end
        setStatus(#applied > 0 and ("Loaded: " .. table.concat(applied, ", ")) or "Nothing to load", Color3.fromRGB(120,255,160))
    end

    local function renderList(saves)
        for _, c in ipairs(scroll:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
        local arr = {}
        for id, sv in pairs(saves or {}) do
            if type(sv) == "table" then
                -- Tolerate a legacy save that got an extra push-key wrapper {pushkey:{cats,name,ts}}.
                if not sv.cats and not sv.name then
                    for _, inner in pairs(sv) do
                        if type(inner) == "table" and (inner.cats or inner.name) then sv = inner; break end
                    end
                end
                sv.__id = id; table.insert(arr, sv)
            end
        end
        table.sort(arr, function(a,b) return (a.ts or 0) > (b.ts or 0) end)
        for i, sv in ipairs(arr) do
            local row = new("Frame", { Size=UDim2.new(1,0,0,16), BackgroundColor3=Color3.fromRGB(40,40,54), BackgroundTransparency=0.15, LayoutOrder=i, ZIndex=52 }, scroll)
            corner(row, 3)
            new("TextLabel", { Size=UDim2.new(1,-54,1,0), Position=UDim2.new(0,4,0,0), BackgroundTransparency=1, Text=tostring(sv.name or "save"), Font=Enum.Font.FredokaOne, TextSize=7, TextColor3=Color3.fromRGB(235,235,255), TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, ZIndex=53 }, row)
            local loadB = new("TextButton", { Size=UDim2.new(0,24,0,12), Position=UDim2.new(1,-51,0.5,-6), BackgroundColor3=Color3.fromRGB(30,70,110), Text="Load", Font=Enum.Font.FredokaOne, TextSize=6, TextColor3=Color3.fromRGB(170,210,255), ZIndex=53 }, row)
            corner(loadB, 3)
            local delB = new("TextButton", { Size=UDim2.new(0,24,0,12), Position=UDim2.new(1,-25,0.5,-6), BackgroundColor3=Color3.fromRGB(110,30,30), Text="Del", Font=Enum.Font.FredokaOne, TextSize=6, TextColor3=Color3.fromRGB(255,180,180), ZIndex=53 }, row)
            corner(delB, 3)
            loadB.MouseButton1Click:Connect(function() doLoad(sv) end)
            delB.MouseButton1Click:Connect(function()
                setStatus("Deleting…")
                task.spawn(function()
                    local _, err = fbReq("DELETE", "saves/"..HWID.."/"..tostring(sv.__id))
                    if err then setStatus("Delete failed: "..err, Color3.fromRGB(255,120,120))
                    else if row.Parent then row:Destroy() end; setStatus("Deleted", Color3.fromRGB(120,255,160)) end
                end)
            end)
        end
        if #arr == 0 then setStatus("No saves yet — make one above.") end
    end

    local function refreshList()
        setStatus("Loading saves…")
        task.spawn(function()
            local data, err = fbReq("GET", "saves/"..HWID)
            if not shadow.Parent then return end
            if err then setStatus("Firebase: "..err, Color3.fromRGB(255,120,120)); return end
            renderList(data)
        end)
    end

    saveBtn.MouseButton1Click:Connect(function()
        local name = (nameBox.Text:gsub("^%s+",""):gsub("%s+$",""))
        if name == "" then name = "Save " .. tostring(os.time()) end
        local cats, any = {}, false
        for key, c in pairs(checks) do
            local hook = _G._saveHooks and _G._saveHooks[key]
            if c.on and hook and hook.save then
                local ok, res = pcall(hook.save)
                if ok and res ~= nil then cats[key] = res; any = true end
            end
        end
        if not any then setStatus("Pick at least one category.", Color3.fromRGB(255,200,80)); return end
        setStatus("Saving…")
        task.spawn(function()
            -- POST (push) to the collection so Firebase generates the key — matches how the
            -- executor's request actually behaves, giving a clean single-level structure.
            local _, err = fbReq("POST", "saves/"..HWID, { name = name, ts = os.time(), cats = cats })
            if not shadow.Parent then return end
            if err then setStatus("Save failed: "..err, Color3.fromRGB(255,120,120))
            else setStatus("Saved!", Color3.fromRGB(120,255,160)); nameBox.Text = ""; refreshList() end
        end)
    end)

    refreshList()
end
end

setActiveTab("Control")
