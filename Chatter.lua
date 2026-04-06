local Chatter = CreateFrame("Frame", "ChatterEventFrame")

Chatter.prefix = "CHATTER_ADDON "
Chatter.roster = {}
Chatter.pendingRoster = nil
Chatter.selectedGuid = nil
Chatter.pendingProfileGuid = nil
Chatter.pendingToneGuid = nil
Chatter.tonePollElapsed = 0
Chatter.tonePollRemaining = 0

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

function Chatter:SetStatus(text, r, g, b)
    if not self.frame or not self.frame.status then
        return
    end

    self.frame.status:SetText(text or "")
    self.frame.status:SetTextColor(
        r or 1, g or 0.82, b or 0
    )
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

function Chatter:UpdateDropdown()
    local dropdown = self.frame and self.frame.dropdown
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

    UIDropDownMenu_SetWidth(dropdown, 215)

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

function Chatter:ApplyProfile(profile)
    if not self.frame then
        return
    end

    local awaitingTone = (
        self.pendingToneGuid == profile.guid
    )

    self.selectedGuid = profile.guid
    self.frame.nameValue:SetText(profile.name or "")
    self.frame.trait1:SetText(profile.trait1 or "")
    self.frame.trait2:SetText(profile.trait2 or "")
    self.frame.trait3:SetText(profile.trait3 or "")
    self.frame.tone:SetText(profile.tone or "")

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
            self:SetStatus("Generating tone...", 1, 0.82, 0)
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

    local trait1 = sanitizeInput(self.frame.trait1:GetText())
    local trait2 = sanitizeInput(self.frame.trait2:GetText())
    local trait3 = sanitizeInput(self.frame.trait3:GetText())

    self.frame.trait1:SetText(trait1)
    self.frame.trait2:SetText(trait2)
    self.frame.trait3:SetText(trait3)
    self.frame.tone:SetText("")

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

function Chatter:BuildFrame()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "ChatterMainFrame", UIParent)
    frame:SetWidth(430)
    frame:SetHeight(380)
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

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
    title:SetText("Chatter")

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    subtitle:SetText("Edit persistent bot traits and view generated tone")

    createLabel(frame, "Known bots", 18, -52)

    local dropdown = CreateFrame("Frame", "ChatterBotDropdown", frame, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -68)
    frame.dropdown = dropdown

    local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    refresh:SetWidth(80)
    refresh:SetHeight(24)
    refresh:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -64)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", function()
        Chatter:RequestRoster()
    end)

    createLabel(frame, "Bot name", 18, -108)
    local nameValue = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameValue:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -124)
    nameValue:SetWidth(385)
    nameValue:SetJustifyH("LEFT")
    nameValue:SetText("No bot selected")
    frame.nameValue = nameValue

    createLabel(frame, "Trait 1", 18, -150)
    frame.trait1 = createEditBox(frame, 18, -168, 385, 24)
    frame.trait1:SetMaxLetters(64)

    createLabel(frame, "Trait 2", 18, -198)
    frame.trait2 = createEditBox(frame, 18, -216, 385, 24)
    frame.trait2:SetMaxLetters(64)

    createLabel(frame, "Trait 3", 18, -246)
    frame.trait3 = createEditBox(frame, 18, -264, 385, 24)
    frame.trait3:SetMaxLetters(64)

    createLabel(frame, "Tone (generated)", 18, -294)
    frame.tone = createEditBox(frame, 18, -312, 385, 24)
    frame.tone:SetMaxLetters(120)
    frame.tone:SetScript("OnEditFocusGained", function(self)
        self:ClearFocus()
    end)

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    closeButton:SetWidth(90)
    closeButton:SetHeight(26)
    closeButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 16)
    closeButton:SetText("Close")
    closeButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    local save = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    save:SetWidth(120)
    save:SetHeight(26)
    save:SetPoint("RIGHT", closeButton, "LEFT", -10, 0)
    save:SetText("Save Changes")
    save:SetScript("OnClick", function()
        Chatter:SaveProfile()
    end)

    local status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, 22)
    status:SetWidth(270)
    status:SetJustifyH("LEFT")
    status:SetText("")
    frame.status = status

    self.frame = frame
    self:RestoreWindowPosition()
    self:UpdateDropdown()
end

function Chatter:BuildOptionsPanel()
    if self.optionsPanel then
        return
    end

    local panel = CreateFrame(
        "Frame",
        "ChatterOptionsPanel",
        UIParent
    )
    panel.name = "Chatter"
    panel:Hide()

    local title = panel:CreateFontString(
        nil,
        "ARTWORK",
        "GameFontNormalLarge"
    )
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Chatter")

    local subtitle = panel:CreateFontString(
        nil,
        "ARTWORK",
        "GameFontHighlightSmall"
    )
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetWidth(560)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText(
        "Edit persistent bot traits and view generated tone for bots "
        .. "you have grouped with before."
    )

    local slashHint = panel:CreateFontString(
        nil,
        "ARTWORK",
        "GameFontNormal"
    )
    slashHint:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -18)
    slashHint:SetText("Slash commands: /chatter or /llmc")

    local openButton = CreateFrame(
        "Button",
        nil,
        panel,
        "UIPanelButtonTemplate"
    )
    openButton:SetWidth(160)
    openButton:SetHeight(24)
    openButton:SetPoint("TOPLEFT", slashHint, "BOTTOMLEFT", 0, -16)
    openButton:SetText("Open Chatter")
    openButton:SetScript("OnClick", function()
        Chatter:BuildFrame()
        if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then
            HideUIPanel(InterfaceOptionsFrame)
        end
        if GameMenuFrame and GameMenuFrame:IsShown() then
            HideUIPanel(GameMenuFrame)
        end
        if not Chatter.frame:IsShown() then
            Chatter.frame:Show()
        end
        Chatter.frame:Raise()
        Chatter:RequestRoster()
    end)

    if type(InterfaceOptions_AddCategory) == "function" then
        InterfaceOptions_AddCategory(panel)
    elseif type(InterfaceOptionsFrame_AddCategory) == "function" then
        InterfaceOptionsFrame_AddCategory(panel)
    elseif type(INTERFACEOPTIONS_ADDONCATEGORIES) == "table" then
        table.insert(INTERFACEOPTIONS_ADDONCATEGORIES, panel)
    end

    self.optionsPanel = panel
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
        self.frame.nameValue:SetText("No known bots found")
        self.frame.trait1:SetText("")
        self.frame.trait2:SetText("")
        self.frame.trait3:SetText("")
        self.frame.tone:SetText("")
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
    local guid, name, trait1, trait2, trait3, tone =
        string.match(rest, "^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)$")
    if not guid then
        return
    end

    self:ApplyProfile({
        guid = tonumber(guid),
        name = self:Decode(name),
        trait1 = self:Decode(trait1),
        trait2 = self:Decode(trait2),
        trait3 = self:Decode(trait3),
        tone = self:Decode(tone)
    })
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

    if command == "UPDATED" then
        local guid, name = string.match(rest, "^(%d+)%s+(%S+)$")
        if guid and name then
            self.selectedGuid = tonumber(guid)
            self.frame.tone:SetText("")
            self:StartTonePoll(guid)
            self:SetStatus(
                "Saved traits for "
                    .. self:Decode(name)
                    .. ". Generating tone...",
                1, 0.82, 0
            )
        end
        return
    end

    if command == "ERROR" then
        local _, encoded = string.match(rest, "^(%S+)%s*(.-)$")
        self:SetStatus(self:Decode(encoded), 1, 0.2, 0.2)
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

SLASH_CHATTER1 = "/chatter"
SLASH_CHATTER2 = "/llmc"
SlashCmdList["CHATTER"] = function()
    Chatter:Toggle()
end

Chatter:SetScript("OnUpdate", function(self, elapsed)
    self:HandleTonePoll(elapsed)
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




