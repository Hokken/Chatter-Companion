-- Regression coverage for the trait upload lifecycle: what
-- happens to a save the server rejects, never answers, or
-- that the player walks away from mid-flight.
--
-- The rule these all check is that an edit is never lost
-- silently. Until the server says it applied the traits, the
-- text the player typed stays in the boxes and Save stays
-- available, and nothing belonging to the abandoned upload
-- keeps running behind it.

local stub = require("wow_stub")

-- Set by the runner, which knows where the addon lives.
local ROOT = "."
local GUID = 7
local BASE = {"steady", "wry", "loyal"}

local tests = {}

local function check(condition, message)
    if not condition then
        error(message, 2)
    end
end

local function checkEqual(actual, expected, label)
    if actual ~= expected then
        error(string.format(
            "%s: expected %s, got %s",
            label, tostring(expected), tostring(actual)
        ), 2)
    end
end

local function traitTexts(panel)
    return {
        panel.trait1:GetText(),
        panel.trait2:GetText(),
        panel.trait3:GetText(),
    }
end

-- Both editors that carry traits are checked every time. The
-- Background Stories section has no trait boxes at all, which
-- is asserted here rather than assumed.
local function checkTraits(C, expected, label)
    for _, panel in ipairs({C.frame, C.traitsPanel}) do
        local actual = traitTexts(panel)
        for i = 1, 3 do
            checkEqual(
                actual[i], expected[i],
                label .. " trait" .. i
            )
        end
    end
    check(
        C.storiesPanel.trait1 == nil,
        "the stories section should hold no traits"
    )
end

-- Status text reaches every open section, so the player sees
-- the same explanation wherever they are.
local function checkStatusEverywhere(C, expected, label)
    for _, name in ipairs({"frame", "traitsPanel", "storiesPanel"}) do
        checkEqual(
            C[name].status:GetText(), expected,
            label .. " status on " .. name
        )
    end
end

-- Percent-encoding makes each space three characters, so
-- three traits of this length no longer fit in one 255
-- character chat line and have to go up as chunks.
local function longTrait(word)
    local filler = string.rep(word .. " ", 30)
    return (filler:sub(1, 60):gsub("%s+$", ""))
end

local function profileLine(C, traits, tone)
    return string.format(
        "PROFILE %d %s %s %s %s %s",
        GUID, C:Encode("Testbot"),
        C:Encode(traits[1]), C:Encode(traits[2]),
        C:Encode(traits[3]), C:Encode(tone or "dry")
    )
end

-- A bot picked from the roster with its saved profile loaded.
local function loadedBot()
    local C = stub.load(ROOT)
    C.roster = {{guid = GUID, name = "Testbot"}}
    C:SelectBot(GUID)
    stub.serverSays(C, profileLine(C, BASE))
    checkTraits(C, BASE, "profile load")
    stub.clearSent()
    return C
end

local function typeTraits(C, traits)
    for i = 1, 3 do
        C.frame["trait" .. i]:SetText(traits[i])
        C.traitsPanel["trait" .. i]:SetText(traits[i])
    end
end

-- Types new traits and confirms the save dialog, leaving the
-- upload in flight.
local function startSave(C, traits)
    typeTraits(C, traits)
    C:SaveProfile()
    checkEqual(
        stub.popups[#stub.popups],
        "CHATTER_CONFIRM_SAVE_TRAITS",
        "changed traits should ask for confirmation"
    )
    C:DoSaveProfile()
end

local function startChunkedSave(C)
    local edited = {
        longTrait("one"), longTrait("two"), longTrait("six"),
    }
    startSave(C, edited)
    -- Queued rather than sent: the chunks leave one at a time
    -- so the upload stays clear of chat flood protection.
    check(
        C.sendQueue[1] ~= nil
            and C.sendQueue[1]:sub(1, 4) == "put ",
        "these traits should have gone up as chunks"
    )
    return edited
end

-- Everything an abandoned upload must leave behind.
local function checkUploadClosed(C, label)
    checkEqual(C.uploadGuid, nil, label .. " uploadGuid")
    checkEqual(C.uploadState, nil, label .. " uploadState")
    checkEqual(#C.sendQueue, 0, label .. " queued commands")
    checkEqual(
        C.pendingToneGuid, nil, label .. " tone poll"
    )
    checkEqual(
        C.pendingBackstoryGuid, nil,
        label .. " backstory poll"
    )
    checkEqual(C.saveLocked, false, label .. " save lock")
end

-- The server rejects a chunk part way through the upload.
-- The rest of the upload has to stop, and the edit has to
-- survive so it can be corrected.
tests["rejection mid-upload keeps the edit"] = function()
    local C = loadedBot()
    local edited = startChunkedSave(C)

    stub.advance(C, 0.35)
    check(#C.sendQueue > 0, "upload should still be draining")
    stub.clearSent()

    stub.serverSays(
        C,
        "ERROR chunk " .. C:Encode("Chunk is too long")
    )

    checkUploadClosed(C, "after rejection")
    checkEqual(
        stub.sentCommand("cancel "), "cancel " .. GUID,
        "the rejected upload should be cancelled server-side"
    )
    checkTraits(C, edited, "after rejection")
    checkEqual(
        C.frame.saveBtn.enabled, true,
        "Save should be available to retry"
    )
    checkStatusEverywhere(
        C, "Chunk is too long", "after rejection"
    )
end

-- The reviewer's case: the rejection arrives, and then a
-- reply to a `get` that was already in flight turns up
-- carrying the pre-save traits. It must not overwrite the
-- boxes the player is still holding.
tests["a late profile cannot revert a rejected edit"] = function()
    local C = loadedBot()
    local edited = startChunkedSave(C)

    stub.advance(C, 2)
    checkEqual(
        #C.sendQueue, 0,
        "the whole upload should have been sent"
    )

    stub.serverSays(
        C,
        "ERROR validation " .. C:Encode("Trait 2 is too long")
    )
    checkTraits(C, edited, "after rejection")

    stub.serverSays(C, profileLine(C, BASE, "brisk"))

    checkTraits(C, edited, "after the late profile")
    checkEqual(
        C.frame.tone:GetText(), "brisk",
        "tone from the server is still worth showing"
    )
    checkEqual(
        C.frame.saveBtn.enabled, true,
        "Save should still be available"
    )
end

-- An older server does not know `put` and answers with its
-- usage error. That is a rejection like any other, and the
-- player's work has to be recoverable from it.
tests["an unsupported server leaves the edit recoverable"] = function()
    local C = loadedBot()
    local edited = startChunkedSave(C)

    stub.serverSays(
        C,
        "ERROR usage " .. C:Encode(
            "Supported commands: roster, get, set, forget"
        )
    )

    checkUploadClosed(C, "after usage error")
    checkTraits(C, edited, "after usage error")
    checkEqual(
        C.frame.saveBtn.enabled, true,
        "Save should be available to retry"
    )
end

-- The upload goes out in full and the server says nothing.
-- The timeout has to end the upload, not just re-enable the
-- button while the rest of it carries on.
tests["a silent server times out into a clean state"] = function()
    local C = loadedBot()
    local edited = startChunkedSave(C)

    stub.advance(C, 2)
    checkEqual(
        #C.sendQueue, 0,
        "the whole upload should have been sent"
    )
    stub.clearSent()

    stub.advance(C, 21)

    checkUploadClosed(C, "after timeout")
    checkEqual(
        stub.sentCommand("cancel "), "cancel " .. GUID,
        "a timed-out upload should be cancelled server-side"
    )
    checkTraits(C, edited, "after timeout")
    checkEqual(
        C.frame.saveBtn.enabled, true,
        "Save should be available to retry"
    )
    check(
        C.frame.status:GetText():find("still here", 1, true)
            ~= nil,
        "the player should be told the edit survived"
    )
end

-- The clock measures the server's silence, not the upload.
-- While commands are still leaving the queue there is nothing
-- to time out on, however many chunks there are.
tests["the timeout does not fire while the queue drains"] = function()
    local C = loadedBot()

    local huge = string.rep("word ", 700)
    C.unsavedTraits = {
        guid = GUID,
        trait1 = huge, trait2 = huge, trait3 = huge,
    }
    check(
        C:QueueChunkedSave(GUID, {
            trait1 = huge, trait2 = huge, trait3 = huge,
        }),
        "the traits should split into chunks"
    )
    C:LockSave()
    C:StartTonePoll(GUID)
    C:StartBackstoryPoll(GUID)
    check(
        #C.sendQueue > 70,
        "this upload should take longer than the timeout"
    )

    stub.advance(C, 21)
    check(
        #C.sendQueue > 0,
        "the upload should still be going out"
    )
    checkEqual(
        C.saveLocked, true,
        "Save should stay locked while the upload runs"
    )
    checkEqual(
        C.frame.saveBtn.enabled, false,
        "Save should stay disabled while the upload runs"
    )
    checkEqual(
        stub.sentCommand("cancel "), nil,
        "an upload in progress should not be cancelled"
    )

    stub.advance(C, 10)
    checkEqual(
        #C.sendQueue, 0,
        "the queue should have drained by now"
    )
    checkEqual(
        stub.sentCommand("cancel "), nil,
        "the wait for the answer has only just started"
    )

    stub.advance(C, 21)
    checkUploadClosed(C, "after the answer never came")
    checkEqual(
        stub.sentCommand("cancel "), "cancel " .. GUID,
        "only now should the upload be cancelled"
    )
end

-- Sending the commit is not the same as having it applied.
-- A tone poll fires every 1.5s during a save, and its reply
-- describes the bot as it was before the save.
tests["a reply during the wait cannot revert the boxes"] = function()
    local C = loadedBot()
    local edited = startChunkedSave(C)

    stub.advance(C, 2)
    checkEqual(
        #C.sendQueue, 0,
        "the commit should have been sent"
    )

    stub.serverSays(C, profileLine(C, BASE))

    checkTraits(C, edited, "during the wait")
    checkEqual(
        C.saveLocked, true,
        "the save is still in progress"
    )
end

-- Picking another bot abandons the edit rather than carrying
-- it over to a bot it was never written for.
tests["switching bots cancels the upload"] = function()
    local C = loadedBot()
    startChunkedSave(C)

    stub.advance(C, 0.35)
    stub.clearSent()

    C.roster = {
        {guid = GUID, name = "Testbot"},
        {guid = 9, name = "Otherbot"},
    }
    C:SelectBot(9)

    checkEqual(
        stub.sentCommand("cancel "), "cancel " .. GUID,
        "the abandoned upload should be cancelled"
    )
    checkEqual(C.uploadGuid, nil, "uploadGuid")
    checkEqual(C.uploadState, nil, "uploadState")
    checkEqual(
        C.unsavedTraits, nil,
        "the edit belonged to the bot that was left"
    )
    checkTraits(
        C, {"", "", ""},
        "the new bot should start from empty boxes"
    )
    checkEqual(
        C.frame.saveBtn.enabled, false,
        "nothing to save until the new profile loads"
    )
    checkEqual(
        stub.sentCommand("get "), "get 9",
        "the new bot's profile should be requested"
    )
end

-- The one path where the edit really is finished with.
tests["a confirmed save closes the upload"] = function()
    local C = loadedBot()
    local edited = startChunkedSave(C)

    stub.advance(C, 2)
    stub.serverSays(
        C,
        "UPDATED " .. GUID .. " " .. C:Encode("Testbot")
            .. " changed"
    )

    checkEqual(C.uploadGuid, nil, "uploadGuid")
    checkEqual(C.uploadState, nil, "uploadState")
    checkEqual(
        C.unsavedTraits, nil,
        "the typed traits are the saved traits now"
    )
    checkEqual(C.saveLocked, false, "save lock")
    checkTraits(C, edited, "after the save")
    -- Changed traits mean the server is rebuilding tone and
    -- backstory, so those polls are expected to be running.
    checkEqual(
        C.pendingToneGuid, GUID, "tone poll"
    )
    checkEqual(
        C.pendingBackstoryGuid, GUID, "backstory poll"
    )
end

return function(root)
    ROOT = root
    return tests
end
