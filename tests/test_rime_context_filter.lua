-- test_rime_context_filter.lua
-- 纯 Lua 单元测试（零外部依赖）
-- 运行: lua tests/test_rime_context_filter.lua

local testdir = (arg[0] or ""):match("^(.*)[/\\]") or "."
local lua_file = testdir .. "/../lua/rime_context_filter.lua"
local mod, err_msg = loadfile(lua_file)
if not mod then
  io.stderr:write("FATAL: Could not load " .. lua_file .. ": " .. tostring(err_msg) .. "\n")
  os.exit(1)
end
local ok, rcf = pcall(mod)
if not ok then
  io.stderr:write("FATAL: rime_context_filter.lua threw: " .. tostring(rcf) .. "\n")
  os.exit(1)
end

local utf8_last          = rcf.utf8_last
local utf8_char_count    = rcf.utf8_char_count
local has_cjk_ideograph  = rcf.has_cjk_ideograph
local is_learnable       = rcf.is_learnable
local is_stop_key        = rcf.is_stop_key
local is_context_breaker = rcf.is_context_breaker
local serialize          = rcf.serialize
local load_data          = rcf.load_data
local save               = rcf.save
local decay_learned      = rcf.decay_learned
local apply_time_decay   = rcf.apply_time_decay
local score_candidates   = rcf.score_candidates
local reorder_batch      = rcf.reorder_batch
local bigram_pair_score  = rcf.bigram_pair_score
local on_token           = rcf.on_token
local on_select          = rcf.on_select
local on_commit          = rcf.on_commit
local on_cancel          = rcf.on_cancel
local on_composition_update = rcf.on_composition_update
local revert_last_select = rcf.revert_last_select
local sync_pending       = rcf.sync_pending
local do_save            = rcf.do_save
local resolve_data_path  = rcf.resolve_data_path
local rebuild_totals     = rcf.rebuild_totals
local prune_store        = rcf.prune_store
local init               = rcf.init
local filter             = rcf.func
local reset_store        = rcf.reset_store_for_tests
local FORMAT_VERSION     = rcf.FORMAT_VERSION
local PROMOTE_SCORE      = rcf.PROMOTE_SCORE

----------------------------------------------------------------------
-- Assertion helpers
----------------------------------------------------------------------

local total, passed, failed = 0, 0, 0

local function check(cond, msg)
  total = total + 1
  if cond then passed = passed + 1; return end
  failed = failed + 1
  io.write("  FAIL: " .. (msg or "check") .. "\n")
end

local function eq(got, expected, msg)
  total = total + 1
  if got == expected then passed = passed + 1; return end
  failed = failed + 1
  io.write("  FAIL: " .. (msg or "eq") .. "\n")
  io.write("    expected: " .. tostring(expected) .. "\n")
  io.write("    got:      " .. tostring(got) .. "\n")
end

local function near(got, expected, epsilon, msg)
  total = total + 1
  if math.abs((got or 0) - expected) < (epsilon or 0.001) then passed = passed + 1; return end
  failed = failed + 1
  io.write("  FAIL: " .. (msg or "near") .. "\n")
  io.write("    expected ≈ " .. tostring(expected) .. "\n")
  io.write("    got:       " .. tostring(got) .. "\n")
end

local function cand(text, opts)
  opts = opts or {}
  return {
    text = text,
    type = opts.type,
    comment = opts.comment,
    start = opts.start,
    _end = opts._end,
    quality = opts.quality or 0,
  }
end

local function cands(texts)
  local c = {}
  for i, t in ipairs(texts) do c[i] = cand(t) end
  return c
end

local function new_env(opts)
  opts = opts or {}
  local store = {
    file = opts.data_file,
    learned = {},
    totals = {},
    meta = { version = FORMAT_VERSION, decay_at = opts.decay_at },
    dirty = false,
    dirty_commits = 0,
    load_ok = true,
    corrupt = false,
    refs = 1,
    save_failures = 0,
  }
  return {
    store = store,
    learned = store.learned,
    window = {},
    commit_count = 0,
    save_interval = 1000,
    decay_enabled = false,
    decay_rate = 0.95,
    decay_period = 86400,
    decay_at = opts.decay_at,
    data_file = opts.data_file,
    _selected = false,
    _committed = false,
    pending_tokens = {},
    pending_marks = {},
    scores = {},
    max_successors = 48,
    max_contexts = 4000,
    promote_min_count = 2,
    max_promote = 5,
    protect_prefix = 0,
    idle_timeout_sec = 120,
    last_activity = os.time(),
  }
end

local function learn_n(env, prev, cur, n)
  env.window = { prev }
  for _ = 1, n do
    on_token(env, cur)
    env.window = { prev }
  end
  env.window = { prev }
end

----------------------------------------------------------------------
-- 1. utf8 helpers
----------------------------------------------------------------------

io.write("=== utf8 helpers ===\n")
eq(utf8_last("任务", 1), "务")
eq(utf8_char_count("任务"), 2)
check(has_cjk_ideograph("任务"), "任务 is CJK")
check(not has_cjk_ideograph("hello"), "hello is not CJK")
check(not has_cjk_ideograph("。"), "ideographic stop is not ideograph")
io.write("  passed\n")

----------------------------------------------------------------------
-- 1c. is_learnable / breakers
----------------------------------------------------------------------

io.write("=== is_learnable / context breakers ===\n")
check(is_learnable("任务"), "word")
check(not is_learnable("的"), "stopword")
check(not is_learnable("hello"), "ascii")
check(not is_learnable("。"), "punct")
check(not is_learnable("你好。"), "word+punct")
check(is_context_breaker("。"), "breaker punct")
check(is_context_breaker("hello"), "breaker ascii")
check(is_context_breaker("接下来的任务是完成报告"), "breaker too long")
check(not is_context_breaker("任务"), "word not breaker")
check(is_stop_key("的"))
io.write("  passed\n")

----------------------------------------------------------------------
-- 2. serialize keeps count == 1
----------------------------------------------------------------------

io.write("=== serialize keeps single observations ===\n")
do
  local data = { ["完成"] = { ["任务"] = 1, ["工作"] = 2 } }
  local ser = serialize(data, { version = 7, decay_at = 42 })
  check(ser:match("version=7"), "has version")
  local fn = (_VERSION == "Lua 5.1") and loadstring(ser) or load(ser)
  check(fn ~= nil, "valid lua")
  local loaded = fn()
  eq(loaded.data["完成"]["任务"], 1, "count=1 persisted")
  eq(loaded.data["完成"]["工作"], 2)
  eq(loaded._meta.version, 7)
end
io.write("  passed\n")

----------------------------------------------------------------------
-- 3. decay
----------------------------------------------------------------------

io.write("=== decay ===\n")
do
  local d = { ["前文"] = { ["高频词"] = 50, ["将消亡"] = 1 } }
  decay_learned(d, 0.95)
  near(d["前文"]["高频词"], 47.5, 0.01)
  eq(d["前文"]["将消亡"], nil, "count 1 * 0.95 < 1.1 pruned by decay")
end
do
  local d = { ["前文"] = { ["词"] = 10 } }
  local now = 1e9
  local at = apply_time_decay(d, 0.95, now - 86400 * 2, now, 86400)
  near(d["前文"]["词"], 10 * 0.95 * 0.95, 0.01)
  eq(at, now)
end
io.write("  passed\n")

----------------------------------------------------------------------
-- 4. bigram scoring (no suffix / concat fake higher-order)
----------------------------------------------------------------------

io.write("=== bigram score / low confidence ===\n")
do
  -- count=1 < promote_min → 0
  near(bigram_pair_score(1, 1, 2), 0, 0.0001, "single obs no promote score")
  local s2 = bigram_pair_score(2, 2, 2)
  check(s2 > PROMOTE_SCORE, "two obs of same pair can promote")
  local s_diluted = bigram_pair_score(2, 100, 2)
  check(s_diluted < PROMOTE_SCORE, "rare pair in busy context stays low")
end

do
  local s = {}
  local learned = { ["接下来的"] = { ["任务"] = 5, ["工作"] = 3 } }
  local totals = rebuild_totals(learned)
  score_candidates(cands{"任务", "人物", "工作"}, {"接下来的"}, learned, totals, s, {
    promote_min_count = 2,
  })
  check((s["任务"] or 0) > (s["工作"] or 0), "higher count ranks higher")
  eq(s["人物"], nil, "unseen no score")
end

do
  -- 不再使用后缀「的」或拼接 key
  local s = {}
  score_candidates(cands{"朋友"}, {"好的"}, {
    ["的"] = { ["朋友"] = 8 },
    ["好的"] = {},
  }, { ["的"] = 8 }, s, { promote_min_count = 2 })
  eq(s["朋友"], nil, "no suffix backoff")
end

do
  local s = {}
  score_candidates(cands{"任务"}, {}, {}, {}, s, {})
  eq(s["任务"], nil, "empty window")
end
io.write("  passed\n")

----------------------------------------------------------------------
-- 5. reorder: stable, span-separated, protected, dedupe text
----------------------------------------------------------------------

io.write("=== reorder_batch ===\n")
do
  local batch = cands{"人物", "任务", "工作", "任命"}
  local scores = { ["任务"] = 0.5, ["工作"] = 0.3 }
  local out, changed = reorder_batch(batch, scores, PROMOTE_SCORE, { max_promote = 5 })
  check(changed, "reordered")
  eq(out[1].text, "任务")
  eq(out[2].text, "工作")
  eq(out[3].text, "人物")
  eq(out[4].text, "任命")
end

do
  local batch = cands{"人物", "任务"}
  local out, changed = reorder_batch(batch, { ["任务"] = 0.05 }, PROMOTE_SCORE)
  check(not changed, "below threshold")
  eq(out[1].text, "人物")
end

do
  -- 不同 span 不混排
  local batch = {
    cand("甲", { start = 0, _end = 2 }),
    cand("乙", { start = 0, _end = 2 }),
    cand("丙", { start = 2, _end = 4 }),
    cand("丁", { start = 2, _end = 4 }),
  }
  local scores = { ["乙"] = 0.9, ["丁"] = 0.8 }
  local out = reorder_batch(batch, scores, PROMOTE_SCORE)
  eq(out[1].text, "乙", "span0 promoted")
  eq(out[2].text, "甲")
  eq(out[3].text, "丁", "span1 promoted separately")
  eq(out[4].text, "丙")
end

do
  local batch = {
    cand("置顶", { comment = "★" }),
    cand("人物"),
    cand("任务"),
  }
  local out = reorder_batch(batch, { ["任务"] = 0.9 }, PROMOTE_SCORE, { protect_prefix = 0 })
  eq(out[1].text, "置顶", "protected stays first")
  eq(out[2].text, "任务")
  eq(out[3].text, "人物")
end

do
  -- 同文字重复候选：只提权第一次出现对应的对象身份
  local a = cand("任务")
  local b = cand("任务")
  local c = cand("人物")
  local batch = { c, a, b }
  local out = reorder_batch(batch, { ["任务"] = 0.9 }, PROMOTE_SCORE)
  check(out[1] == a, "first 任务 object promoted, identity kept")
  check(out[2] == c or out[3] == b, "others present")
  local task_count = 0
  for _, x in ipairs(out) do if x.text == "任务" then task_count = task_count + 1 end end
  eq(task_count, 2, "both 任务 objects still yielded")
end

do
  local batch = cands{"a", "b", "c", "d", "e", "f"}
  local scores = { b = 0.9, c = 0.8, d = 0.7, e = 0.6 }
  local out = reorder_batch(batch, scores, PROMOTE_SCORE, { max_promote = 2 })
  eq(out[1].text, "b")
  eq(out[2].text, "c")
  eq(out[3].text, "a")
end
io.write("  passed\n")

----------------------------------------------------------------------
-- 6. load/save: count=1 roundtrip, corrupt, atomic failure
----------------------------------------------------------------------

io.write("=== load_data / save ===\n")
do
  local tmp = os.tmpname()
  local sample = { ["完成"] = { ["任务"] = 1 } }
  check(save(sample, tmp, { version = 7, decay_at = 42 }), "save count=1")
  local loaded, meta, ok_load = load_data(tmp)
  check(ok_load, "load ok")
  eq(loaded["完成"]["任务"], 1, "reload keeps single obs")
  eq(meta.version, 7)
  os.remove(tmp)
  pcall(function() os.remove(tmp .. ".bak") end)
end

do
  local old = os.tmpname()
  local of = io.open(old, "w")
  of:write('return {["完成"]={["任务"]=5}}\n')
  of:close()
  local loaded, meta, ok_load = load_data(old)
  check(ok_load)
  eq(loaded["完成"]["任务"], 5, "legacy flat")
  eq(meta.version, 5)
  os.remove(old)
end

do
  local bad = os.tmpname()
  local bf = io.open(bad, "w")
  bf:write("not valid lua!!!")
  bf:close()
  local data, _, ok_load = load_data(bad)
  check(not ok_load, "corrupt => ok=false")
  check(next(data) == nil, "corrupt => empty memory")
  -- 不得用空表覆盖：模拟 do_save 在 corrupt 且无 dirty 时
  local env = new_env({ data_file = bad })
  env.store.corrupt = true
  env.store.dirty = false
  env.store.file = bad
  local sok, serr = do_save(env)
  check(not sok, "refuse overwrite corrupt")
  local still = io.open(bad, "r")
  local content = still:read("*a")
  still:close()
  check(content:find("not valid", 1, true), "original corrupt file kept")
  os.remove(bad)
end

do
  -- 写入非法路径应失败且不声称成功
  local sok = save({ ["a"] = { ["b"] = 1 } }, "", {})
  check(not sok, "empty path fails")
end

do
  -- 主文件缺失时从 .bak 恢复，不得当成空库
  local base = os.tmpname()
  os.remove(base)
  local bak = base .. ".bak"
  check(save({ ["完成"] = { ["任务"] = 3 } }, bak, { version = 7, decay_at = 1 }), "write bak")
  local loaded, _, ok_load = load_data(base)
  check(ok_load, "bak recovery ok")
  eq(loaded["完成"]["任务"], 3, "recovered from bak")
  os.remove(bak)
end

do
  -- 损坏 + 新学习 → 旁路 .recovered，主文件不动
  local bad = os.tmpname()
  local bf = io.open(bad, "w")
  bf:write("CORRUPT!!!")
  bf:close()
  local env = new_env({ data_file = bad })
  env.store.file = bad
  env.store.corrupt = true
  env.store.dirty = true
  env.store.learned["完成"] = { ["任务"] = 2 }
  env.store.totals = rebuild_totals(env.store.learned)
  local sok = do_save(env)
  check(sok, "recovered side save")
  local main = io.open(bad, "r")
  local mc = main:read("*a")
  main:close()
  check(mc:find("CORRUPT", 1, true), "corrupt main preserved")
  local side = bad .. ".recovered"
  local loaded = load_data(side)
  eq(loaded["完成"]["任务"], 2, "new learning in recovered")
  os.remove(bad)
  os.remove(side)
  pcall(function() os.remove(side .. ".bak") end)
end
io.write("  passed\n")

----------------------------------------------------------------------
-- 7. learning flows
----------------------------------------------------------------------

io.write("=== learning flows ===\n")
do
  local env = new_env()
  on_select(env, "接下来的")
  on_select(env, "任务")
  check(next(env.learned) == nil, "deferred until commit")
  on_commit(env, "接下来的任务")
  eq(env.learned["接下来的"]["任务"], 1, "pair learned once")
  eq(env.window[1], "任务")
end

do
  local env = new_env()
  on_select(env, "完成")
  on_select(env, "的")
  on_select(env, "任务")
  on_commit(env, "完成的任务")
  eq(env.learned["完成"]["任务"], 1, "stopword skipped, adjacent learnables paired")
  eq(env.learned["的"], nil)
end

do
  local env = new_env()
  on_select(env, "完成")
  on_select(env, "任务")
  on_cancel(env)
  check(next(env.learned) == nil, "Esc no learn")
end

do
  local env = new_env()
  on_commit(env, "完成")
  on_commit(env, "任务")
  eq(env.learned["完成"]["任务"], 1, "direct commit learns")
end

do
  local env = new_env()
  on_commit(env, "完成")
  on_commit(env, "。")
  on_commit(env, "任务")
  eq(env.learned["完成"], nil, "punct breaks adjacency")
  eq(env.learned["任务"], nil)
end

do
  local env = new_env()
  on_select(env, "完成")
  on_commit(env, "。")
  eq(#env.window, 0, "punct in commit text clears window")
end

do
  local env = new_env()
  on_select(env, "接下来的")
  on_select(env, "任务")
  revert_last_select(env)
  on_commit(env, "接下来的")
  eq(env.learned["接下来的"], nil, "reverted segment not paired")
end

do
  local env = new_env()
  on_select(env, "完成")
  on_select(env, "任务")
  on_commit(env, "完成任务")
  on_composition_update(env, false)
  eq(env.learned["完成"]["任务"], 1, "post-commit update no rollback")
end

do
  local env = new_env()
  on_select(env, "完成")
  on_select(env, "任务")
  on_composition_update(env, false)
  check(next(env.learned) == nil, "Esc via update")
end

do
  -- 空闲超时断开（用墙上时间字段，不用 os.clock）
  local env = new_env()
  env.idle_timeout_sec = 10
  env.window = { "完成" }
  env.last_activity = os.time() - 30
  on_token(env, "任务")
  -- idle reset cleared window before learn → no pair
  eq(env.learned["完成"], nil, "idle timeout breaks")
  eq(env.window[1], "任务", "new token becomes sole context")
end

do
  -- 超时不得丢掉本段已 select、即将 commit 的词对
  local env = new_env()
  env.idle_timeout_sec = 10
  on_select(env, "完成")
  on_select(env, "任务")
  env.last_activity = os.time() - 30
  on_commit(env, "完成任务")
  eq(env.learned["完成"]["任务"], 1, "idle before commit still flushes pending")
end
io.write("  passed\n")

----------------------------------------------------------------------
-- 8. save roundtrip after one learn; do_save decay
----------------------------------------------------------------------

io.write("=== persist single learn across reload ===\n")
do
  local tmp = os.tmpname()
  local env = new_env({ data_file = tmp })
  env.store.file = tmp
  on_commit(env, "完成")
  on_commit(env, "任务")
  eq(env.learned["完成"]["任务"], 1)
  env.store.dirty = true
  check(do_save(env), "save")
  local loaded = load_data(tmp)
  eq(loaded["完成"]["任务"], 1, "survives reload")
  os.remove(tmp)
  pcall(function() os.remove(tmp .. ".bak") end)
end

do
  local tmp = os.tmpname()
  local env = new_env({ data_file = tmp })
  env.store.file = tmp
  env.store.learned["前文"] = { ["词"] = 10 }
  env.store.totals = rebuild_totals(env.store.learned)
  env.learned = env.store.learned
  env.decay_enabled = true
  env.store.meta.decay_at = os.time() - 86400
  env.store.dirty = true
  do_save(env)
  local reloaded = load_data(tmp)
  near(reloaded["前文"]["词"], 9.5, 0.01)
  os.remove(tmp)
  pcall(function() os.remove(tmp .. ".bak") end)
end
io.write("  passed\n")

----------------------------------------------------------------------
-- 9. multi-instance share / no clobber
----------------------------------------------------------------------

io.write("=== multi-instance shared store ===\n")
do
  reset_store()
  local tmp = os.tmpname()
  os.remove(tmp)

  local function make_init_env(path)
    local groups = {}
    local function notifier(name)
      return {
        connect = function(_, _, group)
          groups[name] = group
          return { disconnect = function() end }
        end,
      }
    end
    local config = {
      get_string = function(_, key)
        if key:match("/data_path$") then return path end
        return nil
      end,
      get_int = function() return nil end,
      get_bool = function() return nil end,
      get_double = function() return nil end,
    }
    return {
      name_space = "*rime_context_filter",
      engine = {
        schema = { config = config },
        context = {
          select_notifier = notifier("select"),
          commit_notifier = notifier("commit"),
          update_notifier = notifier("update"),
        },
      },
    }, groups
  end

  local env1 = make_init_env(tmp)
  init(env1)
  local env2 = make_init_env(tmp)
  init(env2)
  check(env1.store == env2.store, "shared module store")

  env1.window = { "完成" }
  on_token(env1, "任务")
  eq(env2.store.learned["完成"]["任务"], 1, "instance2 sees instance1 learning")

  env2.window = { "完成" }
  on_token(env2, "工作")
  env1.store.dirty = true
  check(do_save(env1), "save from env1")
  local loaded = load_data(tmp)
  eq(loaded["完成"]["任务"], 1, "both pairs kept")
  eq(loaded["完成"]["工作"], 1)

  rcf.fini(env1)
  rcf.fini(env2)
  reset_store()
  os.remove(tmp)
  pcall(function() os.remove(tmp .. ".bak") end)
end
io.write("  passed\n")

----------------------------------------------------------------------
-- 10. capacity prune
----------------------------------------------------------------------

io.write("=== capacity prune ===\n")
do
  local learned, totals = {}, {}
  for i = 1, 20 do
    local ctx = "前文" .. tostring(i)
    learned[ctx] = { ["词"] = (i == 20) and 100 or 1 }
    totals[ctx] = (i == 20) and 100 or 1
  end
  prune_store(learned, totals, 5, 48)
  local n = 0
  for _ in pairs(learned) do n = n + 1 end
  eq(n, 5, "max contexts enforced")
  check(learned["前文20"] ~= nil, "highest total kept")
end
do
  local learned = { ["前文"] = {} }
  for i = 1, 30 do
    learned["前文"]["词" .. i] = i
  end
  local totals = rebuild_totals(learned)
  prune_store(learned, totals, 100, 10)
  local n = 0
  for _ in pairs(learned["前文"]) do n = n + 1 end
  eq(n, 10, "max successors enforced")
  check(learned["前文"]["词30"] ~= nil, "hottest successor kept")
  local sum = 0
  for _, c in pairs(learned["前文"]) do sum = sum + c end
  eq(totals["前文"], sum, "totals matches remaining successors")
end
do
  -- learn_pair 触发 successor prune 后 totals 仍一致
  local env = new_env()
  env.max_successors = 3
  env.window = { "前文" }
  for i = 1, 5 do
    on_token(env, "词" .. i)
    env.window = { "前文" }
  end
  local n = 0
  local sum = 0
  for _, c in pairs(env.store.learned["前文"]) do
    n = n + 1
    sum = sum + c
  end
  eq(n, 3, "learn_pair respects max_successors")
  eq(env.store.totals["前文"], sum, "totals after learn_pair prune")
end
io.write("  passed\n")

----------------------------------------------------------------------
-- 11. filter: identity, early pass-through, low confidence
----------------------------------------------------------------------

io.write("=== filter behavior ===\n")
do
  local a = cand("人物")
  local b = cand("任务")
  local input = {
    iter = function()
      local values = { a, b }
      local i = 0
      return function()
        i = i + 1
        return values[i]
      end, nil, nil
    end,
  }
  local env = new_env()
  env.window = { "完成" }
  env.store.learned["完成"] = { ["任务"] = 1 }  -- 低置信度
  env.store.totals["完成"] = 1
  env.learned = env.store.learned
  local out = {}
  local old_yield = _G.yield
  _G.yield = function(c) out[#out + 1] = c end
  filter(input, env)
  _G.yield = old_yield
  check(out[1] == a and out[2] == b, "low confidence keeps objects+order")
end

do
  local a = cand("人物")
  local b = cand("任务")
  local input = {
    iter = function()
      local values = { a, b }
      local i = 0
      return function()
        i = i + 1
        return values[i]
      end, nil, nil
    end,
  }
  local env = new_env()
  env.window = { "完成" }
  env.store.learned["完成"] = { ["任务"] = 5 }
  env.store.totals["完成"] = 5
  env.learned = env.store.learned
  local out = {}
  local old_yield = _G.yield
  _G.yield = function(c) out[#out + 1] = c end
  filter(input, env)
  _G.yield = old_yield
  check(out[1] == b, "promoted original object")
  check(out[2] == a, "other original object")
end

do
  local input = {
    iter = function()
      local values = cands{"人物", "任务"}
      local i = 0
      return function()
        i = i + 1
        return values[i]
      end, nil, nil
    end,
  }
  local out = {}
  local old_yield = _G.yield
  _G.yield = function(c) out[#out + 1] = c end
  filter(input, { reorder_limit = 0, window = {}, store = { learned = {} }, scores = {} })
  _G.yield = old_yield
  eq(#out, 2, "limit 0 passthrough")
end

do
  reset_store()
  local tmp = os.tmpname()
  os.remove(tmp)
  local groups = {}
  local function notifier(name)
    return {
      connect = function(_, _, group)
        groups[name] = group
        return { disconnect = function() end }
      end,
    }
  end
  local config = {
    get_string = function(_, key)
      if key:match("/data_path$") then return tmp end
      return nil
    end,
    get_int = function() return nil end,
    get_bool = function() return nil end,
    get_double = function() return nil end,
  }
  local env = {
    name_space = "*rime_context_filter",
    engine = {
      schema = { config = config },
      context = {
        select_notifier = notifier("select"),
        commit_notifier = notifier("commit"),
        update_notifier = notifier("update"),
      },
    },
  }
  init(env)
  eq(groups.select, 0, "select group 0")
  rcf.fini(env)
  reset_store()
  pcall(function() os.remove(tmp) end)
end
io.write("  passed\n")

----------------------------------------------------------------------
-- 12. resolve_data_path
----------------------------------------------------------------------

io.write("=== resolve_data_path ===\n")
eq(resolve_data_path("/custom/x.data", "/user"), "/custom/x.data")
local sep = package.config:sub(1, 1)
eq(resolve_data_path("", "/home/u/rime"), "/home/u/rime" .. sep .. "context_learned.data")
eq(resolve_data_path(nil, "/home/u/rime/"), "/home/u/rime/context_learned.data")
io.write("  passed\n")

----------------------------------------------------------------------
-- 13. performance smoke
----------------------------------------------------------------------

io.write("=== performance smoke ===\n")
do
  local env = new_env()
  -- 构造中等规模：800 前文 × 20 后继
  for i = 1, 800 do
    local ctx = "词" .. tostring(i)
    env.store.learned[ctx] = {}
    for j = 1, 20 do
      env.store.learned[ctx]["后" .. tostring(j)] = (j % 5) + 1
    end
  end
  env.store.totals = rebuild_totals(env.store.learned)
  env.window = { "词1" }
  local batch = {}
  for i = 1, 80 do batch[i] = cand("后" .. tostring((i % 20) + 1)) end
  local t0 = os.clock()
  for _ = 1, 500 do
    score_candidates(batch, env.window, env.store.learned, env.store.totals, env.scores, {
      promote_min_count = 2,
    })
    reorder_batch(batch, env.scores, PROMOTE_SCORE, { max_promote = 5 })
  end
  local dt = os.clock() - t0
  io.write(string.format("  score+reorder 500x80 over 800x20 store: %.4fs\n", dt))
  check(dt < 2.0, "hot path under 2s for 500 iterations")

  local tmp = os.tmpname()
  env.store.file = tmp
  env.data_file = tmp
  env.store.dirty = true
  local t1 = os.clock()
  local sok = do_save(env)
  local dts = os.clock() - t1
  check(sok, "save large ok")
  io.write(string.format("  save ~%d contexts: %.4fs\n", 800, dts))
  check(dts < 5.0, "save under 5s")
  os.remove(tmp)
  pcall(function() os.remove(tmp .. ".bak") end)
end
io.write("  passed\n")

----------------------------------------------------------------------
-- Results
----------------------------------------------------------------------

io.write("\n" .. string.rep("=", 40) .. "\n")
io.write("RESULTS: " .. total .. " tests, " .. passed .. " passed, " .. failed .. " failed\n")
io.write(string.rep("=", 40) .. "\n")

if failed > 0 then os.exit(1) end
