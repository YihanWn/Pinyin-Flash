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

-- ── 收集可见英文字符 ──────────────────────────────────────────
-- 在可见区域中找所有匹配 letter 的英文/数字/符号位置（类似 flash.nvim 的 s 键行为）
-- 跳过中文汉字，避免与 collect_cn 重复
-- 返回: { char, lnum, byte_col, byte_len, pattern, kind="en" }[]
function M.collect_en(letter)
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local top = vim.fn.line("w0")
  local bottom = vim.fn.line("w$")

  -- 不区分大小写，匹配任意位置的 letter（不使用 \< 单词边界，与 flash.nvim 行为一致）
  local pattern = "\\c" .. letter

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
        elseif not is_cjk(cp) then
          -- 非汉字字符：检查是否匹配用户输入的字母
          local ch = line:sub(pos, pos + len - 1)
          if ch:lower() == letter then
            table.insert(results, {
              char = ch,
              lnum = lnum,
              byte_col = pos,
              byte_len = len,
              pattern = letter,   -- 用 pattern 代替 initial 区分中英文
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
--- 从用户获取一个字母 a-z，取消则返回 nil
local function get_input_letter(prompt)
  ensure_highlights()
  vim.api.nvim_echo({ { prompt or "输入首字母 (a-z): ", "PinyinFlashPrompt" } }, false, {})

  local ok, key = pcall(vim.fn.getchar)
  if not ok then
    vim.api.nvim_echo({ { "" }, false, {} })
    return nil
  end

  local ch = vim.fn.nr2char(key)
  -- ESC (27), Ctrl-^ (30), Ctrl-C (3) 都视为取消
  if ch == "\27" or ch == "\30" or key == 3 then
    vim.api.nvim_echo({ { "" }, false, {} })
    return nil
  end

  local initial = ch:lower()
  if not initial:match("^[a-z]$") then
    vim.api.nvim_echo({ { "已取消", "WarningMsg" } }, true, {})
    return nil
  end
  return initial
end

--- 从用户获取一个标签字母，取消则返回 nil
local function get_label_input()
  local ok2, label_input = pcall(vim.fn.getchar)
  if not ok2 then return nil end

  local label_ch = vim.fn.nr2char(label_input):lower()
  if label_ch == "\27" or label_ch == "\30" or label_input == 3 then
    return nil
  end
  return label_ch
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
  local initial = get_input_letter("(拼音) 输入首字母 (a-z): ")
  if not initial then return end

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
  local label_set = "abcdefghijklmnopqrstuvwxyz"

  for i, m in ipairs(matches) do
    if i > #label_set then break end
    m.label = label_set:sub(i, i)
    pcall(vim.api.nvim_buf_set_extmark, 0, ns_id, m.lnum - 1, m.byte_col - 1, {
      virt_text = { { " " .. m.label .. " ", "PinyinFlashLabel" } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = 250,
      strict = false,
    })
  end

  -- 等待标签选择
  vim.api.nvim_echo({ { "(拼音) 跳转到: ", "PinyinFlashPrompt" } }, false, {})
  local label_ch = get_label_input()
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

-- ── 综合跳转：中文拼音 + 英文单词 ─────────────────────────────
-- 按一个字母，同时高亮中文（拼音以此字母开头）和英文（以此字母开头的单词）
-- 标签风格：中文用红色底色，英文用橙色底色
function M.combined_jump(opts)
  opts = opts or {}
  ensure_highlights()

  local is_visual = vim.fn.mode():find("v")
  local saved_view = vim.fn.winsaveview()
  local visual_start  ---@type {lnum:number, col:number}?

  if is_visual then
    -- 保存 visual 模式的起始位置
    visual_start = vim.api.nvim_buf_get_mark(0, "<")
  end

  -- 第一步：获取字母输入
  local initial = get_input_letter("(中+英 flash) 输入字母 (a-z): ")
  if not initial then return end

  -- 第二步：同时收集中文和英文匹配
  local chars = M.collect_cn()
  local en_matches = M.collect_en(initial)

  local matches = {}

  -- 中文匹配
  for _, c in ipairs(chars) do
    if c.initial == initial then
      table.insert(matches, c)
    end
  end

  -- 英文匹配
  for _, m in ipairs(en_matches) do
    table.insert(matches, m)
  end

  if #matches == 0 then
    vim.api.nvim_echo({ { "(flash+拼音) 没有以「" .. initial .. "」开头的字或词", "WarningMsg" } }, true, {})
    return
  end

  -- 按行、列排序
  table.sort(matches, function(a, b)
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    return a.byte_col < b.byte_col
  end)

  -- 唯一匹配 → 直接跳转
  if #matches == 1 then
    local m = matches[1]
    if is_visual and visual_start then
      vim.api.nvim_win_set_cursor(0, { m.lnum, m.byte_col - 1 })
      vim.cmd("normal! v")
      vim.api.nvim_win_set_cursor(0, visual_start)
    else
      vim.cmd("normal! m'")
      pcall(vim.api.nvim_win_set_cursor, 0, { m.lnum, m.byte_col - 1 })
    end
    vim.cmd("normal! zz")
    return
  end

  -- 多匹配 → 分配标签并显示
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

  -- 等待标签选择
  vim.api.nvim_echo({ { "(flash+拼音) 跳转到: ", "PinyinFlashPrompt" } }, false, {})
  local label_ch = get_label_input()
  M.clear_labels()

  if not label_ch then
    if is_visual then
      vim.cmd("normal! \27") -- 退出 visual
    end
    vim.fn.winrestview(saved_view)
    return
  end

  -- 执行跳转
  for _, m in ipairs(matches) do
    if m.label == label_ch then
      if is_visual and visual_start then
        -- Visual mode: 从 visual start 扩展到目标
        vim.api.nvim_win_set_cursor(0, { m.lnum, m.byte_col - 1 })
        vim.cmd("normal! v")
        vim.api.nvim_win_set_cursor(0, visual_start)
      else
        vim.cmd("normal! m'")
        pcall(vim.api.nvim_win_set_cursor, 0, { m.lnum, m.byte_col - 1 })
      end
      vim.cmd("normal! zz")
      return
    end
  end

  -- 按了无效的标签键
  if is_visual then
    vim.cmd("normal! \27")
  end
  vim.fn.winrestview(saved_view)
  vim.api.nvim_echo({ { "(flash+拼音) 已取消", "WarningMsg" } }, true, {})
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
