# SQLite 文件二进制格式参考

## 1. 完整的文件布局图

```
SQLite数据库文件二进制布局
═══════════════════════════════════════════════════════════════

OFFSET BYTES CONTENT
────────────────────────────────────────────────────────────────

【PAGE 1 (通常4096字节)】

+─ 0      16   "SQLite format 3\0"
│
├─ 16     2    Page Size (big-endian, 1=65536) 
│  示例：0x10 0x00 = 4096字节
│
├─ 18     1    File Format Write Version (3)
├─ 19     1    File Format Read Version (3)
├─ 20     1    Reserved Bytes at EOF (通常0)
├─ 21     1    Max Embedded Payload Fraction (64)
├─ 22     1    Min Embedded Payload Fraction (32)
├─ 23     1    Min Leaf Payload Fraction (32)
│
├─ 24     4    Change Counter (big-endian)
│  示例：0x00 0x00 0x00 0x05 = 5次更改
│
├─ 28     4    DB Size in Pages (big-endian)
│  示例：0x00 0x00 0x00 0x0A = 10页
│
├─ 32     4    First Freelist Page (big-endian)
│  示例：0x00 0x00 0x00 0x00 = 无自由列表
│
├─ 36     4    Number of Freelist Pages (big-endian)
│
├─ 40     4    Schema Cookie (meta[0])
├─ 44     4    File Format (meta[1])
├─ 48     4    Cache Size (meta[2])
├─ 52     4    Largest Root-Page (meta[3])
├─ 56     4    Text Encoding (meta[4])
│           1 = UTF-8, 2 = UTF-16LE, 3 = UTF-16BE
├─ 60     4    User Version (meta[5])
├─ 64     4    Incremental Vacuum (meta[6])
├─ 68     4    Application-ID (meta[7])
├─ 72     20   Reserved (meta[8-12])
├─ 92     4    Version-Valid-For (meta[13])
└─ 96     4    SQLITE_VERSION_NUMBER (meta[14])

【BTREE PAGE HEADER】(starts at offset 100 for Page 1)

┌─ 100    1    Page Type Flags
│            0x08 = Leaf page
│            0x04 = Leaf data
│            0x02 = Zero data  
│            0x01 = Int key
│            Example: 0x0d = leaf + leaf_data + int_key
│
├─ 101    2    First Freeblock Offset (big-endian, 0=none)
├─ 103    2    Number of Cells (big-endian)
│            Example: 0x00 0x03 = 3 cells
│
├─ 105    2    First Cell Content Offset (big-endian)
│            Example: 0x0f 0xd8 = 4056 bytes
│
├─ 107    1    Fragmented Free Bytes
│            (< 4 bytes free space, not in freelist)
│
└─ 108    4    Right Child Page Pointer (big-endian, leaf pages omit this)
            (Only for interior nodes)

【CELL POINTER ARRAY】(starts at offset 108 for Page 1 with leaves)

├─ 108    2    Cell Pointer[0] (offset to cell 0)
│            Example: 0x0f 0xd8 = offset 4056
│
├─ 110    2    Cell Pointer[1] (offset to cell 1)
├─ 112    2    Cell Pointer[2] (offset to cell 2)
└─ ...         (continues for each cell, 2 bytes per cell)

【CELL CONTENT AREA】(from offset 3950 downward in this example)

┌─ ... 
├─ 4056  [varint] Number of Data Bytes
│ Example:
│  0x05 = 5 bytes of data follows
│  0x81 0x00 = 128 bytes of data follows (varint encoding)
│
├─ ...   [varint] Number of Key Bytes (or Key itself if intkey)
│ Example:
│  0x01 = 1 byte key
│
├─ ...   [variable] Payload Data
│ Example:
│  48 65 6c 6c 6f = "Hello"
│
└─ ...   [4 bytes] Overflow Page Pointer (optional, only if overflow)
          Example: 0x00 0x00 0x00 0x0B = page 11

【PAGE 2 onwards】(same structure, no 100-byte file header)

┌─ 4096   1    Page Type Flags
├─ 4097   2    First Freeblock Offset
├─ 4099   2    Number of Cells
├─ ...         (same as page 1 page header from offset 100)
└─ ...

【OVERFLOW PAGE】(if data exceeds max payload)

┌─ 0      4    Next Overflow Page Pointer (big-endian, 0=end)
└─ 4      ...  Data Content (up to pageSize-4 bytes)

【FREELIST TRUNK PAGE】

┌─ 0      4    Next Trunk Page Number (big-endian, 0=end)
├─ 4      4    Number of Leaf Page Pointers (big-endian)
│            Example: 0x00 0x00 0x00 0x05 = 5 leaves
│
├─ 8      4    Leaf Page Pointer[0]
├─ 12     4    Leaf Page Pointer[1]
├─ 16     4    Leaf Page Pointer[2]
└─ ...         (continues for each leaf page)

═══════════════════════════════════════════════════════════════
```

## 2. 数据类型编码

### 2.1 变长整数 (Varint) 编码

```
十进制     十六进制序列              说明
─────────────────────────────────────────────────────
0         0x00                    单个字节
127       0x7f                    单个字节（最大单字节）
128       0x81 0x00               二字节
255       0x81 0x7f               二字节（最大两字节）
256       0x82 0x00               三字节
65535     0x82 0x7f 0xff          多字节
16777215  0x83 0x7f 0xff 0xff     多字节

编码算法（举例）：
值: 0x12345678 (305419896)
┌─ 0x12345678 的二进制格式
├─ 分解为 7 位组：0x94 0x62 0x8c 0x78
├─ 添加继续标志：0x81 0x91 0xd1 0xac 0x78
└─ 结果：5 字节序列
```

### 2.2 四字节大端序整数

```
十进制值  十六进制序列   说明
────────────────────────────────────
1         0x00 0x00 0x00 0x01
256       0x00 0x00 0x01 0x00
65536     0x00 0x01 0x00 0x00
16777216  0x01 0x00 0x00 0x00
```

## 3. 页面标志 (Page Type Flags) 详解

```
标志值   标志名      二进制   含义
──────────────────────────────────────────────────
0x01   PTF_INTKEY   00000001  Table B-tree (integer keys)
0x02   PTF_ZERODATA 00000010  Zero data tree
0x04   PTF_LEAFDATA 00000100  Leaf data page
0x08   PTF_LEAF     00001000  Leaf page (no children)

常见组合：
──────────────────────────────────────────────────
值     二进制    页面类型
──────────────────────────────────────────────────
0x05   00000101  Table leaf page (intkey + leafdata)
0x0d   00001101  Table leaf (intkey + leafdata + leaf)
0x02   00000010  Index leaf page (zerodata)
0x0a   00001010  Index leaf (zerodata + leaf)
0x01   00000001  Interior table page (intkey only)
0x09   00001001  Interior table (intkey + leaf) [INVALID]
```

## 4. 单元格式详解

### 4.1 表格B树单元（INTKEY表）

```
【内部节点单元】
┌─ 4 bytes    Left Child Page Number (big-endian)
│            Example: 0x00 0x00 0x00 0x42 = page 66
│
├─ varint     Payload Size (data bytes)
│            Example: 0x15 = 21 bytes
│
├─ varint     Key Value (ROWID, stored in size field)
│            Example: 0x03 = rowid 3
│
├─ ...        Payload Data
│            (variable length, up to payload size)
│
└─ [4 bytes]  First Overflow Page (optional, if overflow)

【叶子单元】
┌─ varint     Payload Size
├─ varint     ROWID
├─ ...        Payload Data
└─ [4 bytes]  First Overflow Page (optional)
```

### 4.2 索引B树单元（BLOBKEY索引或无ROWID表）

```
【内部节点单元】
┌─ 4 bytes    Left Child Page Number
├─ varint     Key Size
├─ ...        Key Data
└─ [4 bytes]  First Overflow Page (optional)

【叶子单元】
┌─ varint     Key Size
├─ ...        Key Data
└─ [4 bytes]  First Overflow Page (optional)
```

## 5. 自由块 (Freeblock) 格式

```
【自由块结构】
┌─ 2 bytes    Next Freeblock Offset (big-endian, 0=last)
│            Example: 0x04 0x00 = offset 1024
│
└─ 2 bytes    Size of This Freeblock (big-endian)
              Example: 0x00 0x20 = 32 bytes
```

## 6. 十六进制转储示例

```
【典型的数据库文件开头（第一个512字节）】

00000000: 5351 4c69 7465 2066 6f72 6d61 7420 3300  SQLite format 3.
00000010: 1000 0301 0040 2020 0000 0001 0000 000b  ....@ ..........
00000020: 0000 0000 0000 0000 0000 0000 0000 0000  ................
00000030: 0000 0000 0000 0000 0000 0000 0000 0001  ................
00000040: 0000 0000 0000 0000 0300 0000 0400 0000  ................
00000050: 0000 0000 0000 0000 0000 0000 0000 0000  ................
00000060: 0000 0000 0000 0000 0000 0000 0000 0000  ................
00000070: 0000 0000 0000 0000 0000 0000 0000 00d4  ................

关键值解析：
- 位置0-15: "SQLite format 3" ✓
- 位置16-17: 0x10 0x00 = 4096 字节页面大小 ✓
- 位置18: 0x03 = 版本3 ✓
- 位置24-27: 0x00 0x00 0x00 0x01 = 1次更改 ✓
- 位置28-31: 0x00 0x00 0x00 0x0b = 11页 ✓
```

## 7. 快速参考表

### 文件头常见值位置

```
描述                    偏移   大小  类型
─────────────────────────────────────────────
签名                    0     16   ASCII
页面大小                16     2   u16 big-endian
写版本                  18     1   u8
读版本                  19     1   u8
预留字节                20     1   u8
最大有效负荷分数        21     1   u8 (64)
最小有效负荷分数        22     1   u8 (32)
最小叶子有效负荷分数    23     1   u8 (32)
更改计数                24     4   u32 big-endian
数据库页面数            28     4   u32 big-endian
第一自由列表页          32     4   u32 big-endian
自由列表页数            36     4   u32 big-endian
模式Cookie              40     4   u32 big-endian
文件格式                44     4   u32 big-endian
缓存大小                48     4   u32 big-endian
最大根页                52     4   u32 big-endian
文本编码                56     4   u32 big-endian
用户版本                60     4   u32 big-endian
增量真空                64     4   u32 big-endian
应用ID                  68     4   u32 big-endian
版本有效检查            92     4   u32 big-endian
SQLite版本号            96     4   u32 big-endian
```

## 8. 解析工具伪代码

```python
# 伪代码：解析SQLite文件头

def parse_sqlite_header(file_data):
    header = {}
    
    # 字符串字段
    header['signature'] = file_data[0:16].decode('ascii')
    
    # 大端序整数
    header['page_size'] = int.from_bytes(file_data[16:18], 'big')
    if header['page_size'] == 1:
        header['page_size'] = 65536
    
    header['write_version'] = file_data[18]
    header['read_version'] = file_data[19]
    header['reserved_bytes'] = file_data[20]
    
    header['change_counter'] = int.from_bytes(file_data[24:28], 'big')
    header['db_pages'] = int.from_bytes(file_data[28:32], 'big')
    header['first_freelist'] = int.from_bytes(file_data[32:36], 'big')
    header['freelist_pages'] = int.from_bytes(file_data[36:40], 'big')
    
    # 元数据
    header['schema_cookie'] = int.from_bytes(file_data[40:44], 'big')
    header['text_encoding'] = int.from_bytes(file_data[56:60], 'big')
    
    return header

# 解析页面头
def parse_page_header(page_data, is_first_page=False):
    offset = 100 if is_first_page else 0
    
    page_type = page_data[offset]
    freeblock_offset = int.from_bytes(page_data[offset+1:offset+3], 'big')
    cell_count = int.from_bytes(page_data[offset+3:offset+5], 'big')
    cell_content_offset = int.from_bytes(page_data[offset+5:offset+7], 'big')
    fragmented_bytes = page_data[offset+7]
    
    return {
        'page_type': page_type,
        'is_leaf': bool(page_type & 0x08),
        'has_intkey': bool(page_type & 0x01),
        'freeblock_offset': freeblock_offset,
        'cell_count': cell_count,
        'cell_content_offset': cell_content_offset,
        'fragmented_bytes': fragmented_bytes
    }
```

