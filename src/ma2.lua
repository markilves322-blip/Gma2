local core = require('layout_assistant.core')
local M = {}
local function check(v, message) if not v then error(message, 0) end return v end
local serial = 0

function M.new(gma_api, filesystem)
    local g = check(gma_api, 'grandMA2 API missing')
    local fs = filesystem or io
    local self = {}
    local obj = check(g.show and g.show.getobj, 'gma.show.getobj missing')
    check(type(obj.handle) == 'function', 'getobj.handle missing')
    local function handle(id)
        local h = obj.handle('Layout ' .. core.id(id))
        if h == false or h == 0 then return nil end
        return h
    end
    function self.log(message) g.feedback(tostring(message)) end
    function self.ask(title, default)
        local result = g.textinput(title, default or '')
        if result == nil or result == false then error('Cancelled', 0) end
        return result
    end
    function self.exists(path)
        local f = fs.open(path, 'rb')
        if f then f:close(); return true end
        return false
    end
    function self.read(path)
        local f, err = fs.open(path, 'rb')
        check(f, 'Cannot read file: ' .. path .. ' (' .. tostring(err) .. ')')
        local data = f:read(16 * 1024 * 1024 + 1)
        f:close()
        check(data and #data <= 16 * 1024 * 1024, 'File empty or over 16 MiB')
        return data
    end
    function self.write_new(path, text)
        check(not self.exists(path), 'Refusing to overwrite file: ' .. path)
        local f, err = fs.open(path, 'wb')
        check(f, 'Cannot write file: ' .. path .. ' (' .. tostring(err) .. ')')
        local ok, write_err = f:write(text)
        local closed, close_err = f:close()
        check(ok and closed, 'File write failed: ' .. tostring(write_err or close_err))
    end
    function self.directory(path)
        check(type(path) == 'string' and #path > 0 and #path <= 512, 'Absolute existing directory required')
        path = path:gsub('\\', '/')
        check(path:match('^/') or path:match('^%a:/'), 'Directory must be absolute')
        check(not path:find('[%c";`$<>|]'), 'Unsafe character in directory')
        local cleaned = path:gsub('/+$', '')
        check(cleaned ~= '' and not cleaned:match('^%a:$'), 'Use an existing subdirectory, not a drive root')
        return cleaned
    end
    function self.basename(dir, role)
        for _ = 1, 1000 do
            serial = serial + 1
            local name = 'la_' .. role .. '_' .. os.date('%Y%m%d_%H%M%S') .. '_' .. serial
            if not self.exists(dir .. '/' .. name .. '.xml') and not self.exists(dir .. '/' .. name .. '.txt') then return name end
        end
        error('Cannot allocate a new filename', 0)
    end
    function self.export(layout, dir)
        layout, dir = core.id(layout), self.directory(dir)
        check(handle(layout), 'Source Layout does not exist')
        local name = self.basename(dir, 'snapshot')
        local path = dir .. '/' .. name .. '.xml'
        -- No /overwrite or /noconfirm, and no drive/destination changes.
        g.cmd(string.format('Export Layout %d "%s" /path="%s"', layout, name, dir))
        for _ = 1, 20 do
            if self.exists(path) then break end
            if type(g.sleep) ~= 'function' then break end
            g.sleep(0.1)
        end
        local text = self.read(path)
        core.read(text) -- Never accept an unrecognised export format.
        return text, path
    end
    function self.probe(address)
        check(type(address) == 'string' and (address:match('^Layout %d+$') or address:match('^Fixture %d+$')), 'Unsupported probe address')
        local h = obj.handle(address)
        check(h and h ~= 0, 'Probe object missing')
        local prop = g.show.property
        self.log('PROBE (read only): ' .. address)
        self.log('Lua runtime: ' .. tostring(_VERSION))
        for _, name in ipairs({'build_date', 'build_time', 'git_version'}) do
            if type(g[name]) == 'function' then
                local ok, value = pcall(g[name])
                self.log('gma.' .. name .. ': ' .. (ok and tostring(value) or '<read error>'))
            end
        end
        local visited, budget = {}, 200
        local function visit(node, label, depth)
            if not node or node == 0 or visited[node] or budget == 0 then return end
            visited[node], budget = true, budget - 1
            self.log(label)
            if prop and prop.amount and prop.name and prop.get then
                local ok, n = pcall(prop.amount, node)
                if ok and type(n) == 'number' then
                    for i = 0, math.min(n, 256) - 1 do
                        local nk, name = pcall(prop.name, node, i)
                        if nk and name then
                            local vk, value = pcall(prop.get, node, name)
                            self.log('  [' .. i .. '] ' .. name .. '=' .. (vk and tostring(value) or '<read error>'))
                        end
                    end
                end
            else self.log('  Property enumeration unavailable') end
            if depth < 2 and obj.amount and obj.child then
                local ok, n = pcall(obj.amount, node)
                if ok and type(n) == 'number' then
                    self.log('  Child count: ' .. n)
                    for i = 0, math.min(n, 200) - 1 do
                        local ck, child = pcall(obj.child, node, i)
                        if ck then visit(child, label .. '/child[' .. i .. ']', depth + 1) end
                    end
                end
            end
        end
        visit(h, address, 0)
        self.log('Probe bounded to depth 2 / 200 objects / 256 properties each. Absence is not proof of API impossibility.')
    end
    local function group_bytes(text)
        local m = core.read(text)
        return text:sub(m.group.start, m.group.finish)
    end
    function self.create(source_layout, target_layout, dir, plan, output_path)
        source_layout, target_layout = core.id(source_layout), core.id(target_layout)
        dir = self.directory(dir)
        check(source_layout ~= target_layout and not handle(target_layout), 'Destination must be an EMPTY Layout slot')
        check(self.read(output_path) == plan.output, 'Output file changed after preview')
        local token = 'CREATE ' .. target_layout
        local reply = self.ask('New Layout ' .. target_layout .. ', ' .. #plan.changes .. ' pixels. Review TXT first. Type ' .. token, '')
        if reply ~= token then self.log('Cancelled: no import executed'); return false end
        -- User may have changed the show while the dialog was open.
        local fresh = self.export(source_layout, dir)
        check(group_bytes(fresh) == group_bytes(plan.source_text), 'Source Layout changed since preview; run again')
        check(self.read(output_path) == plan.output, 'Output file changed after confirmation')
        check(not handle(target_layout), 'Destination occupied since preview; import blocked')
        -- The only show-writing command. Keep MA2's own confirmation enabled.
        local name = check(output_path:match('/(la_result_[%w_]+)%.xml$'), 'Unexpected output filename')
        check(output_path == dir .. '/' .. name .. '.xml', 'Output directory mismatch')
        g.cmd(string.format('Import "%s" At Layout %d /path="%s"', name, target_layout, dir))
        for _ = 1, 20 do
            if handle(target_layout) then break end
            if type(g.sleep) ~= 'function' then break end
            g.sleep(0.1)
        end
        check(handle(target_layout), 'Import not verified; inspect MA2 feedback. No automatic retry/delete performed')
        local actual = core.read(self.export(target_layout, dir))
        for _, change in ipairs(plan.changes) do
            local entries = actual.by_fixture[change.fix_id]
            local e = entries and entries[change.index]
            check(e and math.abs(e.x - change.x) <= 0.0011 and math.abs(e.y - change.y) <= 0.0011,
                'Layout exists, but coordinate verification failed. Inspect it manually; no cleanup performed')
        end
        self.log('Created Layout ' .. target_layout .. '; target coordinates verified by re-export (tolerance 0.0011).')
        return true
    end
    return self
end
return M
