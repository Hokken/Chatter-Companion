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
Chatter.sendQueue = {}
Chatter.sendElapsed = 0
Chatter.saveLocked = false
Chatter.saveLockRemaining = 0
Chatter.uploadGuid = nil
-- nil, "sending" while commands are still leaving the queue,
-- "awaiting" once the last one is out and only the server's
-- answer is outstanding. Sending a commit and having it
-- applied are separate things, and the difference decides
-- when a timeout is meaningful.
Chatter.uploadState = nil
-- What the player typed for the bot being saved. Kept until
-- the server confirms the save so a rejection or a timeout
-- can hand the edit back instead of losing it.
Chatter.unsavedTraits = nil

-- The client cuts an outgoing chat line at 255 characters.
local MAX_CHAT_LENGTH = 255
-- Longest percent-encoded payload carried by one `put`.
local CHUNK_BUDGET = 200
-- One message per interval keeps the upload clear of chat
-- flood protection.
local SEND_INTERVAL = 0.3
-- How long to wait for the server's answer once the whole
-- upload has been sent. It deliberately does not cover the
-- upload itself, which is paced at SEND_INTERVAL and takes as
-- long as it takes: a clock started earlier would be racing
-- the send queue rather than measuring the server.
local SAVE_LOCK_TIMEOUT = 20

local function trim(value)
    if not value then
        return ""
    end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Counts UTF-8 characters, matching SetMaxLetters on the
-- edit boxes and the VARCHAR(64) columns on the server.
-- Continuation bytes are 0x80-0xBF and are not counted.
local function utf8len(value)
    local _, count = string.gsub(value or "", "[^\128-\191]", "")
    return count
end

local function sanitizeInput(value)
    value = trim(value or "")
    value = value:gsub("[%c]", " ")
    value = value:gsub("%s+", " ")
    return trim(value)
end

-- The client replaces %f (focus name) and %t (target name) in
-- every outgoing chat line, case-insensitively, so an escape
-- must never read %F. Bytes 0xF0-0xFF, which only occur in
-- 4-byte UTF-8 characters, are written as ~FX instead, and ~
-- itself is always escaped so it can only start one of those.
function Chatter:Encode(value)
    value = sanitizeInput(value)
    if value == "" then
        return "-"
    end

    return (value:gsub("([^%w%-_%.])", function(char)
        local byte = string.byte(char)
        if byte >= 0xF0 then
            return string.format("~%02X", byte)
        end
        return string.format("%%%02X", byte)
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
    if self.storiesPanel then
        table.insert(panels, self.storiesPanel)
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

function Chatter:QueueCommand(command)
    table.insert(self.sendQueue, command)
end

function Chatter:FlushSendQueue()
    self.sendQueue = {}
    self.sendElapsed = 0
end

function Chatter:HandleSendQueue(elapsed)
    if #self.sendQueue == 0 then
        return
    end

    self.sendElapsed = self.sendElapsed + elapsed
    if self.sendElapsed < SEND_INTERVAL then
        return
    end

    self.sendElapsed = 0
    self:SendCommand(table.remove(self.sendQueue, 1))

    if #self.sendQueue == 0 and self.uploadState == "sending" then
        -- The commit has left, but the server has not said
        -- what it did with it. The upload stays open until it
        -- answers; only the wait for that answer is timed.
        self:BeginConfirmWait()
    end
end

-- Splits an encoded value on a character budget without ever
-- cutting a %XX or ~FX escape in half.
local function startsEscape(char)
    return char == "%" or char == "~"
end

function Chatter:SplitEncoded(encoded, budget)
    local chunks = {}
    local total = string.len(encoded)
    local pos = 1

    while pos <= total do
        local stop = pos + budget - 1
        if stop >= total then
            stop = total
        elseif startsEscape(string.sub(encoded, stop, stop)) then
            stop = stop - 1
        elseif startsEscape(string.sub(encoded, stop - 1, stop - 1)) then
            stop = stop - 2
        end

        if stop < pos then
            return nil
        end

        table.insert(chunks, string.sub(encoded, pos, stop))
        pos = stop + 1
    end

    return chunks
end

function Chatter:LockSave()
    self.saveLocked = true
    self.saveLockRemaining = 0
    self:SetSaveEnabled(false)
end

-- The whole upload is out on the wire, so from here on
-- silence is the server failing to answer rather than the
-- queue still working through its chunks.
function Chatter:BeginConfirmWait()
    self.uploadState = "awaiting"
    self.saveLockRemaining = SAVE_LOCK_TIMEOUT
end

function Chatter:UnlockSave()
    self.saveLocked = false
    self.saveLockRemaining = 0
    self:UpdateSaveButton()
end

function Chatter:HandleSaveLock(elapsed)
    if not self.saveLocked or self.uploadState ~= "awaiting" then
        return
    end

    self.saveLockRemaining = self.saveLockRemaining - elapsed
    if self.saveLockRemaining <= 0 then
        self:AbortUpload(
            "The server did not answer. Your traits are"
                .. " still here — save again to retry.",
            1, 0.82, 0
        )
    end
end

-- Ends an upload that will not complete, whether the server
-- rejected it, never answered, or the player moved on.
-- Everything belonging to it goes at once: a queue left
-- draining would still send `commit` for an abandoned edit,
-- and a poll left running would pull the pre-save profile
-- back over the boxes.
function Chatter:AbortUpload(message, r, g, b)
    if self.uploadGuid then
        self:FlushSendQueue()
        -- Ignored by the server when it holds nothing staged,
        -- so it is safe from every abort path.
        self:SendCommand("cancel " .. self.uploadGuid)
    end
    self.uploadGuid = nil
    self.uploadState = nil
    self:StopTonePoll()
    self:StopBackstoryPoll()
    self:RestoreUnsavedTraits()
    self:UnlockSave()
    if message then
        self:SetStatus(message, r, g, b)
    end
end

-- Puts the traits the player typed back into both editors so
-- an abandoned save can be corrected and retried rather than
-- silently reverting to what the server still holds.
function Chatter:RestoreUnsavedTraits()
    local t = self.unsavedTraits
    if not t or t.guid ~= self.selectedGuid then
        return
    end

    local function apply(p)
        if not p then return end
        if p.trait1 then p.trait1:SetText(t.trait1 or "") end
        if p.trait2 then p.trait2:SetText(t.trait2 or "") end
        if p.trait3 then p.trait3:SetText(t.trait3 or "") end
    end
    apply(self.frame)
    apply(self.traitsPanel)
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
    self.tonePollRemaining = 120

    local function applyPlaceholder(panel)
        if not panel then return end
        if panel.tone then
            panel.tone:SetTextColor(0.5, 0.5, 0.5)
            panel.tone:SetText("Generating tone...")
        end
    end
    applyPlaceholder(self.frame)
    applyPlaceholder(self.traitsPanel)
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

function Chatter:SetRegenStoryEnabled(enabled)
    local function apply(p)
        if not p or not p.regenStoryBtn then
            return
        end
        if enabled then
            p.regenStoryBtn:Enable()
        else
            p.regenStoryBtn:Disable()
        end
    end
    apply(self.frame)
    apply(self.traitsPanel)
    apply(self.storiesPanel)
end

function Chatter:SetSaveEnabled(enabled)
    local function apply(p)
        if not p or not p.saveBtn then return end
        if enabled then
            p.saveBtn:Enable()
        else
            p.saveBtn:Disable()
        end
    end
    apply(self.frame)
    apply(self.traitsPanel)
end

function Chatter:UpdateSaveButton()
    if self.saveLocked then
        self:SetSaveEnabled(false)
        return
    end

    local loaded = self.loadedTraits
    if not loaded or self.pendingProfileGuid or self.forgetQueue then
        self:SetSaveEnabled(false)
        return
    end
    local p = self:GetActivePanel()
    if not p then
        self:SetSaveEnabled(false)
        return
    end
    local t1 = sanitizeInput(
        p.trait1 and p.trait1:GetText() or ""
    )
    local t2 = sanitizeInput(
        p.trait2 and p.trait2:GetText() or ""
    )
    local t3 = sanitizeInput(
        p.trait3 and p.trait3:GetText() or ""
    )
    local changed = (
        t1 ~= (loaded.trait1 or "")
        or t2 ~= (loaded.trait2 or "")
        or t3 ~= (loaded.trait3 or "")
    )
    self:SetSaveEnabled(changed)
end

function Chatter:StopBackstoryPoll()
    self.pendingBackstoryGuid = nil
    self.backstoryPollElapsed = 0
    self.backstoryPollRemaining = 0
    self:SetRegenStoryEnabled(true)
end

function Chatter:StartBackstoryPoll(guid)
    guid = tonumber(guid)
    if not guid then
        return
    end

    self.pendingBackstoryGuid = guid
    self.backstoryPollElapsed = 0
    self.backstoryPollRemaining = 120

    self:SetRegenStoryEnabled(false)

    -- Show placeholder in the backstory box
    local placeholder = "Creating background story..."
    if self.frame and self.frame.backstory then
        self.frame.backstory:SetText(placeholder)
        self.frame.backstory:SetTextColor(
            0.5, 0.5, 0.5
        )
    end
    if self.storiesPanel
        and self.storiesPanel.backstory then
        self.storiesPanel.backstory:SetText(
            placeholder
        )
        self.storiesPanel.backstory:SetTextColor(
            0.5, 0.5, 0.5
        )
    end
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

-- `keepTraits` leaves the three trait boxes alone while still
-- refreshing tone and backstory, for profiles that arrive
-- when the player has edits the server has not accepted yet.
function Chatter:ApplyProfileToPanel(p, profile, keepTraits)
    if not p then
        return
    end
    if p.trait1 and not keepTraits then
        p.trait1:SetText(profile.trait1 or "")
    end
    if p.trait2 and not keepTraits then
        p.trait2:SetText(profile.trait2 or "")
    end
    if p.trait3 and not keepTraits then
        p.trait3:SetText(profile.trait3 or "")
    end
    if p.tone then
        local toneText = profile.tone or ""
        -- Only overwrite if not currently showing
        -- a live placeholder (poll in progress)
        local polling = (
            self.pendingToneGuid
            and self.pendingToneGuid == profile.guid
        )
        if not polling or toneText ~= "" then
            p.tone:SetText(toneText)
            p.tone:SetTextColor(0.7, 0.7, 0.7)
        end
    end
    if p.backstory then
        local bsText = profile.backstory or ""
        -- Only overwrite if not currently showing
        -- a live placeholder (poll in progress)
        local polling = (
            self.pendingBackstoryGuid
            and self.pendingBackstoryGuid == profile.guid
        )
        if not polling or bsText ~= "" then
            p.backstory:SetText(bsText)
            p.backstory:SetTextColor(0.7, 0.7, 0.7)
        end
    end
end

function Chatter:ApplyProfile(profile)
    if profile.guid ~= self.selectedGuid or self.forgetQueue then
        return
    end
    -- Everything the server sends while an upload is open
    -- still describes the pre-save bot, down to the tone that
    -- is about to be regenerated, so none of it is applied.
    if self.uploadState and self.uploadGuid == profile.guid then
        return
    end
    -- Once the upload is over but the edit was never accepted
    -- — rejected, timed out — a late reply may still refresh
    -- tone and backstory, but the trait boxes belong to the
    -- player until they save successfully or pick another bot.
    local keepTraits = (
        self.unsavedTraits ~= nil
        and self.unsavedTraits.guid == profile.guid
    )
    self.pendingProfileGuid = nil
    self:SetRegenStoryEnabled(not self.pendingBackstoryGuid)
    local awaitingTone = (
        self.pendingToneGuid == profile.guid
    )
    self.selectedGuid = profile.guid

    -- Store loaded traits for change detection
    self.loadedTraits = {
        trait1 = profile.trait1 or "",
        trait2 = profile.trait2 or "",
        trait3 = profile.trait3 or "",
    }

    self:ApplyProfileToPanel(self.frame, profile, keepTraits)
    self:ApplyProfileToPanel(
        self.traitsPanel, profile, keepTraits
    )
    self:ApplyProfileToPanel(
        self.storiesPanel, profile, keepTraits
    )

    if keepTraits then
        -- The boxes still hold an edit the server never took,
        -- so Save has to stay available to retry it.
        self:UpdateSaveButton()
    else
        -- Traits just loaded — no unsaved changes yet
        self:SetSaveEnabled(false)
    end

    ChatterDB = ChatterDB or {}
    ChatterDB.selectedGuid = profile.guid

    self:UpdateRosterViews()
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
    if self.forgetQueue then return end
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

    -- An edit belongs to the bot it was written for, so
    -- moving to a different one drops it rather than carrying
    -- it across, and leaves nothing half-staged behind.
    if self.unsavedTraits and self.unsavedTraits.guid ~= guid then
        self.unsavedTraits = nil
    end
    if self.uploadGuid and self.uploadGuid ~= guid then
        self:AbortUpload()
    end

    self.selectedGuid = guid
    self.pendingProfileGuid = guid
    self.loadedTraits = nil
    self:SetSaveEnabled(false)
    self:SetRegenStoryEnabled(false)
    local empty = {trait1 = "", trait2 = "", trait3 = "",
        tone = "", backstory = ""}
    self:ApplyProfileToPanel(self.frame, empty)
    self:ApplyProfileToPanel(self.traitsPanel, empty)
    self:ApplyProfileToPanel(self.storiesPanel, empty)
    self:UpdateRosterViews()
    self:SetStatus("Loading bot profile...", 1, 0.82, 0)
    self:SendCommand("get " .. guid)
end

function Chatter:RequestRoster()
    if self.forgetQueue or self.pendingRoster then return end
    self.pendingRoster = {}
    self.rosterElapsed = 0
    self:UpdateRosterViews()
    self:SetStatus("Requesting roster...", 1, 0.82, 0)
    self:SendCommand("roster")
end

function Chatter:SaveProfile()
    if self.pendingProfileGuid or self.forgetQueue then return end
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

    if trait1 == "" or trait2 == "" or trait3 == "" then
        self:SetStatus("All three traits are required.", 1, 0.2, 0.2)
        return
    end

    if utf8len(trait1) > 64 or utf8len(trait2) > 64
        or utf8len(trait3) > 64 then
        self:SetStatus("Traits must stay under 64 characters.", 1, 0.2, 0.2)
        return
    end

    -- Store pending traits for use after confirm
    self.pendingTraits = {
        guid = self.selectedGuid,
        trait1 = trait1,
        trait2 = trait2,
        trait3 = trait3,
    }

    local loaded = self.loadedTraits or {}
    local changed = (
        trait1 ~= (loaded.trait1 or "")
        or trait2 ~= (loaded.trait2 or "")
        or trait3 ~= (loaded.trait3 or "")
    )

    if changed then
        StaticPopup_Show(
            "CHATTER_CONFIRM_SAVE_TRAITS"
        )
    else
        -- Nothing changed — no server round-trip
        self:SetStatus(
            "Traits unchanged.", 0.3, 1, 0.3
        )
    end
end

-- Uploads the traits one `put` per chunk, then commits.
-- Returns false if a trait somehow refuses to split.
function Chatter:QueueChunkedSave(guid, t)
    local fields = {
        { "t1", t.trait1 },
        { "t2", t.trait2 },
        { "t3", t.trait3 },
    }

    local queued = {}
    for _, field in ipairs(fields) do
        local chunks = self:SplitEncoded(
            self:Encode(field[2]), CHUNK_BUDGET
        )
        if not chunks then
            return false
        end
        for i = 1, #chunks do
            table.insert(queued, string.format(
                "put %d %s %d %d %s",
                guid, field[1], i, #chunks, chunks[i]
            ))
        end
    end

    for _, command in ipairs(queued) do
        self:QueueCommand(command)
    end
    self:QueueCommand(string.format("commit %d", guid))
    self.uploadGuid = guid
    self.uploadState = "sending"
    return true
end

function Chatter:DoSaveProfile()
    local t = self.pendingTraits
    if not t or t.guid ~= self.selectedGuid
        or self.pendingProfileGuid or self.forgetQueue then
        return
    end

    local guid = self.selectedGuid
    self:StopTonePoll()
    self:StopBackstoryPoll()
    self:FlushSendQueue()

    local line = string.format(
        "set %d %s %s %s",
        guid,
        self:Encode(t.trait1),
        self:Encode(t.trait2),
        self:Encode(t.trait3)
    )

    -- Remember what the player typed before anything can
    -- overwrite the boxes: until the server confirms the save
    -- this is the only copy of the edit that exists.
    self.unsavedTraits = {
        guid = guid,
        trait1 = t.trait1,
        trait2 = t.trait2,
        trait3 = t.trait3,
    }
    self.pendingTraits = nil

    if string.len(".llmc " .. line) <= MAX_CHAT_LENGTH then
        self.uploadGuid = guid
        self.uploadState = "sending"
        self:SendCommand(line)
        self:LockSave()
        -- A single line is already gone, so the wait for the
        -- answer starts immediately.
        self:BeginConfirmWait()
    elseif self:QueueChunkedSave(guid, t) then
        self:LockSave()
    else
        self.unsavedTraits = nil
        self:SetStatus(
            "Could not send these traits.", 1, 0.2, 0.2
        )
        return
    end

    -- Start polls immediately so placeholders appear
    -- without waiting for the server round-trip
    self:StartTonePoll(guid)
    self:StartBackstoryPoll(guid)
    self:SetStatus(
        "Saving traits and regenerating tone"
            .. " and backstory...",
        1, 0.82, 0
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
            return entry.name
        end
    end
    return nil
end

function Chatter:RegenBackstory()
    if self.pendingProfileGuid or self.forgetQueue then return end
    if not self.selectedGuid then
        self:SetStatus("Select a bot first.", 1, 0.2, 0.2)
        return
    end

    local guid = self.selectedGuid
    self:StopBackstoryPoll()
    self:SendCommand("regenbackstory " .. guid)
    self:StartBackstoryPoll(guid)
    self:SetStatus(
        "Regenerating backstory...", 1, 0.82, 0
    )
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

    self:UpdateRosterViews()

    if #self.roster == 0 then
        self.selectedGuid = nil
        self.pendingProfileGuid = nil
        self.loadedTraits = nil
        ChatterDB.selectedGuid = nil
        self:StopTonePoll()
        self:StopBackstoryPoll()
        self:SetSaveEnabled(false)
        self:SetRegenStoryEnabled(false)
        self:UpdateRosterViews()
        local empty = {
            trait1 = "", trait2 = "", trait3 = "",
            tone = "", backstory = "",
        }
        self:ApplyProfileToPanel(self.frame, empty)
        self:ApplyProfileToPanel(self.traitsPanel, empty)
        self:ApplyProfileToPanel(self.storiesPanel, empty)
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

    -- Stale while an upload is still open: this is the story
    -- the save is about to replace or regenerate.
    if self.uploadState and self.uploadGuid == numGuid then
        return
    end

    -- Only apply non-empty backstory to boxes;
    -- empty means still generating — preserve
    -- the "Creating background story..." placeholder
    if text and text ~= ""
        and self.selectedGuid == numGuid then
        if self.frame and self.frame.backstory then
            self.frame.backstory:SetText(text)
            self.frame.backstory:SetTextColor(
                0.7, 0.7, 0.7
            )
        end
        if self.storiesPanel
            and self.storiesPanel.backstory then
            self.storiesPanel.backstory:SetText(text)
            self.storiesPanel.backstory:SetTextColor(
                0.7, 0.7, 0.7
            )
        end
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
        local guid, name, flag = string.match(
            rest, "^(%d+)%s+(%S+)%s+(%S+)"
        )
        if guid and name and tonumber(guid) == self.selectedGuid
            and not self.forgetQueue then
            self.selectedGuid = tonumber(guid)
            -- The server applied the edit. Only now is the
            -- upload over and the typed text the saved text.
            self:FlushSendQueue()
            self.uploadGuid = nil
            self.uploadState = nil
            self.unsavedTraits = nil
            self:UnlockSave()
            local changed = (flag == "changed")
            if changed then
                -- Polls were started in DoSaveProfile;
                -- restart here to reset the 120s clock
                -- now that the server confirmed the save
                self:StartTonePoll(guid)
                self:StartBackstoryPoll(guid)
                self:SetStatus(
                    "Saved. Regenerating tone"
                        .. " and backstory...",
                    1, 0.82, 0
                )
            else
                self:StopTonePoll()
                self:StopBackstoryPoll()
                self:SetStatus(
                    "Traits saved for "
                        .. self:Decode(name) .. ".",
                    0.3, 1, 0.3
                )
                -- Reload profile to restore
                -- tone/backstory after optimistic polls
                self:SendCommand(
                    "get " .. tonumber(guid)
                )
            end
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
        self:HandleForgotten(tonumber(string.match(rest, "^(%d+)%s")))
        return
    end

    if command == "ERROR" then
        if self.forgetQueue then
            self:FinishForgetBatch("Stopped: " .. self:Decode(
                string.match(rest, "^%S+%s*(.-)$") or rest))
            return
        end
        self.pendingRoster = nil
        local _, encoded = string.match(
            rest, "^(%S+)%s*(.-)$"
        )
        local text = self:Decode(encoded)
        if self.uploadState then
            -- The rejection belongs to the save in flight, so
            -- the whole save ends here — queue, polls and all
            -- — with the player's traits handed back.
            self:AbortUpload(text, 1, 0.2, 0.2)
        else
            self:UnlockSave()
            self:SetStatus(text, 1, 0.2, 0.2)
        end
    end
end

local function chatterSystemFilter(_, _, message, ...)
    if type(message) == "string"
        and string.find(message, "^" .. Chatter.prefix) then
        return true
    end
    return false
end

StaticPopupDialogs["CHATTER_CONFIRM_SAVE_TRAITS"] = {
    text = "These traits are different from the saved ones. Saving will regenerate this bot's tone and background story. Continue?",
    button1 = "Save",
    button2 = "Cancel",
    OnAccept = function()
        Chatter:DoSaveProfile()
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
    self:HandleSendQueue(elapsed)
    self:HandleSaveLock(elapsed)
    if self.pendingRoster then
        self.rosterElapsed = (self.rosterElapsed or 0) + elapsed
        if self.rosterElapsed >= 10 then
            self.pendingRoster = nil
            self:UpdateRosterViews()
            self:SetStatus("Roster request timed out. Use Refresh.", 1, 0.4, 0.3)
        end
    end
    self:HandleForgetQueue(elapsed)
    self:HandleTonePoll(elapsed)
    self:HandleBackstoryPoll(elapsed)
end)

Chatter:SetScript("OnEvent", function(self, event, message)
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
    elseif event == "CHAT_MSG_SYSTEM" then
        -- Filters run once per chat window; process each response only once.
        self:HandleSystemMessage(message)
    end
end)

Chatter:RegisterEvent("PLAYER_LOGIN")
Chatter:RegisterEvent("PLAYER_LOGOUT")
Chatter:RegisterEvent("CHAT_MSG_SYSTEM")
