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
            { header = nil, tag = nil },
            { header = nil, tag = "foobar" },
            { header = "lorem", tag = nil },
            { header = "ConTeNt-Type", tag = "" },
            { header = "D!ata__d/o!g", tag = "_dd.header" },
            { header = "foo", tag = " " },
            { header = "bar", tag = " mytag      " },
        }

        local norm_header_tags = utils.normalize_header_tags(header_tags)

        assert.equal(count_table(norm_header_tags), 5)
        assert.same(norm_header_tags["content-type"], { normalized = true, value = "content-type" })
        assert.same(norm_header_tags["d_ata__d_o_g"], { normalized = false, value = "_dd.header" })
        assert.same(norm_header_tags["foo"], { normalized = true, value = "foo" })
        assert.same(norm_header_tags["bar"], { normalized = false, value = "mytag" })
        assert.same(norm_header_tags["lorem"], { normalized = true, value = "lorem" })
    end)
end)

describe("utils.concat", function()
    it("table", function()
        local my_array = { "Monday", "Tuesday", "Mercredi" }

        assert.same(utils.concat(my_array, ", "), "Monday, Tuesday, Mercredi")
        assert.same(utils.concat("Datadog", ", "), "Datadog")
    end)
end)

describe("utils.set_http_header_tags", function()
    local function run(header_tags, req, res)
        local recorded = {}
        local span = {
            set_tag = function(_, k, v)
                table.insert(recorded, { k, v })
            end,
        }
        utils.set_http_header_tags(span, header_tags, function(n)
            return req[n]
        end, function(n)
            return res[n]
        end)
        return recorded
    end

    it("prefixes normalized keys with http.request/response.headers.<name>", function()
        local tags = { host = { normalized = true, value = "host" } }
        assert.same({
            { "http.request.headers.host", "req" },
            { "http.response.headers.host", "res" },
        }, run(tags, { host = "req" }, { host = "res" }))
    end)

    it("uses tag_info.value as-is and lets response win when not normalized", function()
        local tags = { ["x-dd"] = { normalized = false, value = "custom.tag" } }
        assert.same({ { "custom.tag", "res" } }, run(tags, { ["x-dd"] = "req" }, { ["x-dd"] = "res" }))
        assert.same({ { "custom.tag", "req" } }, run(tags, { ["x-dd"] = "req" }, {}))
    end)

    it("joins multi-value headers with a comma", function()
        local tags = { accept = { normalized = true, value = "accept" } }
        assert.same(
            { { "http.request.headers.accept", "text/html,application/json" } },
            run(tags, { accept = { "text/html", "application/json" } }, {})
        )
    end)
end)

describe("utils.is_truthy", function()
    it("cases", function()
        local test_cases = {
            { input = nil, expected = false },
            { input = "", expected = false },
            { input = "false", expected = false },
            { input = "no", expected = false },
            { input = "0", expected = false },
            { input = "anything", expected = false },
            { input = "1", expected = true },
            { input = "true", expected = true },
            { input = "yes", expected = true },
        }

        for _, case in ipairs(test_cases) do
            assert.same(case.expected, utils.is_truthy(case.input))
        end
    end)
end)
