# SQLite 文件结构 - 源码实现分析

本文档深入分析SQLite源码中文件结构的具体实现。

## 1. 核心数据结构

### 1.1 Pager 结构 (src/pager.h)

Pager是SQLite的页面缓存管理器，负责读写数据库文件：

```c
/* 页面管理结构 */
typedef struct Pager Pager;      // 每个打开的文件一个实例
typedef struct PgHdr DbPage;     // 页面句柄
typedef u32 Pgno;                // 页面号（从1开始，0表示无效）

/* 创建方式 */
int sqlite3PagerOpen(
  sqlite3_vfs *pVfs,            // 虚拟文件系统
  Pager **ppPager,              // 返回Pager实例
  const char *filename,         // 文件路径
  int extra,                    // 每页额外字节数
  int flags,                    // PAGER_OMIT_JOURNAL 等
  int vfsFlags,                 // VFS标志
  void(*)(DbPage*)              // 页面清理回调
);

/* 关键操作 */
int sqlite3PagerGet(Pager *pPager, Pgno pgno, DbPage **ppPage, int clrFlag);
int sqlite3PagerWrite(DbPage*);
void sqlite3PagerUnref(DbPage*);
```

### 1.2 Btree 结构 (src/btree.h)

B树是SQLite的存储引擎核心：

```c
typedef struct Btree Btree;      // B树实例
typedef struct BtCursor BtCursor; // B树游标

/* 打开B树 */
int sqlite3BtreeOpen(
  sqlite3_vfs *pVfs,
  const char *zFilename,
  sqlite3 *db,
  Btree **ppBtree,
  int flags,                    // BTREE_OMIT_JOURNAL等
  int vfsFlags
);

/* 获取元数据 */
void sqlite3BtreeGetMeta(Btree *pBtree, int idx, u32 *pValue);
int sqlite3BtreeUpdateMeta(Btree*, int idx, u32 value);

/* 元数据索引常量 */
#define BTREE_FREE_PAGE_COUNT     0   // 偏移: 32
#define BTREE_SCHEMA_VERSION      1   // 偏移: 40
#define BTREE_FILE_FORMAT         2   // 偏移: 44
#define BTREE_DEFAULT_CACHE_SIZE  3   // 偏移: 48
#define BTREE_LARGEST_ROOT_PAGE   4   // 偏移: 52
#define BTREE_TEXT_ENCODING       5   // 偏移: 56
#define BTREE_USER_VERSION        6   // 偏移: 60
#define BTREE_INCR_VACUUM         7   // 偏移: 64
#define BTREE_APPLICATION_ID      8   // 偏移: 68
#define BTREE_DATA_VERSION        15  // 虚拟值
```

### 1.3 BtShared 结构 (src/btreeInt.h)

BtShared包含在内存中被共享的B树信息：

```c
struct BtShared {
  Pager *pPager;           // 关联的页面缓存
  Pgno pageSize;           // 页面大小（字节）
  u8 openFlags;            // 打开标志
  u8 autoVacuum;           // 自动真空模式
  u8 incrVacuum;           // 增量真空模式
  u8 isInit;               // 初始化标志
  u16 maxLocal;            // 最大本地有效负荷
  u16 minLocal;            // 最小本地有效负荷
  u16 maxLeaf;             // 最大叶子有效负荷
  u16 minLeaf;             // 最小叶子有效负荷
  u32 pageCount;           // 数据库页面总数
  
  /* 缓存部分 */
  MemPage *pPage1;         // 第一页的缓存副本
  sqlite3 *db;             // 数据库连接
  
  /* ... 其他字段 ... */
};
```

### 1.4 MemPage 结构 (src/btreeInt.h)

MemPage是页面在内存中的表示形式：

```c
struct MemPage {
  u8 isInit;               /* 必须是第一个，初始化标志 */
  u8 intKey;               /* 整数键表标志 */
  u8 intKeyLeaf;           /* 整数键叶子标志 */
  Pgno pgno;               /* 页面号 */
  
  /* 只有前8字节由pager初始化为0 */
  u8 leaf;                 /* 叶子页面标志 */
  u8 hdrOffset;            /* 100表示第一页，否则为0 */
  u8 childPtrSize;         /* 0=叶子, 4=内部节点 */
  u8 max1bytePayload;      /* min(maxLocal, 127) */
  u8 nOverflow;            /* 溢出单元体数量 */
  u16 maxLocal;            /* 最大本地有效负荷大小 */
  u16 minLocal;            /* 最小本地有效负荷大小 */
  u16 cellOffset;          /* 第一个单元指针的索引 */
  int nFree;               /* 页面上的自由字节数 (-1=未知) */
  u16 nCell;               /* 本页面上的单元数 */
  u16 maskPage;            /* 页面偏移掩码 */
  
  u16 aiOvfl[4];           /* 溢出单元插入位置 */
  u8 *apOvfl[4];           /* 溢出单元体指针 */
  
  BtShared *pBt;           /* 所属的BtShared指针 */
  u8 *aData;               /* 页面数据指针 */
  u8 *aDataEnd;            /* 页面末尾+1 */
  u8 *aCellIdx;            /* 单元索引区域 */
  u8 *aDataOfst;           /* 叶子为aData, 内部节点为aData+4 */
  DbPage *pDbPage;         /* Pager页面句柄 */
  
  u16 (*xCellSize)(MemPage*,u8*);      /* 单元大小计算方法 */
  void (*xParseCell)(MemPage*,u8*,CellInfo*); /* 单元解析方法 */
};
```

## 2. 文件格式常数定义

### 2.1 文件头常数 (src/btreeInt.h)

```c
/* 文件头签名 */
#define SQLITE_FILE_HEADER "SQLite format 3"

/* 文件头大小 */
#define SQLITE_FILE_HEADER_SIZE 16

/* 数据库页面信息 */
#define PENDING_BYTE 0x40000000     // 待定字节位置用于锁定
#define MAX_PAGE_SIZE 65536         // 最大页面大小
#define DEFAULT_PAGE_SIZE 4096      // 默认页面大小
#define MIN_PAGE_SIZE 512           // 最小页面大小
```

### 2.2 页面类型标志 (src/btreeInt.h)

```c
/* 页面第一个字节的标志位 */
#define PTF_INTKEY    0x01  /* 整数键表 */
#define PTF_ZERODATA  0x02  /* 零数据页面 */
#define PTF_LEAFDATA  0x04  /* 叶子数据 */
#define PTF_LEAF      0x08  /* 叶子页面 */

/* 页面结构中的偏移量 */
#define PAGE_HDRSIZE 8              /* 叶子页面头大小 */
#define PAGE_HDRSIZE_INT 12         /* 内部节点页面头大小 */
```

## 3. 页面头部读写实现

### 3.1 页面头部宏定义 (src/btreeInt.h)

```c
/* 从页面数据读取页面头部字段的宏 */

/* 得到页面类型（第一个字节）*/
#define get_page_type(a) ((a)[0])

/* 得到自由块偏移（偏移1-2，大端序）*/
#define get_ptrmap_offset(aData) (get2byte(&(aData)[1]))

/* 得到单元数（偏移3-4，大端序）*/
#define get_cell_count(aData) (get2byte(&(aData)[3]))

/* 得到单元内容起始偏移（偏移5-6，大端序）*/
#define get_cell_content_offset(aData) (get2byte(&(aData)[5]))

/* 得到碎片字节数（偏移7）*/
#define get_frag_bytes(aData) ((aData)[7])

/* 得到右子页面（偏移8-11，大端序，仅内部节点）*/
#define get_right_child(aData) (get4byte(&(aData)[8]))
```

### 3.2 大小端转换函数

```c
/* SQLite使用大端序（网络字节序）存储多字节整数 */

/* 读取16位大端序整数 */
static u16 get2byte(const u8 *p){
  return (p[0]<<8) | p[1];
}

/* 读取32位大端序整数 */
static u32 get4byte(const u8 *p){
  return (((u32)p[0])<<24) | (((u32)p[1])<<16) |
         (((u32)p[2])<<8) | p[3];
}

/* 写入32位大端序整数 */
static void put4byte(unsigned char *p, u32 v){
  p[0] = (u8)(v>>24);
  p[1] = (u8)(v>>16);
  p[2] = (u8)(v>>8);
  p[3] = (u8)v;
}
```

## 4. 变长整数 (Varint) 编码

### 4.1 Varint编码/解码 (src/btreeInt.h的相关实现)

```c
/* 使用标准SQLite varint格式编码 */
#define varintEncode(X,Y) \
  (((Y) < (u64)0x80) ? 1 : \
   ((Y) < (u64)0x4000) ? 2 : \
   ((Y) < (u64)0x200000) ? 3 : \
   ((Y) < (u64)0x10000000) ? 4 : \
   ((Y) < (u64)0x800000000) ? 5 : \
   ((Y) < (u64)0x40000000000) ? 6 : \
   ((Y) < (u64)0x2000000000000) ? 7 : \
   ((Y) < (u64)0x100000000000000) ? 8 : 9)
```

### 4.2 Varint解码实现伪代码

```c
/* 解码变长整数 */
u64 sqlite3Varint64(const unsigned char *p, const unsigned char *pEnd, u64 *v){
  u32 a,b,s = 0;
  *v = 0;
  for(a=0; a<8 && p<pEnd && p[a]>=0x80; a++, s+=7){
    *v += ((u64)(p[a]&0x7f)) << s;
  }
  if( a==8 || p>=pEnd ){
    return a + 1;  /* 错误情况或需要第9字节 */
  }
  if( p[a] < 0x80 ){
    *v += ((u64)p[a]) << s;
    return a + 1;
  }
  /* ... 处理第9字节的所有8位 ... */
}
```

## 5. 单元解析

### 5.1 CellInfo 结构 (src/btreeInt.h)

```c
struct CellInfo {
  u8 *pCell;      /* 单元起始指针 */
  i64 iKey;       /* 键值（仅INTKEY表） */
  u32 nData;      /* 有效负荷大小 */
  u32 nHeader;    /* 单元头大小 */
  u16 nLocal;     /* 本地存储的有效负荷 */
  u16 iOverflow;  /* 溢出数据起始位置 */
  u32 nSize;      /* 单元总大小 */
};
```

### 5.2 单元解析函数实现

```c
/* 定义在btree.c中的单元解析 */
static void btreeParseCell(
  MemPage *pPage,    /* 页面 */
  u8 *pCell,         /* 单元指针 */
  CellInfo *pInfo    /* 输出的单元信息 */
){
  u8 *pIter = &pCell[pPage->childPtrSize];  /* 跳过左子指针（如果存在） */
  u32 nPayload;
  u32 iKey = 0;
  
  if( pPage->intKey ){
    /* INTKEY表：第一个varint是有效负荷大小，第二个是键值 */
    iKey = getVarint(pIter, &nPayload);
    iKey = getVarint(&pIter[iKey], pInfo);
  }else{
    /* 索引表：第一个varint是键大小 */
    iKey = getVarint(pIter, &nPayload);
  }
  
  pInfo->nData = nPayload;
  pInfo->nHeader = pIter - pCell;
  pInfo->iKey = iKey;
  pInfo->nLocal = /* ... 计算本地大小 ... */;
  pInfo->iOverflow = /* ... 计算溢出位置 ... */;
}
```

## 6. 页面初始化

### 6.1 新建页面 (src/btree.c)

```c
/* 初始化新页面 */
int btreeInitPage(MemPage *pPage){
  int pc;            /* 单元指针计数 */
  int hdr;           /* 页面头开始位置 */
  u8 *data;          /* 页面数据 */
  
  data = pPage->aData;
  hdr = pPage->hdrOffset;
  
  pPage->isInit = 1;
  pPage->leaf = (data[hdr] & PTF_LEAF) != 0;
  pPage->intKey = (data[hdr] & PTF_INTKEY) != 0;
  pPage->zeroData = (data[hdr] & PTF_ZERODATA) != 0;
  pPage->intKeyLeaf = (data[hdr] & PTF_LEAFDATA) != 0;
  
  /* 页面偏移计算 */
  pPage->cellOffset = 8 + hdr;  /* PTF_LEAF为0x08 */
  if( !pPage->leaf ){
    pPage->cellOffset += 4;     /* 内部节点有4字节右指针 */
  }
  
  /* 单元指针信息 */
  pPage->nCell = (hdr + 3 < pPage->aDataEnd) ? 
    get2byte(&data[hdr+3]) : 0;
  
  /* ... 更多初始化 ... */
  
  return SQLITE_OK;
}
```

## 7. 自由列表管理

### 7.1 自由列表操作 (src/btree.c中的实现)

```c
/* 获取自由页面 */
static int allocatePage(
  BtShared *pBt,    /* B树 */
  MemPage **ppPage, /* 返回分配的页面 */
  Pgno *pPgno,      /* 返回页面号 */
  Pgno nearby,      /* 建议的页面位置 */
  u8 exact           /* 是否必须精确匹配 */
){
  Pgno pgno;
  MemPage *pPage1 = pBt->pPage1;  /* 第一页 */
  
  /* 从自由列表中查找 */
  pgno = sqlite3Get4byte(&pPage1->aData[32]);  /* 第一个自由列表页 */
  
  if( pgno ){
    /* 有自由列表，从中获取 */
    /* ... */
  }else{
    /* 没有自由列表，在文件末尾分配新页面 */
    pgno = sqlite3PagerPagecount(pBt->pPager);
    pgno++;
  }
  
  /* ... 返回页面 ... */
}
```

### 7.2 自由列表树干页面格式

```c
/* 读取自由列表树干页面 */
static void getFreepageCount(
  BtShared *pBt,
  Pgno pgnoTrunk,  /* 树干页面号 */
  int *pnFree      /* 输出：自由页面数 */
){
  MemPage *pTrunk;
  u8 *aData;
  
  /* 读取树干页面 */
  sqlite3PagerGet(pBt->pPager, pgnoTrunk, &pTrunk, 0);
  aData = pTrunk->aData;
  
  /* 树干页面格式：
     4字节：下一个树干页面号
     4字节：此树干上的叶子页面数
     4字节..：叶子页面号列表
  */
  
  *pnFree = sqlite3Get4byte(&aData[4]);  /* 叶子页面数 */
  
  sqlite3PagerUnref(pTrunk);
}
```

## 8. 溢出处理

### 8.1 溢出页面读取 (src/btree.c)

```c
/* 从溢出页面读取数据 */
int getOverflowData(
  MemPage *pPage,           /* 原始页面 */
  u32 offset,               /* 溢出起始偏移 */
  u32 amt,                  /* 要读取的字节数 */
  unsigned char *pBuf       /* 输出缓冲 */
){
  Pgno nextPage;            /* 下一个溢出页面 */
  u32 nCopy;                /* 本页要复制的字节数 */
  const unsigned char *aPayload;  /* 溢出页数据 */
  
  while( amt > 0 ){
    /* 当前页数据 */
    aPayload = pPage->aData + 4;  /* 跳过页面指针 */
    nCopy = pBt->pageSize - 4;    /* 可用数据大小 */
    
    if( nCopy > amt ){
      nCopy = amt;
    }
    
    memcpy(pBuf, aPayload, nCopy);
    amt -= nCopy;
    pBuf += nCopy;
    
    /* 获取下一个溢出页面 */
    nextPage = sqlite3Get4byte(pPage->aData);
    
    if( nextPage == 0 ) break;  /* 最后一页 */
    
    /* 读取下一个页面 */
    sqlite3PagerGet(pBt->pPager, nextPage, &pPage, 0);
  }
  
  return SQLITE_OK;
}
```

## 9. 事务和日志

### 9.1 日志模式常数 (src/pager.h)

```c
/* 日志模式 */
#define PAGER_JOURNALMODE_QUERY     (-1)
#define PAGER_JOURNALMODE_DELETE      0  /* 删除日志文件 */
#define PAGER_JOURNALMODE_PERSIST     1  /* 保留日志 */
#define PAGER_JOURNALMODE_OFF         2  /* 无日志 */
#define PAGER_JOURNALMODE_TRUNCATE    3  /* 截断日志 */
#define PAGER_JOURNALMODE_MEMORY      4  /* 内存日志 */
#define PAGER_JOURNALMODE_WAL         5  /* 写前日志 */
```

### 9.2 Pager状态 (src/pager.c)

```c
/* Pager状态机 */
#define PAGER_OPEN            0  /* 文件打开 */
#define PAGER_READER          1  /* 持有读锁 */
#define PAGER_WRITER_LOCKED   2  /* 持有写锁 */
#define PAGER_WRITER_CACHEMOD 3  /* 缓存被修改 */
#define PAGER_WRITER_DBMOD    4  /* 数据库被修改 */
#define PAGER_WRITER_FINISHED 5  /* 写入完成 */
#define PAGER_ERROR           6  /* 错误状态 */
```

## 10. 关键查询方法

```c
/* 获取页面大小 */
int sqlite3BtreeGetPageSize(Btree *p){
  return sqlite3BtreeGetReserveNoMutex(p)->pageSize;
}

/* 获取元数据 */
void sqlite3BtreeGetMeta(Btree *pBtree, int idx, u32 *pValue){
  unsigned char *p = &pBtree->pBt->pPage1->aData[36 + idx*4];
  *pValue = (p[0]<<24) | (p[1]<<16) | (p[2]<<8) | p[3];
}

/* 获取数据库页面数 */
void sqlite3BtreePagecount(Btree *p, int *pnPage){
  *pnPage = sqlite3PagerPagecount(sqlite3BtreePager(p));
}

/* 检查是否为只读 */
int sqlite3BtreeIsReadonly(Btree *pBt){
  return sqlite3PagerIsreadonly(pBt->pBt->pPager);
}
```

## 11. 总结

SQLite的文件结构实现包括：

1. **分层管理**：Pager（页面缓存）→ Btree（B树逻辑）→ MemPage（内存表示）
2. **大端序**：所有多字节整数均为大端序
3. **变长整数**：节省空间的编码方式
4. **灵活的页面大小**：512-65536字节，默认4096
5. **自由列表管理**：链表式的自由页面跟踪
6. **溢出处理**：超大数据自动溢出到专用页面
7. **事务支持**：多种日志模式和状态管理

