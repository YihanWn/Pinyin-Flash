import os

# prj path
SCRIPT_PATH = os.path.dirname(os.path.abspath(__file__))
BUILD_PATH = os.path.join(SCRIPT_PATH, "..", "build")

# 输入拼音文件 unicode codepoint: 拼音
# e.g. pinyin-data: U+4E01: dīng  # 丁
MANDARIN_PATH = os.path.join(SCRIPT_PATH, "kMandarin_8105.txt")
# 输出 lua label
PINYIN_MAP = os.path.join(BUILD_PATH, "pinyin_map.lua")