-- mvi_test.lua
sysbench.cmdline.options = {
    table_size = {"Number of rows in the table", 1000000},
    index_type = {"Index to use: ft_json, array or mariadb_array"},
    query_type = {"Lookup to benchmark: member (multi-valued index) or " ..
                  "attr1 (plain index on the first tag)", "member"}
}

-- Map the standard Sysbench commands to our custom Lua functions
sysbench.cmdline.commands = {
    prepare = {
        function() cmd_prepare() end,
        sysbench.cmdline.DESC_DEFAULT
    },
    cleanup = {
        function() cmd_cleanup() end,
        sysbench.cmdline.DESC_DEFAULT
    },
    -- Print the plan for the lookup selected by --index-type/--query-type
    -- instead of benchmarking it.
    explain = {
        function() cmd_explain() end,
        sysbench.cmdline.DESC_DEFAULT
    }
}

function cmd_prepare()
    local drv = sysbench.sql.driver()
    local con = drv:connect()

    local index_type = sysbench.opt.index_type

    print("Creating table mvi_benchmark...")
    con:query("DROP TABLE IF EXISTS mvi_benchmark")

    if index_type == "ft_json" then
        con:query("INSTALL SONAME 'ft_json'")
    end

    local create_table_ft_json = [[
        CREATE TABLE mvi_benchmark (
            id INT AUTO_INCREMENT PRIMARY KEY,
            attributes TEXT,
            attr1 VARCHAR(32),
            FULLTEXT INDEX idx_attributes (attributes) WITH PARSER ft_json,
            INDEX idx_attr1 (attr1)
        )
    ]]

    local create_table_array = [[
        CREATE TABLE mvi_benchmark (
            id INT AUTO_INCREMENT PRIMARY KEY,
            attributes JSON,
            attr1 VARCHAR(32),
            INDEX idx_attributes ((CAST(attributes->'$.tags' AS BINARY(32) ARRAY))),
            INDEX idx_attr1 (attr1)
        )
    ]]

    -- MariaDB's multi-valued index only uses the index when the column is
    -- the MEMBER OF argument, so attributes holds the tags array itself.
    local create_table_mariadb_array = [[
        CREATE TABLE mvi_benchmark (
            id INT AUTO_INCREMENT PRIMARY KEY,
            attributes JSON,
            attr1 VARCHAR(32),
            INDEX idx_attributes (CAST(attributes AS CHAR(32) ARRAY)),
            INDEX idx_attr1 (attr1)
        )
    ]]

    if index_type == "ft_json" then
        con:query(create_table_ft_json)
    elseif index_type == "mariadb_array" then
        con:query(create_table_mariadb_array)
    else
        con:query(create_table_array)
    end

    print(string.format("Inserting %d rows (using batches of 1000)...", sysbench.opt.table_size))

    -- Batch inserts for faster data population
    local batch_size = 1000
    for i = 1, sysbench.opt.table_size, batch_size do
        local query = "INSERT INTO mvi_benchmark (attributes, attr1) VALUES "
        local values = {}
        local end_idx = math.min(i + batch_size - 1, sysbench.opt.table_size)

        for j = i, end_idx do
            -- Generate a JSON array with 1 or 2 random tags (50/50), each of the
            -- form "value-N" with N between 1 and table_size. attr1 duplicates
            -- the first array element as a plain indexed column, so the same
            -- lookup can be benchmarked with and without the multi-valued index.
            local t1 = sysbench.rand.default(1, sysbench.opt.table_size)
            if index_type == "mariadb_array" then
                -- attributes is the tags array itself, see above
                if sysbench.rand.uniform(1, 2) == 1 then
                    table.insert(values,
                        string.format("('[\"value-%d\"]', 'value-%d')", t1, t1))
                else
                    local t2 = sysbench.rand.default(1, sysbench.opt.table_size)
                    table.insert(values,
                        string.format("('[\"value-%d\", \"value-%d\"]', 'value-%d')",
                                      t1, t2, t1))
                end
            elseif sysbench.rand.uniform(1, 2) == 1 then
                table.insert(values,
                    string.format("('{\"tags\": [\"value-%d\"]}', 'value-%d')", t1, t1))
            else
                local t2 = sysbench.rand.default(1, sysbench.opt.table_size)
                table.insert(values,
                    string.format("('{\"tags\": [\"value-%d\", \"value-%d\"]}', 'value-%d')",
                                  t1, t2, t1))
            end
        end

        query = query .. table.concat(values, ", ")
        con:query(query)
    end
    print("Prepare phase complete.")
    con:disconnect()
end

function cmd_cleanup()
    local drv = sysbench.sql.driver()
    local con = drv:connect()

    print("Cleaning up table mvi_benchmark...")
    con:query("DROP TABLE IF EXISTS mvi_benchmark")
    con:disconnect()
end

-- Available lookups, selected with --query-type. Both search for the same
-- "value-N" tag, but member goes through the multi-valued index while attr1
-- goes through a plain B-tree on the first tag. These only build the SQL, so
-- the same text can be either executed (run) or explained (explain).
local sql_for = {
    member_ft_json = function(tag)
        return string.format(
            "SELECT id FROM mvi_benchmark WHERE MATCH(attributes) AGAINST ('tags.0=value-%d' IN BOOLEAN MODE)", tag)
    end,

    member_mariadb_array = function(tag)
        return string.format(
            "SELECT id FROM mvi_benchmark WHERE 'value-%d' MEMBER OF(attributes)", tag)
    end,

    member_array = function(tag)
        return string.format(
            "SELECT id FROM mvi_benchmark WHERE 'value-%d' MEMBER OF(attributes->'$.tags')", tag)
    end,

    attr1 = function(tag)
        return string.format(
            "SELECT id FROM mvi_benchmark WHERE attr1 = 'value-%d'", tag)
    end
}

-- Resolve --index-type/--query-type into one SQL builder, so a typo fails at
-- startup rather than running the wrong benchmark to completion. Shared by
-- thread_init() and the explain command.
local function resolve_query()
    local index_type = sysbench.opt.index_type
    if (index_type ~= "ft_json" and index_type ~= "array" and
        index_type ~= "mariadb_array") then
       error("The argument --index-type must be set")
    end

    local query_type = sysbench.opt.query_type
    if query_type == "member" then
      if index_type == "ft_json" then
        query_type = "member_ft_json"
      elseif index_type == "mariadb_array" then
        query_type = "member_mariadb_array"
      else
        query_type = "member_array"
      end
    end

    local builder = sql_for[query_type]
    if not builder then
        error(string.format("unknown --query-type '%s' (expected: member, attr1)",
                            sysbench.opt.query_type))
    end
    return builder, query_type
end

-- Custom command: show the plan for one instance of the benchmarked lookup.
-- Runs standalone, so thread_init() is not called and it connects itself.
function cmd_explain()
    local drv = sysbench.sql.driver()
    local con = drv:connect()

    local build_sql, query_type = resolve_query()
    local query = build_sql(sysbench.rand.default(1, sysbench.opt.table_size))

    print(string.format("index-type: %s, query-type: %s",
                        sysbench.opt.index_type, query_type))
    print(query)

    -- EXPLAIN FORMAT=JSON returns a single row with a single column, so
    -- query_row() gives us the whole plan as one string.
    local plan = con:query_row("EXPLAIN FORMAT=JSON " .. query)
    print(plan or "(no plan returned)")

    con:disconnect()
end

local run_query

function thread_init()
    local build_sql = resolve_query()

    drv = sysbench.sql.driver()
    con = drv:connect()

    run_query = function(tag) con:query(build_sql(tag)) end
end

function event()
    -- Pick a random tag between 1 and table_size to search for
    local random_tag = sysbench.rand.default(1, sysbench.opt.table_size)

    run_query(random_tag)
end

function thread_done()
    con:disconnect()
end
