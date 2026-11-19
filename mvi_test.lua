-- mvi_test.lua
sysbench.cmdline.options = {
    table_size = {"Number of rows in the table", 1000000},
    index_type = {"Index to use: ft_json, array, mariadb_array or pg_gin"},
    query_type = {"Workload to benchmark: the lookups member, attr1, and2, " ..
                  "and2_attr, with_range, range_only, join or join_attr1, " ..
                  "or the writes insert, update_array or write_heavy",
                  "member"},
    data_set = {"Data to load and query: uniform (1-2 tags per row, " ..
                "uniform over table_size values) or skewed (1-5 tags per " ..
                "row, Pareto over --skewed-values values, skew set by " ..
                "--rand-pareto-h)", "uniform"},
    skewed_values = {"Number of distinct tags in the skewed data set", 10000},
    common_values = {"and2 and and2_attr pick both tags from the " ..
                     "--common-values most common ones", 20},
    range_pct = {"Width of the created range in with_range and " ..
                 "range_only, in percent of the rows", 1},
    join_values = {"Number of tags joined per query in join and join_attr1", 10},
    join_groups = {"Number of tag groups to pick from in join and join_attr1", 1000},
    verify_count = {"Number of queries run by the verify command", 100},
    array_index = {"prepare: create the array index (on), or not (off: the " ..
                   "control of the write workloads)", "on"},
    gin_fastupdate = {"PostgreSQL: fastupdate of the GIN index (on or off)", "on"},
    settle = {"prepare: end with the settle command (on or off)", "on"},
    index_name = {"drop_index and create_index: the array index (array) " ..
                  "or the B-tree on attr1 (attr1)", "array"}
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
    },
    -- Print the number and the sum of the ids matched by --verify-count
    -- instances of the lookup, to compare results between servers.
    verify = {
        function() cmd_verify() end,
        sysbench.cmdline.DESC_DEFAULT
    },
    -- Bring the loaded table to a steady state (statistics, no pending
    -- background work), as prepare does at its end unless --settle=off.
    settle = {
        function() cmd_settle() end,
        sysbench.cmdline.DESC_DEFAULT
    },
    -- Drop or create the index named by --index-name, to time the index
    -- build on a loaded table (W2).
    drop_index = {
        function() cmd_index(false) end,
        sysbench.cmdline.DESC_DEFAULT
    },
    create_index = {
        function() cmd_index(true) end,
        sysbench.cmdline.DESC_DEFAULT
    }
}

local function check_data_set()
    local data_set = sysbench.opt.data_set
    if data_set ~= "uniform" and data_set ~= "skewed" then
        error(string.format("unknown --data-set '%s' (expected: uniform, skewed)",
                            data_set))
    end
end

-- Number of distinct tags in the data set: tags are "value-1" to
-- "value-<domain>".
local function tag_domain()
    if sysbench.opt.data_set == "skewed" then
        return sysbench.opt.skewed_values
    end
    return sysbench.opt.table_size
end

-- One tag drawn with the data set's distribution. In the skewed data set
-- "value-1" is the most common tag. Pareto rather than Zipf, which
-- released sysbench versions (up to 1.0.20) don't have.
local function data_tag()
    if sysbench.opt.data_set == "skewed" then
        return sysbench.rand.pareto(1, sysbench.opt.skewed_values)
    end
    return sysbench.rand.default(1, sysbench.opt.table_size)
end

-- n distinct tags, each drawn with draw()
local function distinct_tags(n, draw)
    local tags, seen = {}, {}
    while #tags < n do
        local t = draw()
        if not seen[t] then
            seen[t] = true
            table.insert(tags, t)
        end
    end
    return tags
end

-- The tags of one row. The draws don't depend on --index-type, so with the
-- same --rand-seed every server gets the same data.
local function row_tags()
    if sysbench.opt.data_set == "skewed" then
        return distinct_tags(sysbench.rand.uniform(1, 5), data_tag)
    end
    -- 1 or 2 tags (50/50)
    local t1 = data_tag()
    if sysbench.rand.uniform(1, 2) == 1 then
        return {t1}
    end
    return {t1, data_tag()}
end

-- JSON array of "value-N" strings
local function json_tags(tags)
    local quoted = {}
    for i, t in ipairs(tags) do
        quoted[i] = string.format("\"value-%d\"", t)
    end
    return "[" .. table.concat(quoted, ", ") .. "]"
end

-- The values of one new row, as "(attributes, attr1, attr2, created)"
-- strings, drawn with the data set's distribution
local function row_values()
    local tags = row_tags()
    local doc = json_tags(tags)
    if sysbench.opt.index_type ~= "mariadb_array" then
        -- attributes is the tags array itself for mariadb_array, see
        -- cmd_prepare()
        doc = "{\"tags\": " .. doc .. "}"
    end
    local attr2 = "NULL"
    if tags[2] then
        attr2 = string.format("'value-%d'", tags[2])
    end
    return string.format("'%s'", doc), string.format("'value-%d'", tags[1]),
           attr2, tostring(sysbench.rand.uniform(1, sysbench.opt.table_size))
end

-- DDL creating and dropping the array index of each --index-type
local function array_index_sql(index_type)
    if index_type == "pg_gin" then
        local fastupdate = sysbench.opt.gin_fastupdate
        if fastupdate ~= "on" and fastupdate ~= "off" then
            error("--gin-fastupdate must be on or off")
        end
        return "CREATE INDEX idx_attributes ON mvi_benchmark " ..
               "USING GIN ((attributes->'tags') jsonb_path_ops) " ..
               "WITH (fastupdate = " .. fastupdate .. ")",
               "DROP INDEX idx_attributes"
    end
    local def
    if index_type == "ft_json" then
        def = "FULLTEXT INDEX idx_attributes (attributes) WITH PARSER ft_json"
    elseif index_type == "mariadb_array" then
        def = "INDEX idx_attributes (CAST(attributes AS CHAR(32) ARRAY))"
    else
        def = "INDEX idx_attributes ((CAST(attributes->'$.tags' AS BINARY(32) ARRAY)))"
    end
    return "ALTER TABLE mvi_benchmark ADD " .. def,
           "ALTER TABLE mvi_benchmark DROP INDEX idx_attributes", def
end

-- MySQL and MariaDB: wait, up to timeout seconds, until InnoDB has written
-- out all dirty pages, by setting innodb_max_dirty_pages_pct to 0 for the
-- duration. Otherwise the page cleaner writes out the loaded data during
-- the first runs.
local function flush_innodb(con, timeout)
    local pct = con:query_row("SELECT @@GLOBAL.innodb_max_dirty_pages_pct")
    con:query("SET GLOBAL innodb_max_dirty_pages_pct = 0")
    local dirty
    for _ = 1, timeout do
        local _, value = con:query_row(
            "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_pages_dirty'")
        dirty = tonumber(value)
        if dirty == 0 then
            break
        end
        os.execute("sleep 1")
    end
    con:query("SET GLOBAL innodb_max_dirty_pages_pct = " .. pct)
    if dirty ~= 0 then
        print(string.format("Warning: %d dirty pages left after %d seconds",
                            dirty, timeout))
    end
end

function cmd_prepare()
    check_data_set()
    local drv = sysbench.sql.driver()
    local con = drv:connect()

    local index_type = sysbench.opt.index_type
    local with_array_index = sysbench.opt.array_index ~= "off"
    local _, _, array_index_def = array_index_sql(index_type)
    -- The array index clause of CREATE TABLE (MySQL, MariaDB), if any
    local array_index_clause = ""
    if with_array_index and array_index_def then
        array_index_clause = array_index_def .. ","
    end

    print("Creating tables mvi_benchmark and mvi_vals...")
    con:query("DROP TABLE IF EXISTS mvi_benchmark")
    con:query("DROP TABLE IF EXISTS mvi_vals")

    if index_type == "ft_json" then
        con:query("INSTALL SONAME 'ft_json'")
    end

    -- attr1 and attr2 hold the first and second tags, and created a random
    -- number between 1 and table_size, each with a B-tree index: they are
    -- the controls of the array lookups and the range of with_range.
    local create_table_ft_json = [[
        CREATE TABLE mvi_benchmark (
            id INT AUTO_INCREMENT PRIMARY KEY,
            attributes TEXT,
            attr1 VARCHAR(32),
            attr2 VARCHAR(32),
            created INT,
            %s
            INDEX idx_attr1 (attr1),
            INDEX idx_attr2 (attr2),
            INDEX idx_created (created)
        )
    ]]

    local create_table_array = [[
        CREATE TABLE mvi_benchmark (
            id INT AUTO_INCREMENT PRIMARY KEY,
            attributes JSON,
            attr1 VARCHAR(32),
            attr2 VARCHAR(32),
            created INT,
            %s
            INDEX idx_attr1 (attr1),
            INDEX idx_attr2 (attr2),
            INDEX idx_created (created)
        )
    ]]

    -- MariaDB's multi-valued index only uses the index when the column is
    -- the MEMBER OF argument, so attributes holds the tags array itself.
    local create_table_mariadb_array = [[
        CREATE TABLE mvi_benchmark (
            id INT AUTO_INCREMENT PRIMARY KEY,
            attributes JSON,
            attr1 VARCHAR(32),
            attr2 VARCHAR(32),
            created INT,
            %s
            INDEX idx_attr1 (attr1),
            INDEX idx_attr2 (attr2),
            INDEX idx_created (created)
        )
    ]]

    if index_type == "ft_json" then
        con:query(string.format(create_table_ft_json, array_index_clause))
    elseif index_type == "mariadb_array" then
        con:query(string.format(create_table_mariadb_array, array_index_clause))
    elseif index_type == "pg_gin" then
        -- PostgreSQL: a GIN index on the tags array, the counterpart of the
        -- multi-valued index; indexes are created separately
        con:query([[
            CREATE TABLE mvi_benchmark (
                id SERIAL PRIMARY KEY,
                attributes JSONB,
                attr1 VARCHAR(32),
                attr2 VARCHAR(32),
                created INT
            )
        ]])
        if with_array_index then
            con:query((array_index_sql(index_type)))
        end
        con:query("CREATE INDEX idx_attr1 ON mvi_benchmark (attr1)")
        con:query("CREATE INDEX idx_attr2 ON mvi_benchmark (attr2)")
        con:query("CREATE INDEX idx_created ON mvi_benchmark (created)")
    else
        con:query(string.format(create_table_array, array_index_clause))
    end

    -- The outer table of join and join_attr1: join_groups groups of
    -- join_values distinct tags, drawn uniformly over all tags, so that most
    -- are rare and the cost is in finding the matches.
    con:query([[
        CREATE TABLE mvi_vals (
            grp INT,
            val VARCHAR(32),
            PRIMARY KEY (grp, val)
        )
    ]])
    local domain = tag_domain()
    local draw_any = function() return sysbench.rand.uniform(1, domain) end
    for g = 1, sysbench.opt.join_groups do
        local values = {}
        for _, t in ipairs(distinct_tags(sysbench.opt.join_values, draw_any)) do
            table.insert(values, string.format("(%d, 'value-%d')", g, t))
        end
        con:query("INSERT INTO mvi_vals (grp, val) VALUES " ..
                  table.concat(values, ", "))
    end

    print(string.format("Inserting %d rows (using batches of 1000)...", sysbench.opt.table_size))

    -- Batch inserts for faster data population
    local batch_size = 1000
    for i = 1, sysbench.opt.table_size, batch_size do
        local query = "INSERT INTO mvi_benchmark (attributes, attr1, attr2, created) VALUES "
        local values = {}
        local end_idx = math.min(i + batch_size - 1, sysbench.opt.table_size)

        for j = i, end_idx do
            table.insert(values, "(" .. table.concat({row_values()}, ", ") .. ")")
        end

        query = query .. table.concat(values, ", ")
        con:query(query)
    end
    if sysbench.opt.settle ~= "off" then
        settle_tables(con)
    end
    print("Prepare phase complete.")
    con:disconnect()
end

-- Bring the loaded tables to a steady state, so that the runs don't
-- overlap background work left from loading
function settle_tables(con)
    if sysbench.opt.index_type == "pg_gin" then
        -- PostgreSQL needs statistics to choose the indexes. VACUUM also
        -- merges the GIN pending list, sets hint bits and the visibility
        -- map, and CHECKPOINT writes out the dirty pages, so that neither
        -- autovacuum nor a checkpoint is left to run during the benchmark.
        con:query("VACUUM ANALYZE mvi_benchmark")
        con:query("VACUUM ANALYZE mvi_vals")
        con:query("CHECKPOINT")
    else
        -- The same for MySQL and MariaDB: update the statistics now rather
        -- than in the background during a run, then write out the dirty
        -- pages, including those of the statistics.
        con:query("ANALYZE TABLE mvi_benchmark, mvi_vals")
        flush_innodb(con, 600)
    end
end

function cmd_settle()
    local drv = sysbench.sql.driver()
    local con = drv:connect()
    settle_tables(con)
    con:disconnect()
end

-- Custom commands: drop or create the index named by --index-name (W2).
-- Index creation is timed by the caller.
function cmd_index(create)
    local drv = sysbench.sql.driver()
    local con = drv:connect()
    local index_type = sysbench.opt.index_type
    local create_sql, drop_sql
    if sysbench.opt.index_name == "array" then
        create_sql, drop_sql = array_index_sql(index_type)
    elseif sysbench.opt.index_name == "attr1" then
        create_sql = "CREATE INDEX idx_attr1 ON mvi_benchmark (attr1)"
        drop_sql = "DROP INDEX idx_attr1"
        if index_type ~= "pg_gin" then
            drop_sql = drop_sql .. " ON mvi_benchmark"
        end
    else
        error("--index-name must be array or attr1")
    end
    con:query(create and create_sql or drop_sql)
    con:disconnect()
end

function cmd_cleanup()
    local drv = sysbench.sql.driver()
    local con = drv:connect()

    print("Cleaning up tables mvi_benchmark and mvi_vals...")
    con:query("DROP TABLE IF EXISTS mvi_benchmark")
    con:query("DROP TABLE IF EXISTS mvi_vals")
    con:disconnect()
end

-- The created range of with_range and range_only: range_pct percent of the
-- rows, at a random position.
local function created_range()
    local size = sysbench.opt.table_size
    local width = math.max(1, math.floor(size * sysbench.opt.range_pct / 100))
    local lo = sysbench.rand.uniform(1, math.max(1, size - width + 1))
    return lo, lo + width - 1
end

-- Two distinct tags among the common_values most common ones. In the skewed
-- data set each is in many rows, and both together in few (R3).
local function common_pair()
    local n = math.min(sysbench.opt.common_values, tag_domain())
    local draw = function() return sysbench.rand.uniform(1, n) end
    return distinct_tags(2, draw)
end

-- The array lookups of each --index-type, with tag(s) as their argument:
-- member (one tag) and and2 (all tags of a JSON array). ft_json only has
-- member.
local array_sql = {
    ft_json = {
        member = function(t)
            return string.format(
                "MATCH(attributes) AGAINST ('tags.0=value-%d' IN BOOLEAN MODE)", t)
        end
    },
    mariadb_array = {
        member = function(t)
            return string.format("'value-%d' MEMBER OF(attributes)", t)
        end,
        and2 = function(tags)
            return string.format("JSON_CONTAINS(attributes, '%s')", json_tags(tags))
        end,
        join = "j.val MEMBER OF(t.attributes)"
    },
    pg_gin = {
        member = function(t)
            return string.format("attributes->'tags' @> '[\"value-%d\"]'", t)
        end,
        and2 = function(tags)
            return string.format("attributes->'tags' @> '%s'", json_tags(tags))
        end,
        join = "t.attributes->'tags' @> jsonb_build_array(j.val)"
    },
    array = {
        member = function(t)
            return string.format("'value-%d' MEMBER OF(attributes->'$.tags')", t)
        end,
        and2 = function(tags)
            return string.format("JSON_CONTAINS(attributes->'$.tags', '%s')",
                                 json_tags(tags))
        end,
        join = "j.val MEMBER OF(t.attributes->'$.tags')"
    }
}

-- W3 and W4: one new row, and new tags for a random loaded row
function insert_sql()
    return "INSERT INTO mvi_benchmark (attributes, attr1, attr2, created) " ..
           "VALUES (" .. table.concat({row_values()}, ", ") .. ")"
end

function update_array_sql()
    local attributes, attr1, attr2 = row_values()
    return string.format(
        "UPDATE mvi_benchmark SET attributes = %s, attr1 = %s, attr2 = %s " ..
        "WHERE id = %d", attributes, attr1, attr2,
        sysbench.rand.uniform(1, sysbench.opt.table_size))
end

-- Available lookups, selected with --query-type. Each returns a function
-- that draws the arguments and builds the SQL, or nil if --index-type
-- doesn't support it. They only build the SQL, so the same text can be
-- executed (run), explained (explain) or checked (verify). The *_attr*
-- and range_only lookups are the B-tree controls of the others. They also
-- select attributes, so that like the array lookups they read the row
-- rather than only the index.
local query_types = {
    -- R1 on uniform; R1 and R2 on skewed
    member = function(a)
        return function()
            return "SELECT id FROM mvi_benchmark WHERE " .. a.member(data_tag())
        end
    end,
    attr1 = function()
        return function()
            return string.format(
                "SELECT id, attributes FROM mvi_benchmark WHERE attr1 = 'value-%d'",
                data_tag())
        end
    end,
    -- R3: AND of two common tags
    and2 = function(a)
        if not a.and2 then return nil end
        return function()
            return "SELECT id FROM mvi_benchmark WHERE " .. a.and2(common_pair())
        end
    end,
    and2_attr = function()
        return function()
            local tags = common_pair()
            return string.format(
                "SELECT id, attributes FROM mvi_benchmark WHERE attr1 = 'value-%d' " ..
                "AND attr2 = 'value-%d'", tags[1], tags[2])
        end
    end,
    -- R5: one tag and a range on created
    with_range = function(a)
        return function()
            local lo, hi = created_range()
            return string.format(
                "SELECT id FROM mvi_benchmark WHERE %s AND created BETWEEN %d AND %d",
                a.member(data_tag()), lo, hi)
        end
    end,
    range_only = function()
        return function()
            local lo, hi = created_range()
            return string.format(
                "SELECT id, attributes FROM mvi_benchmark " ..
                "WHERE created BETWEEN %d AND %d", lo, hi)
        end
    end,
    -- R6: join on membership, join_values outer rows per query
    join = function(a)
        if not a.join then return nil end
        return function()
            return string.format(
                "SELECT t.id FROM mvi_vals j JOIN mvi_benchmark t ON %s " ..
                "WHERE j.grp = %d", a.join,
                sysbench.rand.uniform(1, sysbench.opt.join_groups))
        end
    end,
    join_attr1 = function()
        return function()
            return string.format(
                "SELECT t.id, t.attributes FROM mvi_vals j JOIN mvi_benchmark t " ..
                "ON t.attr1 = j.val WHERE j.grp = %d",
                sysbench.rand.uniform(1, sysbench.opt.join_groups))
        end
    end,
    -- W3: insert one new row, drawn like the loaded ones
    insert = function()
        return insert_sql
    end,
    -- W4: replace the tags of a random loaded row with newly drawn ones
    update_array = function()
        return update_array_sql
    end,
    -- M2: 50% member lookups, 25% inserts, 25% array updates
    write_heavy = function(a)
        return function()
            local r = sysbench.rand.uniform(1, 4)
            if r <= 2 then
                return "SELECT id FROM mvi_benchmark WHERE " .. a.member(data_tag())
            elseif r == 3 then
                return insert_sql()
            end
            return update_array_sql()
        end
    end
}

-- Resolve --index-type/--query-type into one SQL builder, so a typo fails at
-- startup rather than running the wrong benchmark to completion. Shared by
-- thread_init() and the explain and verify commands.
local function resolve_query()
    check_data_set()
    local index_type = sysbench.opt.index_type
    local a = array_sql[index_type]
    if not a then
       error("The argument --index-type must be set")
    end

    local query_type = sysbench.opt.query_type
    local make = query_types[query_type]
    if not make then
        error(string.format("unknown --query-type '%s' (expected: member, " ..
                            "attr1, and2, and2_attr, with_range, range_only, " ..
                            "join, join_attr1, insert, update_array, " ..
                            "write_heavy)", query_type))
    end
    local builder = make(a)
    if not builder then
        error(string.format("--query-type '%s' is not supported with " ..
                            "--index-type '%s'", query_type, index_type))
    end
    return builder, query_type
end

-- Custom command: show the plan for one instance of the benchmarked lookup.
-- Runs standalone, so thread_init() is not called and it connects itself.
function cmd_explain()
    local drv = sysbench.sql.driver()
    local con = drv:connect()

    local build_sql, query_type = resolve_query()
    local query = build_sql()

    print(string.format("index-type: %s, query-type: %s, data-set: %s",
                        sysbench.opt.index_type, query_type,
                        sysbench.opt.data_set))
    print(query)

    -- EXPLAIN FORMAT=JSON returns a single row with a single column, so
    -- query_row() gives us the whole plan as one string.
    local explain = "EXPLAIN FORMAT=JSON "
    if sysbench.opt.index_type == "pg_gin" then
        explain = "EXPLAIN (FORMAT JSON) "
    end
    local plan = con:query_row(explain .. query)
    print(plan or "(no plan returned)")

    con:disconnect()
end

-- Custom command: run --verify-count instances of the lookup and print the
-- number and the sum of the matched ids, per query and in total. With the
-- same --rand-seed for prepare and verify, the output must be the same on
-- every server.
function cmd_verify()
    local drv = sysbench.sql.driver()
    local con = drv:connect()

    local build_sql, query_type = resolve_query()
    print(string.format("verify query-type: %s, data-set: %s",
                        query_type, sysbench.opt.data_set))

    local total_rows, total_sum = 0, 0
    for i = 1, sysbench.opt.verify_count do
        local query = build_sql()
        local rs = con:query(query)
        local rows, sum = 0, 0
        for _ = 1, rs.nrows do
            local row = rs:fetch_row()
            rows = rows + 1
            sum = sum + tonumber(row[1])
        end
        -- No SQL text here: it differs between servers, the output mustn't
        print(string.format("%d %d %.0f", i, rows, sum))
        total_rows = total_rows + rows
        total_sum = total_sum + sum
    end
    print(string.format("total %d %.0f", total_rows, total_sum))

    con:disconnect()
end

local run_query

function thread_init()
    local build_sql = resolve_query()

    drv = sysbench.sql.driver()
    con = drv:connect()

    run_query = function() con:query(build_sql()) end
end

function event()
    run_query()
end

function thread_done()
    con:disconnect()
end
