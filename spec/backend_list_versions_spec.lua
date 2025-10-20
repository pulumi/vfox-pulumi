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
        package.loaded.http = {
            get = function(args)
                table.insert(http_calls, args)
                return { status_code = 200, body = "__JSON_PLACEHOLDER__" }, nil
            end,
        }
        package.loaded.json = {
            decode = function(body)
                assert.is_equal("__JSON_PLACEHOLDER__", body)
                return releases
            end,
        }
        load_subject()
    end)

    after_each(function()
        _G.PLUGIN = nil
        package.loaded.http = original_modules.http
        package.loaded.json = original_modules.json
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
end)
