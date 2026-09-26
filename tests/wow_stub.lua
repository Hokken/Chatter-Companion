-- Enough of the 3.3.5 client to load and drive the addon
-- outside the game: widgets that only remember what was set
-- on them, a chat channel that records instead of sends, and
-- a clock the tests advance by hand.
--
-- Only Chatter.lua and ChatterRoster.lua are loaded. ChatterUI
-- builds real widgets from Blizzard templates and has no
-- behaviour of its own, so the panels it would have produced
-- are replaced by the fakes below.

local stub = {}

-- Everything the addon sent through SendChatMessage, in order.
stub.sent = {}
-- Names of the StaticPopup dialogs it asked for.
stub.popups = {}

local function newFontString()
    local fs = {text = ""}
    function fs:SetText(value) self.text = value or "" end
    function fs:GetText() return self.text end
    function fs:SetTextColor(r, g, b)
        self.r, self.g, self.b = r, g, b
    end
    function fs:SetJustifyH() end
    return fs
end

local function newEditBox()
    local box = newFontString()
    function box:SetMaxLetters() end
    function box:SetAutoFocus() end
    function box:ClearFocus() end
    return box
end

local function newButton()
    local btn = {enabled = true}
    function btn:Enable() self.enabled = true end
    function btn:Disable() self.enabled = false end
    function btn:IsEnabled() return self.enabled end
    return btn
end

-- One editor, shaped the way BuildEditor shapes it. The
-- /chatter window carries everything; the Interface Options
-- "Bot Traits" section has the traits and tone but no story,
-- and "Background Stories" has only the story. Which widgets
-- exist matters: the addon guards on their presence.
local function newPanel(shown, section)
    local p = {
        status = newFontString(),
        shown = shown and true or false,
    }

    if section ~= "stories" then
        p.trait1 = newEditBox()
        p.trait2 = newEditBox()
        p.trait3 = newEditBox()
        p.tone = newFontString()
        p.saveBtn = newButton()
    end

    if section ~= "traits" then
        p.backstory = newFontString()
        p.regenStoryBtn = newButton()
    end

    function p:IsShown() return self.shown end
    function p:Show() self.shown = true end
    function p:Hide() self.shown = false end
    p.refreshList = function() end
    return p
end

stub.newPanel = newPanel

local function newFrame(name)
    local f = {scripts = {}, shown = false}
    function f:SetScript(which, fn) self.scripts[which] = fn end
    function f:GetScript(which) return self.scripts[which] end
    function f:RegisterEvent() end
    function f:UnregisterEvent() end
    function f:SetPoint() end
    function f:ClearAllPoints() end
    function f:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    function f:SetWidth() end
    function f:SetHeight() end
    function f:SetText() end
    function f:IsShown() return self.shown end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:SetMovable() end
    function f:EnableMouse() end
    function f:RegisterForDrag() end
    function f:SetBackdrop() end
    if name then _G[name] = f end
    return f
end

-- Reinstalls a clean set of globals. Called before every test
-- so no state survives from the previous one.
function stub.install()
    stub.sent = {}
    stub.popups = {}

    _G.ChatterEventFrame = nil
    _G.ChatterDB = nil
    _G.StaticPopupDialogs = {}
    _G.SlashCmdList = {}
    _G.UIParent = newFrame()
    _G.UISpecialFrames = {}

    _G.CreateFrame = function(_, name)
        return newFrame(name)
    end

    _G.SendChatMessage = function(message)
        table.insert(stub.sent, message)
    end

    _G.StaticPopup_Show = function(name)
        table.insert(stub.popups, name)
        return {}
    end

    _G.ChatFrame_AddMessageEventFilter = function() end
    _G.DEFAULT_CHAT_FRAME = {AddMessage = function() end}
    _G.InterfaceOptions_AddCategory = function() end
    _G.GetTime = function() return 0 end
end

-- Loads the addon fresh and hands back its frame with both
-- editors attached.
function stub.load(root)
    stub.install()
    dofile(root .. "/Chatter.lua")
    dofile(root .. "/ChatterRoster.lua")

    local C = _G.ChatterEventFrame
    C.frame = newPanel(true)
    C.traitsPanel = newPanel(false, "traits")
    C.storiesPanel = newPanel(false, "stories")
    -- Supplied by ChatterUI, which the harness does not load.
    C.BuildFrame = function() end
    C.BuildOptionsPanel = function() end
    C.SaveWindowPosition = function() end
    return C
end

-- Runs the addon's OnUpdate for `seconds` of game time in
-- small steps, the way the client would.
function stub.advance(C, seconds, step)
    step = step or 0.05
    local onUpdate = C:GetScript("OnUpdate")
    local left = seconds
    while left > 0 do
        local slice = step < left and step or left
        onUpdate(C, slice)
        left = left - slice
    end
end

-- Delivers one CHATTER_ADDON line the way the server would.
function stub.serverSays(C, payload)
    C:GetScript("OnEvent")(
        C, "CHAT_MSG_SYSTEM", C.prefix .. payload
    )
end

-- The commands the addon has sent, stripped of the ".llmc "
-- prefix, so tests can talk about "commit 7" rather than the
-- whole chat line.
function stub.commands()
    local out = {}
    for _, line in ipairs(stub.sent) do
        table.insert(out, (line:gsub("^%.llmc ", "")))
    end
    return out
end

function stub.lastCommand()
    local all = stub.commands()
    return all[#all]
end

function stub.sentCommand(prefix)
    for _, command in ipairs(stub.commands()) do
        if command:sub(1, #prefix) == prefix then
            return command
        end
    end
    return nil
end

function stub.clearSent()
    stub.sent = {}
end

return stub
