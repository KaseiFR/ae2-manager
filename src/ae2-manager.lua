--
-- Copyright 2019 KaseiFR <kaseifr@gmail.com>
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
--

local component = require('component')
local computer = require('computer')
local coroutine = require('coroutine')
local event = require('event')
local filesystem = require('filesystem')
local serialization = require('serialization')
local thread = require('thread')
local tty = require('tty')
local GUI = require('GUI')
-- local inspect = require('inspect')

-- Config --

-- Control how many CPUs to use. 0 is unlimited, negative to keep some CPU free, between 0 and 1 to reserve a share,
-- and greater than 1 to allocate a fixed number.
local allowedCpus = -2
-- Maximum size of the crafting requests
local maxBatch = 64
-- How often to check the AE system, in second
local checkInterval = 10
-- Where to save the config
local configPath = '/home/ae2-manager.cfg'

-- Global State --

-- array of recipe like { item, label, wanted, [current, crafting] }
local recipes = {}
-- various system status data
local status = {}
-- AE2 proxy
local ae2

-- Functions --

function main()
    local resetBColor, resetFColor = tty.gpu().getBackground(), tty.gpu().getForeground()

    initAe2()
    loadRecipes()
    --loadCraftables()
    ae2Run()

    local app = buildGui()

    -- Start some background tasks
    local background = {}
    table.insert(background, event.listen("key_up", function (key, address, char)
        if char == string.byte('q') then
            app:stop()
        end
    end))
    table.insert(background, event.listen("redraw", function (key) app:draw() end))
    table.insert(background, event.listen("reload_recipes", loadCraftables))
    table.insert(background, event.timer(.5, checkCrafting, math.huge))
    -- The AE loop is extremely slow (probably because of FFI or balance), and scale linearly with the number of recipes
    table.insert(background, thread.create(ae2Loop))

    -- Run the GUI until stopped
    local ok, err = xpcall(function ()
        app:draw(true)
        app:start()
    end, debug.traceback)

    -- Cleanup
    for _, b in ipairs(background) do
        if type(b) == 'table' and b.kill then
            b:kill()
        else
            event.cancel(b)
        end
    end

    tty.gpu().setBackground(resetBColor)
    tty.gpu().setForeground(resetFColor)
    tty.clear()

    if not ok then
        io.stderr:write(err)
        os.exit(1)
    end
end

function log(...)
    -- TODO: reserve a part of the screen for logs
    for i, v in ipairs{...} do
        if i > 1 then io.stderr:write(' ') end
        io.stderr:write(tostring(v))
    end
    io.stderr:write('\n')
end

function initAe2()
    local function test_ae2(id)
        local proxy = component.proxy(id)
        proxy.getCpus()
        return proxy
    end

    for id, type in pairs(component.list()) do
        -- print('Testing ' .. type .. ' ' .. id)
        local ok, p = pcall(test_ae2, id)
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
end

function loadRecipes()
    print('Loading config from '..configPath)
    local f, err = io.open(configPath, 'r')
    if not f then
        -- usually the file does not exist, on the first run
        print('Loading failed:', err)
        return
    end

    local content = serialization.unserialize(f:read('a'))

    f:close()

    recipes = content.recipes
    print('Loaded '..#recipes..' recipes')
end

function saveRecipes()
    local tmpPath = configPath..'.tmp'
    local content = { recipes={} }

    for _, recipe in ipairs(recipes) do
        table.insert(content.recipes, {
            item = recipe.item,
            label = recipe.label,
            wanted = recipe.wanted,
        })
    end

    local f = io.open(tmpPath, 'w')
    f:write(serialization.serialize(content))
    f:close()

    filesystem.remove(configPath) -- may fail

    local ok, err = os.rename(tmpPath, configPath)
    if not ok then error(err) end
end

-- Main loop --

function ae2Loop()
    while true do
        event.pull(checkInterval, 'ae2_loop')
        --log('AE2 loop in')
        ae2Run()
        --log('AE2 loop out')
        event.push('redraw')
    end
end


function ae2Run()
    local start = computer.uptime()
    updateRecipes()

    local finder = coroutine.create(findRecipeWork)
    while hasFreeCpu() do
        -- Find work
        local _, recipe, needed, craft = coroutine.resume(finder)
        if recipe then
            -- Request crafting
            local amount = math.min(needed, maxBatch)
            --log('Requesting ' .. amount .. ' ' .. recipe.label)
            recipe.crafting = craft.request(amount)
            yield('yield crafting')
            checkFuture(recipe) -- might fail very quickly (missing resource, ...)
        else
            break
        end
    end

    saveRecipes()

    local duration = computer.uptime() - start
    updateStatus(duration)
end

function checkCrafting()
    for _, recipe in ipairs(recipes) do
        if checkFuture(recipe) then
            --log('checkCrafting event !')
            event.push('ae2_loop')
            return
        end
    end
end

function yield(msg)
    --local gpu = tty.gpu()
    --local _, h = gpu.getViewport()
    --gpu.set(1, h, msg)
    os.sleep()
end

function loadCraftables()
    -- Find all AE craftables
    local craftables, err = ae2.getCraftables()
    if err then
        log('ae2.getCraftables', err)
        craftables = {}
    end
    for i, craftable in ipairs(craftables) do
        craftables[i] = craftable.getItemStack()
    end

    -- Ignore the craftables we already know
    for _, recipe in ipairs(recipes) do
        for i, candidate in ipairs(craftables) do
            if contains(candidate, recipe.item) then
                craftables[i] = nil
            end
        end
    end

    -- Add new recipes
    for _, craftable in ipairs(craftables) do
        table.insert(recipes, {
            item = {
                name = craftable.name,
                damage = math.floor(craftable.damage)
            },
            label = craftable.label,
            wanted = 0,
        })
    end
end

function updateRecipes()
    for _, recipe in ipairs(recipes) do
        recipe.error = nil

        checkFuture(recipe)

        -- TODO: bench query all items once vs lots of smaller queries
        yield('yield '..recipe.label)
        local items, err = ae2.getItemsInNetwork(recipe.item)
        if err then
            recipe.stored = 0
            recipe.error = 'ae2.getItemsInNetwork ' .. tostring(err)
        elseif #items == 0 then
            recipe.stored = 0
        elseif #items == 1 then
            local item = items[1]
            recipe.stored = math.floor(item.size)
            if not item.isCraftable then
                -- Warn the user as soon as an item is not craftable rather than wait to try
                recipe.error = 'Not craftable'
            end
        else
            recipe.stored = 0
            recipe.error = 'Match multiple item'
        end
    end
end

function updateStatus(duration)
    status.update = {
        duration = duration
    }

    -- CPU data
    local cpus = ae2.getCpus()
    status.cpu = {
        all = #cpus,
        free = 0,
    }
    for _, cpu in ipairs(cpus) do
        status.cpu.free = status.cpu.free + (cpu.busy and 0 or 1)
    end

    -- Recipe stats
    status.recipes = {
        error = 0,
        crafting = 0,
        queue = 0,
    }
    for _, recipe in ipairs(recipes) do
        if recipe.error then
            status.recipes.error = status.recipes.error + 1
        elseif recipe.crafting then
            status.recipes.crafting = status.recipes.crafting + 1
        elseif (recipe.stored or 0) < (recipe.wanted or 0) then
            status.recipes.queue = status.recipes.queue + 1
        end
    end
end

function checkFuture(recipe)
    if not recipe.crafting then return end

    local canceled, err = recipe.crafting.isCanceled()
    if canceled or err then
        --log('Crafting of ' .. recipe.label .. ' was cancelled')
        recipe.crafting = nil
        recipe.error = err or 'canceled'
        return true
    end

    local done, err = recipe.crafting.isDone()
    if err then error('isDone ' .. err) end
    if done then
        --log('Crafting of ' .. recipe.label .. ' is done')
        recipe.crafting = nil
        return true
    end

    return false
end

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

function contains(haystack, needle)
    if t1 == t2 then return true end
    if type(t1) ~= type(t2) or type(t1) ~= 'table' then return false end

    for k, v in pairs(needle) do
        if not contains(haystack[k], v) then return false end
    end

    return true
end

function hasFreeCpu()
    local cpus = ae2.getCpus()
    local free = 0
    for i, cpu in ipairs(cpus) do
        if not cpu.busy then free = free + 1 end
    end
    local ongoing = 0
    for _, recipe in ipairs(recipes) do
        if recipe.crafting then ongoing = ongoing + 1 end
    end

    if enoughCpus(#cpus, ongoing, free) then
        return true
    else
        --log('No CPU available')
        return false
    end
end

function enoughCpus(available, ongoing, free)
    if free == 0 then return false end
    if ongoing == 0 then return true end
    if allowedCpus == 0 then return true end
    if allowedCpus > 0 and allowedCpus < 1 then
        return  (ongoing + 1) / available <= allowedCpus
    end
    if allowedCpus >= 1 then
        return ongoing < allowedCpus
    end
    if allowedCpus > -1 then
        return (free - 1) / available <= -allowedCpus
    end
    return free > -allowedCpus
end

function findRecipeWork() --> yield (recipe, needed, craft)
    for i, recipe in ipairs(recipes) do
        if recipe.error or recipe.crafting then goto continue end

        local needed = recipe.wanted - recipe.stored
        if needed <= 0 then goto continue end

        yield('yield '..i)
        local craftables, err = ae2.getCraftables(recipe.item)
        --log('get_craftable', inspect(craftables))
        if err then
            recipe.error = 'ae2.getCraftables ' .. tostring(err)
        elseif #craftables == 0 then
            recipe.error = 'No crafting pattern found'
        elseif #craftables == 1 then
            coroutine.yield(recipe, needed, craftables[1])
        else
            recipe.error = 'Multiple crafting patterns'
        end

        ::continue::
    end
end

function override(object, method, fn)
    local super = object[method] or function() end
    object[method] = function(...)
        fn(super, ...)
    end
end

function numberValidator(str)
    n = tonumber(str, 10)
    return n and math.floor(n) == n
end

-- Stay close to the 16 Minecraft colors in order to work on gold GPU/screen
local C_BACKGROUND = 0x3C3C3C
local C_STATUS_BAR = 0xC3C3C3
local C_STATUS_TEXT = 0x1E1E1E
local C_STATUS_PRESSED = 0xFFFF00
local C_BADGE = 0xD2D2D2
local C_BADGE_ERR = 0xFF4900 --0xFFB6FF
local C_BADGE_BUSY = 0x336DFF
local C_BADGE_SELECTED = 0xFFAA00
local C_BADGE_TEXT = 0x1E1E1E
local C_INPUT = 0xFFFFFF
local C_INPUT_TEXT = 0x1E1E1E

function buildGui()
    local app = GUI.application()
    local statusBar = app:addChild(GUI.container(1, 1, app.width, 1))
    local window = app:addChild(GUI.container(1, 1 + statusBar.height, app.width, app.height - statusBar.height))

    window:addChild(GUI.panel(1, 1, window.width, window.height, C_BACKGROUND))
    local columns = math.floor(window.width / 60) + 1

    -- Crating queue view
    local craftingQueueView = window:addChild(GUI.layout(1, 1, window.width-1, window.height, columns, 1))
    for i = 1, columns do
        craftingQueueView:setAlignment(i, 1, GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP)
        craftingQueueView:setMargin(i, 1, .5, 1)
    end

    override(craftingQueueView, 'draw', function(super, self, ...)
        self.children = {}

        local added = 0
        for _, recipe in ipairs(recipes) do
            local color =
            recipe.error and C_BADGE_ERR or
                    recipe.crafting and C_BADGE_BUSY or
                    (recipe.stored or 0) < recipe.wanted and C_BADGE

            if color then
                local badge = GUI.container(1, 1, math.floor(self.width / columns - 1), 4)
                self:setPosition(1 + added % columns, 1, self:addChild(badge))
                badge:addChild(GUI.panel(1, 1, badge.width, 4, color))
                badge:addChild(GUI.text(2, 2, C_BADGE_TEXT, recipe.label)) -- TODO: include the item icon ?
                badge:addChild(GUI.text(2, 3, C_BADGE_TEXT, string.format('%s / %s', recipe.stored or '?', recipe.wanted)))
                if recipe.error then
                    badge:addChild(GUI.text(2, 4, C_BADGE_TEXT, tostring(recipe.error)))
                    badge:moveToFront()
                end

                added = added + 1
            end
        end

        super(self, ...)
    end)

    -- Configuration view
    local SYMBOL_CONFIG_RECIPE = {}
    local configView = window:addChild(GUI.container(1, 1, window.width, window.height))
    configView:addChild(GUI.panel(1, 1, configView.width, configView.height, C_BACKGROUND))
    configView.hidden = true

    -- left panel (item select)
    local itemListPanel = configView:addChild(GUI.list(2, 2, configView.width/2-1, configView.height-2, 1, 0,
            C_BADGE, C_BADGE_TEXT, C_STATUS_BAR, C_STATUS_TEXT, C_BADGE_SELECTED, C_BADGE_TEXT))
    itemListPanel.selectedItem = -1
    --itemListPanel:setAlignment(GUI.ALIGNMENT_HORIZONTAL_LEFT, GUI.ALIGNMENT_VERTICAL_TOP)

    -- TODO: allow filtering by name, status and scroll

    itemListPanel:addChild(GUI.text(5,5, 0xFF0000, "itemConfigPanel 2")) -- TODO

    override(itemListPanel, 'draw', function (super, ...)
        itemListPanel.children = {}

        for _, recipe in ipairs(recipes) do
            local choice = itemListPanel:addItem(recipe.label)
            --choice.colors.default.background = (recipe.error ~= nil) and C_BADGE_ERR or recipe.wanted > 0 and C_BADGE_BUSY or C_BADGE
            choice.onTouch = function(app, object)
                configView[SYMBOL_CONFIG_RECIPE] = recipe
                event.push('config_recipe_change')
            end
        end

        super(...)
    end)

    -- right panel (item details)
    local reloadBtn = configView:addChild(GUI.button(configView.width/2+2, 2, configView.width/2-2, 3, C_BADGE, C_BADGE_TEXT, C_BADGE, C_STATUS_PRESSED, "Reload recipes (slow)"))
    reloadBtn.onTouch = function(app, self)
        event.push('reload_recipes')
    end
    local itemConfigPanel = configView:addChild(GUI.layout(reloadBtn.x, reloadBtn.y + reloadBtn.height + 1, reloadBtn.width, configView.height-reloadBtn.height-3, 1, 1))
    configView:addChild(GUI.panel(itemConfigPanel.x, itemConfigPanel.y, itemConfigPanel.width, itemConfigPanel.height, C_BADGE)):moveBackward()
    itemConfigPanel:setAlignment(1, 1, GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP)
    itemConfigPanel:setMargin(1, 1, .5, 1)

    override(itemConfigPanel, 'eventHandler', function(super, app, self, key, ...)
        if key == "config_recipe_change" then
            local recipe = configView[SYMBOL_CONFIG_RECIPE]

            self.children = {}
            self:addChild(GUI.text(1, 1, C_BADGE_TEXT, '[ '..recipe.label..' ]'))
            self:addChild(GUI.text(1, 1, C_BADGE_TEXT, "Stored: "..tostring(recipe.stored)))
            self:addChild(GUI.text(1, 1, C_BADGE_TEXT, "Wanted"))
            local wantedInput = self:addChild(GUI.input(1, 1, 10, 3,
                    C_INPUT, C_INPUT_TEXT, 0, C_STATUS_PRESSED, C_INPUT_TEXT, tostring(recipe.wanted)))
            wantedInput.validator = numberValidator
            wantedInput.onInputFinished = function(app, object)
                recipe.wanted = tonumber(object.text) or error('cannot parse '..object.text)
                event.push('ae2_loop')
            end

            -- self:draw()
            event.push('redraw') -- There is probably a more elegant way to do it ¯\_(ツ)_/¯
        end
        super(app, self, key, ...)
    end)

    -- Status bar
    statusBar:addChild(GUI.panel(1, 1, statusBar.width, statusBar.height, C_STATUS_BAR))
    local statusText = statusBar:addChild(GUI.text(2, 1, C_STATUS_TEXT, ''))
    statusText.eventHandler = function(app, self)
        self.text = string.format('CPU: %d free / %d total   Recipes:  %d errors  %d ongoing  %d queued   Update: %.0f ms',
            status.cpu.free, status.cpu.all, status.recipes.error, status.recipes.crafting, status.recipes.queue, status.update.duration * 1000)
    end
    statusText.eventHandler(app, statusText)
    local cfgBtn = statusBar:addChild(GUI.button(statusBar.width - 14, 1, 8, 1, C_STATUS_BAR, C_STATUS_TEXT, C_STATUS_BAR, C_STATUS_PRESSED, '[Config]'))
    cfgBtn.switchMode = true
    cfgBtn.animationDuration = .1
    cfgBtn.onTouch = function(app, object)
        configView.hidden = not object.pressed
    end
    statusBar:addChild(GUI.button(statusBar.width - 6, 1, 8, 1, C_STATUS_BAR, C_STATUS_TEXT, C_STATUS_BAR, C_STATUS_PRESSED, '[Exit]')).onTouch = function(app, object)
        app:stop()
    end

    return app
end

-- Start the program
main()
