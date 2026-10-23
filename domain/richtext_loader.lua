local raw_require = require
raw_require("richtext_compat")

local original_require = _G.require
_G.require = function(name)
    name = name:gsub("/", ".")
    local richtext_prefix = "src.ui.components.reach.richtext."
    local utils_prefix = "src.utils."
    if name:sub(1, #richtext_prefix) == richtext_prefix then
        name = "richtext." .. name:sub(#richtext_prefix + 1)
    elseif name:sub(1, #utils_prefix) == utils_prefix then
        name = "richtext." .. name:sub(#utils_prefix + 1)
    end
    return raw_require(name)
end

local ok, modules = pcall(function()
    return {
        TextModel = require("richtext.data.JQRichTextModel"),
        ReviseTextModel = require("richtext.revise.JQReviseRichTextModel"),
        FormatModel = require("richtext.data.JQRichTextFormatModel"),
        ReviseFormatModel = require("richtext.revise.JQReviseRichTextFormatModel"),
    }
end)
_G.require = original_require
if not ok then error(modules) end

function modules.TextModel:getAllCursorIndices()
    local result = {}
    for id, cursor in pairs(self.cursors) do result[id] = { cursor:getIndices() } end
    return result
end

function modules.ReviseTextModel:getAllCursorIndices()
    local result = {}
    for id, cursor in pairs(self.cursors) do result[id] = { cursor:getIndices() } end
    return result
end

return modules
