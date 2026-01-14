local releases
local http_calls
local original_getenv = os.getenv
local getenv_stub
local original_modules = {}

describe("backend_list_versions", function()
    local function load_subject()
        _G.PLUGIN = {}
        dofile("hooks/backend_list_versions.lua")
    end

    before_each(function()
        releases = {}
        http_calls = {}
        getenv_stub = nil
        original_modules.http = package.loaded.http
        original_modules.json = package.loaded.json
        original_modules.github_cache = package.loaded.github_cache

        -- Disable cache for tests by default (unless testing cache specifically)
        package.loaded.github_cache = {
            get_cache = function() return nil end,
            set_cache = function() end,
            is_cache_valid = function() return false end,
            touch_cache = function() end,
            get_cache_path = function(owner, repo) return "/cache/" .. owner .. "_" .. repo .. ".json" end,
            ensure_cache_dir = function() end,
        }

        package.loaded.http = {
            get = function(args)
                table.insert(http_calls, args)
                return { status_code = 200, body = "__JSON_PLACEHOLDER__", headers = {} }, nil
            end,
        }
        package.loaded.json = {
            decode = function(body)
                assert.is_equal("__JSON_PLACEHOLDER__", body)
                return releases
            end,
        }

        -- Set environment to disable cache
        getenv_stub = stub(os, "getenv", function(name)
            if name == "VFOX_PULUMI_DISABLE_CACHE" then
                return "1"
            end
            return original_getenv(name)
        end)

        load_subject()
    end)

    after_each(function()
        _G.PLUGIN = nil
        package.loaded.http = original_modules.http
        package.loaded.json = original_modules.json
        package.loaded.github_cache = original_modules.github_cache
        if getenv_stub then
            getenv_stub:revert()
        end
    end)

    local function run(ctx)
        return PLUGIN:BackendListVersions(ctx)
    end

    it("requires tool name to be present", function()
        assert.has_error(function()
            run({ tool = "  " })
        end, "Tool name cannot be empty")
    end)

    it("requires tools to use owner/repo format", function()
        assert.has_error(function()
            run({ tool = "invalid" })
        end, "Tool invalid must follow format owner/repo")
    end)

    it("trims whitespace around tool name", function()
        releases = {
            { tag_name = "v1.0.0", draft = false, prerelease = false },
        }

        local result = run({ tool = "  owner/repo  " })

        assert.same({ "1.0.0" }, result.versions)
        assert.same("https://api.github.com/repos/owner/repo/releases?per_page=100", http_calls[1].url)
    end)

    it("includes prereleases, and duplicate tags by default", function()
        releases = {
            { tag_name = "v2.0.0", draft = false, prerelease = false },
            { tag_name = "v1.2.0-beta", draft = false, prerelease = true },
            { tag_name = "v1.1.0", draft = false, prerelease = false },
            { tag_name = "1.0.0", draft = true, prerelease = false },
            { tag_name = "v1.1.0", draft = false, prerelease = false },
        }

        local result = run({ tool = "owner/repo" })
        assert.same({ "1.2.0-beta", "1.1.0", "2.0.0" }, result.versions)
    end)

    it("includes prerelease tags when tool config allows them", function()
        releases = {
            { tag_name = "v2.0.0-rc.1", draft = false, prerelease = true },
            { tag_name = "v1.0.0", draft = false, prerelease = false },
        }

        local result = run({
            tool = "owner/repo",
            tool_config = { include_prerelease = true },
        })

        assert.same({ "2.0.0-rc.1", "1.0.0" }, result.versions)
    end)

    it("supports prerelease inclusion via runtime options", function()
        releases = {
            { tag_name = "v1.0.0", draft = false, prerelease = false },
            { tag_name = "v1.1.0-beta", draft = false, prerelease = true },
        }

        local result = run({
            tool = "owner/repo",
            options = { include_prerelease = true },
        })

        assert.same({ "1.1.0-beta", "1.0.0" }, result.versions)
    end)

    it("ignores draft releases", function()
        releases = {
            { tag_name = "v1.2.0", draft = true, prerelease = false },
            { tag_name = "v1.1.0", draft = false, prerelease = false },
        }

        local result = run({ tool = "owner/repo" })

        assert.same({ "1.1.0" }, result.versions)
    end)

    it("requests GitHub releases with auth headers when a token is present", function()
        releases = {
            { tag_name = "v1.0.0", draft = false, prerelease = false },
        }

        -- simulate token presence using a stubbed getenv
        getenv_stub = stub(os, "getenv", function(name)
            if name == "GITHUB_TOKEN" then
                return "secret"
            elseif name == "MISE_GITHUB_TOKEN" then
                return nil
            end
            return original_getenv(name)
        end)

        local ok, result = pcall(run, { tool = "owner/repo" })

        assert.is_true(ok)
        assert.same({ "1.0.0" }, result.versions)

        assert.is_not_nil(http_calls[1])
        local headers = http_calls[1].headers
        assert.is_not_nil(headers)
        assert.same("Bearer secret", headers["Authorization"])
        assert.same("https://api.github.com/repos/owner/repo/releases?per_page=100", http_calls[1].url)
        assert.same("mise-backend-pulumi", headers["User-Agent"])
    end)

    it("raises when http client returns an error", function()
        package.loaded.http.get = function(args)
            table.insert(http_calls, args)
            return nil, "network down"
        end

        assert.has_error(function()
            run({ tool = "owner/repo" })
        end, "Failed to fetch versions for owner/repo: network down")
    end)

    it("raises when GitHub responds with non-200", function()
        package.loaded.http.get = function(args)
            table.insert(http_calls, args)
            return { status_code = 404, body = "{}" }, nil
        end

        assert.has_error(function()
            run({ tool = "owner/repo" })
        end, "GitHub API returned status 404 for owner/repo")
    end)

    it("raises when releases payload is empty", function()
        releases = {}

        assert.has_error(function()
            run({ tool = "owner/repo" })
        end, "No versions found for owner/repo in GitHub releases")
    end)

    it("raises when releases payload is not a table", function()
        package.loaded.json.decode = function()
            return "invalid"
        end

        assert.has_error(function()
            run({ tool = "owner/repo" })
        end, "No versions found for owner/repo in GitHub releases")
    end)

    it("uses MISE_GITHUB_TOKEN when set", function()
        releases = {
            { tag_name = "v1.0.0", draft = false, prerelease = false },
        }

        getenv_stub = stub(os, "getenv", function(name)
            if name == "MISE_GITHUB_TOKEN" then
                return "ghp_mise_token_123"
            end
            return original_getenv(name)
        end)

        local ok, result = pcall(run, { tool = "owner/repo" })

        assert.is_true(ok)
        assert.same({ "1.0.0" }, result.versions)

        assert.is_not_nil(http_calls[1])
        local headers = http_calls[1].headers
        assert.is_not_nil(headers)
        assert.same("Bearer ghp_mise_token_123", headers["Authorization"])
    end)

    it("prefers MISE_GITHUB_TOKEN over GITHUB_TOKEN when both are set", function()
        releases = {
            { tag_name = "v1.0.0", draft = false, prerelease = false },
        }

        getenv_stub = stub(os, "getenv", function(name)
            if name == "MISE_GITHUB_TOKEN" then
                return "ghp_mise_token_456"
            elseif name == "GITHUB_TOKEN" then
                return "ghp_token_ignored"
            end
            return original_getenv(name)
        end)

        local ok, result = pcall(run, { tool = "owner/repo" })

        assert.is_true(ok)
        assert.same({ "1.0.0" }, result.versions)

        assert.is_not_nil(http_calls[1])
        local headers = http_calls[1].headers
        assert.is_not_nil(headers)
        assert.same("Bearer ghp_mise_token_456", headers["Authorization"])
    end)

    describe("caching", function()
        local cache_ops
        local file_ops
        local original_time = os.time

        before_each(function()
            -- Reset cache state
            cache_ops = {
                get_calls = {},
                set_calls = {},
                touch_calls = {},
                cache_data = nil,
            }

            file_ops = {
                existing_files = {},
            }

            -- Re-stub getenv without VFOX_PULUMI_DISABLE_CACHE for caching tests
            if getenv_stub then
                getenv_stub:revert()
            end
            getenv_stub = stub(os, "getenv", function(name)
                return original_getenv(name)
            end)

            -- Mock github_cache module for caching tests
            package.loaded.github_cache = {
                get_cache = function(owner, repo)
                    table.insert(cache_ops.get_calls, { owner = owner, repo = repo })
                    return cache_ops.cache_data
                end,
                set_cache = function(owner, repo, versions, etag, last_modified)
                    table.insert(cache_ops.set_calls, {
                        owner = owner,
                        repo = repo,
                        versions = versions,
                        etag = etag,
                        last_modified = last_modified,
                    })
                end,
                is_cache_valid = function(data, ttl)
                    return data and data.valid == true
                end,
                touch_cache = function(owner, repo)
                    table.insert(cache_ops.touch_calls, { owner = owner, repo = repo })
                end,
                get_cache_path = function(owner, repo)
                    return "/cache/" .. owner .. "_" .. repo .. ".json"
                end,
                ensure_cache_dir = function()
                    -- no-op for tests
                end,
            }

            -- Reload subject with mocked cache
            load_subject()
        end)

        after_each(function()
            -- Restore github_cache mock to the default disabled state for other tests
            package.loaded.github_cache = {
                get_cache = function() return nil end,
                set_cache = function() end,
                is_cache_valid = function() return false end,
                touch_cache = function() end,
                get_cache_path = function(owner, repo) return "/cache/" .. owner .. "_" .. repo .. ".json" end,
                ensure_cache_dir = function() end,
            }
        end)

        it("uses cache when valid cache exists", function()
            cache_ops.cache_data = {
                valid = true,
                versions = { "9.9.0", "9.8.0" },
            }

            local result = run({ tool = "owner/repo" })

            assert.same({ "9.9.0", "9.8.0" }, result.versions)
            assert.is_equal(1, #cache_ops.get_calls)
            assert.is_equal(0, #http_calls) -- No HTTP call made
        end)

        it("makes API call and stores cache when no cache exists", function()
            releases = {
                { tag_name = "v1.0.0", draft = false, prerelease = false },
            }

            package.loaded.http.get = function(args)
                table.insert(http_calls, args)
                return {
                    status_code = 200,
                    body = "__JSON_PLACEHOLDER__",
                    headers = {
                        etag = "W/\"abc123\"",
                        ["last-modified"] = "Mon, 14 Jan 2026 10:00:00 GMT",
                    },
                }, nil
            end

            local result = run({ tool = "owner/repo" })

            assert.same({ "1.0.0" }, result.versions)
            assert.is_equal(1, #http_calls) -- HTTP call made
            assert.is_equal(1, #cache_ops.set_calls) -- Cache stored
            assert.same("W/\"abc123\"", cache_ops.set_calls[1].etag)
        end)

        it("sends If-None-Match header when stale cache with etag exists", function()
            cache_ops.cache_data = {
                valid = false, -- Stale cache
                etag = "W/\"old_etag\"",
                versions = { "9.0.0" },
            }

            releases = {
                { tag_name = "v9.9.0", draft = false, prerelease = false },
            }

            local result = run({ tool = "owner/repo" })

            assert.is_equal(1, #http_calls)
            assert.same("W/\"old_etag\"", http_calls[1].headers["If-None-Match"])
        end)

        it("handles 304 Not Modified response by using cached versions", function()
            cache_ops.cache_data = {
                valid = false, -- Stale cache
                etag = "W/\"abc123\"",
                versions = { "9.9.0", "9.8.0" },
            }

            package.loaded.http.get = function(args)
                table.insert(http_calls, args)
                return { status_code = 304, headers = {} }, nil
            end

            local result = run({ tool = "owner/repo" })

            assert.same({ "9.9.0", "9.8.0" }, result.versions)
            assert.is_equal(1, #http_calls) -- HTTP call made
            assert.is_equal(0, #cache_ops.set_calls) -- No new cache set
            assert.is_equal(1, #cache_ops.touch_calls) -- Cache timestamp updated
        end)

        it("bypasses cache when VFOX_PULUMI_DISABLE_CACHE is set", function()
            releases = {
                { tag_name = "v1.0.0", draft = false, prerelease = false },
            }

            cache_ops.cache_data = {
                valid = true,
                versions = { "9.9.0" },
            }

            -- Revert existing stub and create new one with DISABLE_CACHE
            if getenv_stub then
                getenv_stub:revert()
            end
            getenv_stub = stub(os, "getenv", function(name)
                if name == "VFOX_PULUMI_DISABLE_CACHE" then
                    return "1"
                end
                return original_getenv(name)
            end)

            -- Reload subject with new env
            load_subject()

            local result = run({ tool = "owner/repo" })

            assert.same({ "1.0.0" }, result.versions) -- Fresh data, not cached
            assert.is_equal(1, #http_calls) -- HTTP call made despite cache
            assert.is_equal(0, #cache_ops.set_calls) -- No cache stored
        end)

        it("stores ETag from response headers", function()
            releases = {
                { tag_name = "v1.0.0", draft = false, prerelease = false },
            }

            package.loaded.http.get = function(args)
                table.insert(http_calls, args)
                return {
                    status_code = 200,
                    body = "__JSON_PLACEHOLDER__",
                    headers = {
                        ETag = "W/\"different_case\"",
                    },
                }, nil
            end

            local result = run({ tool = "owner/repo" })

            assert.is_equal(1, #cache_ops.set_calls)
            assert.same("W/\"different_case\"", cache_ops.set_calls[1].etag)
        end)
    end)
end)
