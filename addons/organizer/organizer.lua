--Copyright (c) 2015, Byrthnoth and Rooks
--All rights reserved.

--Redistribution and use in source and binary forms, with or without
--modification, are permitted provided that the following conditions are met:

--    * Redistributions of source code must retain the above copyright
--      notice, this list of conditions and the following disclaimer.
--    * Redistributions in binary form must reproduce the above copyright
--      notice, this list of conditions and the following disclaimer in the
--      documentation and/or other materials provided with the distribution.
--    * Neither the name of <addon name> nor the
--      names of its contributors may be used to endorse or promote products
--      derived from this software without specific prior written permission.

--THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
--ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
--WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
--DISCLAIMED. IN NO EVENT SHALL <your name> BE LIABLE FOR ANY
--DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
--(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
--LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
--ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
--(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
--SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

res = require 'resources'
files = require 'files'
require 'pack'
Items = require 'items'
extdata = require 'extdata'
logger = require 'logger'
require 'tables'
require 'lists'
require 'functions'
config = require 'config'

_addon.name = 'Organizer'
_addon.author = 'Byrth, maintainer: Rooks'
_addon.version = 0.150324
_addon.commands = {'organizer','org'}

_static = {
    bag_ids = {
        inventory=0,
        safe=1,
        storage=2,
        temporary=3,
        locker=4,
        satchel=5,
        sack=6,
        case=7,
        wardrobe=8,
    },
    bag_commands = {
        "dance3",
        "bank",
        "storage",
        "sigh",
        "locker",
        "satchel",
        "sack",
        "case",
        "wardrobe"
    }
}

_global = {
    language = 'english',
    language_log = 'english_log',
}

default_settings = {
    dump_bags = {['Safe']=1,['Locker']=2,['Storage']=3},
    bag_priority = {['Safe']=1,['Locker']=2,['Storage']=3,['Satchel']=4,['Sack']=5,['Case']=6,['Inventory']=7,['Wardrobe']=8},
    item_delay = 0,
    auto_heal = false,
    default_file='default.lua',
    verbose=false,
}

_debugging = {
    warnings = false, -- This mode gives warnings about impossible item movements.
}

function s_to_bag(str)
    if not str and tostring(str) then return end
    for i,v in pairs(res.bags) do
        if v.en:lower() == str:lower() then
            return v.id
        end
    end
end

windower.register_event('load',function()
    if debugging then windower.debug('load') end
    options_load()
end)

function options_load( )
    if not windower.dir_exists(windower.addon_path..'data\\') then
        windower.create_dir(windower.addon_path..'data\\')
        if not windower.dir_exists(windower.addon_path..'data\\') then
            org_error("unable to create data directory!")
        end
    end

    for bag_name, bag_id in pairs(_static.bag_ids) do
        if not windower.dir_exists(windower.addon_path..'data\\'..bag_name) then
            windower.create_dir(windower.addon_path..'data\\'..bag_name)
            if not windower.dir_exists(windower.addon_path..'data\\'..bag_name) then
                org_error("unable to create"..bag_name.."directory!")
            end
        end
    end

    settings = config.load(default_settings)
end



windower.register_event('addon command',function(...)
    local inp = {...}
    -- get (g) = Take the passed file and move everything to its defined location.
    -- tidy (t) = Take the passed file and move everything that isn't in it out of my active inventory.
    -- organize (o) = get followed by tidy.
    local command = table.remove(inp,1):lower()
    if command == 'eval' then
        assert(loadstring(table.concat(inp,' ')))()
        return
    end

    local bag = 'all'
    if inp[1] and (_static.bag_ids[inp[1]:lower()] or inp[1]:lower() == 'all') then
        bag = table.remove(inp,1):lower()
    end

    file_name = table.concat(inp,' ')
    if string.length(file_name) == 0 then
        file_name = default_file_name()
    end

    if file_name:sub(-4) ~= '.lua' then
        file_name = file_name..'.lua'
    end


    if (command == 'g' or command == 'get') then
        get(thaw(file_name, bag))
    elseif (command == 't' or command == 'tidy') then
        tidy(thaw(file_name, bag))
    elseif (command == 'f' or command == 'freeze') then

        local items = Items.new(windower.ffxi.get_items(),true)
        items[3] = nil -- Don't export temporary items
        if _static.bag_ids[bag] then
            freeze(file_name,bag,items)
        else
            for bag_id,item_list in items:it() do
                freeze(file_name,res.bags[bag_id].english:lower(),items)
            end
        end
    elseif (command == 'o' or command == 'organize') then
        organize(thaw(file_name, bag))        
    end

    if settings.auto_heal and tostring(settings.auto_heal):lower() ~= 'false' then
        windower.send_command('input /heal')
    end

end)

function get(goal_items,current_items)
    org_verbose('Getting!')
    if goal_items then
        count = 0
        failed = 0
        current_items = current_items or Items.new()
        goal_items, current_items = clean_goal(goal_items,current_items)
        for bag_id,inv in goal_items:it() do
            for ind,item in inv:it() do
                if not item:annihilated() then
                    local start_bag, start_ind = current_items:find(item)
                    -- Table contains a list of {bag, pos, count}
                    if start_bag then
                        if not current_items:route(start_bag,start_ind,bag_id) then
                            org_warning('Unable to move item.')
                            failed = failed + 1
                        else
                            count = count + 1
                        end
                    else
                        -- Need to adapt this for stacking items somehow.
                        org_warning(res.items[item.id].english..' not found.')
                    end
                    simulate_item_delay()
                end
            end
        end
        org_verbose("Got "..count.." item(s), and failed getting "..failed.." item(s)")
    end
    return goal_items, current_items
end

function freeze(file_name,bag,items)
    local lua_export = T{}
    for _,item_table in items[_static.bag_ids[bag]]:it() do
        local temp_ext,augments = extdata.decode(item_table)
        if temp_ext.augments then
            augments = table.filter(temp_ext.augments,-functions.equals('none'))
        end
        lua_export:append({name = item_table.name,log_name=item_table.log_name,
            id=item_table.id,extdata=item_table.extdata:hex(),augments = augments,count=item_table.count})
    end
    -- Make sure we have something in the bag at all
    if lua_export[1] then
        org_verbose("Freezing "..tostring(bag)..".")
        local export_file = files.new('/data/'..bag..'/'..file_name,true)
        export_file:write('return '..lua_export:tovstring({'augments','log_name','name','id','count','extdata'}))
    end
end

function tidy(goal_items,current_items,usable_bags)
    -- Move everything out of items[0] and into other inventories (defined by the passed table)
    if goal_items and goal_items[0] and goal_items[0]._info.n > 0 then
        current_items = current_items or Items.new()
        goal_items, current_items = clean_goal(goal_items,current_items)
        for index,item in current_items[0]:it() do
            if not goal_items[0]:contains(item,true) then
                current_items[0][index]:put_away(usable_bags)
            end
            simulate_item_delay()
        end
    end
    return goal_items, current_items
end

function organize(goal_items)
    org_message('Starting...')
    local current_items = Items.new()
    local dump_bags = {}
    for i,v in pairs(settings.dump_bags) do
        if i and s_to_bag(i) then
            dump_bags[tonumber(v)] = s_to_bag(i)
        elseif i then
            org_error('The bag name ("'..tostring(i)..'") in dump_bags entry #'..tostring(v)..' in the ../addons/organizer/data/settings.xml file is not valid.\nValid options are '..tostring(res.bags))
            return
        end
    end
    if current_items[0].n == 80 then
        tidy(goal_items,current_items,dump_bags)
    end
    if current_items[0].n == 80 then
        org_error('Unable to make space, aborting!')
        return
    end
    
    local remainder = math.huge
    while remainder do
        goal_items, current_items = get(goal_items,current_items)
        
        goal_items, current_items = clean_goal(goal_items,current_items)
        goal_items, current_items = tidy(goal_items,current_items,dump_bags)
        remainder = incompletion_check(goal_items,remainder)
        org_verbose(tostring(remainder)..' '..current_items[0]._info.n,1)
    end
    goal_items, current_items = tidy(goal_items,current_items)
    
    local count,failures = 0,T{}
    for bag_id,bag in goal_items:it() do
        for ind,item in bag:it() do
            if item:annihilated() then
                count = count + 1
            else
                item.bag_id = bag_id
                failures:append(item)
            end
        end
    end
    org_message('Done! - '..count..' items matched and '..table.length(failures)..' items missing!')
    if table.length(failures) > 0 then
        for i,v in failures:it() do
            org_verbose('Item Missing: '..i.name..' '..(i.augments and tostring(T(i.augments)) or ''))
        end
    end
end

function clean_goal(goal_items,current_items)
    for i,inv in goal_items:it() do
        for ind,item in inv:it() do
            local potential_ind = current_items[i]:contains(item)
            if potential_ind then
                -- If it is already in the right spot, delete it from the goal items and annihilate it.
                local count = math.min(goal_items[i][ind].count,current_items[i][potential_ind].count)
                goal_items[i][ind]:annihilate(goal_items[i][ind].count)
                current_items[i][potential_ind]:annihilate(current_items[i][potential_ind].count)
            end
        end
    end
    return goal_items, current_items
end

function incompletion_check(goal_items,remainder)
    -- Does not work. On cycle 1, you fill up your inventory without purging unnecessary stuff out.
    -- On cycle 2, your inventory is full. A gentler version of tidy needs to be in the loop somehow.
    local remaining = 0
    for i,v in goal_items:it() do
        for n,m in v:it() do
            if not m:annihilated() then
                remaining = remaining + 1
            end
        end
    end
    return remaining ~= 0 and remaining < remainder and remaining
end

function thaw(file_name,bag)
    local bags = _static.bag_ids[bag] and {[bag]=file_name} or table.reassign({},_static.bag_ids) -- One bag name or all of them if no bag is specified
    if settings.default_file:sub(-4) ~= '.lua' then
        settings.default_file = settings.default_file..'.lua'
    end
    for i,v in pairs(_static.bag_ids) do
        bags[i] = bags[i] and windower.file_exists(windower.addon_path..'data/'..i..'/'..file_name) and file_name or settings.default_file
    end
    bags.temporary = nil
    local inv_structure = {}
    for cur_bag,file in pairs(bags) do
        local f,err = loadfile(windower.addon_path..'data/'..cur_bag..'/'..file)
        if f and not err then
            local success = false
            success, inv_structure[cur_bag] = pcall(f)
            if not success then
                org_warning('User File Error (Syntax) - '..inv_structure[cur_bag])
                inv_structure[cur_bag] = nil
            end
        elseif bag and cur_bag:lower() == bag:lower() then
            org_warning('User File Error (Loading) - '..err)
        end
    end
    -- Convert all the extdata back to a normal string
    for i,v in pairs(inv_structure) do
        for n,m in pairs(v) do
            if m.extdata then
                inv_structure[i][n].extdata = string.parse_hex(m.extdata)
            end
        end
    end
    return Items.new(inv_structure)
end

function org_message(msg,col)
    windower.add_to_chat(col or 8,'Organizer: '..msg)
end

function org_warning(msg)
    if _debugging.warnings then
        windower.add_to_chat(123,'Organizer: '..msg)
    end
end

function org_error(msg)
    error('Organizer: '..msg)
end

function org_verbose(msg,col)
    if tostring(settings.verbose):lower() ~= 'false' then
        windower.add_to_chat(col or 8,'Organizer: '..msg)
    end
end

function default_file_name()
    player = windower.ffxi.get_player()
    job_name = res.jobs[player.main_job_id]['english_short']
    return player.name..'_'..job_name..'.lua'
end

function simulate_item_delay()
    if settings.item_delay and settings.item_delay > 0 then
        coroutine.sleep(settings.item_delay)
    end
end