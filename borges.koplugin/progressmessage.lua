-- Three dots with a slow partial refresh, suitable for an e-ink display.
-- The parent UI owns this widget; network work must yield through Background.
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Size = require("ui/size")

local ProgressMessage = InfoMessage:extend{ dismissable = false }
local frames = { "● ○ ○", "○ ● ○", "○ ○ ●" }

function ProgressMessage:init()
    local width = math.floor(Screen:getWidth() * 2 / 3)
    self.face = self.face or Font:getFace("infofont")
    self.dots = TextWidget:new{ text = frames[1], face = self.face }
    self.movable = MovableContainer:new{
        unmovable = true,
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            radius = Size.radius.window,
            VerticalGroup:new{
                align = "center",
                TextBoxWidget:new{ text = self.text, face = self.face, width = width, alignment = "center" },
                VerticalSpan:new{ width = Size.padding.default },
                CenterContainer:new{ dimen = { w = width, h = self.dots:getSize().h }, self.dots },
            },
        },
    }
    self[1] = CenterContainer:new{ dimen = Screen:getSize(), self.movable }
end

function ProgressMessage:onShow()
    InfoMessage.onShow(self)
    self.active = true
    self.frame_index = 1
    self.tick = self.tick or function()
        if not self.active then return end
        self.frame_index = self.frame_index % #frames + 1
        self.dots:setText(frames[self.frame_index])
        UIManager:setDirty(self, "ui", self.movable.dimen)
        UIManager:scheduleIn(0.7, self.tick)
    end
    UIManager:unschedule(self.tick)
    UIManager:scheduleIn(0.7, self.tick)
    return true
end

function ProgressMessage:onCloseWidget()
    self.active = false
    if self.tick then UIManager:unschedule(self.tick) end
    return InfoMessage.onCloseWidget(self)
end

return ProgressMessage
