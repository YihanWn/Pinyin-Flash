-- core.lua — 拼音跳转核心逻辑
-- 按拼音首字母定位可见区域的中文和英文，类似 flash.nvim 的打标签跳转
-- s + <letter> → 同时搜英文单词首字母和拼音首字母汉字

local pinyin_map = require("pinyin_flash.pinyin_map")

local M = {}

-- extmark 命名空间，用来显示标签和做清理
local ns_id = vim.api.nvim_create_namespace("pinyin_flash_ns")

-- ── 拼音首字母缓存 ────────────────────────────────────────────
-- 缓存已经查过的字符 codepoint → 拼音首字母 (a-z)
-- 用 __index 做延迟填充，不影响没有拼音的字（返回 false）
local initial_cache = setmetatable({}, {
  __index = function(t, cp)
    local pinyins = pinyin_map[cp]
    if not pinyins or #pinyins == 0 then
      rawset(t, cp, false)
      return false
    end
    -- 多音字只用第一个读音的首字母
    local initial = pinyins[1]:sub(1, 1)
    rawset(t, cp, initial)
    return initial
  end,
})

--- 查询一个汉字的拼音首字母（公开接口，方便调试）
---@param cp number Unicode codepoint
---@return string|nil
function M.get_initial(cp)
  return initial_cache[cp]
end

-- ── 高亮组（只创建一次） ──────────────────────────────────────
local highlights_setup = false
local function ensure_highlights()
  if highlights_setup then return end
  highlights_setup = true
  vim.cmd([[highlight default PinyinFlashLabel guifg=#ffffff guibg=#e74c3c gui=bold ctermfg=white ctermbg=red cterm=bold]])
  vim.cmd([[highlight default PinyinFlashLabelEn guifg=#ffffff guibg=#e67e22 gui=bold ctermfg=white ctermbg=208 cterm=bold]])
  vim.cmd([[highlight default PinyinFlashPrompt guifg=#61afef gui=bold ctermfg=blue cterm=bold]])
  vim.cmd([[highlight default PinyinFlashMatch guifg=#e74c3c gui=underline ctermfg=red cterm=underline]])
end

-- ── UTF-8 工具 ────────────────────────────────────────────────
-- 在字符串 s 的 pos 位置（1-based byte offset）解码一个 UTF-8 字符
-- 返回: codepoint, byte_length, next_pos
local function decode_utf8_at(s, pos)
  local b1 = s:byte(pos)
  if not b1 then return nil, 0, pos + 1 end

  if b1 < 0x80 then
    return b1, 1, pos + 1
  elseif b1 < 0xE0 then
    local b2 = s:byte(pos + 1)
    if not b2 then return nil, 1, pos + 2 end
    return ((b1 - 0xC0) * 0x40) + (b2 - 0x80), 2, pos + 2
  elseif b1 < 0xF0 then
    local b2, b3 = s:byte(pos + 1, pos + 2)
    if not b2 or not b3 then return nil, 1, pos + (b2 and 2 or 1) end
    local cp = ((b1 - 0xE0) * 0x1000) + ((b2 - 0x80) * 0x40) + (b3 - 0x80)
    return cp, 3, pos + 3
  else
    local b2, b3, b4 = s:byte(pos + 1, pos + 3)
    if not b2 or not b3 or not b4 then return nil, 1, pos + (b3 and 3 or (b2 and 2 or 1)) end
    local cp = ((b1 - 0xF0) * 0x40000) + ((b2 - 0x80) * 0x1000) + ((b3 - 0x80) * 0x40) + (b4 - 0x80)
    return cp, 4, pos + 4
  end
end

-- 判断 codepoint 是否属于常用汉字范围
local function is_cjk(cp)
  return (cp >= 0x4E00 and cp <= 0x9FFF)      -- CJK 统一表意文字
      or (cp >= 0x3400 and cp <= 0x4DBF)      -- CJK 扩展 A
      or (cp >= 0x20000 and cp <= 0x2A6DF)    -- CJK 扩展 B
      or (cp >= 0x2A700 and cp <= 0x2B73F)    -- CJK 扩展 C
      or (cp >= 0x2B740 and cp <= 0x2B81F)    -- CJK 扩展 D
      or (cp >= 0x2B820 and cp <= 0x2CEAF)    -- CJK 扩展 E
      or (cp >= 0x2CEB0 and cp <= 0x2EBEF)    -- CJK 扩展 F
      or (cp >= 0x30000 and cp <= 0x3134F)    -- CJK 扩展 G
      or (cp >= 0x31350 and cp <= 0x323AF)    -- CJK 扩展 H
      or (cp >= 0xF900 and cp <= 0xFAFF)      -- CJK 兼容表意文字
      or (cp >= 0x2F800 and cp <= 0x2FA1F)    -- CJK 兼容表意文字补充
end

-- ── 收集可见中文字符 ──────────────────────────────────────────
-- 返回: { cp, char, lnum, byte_col, byte_len, initial, kind="cn" }[]
function M.collect_cn()
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local top = vim.fn.line("w0")
  local bottom = vim.fn.line("w$")

  local results = {}
  for lnum = top, bottom do
    local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
    local line = lines[1]
    if line and #line > 0 then
      local pos = 1
      while pos <= #line do
        local cp, len, next_pos = decode_utf8_at(line, pos)
        if not cp then
          pos = next_pos
        elseif is_cjk(cp) then
          local initial = initial_cache[cp]
          if initial then
            table.insert(results, {
              cp = cp,
              char = line:sub(pos, pos + len - 1),
              lnum = lnum,
              byte_col = pos,         -- 1-based byte column
              byte_len = len,
              initial = initial,
              kind = "cn",
            })
          end
          pos = next_pos
        else
          pos = next_pos
        end
      end
    end
  end
  return results
end

-- ── 收集可见英文字符（支持多字符搜索） ──────────────────────────
-- 在可见区域中找所有匹配 search_str 的英文/数字/符号位置
-- 行为类似 flash.nvim 的原生 s 键：多字符增量搜索
-- 跳过中文汉字，避免与 collect_cn 重复
-- 返回: { char, lnum, byte_col, byte_len, pattern, kind="en" }[]
function M.collect_en(search_str)
  if not search_str or #search_str == 0 then return {} end

  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local top = vim.fn.line("w0")
  local bottom = vim.fn.line("w$")
  local lower_search = search_str:lower()
  local search_len = #search_str

  local results = {}
  for lnum = top, bottom do
    local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
    local line = lines[1]
    if line and #line >= search_len then
      local pos = 1
      while pos <= #line - search_len + 1 do
        local cp, len, next_pos = decode_utf8_at(line, pos)
        if not cp then
          pos = next_pos
        elseif not is_cjk(cp) then
          -- 非汉字字符位置：检查从此开始的子串是否匹配
          local chunk = line:sub(pos, pos + search_len - 1)
          if chunk:lower() == lower_search then
            table.insert(results, {
              char = chunk,
              lnum = lnum,
              byte_col = pos,
              byte_len = search_len,
              pattern = search_str,
              kind = "en",
            })
          end
          pos = next_pos
        else
          pos = next_pos
        end
      end
    end
  end
  return results
end

-- ── 输入辅助 ──────────────────────────────────────────────────
--- 读取一个原始按键，返回字符或 nil（取消）
local function read_key_raw()
  local ok, key = pcall(vim.fn.getchar)
  if not ok then return nil end
  local ch = vim.fn.nr2char(key)
  -- ESC (27), Ctrl-^ (30), Ctrl-C (3) 都视为取消
  if ch == "\27" or ch == "\30" or key == 3 then
    return nil
  end
  -- <BS> 返回特殊标记
  if key == 127 or ch == "\8" then
    return "<BS>"
  end
  return ch:lower()
end

--- 执行跳转到 match 位置
local function do_jump(m, is_visual, visual_start)
  if is_visual and visual_start then
    vim.api.nvim_win_set_cursor(0, { m.lnum, m.byte_col - 1 })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, visual_start)
  else
    vim.cmd("normal! m'")
    pcall(vim.api.nvim_win_set_cursor, 0, { m.lnum, m.byte_col - 1 })
  end
  vim.cmd("normal! zz")
end

--- 为匹配列表分配标签并显示 extmarks
local function show_match_labels(matches)
  local label_set = "abcdefghijklmnopqrstuvwxyz"
  for i, m in ipairs(matches) do
    if i > #label_set then break end
    m.label = label_set:sub(i, i)
    local hl = (m.kind == "cn") and "PinyinFlashLabel" or "PinyinFlashLabelEn"
    pcall(vim.api.nvim_buf_set_extmark, 0, ns_id, m.lnum - 1, m.byte_col - 1, {
      virt_text = { { " " .. m.label .. " ", hl } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = 250,
      strict = false,
    })
  end
end

-- ── 清理 extmarks ─────────────────────────────────────────────
function M.clear_labels()
  pcall(vim.api.nvim_buf_clear_namespace, 0, ns_id, 0, -1)
end

-- ── 中文拼音跳转（保留原有功能） ──────────────────────────────
function M.pinyin_jump(opts)
  opts = opts or {}
  ensure_highlights()

  local saved_view = vim.fn.winsaveview()

  -- 收集可见中文字符
  local chars = M.collect_cn()
  if #chars == 0 then
    vim.api.nvim_echo({ { "(pinyin-flash) 当前视图没有中文字符", "WarningMsg" } }, true, {})
    return
  end

  -- 获取首字母输入
  vim.api.nvim_echo({ { "(拼音) 输入首字母 (a-z): ", "PinyinFlashPrompt" } }, false, {})
  local key = read_key_raw()
  if not key then return end
  local initial = key:match("^[a-z]$") and key or nil
  if not initial then
    vim.api.nvim_echo({ { "已取消", "WarningMsg" } }, true, {})
    return
  end

  -- 按首字母筛选
  local matches = {}
  for _, c in ipairs(chars) do
    if c.initial == initial then
      table.insert(matches, c)
    end
  end

  if #matches == 0 then
    vim.api.nvim_echo({ { "(拼音) 没有以「" .. initial .. "」开头的字", "WarningMsg" } }, true, {})
    return
  end

  -- 唯一匹配 → 直接跳转
  if #matches == 1 then
    local m = matches[1]
    vim.cmd("normal! m'")
    pcall(vim.api.nvim_win_set_cursor, 0, { m.lnum, m.byte_col - 1 })
    vim.cmd("normal! zz")
    return
  end

  -- 多匹配 → 分配标签并显示
  show_match_labels(matches)

  -- 等待标签选择
  vim.api.nvim_echo({ { "(拼音) 跳转到: ", "PinyinFlashPrompt" } }, false, {})
  local label_ch = read_key_raw()
  M.clear_labels()

  if not label_ch then
    vim.fn.winrestview(saved_view)
    return
  end

  -- 执行跳转
  for _, m in ipairs(matches) do
    if m.label == label_ch then
      vim.cmd("normal! m'")
      pcall(vim.api.nvim_win_set_cursor, 0, { m.lnum, m.byte_col - 1 })
      vim.cmd("normal! zz")
      return
    end
  end

  -- 无效标签
  vim.fn.winrestview(saved_view)
  vim.api.nvim_echo({ { "(拼音) 已取消", "WarningMsg" } }, true, {})
end

-- ── 综合跳转：中文拼音 + 英文 flash 原生 ────────────────────────
-- 按 s 后读取第一个按键：
--   a-z → 走 combined 模式（中文拼音 + 英文多字符搜索）
--   其他 → 委托给 flash.nvim 原生 jump()，保留完整 flash 体验
function M.combined_jump(opts)
  opts = opts or {}
  ensure_highlights()

  local is_visual = vim.fn.mode():find("v")
  local saved_view = vim.fn.winsaveview()
  local visual_start ---@type {lnum:number, col:number}?
  if is_visual then
    visual_start = vim.api.nvim_buf_get_mark(0, "<")
  end

  -- 读取第一个按键
  vim.api.nvim_echo({ { "(flash+拼音) ", "PinyinFlashPrompt" } }, false, {})
  local first_key = read_key_raw()
  if not first_key then
    if is_visual then vim.cmd("normal! \27") end
    vim.fn.winrestview(saved_view)
    return
  end

  -- 非字母 → 完全委托给 flash.nvim 原生 s 键（保留其全部功能）
  if not first_key:match("^[a-z]$") then
    vim.fn.winrestview(saved_view)
    require("flash").jump({ search = { search = first_key, mode = "exact" } })
    return
  end

  -- ── 以下为 combined 模式：中文拼音 + 英文多字符搜索 ──────────
  local search_str = first_key
  local cn_matches = {} -- 中文匹配（首字母决定，之后不变）
  local matches = {}

  while true do
    -- 更新匹配
    M.clear_labels()
    matches = {}

    -- 英文：搜索 search_str 在非中文区域的所有出现
    local en_list = M.collect_en(search_str)
    for _, m in ipairs(en_list) do
      table.insert(matches, m)
    end

    -- 中文：仅由首字母决定，首次收集后保持不变
    if #search_str == 1 then
      cn_matches = {}
      local chars = M.collect_cn()
      local first_letter = search_str:sub(1, 1)
      for _, c in ipairs(chars) do
        if c.initial == first_letter then
          table.insert(cn_matches, c)
        end
      end
    end
    for _, m in ipairs(cn_matches) do
      table.insert(matches, m)
    end

    -- 排序
    table.sort(matches, function(a, b)
      if a.lnum ~= b.lnum then return a.lnum < b.lnum end
      return a.byte_col < b.byte_col
    end)

    -- 处理匹配数量
    if #matches == 0 then
      vim.api.nvim_echo({
        { "(flash+拼音) 「" .. search_str .. "」无匹配", "WarningMsg" },
      }, true, {})
      search_str = search_str:sub(1, -2)
      if #search_str == 0 then cn_matches = {} end
      vim.api.nvim_echo({
        { "(flash+拼音) " .. (#search_str > 0 and "「" .. search_str .. "」" or ""), "PinyinFlashPrompt" },
      }, false, {})
      goto continue
    end

    if #matches == 1 then
      M.clear_labels()
      do_jump(matches[1], is_visual, visual_start)
      return
    end

    -- 显示标签（双字符标签，避免与搜索键冲突）
    show_match_labels(matches)

    local hint = "  | <BS>=" .. (#search_str - 1) .. " | 标签=跳转 | 字母=搜索"
    vim.api.nvim_echo({
      { "(flash+拼音) 「" .. search_str .. "」 ", "PinyinFlashPrompt" },
      { "(" .. #matches .. "个)", "Comment" },
      { hint, "Comment" },
    }, false, {})

    ::continue::

    -- 读取下一个按键
    local key = read_key_raw()
    if not key then
      M.clear_labels()
      if is_visual then vim.cmd("normal! \27") end
      vim.fn.winrestview(saved_view)
      return
    end

    -- Backspace
    if key == "<BS>" then
      if #search_str > 0 then
        search_str = search_str:sub(1, -2)
        if #search_str == 0 then
          cn_matches = {}
          vim.api.nvim_echo({ { "(flash+拼音) ", "PinyinFlashPrompt" } }, false, {})
        end
      end
    -- 字母键
    elseif key:match("^[a-z]$") then
      -- 检查是否是已显示的标签 → 跳转
      local jumped = false
      for _, m in ipairs(matches) do
        if m.label == key then
          M.clear_labels()
          do_jump(m, is_visual, visual_start)
          return
        end
      end
      -- 不是标签 → 追加到搜索串
      search_str = search_str .. key
    else
      -- 其他键 → 取消
      M.clear_labels()
      if is_visual then vim.cmd("normal! \27") end
      vim.fn.winrestview(saved_view)
      return
    end
  end
end

-- ── 初始化入口 ────────────────────────────────────────────────
function M.setup(opts)
  opts = opts or {}
  local cn_keymap = opts.cn_keymap or "<leader>pj"
  local en_keymap = opts.en_keymap or "s"

  -- 中文拼音专用跳转
  vim.keymap.set("n", cn_keymap, function()
    M.pinyin_jump(opts)
  end, { desc = "Pinyin Flash: 按拼音首字母跳转" })

  -- 综合中英文跳转（替换原来的 s → flash.jump()）
  vim.keymap.set("n", en_keymap, function()
    M.combined_jump(opts)
  end, { desc = "Flash Search: 英文+拼音首字母跳转" })

  -- Visual 模式也支持
  vim.keymap.set("x", en_keymap, function()
    M.combined_jump(opts)
  end, { desc = "Flash Search (Visual): 英文+拼音首字母跳转" })

  -- 也提供一个 fallback：<leader>s 用原版 flash 搜索
  local fallback_keymap = opts.flash_fallback or "<leader>s"
  vim.keymap.set("n", fallback_keymap, function()
    -- 原版 flash jump，只有英文
    require("flash").jump()
  end, { desc = "Flash Original: 纯英文字符跳转" })
end

return M
