local original_modules = {}
local original_getenv = os.getenv
local original_time = os.time
local getenv_stub
local time_stub
local file_ops = {}

describe("github_cache", function()
    local cache

    before_each(function()
        -- Mock file module
        file_ops = {
            written_files = {},
            existing_files = {},
        }

        original_modules.file = package.loaded.file
        original_modules.json = package.loaded.json
        original_modules.cmd = package.loaded.cmd

        package.loaded.file = {
            exists = function(path)
                return file_ops.existing_files[path] ~= nil
            end,
            read = function(path)
                local content = file_ops.existing_files[path]
                if not content or content == "__DIR__" then
                    return nil, "file not found"
                end
                return content, nil
            end,
            write = function(path, content)
                file_ops.written_files[path] = content
                file_ops.existing_files[path] = content
                return true, nil
            end,
        }

        package.loaded.cmd = {
            exec = function(command)
                -- Mock mkdir command to mark directory as created
                if command:match("^mkdir") then
                    -- Extract path from mkdir command
                    local path = command:match("mkdir %-p%s+(.+)") or command:match('mkdir%s+"([^"]+)"')
                    if path then
                        file_ops.existing_files[path] = "__DIR__"
                    end
                end
                return { code = 0 }
            end,
        }

        package.loaded.json = {
            encode = function(data)
                -- Simple JSON encoding for test purposes
                -- Just serialize as a Lua table string for testing
                local function serialize(val)
                    if type(val) == "string" then
                        return '"' .. val .. '"'
                    elseif type(val) == "number" then
                        return tostring(val)
                    elseif type(val) == "table" then
                        local result = "{"
                        local first = true
                        for k, v in pairs(val) do
                            if not first then
                                result = result .. ","
                            end
                            first = false
                            result = result .. '"' .. k .. '":' .. serialize(v)
                        end
                        return result .. "}"
                    else
                        return "null"
                    end
                end
                return serialize(data)
            end,
            decode = function(content)
                -- Simple JSON decoding - just store/retrieve from file_ops
                -- In tests, we'll use Lua tables directly
                return file_ops.decoded_cache or {}
            end,
        }

        -- Set HOME for cache directory
        os.getenv = function(name)
            if name == "HOME" then
                return "/home/test"
            end
            return original_getenv(name)
        end

        -- Set fixed time for testing
        os.time = function()
            return 1705234567
        end

        -- Reload cache module after mocking
        package.loaded.github_cache = nil
        cache = require("github_cache")
    end)

    after_each(function()
        package.loaded.file = original_modules.file
        package.loaded.json = original_modules.json
        package.loaded.cmd = original_modules.cmd
        package.loaded.github_cache = nil
        os.getenv = original_getenv
        os.time = original_time
    end)

    describe("get_cache_path", function()
        it("returns correct path for owner and repo", function()
            local path = cache.get_cache_path("pulumi", "pulumi-aws")
            assert.is_equal("/home/test/.mise/cache/vfox-pulumi/github_releases_pulumi_pulumi-aws.json", path)
        end)

        it("sanitizes owner and repo names", function()
            local path = cache.get_cache_path("org/name", "repo@123")
            assert.is_equal("/home/test/.mise/cache/vfox-pulumi/github_releases_org_name_repo_123.json", path)
        end)
    end)

    describe("ensure_cache_dir", function()
        it("creates directory if it doesn't exist", function()
            cache.ensure_cache_dir()
            assert.is_true(file_ops.existing_files["/home/test/.mise/cache/vfox-pulumi"] == "__DIR__")
        end)

        it("doesn't fail if directory already exists", function()
            file_ops.existing_files["/home/test/.mise/cache/vfox-pulumi"] = "__DIR__"
            assert.has_no_errors(function()
                cache.ensure_cache_dir()
            end)
        end)
    end)

    describe("get_cache", function()
        it("returns nil if cache file doesn't exist", function()
            local result = cache.get_cache("pulumi", "pulumi-aws")
            assert.is_nil(result)
        end)

        it("returns nil if cache file has invalid JSON", function()
            local path = cache.get_cache_path("pulumi", "pulumi-aws")
            file_ops.existing_files[path] = "invalid json {"
            file_ops.decoded_cache = nil -- Simulate JSON decode failure

            -- Mock decode to error on invalid JSON
            package.loaded.json.decode = function(content)
                if content == "invalid json {" then
                    error("Invalid JSON")
                end
                return file_ops.decoded_cache or {}
            end

            local result = cache.get_cache("pulumi", "pulumi-aws")
            assert.is_nil(result)
        end)

        it("returns cache data if file exists and is valid", function()
            local path = cache.get_cache_path("pulumi", "pulumi-aws")
            local cache_data = {
                timestamp = 1705234567,
                etag = 'W/"abc123"',
                last_modified = "Mon, 14 Jan 2026 10:00:00 GMT",
                versions = { "9.9.0", "9.8.0" },
            }
            file_ops.existing_files[path] = "json_content"
            file_ops.decoded_cache = cache_data

            local result = cache.get_cache("pulumi", "pulumi-aws")
            assert.is_not_nil(result)
            assert.is_equal(1705234567, result.timestamp)
            assert.is_equal('W/"abc123"', result.etag)
            assert.is_equal(2, #result.versions)
        end)
    end)

    describe("set_cache", function()
        it("writes cache file with correct structure", function()
            local versions = { "9.9.0", "9.8.0" }
            cache.set_cache("pulumi", "pulumi-aws", versions, 'W/"abc123"', "Mon, 14 Jan 2026 10:00:00 GMT")

            local path = cache.get_cache_path("pulumi", "pulumi-aws")
            assert.is_not_nil(file_ops.written_files[path])

            -- Check that JSON string contains expected fields
            local json_str = file_ops.written_files[path]
            assert.is_true(json_str:find('"timestamp":1705234567') ~= nil)
            assert.is_true(json_str:find('"etag":"W/\\\\"abc123\\\\""') ~= nil or json_str:find('"etag":"W/') ~= nil)
        end)

        it("creates cache directory if it doesn't exist", function()
            local versions = { "9.9.0" }
            cache.set_cache("pulumi", "pulumi-aws", versions, nil, nil)

            assert.is_not_nil(file_ops.existing_files["/home/test/.mise/cache/vfox-pulumi"])
        end)
    end)

    describe("is_cache_valid", function()
        it("returns false for nil cache data", function()
            assert.is_false(cache.is_cache_valid(nil, 3600))
        end)

        it("returns false for cache data without timestamp", function()
            local cache_data = { versions = { "9.9.0" } }
            assert.is_false(cache.is_cache_valid(cache_data, 3600))
        end)

        it("returns true if cache is within TTL", function()
            local cache_data = {
                timestamp = 1705234567, -- Same as current time
                versions = { "9.9.0" },
            }
            assert.is_true(cache.is_cache_valid(cache_data, 3600))
        end)

        it("returns false if cache is older than TTL", function()
            local cache_data = {
                timestamp = 1705230000, -- More than 3600 seconds ago
                versions = { "9.9.0" },
            }
            assert.is_false(cache.is_cache_valid(cache_data, 3600))
        end)

        it("handles custom TTL values", function()
            local cache_data = {
                timestamp = 1705234567 - 43200 + 100, -- Just within 12 hour TTL
                versions = { "9.9.0" },
            }
            assert.is_true(cache.is_cache_valid(cache_data, 43200))

            cache_data.timestamp = 1705234567 - 43200 - 100 -- Just outside 12 hour TTL
            assert.is_false(cache.is_cache_valid(cache_data, 43200))
        end)
    end)

    describe("touch_cache", function()
        it("updates timestamp without changing other fields", function()
            -- Set up initial cache
            local path = cache.get_cache_path("pulumi", "pulumi-aws")
            local initial_data = {
                timestamp = 1705230000,
                etag = 'W/"abc123"',
                last_modified = "Mon, 14 Jan 2026 10:00:00 GMT",
                versions = { "9.9.0", "9.8.0" },
            }
            file_ops.existing_files[path] = "json_content"
            file_ops.decoded_cache = initial_data

            -- Touch the cache
            cache.touch_cache("pulumi", "pulumi-aws")

            -- Verify timestamp was updated
            assert.is_not_nil(file_ops.written_files[path])
            local json_str = file_ops.written_files[path]
            assert.is_true(json_str:find('"timestamp":1705234567') ~= nil) -- New timestamp
        end)

        it("doesn't fail if cache doesn't exist", function()
            assert.has_no_errors(function()
                cache.touch_cache("nonexistent", "repo")
            end)
        end)
    end)
end)
