local http_get_calls
local http_download_calls
local http_responses
local decoded_payload
local original_getenv = os.getenv
local original_remove = os.remove
local getenv_stub
local remove_stub
local env_values
local removed_files
local original_modules = {}
local archiver_calls

describe("backend_install", function()
    local function load_subject()
        _G.PLUGIN = {}
        _G.RUNTIME = {
            osType = "darwin",
            archType = "amd64",
        }
        dofile("hooks/backend_install.lua")
    end

    before_each(function()
        http_get_calls = {}
        http_download_calls = {}
        http_responses = {}
        decoded_payload = {}
        env_values = {}
        removed_files = {}
        archiver_calls = {}

        original_modules.file = package.loaded.file
        original_modules.strings = package.loaded.strings
        original_modules.json = package.loaded.json
        original_modules.http = package.loaded.http
        original_modules.archiver = package.loaded.archiver

        package.loaded.file = {
            join_path = function(...)
                return table.concat({ ... }, "/")
            end,
        }

        package.loaded.strings = {
            has_prefix = function(str, prefix)
                return str:sub(1, #prefix) == prefix
            end,
            join = function(parts, sep)
                return table.concat(parts, sep)
            end,
        }

        package.loaded.json = {
            decode = function()
                return decoded_payload
            end,
        }

        package.loaded.http = {
            get = function(opts)
                table.insert(http_get_calls, opts)
                if #http_responses > 0 then
                    local response = table.remove(http_responses, 1)
                    return response
                end
                return { status_code = 200, body = "{}" }
            end,
            download = function(opts)
                table.insert(http_download_calls, opts)
                if #http_responses > 0 then
                    local response = table.remove(http_responses, 1)
                    return response
                end
                return { status_code = 200 }
            end,
        }

        package.loaded.archiver = {
            decompress_file = function(opts)
                table.insert(archiver_calls, opts)
            end,
        }

        getenv_stub = stub(os, "getenv", function(name)
            if env_values[name] ~= nil then
                return env_values[name]
            end
            return original_getenv(name)
        end)

        remove_stub = stub(os, "remove", function(path)
            table.insert(removed_files, path)
        end)

        load_subject()
    end)

    after_each(function()
        _G.PLUGIN = nil
        _G.RUNTIME = nil

        package.loaded.file = original_modules.file
        package.loaded.strings = original_modules.strings
        package.loaded.json = original_modules.json
        package.loaded.http = original_modules.http
        package.loaded.archiver = original_modules.archiver

        if getenv_stub then
            getenv_stub:revert()
        end

        if remove_stub then
            remove_stub:revert()
        end
    end)

    local function run(ctx)
        return PLUGIN:BackendInstall(ctx)
    end

    it("requires tool name", function()
        assert.has_error(function()
            run({ tool = "", version = "1.0.0", install_path = "/tmp/install" })
        end, "Tool name cannot be empty")
    end)

    it("requires version", function()
        assert.has_error(function()
            run({ tool = "owner/repo", version = "", install_path = "/tmp/install" })
        end, "Version cannot be empty")
    end)

    it("requires install path", function()
        assert.has_error(function()
            run({ tool = "owner/repo", version = "1.0.0", install_path = "" })
        end, "Install path cannot be empty")
    end)

    it("requires owner/repo tools", function()
        assert.has_error(function()
            run({ tool = "pulumi", version = "1.0.0", install_path = "/tmp/install" })
        end, "Tool pulumi must follow format owner/repo")
    end)

    it("installs official pulumi plugins from get.pulumi.com", function()
        http_responses = {
            { status_code = 200 }, -- get.pulumi.com succeeds
        }

        local result = run({
            tool = "pulumi/pulumi-snowflake",
            version = "0.1.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)
        -- Should not call GitHub API
        assert.equals(0, #http_get_calls)
        assert.equals(1, #http_download_calls)
        assert.equals(
            "https://get.pulumi.com/releases/plugins/pulumi-resource-snowflake-v0.1.0-darwin-amd64.tar.gz",
            http_download_calls[1].url
        )
        assert.equals("/tmp/install/plugin.tar.gz", http_download_calls[1].output)
        assert.equals(1, #archiver_calls)
        assert.equals("/tmp/install/plugin.tar.gz", archiver_calls[1].file_path)
        assert.equals("/tmp/install/bin", archiver_calls[1].dst_dir)
        assert.equals(1, #removed_files)
        assert.equals("/tmp/install/plugin.tar.gz", removed_files[1])
    end)

    it("installs tool plugins when repo uses pulumi-tool prefix", function()
        http_responses = {
            { status_code = 200 }, -- get.pulumi.com succeeds
        }

        local result = run({
            tool = "pulumi/pulumi-tool-npm",
            version = "1.2.3",
            install_path = "/tmp/install",
        })

        assert.same({}, result)
        assert.equals(
            "https://get.pulumi.com/releases/plugins/pulumi-tool-npm-v1.2.3-darwin-amd64.tar.gz",
            http_download_calls[1].url
        )
    end)

    it("installs converter plugins when repo uses pulumi-converter prefix", function()
        http_responses = {
            { status_code = 200 }, -- get.pulumi.com succeeds
        }

        local result = run({
            tool = "pulumi/pulumi-converter-python",
            version = "0.9.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)
        assert.equals(
            "https://get.pulumi.com/releases/plugins/pulumi-converter-python-v0.9.0-darwin-amd64.tar.gz",
            http_download_calls[1].url
        )
    end)

    it("installs third-party plugins from GitHub", function()
        decoded_payload = {
            assets = {
                {
                    name = "pulumi-resource-equinix-v0.6.0-darwin-amd64.tar.gz",
                    url = "https://api.github.com/repos/equinix/pulumi-equinix/releases/assets/12345",
                },
            },
        }

        http_responses = {
            { status_code = 200, body = "" },
            { status_code = 200 },
        }

        local result = run({
            tool = "equinix/pulumi-equinix",
            version = "0.6.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)
        assert.equals("https://api.github.com/repos/equinix/pulumi-equinix/releases/tags/v0.6.0", http_get_calls[1].url)
    end)

    it("uses GITHUB_TOKEN when falling back to GitHub", function()
        env_values.GITHUB_TOKEN = "ghp_test_token"

        decoded_payload = {
            assets = {
                {
                    name = "pulumi-resource-snowflake-v0.1.0-darwin-amd64.tar.gz",
                    url = "https://api.github.com/repos/pulumi/pulumi-snowflake/releases/assets/12345",
                },
            },
        }

        http_responses = {
            { status_code = 404 }, -- get.pulumi.com fails
            { status_code = 200, body = "" }, -- GitHub API succeeds
            { status_code = 200 }, -- GitHub download succeeds
        }

        local result = run({
            tool = "pulumi/pulumi-snowflake",
            version = "0.1.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)
        assert.is_true(#http_get_calls[1].headers > 0)
        assert.equals("Authorization: token ghp_test_token", http_get_calls[1].headers[1])
        assert.is_true(#http_download_calls[2].headers > 0)
        -- First header is Accept, second is Authorization
        assert.equals("Authorization: token ghp_test_token", http_download_calls[2].headers[2])
    end)

    it("raises when GitHub API returns non-200 for third-party plugin", function()
        http_responses = {
            { status_code = 404, body = "" },
        }

        local success, err = pcall(function()
            run({
                tool = "equinix/pulumi-equinix",
                version = "0.6.0",
                install_path = "/tmp/install",
            })
        end)

        assert.is_false(success)
        assert.matches("Failed to fetch release info for equinix/pulumi%-equinix@0%.6%.0: HTTP 404", err)
    end)

    it("raises when asset cannot be found in release for third-party plugin", function()
        decoded_payload = {
            assets = {
                {
                    name = "wrong-asset-name.tar.gz",
                    url = "https://api.github.com/repos/equinix/pulumi-equinix/releases/assets/12345",
                },
            },
        }

        http_responses = {
            { status_code = 200, body = "" },
        }

        local success, err = pcall(function()
            run({
                tool = "equinix/pulumi-equinix",
                version = "0.6.0",
                install_path = "/tmp/install",
            })
        end)

        assert.is_false(success)
        assert.matches(
            "Could not find asset pulumi%-resource%-equinix%-v0%.6%.0%-darwin%-amd64%.tar%.gz in release",
            err
        )
    end)

    it("raises when both get.pulumi.com and GitHub downloads fail", function()
        decoded_payload = {
            assets = {
                {
                    name = "pulumi-resource-snowflake-v0.1.0-darwin-amd64.tar.gz",
                    url = "https://api.github.com/repos/pulumi/pulumi-snowflake/releases/assets/12345",
                },
            },
        }

        http_responses = {
            { status_code = 500 }, -- get.pulumi.com fails
            { status_code = 200, body = "" }, -- GitHub API succeeds
            { status_code = 500 }, -- GitHub download fails
        }

        assert.has_error(function()
            run({
                tool = "pulumi/pulumi-snowflake",
                version = "0.1.0",
                install_path = "/tmp/install",
            })
        end, "Failed to download plugin pulumi/pulumi-snowflake@0.1.0: HTTP 500")
    end)

    it("falls back to GitHub when get.pulumi.com is not available for pulumi org", function()
        decoded_payload = {
            assets = {
                {
                    name = "pulumi-resource-snowflake-v0.1.0-darwin-amd64.tar.gz",
                    url = "https://api.github.com/repos/pulumi/pulumi-snowflake/releases/assets/12345",
                },
            },
        }

        http_responses = {
            { status_code = 404 }, -- get.pulumi.com fails
            { status_code = 200, body = "" }, -- GitHub API succeeds
            { status_code = 200 }, -- GitHub download succeeds
        }

        local result = run({
            tool = "pulumi/pulumi-snowflake",
            version = "0.1.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)
        -- First download attempt was get.pulumi.com
        assert.equals(
            "https://get.pulumi.com/releases/plugins/pulumi-resource-snowflake-v0.1.0-darwin-amd64.tar.gz",
            http_download_calls[1].url
        )
        -- Second download attempt was GitHub
        assert.equals(1, #http_get_calls)
        assert.equals(
            "https://api.github.com/repos/pulumi/pulumi-snowflake/releases/tags/v0.1.0",
            http_get_calls[1].url
        )
        assert.equals(2, #http_download_calls)
        assert.equals(
            "https://api.github.com/repos/pulumi/pulumi-snowflake/releases/assets/12345",
            http_download_calls[2].url
        )
    end)

    it("falls back to GitHub when asset not found in get.pulumi.com for pulumi org", function()
        decoded_payload = {
            assets = {
                {
                    name = "pulumi-resource-snowflake-v0.1.0-darwin-amd64.tar.gz",
                    url = "https://api.github.com/repos/pulumi/pulumi-snowflake/releases/assets/12345",
                },
            },
        }

        http_responses = {
            { status_code = 500 }, -- get.pulumi.com fails with server error
            { status_code = 200, body = "" }, -- GitHub API succeeds
            { status_code = 200 }, -- GitHub download succeeds
        }

        local result = run({
            tool = "pulumi/pulumi-snowflake",
            version = "0.1.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)
        assert.equals(2, #http_download_calls)
        -- First was get.pulumi.com
        assert.equals(
            "https://get.pulumi.com/releases/plugins/pulumi-resource-snowflake-v0.1.0-darwin-amd64.tar.gz",
            http_download_calls[1].url
        )
        -- Second was GitHub
        assert.equals(
            "https://api.github.com/repos/pulumi/pulumi-snowflake/releases/assets/12345",
            http_download_calls[2].url
        )
    end)
end)
