local core = require('layout_assistant.core')
local ma2 = require('layout_assistant.ma2')
local M = {}
local function list(text, convert)
    local out = {}
    if text:match('^%s*$') or text:match('^%s*,') or text:match(',%s*$') or text:match(',%s*,') then error('Expected comma-separated values', 0) end
    for token in text:gmatch('[^,]+') do
        token = token:match('^%s*(.-)%s*$')
        out[#out + 1] = convert(token)
    end
    return out
end
function M.run(g, filesystem)
    local a = ma2.new(g, filesystem)
    local mode = a.ask('Layout Assistant: probe / preview / create / scene', 'probe')
    if mode == '' then return end
    if mode ~= 'probe' and mode ~= 'preview' and mode ~= 'create' and mode ~= 'scene' then error('Unknown mode', 0) end
    local layout = core.id(a.ask('Existing Layout number', ''))
    if mode == 'probe' then
        a.probe('Layout ' .. layout)
        local fid = a.ask('Optional Fixture ID for read-only probe (empty = skip)', '')
        if fid ~= '' then a.probe('Fixture ' .. core.id(fid)) end
        return
    end
    local dir = a.directory(a.ask('Absolute existing importexport directory (see manual)', ''))
    local text, snapshot, model = a.export(layout, dir)
    a.log('Snapshot kept: ' .. snapshot)
    local plan
    if mode == 'scene' then
        local filename = a.ask('Positions TSV filename in importexport, e.g. scene_front.tsv', '')
        if not filename:match('^[%w_-]+%.tsv$') then error('Use a simple .tsv filename, no path', 0) end
        plan = core.plan(model, core.parse_positions(a.read(dir .. '/' .. filename)))
        mode = a.ask('Scene: preview / create', 'preview')
        if mode ~= 'preview' and mode ~= 'create' then error('Cancelled', 0) end
    else
    local fid = core.id(a.ask('Template Fixture ID', ''))
    local available = table.concat(core.indices(model, fid), ',')
    a.log('Template RAW XML indices: ' .. available .. '. These are not guaranteed to equal displayed .n numbers.')
    local source = {fix_id = fid,
        indices = list(a.ask('RAW XML indices to copy, in order; root = omitted sub_index', available), core.index),
        angle = core.number(a.ask('Template current Layout angle, degrees (CCW)', '0'), 'source angle')}
    local target_ids = list(a.ask('Target Fixture IDs, comma separated', ''), core.id)
    local targets = {}
    for _, id in ipairs(target_ids) do
        a.log('Target ' .. id .. ' RAW indices: ' .. table.concat(core.indices(model, id), ','))
        local target = {fix_id = id,
            indices = list(a.ask('Fixture ' .. id .. ': mapped RAW indices in template order', table.concat(source.indices, ',')), core.index),
            angle = core.number(a.ask('Fixture ' .. id .. ': absolute Layout angle (left/right may use opposite signs)', tostring(source.angle)), 'target angle'),
            mirror = a.ask('Fixture ' .. id .. ': none / flip_x / flip_y (LOCAL coordinates)', 'none')}
        local anchor = a.ask('Fixture ' .. id .. ': anchor x,y or centroid', 'centroid')
        if anchor ~= 'centroid' then
            local xy = list(anchor, function(n) return core.number(n, 'anchor') end)
            if #xy ~= 2 then error('Anchor needs x,y', 0) end
            target.x, target.y = xy[1], xy[2]
        end
        targets[#targets + 1] = target
    end
    plan = core.plan(model, {jobs = {{source = source, targets = targets}}})
    end
    local report = core.report(plan)
    for line in report:gmatch('[^\n]+') do a.log(line) end
    local name = a.basename(dir, 'result')
    local output_path = dir .. '/' .. name .. '.xml'
    a.write_new(output_path, plan.output)
    a.write_new(dir .. '/' .. name .. '.txt', report)
    a.log('Review XML/TXT: ' .. dir .. '/' .. name .. '.*')
    if mode == 'create' then
        local destination = core.id(a.ask('NEW EMPTY Layout number (existing slots are refused)', ''))
        a.create(layout, destination, dir, plan, output_path)
    else a.log('Preview finished: no show objects changed. Run create to generate and confirm a fresh plan.') end
end
return M
