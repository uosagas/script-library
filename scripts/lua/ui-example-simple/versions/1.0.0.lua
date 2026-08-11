-- @name        UI Example - Simple
-- @author      3HMonkey
-- @version     1.0.0
-- @tags        helpers
-- @description The smallest useful script window: labels, a live-updating
--              label, a button callback and a checkbox.

----------------------------------------------------------------------
--  UI Example - Simple
--
--  Shows the four things almost every script window needs:
--
--      1. A window with static text
--      2. A LIVE label: pass a function instead of a string and the
--         engine calls it on an interval and shows what it returns
--      3. A button that runs a callback when clicked
--      4. A checkbox that toggles something
--
--  Run it from the Lua tab while you are in game. Close the window
--  (or press Stop) to end the script.
----------------------------------------------------------------------

local clicks = 0

-- A window at screen position 200,200. Everything is added top to bottom.
local win = UI.Window('Hello Sagas', 200, 200)

win:Label('This is a static label.'):SetColor('#9CDCFE')

-- A live label: the function is evaluated twice a second (500 ms) and
-- the label always shows its latest return value.
local vitals = win:Label(function()
    return 'HP ' .. Player.Hits .. '/' .. Player.HitsMax
        .. '   Mana ' .. Player.Mana .. '/' .. Player.MaxMana
end, 500)
vitals:SetColor('#6FCF6F')

win:Separator()

-- A button with a click callback. The label object we got back above
-- can be changed at any time with SetText/SetColor.
local clickLabel = win:Label('The button was not clicked yet.')

win:Button('Click me', function()
    clicks = clicks + 1
    clickLabel:SetText('Clicked ' .. clicks .. ' time' .. (clicks == 1 and '' or 's') .. '.')
    Messages.Print('Hello from the script window! (' .. clicks .. ')', 68)
end)

-- A checkbox that hides or shows the live label.
win:Checkbox('Show vitals', true, function(checked)
    vitals:SetVisible(checked)
end)

win:Separator()
win:Button('Close', function() win:Close() end)

-- Hand control to the engine: keeps the window alive, delivers the
-- callbacks and live labels, returns when the window is closed.
win:Run()

Messages.Print('Simple UI example finished.', 88)
