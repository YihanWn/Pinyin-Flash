# Pinyin-Flash.nvim

拼音首字母 + 英文字符跳转，类似 [flash.nvim](https://github.com/folke/flash.nvim)，额外支持中文。

按 `s` + 字母 → 同时高亮：
- **英文/数字/符号**：所有匹配该字母的位置（与 flash.nvim 行为一致）
- **中文**：拼音首字母匹配该字母的汉字

按标签字母跳转。

## 安装

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "YihanWn/Pinyin-Flash.nvim",
  event = "VeryLazy",
  config = function()
    require("pinyin_flash").setup()
  end,
}
```

## 键映射

| 按键 | 功能 |
|------|------|
| `s` | 中英文综合跳转（主触发键） |
| `<leader>pj` | 纯拼音首字母跳转 |
| `<leader>s` | 原版 flash.nvim 英文跳转（备用） |

## 自定义

```lua
require("pinyin_flash").setup({
  cn_keymap = "<leader>pj",     -- 纯拼音跳转快捷键
  en_keymap = "s",              -- 综合跳转快捷键（false 禁用）
  flash_fallback = "<leader>s", -- flash.nvim 备用快捷键
})
```

## 依赖

- [flash.nvim](https://github.com/folke/flash.nvim) — `s` 键与 `<leader>s` 备用跳转需要

---

## 数据来源

拼音数据来自 [pinyin-data](https://github.com/mozillazg/pinyin-data) 中的 `kMandarin_8105.txt`:
《通用规范汉字表》(2013 年版) 8105 个汉字最常用的读音。

备选数据源: [Unihan](https://www.unicode.org/Public/UNIDATA/Unihan.zip) `Unihan_Readings.txt` (4w+ 条)。

## 更新拼音表

```bash
cd scripts
python pinyin2LuaTab.py
# 生成 lua/pinyin_flash/pinyin_map.lua
```

## License

MIT
