-- Wire encoding for commands the addon sends.
--
-- The client replaces %f (focus name) and %t (target name) in
-- every outgoing chat line, so no escape may read %F. These
-- checks pin that rule and the round trip through the
-- server's decoder, which is mirrored below.

local stub = require("wow_stub")

local ROOT = "."

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

-- Mirror of PercentDecode() in mod-llm-chatter's
-- LLMChatterCommand.cpp: one left-to-right pass decoding %XX,
-- plus ~FX for bytes 0xF0-0xFF. Decoded output is never
-- rescanned, so %7E followed by F0 stays a literal "~F0".
local function serverDecode(value)
    if value == "-" then
        return ""
    end
    local out, i = {}, 1
    while i <= #value do
        local c = value:sub(i, i)
        local hex = value:sub(i + 1, i + 2)
        local escape = c == "%"
            or (c == "~" and hex:sub(1, 1):upper() == "F")
        if escape and hex:match("^%x%x$") then
            table.insert(out, string.char(tonumber(hex, 16)))
            i = i + 3
        else
            table.insert(out, c)
            i = i + 1
        end
    end
    return table.concat(out)
end

-- What the client would mangle: any %f or %t, either case.
local function hasChatToken(line)
    return line:find("%%[FfTt]") ~= nil
end

local EMOJI = "\240\159\152\128"
local CYRILLIC = "\208\150\208\184\208\183\208\189\209\140"

tests["4-byte characters never produce a %F escape"] = function()
    local C = stub.load(ROOT)
    local encoded = C:Encode(EMOJI)
    checkEqual(encoded, "~F0%9F%98%80", "emoji encoding")
    check(not hasChatToken(encoded), "emoji must not contain %F")

    for byte = 0xF0, 0xFF do
        local one = C:Encode("a" .. string.char(byte))
        check(
            not hasChatToken(one),
            string.format("byte 0x%02X produced %s", byte, one)
        )
    end
end

tests["other bytes keep their %XX form"] = function()
    local C = stub.load(ROOT)
    checkEqual(
        C:Encode(CYRILLIC),
        "%D0%96%D0%B8%D0%B7%D0%BD%D1%8C",
        "Cyrillic encoding"
    )
    checkEqual(C:Encode("lone wolf"), "lone%20wolf", "space")
    checkEqual(C:Encode("a-b_c.d"), "a-b_c.d", "unreserved")
end

tests["a literal tilde is escaped"] = function()
    local C = stub.load(ROOT)
    checkEqual(C:Encode("~F0"), "%7EF0", "tilde")
    checkEqual(serverDecode(C:Encode("~F0")), "~F0", "tilde round trip")
end

tests["the server decodes everything the addon sends"] = function()
    local C = stub.load(ROOT)
    local samples = {
        "plain words",
        CYRILLIC .. " " .. CYRILLIC,
        EMOJI .. EMOJI .. " mixed " .. CYRILLIC,
        "100% ~sure~ %F0 %t",
        "\226\130\172 euro and \228\184\173 CJK",
    }
    for _, text in ipairs(samples) do
        local encoded = C:Encode(text)
        check(not hasChatToken(encoded), "chat token in " .. encoded)
        checkEqual(serverDecode(encoded), text, "round trip")
    end
end

tests["a maximum-length 4-byte backstory splits cleanly"] = function()
    local C = stub.load(ROOT)
    local text = string.rep(EMOJI, 1000)
    local encoded = C:Encode(text)
    checkEqual(string.len(encoded), 12000, "encoded length")

    local chunks = C:SplitEncoded(encoded, 200)
    check(chunks ~= nil, "the story should split")
    checkEqual(#chunks, 61, "chunk count")
    check(#chunks <= 64, "within the server's chunk cap")

    for i, chunk in ipairs(chunks) do
        check(string.len(chunk) <= 200, "chunk " .. i .. " too long")
        check(
            chunk:sub(1, 1) == "~" or chunk:sub(1, 1) == "%",
            "chunk " .. i .. " starts inside an escape"
        )
        check(not hasChatToken(chunk), "chunk " .. i .. " has %F")
        check(not chunk:find(" "), "chunk " .. i .. " has a space")
    end
    checkEqual(
        serverDecode(table.concat(chunks)), text,
        "reassembled story"
    )
end

return function(root)
    ROOT = root
    return tests
end
