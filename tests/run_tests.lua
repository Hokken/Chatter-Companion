#!/usr/bin/env lua5.1
-- Runs the addon's regression tests against a stubbed client.
--
--   lua5.1 tests/run_tests.lua
--
-- Or, without a Lua interpreter installed:
--
--   docker run --rm -v "$PWD":/addon -w /addon \
--     nickblah/lua:5.1-alpine lua tests/run_tests.lua
--
-- Lua 5.1 is what the 3.3.5 client runs, so anything that
-- passes here parses and behaves the same way in game.

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local root = here .. "/.."
package.path = here .. "/?.lua;" .. package.path

local suites = {
    "test_upload_lifecycle",
    "test_encoding",
}

local passed, failed = 0, {}

for _, name in ipairs(suites) do
    local tests = require(name)(root)

    -- Deterministic order, so a failure always reports the
    -- same way between runs.
    local names = {}
    for test in pairs(tests) do
        table.insert(names, test)
    end
    table.sort(names)

    for _, test in ipairs(names) do
        local ok, err = pcall(tests[test])
        if ok then
            passed = passed + 1
            print("  ok    " .. test)
        else
            table.insert(failed, {test = test, err = err})
            print("  FAIL  " .. test)
            print("          " .. tostring(err))
        end
    end
end

print(string.format(
    "\n%d passed, %d failed", passed, #failed
))

os.exit(#failed == 0 and 0 or 1)
