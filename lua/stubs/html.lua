---@meta

---@alias HtmlEachCallback fun(index: integer, selection: HtmlSelection)

---@class HtmlSelection
local HtmlSelection = {}

---Find descendants matching a CSS selector.
---@param selector string
---@return HtmlSelection
function HtmlSelection:find(selector) end

---Return the first matched node.
---@return HtmlSelection
function HtmlSelection:first() end

---Return the node at the given zero-based index.
---@param index integer
---@return HtmlSelection
function HtmlSelection:eq(index) end

---Iterate over matched nodes.
---@param callback HtmlEachCallback
function HtmlSelection:each(callback) end

---Get text content of the wrapped node.
---@return string
function HtmlSelection:text() end

---Get an attribute value or an empty string if missing.
---@param key string
---@return string
function HtmlSelection:attr(key) end

---@class HtmlModule
local html = {}

---Parse an HTML string into a navigable selection.
---@param markup string
---@return HtmlSelection
function html.parse(markup) end

return html
