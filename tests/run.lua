local paths = {xml = 'src/xml.lua', core = 'src/core.lua', ma2 = 'src/ma2.lua', ui = 'src/ui.lua'}
for name, path in pairs(paths) do
    package.preload['layout_assistant.' .. name] = function() return dofile(path) end
end
local core, xml, ma2, ui = require('layout_assistant.core'), require('layout_assistant.xml'), require('layout_assistant.ma2'), require('layout_assistant.ui')
local function read(path) local f = assert(io.open(path, 'rb')); local t = f:read('*a'); f:close(); return t end
local fixture = read('examples/synthetic-layout.xml')
local function model() return core.read(fixture) end
local function config()
    return {jobs = {{source = {fix_id = 101, indices = {'0', '1', '2'}, angle = 30}, targets = {{fix_id = 201, angle = -30}}}}}
end
local function near(a, b, tolerance) assert(math.abs(a - b) <= (tolerance or 0.000002), a .. ' != ' .. b) end
local function rejects(fn, fragment)
    local ok, err = pcall(fn)
    assert(not ok, 'Expected failure')
    if fragment then assert(tostring(err):find(fragment, 1, true), tostring(err)) end
end
local tests, passed = {}, 0
local function test(name, fn) tests[#tests + 1] = {name, fn} end

test('read known MA2 subset and numerical index sorting', function()
    local m = model(); assert(#m.elements == 17)
    assert(table.concat(core.indices(m, 101), ',') == '0,1,2')
    assert(core.id('1e2') == 100 and tostring(core.id('1e2')) == '100')
end)
test('opposite angles preserve pixel order and target centroid', function()
    local p = core.plan(model(), config())
    local out = core.read(p.output).by_fixture[201]
    near(out['0'].x, 19.133975); near(out['0'].y, 10.5)
    near(out['1'].x, 20); near(out['1'].y, 10)
    near(out['2'].x, 20.866025); near(out['2'].y, 9.5)
    assert(#p.changes == 3 and #p.edits == 6)
end)
test('copy at equal angle preserves offsets', function()
    local c = config(); c.jobs[1].targets[1].angle = 30
    local m = model(); local out = core.read(core.plan(m, c).output)
    for _, key in ipairs({'0','1','2'}) do
        near(out.by_fixture[201][key].x - 20, m.by_fixture[101][key].x - 10)
        near(out.by_fixture[201][key].y, m.by_fixture[101][key].y)
    end
end)
test('reflection is in source local frame', function()
    local s = {x = 0, y = 0, angle = 90}
    local t = {x = 10, y = 20, angle = 0, mirror = 'flip_x'}
    local x, y = core.transform(0, 2, s, t); near(x, 8); near(y, 20)
    t.mirror = 'flip_y'; x, y = core.transform(-1, 0, s, t); near(x, 10); near(y, 19)
end)
test('explicit mapping reverses index order independently of mirror', function()
    local c = config(); c.jobs[1].targets[1].indices = {'2','1','0'}
    local out = core.read(core.plan(model(), c).output).by_fixture[201]
    near(out['2'].y, 10.5); near(out['0'].y, 9.5)
end)
test('multiple fixture profiles and explicit anchors', function()
    local p = core.plan(model(), dofile('examples/recipe.lua'))
    assert(#p.changes == 10)
    local out = core.read(p.output).by_fixture[401]
    local x, y = 0, 0
    for _, e in pairs(out) do x, y = x + e.x, y + e.y end
    near(x / 4, 25); near(y / 4, 5)
end)
test('only selected coordinate value spans change', function()
    local p = core.plan(model(), config())
    local cursor, parts = 1, {}
    -- Reconstruct original input by restoring only the edited values.
    for _, edit in ipairs(p.edits) do
        parts[#parts + 1] = fixture:sub(cursor, edit.first - 1)
        parts[#parts + 1] = edit.value; cursor = edit.last + 1
    end
    parts[#parts + 1] = fixture:sub(cursor)
    assert(table.concat(parts) == p.output)
    local a, b = model(), core.read(p.output)
    for _, fid in ipairs({101, 202, 301, 401}) do
        for key, e in pairs(a.by_fixture[fid]) do
            local other = b.by_fixture[fid][key]
            assert(fixture:sub(e.node.start,e.node.finish) == p.output:sub(other.node.start,other.node.finish))
        end
    end
    assert(p.output:find('text="Keep &amp; preserve &quot;this&quot;"', 1, true))
end)
test('rigid transforms preserve distances across 500 random frames', function()
    math.randomseed(20261106)
    for _ = 1, 500 do
        local s = {x = math.random() * 10, y = math.random() * 10, angle = math.random() * 720 - 360}
        local t = {x = math.random() * 10, y = math.random() * 10, angle = math.random() * 720 - 360,
            mirror = ({'none', 'flip_x', 'flip_y'})[math.random(3)]}
        local x1,y1,x2,y2 = math.random(),math.random(),math.random(),math.random()
        local a,b = core.transform(x1,y1,s,t); local c,d = core.transform(x2,y2,s,t)
        near((a-c)^2+(b-d)^2, (x1-x2)^2+(y1-y2)^2, 1e-10)
    end
end)
test('root and zero raw indices remain distinct', function()
    local input = fixture:gsub('<Subfixture fix_id="101" sub_index="0"/>', '<Subfixture fix_id="101"/>')
    local m = core.read(input)
    assert(m.by_fixture[101].root and not m.by_fixture[101]['0'])
end)
test('single quotes, comments, entities and quoted greater-than', function()
    local doc = xml.parse("<?xml version='1.0'?><a test='x > y &amp; z'><!-- <bad> --><b n='1'/></a>")
    assert(xml.value(doc.children[1], 'test') == 'x > y &amp; z')
    assert(#doc.children[1].children == 1)
end)
test('reject DTD, CDATA, duplicate attrs, broken nesting and multiple roots', function()
    for _, s in ipairs({'<!DOCTYPE MA><MA/>','<a><![CDATA[x]]></a>','<a x="1" x="2"/>','<a><b></a>','<a/><b/>','<a x="1>','text<a/>','<a/>text'}) do
        rejects(function() xml.parse(s) end)
    end
end)
test('unrelated channels and deleted references remain untouched', function()
    local channel = '<LayoutSubFix center_x="0" center_y="0"><Subfixture cha_id="10"/></LayoutSubFix>'
    local deleted = '<LayoutSubFix center_x="0" center_y="0"><Subfixture cha_id="0"/></LayoutSubFix>'
    local text = fixture:gsub('</SubFixtures>', channel .. deleted .. '</SubFixtures>')
    local m = core.read(text); assert(m.ignored == 2)
    local p = core.plan(m, config()); assert(p.output:find(channel .. deleted,1,true))
end)
test('reject foreign versions and multi-object exports', function()
    rejects(function() core.read(fixture:gsub('minor_vers="9"','minor_vers="8"')) end, '3.9')
    rejects(function() core.read(fixture:gsub('</MA>','<Macro index="1"/></MA>')) end, 'top-level')
    rejects(function() core.read(fixture:gsub('</MA>','<Group/></MA>')) end, 'one Group')
end)
test('reject duplicate elements and unavailable mappings', function()
    rejects(function() core.read(fixture:gsub('<Subfixture fix_id="101" sub_index="2"/>', '<Subfixture fix_id="101" sub_index="1"/>')) end, 'duplicate')
    local c = config(); c.jobs[1].targets[1].indices = {'0','1'}
    rejects(function() core.plan(model(), c) end, 'count mismatch')
    c.jobs[1].targets[1].indices = {'0','1','9'}
    rejects(function() core.plan(model(), c) end, 'Missing element')
    c.jobs[1].targets[1].indices = {'0','0','1'}
    rejects(function() core.plan(model(), c) end, 'Repeated')
end)
test('reject overlapping jobs and template modification', function()
    local c = config(); c.jobs[1].targets[2] = c.jobs[1].targets[1]
    rejects(function() core.plan(model(), c) end, 'Conflicting')
    c = config(); c.jobs[1].targets[1].fix_id = 101
    rejects(function() core.plan(model(), c) end, 'template')
end)
test('reject non-finite, out-of-range, invalid mirror and incomplete anchor', function()
    for _, n in ipairs({'NaN','inf',math.huge,0/0,1000001}) do rejects(function() core.number(n) end) end
    local c = config(); c.jobs[1].targets[1].mirror = 'guess-left'
    rejects(function() core.plan(model(), c) end, 'mirror')
    c = config(); c.jobs[1].targets[1].x = 0
    rejects(function() core.plan(model(), c) end, 'both')
end)

-- Memory filesystem + simulated MA command transport. This is NOT an onPC emulator.
local function harness(answers, options)
    options = options or {}
    local files, commands, logs = {}, {}, {}
    local layouts = {[1] = fixture}
    if options.occupied then layouts[99] = fixture end
    local fs = {}
    function fs.open(path, mode)
        if mode == 'rb' then
            if not files[path] then return nil, 'missing' end
            return {read = function(_, n) if type(n) == 'number' then return files[path]:sub(1,n) end return files[path] end, close = function() return true end}
        elseif mode == 'wb' then
            files[path] = ''
            return {write = function(self, data) files[path] = files[path] .. data; return self end, close = function() return true end}
        end
        error('Unexpected open mode')
    end
    local g = {show = {getobj = {}}, feedback = function(t) logs[#logs+1] = t end}
    function g.show.getobj.handle(address)
        local id = address:match('^Layout (%d+)$'); return layouts[tonumber(id)] and tonumber(id) or nil
    end
    function g.textinput(title)
        if title:find('Type CREATE', 1, true) and options.on_confirm then options.on_confirm(layouts, files) end
        local value = table.remove(answers, 1)
        if value == '<CANCEL>' then return nil end
        return value
    end
    function g.cmd(command)
        commands[#commands+1] = command
        local id,name,dir = command:match('^Export Layout (%d+) "([%w_]+)" /path="([^"]+)"$')
        if id then
            if not options.export_failure then files[dir .. '/' .. name .. '.xml'] = layouts[tonumber(id)] end
            return
        end
        name,id,dir = command:match('^Import "([%w_]+)" At Layout (%d+) /path="([^"]+)"$')
        assert(id, 'Unexpected command: ' .. command)
        assert(not layouts[tonumber(id)], 'Would overwrite Layout')
        if not options.import_failure then
            layouts[tonumber(id)] = options.corrupt_import and fixture or assert(files[dir .. '/' .. name .. '.xml'])
        end
    end
    local adapter = ma2.new(g, fs)
    return {g = g, fs = fs, files = files, commands = commands, logs = logs, layouts = layouts, a = adapter}
end
local function import_count(h)
    local n=0; for _, c in ipairs(h.commands) do if c:match('^Import ') then n=n+1 end end; return n
end
local function prepared(answers, options)
    local h = harness(answers, options)
    local plan = core.plan(model(), config())
    h.files['/test/la_result_test.xml'] = plan.output
    h.plan = plan
    return h
end
local function create(h) return h.a.create(1,99,'/test',h.plan,'/test/la_result_test.xml') end

test('probe executes zero commands and tolerates absent property API', function()
    local h = harness({'probe','1',''})
    ui.run(h.g,h.fs); assert(#h.commands == 0 and #h.logs > 0)
end)
test('probe uses zero-based property indices and bounded children', function()
    local h = harness({})
    h.g.show.getobj.amount = function() return 1 end
    h.g.show.getobj.child = function(_, i) assert(i == 0); return 1 end
    h.g.show.property = {amount = function() return 2 end, name = function(_, i) return ({[0]='Name',[1]='PosX'})[i] end,
        get = function(_, name) return name == 'Name' and 'Demo' or '2.0' end}
    h.a.probe('Layout 1'); assert(#h.commands == 0)
    assert(table.concat(h.logs, '\n'):find('[0] Name=Demo', 1, true))
end)
test('preview wizard exports and writes review files without importing', function()
    local h = harness({'preview','1','/test','101','0,1,2','30','201','0,1,2','-30','none','centroid'})
    ui.run(h.g,h.fs); assert(import_count(h) == 0 and #h.commands == 1)
    assert(h.layouts[1] == fixture)
    local found = false
    for path in pairs(h.files) do if path:match('la_result_.*%.txt$') then found = true end end
    assert(found)
end)
test('cancelled wizard does not modify objects', function()
    local h = harness({'<CANCEL>'}); rejects(function() ui.run(h.g,h.fs) end, 'Cancelled'); assert(#h.commands == 0)
end)
test('strict confirmation declines empty/wrong tokens without import', function()
    for _, reply in ipairs({'','yes','CREATE 98','CREATE 99 '}) do
        local h = prepared({reply}); assert(create(h) == false and #h.commands == 0)
    end
end)
test('occupied destinations and original slot are blocked before confirmation', function()
    local h = prepared({'CREATE 99'}, {occupied = true})
    rejects(function() create(h) end, 'EMPTY'); assert(#h.commands == 0)
    h = prepared({})
    rejects(function() h.a.create(1,1,'/test',h.plan,'/test/la_result_test.xml') end, 'EMPTY')
end)
test('destination becoming occupied during confirmation is blocked', function()
    local h = prepared({'CREATE 99'}, {on_confirm = function(layouts) layouts[99] = fixture end})
    rejects(function() create(h) end, 'occupied'); assert(import_count(h) == 0)
end)
test('source changed during confirmation is blocked', function()
    local h = prepared({'CREATE 99'}, {on_confirm = function(layouts) layouts[1] = fixture:gsub('center_x="19"','center_x="18"') end})
    rejects(function() create(h) end, 'changed since preview'); assert(import_count(h) == 0)
end)
test('changed output file is blocked before and after confirmation', function()
    local h = prepared({'CREATE 99'}); h.files['/test/la_result_test.xml'] = fixture
    rejects(function() create(h) end, 'changed'); assert(import_count(h) == 0)
    h = prepared({'CREATE 99'}, {on_confirm = function(_, files) files['/test/la_result_test.xml'] = fixture end})
    rejects(function() create(h) end, 'changed'); assert(import_count(h) == 0)
end)
test('successful create verifies coordinates and retains original', function()
    local h = prepared({'CREATE 99'}); assert(create(h)); assert(import_count(h) == 1)
    assert(h.layouts[1] == fixture and h.layouts[99] == h.plan.output)
    assert(#h.commands == 3)
    for _, cmd in ipairs(h.commands) do assert(not cmd:find('/nc',1,true) and not cmd:find('/overwrite',1,true)) end
end)
test('failed export/import is reported without retry or cleanup', function()
    local h = prepared({'CREATE 99'}, {export_failure = true})
    rejects(function() create(h) end, 'Cannot read'); assert(import_count(h) == 0)
    h = prepared({'CREATE 99'}, {import_failure = true})
    rejects(function() create(h) end, 'Import not verified'); assert(import_count(h) == 1 and #h.commands == 2)
end)
test('wrong round-trip coordinates report existing result without cleanup', function()
    local h = prepared({'CREATE 99'}, {corrupt_import = true})
    rejects(function() create(h) end, 'verification failed'); assert(h.layouts[99] and import_count(h) == 1)
end)
test('files never overwrite and command injection is rejected', function()
    local h = harness({}); h.files['/test/a.xml'] = 'keep'
    rejects(function() h.a.write_new('/test/a.xml','replace') end, 'overwrite'); assert(h.files['/test/a.xml'] == 'keep')
    for _, path in ipairs({'relative','/tmp/x"; Delete Layout 1','/tmp/x\nImport','/tmp/$x'}) do
        rejects(function() h.a.directory(path) end)
    end
    assert(h.a.directory('C:\\ProgramData\\MA Lighting\\importexport\\') == 'C:/ProgramData/MA Lighting/importexport')
    rejects(function() h.a.probe('Layout 1; Delete Layout 2') end)
end)
test('venue placements preserve pixel distances and move centroid', function()
    local m = model()
    local p = core.plan(m, {placements = {{fix_id=101, x=-16, y=12, rotation_delta=90}}})
    local after = core.read(p.output).by_fixture[101]
    near(after['1'].x,-16); near(after['1'].y,12)
    near(after['0'].x,-15.5); near(after['0'].y,11.133975)
    near(after['2'].x,-16.5); near(after['2'].y,12.866025)
    assert(#p.changes == 3)
    for key, before in pairs(m.by_fixture[201]) do
        near(core.read(p.output).by_fixture[201][key].x,before.x)
    end
end)
test('venue subset placement preserves unselected modules', function()
    local p = core.plan(model(), {placements={{fix_id=101,indices={'0','2'},x=0,y=0}}})
    local after = core.read(p.output).by_fixture[101]
    near(after['1'].x,10); near(after['1'].y,10)
    near((after['0'].x+after['2'].x)/2,0)
end)
test('venue placement rejects ambiguity and missing fixtures', function()
    rejects(function() core.plan(model(), {placements={{fix_id=999,x=0,y=0}}}) end, 'missing')
    rejects(function() core.plan(model(), {placements={{fix_id=101,x=0,y=0},{fix_id=101,x=1,y=1}}}) end, 'Repeated')
    rejects(function() core.plan(model(), {placements={}, jobs={}}) end, 'OR')
end)
test('normalized positions TSV is data only, supports BOM/CRLF', function()
    local c = core.parse_positions('\239\187\191fix_id\tx\ty\trotation_delta\r\n101\t-16\t12\t0\r\n')
    near(c.placements[1].x,-16)
    assert(#core.plan(model(),c).changes==3)
    for _, t in ipairs({'fix_id,x,y,rotation_delta\n101,1,2,0',
        'fix_id\tx\ty\trotation_delta\n101\t1\t2\t0\textra',
        'fix_id\tx\ty\trotation_delta\n101\tNaN\t2\t0',
        'fix_id\tx\ty\trotation_delta\n101;Delete\t1\t2\t0'}) do
        rejects(function() core.parse_positions(t) end)
    end
end)
test('scene preview and create use the same validated positions', function()
    for _, action in ipairs({'preview','create'}) do
        local h = harness({'scene','1','/test','scene_front.tsv',action,'99','CREATE 99'})
        h.files['/test/scene_front.tsv'] = 'fix_id\tx\ty\trotation_delta\n101\t-16\t12\t0\n'
        ui.run(h.g,h.fs)
        assert(import_count(h) == (action=='create' and 1 or 0))
        assert(h.layouts[1] == fixture)
        if action=='create' then near(core.read(h.layouts[99]).by_fixture[101]['1'].x,-16) end
    end
end)
test('export waits for complete XML and reuses parsed model', function()
    local h = harness({})
    local sleeps=0
    local saved
    h.g.cmd=function(command)
        saved=assert(command:match('"([%w_]+)"'))
        h.files['/test/'..saved..'.xml']='<MA'
    end
    h.g.sleep=function()
        sleeps=sleeps+1
        h.files['/test/'..saved..'.xml']=fixture
    end
    local text, _, m = h.a.export(1,'/test')
    assert(sleeps==1 and text==fixture and #m.elements==17)
end)
test('permanently truncated export times out without show mutation', function()
    local h = harness({})
    local sleeps=0
    h.g.cmd=function(command)
        local name=assert(command:match('"([%w_]+)"'))
        h.files['/test/'..name..'.xml']='<MA'
    end
    h.g.sleep=function() sleeps=sleeps+1 end
    rejects(function() h.a.export(1,'/test') end,'incomplete')
    assert(sleeps==50 and h.layouts[1]==fixture and not h.layouts[99])
end)
test('compiled affine transform matches independent sequential rotations', function()
    math.randomseed(20261107)
    for _=1,200 do
        local s={x=3,y=5,angle=math.random()*720-360}
        local t={x=-3,y=4,angle=math.random()*720-360,mirror=({'none','flip_x','flip_y'})[math.random(3)]}
        local px,py=math.random()*10,math.random()*10
        local u,v=core.rotate(px-s.x,py-s.y,-s.angle)
        if t.mirror=='flip_x' then u=-u elseif t.mirror=='flip_y' then v=-v end
        u,v=core.rotate(u,v,t.angle)
        local x,y=core.compile_transform(s,t)(px,py)
        near(x,u+t.x,1e-10);near(y,v+t.y,1e-10)
    end
end)
test('bundled plugin loads without global require/package and defaults to probe', function()
    local h = harness({'probe','1',''})
    local env = {gma = h.g}
    setmetatable(env, {__index = function(_, key) if key ~= 'require' and key ~= 'package' then return _G[key] end end})
    local entry = assert(loadfile('dist/layout_assistant.lua','t',env))()
    assert(type(entry) == 'function' and #h.commands == 0)
    entry(); assert(#h.commands == 0)
end)

for _, item in ipairs(tests) do
    local ok, err = pcall(item[2])
    if ok then passed = passed + 1; io.write('ok ', passed, ' - ', item[1], '\n')
    else io.stderr:write('FAIL - ', item[1], ': ', tostring(err), '\n'); os.exit(1) end
end
io.write(string.format('%d/%d tests passed; Lua %s. Real MA2/onPC not exercised.\n', passed, #tests, _VERSION))
