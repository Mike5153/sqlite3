# SQLite 索引文件存储格式详解

## 概述

SQLite 中的索引是通过 B-Tree 结构存储在数据库文件中的。索引和表使用相同的底层 B-Tree 存储机制，但在逻辑结构和标志位上有所区别。

## 1. 索引的数据结构

### 1.1 索引在内存中的表示 (Index 结构)

在 `sqliteInt.h` 中定义的 Index 结构：

```c
struct Index {
  char *zName;             /* 索引名称 */
  i16 *aiColumn;           /* 索引包含的列编号（第一列为0） */
  LogEst *aiRowLogEst;     /* 从ANALYZE得到的行数估计 */
  Table *pTable;           /* 该索引索引的SQL表 */
  char *zColAff;           /* 每列亲和性的字符串定义 */
  Index *pNext;            /* 关联同一表的下一个索引 */
  Schema *pSchema;         /* 包含此索引的模式 */
  u8 *aSortOrder;          /* 每列的排序顺序: True==DESC, False==ASC */
  const char **azColl;     /* 索引每列的排序规则名称数组 */
  Expr *pPartIdxWhere;     /* 部分索引的WHERE子句 */
  ExprList *aColExpr;      /* 列表达式 */
  Pgno tnum;               /* 包含此索引根的DB页号 */
  LogEst szIdxRow;         /* 估计的平均行大小（字节） */
  u16 nKeyCol;             /* 组成键的列数 */
  u16 nColumn;             /* B-tree中的列数。可以是2*Table.nCol */
  u8 onError;              /* OE_Abort, OE_Ignore, OE_Replace, 或 OE_None */
  unsigned idxType:2;      /* 0:普通 1:UNIQUE, 2:PRIMARY KEY, 3:IPK */
  unsigned bUnordered:1;   /* 仅用于==或IN查询的索引 */
  unsigned uniqNotNull:1;  /* 如果所有列都UNIQUE且NOT NULL */
  unsigned isResized:1;    /* resizeIndexObject()是否被调用 */
};
```

### 1.2 关键字段解释

| 字段 | 含义 |
|------|------|
| `tnum` | 索引根页号 - 最重要的字段，指向B-Tree的根页面 |
| `nKeyCol` | 构成索引键的列数 |
| `nColumn` | B-Tree中实际存储的列数（可能包括隐藏列如ROWID） |
| `aiColumn` | 列映射数组 - 从B-Tree列索引到表列索引的映射 |
| `aSortOrder` | 每列是否为DESC排序 |
| `azColl` | 每列使用的排序规则 |

## 2. B-Tree 页面结构

### 2.1 页面头部 (Page Header)

SQLite 数据库文件被分为固定大小的页面（通常为 4096 字节）。每个页面包含：

```
Byte Offset | Size | Description
------------|------|--------------------------------------------------
0           | 1    | 标志位 (flags)
1           | 2    | 第一个空闲块的字节偏移量
3           | 2    | 此页上的单元格数
5           | 2    | 单元格内容区域的第一个字节
7           | 1    | 分片空闲字节数
8           | 4    | 右子页面（仅内部节点）
```

### 2.2 标志位 (Page Flags)

```c
#define PTF_INTKEY    0x01   /* 键是整数，存储在单元头中 */
#define PTF_ZERODATA  0x02   /* 页面仅包含键，无数据 */
#define PTF_LEAFDATA  0x04   /* LEAFDATA标志 */
#define PTF_LEAF      0x08   /* 叶节点标志 */
```

**索引与表的关键区别**：
- **表（Table B-Tree）**：标志通常为 `PTF_INTKEY | PTF_LEAF` (0x09) 或 `PTF_INTKEY` (0x01)
  - 使用整数主键 (ROWID)
  - 键存储在单元头中
  
- **索引（Index B-Tree）**：标志通常为 `PTF_LEAF` (0x08)
  - 不使用 `PTF_INTKEY` 标志
  - 键作为完整的有效负荷存储
  - 叶节点存储索引键和ROWID引用

### 2.3 页面布局

```
+----------------------+  0
|   file header (100)  |  <- 仅在第1页
+----------------------+ 100
|   page header (8)    |
+----------------------+ 108
|   cell pointers      |  <- 增长向下
|   array              |
|   (2字节/单元格)     |
+----------------------+
|   unallocated space  |
|   (freeblocks)       |
+----------------------+  ^
|   cell content       |  |  增长向上
|   (arbitrary order)  |  |
+----------------------+
```

## 3. 索引单元格 (Index Cell) 格式

### 3.1 索引叶节点单元格

索引的叶节点单元格包含：

```
Structure:
+--------+--------+--------+--------+
| varint | varint | index  | rowid  |
+--------+--------+--------+--------+
  payload  nKey    keys    reference
  size            (variable)
```

**详细格式**：

1. **Payload Size** (varint)
   - 表示单元格有效负荷的总字节数
   - 可变长度整数 (1-9字节)

2. **Key Size** (varint)
   - 表示索引键部分的字节数
   - 对于复合索引，这是所有索引列的大小总和

3. **Index Keys** (Variable length)
   - 实际的索引键数据
   - 格式取决于每列的亲和性
   - 示例：
     - INTEGER: 1-8字节（取决于大小）
     - TEXT: 长度前缀 + UTF-8字符串
     - BLOB: 长度前缀 + 二进制数据
     - REAL: 8字节IEEE 754浮点数
     - NULL: 1字节 (0x00)

4. **ROWID Reference** (varint)
   - 指向源表中相应行的ROWID
   - 用于在索引命中时检索完整行数据

### 3.2 索引内部节点单元格

```
Structure:
+--------+--------+--------+
| PageNo | varint | index  |
+--------+--------+--------+
  left     nKey    keys
  child    (count)
```

1. **Left Child Page Number** (4字节)
   - 左子页面的页号

2. **Key Size** (varint)
   - 分隔键的大小

3. **Separator Key** (Variable length)
   - 用于在树中导航的分隔键

## 4. 变长整数编码 (Varint Encoding)

SQLite使用特殊的变长整数格式：

```
Value              Encoding
0x00               0x00
0x7f               0x7f
0x80               0x81 0x00
0x100              0x82 0x00
0x7f               0x80 0x7f
0x12345678         0x81 0x91 0xd1 0xac 0x78
```

规则：
- 每个字节的低7位是数据
- 第8位表示是否有更多字节（1=有，0=无）
- 最多9个字节可编码64位整数
- 第9个字节使用所有8位

## 5. 实际示例

### 5.1 创建简单索引

```sql
CREATE INDEX idx_name ON users(name);
```

**在数据库中的存储**：

1. **Schema 记录** (sqlite_schema表)
   - 记录索引元数据
   - 存储 CREATE INDEX 语句

2. **B-Tree 结构**
   - 新建一个B-Tree，其根页为 `tnum`
   - 页面标志为 0x08 (PTF_LEAF)

3. **单元格内容** (对每个表行)
   ```
   | varint(keySize) | keySize bytes | varint(rowid) |
   |  索引键大小     |  "John Doe"   |  1            |
   |  14             |  "Alice Smith"|  2            |
   ```

### 5.2 创建复合索引

```sql
CREATE INDEX idx_composite ON users(age, name);
```

**B-Tree 单元格**:
```
| varint(keySize) | age(4) | name_offset | name | varint(rowid) |
|  18             |  25    | "John"      |      |  1            |
|  20             |  30    | "Alice"     |      |  2            |
```

### 5.3 创建UNIQUE索引

```sql
CREATE UNIQUE INDEX idx_email ON users(email);
```

**区别**：
- `idxType` 字段设为 1 (UNIQUE)
- 数据库强制执行唯一性约束
- 在B-Tree中标记为UNIQUE

## 6. 索引的存储优化

### 6.1 Covering Index（覆盖索引）

```sql
CREATE INDEX idx_cover ON users(age, name, email);
```

- 包含查询所需的所有列
- 避免回表查询
- `nColumn` > `nKeyCol`（包含额外列作为payload）

### 6.2 Partial Index（部分索引）

```sql
CREATE INDEX idx_partial ON users(name) WHERE active = 1;
```

- 存储WHERE条件在 `pPartIdxWhere`
- 只索引匹配条件的行
- 占用更少磁盘空间

### 6.3 表达式索引

```sql
CREATE INDEX idx_expr ON users(UPPER(name));
```

- 存储表达式在 `aColExpr`
- 预计算值存储在索引中

## 7. 索引的页面分配

### 7.1 初始状态

```c
int sqlite3BtreeCreateTable(Btree *pBt, Pgno *piTable, int flags)
```

- 分配新页面
- 初始化B-Tree根页
- 返回页号给 `Index.tnum`

### 7.2 页面增长

当索引数据超过单个页面容量时：

1. **页面满** → 分裂
2. **创建中间节点** (internal node)
3. **创建新根** 
4. **树的高度增加**

### 7.3 空间管理

- 使用freelist跟踪空页面
- 分片空闲字节合并
- 可选的auto-vacuum

## 8. 索引的CRUD操作在文件中的表现

### 8.1 INSERT

```
新行被插入到表中 →
↓
对每个索引调用 sqlite3GenerateConstraintChecks
↓
为索引生成VDBE指令
↓
调用 BtreeCursor 在索引B-Tree中查找位置
↓
调用 BtreeInsert 插入新单元格
↓
页面标记为已修改（脏页）
```

### 8.2 DELETE

```
从表中删除行 →
↓
对每个索引调用 sqlite3GenerateConstraintChecks
↓
为索引生成VDBE删除指令
↓
调用 BtreeCursor 查找索引项
↓
调用 BtreeDelete 删除单元格
↓
可能触发页面合并
```

### 8.3 UPDATE

```
两阶段过程：
1. 如果索引键列被修改：
   - DELETE 旧索引项
   - INSERT 新索引项
2. 如果索引键列未修改：
   - 索引保持不变
```

## 9. 文件头中的索引信息

sqlite_schema 表存储索引元数据：

```
type   | name        | tbl_name | rootpage | sql
-------|-------------|----------|----------|--------------------------------
'index'| idx_name    | users    | 5        | CREATE INDEX idx_name ON users(name)
'index'| idx_email   | users    | 6        | CREATE UNIQUE INDEX idx_email...
```

关键字段：
- `rootpage`: B-Tree根页号 (= `Index.tnum`)
- `sql`: 原始CREATE INDEX语句
- `name`: 索引名称

## 10. 索引与日志恢复

### 10.1 事务中的索引修改

在WAL (Write-Ahead Logging) 模式下：

1. 索引修改写入WAL文件
2. 事务提交时sync到磁盘
3. Crash recovery重放修改

### 10.2 Rollback

```c
int sqlite3BtreeRollback(Btree *pBt, int tripCode, int writeOnly);
```

- 恢复索引B-Tree到事务前状态
- 丢弃所有修改

## 11. 查询优化与索引

### 11.1 索引选择

查询优化器通过以下条件选择索引：

```c
/* from whereInt.h */
u32 colUsed;        /* 查询使用的列 */
u32 colNotIdxed;    /* 索引未覆盖的列 */

/* Covering index check */
if( (colUsed & colNotIdxed) == 0 ) {
    /* 这是一个覆盖索引，可以避免回表 */
}
```

### 11.2 查询执行

```
SQL Query
↓
Parse and Compile
↓
Generate Query Plan
   ├─ Full Table Scan
   ├─ Index Scan
   └─ Multi-Index (某些情况)
↓
For Index Scan:
   ├─ Seek to first matching index entry
   ├─ For each matching entry:
   │  ├─ Extract index key(s)
   │  ├─ Get ROWID from index
   │  ├─ Seek to table row (if needed)
   │  └─ Return data
   └─ Continue to next entry or backtrack
```

## 12. 性能特征

### 12.1 B-Tree搜索复杂度

- **查询复杂度**: O(log N)，N为表中行数
- **范围查询**: O(log N + M)，M为匹配行数
- **磁盘I/O**: 通常 2-4 次 page reads

### 12.2 索引大小

```
Index Size ≈ (Sum of index key sizes) × Number of rows
           + B-Tree开销（约10-20%）

Overhead factors:
- 每个单元格的varint长度字段
- 页面头部和指针
- 可能的页面碎片
```

## 总结

SQLite的索引存储基于B-Tree：

1. **结构**：与表相同的B-Tree机制，但无整数主键优化
2. **标志**：索引页面标志通常为 0x08（PTF_LEAF），不含 PTF_INTKEY
3. **单元格**：叶节点包含索引键、大小字段和ROWID引用
4. **存储**：通过sqlite_schema记录元数据，B-Tree存储实际数据
5. **编码**：使用变长整数编码紧凑存储
6. **优化**：支持覆盖索引、部分索引、表达式索引等高级特性
