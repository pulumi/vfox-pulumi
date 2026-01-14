-- GitHub API Response Cache Module
-- Provides persistent caching for GitHub releases API responses
-- with ETa support for conditional requests

local M = {}

local function get_cache_dir()
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if not home then
        error("Unable to determine home directory")
    end
    return home .. "/.mise/cache/vfox-pulumi"
end

function M.ensure_cache_dir()
    local cache_dir = get_cache_dir()
    local file = require("file")

    -- Create directory if it doesn't exist
    if not file.exists(cache_dir) then
        local cmd = require("cmd")
        -- Use mkdir -p for recursive directory creation (works on Unix/macOS/Linux)
        -- Windows cmd.exe also supports mkdir with /p flag via cmd.exec
        local is_windows = package.config:sub(1, 1) == "\\"
        local mkdir_cmd
        if is_windows then
            -- Windows: use mkdir with quotes around path
            mkdir_cmd = 'mkdir "' .. cache_dir .. '" 2>NUL || exit 0'
        else
            -- Unix/macOS/Linux: use mkdir -p
            mkdir_cmd = "mkdir -p " .. cache_dir
        end

        local result = cmd.exec(mkdir_cmd)
        if result.code ~= 0 then
            -- Don't fail hard - caching is optional
            -- Just log that we couldn't create the directory
            -- error("Failed to create cache directory: " .. cache_dir)
        end
    end
end

function M.get_cache_path(owner, repo)
    local cache_dir = get_cache_dir()
    local safe_owner = owner:gsub("[^%w-]", "_")
    local safe_repo = repo:gsub("[^%w-]", "_")
    return cache_dir .. "/github_releases_" .. safe_owner .. "_" .. safe_repo .. ".json"
end

function M.get_cache(owner, repo)
    local cache_path = M.get_cache_path(owner, repo)
    local file = require("file")

    -- Check if cache file exists
    if not file.exists(cache_path) then
        return nil
    end

    -- Read cache file
    local content, err = file.read(cache_path)
    if err then
        -- Failed to read, return nil (cache miss)
        return nil
    end

    -- Parse JSON
    local json = require("json")
    local ok, cache_data = pcall(json.decode, content)
    if not ok or type(cache_data) ~= "table" then
        -- Invalid JSON, return nil (cache miss)
        return nil
    end

    return cache_data
end

function M.set_cache(owner, repo, versions, etag, last_modified)
    M.ensure_cache_dir()

    local cache_data = {
        timestamp = os.time(),
        etag = etag,
        last_modified = last_modified,
        versions = versions,
    }

    local json = require("json")
    local content = json.encode(cache_data)

    local cache_path = M.get_cache_path(owner, repo)
    local file = require("file")

    local ok, err = file.write(cache_path, content)
    if not ok then
        -- Log error but don't fail - caching is optional
        -- error("Failed to write cache: " .. (err or "unknown error"))
    end
end

function M.is_cache_valid(cache_data, ttl_seconds)
    if not cache_data or type(cache_data) ~= "table" then
        return false
    end

    if not cache_data.timestamp or type(cache_data.timestamp) ~= "number" then
        return false
    end

    local current_time = os.time()
    local age = current_time - cache_data.timestamp

    return age < ttl_seconds
end

function M.touch_cache(owner, repo)
    -- Read existing cache
    local cache_data = M.get_cache(owner, repo)
    if not cache_data then
        return
    end

    -- Update timestamp only
    cache_data.timestamp = os.time()

    -- Write back
    local json = require("json")
    local content = json.encode(cache_data)

    local cache_path = M.get_cache_path(owner, repo)
    local file = require("file")

    local ok, err = file.write(cache_path, content)
    if not ok then
        -- Log error but don't fail
        -- error("Failed to touch cache: " .. (err or "unknown error"))
    end
end

return M
