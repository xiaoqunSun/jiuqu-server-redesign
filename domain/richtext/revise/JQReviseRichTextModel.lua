local JQRichTextModel = require "src/ui/components/reach/richtext/data/JQRichTextModel"
local JQReviseRichTextFormatModel = require "src/ui/components/reach/richtext/revise/JQReviseRichTextFormatModel"
local JQReviseRichTextCursorModel = require "src/ui/components/reach/richtext/revise/JQReviseRichTextCursorModel"
local JQRichTextUtils = require("src/ui/components/reach/richtext/JQRichTextUtils")
local JQRichTextConstants = require("src/ui/components/reach/richtext/JQRichTextConstants")

local JQReviseRichTextModel = class('JQReviseRichTextFormatModel', JQRichTextModel)

function JQReviseRichTextModel:ctor(data)
    JQReviseRichTextModel.super.ctor(self, data)

    self.isRevisionMode = data.isRevise or false
end

function JQReviseRichTextModel:initData(data)
    data = data or {}
    self.isFixedGroupAlign = false
    self.defaultFormat = data.defaultFormat or JQReviseRichTextFormatModel.new()
    self.dataNotification = ternary(data.dataNotification == false, false, true)
    self.formats = {}
    self.cursors = {}
    self.backupFormats = {}
    self.backupCursors = {}
    self:setText(data.text)
end

function JQReviseRichTextModel:setDefaultFormat(defaultFormat)
    self.defaultFormat = defaultFormat
end

function JQReviseRichTextModel:mergeDefaultFormat(defaultFormat)
    self.defaultFormat:merge(defaultFormat)
 end
 
 function JQReviseRichTextModel:setFixedGroupAlign(isFixed)
    self.isFixedGroupAlign = isFixed
 end

function JQReviseRichTextModel:insertChar(uid, char, isFromReplay)
    local cursor = self:getOrCreateCursor(uid)
    local index, formatIndex, charIndex, inFront
    index, inFront = cursor:getEndedIndex()

    formatIndex, charIndex, inFront = self:getFormatIndicesByIndex(index, inFront)
    local format = self.formats[formatIndex]
    local insertingCharIndex = inFront and charIndex or charIndex + 1
    local newIndex, newInFront = index, inFront

    local newFormat = format:clone(0)
    newFormat.color = JQRichTextConstants.REVISE_INPUT_COLOR
    local sections = format:split(insertingCharIndex, char,newFormat,true)
    self:switchLF(sections)
    self:mergeFormat(sections, true)
    table.remove(self.formats, formatIndex)
    table.foreach(sections, function(i, section)
        table.insert(self.formats, formatIndex + i - 1, section)
    end)

    
    newIndex, newInFront = index + (inFront and 0 or string.utf8len(char)), false
    cursor:setIndices(newIndex, newInFront)

    self:mergeFormat(self.formats, false)
    self:adjustFormatGroupIndex()
    self:updateCursorGroupByFormatIndex(uid, isFromReplay)
    self:updateOtherCursorIndicesByInsert(uid, index, inFront, char)

    if self.dataNotification and not isFromReplay then
        self:dispatchChangedEvent()
    end
end

function JQReviseRichTextModel:getFormatIndicesByIndex(charIndex, inFront)
    for formatIndex, format in ipairs(self.formats) do
        local length = format:getOriginalLength()
        if length > charIndex then
            return formatIndex, charIndex, inFront
        elseif length == charIndex then
            if not format.tailWithLF or (format.tailWithLF and inFront) then
                return formatIndex, charIndex, inFront
            end
        end
        charIndex = charIndex - length
    end
    charIndex, inFront = self.formats[#self.formats]:getOriginalLength(), false
    return #self.formats, charIndex, inFront
end

function JQReviseRichTextModel:deleteAheadCharSingle(uid, isFromReplay)
    local cursor = self:getOrCreateCursor(uid)
    local index, formatIndex, charIndex, inFront
    index, inFront = cursor:getEndedIndex()
    formatIndex, charIndex, inFront = self:getFormatIndicesByIndex(index, inFront)
    local format = self.formats[formatIndex]
    local frontFormat = self.formats[formatIndex - 1]
    local deletingCharIndex = inFront and charIndex - 1 or charIndex
    local newIndex, newFormatIndex, newCharIndex, newInFront = index, formatIndex, charIndex, inFront
    local curDeleteChar = ''

    if deletingCharIndex > 0 then
        newFormatIndex, newCharIndex, newInFront ,curDeleteChar = self:deleteAheadCharInNode(formatIndex, deletingCharIndex, inFront)
    elseif formatIndex > 1 then
        newFormatIndex, newCharIndex, newInFront ,curDeleteChar = self:deleteAheadCharAstrideNode(formatIndex, deletingCharIndex, inFront)
    end

    if newFormatIndex == 1 and newCharIndex < 1 then
        newFormatIndex, newInFront = 1, true
    end

    newIndex, newInFront = self:getIndexByFormatIndices(newFormatIndex, newCharIndex, newInFront)

    cursor:setIndices(newIndex, newInFront)
    self:updateCursorGroupByFormatIndex(uid, isFromReplay)
    self:mergeFormat(self.formats, false)
    self:updateOtherCursorIndicesByDeleteAhead(uid, index, inFront)

    self:handleReviseInsertChar(uid,format,frontFormat,deletingCharIndex,curDeleteChar,false,isFromReplay)

    self:deleteFirstNullFormats(uid , isFromReplay)
end

function JQReviseRichTextModel:handleReviseInsertChar(uid,format,frontFormat,deletingCharIndex,curDeleteChar,isBehind,isFromReplay)    
    if deletingCharIndex == 0 then
        if frontFormat and not frontFormat.isReviseInsert then
            self:reviseInsertChar(uid,curDeleteChar,isBehind,isFromReplay,frontFormat)
        end
    else
        if format and not format.isReviseInsert then
            self:reviseInsertChar(uid,curDeleteChar,isBehind,isFromReplay,format)
        end
    end
end

function JQReviseRichTextModel:getIndexByFormatIndices(formatIndex, charIndex, inFront)
    local index = 0
    for i = 1, formatIndex - 1 do
        index = index + self.formats[i]:getOriginalLength()
    end
    local originalLength = self.formats[formatIndex]:getOriginalLength()
    if charIndex <= 0 then
        charIndex, inFront = 1, true
    end
    if charIndex > originalLength then
        charIndex, inFront = originalLength, false
    end
    index = index + charIndex
    return index, inFront
end

function JQReviseRichTextModel:deleteFirstNullFormats(uid, isFromReplay)
    if #self.formats > 1 and self.formats[1].text == '' then
        table.remove(self.formats, 1)
        self:mergeFormat(self.formats, false)
        self:adjustFormatGroupIndex()
        self:updateCursorGroupByFormatIndex(uid, isFromReplay)
    end
end

function JQReviseRichTextModel:deleteBehindCharSingle(uid, isFromReplay)
    local cursor = self:getOrCreateCursor(uid)
    local index, formatIndex, charIndex, inFront
    index, inFront = cursor:getEndedIndex()
    formatIndex, charIndex, inFront = self:getFormatIndicesByIndex(index, inFront)

    local format = self.formats[formatIndex]
    local deletingCharIndex = inFront and charIndex or charIndex + 1
    local newIndex, newFormatIndex, newCharIndex, newInFront = index, formatIndex, charIndex, inFront

    local curDeleteChar = ''
    local deleted = false
    if deletingCharIndex <= format:getLength() then
        newFormatIndex, newCharIndex, newInFront, curDeleteChar = self:deleteBehindCharInNode(formatIndex, deletingCharIndex, inFront)
    elseif formatIndex < #self.formats then
        newFormatIndex, newCharIndex, newInFront, curDeleteChar = self:deleteBehindCharAstrideNode(formatIndex)
    end

    newIndex, newInFront = self:getIndexByFormatIndices(newFormatIndex, newCharIndex, newInFront)
    cursor:setIndices(newIndex, newInFront)
    self:updateCursorGroupByFormatIndex(uid, isFromReplay)
    self:mergeFormat(self.formats, false)

    if not format.isReviseInsert then
        self:reviseBehindInsertChar(uid,curDeleteChar,formatIndex,isFromReplay)
    end

    self:deleteFirstNullFormats(uid, isFromReplay)
end

function JQReviseRichTextModel:updateCursorGroupByFormatIndex(uid, isFromReplay)
    local cursor = self:getOrCreateCursor(uid)
    local index, inFront = cursor:getEndedIndex()
    local formatIndex = self:getFormatIndicesByIndex(index, inFront)
    local groupAlign = self.formats[formatIndex].groupAlign
    local groupIndex = self.formats[formatIndex].groupIndex
    cursor:updateFormatByName(JQRichTextConstants.HTML.FORMAT_GROUP_INDEX, groupIndex)
    cursor:updateFormatByName(JQRichTextConstants.HTML.FORMAT_GROUP_ALIGN, groupAlign)
    if self.dataNotification and not isFromReplay then
        self:dispatchEvent({name = JQRichTextModel.EVENT_CURSOR_FORMAT_CHANGED,
                            uid = uid,
                            formatName = JQRichTextConstants.HTML.FORMAT_GROUP_ALIGN,
                            formatValue = groupAlign,
                            groupIndex = groupIndex})
    end
end

function JQReviseRichTextModel:deleteBehindCharAstrideNode(formatIndex)
    local format = self.formats[formatIndex]
    local nextFormatIndex = formatIndex + 1
    local nextFormat = self.formats[nextFormatIndex]
    local curDeleteChar = ''
    if format.groupIndex ~= nextFormat.groupIndex then
        if format.tailWithLF then
            curDeleteChar = format:deleteLastChar()
        end
        self:setGroupFromIndex(nextFormatIndex, format.groupIndex, format.groupAlign)
    else
        if format.tailWithLF then
            curDeleteChar = format:deleteLastChar()
        else
            curDeleteChar = nextFormat:deleteChar(1, 1)
        end
    end
    return nextFormatIndex, 1, true, curDeleteChar
end

function JQReviseRichTextModel:deleteBehindCharInNode(formatIndex, charIndex, inFront)
    local format = self.formats[formatIndex]
    local curDeleteChar = ''
    if charIndex <= format:getLength() then
        curDeleteChar = format:deleteChar(charIndex, 1)
    else
        curDeleteChar = format:deleteLastChar()
    end
    local length = format:getLength()
    if charIndex == length then
        inFront = true
    elseif charIndex > length then
        charIndex, inFront = charIndex - 1, false
    end
    if charIndex <= 0 then
        charIndex, inFront = 1, true
    end
    return formatIndex, charIndex, inFront,curDeleteChar
end

function JQReviseRichTextModel:deleteCharsAtRange(uid, isFromReplay)
    local cursor = self:getOrCreateCursor(uid)
    local beganIndex, beganInFront, endedIndex, endedInFront = cursor:getIndices()
    if beganIndex > endedIndex or (beganIndex == endedIndex and not beganInFront) then
        beganIndex, endedIndex = endedIndex, beganIndex
        beganInFront, endedInFront = endedInFront, beganInFront
    end
    
    local beganFormatIndex, beganCharIndex, endedFormatIndex, endedCharIndex
    beganFormatIndex, beganCharIndex, beganInFront = self:getFormatIndicesByIndex(beganIndex, beganInFront)
    endedFormatIndex, endedCharIndex, endedInFront = self:getFormatIndicesByIndex(endedIndex, endedInFront)

    local curDeleteChar = '' 
    local delectCharData = {}
    if beganFormatIndex ~= endedFormatIndex then       
        local headDeleteChar = self:deleteCharsToHead(endedFormatIndex, endedCharIndex, endedInFront)
        local TailDeleteChar = self:deleteCharsToTail(beganFormatIndex, beganCharIndex, beganInFront)
        local centerDeleteChar = ''
        
        local headData = {} 
        headData.text = headDeleteChar
        headData.format = self.formats[endedFormatIndex]
        table.insert(delectCharData,headData)

        for i = endedFormatIndex - 1, beganFormatIndex + 1, -1 do
            if not self.formats[i].isReviseInsert then
                centerDeleteChar = self.formats[i].text .. centerDeleteChar
                local centerData = {}
                centerData.text = self.formats[i].text
                centerData.format = self.formats[i]
                table.insert(delectCharData,centerData)
            end
            table.remove(self.formats, i)
            endedFormatIndex = endedFormatIndex - 1
        end
        local beganFormat = self.formats[beganFormatIndex]
        self:setGroupFromIndex(endedFormatIndex, beganFormat.groupIndex, beganFormat.groupAlign)
        curDeleteChar = TailDeleteChar .. centerDeleteChar .. headDeleteChar
       
        local tailData = {}
        tailData.text = TailDeleteChar
        tailData.format = self.formats[beganFormatIndex]
        table.insert(delectCharData,tailData)
    else
        curDeleteChar = self:deleteCharsInNode(beganFormatIndex, beganCharIndex, beganInFront, endedCharIndex, endedInFront)
        local charData = {}
        charData.text = curDeleteChar
        charData.format = self.formats[beganFormatIndex]
        table.insert(delectCharData,charData)
    end

    cursor:setIndices(beganIndex, beganInFront)
    self:updateCursorGroupByFormatIndex(uid, isFromReplay)
    self:mergeFormat(self.formats, false)
    self:updateOtherCursorIndicesByDeleteRange(uid, beganIndex, beganInFront, endedIndex, endedInFront)
    
    if delectCharData then
        for i, v in pairs(delectCharData) do
            if v.text ~= '' then
                self:reviseInsertChar(uid,v.text,false,isFromReplay,v.format)
            end
        end       
    end

    self:deleteFirstNullFormats(uid, isFromReplay)
end

function JQReviseRichTextModel:deleteCharsToHead(formatIndex, index, inFront)
    local format = self.formats[formatIndex]
    local length = format:getLength()
    local toIndex = index + (inFront and -1 or 0)
    local deletedLen = toIndex
    local curDeleteChar = ''
    if deletedLen > 0 then
        curDeleteChar = format:deleteChar(1, deletedLen)
    end
    if toIndex > length then
        format:setTailWithLF(false)
        format:setNullString(false)
    end

    if format.isReviseInsert then
        curDeleteChar = ''
    end
    return curDeleteChar
end

function JQReviseRichTextModel:deleteCharsToTail(formatIndex, index, inFront)
    local format = self.formats[formatIndex]
    local length = format:getLength()
    local fromIndex = index + (inFront and 0 or 1)
    local deletedLen = length - fromIndex + 1
    local curDeleteChar = ''
    if deletedLen > 0 then
        curDeleteChar = format:deleteChar(fromIndex, deletedLen)
    end
    format:setTailWithLF(false)
    format:setNullString(false)

    if format.isReviseInsert then
        curDeleteChar = ''
    end
    return curDeleteChar
end

function JQReviseRichTextModel:deleteCharsInNode(formatIndex, beganIndex, beganInFront, endedIndex, endedInFront)
    local format = self.formats[formatIndex]
    local length = format:getLength()
    local fromIndex = beganIndex + (beganInFront and 0 or 1)
    local toIndex = endedIndex + (endedInFront and -1 or 0)
    local curDeleteChar = ''
    if fromIndex <= toIndex then
        curDeleteChar = format:deleteChar(fromIndex, toIndex - fromIndex + 1)
    end
    if toIndex > length then
        format:setTailWithLF(false)
        format:setNullString(false)
    end

    if format.isReviseInsert then
        curDeleteChar = ''
    end
    return curDeleteChar
end

function JQReviseRichTextModel:deleteAheadCharInNode(formatIndex, charIndex, inFront)
    local format = self.formats[formatIndex]
    local curDeleteChar = ''
    if charIndex > format:getLength() then
        curDeleteChar = format:deleteLastChar()
    else
        curDeleteChar = format:deleteChar(charIndex, 1)
    end
    if format:getOriginalLength() == 0 and self:getFormatCountOfGroupIndex(format.groupIndex) == 1 then
        format:setNullString(true)
    end
    charIndex = charIndex - 1
    if charIndex == 0 then
        if format:getLength() > 0 then
            charIndex, inFront = 1, true
        else
            charIndex, inFront = 1, true
        end
    else
        inFront = false
    end
    return formatIndex, charIndex, inFront , curDeleteChar 
end

function JQReviseRichTextModel:deleteAheadCharAstrideNode(formatIndex, charIndex, inFront)
    local format = self.formats[formatIndex]
    local nextFormatIndex = formatIndex - 1
    local nextFormat = self.formats[nextFormatIndex]
    local curDeleteChar = ''
    if format.groupAlign == JQRichTextConstants.ALIGNMENT_LEFT or self.isFixedGroupAlign then
        if format.groupAlign == nextFormat.groupAlign then
            if format.groupIndex == nextFormat.groupIndex then
                if format:getLength() == 0 then
                    table.remove(self.formats, formatIndex)
                else
                    curDeleteChar = nextFormat:deleteLastChar()
                end
                formatIndex, charIndex, inFront = nextFormatIndex, nextFormat:getLength(), false
            else
                self:setGroupFromIndex(formatIndex, nextFormat.groupIndex, nextFormat.groupAlign)
                if format:getOriginalLength() == 1 and (format.tailWithLF or format.nullString) then
                    table.remove(self.formats, formatIndex)
                end
                if nextFormat.tailWithLF then
                    curDeleteChar = nextFormat:deleteLastChar()
                end
                formatIndex, charIndex, inFront = nextFormatIndex, nextFormat:getLength(), false
            end
        else
            self:setGroupFromIndex(formatIndex, nextFormat.groupIndex, nextFormat.groupAlign)
            if format:getLength() == 0 then
                curDeleteChar = format:deleteLastChar()
            elseif nextFormat.tailWithLF then
                curDeleteChar = nextFormat:deleteLastChar()
            end
            if format:getOriginalLength() == 0 then
                table.remove(self.formats, formatIndex)
            end
            formatIndex, charIndex, inFront = nextFormatIndex, nextFormat:getLength(), false
        end
    else
        self:setGroupFromIndex(formatIndex, JQRichTextUtils:newGroupIndex(), JQRichTextConstants.ALIGNMENT_LEFT)
        charIndex, inFront = 1, true
    end
    return formatIndex, charIndex, inFront, curDeleteChar
end

function JQReviseRichTextModel:reviseInsertChar(uid,char,isBehind,isFromReplay,deleteFormat)
    local cursor = self:getOrCreateCursor(uid)
    local index, formatIndex, charIndex, inFront
    index, inFront = cursor:getEndedIndex()
    formatIndex, charIndex, inFront = self:getFormatIndicesByIndex(index, inFront)

    local format = self.formats[formatIndex]
    local insertingCharIndex = inFront and charIndex or charIndex + 1
    local newIndex, newInFront = index, inFront

    local newFormat = deleteFormat:clone(-2)
    newFormat.color = JQRichTextConstants.REVISE_INPUT_COLOR
    local sections = format:split(insertingCharIndex, char, newFormat,false)
    self:switchLF(sections)
    self:mergeFormat(sections, true)
    table.remove(self.formats, formatIndex)
    table.foreach(sections, function(i, section)
        table.insert(self.formats, formatIndex + i - 1, section)
    end)

    if isBehind then
        newIndex, newInFront = index + (inFront and 0 or string.utf8len(char)), false
        cursor:setIndices(newIndex, newInFront)
    end

    self:mergeFormat(self.formats, false)
    self:adjustFormatGroupIndex()
    self:updateCursorGroupByFormatIndex(uid, isFromReplay)
    self:updateOtherCursorIndicesByInsert(uid, index, inFront, char)
end

function JQReviseRichTextModel:reviseBehindInsertChar(uid,char,curormatIndex,isFromReplay)
    local cursor = self:getOrCreateCursor(uid)
    local index, formatIndex, charIndex, inFront
    index, inFront = cursor:getEndedIndex()
    formatIndex, charIndex, inFront = self:getBehindFormatIndicesByIndex(index, inFront)

    local format = self.formats[formatIndex]
    local insertingCharIndex = inFront and charIndex or charIndex + 1
    local newIndex, newInFront = index, inFront

    local newFormat = format:clone(-2)
    local sections = format:split(insertingCharIndex, char, newFormat,false)
    self:switchLF(sections)
    self:mergeFormat(sections, true)
    table.remove(self.formats, formatIndex)
    table.foreach(sections, function(i, section)
        table.insert(self.formats, formatIndex + i - 1, section)
    end)

    --newIndex, newInFront = index + (inFront and 0 or string.utf8len(char)), false
    --cursor:setIndices(newIndex, newInFront)

    self:mergeFormat(self.formats, false)
    self:adjustFormatGroupIndex()
    self:updateCursorGroupByFormatIndex(uid, isFromReplay)
    self:updateOtherCursorIndicesByInsert(uid, index, inFront, char)
end

function JQReviseRichTextModel:getBehindFormatIndicesByIndex(charIndex, inFront)
    for formatIndex, format in ipairs(self.formats) do
        local length = format:getOriginalLength()
        if length > charIndex then
            return formatIndex, charIndex, inFront
        elseif length == charIndex then
            if not format.tailWithLF or (format.tailWithLF and inFront) then
                return formatIndex, charIndex, inFront
            end
        end
        charIndex = charIndex - length
    end
    charIndex, inFront = self.formats[#self.formats]:getOriginalLength(), false
    return #self.formats, charIndex, inFront
end

function JQReviseRichTextModel:getOrCreateCursor(uid)
    uid = uid or JQRichTextConstants.DEFAULT_ID
    if not self.cursors[uid] then
        self.cursors[uid] = JQReviseRichTextCursorModel.new({defaultFormat = self.defaultFormat:clone()})
    end
    return self.cursors[uid]
end

return JQReviseRichTextModel