---@meta

---@class HttpResponse
---@field status_code integer
---@field headers table<string, string>
---@field body? string

---@class HttpModule
local http = {}

---Perform an HTTP GET request.
---@async
---@param opts {url: string}
---@return HttpResponse
function http.get(opts) end

---Perform an HTTP HEAD request.
---@async
---@param opts {url: string}
---@return HttpResponse
function http.head(opts) end

---Download the response body to a file.
---@async
---@param opts {url: string, headers?: table<string, string>}
---@param path string
function http.download_file(opts, path) end

return http
