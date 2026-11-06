local xml = require('layout_assistant.xml')
local M = {}
local function check(v, message) if not v then error(message, 0) end return v end
function M.number(v, what)
    local n = tonumber(v)
    check(n and n == n and math.abs(n) <= 1000000, 'Invalid finite number: ' .. (what or '?'))
    return n
end
function M.id(v)
    local n = M.number(v, 'ID')
    check(n > 0 and n % 1 == 0, 'Expected positive integer ID')
    return math.floor(n)
end
function M.index(v)
    if v == 'root' then return v end
    local n = M.number(v, 'raw sub_index')
    check(n >= 0 and n % 1 == 0, 'Expected raw integer sub_index or root')
    return string.format('%.0f', n)
end
function M.rotate(x, y, degrees)
    local r = M.number(degrees, 'angle') * math.pi / 180
    return x * math.cos(r) - y * math.sin(r), x * math.sin(r) + y * math.cos(r)
end
function M.compile_transform(source, target)
    local mirror = target.mirror or 'none'
    check(mirror == 'none' or mirror == 'flip_x' or mirror == 'flip_y', 'Unknown mirror mode')
    local sr = -M.number(source.angle, 'source angle') * math.pi / 180
    local tr = M.number(target.angle, 'target angle') * math.pi / 180
    local cs, ss, ct, st = math.cos(sr), math.sin(sr), math.cos(tr), math.sin(tr)
    local mx, my = mirror == 'flip_x' and -1 or 1, mirror == 'flip_y' and -1 or 1
    local a, b = ct*mx*cs - st*my*ss, -ct*mx*ss - st*my*cs
    local c, d = st*mx*cs + ct*my*ss, -st*mx*ss + ct*my*cs
    return function(x, y)
        local u, v = x - source.x, y - source.y
        return target.x + a*u + b*v, target.y + c*u + d*v
    end
end
function M.transform(x, y, source, target)
    return M.compile_transform(source, target)(x, y)
end

function M.read(text)
    local doc = xml.parse(text)
    local root = doc.children[1]
    check(root.name == 'MA' and xml.value(root, 'xmlns') == 'http://schemas.malighting.de/grandma2/xml/MA', 'Expected MA2 namespace')
    check(xml.value(root, 'major_vers') == '3' and xml.value(root, 'minor_vers') == '9', 'Only MA2 3.9 exports supported')
    -- Reject multi-object exports: importing them could affect unrelated pools.
    for _, child in ipairs(root.children) do
        check(child.name == 'Info' or child.name == 'Group', 'Unexpected top-level object: ' .. child.name)
    end
    local group = xml.one(root, 'Group')
    local data = xml.one(group, 'LayoutData')
    local fixtures = xml.one(data, 'SubFixtures')
    local model = {text = text, group = group, elements = {}, by_fixture = {}, ignored = 0}
    for _, node in ipairs(xml.children(fixtures, 'LayoutSubFix')) do
        local ref = xml.one(node, 'Subfixture')
        local raw_fid = xml.value(ref, 'fix_id')
        if not raw_fid or raw_fid == '0' then
            -- Channels and deleted references are not candidates; preserve their bytes.
            model.ignored = model.ignored + 1
        else
        local fid = M.id(raw_fid)
        local key = xml.value(ref, 'sub_index')
        key = key and M.index(key) or 'root'
        local elem = {fix_id = fid, index = key, node = node,
            x = M.number(xml.value(node, 'center_x'), 'center_x'),
            y = M.number(xml.value(node, 'center_y'), 'center_y')}
        model.by_fixture[fid] = model.by_fixture[fid] or {}
        check(not model.by_fixture[fid][key], 'Ambiguous duplicate Layout element: ' .. fid .. '/' .. key)
        model.by_fixture[fid][key] = elem
        model.elements[#model.elements + 1] = elem
        end
    end
    check(#model.elements > 0, 'No fixture elements in Layout')
    return model
end

function M.indices(model, fid)
    local elements = check(model.by_fixture[M.id(fid)], 'Fixture missing from Layout')
    local keys = {}
    for key in pairs(elements) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        if a == 'root' then return b ~= 'root' end
        if b == 'root' then return false end
        return tonumber(a) < tonumber(b)
    end)
    return keys
end

local function select_elements(model, fid, indices)
    local elements = check(model.by_fixture[M.id(fid)], 'Fixture missing from Layout: ' .. tostring(fid))
    check(type(indices) == 'table' and #indices > 0, 'Explicit nonempty index list required')
    local selected, seen = {}, {}
    for _, index in ipairs(indices) do
        local key = M.index(index)
        check(not seen[key], 'Repeated sub_index: ' .. key)
        seen[key] = true
        selected[#selected + 1] = check(elements[key], 'Missing element: ' .. fid .. '/' .. key)
    end
    return selected
end
local function frame(elements, spec)
    check((spec.x == nil) == (spec.y == nil), 'Anchor needs both x and y')
    local x, y = 0, 0
    for _, elem in ipairs(elements) do x, y = x + elem.x, y + elem.y end
    return {x = spec.x == nil and x / #elements or M.number(spec.x, 'anchor x'),
        y = spec.y == nil and y / #elements or M.number(spec.y, 'anchor y'),
        angle = M.number(spec.angle, 'angle'), mirror = spec.mirror or 'none'}
end

local function add_change(plan, before, source_index, x, y)
    x, y = M.number(x, 'result x'), M.number(y, 'result y')
    plan.changes[#plan.changes + 1] = {fix_id = before.fix_id, index = before.index,
        source_index = source_index, before_x = before.x, before_y = before.y, x = x, y = y}
    for _, pair in ipairs({{'center_x', x}, {'center_y', y}}) do
        local attr = before.node.attrs[pair[1]]
        local value = math.abs(pair[2]) < 0.0000005 and 0 or pair[2]
        plan.edits[#plan.edits + 1] = {first = attr.first, last = attr.last,
            value = (string.format('%.6f', value):gsub(',', '.'))}
    end
end

function M.parse_positions(text)
    check(type(text) == 'string' and #text <= 16 * 1024 * 1024, 'Positions file too large')
    text = text:gsub('^\239\187\191', ''):gsub('\r\n', '\n')
    local placements, header = {}, true
    for line in (text .. '\n'):gmatch('(.-)\n') do
        if header then
            check(line == 'fix_id\tx\ty\trotation_delta', 'Expected normalized positions TSV header')
            header = false
        elseif line ~= '' then
            local fid, x, y, angle = line:match('^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$')
            check(fid, 'Expected exactly four TSV fields')
            placements[#placements + 1] = {fix_id = M.id(fid), x = M.number(x, 'x'),
                y = M.number(y, 'y'), rotation_delta = M.number(angle, 'rotation_delta')}
        end
    end
    check(#placements > 0, 'Empty positions file')
    return {placements = placements}
end

-- Venue placement: each fixture keeps its own pixel geometry and numbering.
-- Rotation is a DELTA in the Layout plane, never an inferred 3D Euler angle.
function M.place(model, config)
    check(type(config.placements) == 'table' and #config.placements > 0, 'Nonempty placements required')
    local plan = {changes = {}, edits = {}, source_text = model.text}
    local seen = {}
    for _, placement in ipairs(config.placements) do
        local fid = M.id(placement.fix_id)
        check(not seen[fid], 'Repeated placement fixture: ' .. fid)
        seen[fid] = true
        local elements = select_elements(model, fid, placement.indices or M.indices(model, fid))
        local source = frame(elements, {angle = 0})
        local target = {x = M.number(placement.x, 'placement x'), y = M.number(placement.y, 'placement y'),
            angle = M.number(placement.rotation_delta or 0, 'rotation delta'), mirror = 'none'}
        local transform = M.compile_transform(source, target)
        for _, before in ipairs(elements) do
            local x, y = transform(before.x, before.y)
            add_change(plan, before, before.index, x, y)
        end
    end
    plan.output = xml.patch(model.text, plan.edits)
    return plan
end

-- All jobs read the same immutable snapshot. Conflicting writes are rejected.
function M.plan(model, config)
    if type(config) == 'table' and config.placements then
        check(config.jobs == nil, 'Use jobs OR placements per plan')
        return M.place(model, config)
    end
    check(type(config) == 'table' and type(config.jobs) == 'table' and #config.jobs > 0, 'Nonempty jobs required')
    local plan = {changes = {}, edits = {}, source_text = model.text}
    local used, sources = {}, {}
    for _, job in ipairs(config.jobs) do
        check(type(job.source) == 'table', 'Source required')
        sources[M.id(job.source.fix_id)] = true
    end
    for _, job in ipairs(config.jobs) do
        local source = job.source
        local selected = select_elements(model, source.fix_id, source.indices)
        local origin = frame(selected, source)
        check(type(job.targets) == 'table' and #job.targets > 0, 'Targets required')
        for _, target in ipairs(job.targets) do
            local fid = M.id(target.fix_id)
            check(not sources[fid], 'A template fixture cannot also be a target')
            local indices = target.indices or source.indices
            check(#indices == #selected, 'Source/target index count mismatch')
            local mapped = select_elements(model, fid, indices)
            local destination = frame(mapped, target)
            local transform = M.compile_transform(origin, destination)
            for i, before in ipairs(mapped) do
                local key = fid .. '/' .. before.index
                check(not used[key], 'Conflicting target: ' .. key)
                used[key] = true
                local x, y = transform(selected[i].x, selected[i].y)
                add_change(plan, before, selected[i].index, x, y)
            end
        end
    end
    plan.output = xml.patch(model.text, plan.edits)
    return plan
end

function M.report(plan)
    local lines = {'Layout Assistant 0.2.0 - PREVIEW',
        'Only center_x/center_y change in a NEW Layout copy. Icons/sizes/patch stay as exported.',
        'Fixture/raw_index <- source_raw_index: old x,y -> new x,y'}
    for _, c in ipairs(plan.changes) do
        lines[#lines + 1] = string.format('%d/%s <- %s: %.6f,%.6f -> %.6f,%.6f',
            c.fix_id, c.index, c.source_index, c.before_x, c.before_y, c.x, c.y)
    end
    return table.concat(lines, '\n') .. '\n'
end
return M
