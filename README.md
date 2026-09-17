# 个人 Rime Lua 脚本

个人维护的 [Rime](https://rime.im) Lua 脚本仓库。脚本彼此独立，按需安装；后续新脚本也放在这里。

[![CI](https://github.com/sakuradairong/rime-lua-scripts/actions/workflows/ci.yml/badge.svg)](https://github.com/sakuradairong/rime-lua-scripts/actions/workflows/ci.yml)

## 脚本目录

| 脚本 | 作用 | 激活 |
|---|---|---|
| [`rime_context_filter`](#rime_context_filter) | 根据组词时刚确认的词，调整后续候选顺序 | `lua_filter@*rime_context_filter` |

## 安装

### 手动安装

把 `lua/` 下需要的 `.lua` 复制到 RIME 用户目录的 `lua/`：

| 平台 | 路径 |
|---|---|
| **Windows (Weasel)** | `%APPDATA%\Rime\lua\` |
| **macOS (Squirrel)** | `~/Library/Rime/lua/` |
| **Linux (ibus/fcitx5)** | `~/.config/ibus/rime/lua/` 或 `~/.local/share/fcitx5/rime/lua/` |
| **Android (Trime)** | `/storage/emulated/0/rime/lua/` |

然后按各脚本说明，在方案的 `.custom.yaml` 里激活，并重新部署。

### Plum

```bash
bash rime-install sakuradairong/rime-lua-scripts
```

这会把 `lua/` 下全部脚本装进用户目录。仍需在方案中逐个激活。

## 新增脚本

1. 脚本放到 `lua/<name>.lua`
2. 测试放到 `tests/test_<name>.lua`
3. 在上方目录表和本文对应小节补说明

CI 会自动 lint `lua/`、并跑 `tests/test_*.lua`。

---

## rime_context_filter

RIME 个人本地**词级二元模型**过滤器。在正常选词／上屏中学习「前词 → 当前词」，之后在相同前文下适度提前常选候选。不替代原生用户词典（造词、调频、删词仍由 Rime 负责）。

### 原理

- **真正的 bigram**：只按相邻两个有效 token 计次与打分；不做字符串后缀匹配或拼接伪高阶
- **分数**：`P(当前|前词)`（加性平滑）× 搭配置信度；低置信度保持原序
- **落盘 ≠ 提权**：`count >= 1` 即持久化；默认至少 2 次且分数过门槛才提权
- **分段学习**：对齐 select；Esc／退格不学习；标点／英文／超时断开上下文
- **轻量**：热路径无磁盘 I/O；无有效前文时直接透传
- **安全落盘**：写 `.tmp` → 校验 → 主文件改名 `.bak` → 再替换；失败保留旧数据并可重试

### 效果

组词中先确认「接下来的」，再输入 `renwu`：约两次以上稳定选择「任务」后，「任务」会在相同前文下被提前。单次出现只记统计，不置顶。

### 激活

必须追加到 `engine/filters` **末尾**（`uniquifier` 之后）。

**雾凇拼音 (rime_ice)**——编辑 `rime_ice.custom.yaml`：

```yaml
patch:
  engine/filters/+:
    - lua_filter@*rime_context_filter
```

不要使用 `"engine/filters/@after 6"`：会插到 `pin_cand_filter` / emoji / 简繁 / `uniquifier` 之前，可能打乱置顶与去重。脚本对 ★／📌／emoji type 有保护，但不能替代正确的 filter 顺序。

### 重新部署

- **Windows**: 右键托盘图标 → 重新部署
- **macOS**: 点击菜单栏鼠须管图标 → 重新部署
- **Linux**: `ibus-daemon -drx` 或重启 fcitx5
- **Android**: 重新部署 Trime

### 配置

```yaml
patch:
  rime_context_filter:
    save_interval: 30
    data_path: ""
    decay_enabled: true
    decay_rate: 0.95
    decay_period_days: 1
    reorder_limit: 80
    idle_timeout_sec: 120
    max_contexts: 4000
    max_successors: 48
    promote_min_count: 2
    max_promote: 5
    protect_prefix: 0
```

也兼容命名空间 `context_filter:`。

| 参数 | 默认 | 说明 |
|---|---|---|
| `save_interval` | 30 | 每 N 次上屏存盘；`0` 表示每次上屏都存 |
| `data_path` | 用户目录 | 自定义数据文件完整路径 |
| `decay_*` | 见上 | 按自然日衰减，与打字频率无关 |
| `reorder_limit` | 80 | 只重排前 N 个；`≤0` 禁用重排 |
| `idle_timeout_sec` | 120 | 空闲超过该秒数清空前文（`os.time`） |
| `max_contexts` / `max_successors` | 4000 / 48 | 容量上限，超出淘汰低频 |
| `promote_min_count` | 2 | 提权所需最少搭配次数 |
| `max_promote` | 5 | 每个输入范围内最多提前几个候选 |
| `protect_prefix` | 0 | 每个输入范围内前 N 个候选冻结（可配合置顶） |

### 数据文件

`context_learned.data`（由 `rime_api.get_user_data_dir()` 定位）。同步冲突文件（`*.sync-conflict*`）**不会**自动删除或合并。

```lua
return {
  _meta={version=7,decay_at=1735689600,saved_at=1735689600},
  data={
    ["接下来的"]={["任务"]=8,["工作"]=3},
    ["完成"]={["任务"]=1},
  },
}
```

可读取 v5 扁平格式与 v6（`_meta`+`data` 无 version）。首次保存会写成 v7。旧版曾丢弃 `count==1` 的搭配，那些记录无法无损恢复。

损坏文件：不静默用空表覆盖；若损坏后仍有新学习，写入旁路 `context_learned.data.recovered`。

### 工作原理（简）

```
select (group 0) → 更新窗口，词对暂存
update           → 退格回滚 / Esc 取消（不学习）
commit           → 落成 bigram；达 save_interval 则存盘
filter           → 仅 P(w|prev)×置信度；同 span 内稳定提权；yield 原 Candidate
```

不把模型分加到 Rime `quality`。整句无分段直接上屏时：仅当整段本身是单个可学习词才学习，否则断开。

### 版本历史

- **v7** — 词级 bigram + 平滑／置信度；`count>=1` 落盘；原子保存与损坏保护；模块级共享存储；标点／超时断上下文；span／置顶／去重保护；容量上限
- **v6** — 按 select 分段学习、`get_user_data_dir`、notifier 持有、按日衰减
- **v5.1 / v5 / v4 …** — 路径、沙箱、Lua 持久化等早期能力

---

## 开发

需要 Lua 5.3+ 或 LuaJIT：

```bash
lua tests/test_rime_context_filter.lua
```

测试覆盖：词级 bigram、落盘/提权分离、分段学习与取消、标点与空闲超时、span/置顶/去重、原子保存与损坏旁路、`.bak` 恢复、多实例共享存储、容量淘汰、候选对象身份、热路径性能。

每次推送自动运行：
- `luacheck` 静态分析 `lua/` 与 `tests/`
- 跨 Lua 5.3 / LuaJIT / Lua 5.1 跑全部 `tests/test_*.lua`

## License

MIT
