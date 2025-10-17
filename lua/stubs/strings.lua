---@meta

---@class StringsModule
local strings = {}

---@param text string
---@param sep string
---@return string[]
function strings.split(text, sep) end

---@param text string
---@param prefix string
---@return boolean
function strings.has_prefix(text, prefix) end

---@param text string
---@param suffix string
---@return boolean
function strings.has_suffix(text, suffix) end

---Trim a matching suffix from the string.
---@param text string
---@param suffix string
---@return string
function strings.trim(text, suffix) end

---Trim leading and trailing whitespace.
---@param text string
---@return string
function strings.trim_space(text) end

---@param text string
---@param substr string
---@return boolean
function strings.contains(text, substr) end

---@param parts any[]
---@param sep string
---@return string
function strings.join(parts, sep) end

return strings
