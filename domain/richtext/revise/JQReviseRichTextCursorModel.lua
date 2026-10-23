local JQRichTextCursorModel = require "src/ui/components/reach/richtext/data/JQRichTextCursorModel"
local JQReviseRichTextFormatModel = require "src/ui/components/reach/richtext/revise/JQReviseRichTextFormatModel"

local JQReviseRichTextCursorModel = class('JQReviseRichTextCursorModel', JQRichTextCursorModel)

function JQReviseRichTextCursorModel:ctor(data)
    JQReviseRichTextCursorModel.super.ctor(self, data)
end

function JQReviseRichTextCursorModel:initData(data)
    data = data or {}
    self.format = data.defaultFormat or JQReviseRichTextFormatModel.new()
    self.beganIndex = data.beganIndex or -1
    self.endedIndex = data.endedIndex or -1
    self.beganInFront = data.beganInFront or false
    self.endedInFront = data.endedInFront or false
end

return JQReviseRichTextCursorModel