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

    -- TODO: trim tag. Space in tag is OK?
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
  normalize_header_tags = normalize_header_tags
}
