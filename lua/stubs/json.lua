---@meta

---@class JsonModule
local json = {}

---Encode a Lua value as JSON.
---@param value any
---@return string
function json.encode(value) end

---Decode a JSON string into Lua data.
---@param source string
---@return any
function json.decode(source) end

return json
