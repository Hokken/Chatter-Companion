-- Roster selection and acknowledged, paced memory deletion.
local Chatter = ChatterEventFrame
Chatter.checkedBots = {}

function Chatter:GetFilteredRoster(query)
    local result = {}
    query = string.lower(query or "")
    for _, bot in ipairs(self.roster) do
        if string.find(string.lower(bot.name), query, 1, true) then
            table.insert(result, bot)
        end
    end
    return result
end

function Chatter:UpdateRosterViews()
    local known = {}
    for _, bot in ipairs(self.roster) do known[bot.guid] = true end
    for guid in pairs(self.checkedBots) do
        if not known[guid] then self.checkedBots[guid] = nil end
    end
    if self.frame and self.frame.refreshList then
        self.frame.refreshList()
    end
    if self.traitsPanel and self.traitsPanel.refreshList then
        self.traitsPanel.refreshList()
    end
    if self.storiesPanel and self.storiesPanel.refreshList then
        self.storiesPanel.refreshList()
    end
end

function Chatter:ConfirmForget()
    if self.forgetQueue or self.pendingRoster then return end
    local targets, names = {}, {}
    for _, bot in ipairs(self.roster) do
        if self.checkedBots[bot.guid] then
            table.insert(targets, bot.guid)
            if #names < 6 then table.insert(names, bot.name) end
        end
    end
    if #targets == 0 then return end
    local description = table.concat(names, ", ")
    if #targets > #names then
        description = description .. " and " .. (#targets - #names)
            .. " more"
    end
    -- Popup owns this snapshot: later checkbox changes cannot retarget it.
    local popup = StaticPopup_Show("CHATTER_CONFIRM_FORGET",
        #targets, description)
    if popup then popup.data = targets end
end

function Chatter:StartForgetBatch(targets)
    if self.forgetQueue or not targets or #targets == 0 then return end
    -- Bots are about to be erased, so an unfinished save for
    -- one of them has nothing left to save to.
    self.unsavedTraits = nil
    if self.uploadGuid then self:AbortUpload() end
    self:StopTonePoll()
    self:StopBackstoryPoll()
    self.pendingProfileGuid = nil
    self.loadedTraits = nil
    self:SetSaveEnabled(false)
    self:SetRegenStoryEnabled(false)
    self.forgetQueue = targets
    self.forgetIndex = 1
    self.forgetDone = 0
    self.forgetElapsed = 0
    self.forgetWaiting = nil
    self:UpdateRosterViews()
    self:SetStatus("Forgetting selected bots...", 1, 0.82, 0)
end

function Chatter:HandleForgetQueue(elapsed)
    if not self.forgetQueue then return end
    self.forgetElapsed = self.forgetElapsed + elapsed
    if self.forgetWaiting then
        if self.forgetElapsed >= 10 then
            self:FinishForgetBatch("No server reply. Use Refresh before retrying.")
        end
        return
    end
    if self.forgetElapsed < 0.3 then return end
    self.forgetElapsed = 0
    self.forgetWaiting = self.forgetQueue[self.forgetIndex]
    self:SendCommand("forget " .. self.forgetWaiting)
end

function Chatter:HandleForgotten(guid)
    if not guid then return end
    -- Duplicate or delayed acknowledgements must not advance the batch.
    if self.forgetQueue and guid ~= self.forgetWaiting then return end
    for i = #self.roster, 1, -1 do
        if self.roster[i].guid == guid then table.remove(self.roster, i) end
    end
    self.checkedBots[guid] = nil
    if self.selectedGuid == guid then
        self.selectedGuid = nil
        ChatterDB.selectedGuid = nil
        self.loadedTraits = nil
        self.pendingProfileGuid = nil
        self.unsavedTraits = nil
        self:ApplyProfileToPanel(self.frame, {})
        self:ApplyProfileToPanel(self.traitsPanel, {})
        self:ApplyProfileToPanel(self.storiesPanel, {})
    end
    if not self.forgetQueue then
        self:RequestRoster()
        return
    end
    self.forgetDone = self.forgetDone + 1
    self.forgetIndex = self.forgetIndex + 1
    self.forgetWaiting = nil
    self.forgetElapsed = 0
    self:UpdateRosterViews()
    if self.forgetIndex > #self.forgetQueue then
        self:FinishForgetBatch()
    else
        self:SetStatus("Forgot " .. self.forgetDone .. "/"
            .. #self.forgetQueue .. " bots...", 1, 0.82, 0)
    end
end

function Chatter:FinishForgetBatch(reason)
    local done = self.forgetDone or 0
    self.forgetQueue = nil
    self.forgetWaiting = nil
    self:UpdateRosterViews()
    self:RequestRoster()
    local message = "Forgot " .. done .. " bot(s)."
    if reason then message = message .. " " .. reason end
    self:SetStatus(message, reason and 1 or 0.3,
        reason and 0.4 or 1, 0.3)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Chatter:|r " .. message)
end

StaticPopupDialogs["CHATTER_CONFIRM_FORGET"] = {
    text = "Forget %d bot(s)?\n%s\n\nTheir memories with you will be erased."
        .. " Their personalities are preserved.",
    button1 = "Forget",
    button2 = "Cancel",
    OnAccept = function(self)
        Chatter:StartForgetBatch(self.data)
    end,
    timeout = 0,
    whileDead = false,
    hideOnEscape = true,
    preferredIndex = 3,
}
