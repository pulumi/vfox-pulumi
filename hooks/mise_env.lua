-- Extracts PULUMI_VERSION_MISE and GO_VERSION_MISE from go.mod

local function read_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    return content
end

local function extract_pulumi_version(content, module_path)
    -- Look for lines containing the module path
    for line in content:gmatch("[^\r\n]+") do
        if line:find(module_path, 1, true) then
            -- Extract version starting with 'v' followed by digits
            -- Match the version after the module path
            local version = line:match(module_path .. "%s+v([0-9]+%.[0-9]+%.[0-9]+)")
            if version then
                return version
            end
        end
    end
    return nil
end

local function extract_go_version(content)
    -- Prefer toolchain directive if present
    local toolchain_version = content:match("toolchain%s+go([0-9][^\r\n]*)")
    if toolchain_version then
        return toolchain_version:match("^[^%s]+")
    end

    -- Fall back to go version line
    local go_version = content:match("go%s+([0-9][^\r\n]*)")
    if go_version then
        return go_version:match("^[^%s]+")
    end

    return nil
end

local function find_git_root()
    -- Try to find .git directory by walking up the tree
    local current_dir = "."
    for _ = 1, 10 do -- Limit depth to avoid infinite loops
        local git_dir = current_dir .. "/.git"
        local f = io.open(git_dir .. "/config", "r")
        if f then
            f:close()
            return current_dir
        end
        current_dir = current_dir .. "/.."
    end
    return nil
end

function PLUGIN:MiseEnv(ctx)
    -- Ensure PULUMI_HOME symlinks exist for ALL installed pulumi plugins
    -- This runs when mise env hook is triggered (shell activation, directory change, config change)
    -- This handles cache restoration automatically - if mise installs exist but PULUMI_HOME is empty,
    -- the symlinks will be created here
    local pulumi_home_lib = require("pulumi_home")

    -- Get all installed pulumi: tools from mise
    local handle = io.popen("mise list 2>/dev/null | grep '^pulumi:'")
    if handle then
        for line in handle:lines() do
            local tool, version = line:match("^(pulumi:[^%s]+)%s+([^%s]+)")
            if tool and version then
                -- Get install path for this tool
                local where_handle = io.popen("mise where " .. tool .. " 2>/dev/null")
                if where_handle then
                    local install_path = where_handle:read("*l")
                    where_handle:close()
                    if install_path and install_path ~= "" then
                        local bin_path = install_path .. "/bin"
                        local tool_name = tool:gsub("^pulumi:", "")
                        -- Silently ensure symlink exists (pcall to avoid errors stopping other env setup)
                        pcall(function()
                            pulumi_home_lib.ensure_pulumi_home_link(bin_path, tool_name, version)
                        end)
                    end
                end
            end
        end
        handle:close()
    end

    -- Original go.mod parsing logic
    local module_path = "github.com/pulumi/pulumi/pkg/v3"
    local go_mod_path = ctx.options.module_path or ""
    local gomod = "go.mod"

    if go_mod_path ~= "" and go_mod_path ~= "." then
        gomod = go_mod_path .. "/" .. gomod
    end

    -- First, try to read go.mod from the specified location (or current dir)
    local content = read_file(gomod)

    -- If not found and no custom path was specified, try the repo root
    if not content and (go_mod_path == "" or go_mod_path == ".") then
        local git_root = find_git_root()
        if git_root then
            content = read_file(git_root .. "/go.mod")
        end
    end

    if not content then
        -- No go.mod found, return empty (don't set variables, don't error)
        return {}
    end

    -- Extract both versions independently
    local pulumi_version = extract_pulumi_version(content, module_path)
    local go_version = extract_go_version(content)

    -- Build result array with whatever we found
    local result = {}

    if pulumi_version then
        table.insert(result, { key = "PULUMI_VERSION_MISE", value = pulumi_version })
    end

    if go_version then
        table.insert(result, { key = "GO_VERSION_MISE", value = go_version })
    end

    return result
end
