local cmd_exec_calls
local http_download_calls
local archiver_decompress_calls
local original_getenv = os.getenv
local getenv_stub
local env_values
local original_modules = {}

describe("backend_install", function()
    local function load_subject()
        _G.PLUGIN = {}
        -- Only set RUNTIME if it's not already set (for tests that override it)
        if not _G.RUNTIME then
            _G.RUNTIME = {
                osType = "Darwin",
                archType = "arm64",
            }
        end
        dofile("hooks/backend_install.lua")
    end

    before_each(function()
        cmd_exec_calls = {}
        http_download_calls = {}
        archiver_decompress_calls = {}
        env_values = {}

        original_modules.file = package.loaded.file
        original_modules.strings = package.loaded.strings
        original_modules.cmd = package.loaded.cmd
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

        package.loaded.cmd = {
            exec = function(command)
                table.insert(cmd_exec_calls, command)
                return ""
            end,
        }

        package.loaded.http = {
            download_file = function(opts, path)
                table.insert(http_download_calls, { url = opts.url, path = path })
                -- Simulate successful download by returning nil
                return nil
            end,
        }

        package.loaded.archiver = {
            decompress = function(archive_path, destination)
                table.insert(archiver_decompress_calls, { archive = archive_path, dest = destination })
            end,
        }

        getenv_stub = stub(os, "getenv", function(name)
            if env_values[name] ~= nil then
                return env_values[name]
            end
            return original_getenv(name)
        end)

        load_subject()
    end)

    after_each(function()
        _G.PLUGIN = nil
        _G.RUNTIME = nil

        package.loaded.file = original_modules.file
        package.loaded.strings = original_modules.strings
        package.loaded.cmd = original_modules.cmd
        package.loaded.http = original_modules.http
        package.loaded.archiver = original_modules.archiver

        if getenv_stub then
            getenv_stub:revert()
        end
    end)

    local function run(ctx)
        return PLUGIN:BackendInstall(ctx)
    end

    -- Validation tests
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

    -- Installation tests
    it("installs resource plugins using direct download from CDN", function()
        env_values.HOME = "/home/test"

        local result = run({
            tool = "pulumi/pulumi-snowflake",
            version = "0.1.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify download was attempted from CDN
        assert.same(1, #http_download_calls)
        assert.is_truthy(
            http_download_calls[1].url:match(
                "https://get%.pulumi%.com/releases/plugins/pulumi%-resource%-snowflake%-v0%.1%.0%-darwin%-arm64%.tar%.gz"
            )
        )

        -- Verify extraction
        assert.same(1, #archiver_decompress_calls)

        -- Verify installation commands
        local found_rm_tarball = false

        for _, cmd in ipairs(cmd_exec_calls) do
            if cmd:match("rm %-f .*/plugin%.tar%.gz") then
                found_rm_tarball = true
            end
        end

        assert.is_true(found_rm_tarball, "Should cleanup tarball")
    end)

    it("installs tool plugins when repo uses pulumi-tool prefix", function()
        env_values.HOME = "/home/test"

        local result = run({
            tool = "pulumi/pulumi-tool-npm",
            version = "1.2.3",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify correct plugin type in URL
        assert.same(1, #http_download_calls)
        assert.is_truthy(http_download_calls[1].url:match("pulumi%-tool%-npm%-v1%.2%.3"))
    end)

    it("installs converter plugins when repo uses pulumi-converter prefix", function()
        env_values.HOME = "/home/test"

        local result = run({
            tool = "pulumi/pulumi-converter-python",
            version = "0.9.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify correct plugin type in URL
        assert.same(1, #http_download_calls)
        assert.is_truthy(http_download_calls[1].url:match("pulumi%-converter%-python%-v0%.9%.0"))
    end)

    it("falls back to GitHub when CDN fails", function()
        env_values.HOME = "/home/test"

        -- Make first download (CDN) fail, second (GitHub) succeed
        local download_count = 0
        package.loaded.http = {
            download_file = function(opts, path)
                download_count = download_count + 1
                table.insert(http_download_calls, { url = opts.url, path = path })
                if download_count == 1 then
                    return "CDN download failed"
                end
                -- Second call succeeds
                return nil
            end,
        }
        load_subject()

        local result = run({
            tool = "pulumi/pulumi-random",
            version = "4.16.8",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify both downloads were attempted
        assert.same(2, #http_download_calls)
        assert.is_truthy(http_download_calls[1].url:match("https://get%.pulumi%.com"))
        assert.is_truthy(
            http_download_calls[2].url:match("https://github%.com/pulumi/pulumi%-random/releases/download")
        )
    end)

    it("uses GitHub directly for third-party providers", function()
        env_values.HOME = "/home/test"

        local result = run({
            tool = "oxidecomputer/pulumi-oxide",
            version = "0.5.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify only GitHub download was attempted (no CDN)
        assert.same(1, #http_download_calls)
        assert.is_truthy(http_download_calls[1].url:match("https://github%.com/oxidecomputer/pulumi%-oxide"))
        assert.is_falsy(http_download_calls[1].url:match("get%.pulumi%.com"))
    end)

    it("uses Windows commands when on Windows", function()
        -- Clear state and reset with Windows RUNTIME
        _G.RUNTIME = nil
        _G.PLUGIN = nil
        http_download_calls = {}
        cmd_exec_calls = {}
        archiver_decompress_calls = {}

        -- Mock io.popen for Windows command execution
        local original_io_popen = io.popen
        io.popen = function(command)
            -- Strip the 2>&1 redirect for cleaner command logging
            local clean_cmd = command:gsub(" 2>&1$", "")
            table.insert(cmd_exec_calls, clean_cmd)

            -- Return success for all commands
            return {
                read = function() return "" end,
                close = function() return true, "exit", 0 end
            }
        end

        -- Re-setup mocks
        package.loaded.http = {
            download_file = function(opts, path)
                table.insert(http_download_calls, { url = opts.url, path = path })
                return nil
            end,
        }
        package.loaded.archiver = {
            decompress = function(archive_path, destination)
                table.insert(archiver_decompress_calls, { archive = archive_path, dest = destination })
            end,
        }
        package.loaded.cmd = {
            exec = function(command)
                table.insert(cmd_exec_calls, command)
                return ""
            end,
        }

        _G.RUNTIME = {
            osType = "Windows",
            archType = "amd64",
        }
        env_values.TEMP = "C:/Users/test/AppData/Local/Temp"
        env_values.USERPROFILE = "C:/Users/test"
        env_values.HOME = nil -- Use nil instead of false

        load_subject()

        local result = run({
            tool = "pulumi/pulumi-azure",
            version = "5.0.0",
            install_path = "C:/tmp/install",
        })

        assert.same({}, result)

        -- Verify Windows asset name in download URL
        assert.same(1, #http_download_calls, "Expected 1 download call, got " .. #http_download_calls)
        if #http_download_calls > 0 and http_download_calls[1] then
            assert.is_truthy(
                http_download_calls[1].url:match("windows%-amd64"),
                "Expected URL to contain 'windows-amd64', got: " .. tostring(http_download_calls[1].url)
            )
        else
            error("No download calls recorded")
        end

        -- Verify Windows commands are used
        local found_del = false

        for _, cmd in ipairs(cmd_exec_calls) do
            if cmd:match("del /F /Q.*plugin%.tar%.gz") then
                found_del = true
            end
        end

        assert.is_true(found_del, "Should delete tarball after extraction")

        -- Restore original io.popen
        io.popen = original_io_popen
    end)

    it("raises when download fails from both sources", function()
        env_values.HOME = "/home/test"

        -- Make all downloads fail
        package.loaded.http = {
            download_file = function(opts, path)
                table.insert(http_download_calls, { url = opts.url, path = path })
                return "Network error"
            end,
        }
        load_subject()

        assert.has_error(function()
            run({
                tool = "pulumi/pulumi-gcp",
                version = "7.0.0",
                install_path = "/tmp/install",
            })
        end)
    end)

    it("raises when extraction fails", function()
        env_values.HOME = "/home/test"

        -- Make extraction fail
        package.loaded.archiver = {
            decompress = function(archive_path, destination)
                table.insert(archiver_decompress_calls, { archive = archive_path, dest = destination })
                error("Corrupted archive")
            end,
        }
        load_subject()

        assert.has_error(function()
            run({
                tool = "pulumi/pulumi-kubernetes",
                version = "4.0.0",
                install_path = "/tmp/install",
            })
        end)
    end)

    it("uses correct platform detection for Linux amd64", function()
        -- Clear state and reset with Linux RUNTIME
        _G.RUNTIME = nil
        _G.PLUGIN = nil
        http_download_calls = {}
        cmd_exec_calls = {}
        archiver_decompress_calls = {}

        -- Re-setup mocks
        package.loaded.http = {
            download_file = function(opts, path)
                table.insert(http_download_calls, { url = opts.url, path = path })
                return nil
            end,
        }
        package.loaded.archiver = {
            decompress = function(archive_path, destination)
                table.insert(archiver_decompress_calls, { archive = archive_path, dest = destination })
            end,
        }
        package.loaded.cmd = {
            exec = function(command)
                table.insert(cmd_exec_calls, command)
                return ""
            end,
        }

        _G.RUNTIME = {
            osType = "Linux",
            archType = "x86_64", -- Should map to amd64
        }
        env_values.HOME = "/home/test"

        load_subject()

        local result = run({
            tool = "pulumi/pulumi-aws",
            version = "6.0.0",
            install_path = "/tmp/install",
        })

        assert.same({}, result)

        -- Verify correct OS and arch in URL
        assert.same(1, #http_download_calls, "Expected 1 download call, got " .. #http_download_calls)
        if #http_download_calls > 0 and http_download_calls[1] then
            assert.is_truthy(
                http_download_calls[1].url:match("linux%-amd64"),
                "Expected URL to contain 'linux-amd64', got: " .. tostring(http_download_calls[1].url)
            )
        else
            error("No download calls recorded")
        end
    end)
end)
