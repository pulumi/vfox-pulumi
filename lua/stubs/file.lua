---@meta

---@class FileModule
local file = {}

---Create a filesystem symlink; uses platform-specific semantics.
---@async
---@param source string
---@param destination string
function file.symlink(source, destination) end

---Join path components using the host separator, ignoring empty segments.
---@param ... string
---@return string
function file.join_path(...) end

return file
