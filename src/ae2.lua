component = require('component')
event = require('event')
inspect = require('inspect')
thread = require('thread')

-- Config --
local allowed_cpus = -2
local max_batch = 16
-- TODO: save on disk
local wanted = {
    {
        item={
            name = 'minecraft:glass',
            damage = 0
        },
        label = 'Glass',
        quantity = 1024,
    },
    {
        item={
            name = 'thermalfoundation:material',
            damage = 324
        },
        label = 'Aluminum Plate',
        quantity = 512,
    },
}

-- State --

-- table { item => future }
local ongoing_crafting = {}

-- Init --

local function test_ae2(id)
    local proxy = component.proxy(id)
    proxy.getCpus()
    return proxy
end

local ae2
for id, type in pairs(component.list()) do
    -- print('Testing ' .. type .. ' ' .. id)
    ok, p = pcall(test_ae2, id)
    if ok then
        print('Component ' .. type .. ' (' .. id .. ') is suitable')
        ae2 = p
    end
end

if ae2 == nil then
    error('No AE2 component found')
else
    print('Using component ' .. ae2.type .. ' (' .. ae2.address .. ')')
end

thread.create(function ()
    while True do
        print('Event', event.pull())
    end
end)

-- Main loop --

function mainLoop()
    -- Clean ongoing
    check_ongoing_crafting()

    -- Check CPUs
    if not has_free_cpu() then return end

    -- Check wanted items
    local spec, needed, craft = get_needed_craft()
    if not spec then return end

    -- Request crafting
    local amount = math.min(needed, max_batch)
    print('Requesting ' .. amount .. ' ' .. spec.label)
    future = craft.request(amount)
    --print(inspect(future))
    ongoing_crafting[spec.item] = future
end

-- Functions --

function equals(t1, t2)
    if t1 == t2 then return true end
    if type(t1) ~= type(t2) or type(t1) ~= 'table' then return false end

    for k1, v1 in pairs(t1) do
        local v2 = t2[k1]
        if not equals(v1, v2) then return false end
    end

    for k2, _ in pairs(t2) do
        if t1[k2] == nil then return false end
    end

    return true
end

function remove_if(arr, fn)
    local j = 1
    local len = #arr
    for i = 1, len do
        if fn(arr[i]) then
            arr[i] = nil
        else
            if (i > j) then
                arr[j] = arr[i]
                arr[i] = nil
            end
            j = j + 1
        end
    end
end

function get_stored(item)
    local found, err = ae2.getItemsInNetwork(item)
    if err then error('getItemsInNetwork ' .. err) end
    --print('get_stored', inspect(item), '=>',  inspect(found))
    if #found == 0 then
        return 0
    elseif #found == 1 then
        return found[1].size
    else
        print('Multiple items matching:', inspect(item), ':', inspect(found))
        return 1/0
    end
end

function get_craftable(item)
    local craftables, err = ae2.getCraftables(item)
    if err then error('getCraftables ' .. err) end
    --print('get_craftable', inspect(craftables))
    if #craftables == 0 then
        print('No crafting pattern found for ' .. inspect(item))
        return nil
    elseif #craftables == 1 then
        return craftables[1]
    else
        print('Multiple crafting pattern matching:', inspect(item), ':', inspect(craftables))
        return nil
    end
end

function get_needed_craft()
    for _, spec in ipairs(wanted) do
        if ongoing_crafting[spec.item] then goto continue end

        local stored = get_stored(spec.item)
        local needed = spec.quantity - stored
        if needed <= 0 then goto continue end

        local craft = get_craftable(spec.item)
        if craft then
            return spec, needed, craft
        end

        ::continue::
    end
    return nil, 0, nil
end

function has_free_cpu()
    local cpus = ae2.getCpus()
    local free_cpus = {}
    for i, cpu in ipairs(cpus) do
        if not cpu.busy then
            table.insert(free_cpus, cpu)
        end
    end
    if enough_cpus(#cpus, #ongoing_crafting, #free_cpus) then
        return true
    else
        print('No CPU available')
        return false
    end
end

function enough_cpus(available, ongoing, free)
    if free == 0 then return false end
    if mine == 0 then return true end
    if allowed_cpus == 0 then return true end
    if allowed_cpus > 0 and allowed_cpus < 1 then
        return  (ongoing + 1) / available <= allowed_cpus
    end
    if allowed_cpus >= 1 then
        return ongoing < allowed_cpus
    end
    if allowed_cpus > -1 then
        return (free - 1) / available <= -allowed_cpus
    end
    return free > -allowed_cpus
end

function check_ongoing_crafting()
    for item, future in pairs(ongoing_crafting) do
        canceled, err = future.isCanceled()
        if err then error('isCancelled ' .. err) end
        if canceled then
            print('Crafting of ' .. inspect(item) .. ' was cancelled')
            ongoing_crafting[item] = nil
        end

        done, err = future.isDone()
        if err then error('isDone ' .. err) end
        if done then
            print('Crafting of ' .. inspect(item) .. ' is done')
            ongoing_crafting[item] = nil
        end
    end
end

-- Start --

while true do
    mainLoop()
    os.sleep(1)
end
