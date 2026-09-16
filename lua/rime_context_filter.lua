-- rime_context_filter.lua
-- 纯学习的上下文调频引擎（v6 — 分段学习 + 用户目录 + 受限重排）
--
-- 学习：记录「刚确认的词 → 下一个确认的词」，对齐组词过程中的 select
-- 匹配：根据当前上下文对首页候选提权，其余保持原序
-- 持久化：数据以 Lua 表字面量存到用户目录 context_learned.data
--
-- 配置（rime_context_filter: 或 context_filter:）：
--   save_interval: 30
--   data_path: ""
--   decay_enabled: true
--   decay_rate: 0.95          -- 每个衰减周期的乘数
--   decay_period_days: 1      -- 按自然日衰减，而非按保存次数
--   reorder_limit: 80         -- 只重排前 N 个候选
--
-- 激活（务必放在 uniquifier 之后）：
--   engine/filters/+:
--     - lua_filter@*rime_context_filter

----------------------------------------------------------------------
-- 配置读取（兼容 name_space 与 README 中的 context_filter）
----------------------------------------------------------------------

local function cfg_get(config, ns, key, getter)
  local fn = config[getter]
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, config, ns .. "/" .. key)
  if ok and v ~= nil then return v end
  if ns ~= "context_filter" then
    ok, v = pcall(fn, config, "context_filter/" .. key)
    if ok and v ~= nil then return v end
  end
  return nil
end

----------------------------------------------------------------------
-- UTF-8
----------------------------------------------------------------------

local function utf8_last(s, n)
  local len = #s
  if len == 0 then return s end
  local pos = len + 1
  for _ = 1, n do
    if pos <= 1 then break end
    pos = pos - 1
    while pos > 1 and s:byte(pos) >= 0x80 and s:byte(pos) < 0xC0 do
      pos = pos - 1
    end
  end
  if pos < 1 then pos = 1 end
  return s:sub(pos)
end

local function utf8_char_count(s)
  local count, i, len = 0, 1, #s
  while i <= len do
    local b = s:byte(i)
    if not b then break end
    if b < 0x80 then
      i = i + 1
    elseif b < 0xE0 then
      i = i + 2
    elseif b < 0xF0 then
      i = i + 3
    else
      i = i + 4
    end
    count = count + 1
  end
  return count
end

--- 是否含汉字（CJK 统一表意文字），不含标点
local function has_cjk_ideograph(s)
  local i, len = 1, #s
  while i <= len do
    local b = s:byte(i)
    if not b then break end
    if b >= 0xE0 and b < 0xF0 and i + 2 <= len then
      local c = (b - 0xE0) * 4096 + (s:byte(i + 1) - 0x80) * 64 + (s:byte(i + 2) - 0x80)
      if (c >= 0x4E00 and c <= 0x9FFF) or (c >= 0x3400 and c <= 0x4DBF) then
        return true
      end
      i = i + 3
    elseif b < 0x80 then
      i = i + 1
    elseif b < 0xE0 then
      i = i + 2
    else
      i = i + 4
    end
  end
  return false
end

----------------------------------------------------------------------
-- 可学习 token：排除整句、纯英文、标点、高频虚词
----------------------------------------------------------------------

local STOP = {
  ["的"]=true, ["了"]=true, ["是"]=true, ["在"]=true, ["和"]=true,
  ["有"]=true, ["我"]=true, ["不"]=true, ["就"]=true, ["都"]=true,
  ["一"]=true, ["也"]=true, ["很"]=true, ["到"]=true, ["要"]=true,
  ["去"]=true, ["你"]=true, ["会"]=true, ["着"]=true, ["这"]=true,
  ["那"]=true, ["吗"]=true, ["吧"]=true, ["呢"]=true, ["啊"]=true,
  ["嗯"]=true, ["把"]=true, ["被"]=true, ["让"]=true, ["给"]=true,
  ["跟"]=true, ["与"]=true, ["或"]=true, ["但"]=true, ["而"]=true,
  ["又"]=true, ["还"]=true, ["没"]=true, ["对"]=true, ["为"]=true,
}

local MAX_TOKEN_CHARS = 8

local function is_learnable(s)
  if not s or s == "" then return false end
  if STOP[s] then return false end
  if s:match("^[%p%s%c]+$") then return false end
  local n = utf8_char_count(s)
  if n < 1 or n > MAX_TOKEN_CHARS then return false end
  return has_cjk_ideograph(s)
end

local function is_stop_key(s)
  return s ~= nil and STOP[s] == true
end

----------------------------------------------------------------------
-- 路径
----------------------------------------------------------------------

local function resolve_data_path(custom_path, user_data_dir)
  if custom_path and #custom_path > 0 then return custom_path end

  local sep = package.config:sub(1, 1)
  if user_data_dir and #user_data_dir > 0 then
    local last = user_data_dir:sub(-1)
    if last == "/" or last == "\\" then
      return user_data_dir .. "context_learned.data"
    end
    return user_data_dir .. sep .. "context_learned.data"
  end

  -- rime_api 不可用时的回退（测试 / 异常嵌入）
  if sep == "\\" then
    return (os.getenv("APPDATA") or "") .. sep .. "Rime" .. sep .. "context_learned.data"
  end
  local home = os.getenv("HOME") or ""
  local xdg = os.getenv("XDG_DATA_HOME")
  if xdg and #xdg > 0 then
    return xdg .. "/rime/context_learned.data"
  end
  return home .. "/.local/share/rime/context_learned.data"
end

local function get_data_path(env)
  local config = env.engine.schema.config
  local ns = env.name_space
  local custom = cfg_get(config, ns, "data_path", "get_string")
  local user_dir = ""
  if rime_api and rime_api.get_user_data_dir then
    user_dir = rime_api.get_user_data_dir() or ""
  end
  return resolve_data_path(custom, user_dir)
end

----------------------------------------------------------------------
-- 持久化
----------------------------------------------------------------------

local function esc(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

local function serialize(data, meta)
  meta = meta or {}
  local buf = {
    "return {\n",
    "  _meta={decay_at=" .. tostring(meta.decay_at or os.time()) .. "},\n",
    "  data={\n",
  }
  for ctx, words in pairs(data) do
    if type(ctx) == "string" and type(words) == "table" then
      local first = true
      buf[#buf + 1] = "    [" .. esc(ctx) .. "]={"
      for word, count in pairs(words) do
        if type(word) == "string" and type(count) == "number" and count > 1 then
          if first then first = false else buf[#buf + 1] = "," end
          buf[#buf + 1] = "[" .. esc(word) .. "]=" .. count
        end
      end
      if first then
        buf[#buf] = nil
      else
        buf[#buf + 1] = "},\n"
      end
    end
  end
  buf[#buf + 1] = "  },\n}\n"
  return table.concat(buf)
end

local function load_data(data_file)
  local f = io.open(data_file, "r")
  if not f then return {}, {} end

  local content = f:read("*a")
  f:close()
  if not content or #content == 0 then return {}, {} end

  local safe_env = {}
  local loader

  if _VERSION == "Lua 5.1" then
    loader = loadstring(content, "@" .. data_file)
    local setf = rawget(_G, "setfenv")
    if loader and setf then
      setf(loader, safe_env)
    elseif loader then
      io.stderr:write("[rime-context-filter] WARNING: " ..
        "Sandbox unavailable on Lua 5.1. " ..
        "Data file could access global environment.\n")
    end
  else
    loader = load(content, "@" .. data_file, "t", safe_env)
    if not loader then
      loader = load(content, "@" .. data_file)
      if loader then
        io.stderr:write("[rime-context-filter] WARNING: " ..
          "Sandbox unavailable, data file could access global environment.\n")
      end
    end
  end

  if not loader then return {}, {} end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" then return {}, {} end

  -- 必须同时有 _meta 和 data，避免旧文件里恰好有 key「data」时被误判
  if type(data._meta) == "table" and type(data.data) == "table" then
    return data.data, data._meta
  end
  -- v5 扁平格式
  local learned = {}
  for k, v in pairs(data) do
    if type(k) == "string" and k ~= "_meta" and type(v) == "table" then
      learned[k] = v
    end
  end
  return learned, {}
end

local function save(data, data_file, meta)
  local tmp = data_file .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(serialize(data, meta))
  f:close()
  os.remove(data_file)
  os.rename(tmp, data_file)
  return true
end

local function ensure_dir(path)
  local is_win = package.config:sub(1, 1) == "\\"
  if is_win then
    local dir = path:match("^(.+)\\[^\\]+$")
    if dir then os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '"') end
  else
    local dir = path:match("^(.+)/([^/]+)$")
    if dir then
      os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
    end
  end
end

local function ensure_file(data_file)
  local f = io.open(data_file, "a")
  if f then f:close(); return end
  ensure_dir(data_file)
  f = io.open(data_file, "w")
  if f then f:write("return {_meta={},data={}}\n"); f:close() end
end

----------------------------------------------------------------------
-- 衰减：按自然日，而不是按保存次数
----------------------------------------------------------------------

local function decay_learned(learned, rate)
  for ctx, words in pairs(learned) do
    for word, count in pairs(words) do
      local new_count = count * rate
      if new_count < 1.1 then
        words[word] = nil
      else
        words[word] = new_count
      end
    end
    if next(words) == nil then
      learned[ctx] = nil
    end
  end
end

local function apply_time_decay(learned, rate, decay_at, now, period)
  now = now or os.time()
  period = period or 86400
  if not decay_at then
    return now
  end
  local elapsed = now - decay_at
  if elapsed < period then
    return decay_at
  end
  local steps = math.floor(elapsed / period)
  if steps > 0 then
    decay_learned(learned, rate ^ steps)
    decay_at = decay_at + steps * period
  end
  return decay_at
end

----------------------------------------------------------------------
-- 学习 / 窗口
----------------------------------------------------------------------

local function push_window(window, text, max_n)
  window[#window + 1] = text
  while #window > max_n do
    table.remove(window, 1)
  end
end

local function learn_pair(learned, prev, text)
  local e = learned[prev]
  if e then
    e[text] = (e[text] or 0) + 1
  else
    learned[prev] = { [text] = 1 }
  end
end

local function copy_window(w)
  local n = {}
  for i = 1, #w do n[i] = w[i] end
  return n
end

local function clear_pending(env)
  env.pending_tokens = {}
  env.pending_marks = {}
  env.window_checkpoint = nil
  env._selected = false
end

local function rebuild_window(env)
  env.window = copy_window(env.window_checkpoint or {})
  local pending = env.pending_tokens or {}
  for i = 1, #pending do
    push_window(env.window, pending[i], 3)
  end
end

--- 退格撤销最近一次 select：弹出 pending 并按 checkpoint 重建窗口。
local function revert_last_select(env)
  local pending = env.pending_tokens
  if not pending or #pending == 0 then return false end
  pending[#pending] = nil
  if env.pending_marks then
    env.pending_marks[#env.pending_marks] = nil
  end
  if #pending == 0 then
    env.window = copy_window(env.window_checkpoint or {})
    clear_pending(env)
  else
    rebuild_window(env)
  end
  return true
end

--- confirmed_count：仍处于 kSelected/kConfirmed 的可学习分段数。
--- confirmed_pos：segmentation:get_confirmed_position()，与 select 时记下的 mark 比较。
local function sync_pending(env, confirmed_count, confirmed_pos)
  local pending = env.pending_tokens
  if not pending or #pending == 0 then return end
  if type(confirmed_count) == "number" then
    while #pending > confirmed_count do
      revert_last_select(env)
      pending = env.pending_tokens
      if not pending or #pending == 0 then return end
    end
    return
  end
  if type(confirmed_pos) == "number" and env.pending_marks then
    while #pending > 0 do
      local mark = env.pending_marks[#env.pending_marks]
      if not mark or mark <= confirmed_pos then break end
      revert_last_select(env)
      pending = env.pending_tokens
    end
  end
end

--- 直接上屏的词（无 select）：过滤后学习并入窗。
local function on_token(env, text)
  if not is_learnable(text) then return false end
  local prev = env.window[#env.window]
  if prev then
    learn_pair(env.learned, prev, text)
  end
  push_window(env.window, text, 3)
  return true
end

--- 组词中确认当前词：立刻更新窗口供下一分段打分，学习推迟到 commit。
--- confirmed_pos 为可选的 input 已确认长度，用于退格时判断。
local function on_select(env, text, confirmed_pos)
  env._selected = true
  env._committed = false
  if not is_learnable(text) then return false end
  env.pending_tokens = env.pending_tokens or {}
  env.pending_marks = env.pending_marks or {}
  if #env.pending_tokens == 0 then
    env.window_checkpoint = copy_window(env.window)
  end
  env.pending_tokens[#env.pending_tokens + 1] = text
  env.pending_marks[#env.pending_marks + 1] = confirmed_pos
  push_window(env.window, text, 3)
  return true
end

local function learn_pending(env)
  local pending = env.pending_tokens
  if not pending or #pending == 0 then return end
  local prev
  if env.window_checkpoint and #env.window_checkpoint > 0 then
    prev = env.window_checkpoint[#env.window_checkpoint]
  end
  for i = 1, #pending do
    local text = pending[i]
    if prev then learn_pair(env.learned, prev, text) end
    prev = text
  end
end

--- Esc / 清空组词：回滚窗口，不写入学习数据。
local function on_cancel(env)
  if env.window_checkpoint then
    env.window = env.window_checkpoint
  end
  clear_pending(env)
end

--- commit 时若刚发生过 select，把本段组词落成词对；整句本身不再当 token。
local function on_commit(env, text)
  env._committed = true
  if env._selected then
    learn_pending(env)
    clear_pending(env)
  else
    on_token(env, text)
  end
  env.commit_count = (env.commit_count or 0) + 1
  return env.commit_count
end

--- 组词状态变化：Esc 整段取消，或退格撤销部分 select。
--- composing=false 且尚未 commit 且仍有 pending → 整段回滚。
--- composing=true 时按 confirmed_count / confirmed_pos 弹出多余 pending。
local function on_composition_update(env, composing, confirmed_count, confirmed_pos)
  if env._committed then
    if composing then env._committed = false end
    return
  end
  if not composing then
    if env.pending_tokens and #env.pending_tokens > 0 then
      on_cancel(env)
    end
    return
  end
  sync_pending(env, confirmed_count, confirmed_pos)
end

local function selected_text(ctx)
  local cand = ctx:get_selected_candidate()
  if cand and cand.text and #cand.text > 0 then
    return cand.text
  end
  local comp = ctx.composition
  if comp and not comp:empty() then
    local seg = comp:back()
    if seg and seg.get_selected_candidate then
      cand = seg:get_selected_candidate()
      if cand and cand.text and #cand.text > 0 then
        return cand.text
      end
    end
  end
  return nil
end

local function get_confirmed_pos(ctx)
  local ok, pos = pcall(function()
    return ctx.composition:toSegmentation():get_confirmed_position()
  end)
  if ok and type(pos) == "number" then return pos end
  return nil
end

local function confirmed_learnable_count(ctx)
  local ok, segs = pcall(function()
    local comp = ctx.composition
    if not comp or comp:empty() then return {} end
    return comp:toSegmentation():get_segments()
  end)
  if not ok or type(segs) ~= "table" then return nil end
  local n = 0
  for i = 1, #segs do
    local seg = segs[i]
    local st = seg.status
    if st == "kSelected" or st == "kConfirmed" then
      local cand = seg.get_selected_candidate and seg:get_selected_candidate()
      if cand and is_learnable(cand.text) then
        n = n + 1
      end
    end
  end
  return n
end

----------------------------------------------------------------------
-- 评分与重排（热路径）
----------------------------------------------------------------------

local THRESHOLD = 2.0

local function score_candidates(candidates, window, learned, scores)
  for k in pairs(scores) do scores[k] = nil end

  local last = window[#window]
  if not last or #last == 0 then return end

  local function apply_weight(key, weight)
    if not key or is_stop_key(key) then return end
    local e = learned[key]
    if not e then return end
    for _, c in ipairs(candidates) do
      local w = c.text
      if e[w] then
        scores[w] = (scores[w] or 0) + e[w] * weight
      end
    end
  end

  local nchars = utf8_char_count(last)
  apply_weight(last, 1.0)
  if nchars >= 2 then apply_weight(utf8_last(last, 2), 0.5) end
  if nchars >= 1 then apply_weight(utf8_last(last, 1), 0.25) end
  if #window >= 2 then
    apply_weight(window[#window - 1] .. last, 0.4)
  end
end

--- 只把超过阈值的候选提前，其余保持原序（不整表 sort）
local function reorder_batch(candidates, scores, threshold)
  threshold = threshold or THRESHOLD
  local promoted, rest = {}, {}
  local max_score = 0
  for i = 1, #candidates do
    local s = scores[candidates[i].text] or 0
    if s > max_score then max_score = s end
    if s >= threshold then
      promoted[#promoted + 1] = i
    else
      rest[#rest + 1] = i
    end
  end
  if max_score < threshold or #promoted == 0 then
    return candidates, false
  end
  table.sort(promoted, function(a, b)
    local sa = scores[candidates[a].text] or 0
    local sb = scores[candidates[b].text] or 0
    if sa ~= sb then return sa > sb end
    return a < b
  end)
  local out = {}
  for _, i in ipairs(promoted) do out[#out + 1] = candidates[i] end
  for _, i in ipairs(rest) do out[#out + 1] = candidates[i] end
  return out, true
end

----------------------------------------------------------------------
-- 存盘
----------------------------------------------------------------------

local function do_save(env)
  if env.decay_enabled then
    env.decay_at = apply_time_decay(
      env.learned,
      env.decay_rate,
      env.decay_at,
      os.time(),
      env.decay_period
    )
  elseif not env.decay_at then
    env.decay_at = os.time()
  end
  local ok = save(env.learned, env.data_file, { decay_at = env.decay_at })
  if ok then
    env.commit_count = 0
  end
  return ok
end

----------------------------------------------------------------------
-- 组件入口
----------------------------------------------------------------------

local function init(env)
  env.name_space = env.name_space:gsub("^*", "")
  local config = env.engine.schema.config
  local ns = env.name_space

  env.data_file = get_data_path(env)

  local interval = cfg_get(config, ns, "save_interval", "get_int")
  env.save_interval = (interval ~= nil) and interval or 30

  env.decay_enabled = cfg_get(config, ns, "decay_enabled", "get_bool")
  if env.decay_enabled == nil then env.decay_enabled = true end

  local rate = cfg_get(config, ns, "decay_rate", "get_double")
  if rate == nil then
    rate = tonumber(cfg_get(config, ns, "decay_rate", "get_string") or "")
  end
  env.decay_rate = rate or 0.95

  local days = cfg_get(config, ns, "decay_period_days", "get_int") or 1
  if days < 1 then days = 1 end
  env.decay_period = days * 86400

  env.reorder_limit = cfg_get(config, ns, "reorder_limit", "get_int") or 80

  env.window = {}
  ensure_file(env.data_file)
  local meta
  env.learned, meta = load_data(env.data_file)
  env.decay_at = meta.decay_at
  env.scores = {}
  env.commit_count = 0
  env._selected = false
  env.pending_tokens = {}
  env.pending_marks = {}
  env._in_commit = false
  env._committed = false

  local ctx = env.engine.context

  -- 必须持有 connection，否则 GC 会断开回调
  -- group 0 先于未分组的引擎回调执行，避免 composition 推进后丢失刚选中的词。
  env.select_conn = ctx.select_notifier:connect(function(c)
    local ok, text = pcall(selected_text, c)
    if ok and text then
      on_select(env, text, get_confirmed_pos(c))
    end
  end, 0)

  env.commit_conn = ctx.commit_notifier:connect(function(c)
    env._in_commit = true
    local text = c:get_commit_text()
    on_commit(env, text)
    if env.commit_count >= env.save_interval then
      do_save(env)
    end
    env._in_commit = false
  end)

  env.update_conn = ctx.update_notifier:connect(function(c)
    if env._in_commit then return end
    local ok, composing = pcall(function() return c:is_composing() end)
    if not ok then return end
    on_composition_update(
      env,
      composing,
      confirmed_learnable_count(c),
      get_confirmed_pos(c)
    )
  end)
end

local function fini(env)
  if env.commit_count and env.commit_count > 0 then
    do_save(env)
  end
  if env.select_conn and env.select_conn.disconnect then
    env.select_conn:disconnect()
  end
  if env.commit_conn and env.commit_conn.disconnect then
    env.commit_conn:disconnect()
  end
  if env.update_conn and env.update_conn.disconnect then
    env.update_conn:disconnect()
  end
end

local function tags_match(segment, env)
  local ok, hit = pcall(function()
    return segment:has_tag("abc")
  end)
  if ok then return hit and true or false end
  return true
end

local function filter(input, env)
  local limit = env.reorder_limit or 80
  local iter_fn, inv, var = input:iter()
  local function next_cand()
    var = iter_fn(inv, var)
    return var
  end

  if limit <= 0 then
    local cand = next_cand()
    while cand do
      yield(cand)
      cand = next_cand()
    end
    return
  end

  local batch = {}
  for _ = 1, limit do
    local cand = next_cand()
    if not cand then break end
    batch[#batch + 1] = cand
  end
  if #batch == 0 then return end

  score_candidates(batch, env.window, env.learned, env.scores)
  local ordered = reorder_batch(batch, env.scores, THRESHOLD)
  for _, cand in ipairs(ordered) do
    yield(cand)
  end

  local cand = next_cand()
  while cand do
    yield(cand)
    cand = next_cand()
  end
end

return {
  init = init,
  fini = fini,
  func = filter,
  tags_match = tags_match,
  -- 测试导出
  utf8_last = utf8_last,
  utf8_char_count = utf8_char_count,
  has_cjk_ideograph = has_cjk_ideograph,
  is_learnable = is_learnable,
  is_stop_key = is_stop_key,
  serialize = serialize,
  load_data = load_data,
  save = save,
  decay_learned = decay_learned,
  apply_time_decay = apply_time_decay,
  score_candidates = score_candidates,
  reorder_batch = reorder_batch,
  on_token = on_token,
  on_select = on_select,
  on_commit = on_commit,
  on_cancel = on_cancel,
  on_composition_update = on_composition_update,
  revert_last_select = revert_last_select,
  sync_pending = sync_pending,
  do_save = do_save,
  resolve_data_path = resolve_data_path,
}
