local utils = require("kong.plugins.ddtrace.utils")

local function count_table(t)
    local count = 0

    for _ in pairs(t) do
        count = count + 1
    end

    return count
end

describe("utils.normalize_headers_tag", function()
    it("header", function()
        local header_tags = {
            { header = "Content-Type", tag = "case_insensitive" },
            { header = "  Host      ", tag = "trimed" },
            { header = "D!ata__d/o!g", tag = "replace character" },
        }

        local norm_header_tags = utils.normalize_header_tags(header_tags)

        assert.equal(count_table(norm_header_tags), 3)
        assert.is_not_nil(norm_header_tags["content-type"])
        assert.is_not_nil(norm_header_tags["host"])
        assert.is_not_nil(norm_header_tags["d_ata__d_o_g"])
    end)
    it("tag", function()
        local header_tags = {
            { header = "ConTeNt-Type", tag = "" },
            { header = "D!ata__d/o!g", tag = "_dd.header" },
            { header = "foo", tag = " " },
            { header = "bar", tag = " mytag      " },
        }

        local norm_header_tags = utils.normalize_header_tags(header_tags)

        assert.equal(count_table(norm_header_tags), 4)
        assert.same(norm_header_tags["content-type"], { normalized = true, value = "content-type" })
        assert.same(norm_header_tags["d_ata__d_o_g"], { normalized = false, value = "_dd.header" })
        assert.same(norm_header_tags["foo"], { normalized = true, value = "foo" })
        assert.same(norm_header_tags["bar"], { normalized = false, value = "mytag" })
    end)
end)

describe("utils.concat", function()
    it("table", function()
        local my_array = { "Monday", "Tuesday", "Mercredi" }

        assert.same(utils.concat(my_array, ", "), "Monday, Tuesday, Mercredi")
        assert.same(utils.concat("Datadog", ", "), "Datadog")
    end)
end)
