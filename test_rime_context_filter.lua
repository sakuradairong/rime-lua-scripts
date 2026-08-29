-- test_rime_context_filter.lua
-- 纯 Lua 单元测试（零外部依赖）
-- 运行: lua test_rime_context_filter.lua

local mod, err_msg = loadfile("rime_context_filter.lua")
if not mod then
  io.stderr:write("FATAL: Could not load rime_context_filter.lua: " .. tostring(err_msg) .. "\n")
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
local serialize          = rcf.serialize
local load_data          = rcf.load_data
local save               = rcf.save
local decay_learned      = rcf.decay_learned
local apply_time_decay   = rcf.apply_time_decay
local score_candidates   = rcf.score_candidates
local reorder_batch      = rcf.reorder_batch
local on_token           = rcf.on_token
local on_select          = rcf.on_select
local on_commit          = rcf.on_commit
local on_cancel          = rcf.on_cancel
local on_composition_update = rcf.on_composition_update
local revert_last_select = rcf.revert_last_select
local sync_pending       = rcf.sync_pending
local do_save            = rcf.do_save
local resolve_data_path  = rcf.resolve_data_path

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
  if math.abs(got - expected) < (epsilon or 0.001) then passed = passed + 1; return end
  failed = failed + 1
  io.write("  FAIL: " .. (msg or "near") .. "\n")
  io.write("    expected ≈ " .. tostring(expected) .. "\n")
  io.write("    got:       " .. tostring(got) .. "\n")
end

local function cand(text) return { text = text } end
local function cands(texts) local c = {} for i, t in ipairs(texts) do c[i] = cand(t) end return c end

local function new_env()
  return {
    learned = {},
    window = {},
    commit_count = 0,
    save_interval = 1000,
    decay_enabled = false,
    decay_rate = 0.95,
    decay_period = 86400,
    _selected = false,
    _committed = false,
    pending_tokens = {},
    pending_marks = {},
    scores = {},
  }
end

----------------------------------------------------------------------
-- 1. utf8_last
----------------------------------------------------------------------

io.write("=== utf8_last ===\n")
eq(utf8_last("hello", 2), "lo")
eq(utf8_last("hello", 1), "o")
eq(utf8_last("hello", 10), "hello")
eq(utf8_last("", 1), "")
eq(utf8_last("任务", 1), "务")
eq(utf8_last("任务", 2), "任务")
eq(utf8_last("接下来的任务", 2), "任务")
eq(utf8_last("接下来的任务", 1), "务")
eq(utf8_last("接下来的", 2), "来的")
eq(utf8_last("接下来的", 1), "的")
eq(utf8_last("任务abc", 2), "bc")
eq(utf8_last("任务abc", 4), "务abc")
io.write("  passed\n")

----------------------------------------------------------------------
-- 1b. utf8_char_count / has_cjk
----------------------------------------------------------------------

io.write("=== utf8_char_count / has_cjk ===\n")
eq(utf8_char_count(""), 0)
eq(utf8_char_count("a"), 1)
eq(utf8_char_count("hello"), 5)
eq(utf8_char_count("任务"), 2)
eq(utf8_char_count("任务abc"), 5)
eq(utf8_char_count("接下来的"), 4)
check(has_cjk_ideograph("任务"), "任务 is CJK")
check(not has_cjk_ideograph("hello"), "hello is not CJK")
check(not has_cjk_ideograph("。"), "ideographic stop is not ideograph")
check(not has_cjk_ideograph(""), "empty")
io.write("  passed\n")

----------------------------------------------------------------------
-- 1c. is_learnable
----------------------------------------------------------------------

io.write("=== is_learnable ===\n")
check(is_learnable("任务"), "word")
check(is_learnable("接下来的"), "phrase 4 chars")
check(not is_learnable("的"), "stopword 的")
check(not is_learnable("了"), "stopword 了")
check(not is_learnable("hello"), "ascii")
check(not is_learnable("。"), "punct")
check(not is_learnable(""), "empty")
check(not is_learnable("接下来的任务是完成报告"), "too long sentence")
check(is_stop_key("的"))
check(not is_stop_key("任务"))
io.write("  passed\n")

----------------------------------------------------------------------
-- 2. serialize 格式
----------------------------------------------------------------------

io.write("=== serialize ===\n")

local data = {
  ["接下来的"] = { ["任务"] = 8, ["工作"] = 3 },
  ["完成"]     = { ["任务"] = 5 },
  ["那个"]     = { ["人物"] = 4 },
}
local ser = serialize(data, { decay_at = 1700000000 })
check(type(ser) == "string", "is string")
check(ser:match("^return%s*{"), "starts with return {")
check(ser:match("_meta="), "has _meta")
check(ser:match("data="), "has data")
check(ser:match("}\n$"), "ends with }\\n")

local fn, err
if _VERSION == "Lua 5.1" then
  fn, err = loadstring(ser)
else
  fn, err = load(ser)
end
check(fn ~= nil, "serialized output is valid Lua (" .. tostring(err) .. ")")
if fn then
  local ok2, loaded = pcall(fn)
  check(ok2, "executable")
  if ok2 then
    eq(loaded.data["接下来的"]["任务"], 8)
    eq(loaded.data["完成"]["任务"], 5)
    eq(loaded._meta.decay_at, 1700000000)
  end
end

local empty_ser = serialize({}, { decay_at = 1 })
check(empty_ser:match("^return {"), "empty starts with return {")
local fn2, err2
if _VERSION == "Lua 5.1" then
  fn2, err2 = loadstring(empty_ser)
else
  fn2, err2 = load(empty_ser)
end
check(fn2 ~= nil, "empty output is valid Lua (" .. tostring(err2) .. ")")
if fn2 then
  local ok3, empty_data = pcall(fn2)
  check(ok3 and type(empty_data) == "table")
  check(next(empty_data.data) == nil)
end

io.write("  passed\n")

----------------------------------------------------------------------
-- 3. decay
----------------------------------------------------------------------

io.write("=== decay_learned / apply_time_decay ===\n")

do
  local d = { ["前文"] = { ["高频词"] = 50, ["将消亡"] = 1 } }
  decay_learned(d, 0.95)
  near(d["前文"]["高频词"], 47.5, 0.01, "high freq: 50*0.95")
  eq(d["前文"]["将消亡"], nil, "count 1 * 0.95 < 1.1 → nil")
end

do
  local d2 = { ["前文"] = { ["孤例"] = 1 } }
  decay_learned(d2, 0.95)
  eq(d2["前文"], nil, "empty ctx removed after all keys pruned")
end

do
  local d = { ["前文"] = { ["词"] = 10 } }
  local now = 1e9
  local at = apply_time_decay(d, 0.95, nil, now, 86400)
  eq(at, now, "first run stamps decay_at, no decay")
  eq(d["前文"]["词"], 10, "no decay on first stamp")
end

do
  local d = { ["前文"] = { ["词"] = 10 } }
  local now = 1e9
  local at = apply_time_decay(d, 0.95, now - 86400 * 2, now, 86400)
  near(d["前文"]["词"], 10 * 0.95 * 0.95, 0.01, "two days → rate^2")
  eq(at, now, "decay_at advanced by 2 periods")
end

do
  local d = { ["前文"] = { ["词"] = 10 } }
  local now = 1e9
  local old = now - 3600
  local at = apply_time_decay(d, 0.95, old, now, 86400)
  eq(d["前文"]["词"], 10, "same day: no decay")
  eq(at, old, "decay_at unchanged")
end

io.write("  passed\n")

----------------------------------------------------------------------
-- 4. score_candidates
----------------------------------------------------------------------

io.write("=== score_candidates ===\n")

do
  local s = {}
  score_candidates(cands{"任务", "人物", "工作"}, {"接下来的"}, {
    ["接下来的"] = { ["任务"] = 5, ["工作"] = 3 },
    ["来的"]     = { ["任务"] = 2 },
    ["的"]       = { ["人物"] = 4 },
  }, s)
  -- 精确 1.0: 任务 5, 工作 3
  -- last-2 0.5 (来的): 任务 +1
  -- last-1 「的」是虚词，跳过，人物不得分
  near(s["任务"], 6.0, 0.01, "任务 score")
  near(s["工作"], 3.0, 0.01, "工作 score")
  eq(s["人物"], nil, "stopword suffix 的 does not score")
end

do
  local s = {}
  score_candidates(cands{"任务", "人物"}, {"完成", "接下来的"}, {
    ["接下来的"]   = { ["任务"] = 5 },
    ["完成接下来的"] = { ["任务"] = 10 },
  }, s)
  near(s["任务"], 5 + 10 * 0.4, 0.01, "bigram score")
end

do
  local s = {}
  score_candidates(cands{"任务"}, {}, {}, s)
  eq(s["任务"], nil, "empty window => no scores")
end

do
  local s = {}
  score_candidates({}, {"接下来的"}, {}, s)
  check(next(s) == nil, "no candidates => no scores")
end

do
  -- 「好的」后不应被「的→朋友」带起
  local s = {}
  score_candidates(cands{"天气", "朋友"}, {"好的"}, {
    ["的"] = { ["朋友"] = 8 },
  }, s)
  eq(s["朋友"], nil, "好的 does not inherit 的→朋友")
  eq(s["天气"], nil)
end

io.write("  passed\n")

----------------------------------------------------------------------
-- 5. 表格复用
----------------------------------------------------------------------

io.write("=== scores reuse ===\n")

local s = { ["旧数据"] = 999 }
score_candidates(cands{"任务"}, {"接下来的"}, { ["接下来的"] = { ["任务"] = 3 } }, s)
eq(s["旧数据"], nil, "old keys cleared")
eq(s["任务"], 3.0, "new score set; table reused")

score_candidates(cands{"工作"}, {"接下来的"}, { ["接下来的"] = { ["工作"] = 5 } }, s)
eq(s["任务"], nil, "prev scores cleared on reuse")
eq(s["工作"], 5.0, "new score after reuse")

io.write("  passed\n")

----------------------------------------------------------------------
-- 6. 多 weight 累积
----------------------------------------------------------------------

io.write("=== multi-weight accumulation ===\n")

s = {}
score_candidates(cands{"任务"}, {"接下来的"}, {
  ["接下来的"] = { ["任务"] = 3 },  -- 1.0 => 3
  ["来的"]     = { ["任务"] = 4 },  -- 0.5 => 2
  ["的"]       = { ["任务"] = 8 },  -- skipped stopword
}, s)
near(s["任务"], 5.0, 0.01, "3 + 2, 的 skipped")

io.write("  passed\n")

----------------------------------------------------------------------
-- 7. load_data / save 往返（新格式 + 旧格式）
----------------------------------------------------------------------

io.write("=== load_data / save roundtrip ===\n")

local tmp_file = os.tmpname()
local sample = {
  ["接下来的"] = { ["任务"] = 8, ["工作"] = 3 },
  ["完成"]     = { ["任务"] = 5 },
}
check(save(sample, tmp_file, { decay_at = 42 }), "save succeeds")
local loaded, meta = load_data(tmp_file)
eq(loaded["接下来的"]["任务"], 8)
eq(loaded["接下来的"]["工作"], 3)
eq(loaded["完成"]["任务"], 5)
eq(meta.decay_at, 42)
os.remove(tmp_file)

-- 旧扁平格式
local old_file = os.tmpname()
local of = io.open(old_file, "w")
of:write('return {["完成"]={["任务"]=5}}\n')
of:close()
local old_loaded, old_meta = load_data(old_file)
eq(old_loaded["完成"]["任务"], 5, "legacy format")
check(old_meta.decay_at == nil, "legacy has no decay_at")
os.remove(old_file)

-- 旧文件里恰好有 key「data」时不能当成新格式
local mixed_file = os.tmpname()
local mf = io.open(mixed_file, "w")
mf:write('return {["完成"]={["任务"]=5},["data"]={["foo"]=2}}\n')
mf:close()
local mixed, mixed_meta = load_data(mixed_file)
eq(mixed["完成"]["任务"], 5, "legacy with data key keeps 完成")
eq(mixed["data"]["foo"], 2, "legacy data key kept as context")
check(mixed_meta.decay_at == nil, "not treated as new format")
os.remove(mixed_file)

local bad_file = os.tmpname()
local bf = io.open(bad_file, "w")
bf:write("not valid lua!!!")
bf:close()
local bad_data = load_data(bad_file)
check(next(bad_data) == nil, "corrupt file => empty table")
os.remove(bad_file)

io.write("  passed\n")

----------------------------------------------------------------------
-- 8. 分段学习：select 粒度，整句不上窗
----------------------------------------------------------------------

io.write("=== on_select / on_commit (segment learning) ===\n")

do
  local env = new_env()
  on_select(env, "接下来的")
  on_select(env, "任务")
  eq(env.window[1], "接下来的", "window updates on select for next-segment scoring")
  eq(env.window[2], "任务")
  check(next(env.learned) == nil, "learning deferred until commit")
  on_commit(env, "接下来的任务")
  eq(env.learned["接下来的"]["任务"], 1, "commit flushes word pair")
  eq(env.learned["任务"], nil, "whole sentence not used as next key")
  eq(env.commit_count, 1)
end

do
  local env = new_env()
  on_select(env, "接下来的任务是完成报告")
  check(next(env.learned) == nil, "long sentence not learned")
  eq(#env.window, 0, "long sentence not pushed to window")
  on_commit(env, "接下来的任务是完成报告")
  check(next(env.learned) == nil, "long sentence still not learned on commit")
end

do
  local env = new_env()
  on_select(env, "完成")
  on_select(env, "的")
  on_select(env, "任务")
  on_commit(env, "完成的任务")
  eq(env.learned["的"], nil, "stopword 的 is not a key")
  eq(env.learned["完成"]["任务"], 1, "window skips 的, learns 完成→任务")
  eq(env.window[#env.window], "任务")
end

do
  local env = new_env()
  on_select(env, "完成")
  on_select(env, "任务")
  on_cancel(env)
  check(next(env.learned) == nil, "Esc does not learn")
  eq(#env.window, 0, "Esc rolls window back")
end

do
  local env = new_env()
  on_commit(env, "完成")
  on_select(env, "任务")
  on_cancel(env)
  eq(env.window[1], "完成", "Esc restores pre-composition window")
  eq(env.learned["完成"], nil, "cancelled 任务 not learned")
end

do
  local env = new_env()
  on_commit(env, "完成")  -- 无 select（例如直接上屏）
  on_commit(env, "任务")
  eq(env.learned["完成"]["任务"], 1, "commit-only still learns when tokens are words")
end

do
  local env = new_env()
  on_select(env, "完成")
  on_commit(env, "。")
  eq(#env.window, 1, "punct commit after select does not replace window")
  eq(env.window[1], "完成")
end

do
  local env = new_env()
  on_select(env, "接下来的")
  on_select(env, "任务")
  check(revert_last_select(env), "revert pops last select")
  eq(env.window[1], "接下来的", "window after backspace")
  eq(#env.window, 1)
  eq(#env.pending_tokens, 1)
  check(next(env.learned) == nil, "revert does not learn")
  on_commit(env, "接下来的")
  eq(env.learned["接下来的"], nil, "single remaining token has no pair")
end

do
  local env = new_env()
  on_select(env, "接下来的")
  on_select(env, "任务")
  sync_pending(env, 1)  -- 退格后只剩 1 个已确认分段
  eq(#env.pending_tokens, 1)
  eq(env.window[1], "接下来的")
  eq(env.window[2], nil)
end

do
  local env = new_env()
  on_select(env, "接下来的", 11)
  on_select(env, "任务", 16)
  sync_pending(env, nil, 11)  -- confirmed_pos 回到选第一个词之后
  eq(#env.pending_tokens, 1)
  eq(env.window[1], "接下来的")
end

do
  local env = new_env()
  on_select(env, "完成")
  on_select(env, "任务")
  on_commit(env, "完成任务")
  eq(env.window[2], "任务")
  on_composition_update(env, false)  -- 上屏后 composition 清空
  eq(env.window[1], "完成", "post-commit update does not roll back")
  eq(env.window[2], "任务")
  eq(env.learned["完成"]["任务"], 1)
end

do
  local env = new_env()
  on_select(env, "完成")
  on_select(env, "任务")
  on_composition_update(env, false)  -- Esc，尚未 commit
  check(next(env.learned) == nil, "Esc via composition update does not learn")
  eq(#env.window, 0)
end

io.write("  passed\n")

----------------------------------------------------------------------
-- 9. do_save 按日衰减
----------------------------------------------------------------------

io.write("=== do_save time decay ===\n")

do
  local tmp = os.tmpname()
  local env = {
    learned = { ["前文"] = { ["词"] = 10, ["将消亡"] = 1 } },
    data_file = tmp,
    decay_enabled = true,
    decay_rate = 0.95,
    decay_period = 86400,
    decay_at = os.time() - 86400,
    commit_count = 3,
  }
  do_save(env)
  eq(env.commit_count, 0, "commit_count reset after save")
  local reloaded = load_data(tmp)
  near(reloaded["前文"]["词"], 9.5, 0.01, "one day decay on save")
  os.remove(tmp)
end

do
  local tmp = os.tmpname()
  local env = {
    learned = { ["前文"] = { ["词"] = 10 } },
    data_file = tmp,
    decay_enabled = true,
    decay_rate = 0.95,
    decay_period = 86400,
    decay_at = os.time(),
    commit_count = 2,
  }
  do_save(env)
  local reloaded = load_data(tmp)
  eq(reloaded["前文"]["词"], 10, "same-day save skips decay")
  os.remove(tmp)
end

io.write("  passed\n")

----------------------------------------------------------------------
-- 10. reorder_batch：只提前，不整表打乱
----------------------------------------------------------------------

io.write("=== reorder_batch ===\n")

do
  local batch = cands{"人物", "任务", "工作", "任命"}
  local scores = { ["任务"] = 5, ["工作"] = 3 }
  local out, changed = reorder_batch(batch, scores, 2.0)
  check(changed, "reordered")
  eq(out[1].text, "任务", "highest first")
  eq(out[2].text, "工作", "second promoted")
  eq(out[3].text, "人物", "unscored keep original relative order")
  eq(out[4].text, "任命")
end

do
  local batch = cands{"人物", "任务"}
  local out, changed = reorder_batch(batch, { ["任务"] = 1.5 }, 2.0)
  check(not changed, "below threshold")
  eq(out[1].text, "人物", "original order preserved")
  eq(out[2].text, "任务")
end

io.write("  passed\n")

----------------------------------------------------------------------
-- 11. resolve_data_path
----------------------------------------------------------------------

io.write("=== resolve_data_path ===\n")
eq(resolve_data_path("/custom/x.data", "/user"), "/custom/x.data", "custom wins")
local sep = package.config:sub(1, 1)
eq(resolve_data_path("", "/home/u/rime"), "/home/u/rime" .. sep .. "context_learned.data")
eq(resolve_data_path(nil, "/home/u/rime/"), "/home/u/rime/context_learned.data", "trailing slash")
io.write("  passed\n")

----------------------------------------------------------------------
-- Results
----------------------------------------------------------------------

io.write("\n" .. string.rep("=", 40) .. "\n")
io.write("RESULTS: " .. total .. " tests, " .. passed .. " passed, " .. failed .. " failed\n")
io.write(string.rep("=", 40) .. "\n")

if failed > 0 then os.exit(1) end
