# SQLite Index 结构体初始化详解

## 概述

SQLite中的Index结构体有两个主要初始化途径：
1. **执行CREATE INDEX语句时** - 动态创建新索引
2. **读取数据库schema时** - 从sqlite_schema表恢复已存在的索引

本文详细分析这两个过程。

## 一、CREATE INDEX 执行流程

### 1.1 函数调用链

```
Parser (parse.y)
  ↓
sqlite3CreateIndex() [build.c:3923]
  ├─ sqlite3AllocateIndexObject() [build.c:3860] - 分配内存
  ├─ 初始化Index结构体字段
  └─ 生成VDBE指令/插入schema
```

### 1.2 详细步骤

#### 第一步：内存分配 - `sqlite3AllocateIndexObject()`

**文件**: `src/build.c`  
**行号**: 3860-3888

```c
Index *sqlite3AllocateIndexObject(
  sqlite3 *db,         /* 数据库连接 */
  int nCol,            /* 索引列数 */
  int nExtra,          /* 额外空间字节数 */
  char **ppExtra       /* 返回额外空间指针 */
)
```

**内存布局**:
```
┌─────────────────────────┐
│  Index struct (固定)     │ ROUND8(sizeof(Index))
├─────────────────────────┤
│  azColl指针数组          │ ROUND8(sizeof(char*)*nCol)
├─────────────────────────┤
│  aiRowLogEst数组         │ ROUND8(sizeof(LogEst)*(nCol+1))
├─────────────────────────┤
│  aiColumn数组            │ sizeof(i16)*nCol
├─────────────────────────┤
│  aSortOrder数组          │ sizeof(u8)*nCol
├─────────────────────────┤
│  额外空间 (zName等)       │ nExtra字节
└─────────────────────────┘
```

**关键代码** (3870-3887):
```c
nByte = ROUND8(sizeof(Index)) +              /* Index结构 */
        ROUND8(sizeof(char*)*nCol) +         /* azColl数组 */
        ROUND8(sizeof(LogEst)*(nCol+1) +     /* aiRowLogEst数组 */
               sizeof(i16)*nCol +             /* aiColumn数组 */
               sizeof(u8)*nCol);              /* aSortOrder数组 */
p = sqlite3DbMallocZero(db, nByte + nExtra);

if( p ){
  char *pExtra = ((char*)p)+ROUND8(sizeof(Index));
  p->azColl = (const char**)pExtra;          /* 第1个数组 */
  pExtra += ROUND8(sizeof(char*)*nCol);
  p->aiRowLogEst = (LogEst*)pExtra;          /* 第2个数组 */
  pExtra += sizeof(LogEst)*(nCol+1);
  p->aiColumn = (i16*)pExtra;                /* 第3个数组 */
  pExtra += sizeof(i16)*nCol;
  p->aSortOrder = (u8*)pExtra;               /* 第4个数组 */
  p->nColumn = (u16)nCol;
  p->nKeyCol = (u16)(nCol - 1);
}
```

#### 第二步：基础字段初始化 - `sqlite3CreateIndex()`

**文件**: `src/build.c`  
**行号**: 3923-4500

**4149-4163行** - 初始化核心字段:

```c
pIndex = sqlite3AllocateIndexObject(db, pList->nExpr + nExtraCol,
                                    nName + nExtra + 1, &zExtra);

pIndex->zName = zExtra;              /* 索引名称 */
zExtra += nName + 1;
memcpy(pIndex->zName, zName, nName+1);

pIndex->pTable = pTab;               /* 关联的表 */
pIndex->onError = (u8)onError;       /* 冲突解决方案 (OE_*) */
pIndex->uniqNotNull = onError!=OE_None;  /* UNIQUE标志 */
pIndex->idxType = idxType;           /* 索引类型 */
pIndex->pSchema = db->aDb[iDb].pSchema;  /* Schema指针 */
pIndex->nKeyCol = pList->nExpr;      /* Key列数 */
```

**字段含义**:

| 字段 | 值 | 含义 |
|------|-----|------|
| `zName` | 字符串 | 索引名称 |
| `pTable` | Table* | 指向被索引的表 |
| `onError` | OE_Abort等 | UNIQUE冲突时的行为 |
| `idxType` | 0-3 | 0=普通, 1=UNIQUE, 2=PRIMARY KEY, 3=IPK |
| `pSchema` | Schema* | 所属Schema |
| `nKeyCol` | 整数 | 索引键列数 |
| `nColumn` | 整数 | B-Tree总列数 |

#### 第三步：列信息初始化

**文件**: `src/build.c`  
**行号**: 4194-4254

处理索引每一列的信息：

```c
for(i=0; i<pIndex->nKeyCol; i++, pListItem++){
  Expr *pCExpr;
  int requestedSortOrder;
  const char *zColl;

  /* 解析列表达式 */
  sqlite3StringToId(pListItem->pExpr);
  sqlite3ResolveSelfReference(pParse, pTab, NC_IdxExpr, 
                              pListItem->pExpr, 0);
  
  pCExpr = sqlite3ExprSkipCollate(pListItem->pExpr);
  
  /* 检查是否为表达式 */
  if( pCExpr->op!=TK_COLUMN ){
    /* 表达式索引 */
    j = XN_EXPR;
    pIndex->aiColumn[i] = XN_EXPR;  /* 标记为表达式 */
    pIndex->uniqNotNull = 0;
    pIndex->bHasExpr = 1;
  }else{
    /* 普通列索引 */
    j = pCExpr->iColumn;
    pIndex->aiColumn[i] = (i16)j;   /* 存储列索引 */
  }
  
  /* 获取排序规则 */
  if( pListItem->pExpr->op==TK_COLLATE ){
    /* 显式指定排序规则 */
    zColl = pListItem->pExpr->u.zToken;
  }else if( j>=0 ){
    /* 使用列的默认排序规则 */
    zColl = sqlite3ColumnColl(&pTab->aCol[j]);
  }
  
  pIndex->azColl[i] = zColl;        /* 存储排序规则 */
  
  /* 获取排序顺序 (ASC/DESC) */
  requestedSortOrder = pListItem->fg.sortFlags & sortOrderMask;
  pIndex->aSortOrder[i] = (u8)requestedSortOrder;  /* 1=DESC, 0=ASC */
}
```

**aiColumn数组说明**:
- 值 >= 0: 表列索引（0表示第一列）
- 值 = XN_ROWID (-1): ROWID
- 值 = XN_EXPR (-2): 表达式索引

#### 第四步：添加隐含列

**文件**: `src/build.c`  
**行号**: 4260-4278

```c
/* 添加表的主键到索引末尾 */
if( pPk ){
  for(j=0; j<pPk->nKeyCol; j++){
    int x = pPk->aiColumn[j];
    if( !isDupColumn(pIndex, pIndex->nKeyCol, pPk, j) ){
      pIndex->aiColumn[i] = x;
      pIndex->azColl[i] = pPk->azColl[j];
      pIndex->aSortOrder[i] = pPk->aSortOrder[j];
      i++;
    }
  }
}else{
  /* 普通表：添加ROWID列 */
  pIndex->aiColumn[i] = XN_ROWID;
  pIndex->azColl[i] = sqlite3StrBINARY;
}
```

#### 第五步：链接到表和Schema

**文件**: `src/build.c`  
**行号**: 4467-4468

```c
pIndex->pNext = pTab->pIndex;   /* 链接到表的索引链表 */
pTab->pIndex = pIndex;
```

#### 第六步：生成VDBE指令

**文件**: `src/build.c`  
**行号**: 4405-4509

在`db->init.busy == 0`时（正常操作），生成VDBE指令：

```c
v = sqlite3GetVdbe(pParse);
/* OP_CreateIndex - 分配B-Tree根页 */
/* OP_OpenWrite - 打开索引B-Tree游标 */
/* OP_Seek - 定位到表中的行 */
/* OP_MakeRecord - 构造索引键 */
/* OP_InsertIdx - 插入到索引 */
```

#### 第七步：更新sqlite_schema表

**文件**: `src/build.c`  
**行号**: 4442-4449

```c
/* 生成INSERT INTO sqlite_schema语句 */
zStmt = sqlite3MPrintf(db,
    "INSERT INTO %s VALUES('index',%Q,%Q,%d,%Q)",
    SCHEMA_TABLE(iDb),
    pIndex->zName,       /* index name */
    pTab->zName,         /* table name */
    pIndex->tnum,        /* rootpage */
    zCreateIndex         /* CREATE INDEX语句 */
);
```

---

## 二、从sqlite_schema恢复Index

### 2.1 初始化流程

```
sqlite3Init() [prepare.c:437]
  ↓
sqlite3InitOne() [prepare.c:198]
  ├─ 读取sqlite_schema表
  └─ sqlite3InitCallback() [prepare.c:95] - 对每一行调用
      ├─ 如果sql字段非空 → 解析CREATE INDEX语句
      │   └─ sqlite3CreateIndex() - 创建Index对象
      └─ 如果sql字段为空 → 直接设置tnum
```

### 2.2 详细步骤

#### 第一步：打开数据库时初始化Schema

**文件**: `src/prepare.c`  
**行号**: 198-426

```c
int sqlite3InitOne(sqlite3 *db, int iDb, char **pzErrMsg, u32 mFlags){
  /* ... 初始化代码 ... */
  
  /* 第364-373行：执行SELECT查询读取sqlite_schema表 */
  char *zSql;
  zSql = sqlite3MPrintf(db, 
      "SELECT * FROM \"%w\".%s ORDER BY rowid",
      db->aDb[iDb].zDbSName, zSchemaTabName);
  
  /* 第373行：对每一行调用回调函数 */
  rc = sqlite3_exec(db, zSql, sqlite3InitCallback, &initData, 0);
}
```

**SQL查询返回的行格式**:
```
列0 (type)    | 列1 (name)      | 列2 (tbl_name) | 列3 (rootpage) | 列4 (sql)
'index'       | idx_name        | users          | 5              | CREATE INDEX...
'index'       | sqlite_autoidx_1| users          | 6              | (NULL)
```

#### 第二步：回调处理每一行

**文件**: `src/prepare.c`  
**行号**: 95-188

```c
int sqlite3InitCallback(void *pInit, int argc, char **argv, char **NotUsed){
  InitData *pData = (InitData*)pInit;
  sqlite3 *db = pData->db;
  int iDb = pData->iDb;
  
  /* argv参数:
     argv[0] = type ('table'/'index'/'view')
     argv[1] = name (索引/表/视图名)
     argv[2] = tbl_name (关联的表名)
     argv[3] = rootpage (B-Tree根页号)
     argv[4] = sql (CREATE语句)
  */
```

**路径A：sql字段非空（显式CREATE INDEX）**

**行号**: 114-162

```c
if( argv[4]
    && 'c'==sqlite3UpperToLower[(unsigned char)argv[4][0]]
    && 'r'==sqlite3UpperToLower[(unsigned char)argv[4][1]] ){
  /* 检查首字符是否为'CR'（CREATE） */
  
  /* 第134-140行：验证rootpage有效性 */
  if( sqlite3GetUInt32(argv[3], &db->init.newTnum)==0
   || (db->init.newTnum>pData->mxPage && pData->mxPage>0)
  ){
    if( sqlite3Config.bExtraSchemaChecks ){
      corruptSchema(pData, argv, "invalid rootpage");
    }
  }
  
  /* 第144行：解析CREATE INDEX语句 */
  sqlite3Prepare(db, argv[4], -1, 0, 0, &pStmt, 0);
  /* 这会调用parser，最终调用sqlite3CreateIndex()
     创建Index对象，使用db->init.newTnum作为tnum */
}
```

**路径B：sql字段为空（自动创建的索引）**

**行号**: 163-186

```c
else if( argv[1]==0 || (argv[4]!=0 && argv[4][0]!=0) ){
  corruptSchema(pData, argv, 0);
}else{
  /* sql字段为空，这是自动创建的PRIMARY KEY或UNIQUE索引
     Index对象已在CREATE TABLE时创建
     现在只需设置rootpage */
  
  Index *pIndex;
  
  /* 第173行：在已存在的索引中查找 */
  pIndex = sqlite3FindIndex(db, argv[1], db->aDb[iDb].zDbSName);
  
  if( pIndex==0 ){
    corruptSchema(pData, argv, "orphan index");
  }else
  
  /* 第177-185行：验证并设置tnum */
  if( sqlite3GetUInt32(argv[3], &pIndex->tnum)==0  /* 转换rootpage */
   || pIndex->tnum<2                                /* 不能是特殊页 */
   || pIndex->tnum>pData->mxPage                    /* 不能超过最大页 */
   || sqlite3IndexHasDuplicateRootPage(pIndex)     /* 不能重复 */
  ){
    if( sqlite3Config.bExtraSchemaChecks ){
      corruptSchema(pData, argv, "invalid rootpage");
    }
  }
  
  /* 设置根页号 */
  pIndex->tnum = 根页号;
}
```

### 2.3 sqlite_schema表结构

**表定义**:
```sql
CREATE TABLE sqlite_schema(
  type text,      /* 'table'/'index'/'view'/'trigger' */
  name text,      /* 对象名称 */
  tbl_name text,  /* 关联表名（仅对index/trigger） */
  rootpage int,   /* B-Tree根页号 */
  sql text        /* 创建对象的SQL语句 */
)
```

**索引条目示例**:
```
type    | name              | tbl_name | rootpage | sql
--------|-------------------|----------|----------|------
'index' | idx_users_name    | users    | 5        | CREATE INDEX idx_users_name ON users(name)
'index' | idx_users_email   | users    | 6        | CREATE UNIQUE INDEX idx_users_email ON users(email)
'index' | sqlite_autoindex  | users    | 7        | (NULL)
```

---

## 三、Index结构体字段初始化总结

### 3.1 所有字段及其初始化位置

| 字段 | 类型 | 初始化位置 | 说明 |
|------|------|-----------|------|
| `zName` | char* | build.c:4156-4158 | 索引名称 |
| `aiColumn` | i16* | build.c:4194-4232, 4268, 4276 | 列索引数组 |
| `aiRowLogEst` | LogEst* | build.c:3879, 4279 | 行数估算 |
| `pTable` | Table* | build.c:4159 | 指向表 |
| `zColAff` | char* | 选项特定 | 列亲和性 |
| `pNext` | Index* | build.c:4467 | 索引链表指针 |
| `pSchema` | Schema* | build.c:4163 | 指向Schema |
| `aSortOrder` | u8* | build.c:4253 | 排序顺序 |
| `azColl` | const char** | build.c:4251 | 排序规则数组 |
| `pPartIdxWhere` | Expr* | build.c:4165-4168 | 部分索引条件 |
| `aColExpr` | ExprList* | build.c:4191, 4210 | 列表达式 |
| `tnum` | Pgno | prepare.c:4375或177 | B-Tree根页号 |
| `szIdxRow` | LogEst | 数据库估算 | 行大小估算 |
| `nKeyCol` | u16 | build.c:4164 或 3884 | Key列数 |
| `nColumn` | u16 | build.c:3883, 4265 | 总列数 |
| `onError` | u8 | build.c:4160 | 冲突解决 |
| `idxType` | unsigned:2 | build.c:4162 | 索引类型 |
| `bUnordered` | unsigned:1 | 默认0 | 是否无序 |
| `uniqNotNull` | unsigned:1 | build.c:4161, 4224 | UNIQUE标志 |

### 3.2 关键初始化时机

```
CREATE INDEX执行:
  ├─ 内存分配 (sqlite3AllocateIndexObject)
  ├─ 基础字段初始化
  ├─ 列信息初始化
  ├─ 链接到表
  ├─ 生成VDBE指令
  └─ 插入sqlite_schema

数据库打开恢复:
  ├─ 读取sqlite_schema表
  ├─ 对每一行调用sqlite3InitCallback
  ├─ 如果sql非空: 解析并重新创建Index对象
  └─ 如果sql为空: 只设置tnum字段
```

---

## 四、特殊情况分析

### 4.1 PRIMARY KEY索引

当CREATE TABLE时定义PRIMARY KEY：

```sql
CREATE TABLE users(
  id INTEGER PRIMARY KEY,
  name TEXT
);
```

**初始化过程**:
1. CREATE TABLE执行时，识别PRIMARY KEY
2. 调用`sqlite3CreateIndex()`创建自动索引
3. `idxType`设为`SQLITE_IDXTYPE_PRIMARYKEY`
4. `sql`字段为NULL（自动生成的索引）
5. 从sqlite_schema恢复时，不重新解析SQL，直接设置tnum

### 4.2 UNIQUE约束索引

```sql
CREATE TABLE users(
  email TEXT UNIQUE
);
```

**初始化过程**:
1. 自动创建UNIQUE索引
2. `idxType`设为`SQLITE_IDXTYPE_APPDEF`
3. `onError`设为`OE_Abort`或`OE_Replace`
4. `uniqNotNull`设为1
5. 索引名称自动生成为`sqlite_autoindex_表名_序号`

### 4.3 表达式索引

```sql
CREATE INDEX idx_upper ON users(UPPER(name));
```

**初始化过程**:
1. `pCExpr->op != TK_COLUMN`，进入表达式处理
2. `aiColumn[0]`设为`XN_EXPR`(-2)
3. 表达式存储在`aColExpr`中
4. `bHasExpr`设为1
5. `uniqNotNull`设为0（表达式不能是UNIQUE）

### 4.4 部分索引

```sql
CREATE INDEX idx_active ON users(id) WHERE active = 1;
```

**初始化过程**:
1. WHERE表达式解析并存储在`pPartIdxWhere`
2. 使用`sqlite3ResolveSelfReference()`解析自引用
3. 索引的B-Tree中只包含满足条件的行

---

## 五、调试技巧

### 在gdb中检查Index对象

```c
/* 当程序在sqlite3CreateIndex中断点时 */
(gdb) p *pIndex
(gdb) p pIndex->zName
(gdb) p pIndex->aiColumn[0]
(gdb) p pIndex->azColl[0]
(gdb) p pIndex->tnum

/* 查看表的索引链表 */
(gdb) p pTab->pIndex
(gdb) p pTab->pIndex->pNext
(gdb) p pTab->pIndex->pNext->zName
```

### 跟踪初始化过程

```sql
-- 在打开数据库时启用PRAGMA来观察索引
PRAGMA integrity_check;           -- 验证索引完整性
PRAGMA index_list(tablename);     -- 列出表的所有索引
PRAGMA index_info(indexname);     -- 查看索引的列信息
PRAGMA index_xinfo(indexname);    -- 查看扩展索引信息
```

---

## 参考资源

- **源文件**:
  - `src/sqliteInt.h` - Index结构体定义 (行2787)
  - `src/build.c` - sqlite3CreateIndex() (行3923)
  - `src/build.c` - sqlite3AllocateIndexObject() (行3860)
  - `src/prepare.c` - sqlite3InitOne() (行198)
  - `src/prepare.c` - sqlite3InitCallback() (行95)

- **关键函数**:
  - `sqlite3CreateIndex()` - 创建索引
  - `sqlite3AllocateIndexObject()` - 分配内存
  - `sqlite3InitOne()` - Schema初始化
  - `sqlite3InitCallback()` - Schema回调
  - `sqlite3FindIndex()` - 查找索引
