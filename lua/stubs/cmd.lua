---@meta

---@class CmdExecOptions
---@field cwd? string
---@field env? table<string, string>
---@field timeout? integer -- Currently ignored by the runtime

---@class CmdModule
local cmd = {}

---Run a shell command (`sh -c` or `cmd /C` based on platform).
---@param command string
---@param opts? CmdExecOptions
---@return string stdout
function cmd.exec(command, opts) end

return cmd
