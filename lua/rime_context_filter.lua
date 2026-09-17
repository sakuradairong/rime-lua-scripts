-- rime_context_filter.lua
-- 个人本地词级二元模型（v7）
--
-- 学习：相邻两个有效 token 的 bigram 计数（前词 → 当前词）
-- 打分：平滑后的 P(当前|前词) × 置信度；低置信度不改序
-- 持久化：用户目录 context_learned.data（Lua 表字面量，带版本号）
--
-- 配置（rime_context_filter: 或 context_filter:）：
--   save_interval: 30
--   data_path: ""
--   decay_enabled: true
--   decay_rate: 0.95
--   decay_period_days: 1
--   reorder_limit: 80
--   idle_timeout_sec: 120
--   max_contexts: 4000
--   max_successors: 48
--   promote_min_count: 2
--   max_promote: 5
--   protect_prefix: 0
--
-- 激活（务必放在 uniquifier 之后）：
--   engine/filters/+:
--     - lua_filter@*rime_context_filter

local FORMAT_VERSION = 7
local ALPHA = 1.0              -- 加性平滑
local CONF_K = 1.0             -- 搭配置信度：c/(c+K)
local PROMOTE_SCORE = 0.12     -- 提权分数门槛（≠ 落盘门槛）
local DEFAULT_PROMOTE_MIN = 2  -- 至少出现这么多次才允许提权
local DEFAULT_MAX_PROMOTE = 5
local DEFAULT_IDLE = 120
local DEFAULT_MAX_CTX = 4000
local DEFAULT_MAX_SUCC = 48
local DECAY_FLOOR = 1.1        -- 衰减后低于此则淘汰；落盘门槛仍为 count >= 1

----------------------------------------------------------------------
-- 模块级共享存储：多 Filter 实例共用同一份内存，避免互相用旧快照覆盖
----------------------------------------------------------------------

local STORE = {
  file = nil,
  learned = {},
  totals = {},
  meta = { version = FORMAT_VERSION },
  dirty = false,
  dirty_commits = 0,
  load_ok = true,
  corrupt = false,
  refs = 0,
  save_failures = 0,
}

----------------------------------------------------------------------
-- 配置读取
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
-- 可学习 token / 边界
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

-- CJK 句读：跨越它们不得视为相邻词
local SENTENCE_PUNCT = {
  ["。"]=true, ["？"]=true, ["！"]=true, ["；"]=true, ["…"]=true,
  ["，"]=true, ["、"]=true, ["："]=true, ["\n"]=true, ["\r"]=true,
}

local function contains_sentence_punct(s)
  if not s then return false end
  for p in pairs(SENTENCE_PUNCT) do
    if p ~= "" and s:find(p, 1, true) then return true end
  end
  if s:find("[\r\n]") then return true end
  return false
end

local function is_ascii_or_digit_heavy(s)
  if not s or s == "" then return false end
  if s:match("^[%w%s%p]+$") and not has_cjk_ideograph(s) then
    return true
  end
  return false
end

local function is_learnable(s)
  if not s or s == "" then return false end
  if STOP[s] then return false end
  if s:match("^[%p%s%c]+$") then return false end
  if contains_sentence_punct(s) then return false end
  if is_ascii_or_digit_heavy(s) then return false end
  local n = utf8_char_count(s)
  if n < 1 or n > MAX_TOKEN_CHARS then return false end
  return has_cjk_ideograph(s)
end

local function is_stop_key(s)
  return s ~= nil and STOP[s] == true
end

--- 边界 token：应清空上下文，不得把前后词当作相邻
local function is_context_breaker(s)
  if not s or s == "" then return true end
  if s:match("^[%p%s%c]+$") then return true end
  if contains_sentence_punct(s) then return true end
  if is_ascii_or_digit_heavy(s) then return true end
  local n = utf8_char_count(s)
  if n > MAX_TOKEN_CHARS then return true end
  return false
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
-- totals / prune
----------------------------------------------------------------------

local function recompute_total(words)
  local t = 0
  if type(words) ~= "table" then return 0 end
  for _, c in pairs(words) do
    if type(c) == "number" then t = t + c end
  end
  return t
end

local function rebuild_totals(learned)
  local totals = {}
  for ctx, words in pairs(learned) do
    if type(ctx) == "string" and type(words) == "table" then
      totals[ctx] = recompute_total(words)
    end
  end
  return totals
end

local function count_contexts(learned)
  local n = 0
  for _ in pairs(learned) do n = n + 1 end
  return n
end

local function prune_successors(words, max_succ)
  local n = 0
  for _ in pairs(words) do n = n + 1 end
  if n <= max_succ then return end
  local arr = {}
  for w, c in pairs(words) do
    arr[#arr + 1] = { w = w, c = c }
  end
  table.sort(arr, function(a, b)
    if a.c ~= b.c then return a.c > b.c end
    return a.w < b.w
  end)
  for i = max_succ + 1, #arr do
    words[arr[i].w] = nil
  end
end

local function prune_store(learned, totals, max_ctx, max_succ)
  for ctx, words in pairs(learned) do
    prune_successors(words, max_succ)
    local t = recompute_total(words)
    if t <= 0 then
      learned[ctx] = nil
      totals[ctx] = nil
    else
      totals[ctx] = t
    end
  end
  local n = count_contexts(learned)
  if n <= max_ctx then return end
  local arr = {}
  for ctx, t in pairs(totals) do
    arr[#arr + 1] = { ctx = ctx, t = t or 0 }
  end
  table.sort(arr, function(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return a.ctx < b.ctx
  end)
  for i = max_ctx + 1, #arr do
    learned[arr[i].ctx] = nil
    totals[arr[i].ctx] = nil
  end
end

----------------------------------------------------------------------
-- 持久化
----------------------------------------------------------------------

local function esc(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

--- 落盘保留 count >= 1 的搭配（与提权门槛分离）
local function serialize(data, meta)
  meta = meta or {}
  local buf = {
    "return {\n",
    "  _meta={version=" .. tostring(meta.version or FORMAT_VERSION) ..
      ",decay_at=" .. tostring(meta.decay_at or os.time()) ..
      ",saved_at=" .. tostring(meta.saved_at or os.time()) .. "},\n",
    "  data={\n",
  }
  for ctx, words in pairs(data) do
    if type(ctx) == "string" and type(words) == "table" then
      local parts = {}
      for word, count in pairs(words) do
        if type(word) == "string" and type(count) == "number" and count >= 1 then
          local n = count
          if math.floor(n) == n then
            parts[#parts + 1] = "[" .. esc(word) .. "]=" .. tostring(n)
          else
            parts[#parts + 1] = "[" .. esc(word) .. "]=" .. string.format("%.4f", n)
          end
        end
      end
      if #parts > 0 then
        buf[#buf + 1] = "    [" .. esc(ctx) .. "]={" .. table.concat(parts, ",") .. "},\n"
      end
    end
  end
  buf[#buf + 1] = "  },\n}\n"
  return table.concat(buf)
end

local function normalize_loaded(raw_learned)
  local learned = {}
  for ctx, words in pairs(raw_learned) do
    if type(ctx) == "string" and type(words) == "table" then
      local e = {}
      for w, c in pairs(words) do
        if type(w) == "string" and type(c) == "number" and c >= 1 then
          e[w] = c
        end
      end
      if next(e) then learned[ctx] = e end
    end
  end
  return learned
end

--- 返回 learned, meta, ok
--- ok=false：文件损坏或不可解析；不得用空表静默覆盖原文件
local function load_data(data_file)
  local function parse_content(content, path)
    if not content or #content == 0 then
      return {}, { version = FORMAT_VERSION }, true
    end
    local safe_env = {}
    local loader
    if _VERSION == "Lua 5.1" then
      loader = loadstring(content, "@" .. path)
      local setf = rawget(_G, "setfenv")
      if loader and setf then
        setf(loader, safe_env)
      elseif loader then
        io.stderr:write("[rime-context-filter] WARNING: sandbox unavailable on Lua 5.1\n")
      end
    else
      loader = load(content, "@" .. path, "t", safe_env)
      if not loader then
        loader = load(content, "@" .. path)
        if loader then
          io.stderr:write("[rime-context-filter] WARNING: sandbox unavailable\n")
        end
      end
    end
    if not loader then
      return {}, { version = FORMAT_VERSION }, false
    end
    local ok, data = pcall(loader)
    if not ok or type(data) ~= "table" then
      return {}, { version = FORMAT_VERSION }, false
    end
    if type(data._meta) == "table" and type(data.data) == "table" then
      local meta = {
        version = tonumber(data._meta.version) or 6,
        decay_at = data._meta.decay_at,
        saved_at = data._meta.saved_at,
      }
      return normalize_loaded(data.data), meta, true
    end
    local learned = {}
    for k, v in pairs(data) do
      if type(k) == "string" and k ~= "_meta" and type(v) == "table" then
        learned[k] = v
      end
    end
    return normalize_loaded(learned), { version = 5 }, true
  end

  --- @return status "missing"|"ok"|"bad", learned, meta
  local function try_path(path)
    local f = io.open(path, "r")
    if not f then return "missing" end
    local content = f:read("*a")
    f:close()
    local learned, meta, ok = parse_content(content, path)
    if ok then return "ok", learned, meta end
    return "bad", learned, meta
  end

  local st, learned, meta = try_path(data_file)
  if st == "ok" then return learned, meta, true end
  if st == "bad" then return {}, { version = FORMAT_VERSION }, false end

  -- 主文件缺失：从 .bak / .tmp 恢复（崩溃发生在 rename 中间时）
  -- 不同步合并 *.sync-conflict*
  local st_bak, learned_bak, meta_bak = try_path(data_file .. ".bak")
  if st_bak == "ok" then return learned_bak, meta_bak, true end
  local st_tmp, learned_tmp, meta_tmp = try_path(data_file .. ".tmp")
  if st_tmp == "ok" then return learned_tmp, meta_tmp, true end
  if st_bak == "bad" or st_tmp == "bad" then
    return {}, { version = FORMAT_VERSION }, false
  end

  return {}, { version = FORMAT_VERSION }, true
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

--- 安全原子保存。
--- 失败时保留可恢复旧数据，返回 false（绝不在删主文件后仍报成功）。
local function save(data, data_file, meta)
  if not data_file or #data_file == 0 then
    return false, "empty_path"
  end

  meta = meta or {}
  meta.version = meta.version or FORMAT_VERSION
  meta.saved_at = os.time()

  local content = serialize(data, meta)
  local tmp = data_file .. ".tmp"
  local bak = data_file .. ".bak"

  local f, err = io.open(tmp, "w")
  if not f then
    ensure_dir(data_file)
    f, err = io.open(tmp, "w")
    if not f then return false, "open_tmp:" .. tostring(err) end
  end

  local wok, werr = f:write(content)
  if wok == false or (type(wok) == "nil" and werr) then
    pcall(function() f:close() end)
    pcall(function() os.remove(tmp) end)
    return false, "write:" .. tostring(werr)
  end
  if f.flush then
    local fok, ferr = f:flush()
    if fok == false then
      pcall(function() f:close() end)
      pcall(function() os.remove(tmp) end)
      return false, "flush:" .. tostring(ferr)
    end
  end
  local closed = f:close()
  -- Lua 5.1 close 可能返回 nil；仅在显式 false 时判失败
  if closed == false then
    pcall(function() os.remove(tmp) end)
    return false, "close"
  end

  local existing = io.open(data_file, "r")
  if existing then
    existing:close()
    pcall(function() os.remove(bak) end)
    local rok = os.rename(data_file, bak)
    if not rok then
      -- Windows 上若 bak 仍占用，尝试直接覆盖策略失败 → 保留主文件与 tmp
      return false, "rename_to_bak"
    end
  end

  local mok = os.rename(tmp, data_file)
  if not mok then
    -- 尝试恢复 bak
    local bak_f = io.open(bak, "r")
    if bak_f then
      bak_f:close()
      pcall(function() os.rename(bak, data_file) end)
    end
    return false, "rename_tmp"
  end

  return true
end

local function ensure_file(data_file)
  local f = io.open(data_file, "r")
  if f then f:close(); return end
  -- 不预创建空库文件，避免与「损坏时空表覆盖」混淆；首次保存时再写
end

----------------------------------------------------------------------
-- 衰减
----------------------------------------------------------------------

local function decay_learned(learned, rate, floor)
  floor = floor or DECAY_FLOOR
  for ctx, words in pairs(learned) do
    for word, count in pairs(words) do
      local new_count = count * rate
      if new_count < floor then
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

local function touch_activity(env, now)
  env.last_activity = now or os.time()
end

local function maybe_idle_reset(env, now, opts)
  now = now or os.time()
  opts = opts or {}
  local idle = env.idle_timeout_sec or DEFAULT_IDLE
  if idle > 0 and env.last_activity and (now - env.last_activity) >= idle then
    -- 清空前文窗口；默认也清 pending。commit 路径应设 keep_pending，避免丢掉即将落盘的分段。
    env.window = {}
    if not opts.keep_pending then
      env.pending_tokens = {}
      env.pending_marks = {}
      env.window_checkpoint = nil
    end
  end
  touch_activity(env, now)
end

local function clear_context(env)
  env.window = {}
  env.pending_tokens = {}
  env.pending_marks = {}
  env.window_checkpoint = nil
end

local function push_window(window, text, max_n)
  window[#window + 1] = text
  while #window > max_n do
    table.remove(window, 1)
  end
end

local function learn_pair(learned, totals, prev, text, max_succ)
  if not prev or not text or prev == "" or text == "" then return end
  local e = learned[prev]
  if e then
    e[text] = (e[text] or 0) + 1
  else
    e = { [text] = 1 }
    learned[prev] = e
  end
  if max_succ then prune_successors(e, max_succ) end
  totals[prev] = recompute_total(e)
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
    push_window(env.window, pending[i], 1)
  end
end

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

local function store_of(env)
  return env.store or STORE
end

--- 直接上屏（无 select）
local function on_token(env, text)
  maybe_idle_reset(env)
  if is_context_breaker(text) then
    -- 标点/英文/超长：断开上下文，不保留旧前词
    if env.window_checkpoint then
      -- 组词中不应走这条；防御性清空窗口
    end
    env.window = {}
    return false
  end
  if is_stop_key(text) then
    -- 虚词不是有效 token：不入窗、不学习，但也不单独断句
    return false
  end
  if not is_learnable(text) then
    env.window = {}
    return false
  end
  local store = store_of(env)
  local prev = env.window[#env.window]
  if prev then
    learn_pair(store.learned, store.totals, prev, text, env.max_successors)
    store.dirty = true
  end
  env.window = { text }  -- 纯 bigram：只保留前一个有效词
  return true
end

--- 组词确认：立刻更新窗口供下一段打分；学习推迟到 commit
local function on_select(env, text, confirmed_pos)
  maybe_idle_reset(env)
  env._selected = true
  env._committed = false

  if is_context_breaker(text) then
    -- 选到标点等：断开，仍标记 selected 以便 commit 路径不走整句学习
    env.window = {}
    return false
  end
  if is_stop_key(text) then
    return false
  end
  if not is_learnable(text) then
    env.window = {}
    return false
  end

  env.pending_tokens = env.pending_tokens or {}
  env.pending_marks = env.pending_marks or {}
  if #env.pending_tokens == 0 then
    env.window_checkpoint = copy_window(env.window)
  end
  env.pending_tokens[#env.pending_tokens + 1] = text
  env.pending_marks[#env.pending_marks + 1] = confirmed_pos
  env.window = { text }
  return true
end

local function learn_pending(env)
  local pending = env.pending_tokens
  if not pending or #pending == 0 then return end
  local store = store_of(env)
  local prev
  if env.window_checkpoint and #env.window_checkpoint > 0 then
    prev = env.window_checkpoint[#env.window_checkpoint]
  end
  for i = 1, #pending do
    local text = pending[i]
    if prev then
      learn_pair(store.learned, store.totals, prev, text, env.max_successors)
      store.dirty = true
    end
    prev = text
  end
end

local function on_cancel(env)
  if env.window_checkpoint then
    env.window = env.window_checkpoint
  end
  clear_pending(env)
end

--- commit：若刚 select 过则落盘 pending；否则按整段 commit_text 保守处理
local function on_commit(env, text)
  -- keep_pending：超时只断「下一句」上下文，不丢本段已选词对
  maybe_idle_reset(env, nil, { keep_pending = true })
  env._committed = true
  if env._selected then
    learn_pending(env)
    clear_pending(env)
    -- 上屏文本含句读时断开，避免跨句当作相邻词
    if contains_sentence_punct(text) then
      env.window = {}
    end
  else
    -- 无可靠分段时：仅当整段本身是单个可学习 token 才学习；否则断开
    if is_learnable(text) then
      on_token(env, text)
    else
      env.window = {}
    end
  end
  local store = store_of(env)
  if store.dirty then
    store.dirty_commits = (store.dirty_commits or 0) + 1
  end
  env.commit_count = (env.commit_count or 0) + 1
  return env.commit_count
end

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
-- 评分：真正的 bigram P(w|prev)，不做后缀/拼接伪高阶
----------------------------------------------------------------------

local function bigram_pair_score(count, ctx_total, promote_min)
  if not count or count < (promote_min or DEFAULT_PROMOTE_MIN) then
    return 0
  end
  if not ctx_total or ctx_total <= 0 then return 0 end
  local p = count / (ctx_total + ALPHA)
  local conf = count / (count + CONF_K)
  return p * conf
end

local function score_candidates(candidates, window, learned, totals, scores, opts)
  for k in pairs(scores) do scores[k] = nil end
  opts = opts or {}
  local promote_min = opts.promote_min_count or DEFAULT_PROMOTE_MIN

  local prev = window and window[#window]
  if not prev or #prev == 0 then return end
  if is_stop_key(prev) then return end

  local e = learned[prev]
  if not e then return end
  local ctx_total = (totals and totals[prev]) or recompute_total(e)

  -- 同文字只计一次分，避免重复候选叠加
  local seen = {}
  for _, c in ipairs(candidates) do
    local w = c.text
    if w and not seen[w] then
      seen[w] = true
      local sc = bigram_pair_score(e[w], ctx_total, promote_min)
      if sc > 0 then scores[w] = sc end
    end
  end
end

local function cand_span_key(c)
  local s = c.start
  local e = c._end or c["end"]
  if type(s) == "number" and type(e) == "number" then
    return tostring(s) .. ":" .. tostring(e)
  end
  return ""
end

local function is_protected_cand(c)
  if not c then return true end
  local t = c.type
  if type(t) == "string" then
    local tl = t:lower()
    if tl == "emoji" or tl == "punct" or tl == "simplifier" then
      return true
    end
    -- 部分方案用 comment/type 标记置顶
    if tl:find("pin", 1, true) then return true end
  end
  local comment = c.comment
  if type(comment) == "string" then
    if comment:find("📌", 1, true) or comment:find("★", 1, true) then
      return true
    end
    if comment:find("^%[pin%]") or comment:find("^pin") then
      return true
    end
  end
  return false
end

--- 稳定重排：同 span 内提权；保护置顶/emoji；限制最大提权个数
local function reorder_batch(candidates, scores, threshold, opts)
  threshold = threshold or PROMOTE_SCORE
  opts = opts or {}
  local max_promote = opts.max_promote or DEFAULT_MAX_PROMOTE
  local protect_prefix = opts.protect_prefix or 0

  if not candidates or #candidates == 0 then
    return candidates, false
  end

  -- 按输入覆盖范围分组，不把不同 span 混排
  local groups = {}
  local order = {}
  for i, c in ipairs(candidates) do
    local key = cand_span_key(c)
    if not groups[key] then
      groups[key] = {}
      order[#order + 1] = key
    end
    groups[key][#groups[key] + 1] = { idx = i, cand = c }
  end

  local out = {}
  local any = false

  for _, key in ipairs(order) do
    local g = groups[key]
    -- 组内前缀 + 置顶/emoji 等标记：冻结，不参与模型提权
    local frozen, movable = {}, {}
    for gi, item in ipairs(g) do
      if gi <= protect_prefix or is_protected_cand(item.cand) then
        frozen[#frozen + 1] = item
      else
        movable[#movable + 1] = item
      end
    end

    local promoted, rest = {}, {}
    -- 同文字只允许第一次出现参与提权，避免重复累计
    local text_promoted = {}
    for _, item in ipairs(movable) do
      local w = item.cand.text
      local sc = (w and scores[w]) or 0
      if w and sc >= threshold and not text_promoted[w] then
        text_promoted[w] = true
        promoted[#promoted + 1] = item
      else
        rest[#rest + 1] = item
      end
    end

    if #promoted > 0 then
      table.sort(promoted, function(a, b)
        local sa = scores[a.cand.text] or 0
        local sb = scores[b.cand.text] or 0
        if sa ~= sb then return sa > sb end
        return a.idx < b.idx
      end)
      if #promoted > max_promote then
        for i = max_promote + 1, #promoted do
          rest[#rest + 1] = promoted[i]
        end
        table.sort(rest, function(a, b) return a.idx < b.idx end)
        local trimmed = {}
        for i = 1, max_promote do trimmed[i] = promoted[i] end
        promoted = trimmed
      end
      any = true
    end

    for _, item in ipairs(frozen) do out[#out + 1] = item.cand end
    for _, item in ipairs(promoted) do out[#out + 1] = item.cand end
    for _, item in ipairs(rest) do out[#out + 1] = item.cand end
  end

  if not any then
    return candidates, false
  end
  return out, true
end

----------------------------------------------------------------------
-- 存盘
----------------------------------------------------------------------

local function do_save(env)
  local store = store_of(env)
  if store.corrupt and not store.dirty then
    -- 损坏且无新学习：绝不覆盖原文件
    return false, "corrupt_clean"
  end
  if store.corrupt and store.dirty then
    -- 有新学习：写到旁路文件，保留损坏原件以便人工处理
    local side = (store.file or env.data_file) .. ".recovered"
    if env.decay_enabled then
      store.meta.decay_at = apply_time_decay(
        store.learned, env.decay_rate, store.meta.decay_at, os.time(), env.decay_period
      )
      store.totals = rebuild_totals(store.learned)
    end
    prune_store(store.learned, store.totals, env.max_contexts or DEFAULT_MAX_CTX,
      env.max_successors or DEFAULT_MAX_SUCC)
    store.meta.version = FORMAT_VERSION
    local ok, err = save(store.learned, side, store.meta)
    if ok then
      store.dirty_commits = 0
      -- dirty 保持 true，直到原文件问题被处理；避免下次再写主文件
      env.commit_count = 0
      return true, "recovered_side"
    end
    store.save_failures = (store.save_failures or 0) + 1
    return false, err
  end

  if not store.dirty and (env.commit_count or 0) == 0 then
    return true, "noop"
  end

  if env.decay_enabled then
    store.meta.decay_at = apply_time_decay(
      store.learned,
      env.decay_rate,
      store.meta.decay_at,
      os.time(),
      env.decay_period
    )
    store.totals = rebuild_totals(store.learned)
  elseif not store.meta.decay_at then
    store.meta.decay_at = os.time()
  end

  prune_store(store.learned, store.totals, env.max_contexts or DEFAULT_MAX_CTX,
    env.max_successors or DEFAULT_MAX_SUCC)
  store.meta.version = FORMAT_VERSION

  local ok, err = save(store.learned, store.file or env.data_file, store.meta)
  if ok then
    store.dirty = false
    store.dirty_commits = 0
    store.save_failures = 0
    env.commit_count = 0
    return true
  end
  store.save_failures = (store.save_failures or 0) + 1
  -- 失败保留 dirty，下次重试；旧 .bak / 原文件仍在
  return false, err
end

local function bind_store(env, data_file)
  if STORE.file and STORE.file ~= data_file and STORE.refs > 0 then
    -- 不同路径：该 env 使用独立局部 store（少见）
    local local_store = {
      file = data_file,
      learned = {},
      totals = {},
      meta = { version = FORMAT_VERSION },
      dirty = false,
      dirty_commits = 0,
      load_ok = true,
      corrupt = false,
      refs = 1,
      save_failures = 0,
    }
    ensure_file(data_file)
    local learned, meta, ok = load_data(data_file)
    local_store.learned = learned
    local_store.meta = meta
    local_store.meta.version = FORMAT_VERSION
    local_store.totals = rebuild_totals(learned)
    local_store.load_ok = ok
    local_store.corrupt = not ok
    env.store = local_store
    return local_store
  end

  if STORE.refs == 0 or STORE.file ~= data_file then
    STORE.file = data_file
    ensure_file(data_file)
    local learned, meta, ok = load_data(data_file)
    STORE.learned = learned
    STORE.meta = meta or { version = FORMAT_VERSION }
    STORE.totals = rebuild_totals(learned)
    STORE.load_ok = ok
    STORE.corrupt = not ok
    STORE.dirty = false
    STORE.dirty_commits = 0
  end
  STORE.refs = STORE.refs + 1
  env.store = STORE
  return STORE
end

local function unbind_store(env)
  local store = env.store
  if not store then return end
  if store == STORE then
    STORE.refs = math.max(0, (STORE.refs or 1) - 1)
  end
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
  env.idle_timeout_sec = cfg_get(config, ns, "idle_timeout_sec", "get_int") or DEFAULT_IDLE
  env.max_contexts = cfg_get(config, ns, "max_contexts", "get_int") or DEFAULT_MAX_CTX
  env.max_successors = cfg_get(config, ns, "max_successors", "get_int") or DEFAULT_MAX_SUCC
  env.promote_min_count = cfg_get(config, ns, "promote_min_count", "get_int") or DEFAULT_PROMOTE_MIN
  env.max_promote = cfg_get(config, ns, "max_promote", "get_int") or DEFAULT_MAX_PROMOTE
  env.protect_prefix = cfg_get(config, ns, "protect_prefix", "get_int") or 0

  bind_store(env, env.data_file)

  env.window = {}
  env.scores = {}
  env.commit_count = 0
  env._selected = false
  env.pending_tokens = {}
  env.pending_marks = {}
  env._in_commit = false
  env._committed = false
  env.last_activity = os.time()

  -- 兼容旧测试字段
  env.learned = env.store.learned
  env.decay_at = env.store.meta.decay_at

  local ctx = env.engine.context

  -- group 0 先于未分组引擎回调，避免 composition 推进后丢失刚选中的词
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
    local store = store_of(env)
    local interval_n = env.save_interval or 30
    if interval_n <= 0 then
      do_save(env)
    elseif store.dirty_commits >= interval_n or env.commit_count >= interval_n then
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
  -- fini 不可作为唯一落盘手段；尽力刷盘，失败则保留 dirty（进程退出仍可能丢未达 save_interval 的变更）
  local store = store_of(env)
  if store and (store.dirty or (env.commit_count and env.commit_count > 0)) then
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
  unbind_store(env)
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

  -- 无有效前文或该前词无统计：尽早透传，不预取
  local prev = env.window and env.window[#env.window]
  local store = store_of(env)
  local has_ctx = prev and #prev > 0 and store.learned[prev] ~= nil

  if limit <= 0 or not has_ctx then
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

  score_candidates(batch, env.window, store.learned, store.totals, env.scores, {
    promote_min_count = env.promote_min_count,
  })
  local ordered = reorder_batch(batch, env.scores, PROMOTE_SCORE, {
    max_promote = env.max_promote,
    protect_prefix = env.protect_prefix,
  })
  for _, cand in ipairs(ordered) do
    yield(cand)  -- 原始候选对象，不重建
  end

  local cand = next_cand()
  while cand do
    yield(cand)
    cand = next_cand()
  end
end

--- 测试辅助：重置模块级 STORE
local function reset_store_for_tests()
  STORE.file = nil
  STORE.learned = {}
  STORE.totals = {}
  STORE.meta = { version = FORMAT_VERSION }
  STORE.dirty = false
  STORE.dirty_commits = 0
  STORE.load_ok = true
  STORE.corrupt = false
  STORE.refs = 0
  STORE.save_failures = 0
end

return {
  init = init,
  fini = fini,
  func = filter,
  tags_match = tags_match,
  -- 常量
  FORMAT_VERSION = FORMAT_VERSION,
  PROMOTE_SCORE = PROMOTE_SCORE,
  -- 测试导出
  utf8_char_count = utf8_char_count,
  has_cjk_ideograph = has_cjk_ideograph,
  is_learnable = is_learnable,
  is_stop_key = is_stop_key,
  is_context_breaker = is_context_breaker,
  serialize = serialize,
  load_data = load_data,
  save = save,
  decay_learned = decay_learned,
  apply_time_decay = apply_time_decay,
  score_candidates = score_candidates,
  reorder_batch = reorder_batch,
  bigram_pair_score = bigram_pair_score,
  on_token = on_token,
  on_select = on_select,
  on_commit = on_commit,
  on_cancel = on_cancel,
  on_composition_update = on_composition_update,
  revert_last_select = revert_last_select,
  sync_pending = sync_pending,
  do_save = do_save,
  resolve_data_path = resolve_data_path,
  rebuild_totals = rebuild_totals,
  prune_store = prune_store,
  bind_store = bind_store,
  reset_store_for_tests = reset_store_for_tests,
  STORE = STORE,
  -- 兼容旧测试名（已移除伪高阶后缀）
  utf8_last = function(s, n)
    -- 保留最小实现供旧测试；新模型不再用于打分
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
  end,
}
