local Chatter = CreateFrame("Frame", "ChatterEventFrame")

Chatter.prefix = "CHATTER_ADDON "
Chatter.roster = {}
Chatter.pendingRoster = nil
Chatter.selectedGuid = nil
Chatter.pendingProfileGuid = nil
Chatter.pendingToneGuid = nil
Chatter.tonePollElapsed = 0
Chatter.tonePollRemaining = 0
Chatter.pendingBackstoryGuid = nil
Chatter.backstoryPollElapsed = 0
Chatter.backstoryPollRemaining = 0

local function trim(value)
    if not value then
        return ""
    end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sanitizeInput(value)
    value = trim(value or "")
    value = value:gsub("[%c]", " ")
    value = value:gsub("%s+", " ")
    return trim(value)
end

function Chatter:Encode(value)
    value = sanitizeInput(value)
    if value == "" then
        return "-"
    end

    return (value:gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

function Chatter:Decode(value)
    if not value or value == "-" then
        return ""
    end

    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function Chatter:GetActivePanel()
    if self.frame and self.frame:IsShown() then
        return self.frame
    end
    if self.traitsPanel and self.traitsPanel:IsShown() then
        return self.traitsPanel
    end
    return self.frame
end

function Chatter:SetStatus(text, r, g, b)
    local panels = {}
    if self.frame then
        table.insert(panels, self.frame)
    end
    if self.traitsPanel then
        table.insert(panels, self.traitsPanel)
    end
    for _, p in ipairs(panels) do
        if p.status then
            p.status:SetText(text or "")
            p.status:SetTextColor(
                r or 1, g or 0.82, b or 0
            )
        end
    end
end

function Chatter:SendCommand(command)
    SendChatMessage(".llmc " .. command, "SAY")
end

function Chatter:StopTonePoll()
    self.pendingToneGuid = nil
    self.tonePollElapsed = 0
    self.tonePollRemaining = 0
end

function Chatter:StartTonePoll(guid)
    guid = tonumber(guid)
    if not guid then
        return
    end

    self.pendingToneGuid = guid
    self.tonePollElapsed = 0
    self.tonePollRemaining = 20
end

function Chatter:HandleTonePoll(elapsed)
    if not self.pendingToneGuid then
        return
    end

    self.tonePollElapsed = self.tonePollElapsed + elapsed
    self.tonePollRemaining = self.tonePollRemaining - elapsed

    if self.tonePollRemaining <= 0 then
        self:SetStatus(
            "Tone generation is still pending. Use Refresh.",
            1, 0.82, 0
        )
        self:StopTonePoll()
        return
    end

    if self.tonePollElapsed >= 1.5 then
        self.tonePollElapsed = 0
        self:SendCommand("get " .. self.pendingToneGuid)
    end
end

function Chatter:StopBackstoryPoll()
    self.pendingBackstoryGuid = nil
    self.backstoryPollElapsed = 0
    self.backstoryPollRemaining = 0
end

function Chatter:StartBackstoryPoll(guid)
    guid = tonumber(guid)
    if not guid then
        return
    end

    self.pendingBackstoryGuid = guid
    self.backstoryPollElapsed = 0
    self.backstoryPollRemaining = 30
end

function Chatter:HandleBackstoryPoll(elapsed)
    if not self.pendingBackstoryGuid then
        return
    end

    self.backstoryPollElapsed =
        self.backstoryPollElapsed + elapsed
    self.backstoryPollRemaining =
        self.backstoryPollRemaining - elapsed

    if self.backstoryPollRemaining <= 0 then
        self:SetStatus(
            "Backstory generation still pending."
            .. " Use Refresh.",
            1, 0.82, 0
        )
        self:StopBackstoryPoll()
        return
    end

    if self.backstoryPollElapsed >= 2.0 then
        self.backstoryPollElapsed = 0
        self:SendCommand(
            "get " .. self.pendingBackstoryGuid
        )
    end
end

function Chatter:SaveWindowPosition()
    if not self.frame then
        return
    end

    local point, _, relPoint, x, y =
        self.frame:GetPoint(1)
    ChatterDB = ChatterDB or {}
    ChatterDB.point = point
    ChatterDB.relPoint = relPoint
    ChatterDB.x = x
    ChatterDB.y = y
end

function Chatter:RestoreWindowPosition()
    if not self.frame then
        return
    end

    self.frame:ClearAllPoints()
    if ChatterDB and ChatterDB.point then
        self.frame:SetPoint(
            ChatterDB.point,
            UIParent,
            ChatterDB.relPoint or ChatterDB.point,
            ChatterDB.x or 0,
            ChatterDB.y or 0
        )
    else
        self.frame:SetPoint("CENTER")
    end
end

local function createLabel(parent, text, x, y)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetJustifyH("LEFT")
    label:SetText(text)
    return label
end

local function createEditBox(parent, x, y, width, height)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    holder:SetWidth(width)
    holder:SetHeight(height)
    holder:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 12,
        insets = {
            left = 3,
            right = 3,
            top = 3,
            bottom = 3
        }
    })
    holder:SetBackdropColor(0, 0, 0, 0.85)
    holder:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)

    local box = CreateFrame("EditBox", nil, holder)
    box:SetAutoFocus(false)
    box:SetMultiLine(false)
    box:SetFontObject(GameFontHighlight)
    box:SetPoint("TOPLEFT", holder, "TOPLEFT", 8, -6)
    box:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -8, 6)
    box:SetTextInsets(0, 0, 0, 0)
    box:SetJustifyH("LEFT")

    holder.editBox = box
    return box
end

local function createMultiLineEditBox(
    parent, x, y, width, height
)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    holder:SetWidth(width)
    holder:SetHeight(height)
    holder:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 12,
        insets = {
            left = 3,
            right = 3,
            top = 3,
            bottom = 3
        }
    })
    holder:SetBackdropColor(0, 0, 0, 0.85)
    holder:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)

    -- Scrollbar (thin slider on the right)
    local scrollbar = CreateFrame(
        "Slider", nil, holder
    )
    scrollbar:SetWidth(12)
    scrollbar:SetPoint(
        "TOPRIGHT", holder, "TOPRIGHT", -4, -6
    )
    scrollbar:SetPoint(
        "BOTTOMRIGHT", holder, "BOTTOMRIGHT", -4, 6
    )
    scrollbar:SetOrientation("VERTICAL")
    scrollbar:SetMinMaxValues(0, 1)
    scrollbar:SetValue(0)
    scrollbar:SetValueStep(1)
    scrollbar:SetThumbTexture(
        "Interface\\Buttons\\UI-ScrollBar-Knob"
    )
    scrollbar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
    })
    scrollbar:SetBackdropColor(0.1, 0.1, 0.1, 0.5)

    local scroll = CreateFrame(
        "ScrollFrame", nil, holder
    )
    scroll:SetPoint("TOPLEFT", holder, "TOPLEFT", 6, -6)
    scroll:SetPoint(
        "BOTTOMRIGHT", scrollbar, "BOTTOMLEFT", -2, 0
    )

    local box = CreateFrame("EditBox", nil, scroll)
    box:SetAutoFocus(false)
    box:SetMultiLine(true)
    box:SetFontObject(GameFontHighlight)
    -- Full width minus scrollbar and padding
    box:SetWidth(width - 28)
    box:SetTextInsets(2, 2, 2, 2)
    box:SetJustifyH("LEFT")
    scroll:SetScrollChild(box)

    -- Update width dynamically when shown
    scroll:SetScript("OnSizeChanged", function(self)
        box:SetWidth(self:GetWidth())
    end)

    -- Sync helper: update scrollbar range and
    -- position from current scroll state
    local function updateScrollbar()
        local maxScroll = math.max(
            0,
            box:GetHeight() - scroll:GetHeight()
        )
        scrollbar:SetMinMaxValues(0, maxScroll)
        if maxScroll > 0 then
            scrollbar:Show()
        else
            scrollbar:Hide()
        end
    end

    -- Mouse-wheel scrolling on the holder frame
    holder:EnableMouseWheel(true)
    holder:SetScript("OnMouseWheel", function(_, delta)
        local cur = scroll:GetVerticalScroll()
        local maxScroll = math.max(
            0,
            box:GetHeight() - scroll:GetHeight()
        )
        local step = 20
        local newVal = cur - (delta * step)
        newVal = math.max(0, math.min(newVal, maxScroll))
        scroll:SetVerticalScroll(newVal)
        scrollbar:SetValue(newVal)
    end)

    -- Scrollbar drag updates scroll position
    scrollbar:SetScript("OnValueChanged", function(
        self, value
    )
        scroll:SetVerticalScroll(value)
    end)

    -- Update scrollbar when text changes
    box:SetScript("OnTextChanged", function()
        updateScrollbar()
    end)

    -- Initial scrollbar state (hidden until needed)
    scrollbar:Hide()

    holder.editBox = box
    holder.scroll = scroll
    holder.scrollbar = scrollbar
    holder.updateScrollbar = updateScrollbar
    return box
end

function Chatter:InitDropdown(dropdown)
    if not dropdown then
        return
    end

    UIDropDownMenu_Initialize(dropdown, function(_, level)
        if level ~= 1 then
            return
        end

        if #self.roster == 0 then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "No known bots"
            info.isTitle = true
            info.notCheckable = true
            UIDropDownMenu_AddButton(info, level)
            return
        end

        for _, bot in ipairs(self.roster) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = bot.name
            info.value = bot.guid
            info.checked = (bot.guid == self.selectedGuid)
            info.func = function()
                Chatter:SelectBot(bot.guid)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    UIDropDownMenu_SetWidth(dropdown, 260)

    if self.selectedGuid then
        for _, bot in ipairs(self.roster) do
            if bot.guid == self.selectedGuid then
                UIDropDownMenu_SetText(dropdown, bot.name)
                return
            end
        end
    end

    UIDropDownMenu_SetText(dropdown, "Select a bot")
end

function Chatter:UpdateDropdown()
    if self.frame then
        self:InitDropdown(self.frame.dropdown)
    end
    if self.traitsPanel then
        self:InitDropdown(self.traitsPanel.dropdown)
    end
end

function Chatter:ApplyProfileToPanel(p, profile)
    if not p then
        return
    end
    if p.trait1 then
        p.trait1:SetText(profile.trait1 or "")
    end
    if p.trait2 then
        p.trait2:SetText(profile.trait2 or "")
    end
    if p.trait3 then
        p.trait3:SetText(profile.trait3 or "")
    end
    if p.tone then
        p.tone:SetText(profile.tone or "")
    end
end

function Chatter:ApplyProfile(profile)
    local awaitingTone = (
        self.pendingToneGuid == profile.guid
    )
    self.selectedGuid = profile.guid

    self:ApplyProfileToPanel(self.frame, profile)
    self:ApplyProfileToPanel(self.traitsPanel, profile)

    ChatterDB = ChatterDB or {}
    ChatterDB.selectedGuid = profile.guid

    self:UpdateDropdown()
    if awaitingTone then
        if profile.tone and profile.tone ~= "" then
            self:StopTonePoll()
            self:SetStatus(
                "Generated tone for "
                    .. (profile.name or "bot"),
                0.3, 1, 0.3
            )
        else
            self:SetStatus(
                "Generating tone...", 1, 0.82, 0
            )
        end
    else
        self:SetStatus(
            "Loaded " .. (profile.name or "bot"),
            0.3, 1, 0.3
        )
    end
end

function Chatter:SelectBot(guid)
    guid = tonumber(guid)
    if not guid then
        return
    end

    if self.pendingToneGuid and self.pendingToneGuid ~= guid then
        self:StopTonePoll()
    end
    if self.pendingBackstoryGuid
        and self.pendingBackstoryGuid ~= guid then
        self:StopBackstoryPoll()
    end

    self.selectedGuid = guid
    self.pendingProfileGuid = guid
    self:UpdateDropdown()
    self:SetStatus("Loading bot profile...", 1, 0.82, 0)
    self:SendCommand("get " .. guid)
end

function Chatter:RequestRoster()
    self.pendingRoster = {}
    self:SetStatus("Requesting roster...", 1, 0.82, 0)
    self:SendCommand("roster")
end

function Chatter:SaveProfile()
    if not self.selectedGuid then
        self:SetStatus("Select a bot first.", 1, 0.2, 0.2)
        return
    end

    local p = self:GetActivePanel()
    if not p then
        self:SetStatus("No panel open.", 1, 0.2, 0.2)
        return
    end

    local trait1 = sanitizeInput(p.trait1:GetText())
    local trait2 = sanitizeInput(p.trait2:GetText())
    local trait3 = sanitizeInput(p.trait3:GetText())

    p.trait1:SetText(trait1)
    p.trait2:SetText(trait2)
    p.trait3:SetText(trait3)
    p.tone:SetText("")

    if trait1 == "" or trait2 == "" or trait3 == "" then
        self:SetStatus("All three traits are required.", 1, 0.2, 0.2)
        return
    end

    if string.len(trait1) > 64 or string.len(trait2) > 64
        or string.len(trait3) > 64 then
        self:SetStatus("Traits must stay under 64 characters.", 1, 0.2, 0.2)
        return
    end

    self:StopTonePoll()
    self:StopBackstoryPoll()
    self:SetStatus("Saving traits and generating tone...", 1, 0.82, 0)
    self:SendCommand(
        string.format(
            "set %d %s %s %s",
            self.selectedGuid,
            self:Encode(trait1),
            self:Encode(trait2),
            self:Encode(trait3)
        )
    )
end

function Chatter:ConfirmForget()
    if not self.selectedGuid then
        self:SetStatus(
            "Select a bot first.", 1, 0.2, 0.2
        )
        return
    end

    local p = self:GetActivePanel()
    local botName = self.selectedGuid
    if p and p.trait1 then
        local t = p.trait1:GetText()
        if t and t ~= "" then
            botName = self:Decode(
                self:GetSelectedName() or botName
            )
        end
    end
    botName = self:GetSelectedName() or botName

    StaticPopup_Show(
        "CHATTER_CONFIRM_FORGET", botName
    )
end

function Chatter:GetSelectedName()
    if not self.selectedGuid then
        return nil
    end
    local guid = tonumber(self.selectedGuid)
    if not guid then return nil end
    for _, entry in ipairs(self.roster or {}) do
        if entry.guid == guid then
            return self:Decode(entry.name)
        end
    end
    return nil
end

function Chatter:ForgetBot()
    if not self.selectedGuid then return end
    self:SetStatus(
        "Forgetting bot...", 1, 0.82, 0
    )
    self:SendCommand(
        "forget " .. self.selectedGuid
    )
end

function Chatter:RegenBackstory()
    if not self.selectedGuid then
        self:SetStatus("Select a bot first.", 1, 0.2, 0.2)
        return
    end

    self:StopBackstoryPoll()
    self:SetStatus(
        "Regenerating backstory...", 1, 0.82, 0
    )

    local p = self:GetActivePanel()
    if p and p.backstory then
        p.backstory:SetText("")
    end

    self:SendCommand(
        "regenbackstory " .. self.selectedGuid
    )
    self:StartBackstoryPoll(self.selectedGuid)
end

function Chatter:BuildFrame()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "ChatterMainFrame", UIParent)
    frame:SetWidth(480)
    frame:SetHeight(580)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        Chatter:SaveWindowPosition()
    end)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = {
            left = 4,
            right = 4,
            top = 4,
            bottom = 4
        }
    })
    frame:SetBackdropColor(0, 0, 0, 0.9)
    frame:Hide()

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)

    local title = frame:CreateFontString(
        nil, "OVERLAY", "GameFontNormalLarge"
    )
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
    title:SetText("Bot Traits")

    local subtitle = frame:CreateFontString(
        nil, "OVERLAY", "GameFontHighlightSmall"
    )
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    subtitle:SetText(
        "Edit persistent bot traits and view"
        .. " generated tone"
    )

    createLabel(frame, "Known bots", 18, -70)

    local dropdown = CreateFrame(
        "Frame", "ChatterBotDropdown",
        frame, "UIDropDownMenuTemplate"
    )
    dropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -86)
    frame.dropdown = dropdown

    local refresh = CreateFrame(
        "Button", nil, frame, "UIPanelButtonTemplate"
    )
    refresh:SetWidth(80)
    refresh:SetHeight(24)
    refresh:SetPoint("LEFT", dropdown, "RIGHT", -10, 2)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", function()
        Chatter:RequestRoster()
    end)

    local forget = CreateFrame(
        "Button", nil, frame, "UIPanelButtonTemplate"
    )
    forget:SetWidth(70)
    forget:SetHeight(24)
    forget:SetPoint("LEFT", refresh, "RIGHT", 4, 0)
    forget:SetText("Forget")
    forget:SetScript("OnClick", function()
        Chatter:ConfirmForget()
    end)

    createLabel(frame, "Trait 1", 18, -126)
    frame.trait1 = createEditBox(frame, 18, -144, 435, 24)
    frame.trait1:SetMaxLetters(64)

    createLabel(frame, "Trait 2", 18, -174)
    frame.trait2 = createEditBox(frame, 18, -192, 435, 24)
    frame.trait2:SetMaxLetters(64)

    createLabel(frame, "Trait 3", 18, -222)
    frame.trait3 = createEditBox(frame, 18, -240, 435, 24)
    frame.trait3:SetMaxLetters(64)

    createLabel(frame, "Tone (generated)", 18, -280)
    frame.tone = createEditBox(frame, 18, -298, 435, 24)
    frame.tone:SetMaxLetters(120)
    frame.tone:SetScript("OnEditFocusGained", function(self)
        self:ClearFocus()
    end)

    createLabel(frame, "Background Story", 18, -360)
    frame.backstory = createMultiLineEditBox(
        frame, 18, -378, 435, 90
    )
    frame.backstory:SetMaxLetters(1000)
    frame.backstory:EnableMouse(false)
    frame.backstory:SetTextColor(0.7, 0.7, 0.7)

    local regenStory = CreateFrame(
        "Button", nil, frame, "UIPanelButtonTemplate"
    )
    regenStory:SetWidth(130)
    regenStory:SetHeight(22)
    regenStory:SetPoint(
        "TOPLEFT", frame, "TOPLEFT", 18, -476
    )
    regenStory:SetText("Regenerate Story")
    regenStory:SetScript("OnClick", function()
        Chatter:RegenBackstory()
    end)

    local status = frame:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall"
    )
    status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, 20)
    status:SetWidth(200)
    status:SetJustifyH("LEFT")
    status:SetText("")
    frame.status = status

    local closeButton = CreateFrame(
        "Button", nil, frame, "UIPanelButtonTemplate"
    )
    closeButton:SetWidth(90)
    closeButton:SetHeight(26)
    closeButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 14)
    closeButton:SetText("Close")
    closeButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    local save = CreateFrame(
        "Button", nil, frame, "UIPanelButtonTemplate"
    )
    save:SetWidth(120)
    save:SetHeight(26)
    save:SetPoint("RIGHT", closeButton, "LEFT", -10, 0)
    save:SetText("Save Traits")
    save:SetScript("OnClick", function()
        Chatter:SaveProfile()
    end)

    self.frame = frame
    self:RestoreWindowPosition()
    self:UpdateDropdown()
end

local function addCategory(panel)
    if type(InterfaceOptions_AddCategory) == "function" then
        InterfaceOptions_AddCategory(panel)
    elseif type(InterfaceOptionsFrame_AddCategory) == "function" then
        InterfaceOptionsFrame_AddCategory(panel)
    elseif type(INTERFACEOPTIONS_ADDONCATEGORIES) == "table" then
        table.insert(INTERFACEOPTIONS_ADDONCATEGORIES, panel)
    end
end

function Chatter:BuildOptionsPanel()
    if self.optionsPanel then
        return
    end

    -- Parent panel: overview and slash commands
    local parent = CreateFrame(
        "Frame",
        "ChatterOptionsPanel",
        UIParent
    )
    parent.name = "Chatter"
    parent:Hide()

    local title = parent:CreateFontString(
        nil, "ARTWORK", "GameFontNormalLarge"
    )
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Chatter")

    local desc = parent:CreateFontString(
        nil, "ARTWORK", "GameFontHighlight"
    )
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetText(
        "Ambient bot conversation module for"
        .. " mod-llm-chatter"
    )

    local slashHint = parent:CreateFontString(
        nil, "ARTWORK", "GameFontNormal"
    )
    slashHint:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    slashHint:SetText("Slash commands: /chatter or /llmc")

    addCategory(parent)
    self.optionsPanel = parent

    -- Child panel: Bot Traits editor
    local child = CreateFrame(
        "Frame",
        "ChatterTraitsPanel",
        UIParent
    )
    child.name = "Bot Traits"
    child.parent = "Chatter"
    child:Hide()

    local cTitle = child:CreateFontString(
        nil, "ARTWORK", "GameFontNormalLarge"
    )
    cTitle:SetPoint("TOPLEFT", 16, -16)
    cTitle:SetText("Bot Traits")

    local cDesc = child:CreateFontString(
        nil, "ARTWORK", "GameFontHighlightSmall"
    )
    cDesc:SetPoint("TOPLEFT", cTitle, "BOTTOMLEFT", 0, -6)
    cDesc:SetText(
        "Edit persistent bot traits and view"
        .. " generated tone"
    )

    createLabel(child, "Known bots", 18, -70)

    local dropdown = CreateFrame(
        "Frame",
        "ChatterOptBotDropdown",
        child,
        "UIDropDownMenuTemplate"
    )
    dropdown:SetPoint("TOPLEFT", child, "TOPLEFT", 4, -86)
    child.dropdown = dropdown

    local refresh = CreateFrame(
        "Button", nil, child, "UIPanelButtonTemplate"
    )
    refresh:SetWidth(80)
    refresh:SetHeight(24)
    refresh:SetPoint("LEFT", dropdown, "RIGHT", -10, 2)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", function()
        Chatter:RequestRoster()
    end)

    local cForget = CreateFrame(
        "Button", nil, child, "UIPanelButtonTemplate"
    )
    cForget:SetWidth(70)
    cForget:SetHeight(24)
    cForget:SetPoint("LEFT", refresh, "RIGHT", 4, 0)
    cForget:SetText("Forget")
    cForget:SetScript("OnClick", function()
        Chatter:ConfirmForget()
    end)

    createLabel(child, "Trait 1", 18, -126)
    child.trait1 = createEditBox(child, 18, -144, 435, 24)
    child.trait1:SetMaxLetters(64)

    createLabel(child, "Trait 2", 18, -174)
    child.trait2 = createEditBox(child, 18, -192, 435, 24)
    child.trait2:SetMaxLetters(64)

    createLabel(child, "Trait 3", 18, -222)
    child.trait3 = createEditBox(child, 18, -240, 435, 24)
    child.trait3:SetMaxLetters(64)

    createLabel(child, "Tone (generated)", 18, -280)
    child.tone = createEditBox(child, 18, -298, 435, 24)
    child.tone:SetMaxLetters(120)
    child.tone:SetScript("OnEditFocusGained", function(self)
        self:ClearFocus()
    end)

    createLabel(child, "Background Story", 18, -360)
    child.backstory = createMultiLineEditBox(
        child, 18, -378, 435, 90
    )
    child.backstory:SetMaxLetters(1000)
    child.backstory:EnableMouse(false)
    child.backstory:SetTextColor(0.7, 0.7, 0.7)

    local cRegenStory = CreateFrame(
        "Button", nil, child, "UIPanelButtonTemplate"
    )
    cRegenStory:SetWidth(130)
    cRegenStory:SetHeight(22)
    cRegenStory:SetPoint(
        "TOPLEFT", child, "TOPLEFT", 18, -476
    )
    cRegenStory:SetText("Regenerate Story")
    cRegenStory:SetScript("OnClick", function()
        Chatter:RegenBackstory()
    end)

    local status = child:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall"
    )
    status:SetPoint("TOPLEFT", child, "TOPLEFT", 18, -506)
    status:SetWidth(250)
    status:SetJustifyH("LEFT")
    status:SetText("")
    child.status = status

    local save = CreateFrame(
        "Button", nil, child, "UIPanelButtonTemplate"
    )
    save:SetWidth(120)
    save:SetHeight(26)
    save:SetPoint("TOPRIGHT", child, "TOPRIGHT", -18, -500)
    save:SetText("Save Traits")
    save:SetScript("OnClick", function()
        Chatter:SaveProfile()
    end)

    child:SetScript("OnShow", function()
        Chatter:RequestRoster()
    end)

    addCategory(child)
    self.traitsPanel = child
end

function Chatter:Toggle()
    self:BuildFrame()

    if self.frame:IsShown() then
        self.frame:Hide()
        return
    end

    self.frame:Show()
    self.frame:Raise()
    self:RequestRoster()
end

function Chatter:HandleRosterEntry(guidToken, nameToken)
    local guid = tonumber(guidToken)
    local name = self:Decode(nameToken)
    if not guid or name == "" then
        return
    end

    table.insert(self.pendingRoster, {
        guid = guid,
        name = name
    })
end

function Chatter:FinishRoster()
    self.roster = self.pendingRoster or {}
    self.pendingRoster = nil

    table.sort(self.roster, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)

    self:UpdateDropdown()

    if #self.roster == 0 then
        self.selectedGuid = nil
        local empty = {
            trait1 = "", trait2 = "", trait3 = "",
            tone = "", backstory = "",
        }
        self:ApplyProfileToPanel(self.frame, empty)
        self:ApplyProfileToPanel(self.traitsPanel, empty)
        self:SetStatus("No known bots yet.", 1, 0.82, 0)
        return
    end

    local preferredGuid = self.selectedGuid
    if not preferredGuid and ChatterDB then
        preferredGuid = ChatterDB.selectedGuid
    end

    local found = nil
    for _, bot in ipairs(self.roster) do
        if bot.guid == preferredGuid then
            found = bot.guid
            break
        end
    end

    if not found then
        found = self.roster[1].guid
    end

    self:SelectBot(found)
end

function Chatter:HandleProfilePayload(rest)
    -- Parse 6 fields: guid name t1 t2 t3 tone
    -- Backstory arrives as a separate BACKSTORY message
    local guid, name, trait1, trait2, trait3, tone =
        string.match(
            rest,
            "^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)"
            .. "%s+(%S+)%s+(%S+)$"
        )
    if not guid then
        return
    end

    self:ApplyProfile({
        guid = tonumber(guid),
        name = self:Decode(name),
        trait1 = self:Decode(trait1),
        trait2 = self:Decode(trait2),
        trait3 = self:Decode(trait3),
        tone = self:Decode(tone),
    })
end

function Chatter:HandleBackstoryPayload(rest)
    local guid, encoded = string.match(
        rest, "^(%d+)%s+(.+)$"
    )
    if not guid then
        return
    end

    local numGuid = tonumber(guid)
    local text = self:Decode(encoded or "-")

    -- Apply to whichever panels are open
    if self.frame and self.frame.backstory
        and self.selectedGuid == numGuid then
        self.frame.backstory:SetText(text)
    end
    if self.traitsPanel
        and self.traitsPanel.backstory
        and self.selectedGuid == numGuid then
        self.traitsPanel.backstory:SetText(text)
    end

    -- If we were polling for backstory, check
    -- if it arrived
    if self.pendingBackstoryGuid == numGuid then
        if text and text ~= "" then
            self:StopBackstoryPoll()
            -- Only show backstory status if tone
            -- poll is already done
            if not self.pendingToneGuid then
                self:SetStatus(
                    "Backstory generated.",
                    0.3, 1, 0.3
                )
            end
        end
    end
end

function Chatter:HandleSystemMessage(message)
    if not string.find(message, "^" .. self.prefix) then
        return
    end

    local payload = string.sub(message, string.len(self.prefix) + 1)
    local command, rest = string.match(payload, "^(%S+)%s*(.-)$")

    if command == "ROSTER_BEGIN" then
        self.pendingRoster = {}
        return
    end

    if command == "ROSTER" then
        local guid, name = string.match(rest, "^(%d+)%s+(%S+)$")
        if guid and name and self.pendingRoster then
            self:HandleRosterEntry(guid, name)
        end
        return
    end

    if command == "ROSTER_END" then
        self:FinishRoster()
        return
    end

    if command == "PROFILE" then
        self:HandleProfilePayload(rest)
        return
    end

    if command == "BACKSTORY" then
        self:HandleBackstoryPayload(rest)
        return
    end

    if command == "UPDATED" then
        local guid, name = string.match(rest, "^(%d+)%s+(%S+)$")
        if guid and name then
            self.selectedGuid = tonumber(guid)
            if self.frame and self.frame.tone then
                self.frame.tone:SetText("")
            end
            if self.traitsPanel and self.traitsPanel.tone then
                self.traitsPanel.tone:SetText("")
            end
            if self.frame and self.frame.backstory then
                self.frame.backstory:SetText("")
            end
            if self.traitsPanel
                and self.traitsPanel.backstory then
                self.traitsPanel.backstory:SetText("")
            end
            self:StartTonePoll(guid)
            self:StartBackstoryPoll(guid)
            self:SetStatus(
                "Saved traits for "
                    .. self:Decode(name)
                    .. ". Generating tone"
                    .. " and backstory...",
                1, 0.82, 0
            )
        end
        return
    end

    if command == "BACKSTORY_REGEN" then
        local guid, name = string.match(
            rest, "^(%d+)%s+(%S+)$"
        )
        if guid and name then
            self:SetStatus(
                "Regenerating backstory for "
                    .. self:Decode(name) .. "...",
                1, 0.82, 0
            )
        end
        return
    end

    if command == "FORGOTTEN" then
        local guid, name = string.match(
            rest, "^(%d+)%s+(%S+)$"
        )
        local displayName = guid and name
            and self:Decode(name) or "Bot"
        self:SetStatus(
            displayName .. " forgotten.",
            0.4, 1, 0.4
        )
        self.selectedGuid = nil
        local p = self:GetActivePanel()
        if p then
            self:ApplyProfileToPanel(p, {
                trait1 = "", trait2 = "",
                trait3 = "", tone = "",
                backstory = "",
            })
        end
        self:RequestRoster()
        return
    end

    if command == "ERROR" then
        local _, encoded = string.match(
            rest, "^(%S+)%s*(.-)$"
        )
        self:SetStatus(
            self:Decode(encoded), 1, 0.2, 0.2
        )
    end
end

local function chatterSystemFilter(_, _, message, ...)
    if type(message) == "string"
        and string.find(message, "^" .. Chatter.prefix) then
        Chatter:HandleSystemMessage(message)
        return true
    end
    return false
end

StaticPopupDialogs["CHATTER_CONFIRM_FORGET"] = {
    text = "Forget %s? Their memories with you will be erased. Their personality is preserved.",
    button1 = "Forget",
    button2 = "Cancel",
    OnAccept = function()
        Chatter:ForgetBot()
    end,
    timeout = 0,
    whileDead = false,
    hideOnEscape = true,
    preferredIndex = 3,
}

SLASH_CHATTER1 = "/chatter"
SLASH_CHATTER2 = "/llmc"
SlashCmdList["CHATTER"] = function()
    Chatter:Toggle()
end

Chatter:SetScript("OnUpdate", function(self, elapsed)
    self:HandleTonePoll(elapsed)
    self:HandleBackstoryPoll(elapsed)
end)

Chatter:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        ChatterDB = ChatterDB or {}
        self:BuildOptionsPanel()
        self:BuildFrame()
        ChatFrame_AddMessageEventFilter(
            "CHAT_MSG_SYSTEM",
            chatterSystemFilter
        )
    elseif event == "PLAYER_LOGOUT" then
        self:SaveWindowPosition()
    end
end)

Chatter:RegisterEvent("PLAYER_LOGIN")
Chatter:RegisterEvent("PLAYER_LOGOUT")




