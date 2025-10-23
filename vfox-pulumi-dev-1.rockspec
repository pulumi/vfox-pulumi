rockspec_format = "3.0"
package = "vfox-pulumi"
version = "dev-1"
source = {
    url = "git+https://github.com/pulumi/vfox-pulumi.git",
}
description = {
    detailed = "This is a mise backend plugin using the vfox-style backend architecture.",
    homepage = "https://github.com/pulumi/vfox-pulumi",
    license = "*** please specify a license ***",
}
dependencies = {
    "luacheck",
    "busted",
}
build_dependencies = {}
build = {
    type = "builtin",
    modules = {
        ["stubs.archiver"] = "lua/stubs/archiver.lua",
        ["stubs.cmd"] = "lua/stubs/cmd.lua",
        ["stubs.env"] = "lua/stubs/env.lua",
        ["stubs.file"] = "lua/stubs/file.lua",
        ["stubs.html"] = "lua/stubs/html.lua",
        ["stubs.http"] = "lua/stubs/http.lua",
        ["stubs.json"] = "lua/stubs/json.lua",
        ["stubs.strings"] = "lua/stubs/strings.lua",
        ["stubs.vfox.cmd"] = "lua/stubs/vfox/cmd.lua",
        ["stubs.vfox.env"] = "lua/stubs/vfox/env.lua",
        ["stubs.vfox.strings"] = "lua/stubs/vfox/strings.lua",
    },
}
test_dependencies = {}
