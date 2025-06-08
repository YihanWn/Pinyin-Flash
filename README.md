# Pinyin-Flash

## 1. Data

### 1.1 Unihan

[Unihan](https://www.unicode.org/Public/UNIDATA/) 较 pinyin-data 新, 为 2024-07-31.

提取 Unihan/Unihan_Readings.txt 为 Unicode-拼音 查找表, 但 Unihan 太长, 有 4w+。

### 1.2 kMandarin_8105.txt

后来发现已经有工作 [pinyin-data](https://github.com/mozillazg/pinyin-data#) 做了许多数据集

其中 kMandarin_8105.txt: 《通用规范汉字表》(2013 年版)里 8105 个汉字最常用的一个读音, 后面使用 kMandarin_8105.txt 做测试

## 2. scripts

pinyin2LuaTab.py 提取 kMandarin_8105 格式 unicode codepoints: pinyin 为 lua table
