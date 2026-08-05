-- rime_context_filter.lua
-- 纯学习的上下文调频引擎（v5 — 跨平台 + 衰减 + 安全）
--
-- 学习：自动记录「上屏的前文 → 当前选的词」的共现关系
-- 匹配：根据当前上下文对候选词加权，越相关的越靠前
-- 持久化：数据以 Lua 表字面量格式存到
--         context_learned.data（路径因平台而异）
--         由 Lua VM 原生加载，不需要逐行 regex 解析
--
-- 配置（可选，写入 rime_ice.custom.yaml patch: 下）：
--   context_filter:
--     save_interval: 30      # 每 N 次提交存一次盘（默认 30）
--     data_path: /自定义/path/context_learned.data  # 自定义数据路径，优先级最高
--     decay_enabled: true    # 是否启用衰减（默认 true）
--     decay_rate: 0.95       # 每次保存时的衰减因子（默认 0.95）
--
-- 激活：
--   "engine/filters/@after 6":
--     lua_filter@*rime_context_filter

----------------------------------------------------------------------
-- 跨平台路径解析
----------------------------------------------------------------------

local function get_data_path(env)
  local config = env.engine.schema.config
  local custom = config:get_string(env.name_space .. "/data_path")
  if custom and #custom > 0 then return custom end

  local sep = package.config:sub(1,1)
  if sep == "\\" then
    return (os.getenv("APPDATA") or "") .. sep .. "Rime" .. sep .. "context_learned.data"
  end
  -- macOS: ~/Library/Rime/（检测目录或通过 sw_vers 确认平台）
  local home = os.getenv("HOME") or ""
  if os.execute('test -d "' .. home .. '/Library/Rime" 2>/dev/null') == 0 then
    return home .. "/Library/Rime/context_learned.data"
  end
  -- 首次部署时 ~/Library/Rime/ 可能尚未创建，通过 macOS 独有文件确认
  if os.execute('test -f /usr/bin/sw_vers 2>/dev/null') == 0 then
    return home .. "/Library/Rime/context_learned.data"
  end

  -- Linux: 优先 XDG_DATA_HOME
  local xdg = os.getenv("XDG_DATA_HOME")
  if xdg and #xdg > 0 then
    return xdg .. "/rime/context_learned.data"
  end
  -- Linux fallback: $HOME/.local/share/rime/
  return home .. "/.local/share/rime/context_learned.data"
end

----------------------------------------------------------------------
-- 持久化 — Lua 表字面量格式
----------------------------------------------------------------------

local function esc(s)
  -- Lua 字符串字面量转义（中文不包含需要转义的字符，聊备一格）
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

--- 将内存数据序列化为 Lua 源码
--- 格式：
---   return {
---     ["前文"]={["词"]=5,["词2"]=3},
---     ["前文2"]={["词"]=2},
---   }
local function serialize(data)
  local buf = { "return {\n" }
  for ctx, words in pairs(data) do
    local first = true
    buf[#buf + 1] = "  [" .. esc(ctx) .. "]={"
    for word, count in pairs(words) do
      if count > 1 then  -- 写入时即剪枝
        if first then first = false else buf[#buf + 1] = "," end
        buf[#buf + 1] = "[" .. esc(word) .. "]=" .. count
      end
    end
    if first then
      buf[#buf] = nil  -- 该前文没有有效词条，跳过
    else
      buf[#buf + 1] = "},\n"
    end
  end
  buf[#buf + 1] = "}\n"
  return table.concat(buf)
end

--- 用 Lua VM 原生加载数据文件（无逐行 regex）
--- 沙箱环境防止数据文件执行恶意代码
local function load_data(data_file)
  local f = io.open(data_file, "r")
  if not f then return {} end

  local content = f:read("*a")
  f:close()
  if not content or #content == 0 then return {} end

  local safe_env = {}
  local loader

  if _VERSION == "Lua 5.1" then
    -- Lua 5.1: load() accepts function only; loadstring for string chunks
    loader = loadstring(content, "@" .. data_file)
    if loader then
      io.stderr:write("[rime-context-filter] WARNING: " ..
        "Sandbox unavailable on Lua 5.1. " ..
        "Data file could access global environment.\n")
    end
  else
    -- Lua 5.3+: load(chunk, name, mode, env) with sandbox
    loader = load(content, "@" .. data_file, "t", safe_env)
    if not loader then
      -- Fallback for embedders without 4-arg load
      loader = load(content, "@" .. data_file)
      if loader then
        io.stderr:write("[rime-context-filter] WARNING: " ..
          "Sandbox unavailable, data file could access global environment.\n")
      end
    end
  end

  if not loader then return {} end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

--- 原子重写整个文件
local function save(data, data_file)
  local tmp = data_file .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(serialize(data))
  f:close()
  os.remove(data_file)
  os.rename(tmp, data_file)
  return true
end

----------------------------------------------------------------------
-- 跨平台目录确保
----------------------------------------------------------------------

local function ensure_dir(path)
  local is_win = package.config:sub(1,1) == "\\"
  if is_win then
    local dir = path:match("^(.+)\\[^\\]+$")
    if dir then os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '"') end
  else
    local dir = path:match("^(.+)/([^/]+)$")
    if dir then
      os.execute("mkdir -p '" .. dir:gsub("\\", "/") .. "' 2>/dev/null")
    end
  end
end

--- 确保文件和目录存在
local function ensure_file(data_file)
  local f = io.open(data_file, "a")
  if f then f:close(); return end
  ensure_dir(data_file)
  f = io.open(data_file, "w")
  if f then f:write("return {}\n"); f:close() end
end

----------------------------------------------------------------------
-- 衰减 / 遗忘机制
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

----------------------------------------------------------------------
-- UTF-8 安全截取（按字符边界，非字节）
----------------------------------------------------------------------

--- 安全截取字符串末尾 N 个字符
local function utf8_last(s, n)
  local len = #s
  if len == 0 then return s end
  local pos = len + 1
  for _ = 1, n do
    if pos <= 1 then break end
    pos = pos - 1
    -- 跳过 utf-8 连续字节 (0x80-0xBF)
    while pos > 1 and s:byte(pos) >= 0x80 and s:byte(pos) < 0xC0 do
      pos = pos - 1
    end
  end
  if pos < 1 then pos = 1 end
  return s:sub(pos)
end

--- 按 UTF-8 字符计数（非字节）
local function utf8_char_count(s)
  local count, i, len = 0, 1, #s
  while i <= len do
    local b = s:byte(i)
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

----------------------------------------------------------------------
-- 上下文评分（热路径）
----------------------------------------------------------------------

local function score_candidates(candidates, window, learned, scores)
  -- 清空复用表
  for k in pairs(scores) do scores[k] = nil end

  local last = window[#window]
  if not last or #last == 0 then return end

  local function apply_weight(key, weight)
    local e = learned[key]
    if not e then return end
    for _, c in ipairs(candidates) do
      local w = c.text
      if e[w] then
        scores[w] = (scores[w] or 0) + e[w] * weight
      end
    end
  end

  apply_weight(last, 1.0)
  if utf8_char_count(last) >= 2 then apply_weight(utf8_last(last, 2), 0.5) end
  if utf8_char_count(last) >= 1 then apply_weight(utf8_last(last, 1), 0.25) end
  if #window >= 2 then
    apply_weight(window[#window - 1] .. last, 0.4)
  end
end

----------------------------------------------------------------------
-- 组件入口
----------------------------------------------------------------------

local function do_save(env, with_decay)
  if with_decay and env.decay_enabled then
    decay_learned(env.learned, env.decay_rate)
  end
  save(env.learned, env.data_file)
  env.commit_count = 0
end

local function init(env)
  env.name_space = env.name_space:gsub("^*", "")
  local config = env.engine.schema.config

  -- 跨平台数据路径
  env.data_file = get_data_path(env)

  local interval = config:get_int(env.name_space .. "/save_interval")
  env.save_interval = (interval ~= nil) and interval or 30

  -- 衰减配置
  env.decay_enabled = config:get_bool(env.name_space .. "/decay_enabled")
  if env.decay_enabled == nil then env.decay_enabled = true end
  env.decay_rate = tonumber(config:get_string(env.name_space .. "/decay_rate")) or 0.95

  -- 上下文窗口（最近 3 次上屏）
  env.window = {}

  -- 加载历史数据
  ensure_file(env.data_file)
  env.learned = load_data(env.data_file)

  env.scores = {}
  env.commit_count = 0

  -- 监听提交
  env.engine.context.commit_notifier:connect(function(ctx)
    local text = ctx:get_commit_text()
    if not text or #text == 0 then return end

    local prev = env.window[#env.window]
    if prev and #prev > 0 then
      local e = env.learned[prev]
      if e then
        e[text] = (e[text] or 0) + 1
      else
        env.learned[prev] = { [text] = 1 }
      end
    end

    -- 更新窗口
    env.window[#env.window + 1] = text
    if #env.window > 3 then
      table.remove(env.window, 1)
    end

    -- 批量存盘
    env.commit_count = env.commit_count + 1
    if env.commit_count >= env.save_interval then
      do_save(env, true)
    end
  end)
end

local function fini(env)
  if env.commit_count > 0 then
    do_save(env, false)
  end
end

local function filter(input, env)
  local candidates = {}
  for cand in input:iter() do
    candidates[#candidates + 1] = cand
  end
  if #candidates == 0 then return end

  score_candidates(candidates, env.window, env.learned, env.scores)
  local scores = env.scores

  -- 阈值 2.0（同一搭配选 2 次以上才生效）
  local max_score = 0
  for _, v in pairs(scores) do
    if v > max_score then max_score = v end
  end
  if max_score < 2.0 then
    for _, cand in ipairs(candidates) do yield(cand) end
    return
  end

  -- 提权降序，同权保持原序
  local order = {}
  for i = 1, #candidates do order[i] = i end
  table.sort(order, function(a, b)
    local sa = scores[candidates[a].text] or 0
    local sb = scores[candidates[b].text] or 0
    if sa ~= sb then return sa > sb end
    return a < b
  end)
  for _, idx in ipairs(order) do
    yield(candidates[idx])
  end
end

return {
  init = init,
  fini = fini,
  func = filter,
  -- 以下仅用于测试
  utf8_last = utf8_last,
  utf8_char_count = utf8_char_count,
  serialize = serialize,
  load_data = load_data,
  save = save,
  decay_learned = decay_learned,
  score_candidates = score_candidates,
  do_save = do_save,
}
