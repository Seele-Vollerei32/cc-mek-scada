-- Div (Division, like in HTML) Graphics Element

local element = require("graphics.element")

---@class div_args
---@field parent graphics_element
---@field x? integer 1 if omitted
---@field y? integer 1 if omitted
---@field width? integer parent width if omitted
---@field height? integer parent height if omitted
---@field gframe? graphics_frame frame instead of x/y/width/height
---@field fg_bg? cpair foreground/background colors

-- new div element
---@param args div_args
local function div(args)
    -- create new graphics element base object
    return element.new(args).get()
end

return div