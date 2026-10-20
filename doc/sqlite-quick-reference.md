# SQLite 文件结构 - 快速参考卡

## 📋 一页纸总结

### 文件布局
```
[100字节文件头] [Page 1数据] [Page 2数据] ... [Page N数据]
                     ↓
            [页头8-12字节][单元指针][空闲][单元内容]
```

### 文件头位置（100字节）
```
0-15      : "SQLite format 3\0"
16-17     : 页面大小(1=65536)
18-19     : 版本号
24-27     : 更改计数
28-31     : 数据库页数
32-35     : 第一自由列表页
36-39     : 自由列表页数
40-99     : 15个4字节元数据
```

### 元数据位置
```
40-43 (+0) : Schema Cookie
44-47 (+4) : File Format
48-51 (+8) : Cache Size
52-55 (+12): Largest Root
56-59 (+16): Text Encoding (1=UTF8)
60-63 (+20): User Version
64-67 (+24): Incremental Vacuum
68-71 (+28): Application ID
```

### 页面头位置（Page 1从100开始，其他从0开始）
```
+0  : 页面类型标志
+1-2: 第一自由块偏移
+3-4: 单元数
+5-6: 单元内容起始
+7  : 碎片字节数
+8-11: 右子指针(仅内部节点)
+12... : 单元指针数组(2字节每个)
```

### 页面类型标志组合
```
0x01 = INTKEY      (表B树)
0x02 = ZERODATA    (无数据)
0x04 = LEAFDATA    (叶子数据)
0x08 = LEAF        (叶子页面)

常见：
0x0D = 表叶子 (0x01|0x04|0x08)
0x05 = 表内部 (0x01|0x04)
0x02 = 索引叶子
0x0A = 索引内部 (0x02|0x08)
```

### 单元格式（INTKEY表）
```
【内部节点】
4字节: 左子页面
Varint: 数据字节数
Varint: ROWID(键)
*字节: 数据
[4字节]: 溢出页(可选)

【叶子单元】
Varint: 数据字节数
Varint: ROWID
*字节: 数据
[4字节]: 溢出页(可选)
```

### 变长整数(Varint)编码
```
< 128      : 1字节
< 16384    : 2字节
< 2097152  : 3字节
< 268M     : 4字节
...
> 72057594B: 9字节

编码规则: 低7位是数据，第8位是继续标志
解码: 第9字节用满8位
```

### 大端序整数(Big-Endian)
```
2字节: (b[0]<<8) | b[1]
4字节: (b[0]<<24)|(b[1]<<16)|(b[2]<<8)|b[3]

示例: 0x12 0x34 = 4660
     0x12 0x34 0x56 0x78 = 305419896
```

## 🎯 实用速查

### 读取文件头
```
字段                位置        类型        标准值
签名                0-15        ASCII       "SQLite format 3"
页面大小(字节)      16-17       u16 BE      4096
读版本              19          u8          3
写版本              18          u8          3
文本编码            56-59       u32 BE      1(UTF-8)
```

### 页面位置计算
```
页面号为N的起始位置 = (N-1) × 页面大小
(第一页特殊，前100字节是文件头)
```

### 单元指针位置
```
Page 1第一个单元指针位置 = 100(文件头) + 8(页头)  = 108
其他页第一个单元指针位置 = 0 + 8(页头) = 8
内部节点多4字节: 108+4=112 (Page1) 或 8+4=12 (其他)
```

### 自由列表树干页格式
```
0-3   : 下一个树干页号
4-7   : 此树干的叶子数
8+    : 叶子页面号列表(每个4字节)
```

### 溢出页格式
```
0-3   : 下一个溢出页号(0=末尾)
4+    : 数据(最多 页面大小-4)
```

## 🔍 调试技巧

### 用hexdump查看
```bash
# 查看前512字节
hexdump -C database.db | head -20

# 查看特定页面
dd if=database.db bs=4096 skip=0 count=1 | hexdump -C
```

### 用Python验证
```python
import struct

with open('database.db', 'rb') as f:
    data = f.read(100)
    
    # 验证签名
    sig = data[0:16].decode('ascii')
    print(f"签名: {sig}")
    
    # 读取页面大小
    page_size = struct.unpack('>H', data[16:18])[0]
    if page_size == 1: page_size = 65536
    print(f"页面大小: {page_size}")
    
    # 读取页数
    page_count = struct.unpack('>I', data[28:32])[0]
    print(f"页数: {page_count}")
    
    # 读取文本编码
    encoding = struct.unpack('>I', data[56:60])[0]
    enc_name = {1: 'UTF-8', 2: 'UTF-16LE', 3: 'UTF-16BE'}.get(encoding, '未知')
    print(f"文本编码: {enc_name}")
```

### 用SQLite命令查询
```bash
sqlite3 database.db "PRAGMA page_size;"
sqlite3 database.db "PRAGMA page_count;"
sqlite3 database.db "PRAGMA encoding;"
sqlite3 database.db "PRAGMA schema_version;"
sqlite3 database.db "PRAGMA user_version;"
sqlite3 database.db "PRAGMA application_id;"
```

## 📊 尺寸速查表

| 项目 | 大小 | 说明 |
|------|------|------|
| 文件头 | 100字节 | 仅Page 1 |
| 页头(叶子) | 8字节 | PTF_LEAF=1 |
| 页头(内部) | 12字节 | 包含右指针 |
| 单元指针 | 2字节/个 | 每个单元一个 |
| 左子指针 | 4字节 | 内部节点单元头 |
| 右子指针 | 4字节 | 内部节点页头 |
| 溢出页指针 | 4字节 | 单元末尾(可选) |
| 下一页指针 | 4字节 | 自由列表、溢出页 |
| Varint | 1-9字节 | 变长编码 |

## ⚠️ 常见陷阱

1. **页面号从1开始**，不是0。页面0表示"无页面"
2. **Page 1特殊**：前100字节是文件头，页面头从偏移100开始
3. **大端序**：所有多字节整数都是大端序
4. **Varint继续标志**：第8位是继续标志，需要特殊处理
5. **碎片空间**：< 4字节的空闲空间不在自由块链表中
6. **偏移量**：单元指针指向单元开始位置，在页面内是相对的
7. **自由块链表**：第一个自由块偏移为0表示没有自由块

## 📖 关键常数

```c
#define SQLITE_FILE_HEADER "SQLite format 3"
#define DEFAULT_PAGE_SIZE 4096
#define MIN_PAGE_SIZE 512
#define MAX_PAGE_SIZE 65536

#define PTF_INTKEY 0x01
#define PTF_ZERODATA 0x02
#define PTF_LEAFDATA 0x04
#define PTF_LEAF 0x08

#define PAGER_JOURNALMODE_DELETE 0
#define PAGER_JOURNALMODE_PERSIST 1
#define PAGER_JOURNALMODE_OFF 2
#define PAGER_JOURNALMODE_TRUNCATE 3
#define PAGER_JOURNALMODE_MEMORY 4
#define PAGER_JOURNALMODE_WAL 5
```

## 🎓 学习资源

- 官方文档：https://sqlite.org/fileformat.html
- 源码：src/btreeInt.h 中的详细注释
- 二进制格式详解：sqlite-binary-format.md
- 结构详解：sqlite-file-structure.md
- 源码实现：sqlite-source-implementation.md

---

**提示**: 这是速查卡，详细内容请参考完整文档。

