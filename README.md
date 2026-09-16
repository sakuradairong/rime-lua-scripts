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

RIME 输入法上下文调频过滤器。根据组词过程中刚确认的词，自动调整后续候选顺序。

### 原理

监听组词时的 **select**（空格确认当前词），记录「刚确认的词 → 下一个词」。之后在同样前文下，把对应候选提前到首页，其余顺序不变。

- **按词学习**：对齐 RIME 组词分段，而不是整句上屏
- **跨会话**：学习数据写在 RIME 用户目录，重启不丢
- **轻量**：只重排前 N 个候选，热路径无文件 I/O
- **跨平台**：通过 `rime_api.get_user_data_dir()` 定位用户目录
- **安全**：数据文件在沙箱中加载
- **按日遗忘**：长期不用的搭配按自然日衰减，打字多不会加速遗忘

### 效果

在组词中先确认「接下来的」，再输入 `renwu`：

| 输入 | 第一次 | 多次选择后 |
|---|---|---|
| `接下来的` + `renwu` | 人物 1. 任务 2. 人物 | 任务 1. 任务 2. 人物 |
| `那个` + `renwu` | 任务 1. 人物 2. 任务 | 人物 1. 人物 2. 任务 |
| `完成` + `renwu` | — | 任务 自动提前 |

一次把整句上屏时，过长的句子不会写入学习数据，避免污染。组词中途按 Esc 取消、或退格撤销刚确认的词，都不会留下半成品。

### 激活

必须追加到 `engine/filters` **末尾**（`uniquifier` 之后），避免打乱置顶、长词优先、简繁和去重。

**雾凇拼音 (rime_ice)**——编辑 `rime_ice.custom.yaml`：

```yaml
patch:
  engine/filters/+:
    - lua_filter@*rime_context_filter
```

**朙月拼音**——编辑 `luna_pinyin.custom.yaml`：

```yaml
patch:
  engine/filters/+:
    - lua_filter@*rime_context_filter
```

不要使用 `"engine/filters/@after 6"`：雾凇当前有 11 个 filter，插在中间会覆盖 `pin_cand_filter` 的置顶。

### 重新部署

- **Windows**: 右键托盘图标 → 重新部署
- **macOS**: 点击菜单栏鼠须管图标 → 重新部署
- **Linux**: `ibus-daemon -drx` 或重启 fcitx5
- **Android**: 重新部署 Trime

### 配置

写入方案 patch（键名与 lua 组件命名空间一致，也兼容 `context_filter`）：

```yaml
patch:
  rime_context_filter:
    save_interval: 30      # 每 N 次上屏存一次盘（默认 30）
    data_path: ""          # 自定义数据路径；为空则用用户目录
    decay_enabled: true    # 是否按日衰减（默认 true）
    decay_rate: 0.95       # 每个衰减周期的乘数（默认 0.95）
    decay_period_days: 1   # 衰减周期天数（默认 1）
    reorder_limit: 80      # 只重排前 N 个候选（默认 80）
```

#### 参数说明

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `save_interval` | 整数 | 30 | 每 N 次提交写一次磁盘。可设为 0 每次上屏都存盘 |
| `data_path` | 字符串 | 自动 | 自定义数据文件完整路径。设置后覆盖用户目录 |
| `decay_enabled` | 布尔 | true | 启用后，旧数据的权重按自然日降低 |
| `decay_rate` | 浮点数 | 0.95 | 每个衰减周期所有计数的乘数（0 < rate < 1） |
| `decay_period_days` | 整数 | 1 | 多少天衰减一次。打字频率不影响衰减速度 |
| `reorder_limit` | 整数 | 80 | 只对前 N 个候选评分和提前，其余原样输出；设为 0 或负数时禁用重排并原样输出 |

#### 衰减行为

`decay_rate = 0.95`、每天衰减一次时：

| 初始计数 | 10 天后 | 20 天后 | 40 天后 | 消亡阈值 (≈1.1) |
|---|---|---|---|---|
| 1 | 已消亡 | — | — | 1 天 |
| 3 | 1.79 | 1.07 → 已消亡 | — | ~20 天 |
| 5 | 2.99 | 1.79 | 0.64 → 已消亡 | ~32 天 |
| 10 | 5.99 | 3.58 | 2.15 | ~44 天 |
| 50 | 29.9 | 17.9 | 6.43 | ~76 天 |

频率越高的搭配保留越久。一天打一万次也不会比一天打一百次忘得更快。

### 数据文件

学习数据存储为用户目录下的 `context_learned.data`，路径由 RIME 提供的用户目录决定：

| 平台 | 典型路径 |
|---|---|
| **Windows** | `%APPDATA%\Rime\context_learned.data` |
| **macOS** | `~/Library/Rime/context_learned.data` |
| **Linux (fcitx5)** | `~/.local/share/fcitx5/rime/context_learned.data` |
| **Linux (ibus)** | `~/.config/ibus/rime/context_learned.data` |
| **Android (Trime)** | `/storage/emulated/0/rime/context_learned.data` |

也可以配置 `data_path` 指定任意路径。备份用户目录时会一并带走学习数据。

#### 文件格式

```lua
return {
  _meta={decay_at=1735689600},
  data={
    ["接下来的"]={["任务"]=8,["工作"]=3},
    ["完成"]={["任务"]=5},
  },
}
```

仍能读取旧版扁平格式（无 `_meta`/`data` 包装）。

#### 安全性

数据文件在**沙箱环境**中加载。Lua 5.1 / LuaJIT 使用 `setfenv`；Lua 5.3+ 使用 `load(..., "t", env)`。恶意构造的数据文件无法访问 `os`、`io` 等系统库。

### 工作原理

#### 学习粒度

```
select_notifier(group 0) ← 在引擎推进 composition 前捕获当前词（空格确认）
  ├─ 过滤：过长整句 / 纯英文 / 标点 / 的了是…
  ├─ 立刻更新上下文窗口（供下一段打分）
  └─ 词对暂存，等到真正上屏再写入

update_notifier
  ├─ 退格：按已确认分段数弹出窗口中的半成品
  └─ Esc：整段回滚，不学习

commit_notifier   ← 文本真正上屏
  ├─ 把本段词对写入 learned（整句不再当 token）
  └─ 达到 save_interval 则存盘
```

过滤器只处理带 `abc` 标签的分段（拼音等），不改动 Emoji、反查、数字。

每次出候选时，从窗口提取最多 4 种 key 加权查询。虚词（的、了、是…）不会作为 suffix key，避免「好的」把「朋友」提前。

| Key | 权重 | 示例 |
|---|---|---|
| 精确前文 | 1.0 | `"接下来的"` |
| 末尾 2 字 | 0.5 | `"来的"`（前文 `"接下来的"` 时；虚词 key 会跳过） |
| 末尾 1 字 | 0.25 | 若为「的」则跳过 |
| 双词组合 | 0.4 | `"完成接下来的"` |

四个 key 的得分加权求和，单个候选 ≥ 2.0 才提前（约 2–3 次选择后生效）。未达阈值的候选保持原序，置顶词不会被整表排序打乱。

#### 持久化

数据以 **Lua 源码格式** 存储。写入使用原子重写（`.tmp` + `rename`）。退出时 `fini` 会刷盘未保存的学习，并断开 notifier，避免回调泄漏。

#### 衰减 / 遗忘

按 `decay_period_days`（默认每天）对全部计数乘以 `decay_rate`。与保存次数、上屏次数无关。

### 版本历史

- **v6** — 按 select 分段学习（整句不上窗）、`get_user_data_dir` 存盘、notifier 持有 connection、只提前高分候选、虚词不作为 key、按自然日衰减、过滤器放到 uniquifier 之后；退格回滚窗口、上屏后不误取消、新旧数据格式用 `_meta`+`data` 判定
- **v5.1** — 修复 Linux 数据路径、UTF-8 按字符截取、Lua 5.3 序列化兼容、scores 表复用减 GC、单元测试 + CI
- **v5** — 跨平台路径自动检测、衰减遗忘机制、沙箱安全加载、热路径 GC 优化
- **v4** — Lua 源码持久化格式（移除 JSON 依赖）
- **v3** — 增量缓冲 + 批量写入
- **v2** — 上下文窗口 + 4 种 key 加权查询
- **v1** — 初版

---

## 开发

需要 Lua 5.3+ 或 LuaJIT：

```bash
lua tests/test_rime_context_filter.lua
```

测试覆盖：分段学习、select/commit 去重、退格回滚、Esc 与上屏后的 composition 更新、虚词过滤、评分聚合、按日衰减、序列化新旧格式（含旧文件带 `data` 键）、受限重排、路径解析。

每次推送自动运行：
- `luacheck` 静态分析 `lua/` 与 `tests/`
- 跨 Lua 5.3 / LuaJIT / Lua 5.1 跑全部 `tests/test_*.lua`

## License

MIT
