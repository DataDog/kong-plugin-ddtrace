--[[
`normalize_header_tags` processes a collection of header tags, normalizing
and transforming them into a standardized format.

It assumes that the input `header_tags` has already passed validation,
including type checking and uniqueness of keys.

The normalization involves converting headers to lowercase, removing
whitespaces, replacing non-alphanumeric characters with underscores,
and handling the optional `tag` attribute.

Normalization Steps:
1. Lowercasing and Removal of Whitespaces.
2. Replacing Non-Alphanumeric Characters.
3. Handling Empty Headers.
4. Handling Optional Tags.

Usage Notes:
============
- This function assumes that the input `header_tags` has already
  undergone validation, ensuring that each entry is a table with
  appropriate properties.
- The `tag` attribute is optional, and if not provided or empty,
  the function uses the normalized header itself as the associated
  value.

Example:
```lua
local header_tags = {
  { header = "Content-Type", tag = "case_insensitive" },
  { header = "  Host      ", tag = "" },
  { header = "D!ata__d/o!g", tag = "   " },
}

local result = normalize_header_tags(header_tags)
-- Result:
-- {
--   content-type = { normalized = false, value = "case_insensitive" },
--   host = { normalized = true, value = "host" },
--   d_ata__d_o_g = { normalized = true, value = "d_ata__d_o_g" },
-- }
--]]
local function normalize_header_tags(header_tags)
    -- `header_tags` already passed the validation step, no need to check for
    -- the type and if the key is unique.
    local normalized = {}

    for i = 1, #header_tags do
        local tag = header_tags[i].tag
        local header = header_tags[i].header

        local norm_header = string.lower(string.gsub(header, "%s+", ""))
        if #norm_header == 0 then
            goto continue
        end

        norm_header = string.gsub(norm_header, "[^a-zA-Z0-9 -]", "_")

        tag = string.gsub(tag, "%s+", "")
        if not tag or #tag == 0 then
            normalized[norm_header] = { normalized = true, value = norm_header }
        else
            normalized[norm_header] = { normalized = false, value = tag }
        end

        ::continue::
    end

    return normalized
end

local function concat(input, separator)
    if type(input) ~= "table" then
        return input
    end

    return table.concat(input, separator)
end

return {
    concat = concat,
    normalize_header_tags = normalize_header_tags,
}
