-- metadata.lua
-- Backend plugin metadata and configuration
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html

PLUGIN = { -- luacheck: ignore
    -- Required: Plugin name (will be the backend name users reference)
    name = "vfox-pulumi",

    -- Required: Plugin version (not the tool versions)
    version = "0.0.1",

    -- Required: Brief description of the backend and tools it manages
    description = "A mise backend plugin for pulumi tools",

    -- Required: Plugin author/maintainer
    author = "pulumi",

    -- Optional: Plugin homepage/repository URL
    homepage = "https://github.com/pulumi/vfox-pulumi",

    -- Optional: Plugin license
    license = "Apache",

    -- Optional: Important notes for users
    notes = {
        -- "Requires pulumi to be installed on your system",
        -- "This plugin manages tools from the pulumi ecosystem"
    },
}
