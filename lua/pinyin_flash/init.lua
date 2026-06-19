-- pinyin_flash 主模块入口
-- require("pinyin_flash") 会加载此文件，委托给 core 模块

local core = require("pinyin_flash.core")

local M = {}

-- 注册键映射：<leader>pj 拼音跳转，s 综合中英文跳转，<leader>s 原版 flash 跳转
function M.setup(opts)
  core.setup(opts)
end

-- 纯拼音首字母跳转
function M.jump(opts)
  core.pinyin_jump(opts)
end

-- 综合中英文跳转（拼音首字母 + 英文单词首字母）
function M.combined_jump(opts)
  core.combined_jump(opts)
end

return M
