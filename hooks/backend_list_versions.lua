local function classify(version)
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    if major then
        return 1, tonumber(major), tonumber(minor), tonumber(patch), version
    end
    return 0, nil, nil, nil, version
end

local function stable_first_sort(a, b)
    local a_rank, a_major, a_minor, a_patch, a_version = classify(a)
    local b_rank, b_major, b_minor, b_patch, b_version = classify(b)

    if a_rank ~= b_rank then
        return a_rank < b_rank
    end

    if a_rank == 1 then
        if a_major ~= b_major then
            return a_major < b_major
        end
        if a_minor ~= b_minor then
            return a_minor < b_minor
        end
        if a_patch ~= b_patch then
            return a_patch < b_patch
        end
        return a_version < b_version
    end

    return a_version < b_version
end

function PLUGIN:BackendListVersions(ctx)
    local tool = ctx.tool and ctx.tool:gsub("^%s+", ""):gsub("%s+$", "")

    -- Validate tool name
    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end

    local owner, repo = tool:match("^([^/%s]+)/([^/%s]+)$")
    if not owner or not repo then
        error("Tool " .. tool .. " must follow format owner/repo")
    end

    local full_repo = owner .. "/" .. repo

    local tool_cfg = ctx.tool_config or {}
    local http = require("http")
    local json = require("json")
    local headers = { ["User-Agent"] = "mise-backend-pulumi" }

    local token = os.getenv("GITHUB_TOKEN")
    if token and token ~= "" then
        headers["Authorization"] = "Bearer " .. token
    end

    local include_prerelease = tool_cfg.include_prerelease
    if include_prerelease == nil and ctx.options then
        include_prerelease = ctx.options.include_prerelease or ctx.options.prerelease
    end
    include_prerelease = include_prerelease == true

    local per_page = 100
    local versions = {}
    local seen = {}

    local api_url =
        string.format("https://api.github.com/repos/%s/releases?per_page=%d", full_repo, per_page)

    local resp, err = http.get({
        url = api_url,
        headers = headers,
    })

    if err then
        error("Failed to fetch versions for " .. tool .. ": " .. err)
    end

    if resp.status_code ~= 200 then
        error(("GitHub API returned status %d for %s"):format(resp.status_code, full_repo))
    end

    local releases = json.decode(resp.body)
    if type(releases) ~= "table" or #releases == 0 then
        error("No versions found for " .. tool .. " in GitHub releases")
    end

    for _, release in ipairs(releases) do
        if not release.draft and (include_prerelease or not release.prerelease) then
            local tag = release.tag_name or ""
            if tag ~= "" then
                local version = tag:gsub("^v", "")
                if not seen[version] then
                    table.insert(versions, version)
                    seen[version] = true
                end
            end
        end
    end

    table.sort(versions, stable_first_sort)

    return { versions = versions }
end
