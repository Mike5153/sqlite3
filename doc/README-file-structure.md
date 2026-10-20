# SQLite 文件内容结构 - 完整分析总结

这个目录包含了对SQLite数据库文件内容结构的详细分析，由源码分析而来。

## 📚 文档说明

### 1. **sqlite-file-structure.md** (逻辑结构视角)
   - SQLite文件的概念和逻辑结构
   - 文件头100字节的详细解析
   - 页面结构和B树布局
   - 单元、溢出页面、自由列表的完整说明
   - 有效负荷分数的概念
   
   **适合理解：** SQLite文件的整体设计思想和数据组织方式

### 2. **sqlite-binary-format.md** (二进制格式视角)
   - 完整的文件二进制布局图
   - 十六进制数据示例和解析
   - 变长整数(Varint)编码详解
   - 四字节大端序整数编码
   - 页面类型标志的所有组合
   - 实际的十六进制转储示例
   - 快速参考表和伪代码工具
   
   **适合理解：** 如何在原始二进制数据中识别各种结构

### 3. **sqlite-source-implementation.md** (源码实现视角)
   - 核心数据结构(Pager, Btree, BtShared, MemPage)
   - 文件格式常数定义
   - 页面头部读写实现
   - 变长整数编码/解码函数
   - 单元解析的具体实现
   - 自由列表和溢出处理的源码细节
   - 事务和日志机制
   
   **适合理解：** SQLite源码如何实现文件格式

## 🎯 快速开始

### 如果你要...

**理解SQLite如何存储数据**
→ 从 `sqlite-file-structure.md` 开始，了解整体架构

**修改或创建SQLite文件解析工具**
→ 阅读 `sqlite-binary-format.md`，学习二进制格式

**贡献SQLite源码或深度优化**
→ 阅读 `sqlite-source-implementation.md`，理解实现细节

**调试数据库文件问题**
→ 结合所有三份文档，对照源码和十六进制数据

## 📊 核心概念速览

### 文件结构层次

```
SQLite数据库文件
├── 文件头 (第1页前100字节)
│   ├── 签名 "SQLite format 3"
│   ├── 页面大小
│   ├── 版本信息
│   └── 元数据(15个4字节值)
│
├── Page 1 (包含文件头)
│   ├── 页面头 (8-12字节)
│   ├── 单元指针数组
│   ├── 空闲空间
│   └── 单元内容区域
│
├── Page 2-N (B树页面)
│   ├── 页面头
│   ├── 单元指针数组
│   ├── 空闲空间
│   └── 单元内容区域
│
├── 溢出页面 (按需)
│   └── 大数据存储
│
└── 自由列表页面 (按需)
    └── 未使用页面追踪
```

### 关键术语

| 术语 | 解释 |
|------|------|
| **Page** | 固定大小的数据块（默认4096字节） |
| **Btree** | B树，SQLite的主要数据结构 |
| **Cell** | 单元，存储键值对的最小单位 |
| **Varint** | 变长整数，节省空间的编码格式 |
| **Overflow** | 溢出，当数据超过页面空间时存储到额外页面 |
| **Freelist** | 自由列表，追踪未使用的页面 |
| **Payload** | 有效负荷，单元中的实际数据部分 |

### 重要数字

| 项目 | 默认值 | 范围 |
|------|--------|------|
| 页面大小 | 4096字节 | 512-65536字节 |
| 文件头大小 | 100字节 | 固定100字节(仅Page1) |
| 页面头大小 | 8或12字节 | 8(叶子) 或 12(内部) |
| 最大文件大小 | ~1TB | 受4294967294页限制 |
| 元数据条目 | 15个 | 各4字节 |

## 🔍 源码对应关系

| 结构/概念 | 定义位置 | 实现位置 |
|---------|---------|---------|
| Pager | src/pager.h | src/pager.c |
| Btree | src/btree.h | src/btree.c |
| MemPage | src/btreeInt.h | src/btree.c |
| 文件格式 | src/btreeInt.h | src/btree.c |
| 页面缓存 | src/pcache.h | src/pcache.c |
| 日志 | src/wal.h | src/wal.c |

## 📝 分析特点

本分析基于SQLite源代码的仔细阅读，重点包括：

1. **准确性高**：所有数据、偏移量和格式都直接来自源码
2. **深度完整**：从宏观架构到微观二进制细节
3. **多角度解释**：逻辑、二进制、源码三个维度
4. **实用参考**：包含十六进制示例和伪代码
5. **源码交叉**：每个概念都能在源码中找到对应实现

## 🚀 实用建议

### 阅读顺序推荐

**初学者路径：**
1. sqlite-file-structure.md - 第1-3节
2. sqlite-binary-format.md - 第1节和第2节
3. sqlite-file-structure.md - 第4-8节

**中级开发者路径：**
1. sqlite-binary-format.md - 全部
2. sqlite-file-structure.md - 全部
3. sqlite-source-implementation.md - 相关部分

**高级/源码贡献者路径：**
1. sqlite-source-implementation.md - 全部
2. sqlite-binary-format.md - 作为参考
3. sqlite-file-structure.md - 作为总体理解

### 实践建议

**使用十六进制编辑器检查真实数据库：**
```bash
# 查看数据库文件的前512字节
hexdump -C your_database.db | head -20

# 或使用sqlite命令查询元数据
sqlite3 your_database.db "PRAGMA database_list;"
sqlite3 your_database.db "PRAGMA page_size;"
sqlite3 your_database.db "PRAGMA page_count;"
```

**编写文件解析工具：**
参考 sqlite-binary-format.md 中的伪代码，可以编写：
- SQLite文件校验工具
- 损坏数据库恢复工具
- 数据库文件分析工具

## 📖 相关资源

- **官方文档**：https://www.sqlite.org/fileformat.html
- **源码位置**：https://github.com/sqlite/sqlite
- **B树理论**：Donald Knuth 《计算机程序设计艺术》第3卷

## 🤝 文档维护

这些文档基于SQLite源码分析而来。当SQLite更新重大文件格式时，需要对应更新这些文档。

当前分析基于SQLite最新主分支代码，源码文件：
- src/btreeInt.h
- src/btree.h
- src/pager.h
- src/btree.c
- src/pager.c

---

**生成日期**：2026年6月10日  
**SQLite版本**：Latest (from master branch)  
**分析深度**：完整（文件格式、源码实现、二进制格式）

