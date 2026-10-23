local json = require "json"
local models = require "richtext_loader"

local M = {}
M.__index = M

function M.new(snapshot)
    local self = setmetatable({ documents = {} }, M)
    for id, saved in pairs(snapshot or {}) do
        local format_class = saved.revise and models.ReviseFormatModel or models.FormatModel
        local default_format = format_class.new(saved.defaultformat or {})
        local model_class = saved.revise and models.ReviseTextModel or models.TextModel
        local model = model_class.new({ inServer = true, isRevise = saved.revise, defaultFormat = default_format, text = saved.text })
        for uid, cursor in pairs(saved.cursors or {}) do
            if cursor.indices then model:updateCursorIndicesAndFormat(uid, table.unpack(cursor.indices)) end
            if cursor.format then model:updateCursorFormat(uid, cursor.format) end
        end
        self.documents[id] = model
    end
    return self
end

function M:snapshot()
    local result = {}
    for id, model in pairs(self.documents) do
        local cursors = {}
        for uid, indices in pairs(model:getAllCursorIndices()) do
            local cursor = model.cursors[uid]
            cursors[uid] = { indices = indices, format = cursor:getFormatInServer() }
        end
        result[id] = {
            text = model:serialize(),
            cursors = cursors,
            defaultformat = model:getDefaultFormatInServer(),
            revise = model.isRevisionMode == true,
        }
    end
    return result
end

local function create_model(self, id, revise)
    local format_class = revise and models.ReviseFormatModel or models.FormatModel
    local model_class = revise and models.ReviseTextModel or models.TextModel
    self.documents[id] = model_class.new({
        inServer = true, isRevise = revise, defaultFormat = format_class.new(),
    })
    return self.documents[id]
end

function M:process(message, uid)
    local event = message.id
    local ok, value = pcall(json.decode, message.var)
    if not ok or type(value) ~= "table" or type(value.id) ~= "string" then
        error("invalid RichText event payload")
    end
    value.uid = uid
    local id = value.id
    local model = self.documents[id]
    if not model and event ~= 9007 and event ~= 9011 then model = create_model(self, id, false) end
    if event == 9011 then
        if not model then model = create_model(self, id, value.isRevise == true) end
    elseif event ~= 9007 and not model then
        model = create_model(self, id, false)
    end

    local response = { id = event }
    local should_broadcast = true
    if event == 9000 then
        value.cursor = { model:getCursorIndices(uid) }
        model:insertChar(uid, value.char)
    elseif event == 9001 then
        value.cursor = { model:getCursorIndices(uid) }
        model:deleteAheadChar(uid)
    elseif event == 9002 then
        value.cursor = { model:getCursorIndices(uid) }
        model:deleteBehindChar(uid)
    elseif event == 9003 then
        model:updateCursorIndicesAndFormat(uid, table.unpack(value.cursor or {}))
        value.cursor = { model:getCursorIndices(uid) }
    elseif event == 9004 then
        local first, first_front, last, last_front = table.unpack(value.cursor or {})
        if first ~= nil and last ~= nil then
            model:updateFormatsAtRangeByName(uid, {
                beganIndex = first, beganInFront = first_front,
                endedIndex = last, endedInFront = last_front,
            }, value.formatName, value.formatValue, value.groupIndex)
        else
            model:updateFormatsByName(uid, value.formatName, value.formatValue, value.groupIndex)
        end
    elseif event == 9005 then
        value.cursor = { model:getCursorIndices(uid) }
        model:updateCursorFormatByName(uid, value.formatName, value.formatValue)
    elseif event == 9006 then
        should_broadcast = false
        value.uid = nil
        value.text = model:serialize()
        value.cursors = model:getCursorsInServer()
        value.defaultformat = model:getDefaultFormatInServer()
    elseif event == 9007 then
        for key in pairs(self.documents) do
            if key == id or key:sub(1, #id) == id then self.documents[key] = nil end
        end
    elseif event == 9008 then
        model:updateFullFormatsByName(uid, value.formatName, value.formatValue, value.groupIndex)
    elseif event == 9009 then
        model:setText(value.text)
    elseif event == 9010 then
        model:updateDefaultFormatByName(uid, value.formatName, value.formatValue)
    elseif event == 9011 then
        -- The model may have been created from isRevise above; echo the
        -- client's event payload as the legacy manager did.
    else
        return nil, false
    end
    response.var = json.encode(value)
    return response, should_broadcast
end

return M
