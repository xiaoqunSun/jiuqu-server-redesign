local JQRichTextFormatModel = require "src/ui/components/reach/richtext/data/JQRichTextFormatModel"
local JQRichTextUtils = require("src/ui/components/reach/richtext/JQRichTextUtils")
local JQRichTextConstants = require("src/ui/components/reach/richtext/JQRichTextConstants")

local JQReviseRichTextFormatModel = class('JQReviseRichTextFormatModel', JQRichTextFormatModel)

function JQReviseRichTextFormatModel:ctor(data)
    JQReviseRichTextFormatModel.super.ctor(self, data)
end

function JQReviseRichTextFormatModel:initData(data)
    self.type = data.type or JQRichTextConstants.TYPES.TEXT
    self.text = data.text or ""
    self.fontName = data.fontName or JQRichTextConstants.FONT_NAME
    self.fontSize = data.fontSize or JQRichTextConstants.FONT_SIZE
    self.bold = data.bold or false
    self.underlineWidth = data.underlineWidth or 0
    self.resPath = data.resPath or ""
    self.imgSize = data.imgSize
    self.color = data.color or JQRichTextConstants.COLOR
    self.bgColor = data.bgColor
    self.hasBgColor = not (not self.bgColor)
    self.lineHeight = data.lineHeight or 0
    self.groupIndex = data.groupIndex or 0
    self.groupAlign = data.groupAlign or JQRichTextConstants.ALIGNMENT_LEFT
    self.lineIndex = data.lineIndex or 0
    self.tailWithLF = data.tailWithLF or false
    self:setNullString(data.nullString or false)
    self.clickable = data.clickable or false
    self.isTextSetup = false
    self.isReviseInsert = data.isReviseInsert or false
end

function JQReviseRichTextFormatModel:deleteLastChar()
    local curDeleteChar = ''
    if self.tailWithLF then
        self.tailWithLF = false
    elseif self.nullString then
        self.nullString = false
    else
        curDeleteChar = self:deleteChar(string.utf8len(self.text), 1)
    end
    return curDeleteChar
end

function JQReviseRichTextFormatModel:deleteChar(index, length)
    length = length or 1
    local toIndex = index + length - 1
    if toIndex > string.utf8len(self.text) then
        toIndex = string.utf8len(self.text)
    end
    local curDeleteChar = string.utf8sub(self.text,index, toIndex - index + 1)
    self.text = string.delete(self.text, index, toIndex, true)

    return curDeleteChar
end

function JQReviseRichTextFormatModel:insertChar(index, char)
    local text = string.insert(self.text, index, char,true)
    self:setText(text)
end

function JQReviseRichTextFormatModel:split(index, char, newFormat,isInsert)
    if self.nullString then
        return self:splitOnNullString(char, newFormat ,isInsert)
    elseif index > self:getOriginalLength() then
        return self:splitAtEnd(char, newFormat, false, isInsert)
    elseif index < 1 then
        return self:splitAtEnd(char, newFormat, true, isInsert)
    else
        return self:splitIn(index, char, newFormat, isInsert)
    end
end

function JQReviseRichTextFormatModel:splitOnNullString(char, newFormat , isInsert)
    local sections = {}
    local format = self:clone():merge(newFormat)
    format:setText(char)
    format.isReviseInsert = true
    table.insert(sections, format)
    --if char == "\n" then
    --    table.insert(sections, format:clone())
    --end
    return sections
end

function JQReviseRichTextFormatModel:splitAtEnd(char, newFormat, isHead , isInsert)
    local sections = {}
    local underLineWidth = isInsert and 0 or nil
    local format = self:clone(underLineWidth):merge(newFormat)
    format:setText(char)
    format:setTailWithLF(false)
    table.insert(sections, format)
    if isInsert then
        format.isReviseInsert = true
        format:setUnderlineWidth(underLineWidth)
    else
        format.isReviseInsert = false
    end

    local newSection = self:clone()
    if self.isReviseInsert then
        newSection.isReviseInsert = true
    end
    if isHead then
        table.insert(sections, newSection)
    else
        table.insert(sections, 1, newSection)
    end
    return sections
end

function JQReviseRichTextFormatModel:splitIn(index, char, newFormat , isInsert)
    local beganIndex, endedIndex = index, index - 1
    local divisions = self:divide(beganIndex, endedIndex)

    local sections = {}
    table.foreach(divisions, function(divisionIndex, division)
        local format = self:clone()
        if self.isReviseInsert and isInsert then
            format.isReviseInsert = true
        else
            format.isReviseInsert = false
        end
        if division[1] == beganIndex and division[2] == endedIndex then
            format:merge(newFormat)
            format:setText(char)
            if isInsert then
                format.isReviseInsert = true
            end
        else
            format:setText(string.utf8sub(self.text, division[1], division[2] - division[1] + 1))
        end
        if divisionIndex ~= #divisions then
            format:setTailWithLF(false)
        else
            format:setTailWithLF(self.tailWithLF)
        end
        table.insert(sections, format)
    end)
    return sections
end

function JQReviseRichTextFormatModel:clone(underLineWidth)
    return JQReviseRichTextFormatModel.new({
        type = self.type,
        text = self.text,
        fontName = self.fontName,
        fontSize = self.fontSize,
        bold = self.bold,
        underlineWidth = underLineWidth or self.underlineWidth,
        resPath = self.resPath,
        imgSize = self.imgSize and {width = self.imgSize.width, height = self.imgSize.height},
        color = {r = self.color.r, g = self.color.g, b = self.color.b},
        bgColor = self.bgColor and {r = self.bgColor.r, g = self.bgColor.g, b = self.bgColor.b},
        lineHeight = self.lineHeight,
        hasBgColor = self.hasBgColor,
        groupIndex = self.groupIndex,
        groupAlign = self.groupAlign,
        lineIndex = self.lineIndex,
        tailWithLF = self.tailWithLF,
        nullString = self.nullString,
        clickable = self.clickable,
        isReviseInsert = self.isReviseInsert
    })
end

return JQReviseRichTextFormatModel