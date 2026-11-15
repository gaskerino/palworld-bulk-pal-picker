-- BulkPalPicker
--
-- Shift + right-click a Pal on the Pal Merchant's sell screen to select (or
-- deselect) every Pal of the same kind on the current Palbox page. In Pal
-- container screens (e.g. the Disassembly Conveyor), Shift + right-click
-- sends every Pal of that kind on the page across, like a normal right-click
-- does for one (see "Pal containers" below).
--
-- Shift is read through a UE4SS keybind on Shift + right mouse button: in
-- menus the game's player controller does not see keyboard keys.
--
-- How (found with a diagnostic probe):
--   * The sell screen is WBP_Shop_Pal_00_C. Right-clicking a Palbox slot
--     calls its SelectSellSlot(slotButton), which toggles the Pal: it adds it,
--     or calls "Unselect Sell Slot"(slot) when it was already selected.
--   * Palbox slots are WBP_PalCommonCharacterSlotButton_C; GetTargetSlot()
--     gives the PalIndividualCharacterSlot, whose handle gives the Pal.
--   * In this UE4SS build a hook runs after the function body, so the
--     clicked Pal's new state is known when the hook fires.
--
-- Safety: favorites are never touched; Lucky Pals are only included when the
-- Pal you click is Lucky too. Alphas count as the same kind as their normal
-- species (see settings below). Nothing is sold automatically: you still
-- confirm the sale yourself.

------------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------------

local SKIP_FAVORITES = true         -- never select favorite Pals
local LUCKY_ONLY_WITH_LUCKY = true  -- include Lucky Pals only if the clicked Pal is Lucky
local SEPARATE_ALPHAS = false       -- true: Alphas (BOSS_X) and normal X are separate kinds

------------------------------------------------------------------------------

local TAG = "[BulkPalPicker] "
local SHOP_CLASS = "/Game/Pal/Blueprint/UI/UserInterface/Shop/WBP_Shop_Pal_00.WBP_Shop_Pal_00_C"
local SLOT_BUTTON = "WBP_PalCommonCharacterSlotButton_C"

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(TAG .. (ok and msg or tostring(fmt)) .. "\n")
end

local logged = {}
local function logOnce(key, fmt, ...)
    if logged[key] then return end
    logged[key] = true
    log(fmt, ...)
end

local function unwrap(v)
    if type(v) ~= "userdata" then return v end
    local okg, g = pcall(function() return v.get end)
    if okg and g then
        local ok, inner = pcall(function() return v:get() end)
        if ok then return inner end
    end
    return v
end

local function valid(o)
    o = unwrap(o)
    if o == nil then return false end
    local ok, r = pcall(function() return o:IsValid() end)
    return ok and r == true
end

local function call(o, fn, ...)
    o = unwrap(o)
    if not valid(o) then return nil end
    local args = { ... }
    local ok, r = pcall(function() return o[fn](o, table.unpack(args)) end)
    if ok then return unwrap(r) end
    return nil
end

local function prop(o, name)
    o = unwrap(o)
    if not valid(o) then return nil end
    local ok, r = pcall(function() return o[name] end)
    if ok then return unwrap(r) end
    return nil
end

local function str(v)
    v = unwrap(v)
    if type(v) == "string" then return v end
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or nil
end

local function addr(o)
    o = unwrap(o)
    if not valid(o) then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    return ok and a or nil
end

local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then logOnce("err:" .. tostring(err), "error: %s", tostring(err)) end
end

------------------------------------------------------------------------------
-- Shift key
------------------------------------------------------------------------------

local function playerController()
    local pc = nil
    pcall(function()
        for _, c in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(c) then pc = c break end
        end
    end)
    return pc
end

-- While a menu has focus the player controller does not see keys, so
-- IsInputKeyDown reports Shift as up. UE4SS keybinds read the keyboard from
-- Windows directly: a Shift + right-mouse keybind raises a short-lived flag
-- (cleared after SHIFT_FLAG_MS of game time), which the next selection
-- consumes.
local SHIFT_FLAG_MS = 800
local shiftToken = 0
local pendingShift = nil

local okBind, bindErr = pcall(function()
    local rmb = (Key and Key.RIGHT_MOUSE_BUTTON) or 0x02
    RegisterKeyBind(rmb, { ModifierKey.SHIFT }, function()
        shiftToken = shiftToken + 1
        local mine = shiftToken
        pendingShift = mine
        pcall(ExecuteInGameThreadWithDelay, SHIFT_FLAG_MS, function()
            if pendingShift == mine then pendingShift = nil end
        end)
    end)
end)
if not okBind then log("could not register Shift + right mouse button (%s)", tostring(bindErr)) end

local function shiftPlayerInput()
    local pc = playerController()
    if not valid(pc) then return false end
    for _, k in ipairs({ "LeftShift", "RightShift" }) do
        local ok, down = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(k) }) end)
        if ok and down == true then return true end
    end
    return false
end

local function takeShiftClick()
    if pendingShift then
        pendingShift = nil
        return true
    end
    return false
end

------------------------------------------------------------------------------
-- Pals
------------------------------------------------------------------------------

local function className(o)
    local c = call(o, "GetClass")
    if not valid(c) then return "?" end
    local ok, n = pcall(function() return c:GetFName():ToString() end)
    return ok and n or "?"
end

-- The PalIndividualCharacterSlot a slot button shows. GetTargetSlot is a
-- blueprint function that returns through an output parameter, which a plain
-- Lua call does not hand back, so the slot is read from the button's own
-- object properties (the property name is found once and cached).
local slotPropName = nil
local propScanMisses = 0 -- after 5 scans that found nothing, stop scanning
local function slotOfButton(button)
    button = unwrap(button)
    if not valid(button) then return nil end
    -- Verified in game: GetTargetSlot hands the slot back in its output
    -- parameter "TargetSlot". Tried first; the other methods are fallbacks.
    local first = {}
    pcall(function() button:GetTargetSlot(first) end)
    local ts = unwrap(first.TargetSlot)
    if valid(ts) then return ts end
    if slotPropName then
        local s = prop(button, slotPropName)
        if valid(s) and className(s) == "PalIndividualCharacterSlot" then return s end
    end
    local found = nil
    if propScanMisses < 5 then pcall(function()
        local cls = button:GetClass()
        local depth = 0
        while cls and cls:IsValid() and depth < 6 and not found do
            cls:ForEachProperty(function(p)
                local okT, pt = pcall(function() return p:GetClass():GetFName():ToString() end)
                if okT and pt == "ObjectProperty" then
                    local pn = p:GetFName():ToString()
                    local v = prop(button, pn)
                    if valid(v) and className(v) == "PalIndividualCharacterSlot" then
                        found = v
                        if slotPropName ~= pn then
                            slotPropName = pn
                            log("slot buttons keep their Pal slot in '%s'", pn)
                        end
                        return true
                    end
                end
            end)
            cls = cls:GetSuperStruct()
            depth = depth + 1
        end
    end) end
    if found then return found end
    if not slotPropName then propScanMisses = propScanMisses + 1 end
    -- Fallback: call GetTargetSlot with an output table.
    local out = {}
    pcall(function() button:GetTargetSlot(out) end)
    for k, v in pairs(out) do
        v = unwrap(v)
        if valid(v) and className(v) == "PalIndividualCharacterSlot" then
            logOnce("slotvia:out", "slot read through GetTargetSlot output '%s'", tostring(k))
            return v
        end
    end
    local direct = call(button, "GetTargetSlot")
    if valid(direct) then
        logOnce("slotvia:direct", "slot read through GetTargetSlot return value")
        return direct
    end
    return nil
end

-- { slot, key, outerKey, id, lucky, favorite } for a slot button, or nil.
local function describeButton(button)
    local slot = slotOfButton(button)
    if not valid(slot) then
        logOnce("noslot", "could not read the Pal slot of a slot button (%s)", className(button))
        return nil
    end
    local handle = call(slot, "GetHandle")
    local param = valid(handle) and call(handle, "TryGetIndividualParameter") or nil
    if not valid(param) then return nil end
    local id = str(call(param, "GetCharacterID"))
    if not id then return nil end
    return {
        slot = slot,
        key = addr(slot),
        outerKey = addr(call(slot, "GetOuter")),
        id = id,
        lucky = call(param, "IsRarePal") == true,
        favorite = call(param, "IsFavoritePal") == true,
    }
end

-- Cheap version for the hover hook, which fires on every mouse-over: the
-- species / Lucky / container of a Pal never change, so they are cached per
-- Pal handle. (Bulk candidates always use describeButton, so a favorite set
-- after caching is still respected.)
local hoverCache = {} -- handle address -> { id, lucky, outerKey }
local hoverCacheSize = 0
local function describeHover(button)
    local slot = slotOfButton(button)
    if not valid(slot) then return nil end
    local handle = call(slot, "GetHandle")
    local ha = addr(handle)
    if not ha then return nil end
    local c = hoverCache[ha]
    if not c then
        local p = describeButton(button)
        if not p then return nil end
        if hoverCacheSize > 2000 then hoverCache, hoverCacheSize = {}, 0 end
        c = { id = p.id, lucky = p.lucky, outerKey = p.outerKey }
        hoverCache[ha] = c
        hoverCacheSize = hoverCacheSize + 1
    end
    return c
end

local function kindOf(id)
    if SEPARATE_ALPHAS then return id:lower() end
    return (id:gsub("^[Bb][Oo][Ss][Ss]_", "")):lower()
end

------------------------------------------------------------------------------
-- Selection tracking
------------------------------------------------------------------------------

-- Selected slots on the current sell screen (slot address -> true), kept up
-- to date from the game's own SelectSellSlot / "Unselect Sell Slot" calls.
local selected = {}
local currentShop = nil
local unselectedNow = nil -- slot address "Unselect Sell Slot" just ran for
local bulkRunning = false

local function resetIfNewShop(shop)
    local a = addr(shop)
    if a ~= currentShop then
        currentShop = a
        selected = {}
    end
end

------------------------------------------------------------------------------
-- Bulk select
------------------------------------------------------------------------------

local function partyButtons(shop)
    local set = {}
    pcall(function()
        shop.OtomoPalSlotArray:ForEach(function(_, el)
            local a = addr(el)
            if a then set[a] = true end
        end)
    end)
    return set
end

local function bulk(shop, clicked, wantSelected)
    if not valid(shop) then log("sell screen closed") return end
    if prop(shop, "IsSellMode") ~= true then log("not in sell mode") return end
    local party = partyButtons(shop)
    local queue = {}
    local n = { all = 0, visible = 0, pal = 0, box = 0, kind = 0 }
    for _, b in ipairs(FindAllOf(SLOT_BUTTON) or {}) do
        n.all = n.all + 1
        local ba = addr(b)
        if ba and ba ~= clicked.buttonKey and not party[ba] and call(b, "IsVisible") == true then
            n.visible = n.visible + 1
            local p = describeButton(b)
            if p then n.pal = n.pal + 1 end
            if p and p.outerKey == clicked.outerKey then n.box = n.box + 1 end
            if p and p.outerKey == clicked.outerKey and kindOf(p.id) == clicked.kind then
                n.kind = n.kind + 1
                if not (SKIP_FAVORITES and p.favorite)
                    and not (LUCKY_ONLY_WITH_LUCKY and p.lucky and not clicked.lucky)
                    and (selected[p.key] == true) ~= wantSelected then
                    queue[#queue + 1] = b
                end
            end
        end
    end
    if #queue == 0 then
        log("no other %s Pals to %s (buttons %d, visible %d, with a Pal %d, same box %d, same kind %d)",
            clicked.id, wantSelected and "select" or "deselect", n.all, n.visible, n.pal, n.box, n.kind)
        return
    end
    -- One Pal per game tick, like the game's own clicks (avoids a hitch).
    bulkRunning = true
    local i = 0
    local function step()
        i = i + 1
        local b = queue[i]
        if b and valid(shop) and valid(b) then
            safe(function() shop:SelectSellSlot(b) end)
        end
        if i < #queue then
            if not pcall(ExecuteInGameThread, function() safe(step) end) then step() end
        else
            bulkRunning = false
            log("%s %d more %s", wantSelected and "selected" or "deselected", #queue, clicked.id)
        end
    end
    step()
end

------------------------------------------------------------------------------
-- Hooks
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- Pal containers (Disassembly Conveyor and other container screens)
------------------------------------------------------------------------------
--
-- The conveyor has no selection: it is a container. Its screen,
-- WBP_IngameMenu_CommonCharacterContainer_C, remembers the slot under the
-- mouse (OnHoverPalSlot(button)) and a right-click calls OnSendSlotInput(),
-- which moves that Pal to the other container. Bulk sending repeats
-- "hover this button, send" for each matching Pal, one per game tick.

local CONTAINER_CLASS = "/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/WBP_IngameMenu_CommonCharacterContainer.WBP_IngameMenu_CommonCharacterContainer_C"

local hovered = nil -- { button, info } of the slot under the mouse

local function bulkSend(screen, clicked)
    if not valid(screen) then log("container screen closed") return end
    local queue = {}
    local n = { visible = 0, box = 0, kind = 0 }
    for _, b in ipairs(FindAllOf(SLOT_BUTTON) or {}) do
        local ba = addr(b)
        if ba and ba ~= clicked.buttonKey and call(b, "IsVisible") == true then
            n.visible = n.visible + 1
            local p = describeButton(b)
            if p and p.outerKey == clicked.outerKey then
                n.box = n.box + 1
                if kindOf(p.id) == clicked.kind then
                    n.kind = n.kind + 1
                    if not (SKIP_FAVORITES and p.favorite)
                        and not (LUCKY_ONLY_WITH_LUCKY and p.lucky and not clicked.lucky) then
                        queue[#queue + 1] = b
                    end
                end
            end
        end
    end
    if #queue == 0 then
        log("no other %s Pals to send (visible %d, same container %d, same kind %d)",
            clicked.id, n.visible, n.box, n.kind)
        return
    end
    bulkRunning = true
    local i = 0
    local function step()
        i = i + 1
        local b = queue[i]
        if b and valid(screen) and valid(b) then
            safe(function()
                screen:OnHoverPalSlot(b)
                screen:OnSendSlotInput()
                screen:OnUnhoverPalSlot(b)
            end)
        end
        if i < #queue and valid(screen) then
            if not pcall(ExecuteInGameThread, function() safe(step) end) then step() end
        else
            bulkRunning = false
            log("sent %d more %s", i, clicked.id)
        end
    end
    step()
end

------------------------------------------------------------------------------
-- Hooks
------------------------------------------------------------------------------

local SLOT_BUTTON_BASE = "/Game/Pal/Blueprint/UI/Thumbnails/Character/Base/WBP_PalCharacterSlotButtonBase.WBP_PalCharacterSlotButtonBase_C"

local hooks = {
    {
        class = SHOP_CLASS,
        fn = "Unselect Sell Slot",
        cb = function(shop, slotParam)
            unselectedNow = addr(slotParam)
        end,
    },
    {
        class = SHOP_CLASS,
        fn = "SelectSellSlot",
        cb = function(shop, buttonParam)
            resetIfNewShop(shop)
            local button = unwrap(buttonParam)
            local p = describeButton(button)
            if not p or not p.key then unselectedNow = nil return end
            local nowSelected = unselectedNow ~= p.key
            unselectedNow = nil
            selected[p.key] = nowSelected or nil
            if bulkRunning then return end
            local clicked = {
                buttonKey = addr(button), outerKey = p.outerKey, kind = kindOf(p.id),
                id = p.id, lucky = p.lucky,
            }
            local shiftNow = shiftPlayerInput()
            -- Checked a moment later (the UE4SS keybind may register just
            -- after the game's click), and never inside the game's own call.
            pcall(ExecuteInGameThreadWithDelay, 120, function()
                local shift = takeShiftClick() or shiftNow
                logOnce("click:" .. tostring(shift),
                    "sell screen right-click on %s (now %s, shift=%s)", p.id,
                    nowSelected and "selected" or "deselected", tostring(shift))
                if shift then safe(bulk, shop, clicked, nowSelected) end
            end)
        end,
    },
    {
        class = CONTAINER_CLASS,
        fn = "OnHoverPalSlot",
        cb = function(screen, buttonParam)
            if bulkRunning then return end
            local button = unwrap(buttonParam)
            local p = describeHover(button)
            hovered = p and { buttonKey = addr(button), info = p } or nil
        end,
    },
    {
        class = CONTAINER_CLASS,
        fn = "OnSendSlotInput",
        cb = function(screen)
            if bulkRunning or not hovered then return end
            local p = hovered.info
            local clicked = {
                buttonKey = hovered.buttonKey, outerKey = p.outerKey, kind = kindOf(p.id),
                id = p.id, lucky = p.lucky,
            }
            hovered = nil -- the Pal has just moved out of that slot
            local shiftNow = shiftPlayerInput()
            pcall(ExecuteInGameThreadWithDelay, 120, function()
                local shift = takeShiftClick() or shiftNow
                logOnce("send:" .. tostring(shift), "container right-click on %s (shift=%s)", p.id, tostring(shift))
                if shift then safe(bulkSend, screen, clicked) end
            end)
        end,
    },
}

-- How often each hook fires, logged every 30 s while any fired.
local hookCalls = {}
local function reportCalls()
    local parts = {}
    for k, v in pairs(hookCalls) do parts[#parts + 1] = k .. "=" .. v end
    if #parts > 0 then log("hook calls in the last 30 s: %s", table.concat(parts, ", ")) end
    hookCalls = {}
end
pcall(LoopInGameThreadWithDelay, 30000, function() safe(reportCalls) end)

local function install()
    for _, h in ipairs(hooks) do
        if not h.done and valid(StaticFindObject(h.class)) then
            h.done = true
            local cb = h.cb
            local fired = 0
            local fn = h.fn
            local ok, err = pcall(RegisterHook, h.class .. ":" .. h.fn, function(ctx, ...)
                fired = fired + 1
                if fired <= 2 then log("%s fired (#%d)", fn, fired) end
                hookCalls[fn] = (hookCalls[fn] or 0) + 1
                safe(cb, unwrap(ctx), ...)
            end)
            if ok then
                log("hooked %s", h.fn)
            else
                log("could not hook %s (%s)", h.fn, tostring(err))
            end
        end
    end
end

for _, cls in ipairs({ SHOP_CLASS, CONTAINER_CLASS }) do
    pcall(NotifyOnNewObject, cls, function()
        pcall(ExecuteInGameThread, function() safe(install) end)
    end)
end
pcall(ExecuteInGameThread, function() safe(install) end)

log("loaded. Shift + right-click a Pal on the merchant's sell screen or in a Pal container (e.g. the Disassembly Conveyor).")
