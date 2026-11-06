-- Run from the repository root: lua tools/offline.lua input.xml recipe.lua NEW-output.xml
local paths = {['layout_assistant.xml']='src/xml.lua', ['layout_assistant.core']='src/core.lua'}
for name, path in pairs(paths) do package.preload[name] = function() return dofile(path) end end
local core = require('layout_assistant.core')
local function read(path)
    local f = assert(io.open(path, 'rb')); local text = f:read('*a'); f:close(); return text
end
local function write_new(path, text)
    local existing = io.open(path, 'rb')
    if existing then existing:close(); error('Refusing to overwrite: ' .. path) end
    local f = assert(io.open(path, 'wb')); assert(f:write(text)); assert(f:close())
end
assert(arg[1] and arg[2] and arg[3] and not arg[4], 'Usage: lua tools/offline.lua input.xml recipe.lua NEW-output.xml')
assert(arg[1] ~= arg[3] and arg[2] ~= arg[3], 'Output must be a new file')
-- A recipe is executable Lua authored by the operator: never run an untrusted recipe.
local plan = core.plan(core.read(read(arg[1])), assert(loadfile(arg[2]))())
local report = core.report(plan)
-- Preflight BOTH paths before writing either file.
for _, path in ipairs({arg[3], arg[3] .. '.txt'}) do
    local f = io.open(path, 'rb'); if f then f:close(); error('Refusing to overwrite: ' .. path) end
end
write_new(arg[3], plan.output)
write_new(arg[3] .. '.txt', report)
io.write(report)
