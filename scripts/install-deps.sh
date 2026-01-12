#!/usr/bin/env bash
# Install Lua dependencies to local tree

set -e

echo "Installing Lua dependencies with luarocks..."
luarocks install --only-deps --tree=lua_modules vfox-pulumi-dev-1.rockspec
echo "Dependencies installed successfully"
