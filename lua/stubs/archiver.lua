---@meta

---@class ArchiverModule
local archiver = {}

---Extract a supported archive into the destination directory.
---@async
---@param archive_path string -- Accepts .zip, .tar.gz, .tar.xz, .tar.bz2
---@param destination string
function archiver.decompress(archive_path, destination) end

return archiver
