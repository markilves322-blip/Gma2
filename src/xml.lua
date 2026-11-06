-- A deliberately restricted, span-preserving reader for grandMA2 exports.
-- No entity expansion, DTD, schema fetching, or execution of input data.
local M = {}
local function check(v, message) if not v then error(message, 0) end return v end

function M.parse(text)
    check(type(text) == 'string' and #text <= 16 * 1024 * 1024, 'XML: invalid size (max 16 MiB)')
    local doc = {name = '#document', children = {}, text = text}
    local stack, pos, count = {doc}, 1, 0
    while true do
        local s = text:find('<', pos, true)
        local between = text:sub(pos, s and s - 1 or #text)
        if #stack == 1 then
            if pos == 1 then between = between:gsub('^\239\187\191', '') end
            check(between:match('^%s*$'), 'XML: text outside root')
        end
        if not s then break end
        if text:sub(s, s + 3) == '<!--' then
            local e = check(text:find('-->', s + 4, true), 'XML: unclosed comment')
            pos = e + 3
        elseif text:sub(s, s + 1) == '<?' then
            local e = check(text:find('?>', s + 2, true), 'XML: unclosed processing instruction')
            pos = e + 2
        else
            check(text:sub(s, s + 1) ~= '<!', 'XML: DTD/CDATA/declarations unsupported')
            local i, quote = s + 1, nil
            while i <= #text do
                local c = text:sub(i, i)
                if quote then if c == quote then quote = nil end
                elseif c == '"' or c == "'" then quote = c
                elseif c == '>' then break end
                i = i + 1
            end
            check(i <= #text, 'XML: unclosed tag')
            local raw = text:sub(s, i)
            local closing = raw:match('^</([%w_:.-]+)%s*>$')
            if closing then
                check(#stack > 1 and stack[#stack].name == closing, 'XML: mismatched closing tag')
                stack[#stack].finish = i
                table.remove(stack)
            else
                local name, after = raw:match('^<([%w_:.-]+)()')
                check(name, 'XML: invalid tag')
                local node = {name = name, start = s, open_end = i, attrs = {}, children = {}}
                local tail = raw:match('/%s*>$') and '/%s*>$' or '>%s*$'
                local cursor = after
                while true do
                    local rest = raw:sub(cursor)
                    if rest:match('^%s*' .. tail) then break end
                    local a, b, key, q, value, vs, ve
                    a, b, key, q = rest:find('^%s+([%w_:.-]+)%s*=%s*([\'\"])')
                    check(a, 'XML: malformed attributes')
                    vs = cursor + b
                    ve = check(raw:find(q, vs, true), 'XML: unclosed attribute') - 1
                    value = raw:sub(vs, ve)
                    check(not node.attrs[key] and not value:find('<', 1, true), 'XML: duplicate/invalid attribute')
                    node.attrs[key] = {value = value, first = s + vs - 1, last = s + ve - 1}
                    cursor = ve + 2
                end
                local parent = stack[#stack]
                node.parent = parent
                parent.children[#parent.children + 1] = node
                count = count + 1
                check(count <= 200000 and #stack < 64, 'XML: complexity limit')
                if raw:match('/%s*>$') then node.finish = i else stack[#stack + 1] = node end
            end
            pos = i + 1
        end
    end
    check(#stack == 1 and #doc.children == 1, 'XML: expected one complete root')
    return doc
end

function M.value(node, key)
    return node.attrs[key] and node.attrs[key].value
end

function M.children(node, name)
    local out = {}
    for _, child in ipairs(node.children) do
        if child.name == name then out[#out + 1] = child end
    end
    return out
end

function M.one(node, name)
    local found = M.children(node, name)
    check(#found == 1, 'XML: expected one ' .. name)
    return found[1]
end

function M.patch(text, edits)
    table.sort(edits, function(a, b) return a.first < b.first end)
    local out, cursor = {}, 1
    for _, edit in ipairs(edits) do
        check(edit.first >= cursor and edit.last >= edit.first, 'XML: overlapping edits')
        out[#out + 1] = text:sub(cursor, edit.first - 1)
        out[#out + 1] = edit.value
        cursor = edit.last + 1
    end
    out[#out + 1] = text:sub(cursor)
    return table.concat(out)
end
return M
