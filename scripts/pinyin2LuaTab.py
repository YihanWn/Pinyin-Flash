import re
import os
from config import *


def parse_and_generate_lua(input_path: str, output_path: str):
    """
    从 input_path 中提取所有 U+XXXX: 拼音 # 注释 行，
    生成一个 Lua 模块，映射 codepoint -> { 拼音 }。
    """
    entries = []
    # 匹配 U+4E00: yī  # 一 这种格式，拼音支持音调符号
    pattern = re.compile(r"^U\+([0-9A-Fa-f]{4,6}):\s*([a-zāáǎàēéěèīíǐìōóǒòūúǔùüǘǚǜ]+)")
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(input_path, "r", encoding="utf-8") as fin:
        for line in fin:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = pattern.match(line)
            if m:
                code_hex, pinyin = m.groups()
                code = int(code_hex, 16)
                entries.append((code, pinyin))

    # 写 Lua 模块
    with open(output_path, "w", encoding="utf-8") as fout:
        fout.write("-- 自动生成：通用规范汉字表最常用读音映射（共 %d 字）\n" % len(entries))
        fout.write("local pinyin_map = {\n")
        for code, py in entries:
            # 注释显示对应汉字
            fout.write(f'  [0x{code:04X}] = {{ "{py}" }},  -- {chr(code)}\n')
        fout.write("}\n\nreturn pinyin_map\n")

    print(f"Wrote {len(entries)} entries to {output_path}")


def main():
    parse_and_generate_lua(MANDARIN_PATH, PINYIN_MAP)


if __name__ == "__main__":
    main()
