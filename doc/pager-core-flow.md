# SQLite Pager 核心流程梳理

## 概述

Pager 是SQLite的页面缓存和事务管理子系统，负责：
- 数据库文件的页面级读写
- 事务的原子性保证（通过日志机制）
- 文件锁定和并发控制
- 页面缓存管理

## Pager 状态机

Pager 在以下7个状态间转换：

```
                        OPEN <------+------+
                          |         |      |
                          V         |      |
          +---------> READER-------+      |
          |              |                |
          |              V                |
          |<-------WRITER_LOCKED------> ERROR
          |              |                ^ 
          |              V                |
          |<------WRITER_CACHEMOD-------->|
          |              |                |
          |              V                |
          |<-------WRITER_DBMOD---------->|
          |              |                |
          |              V                |
          +<------WRITER_FINISHED-------->+
```

### 状态说明

| 状态 | 描述 | 能做什么 |
|------|------|--------|
| **OPEN** | 初始状态 | 无法读写，锁定状态未知 |
| **READER** | 读事务打开 | 可读，持有 SHARED 锁，数据库大小已知 |
| **WRITER_LOCKED** | 写事务开始 | 持有 RESERVED 锁，还未修改任何页 |
| **WRITER_CACHEMOD** | 写事务进行中 | 日志文件已打开，页被加载到缓存 |
| **WRITER_DBMOD** | 数据库已修改 | 脏页已写入日志，准备提交 |
| **WRITER_FINISHED** | 提交第一阶段完成 | 准备进入第二阶段 |
| **ERROR** | 错误状态 | 任何操作都会返回错误 |

## 核心数据结构

### Pager 结构体 (src/pager.c:619)

**配置部分（相对固定）：**
```c
sqlite3_vfs *pVfs;          // VFS 接口
u8 journalMode;             // 日志模式 (DELETE/PERSIST/OFF/TRUNCATE/WAL/MEMORY)
u8 useJournal;              // 是否使用回滚日志
u8 noSync;                  // 不进行同步
u8 fullSync;                // 完整同步标志
u8 syncFlags;               // SYNC_NORMAL or SYNC_FULL
u32 pageSize;               // 页大小
```

**运行部分（频繁变化）：**
```c
u8 eState;                  // 当前状态
u8 eLock;                   // 当前持有的锁
Pgno dbSize;                // 数据库中的页数
Pgno dbOrigSize;            // 事务开始时的页数
Pgno dbFileSize;            // 文件中的页数
Bitvec *pInJournal;         // 哪些页已写入日志
sqlite3_file *fd;           // 数据库文件描述符
sqlite3_file *jfd;          // 日志文件描述符
sqlite3_file *sjfd;         // 子日志文件描述符
i64 journalOff;             // 日志文件当前写入位置
PCache *pPCache;            // 页缓存
Wal *pWal;                  // WAL 对象（WAL 模式）
```

## 完整事务流程

### 1. 初始化与打开 (sqlite3PagerOpen)

```c
sqlite3PagerOpen(vfs, &pPager, filename, flags, permissions, page_size, destructor)
├─> 创建 Pager 结构体
├─> 打开数据库文件
├─> 初始化页缓存 (PCache)
├─> 设置默认页大小
├─> 状态设置为 PAGER_OPEN
└─> 返回 Pager 指针
```

**关键变量初始化：**
- `eState = PAGER_OPEN`
- `eLock = NO_LOCK` 或 `SHARED_LOCK`
- `journalMode` 取决于编译选项和 PRAGMA 设置

### 2. 开始读事务 (sqlite3PagerSharedLock)

```c
sqlite3PagerSharedLock(pPager)
├─> 检查当前状态
├─> 获取数据库文件上的 SHARED 锁
├─> 读取数据库头部（前100字节）
│   └─> 从中获知页大小、文件大小等
├─> 检查是否存在需要恢复的热日志
│   └─> 如果存在则执行自动回滚
├─> 更新 dbSize, dbFileSize
├─> 状态转换为 PAGER_READER
└─> 返回 SQLITE_OK
```

**锁机制：**
- SHARED 锁：允许多个读取器并存
- 持有 SHARED 锁期间不能写入

### 3. 开始写事务 (sqlite3PagerBegin)

**关键决策：是否使用 WAL 模式？**

#### 3A. 使用 WAL 模式
```c
sqlite3PagerBegin(pPager, exclusive_flag, in_memory_subjnl)
├─> 检查 pagerUseWal(pPager) == true
├─> 获取 WAL 写锁
│   └─> sqlite3WalBeginWriteTransaction(pWal)
├─> 状态转换为 PAGER_WRITER_LOCKED
├─> 记录 dbOrigSize（用于回滚）
└─> 返回 SQLITE_OK
```

#### 3B. 使用传统回滚日志模式
```c
sqlite3PagerBegin(pPager, exclusive_flag, in_memory_subjnl)
├─> 在 PAGER_READER 状态下
├─> 获取数据库上的 RESERVED 锁
│   └─> pagerLockDb(pPager, RESERVED_LOCK)
├─> 如果 exFlag=true，继续升级到 EXCLUSIVE 锁
├─> 状态转换为 PAGER_WRITER_LOCKED
├─> 初始化日志相关变量
│   ├─> journalOff = 0
│   ├─> nRec = 0
│   └─> pInJournal = 0
└─> 返回 SQLITE_OK
```

**锁升级过程：**
```
SHARED → RESERVED → EXCLUSIVE
```

### 4. 页面修改与缓存 (sqlite3PagerWrite)

```c
sqlite3PagerWrite(pPage)
├─> 检查页是否已在脏页列表中
│   └─> 如果已在，直接返回
├─> 检查 pager 是否在 WRITER_LOCKED 状态
│   └─> 需要打开日志文件并转换状态
├─> 如果是首次修改页
│   ├─> 打开日志文件 (pagerOpenJournal)
│   │   ├─> 创建日志文件
│   │   ├─> 写入日志头部
│   │   ├─> 记录初始的 dbSize
│   │   └─> 状态转换为 PAGER_WRITER_CACHEMOD
│   │
│   ├─> 将页的原始内容写入日志
│   │   ├─> 记录页号和数据
│   │   └─> 更新 pInJournal 位向量
│   │
│   └─> 状态转换为 PAGER_WRITER_DBMOD（如果有更多脏页）
│
├─> 将页标记为脏页
│   └─> 加入脏页链表
│
└─> 返回 SQLITE_OK
```

**关键点：**
- 日志采用 **Write-Ahead Logging** 原则：先写日志，后写数据库
- 每个脏页的原始内容被记录，用于回滚
- 一旦页被修改，就进入 WRITER_CACHEMOD 或 WRITER_DBMOD 状态

### 5. 事务提交 - 第一阶段 (sqlite3PagerCommitPhaseOne)

这个阶段的目标是**确保所有修改都已安全落盘到磁盘**。

#### 5A. WAL 模式提交
```c
sqlite3PagerCommitPhaseOne(pPager, zSuper, noSync)
├─> 检查是否有脏页
├─> 获取脏页列表
├─> 调用 pagerWalFrames(pPager, dirtyList, dbSize, isCommit=1)
│   ├─> 写入 WAL 文件头（如需要）
│   ├─> 循环遍历脏页列表
│   │   └─> walWriteOneFrame(page_number, page_data, commit_flag)
│   ├─> 计算同步点（通常在扇区边界）
│   ├─> 跨越同步点时触发 fsync
│   ├─> 最后调用 sqlite3OsSync() 确保 WAL 已落盘
│   └─> 清空页缓存
│
└─> 返回 SQLITE_OK
```

#### 5B. 传统日志模式提交
```c
sqlite3PagerCommitPhaseOne(pPager, zSuper, noSync)
├─> 检查是否有脏页
│   └─> 如果无脏页，则直接返回
│
├─> 是否启用 Batch-Atomic-Write？
│   ├─> YES: 使用原子写优化（单页事务）
│   └─> NO:  使用传统提交流程
│
├─> 获取脏页列表
│
├─> 同步日志文件 (syncJournal)
│   ├─> 如果 synchronous≠OFF，则 fsync 日志文件
│   └─> 确保日志中的页已安全落盘
│
├─> 遍历脏页列表，逐页写入数据库
│   ├─> 升级到 EXCLUSIVE 锁（如果还没有）
│   ├─> 将每个脏页写入数据库文件
│   └─> 根据同步模式决定是否 fsync
│
├─> 更新数据库文件头中的 change-counter
│   ├─> 这会触发其他连接的缓存失效
│   └─> fsync 数据库文件（根据 synchronous 设置）
│
├─> 状态转换为 PAGER_WRITER_FINISHED
│
└─> 返回 SQLITE_OK
```

**关键同步决策（基于 PRAGMA synchronous）：**

| synchronous | 日志 fsync | 数据库 fsync | 性能 | 安全性 |
|-------------|----------|------------|------|--------|
| OFF | ✗ | ✗ | 最快 | 最低 |
| NORMAL | ✓ | ✗ | 中等 | 中等 |
| FULL | ✓ | ✓ | 较慢 | 高 |
| EXTRA | ✓ | ✓ | 最慢 | 最高 |

### 6. 事务提交 - 第二阶段 (sqlite3PagerCommitPhaseTwo)

这个阶段的目标是**清理日志文件并最终释放锁**。

#### 6A. WAL 模式
```c
sqlite3PagerCommitPhaseTwo(pPager)
├─> 增加 iDataVersion（表示数据变更）
├─> 调用 pager_end_transaction()
│   ├─> 释放写锁
│   ├─> 状态转换为 PAGER_READER
│   └─> 返回
└─> 返回 SQLITE_OK
```

#### 6B. 传统日志模式
```c
sqlite3PagerCommitPhaseTwo(pPager)
├─> 增加 iDataVersion
├─> 调用 pager_end_transaction()
│   ├─> 是否存在超级日志？
│   │   ├─> YES: 删除超级日志
│   │   └─> NO:  删除/截断/清零主日志
│   ├─> 根据 journalMode 清理日志
│   │   ├─> DELETE: 删除日志文件
│   │   ├─> PERSIST: 清零日志头部
│   │   ├─> TRUNCATE: 截断日志文件
│   │   └─> MEMORY: 内存日志自动清空
│   ├─> 释放锁
│   ├─> 状态转换为 PAGER_READER
│   └─> 返回
└─> 返回 SQLITE_OK
```

**优化：** 如果满足条件，第二阶段可能是完全的无操作：
```c
if( pPager->eState == PAGER_WRITER_LOCKED 
 && pPager->exclusiveMode 
 && pPager->journalMode == PAGER_JOURNALMODE_PERSIST
){
    // 日志头已经是空的（nRec=0），无需清理
    pPager->eState = PAGER_READER;
    return SQLITE_OK;
}
```

### 7. 事务回滚 (sqlite3PagerRollback)

#### 7A. WAL 模式回滚
```c
sqlite3PagerRollback(pPager)
├─> 检查状态
│   ├─> 如果 READER 或 OPEN 状态 → 返回（无操作）
│   └─> 如果 ERROR 状态 → 返回错误码
│
├─> 调用 sqlite3WalUndo()
│   ├─> 撤销所有 WAL 中未提交的帧
│   └─> 从磁盘重新读取原始页
│
├─> 从缓存中清除修改的页
│
├─> 调用 sqlite3WalEndReadTransaction()
│   └─> 关闭 WAL 读事务
│
├─> 状态转换为 PAGER_READER
│
└─> 返回 SQLITE_OK
```

#### 7B. 传统日志模式回滚
```c
sqlite3PagerRollback(pPager)
├─> 检查状态（同上）
├─> 检查是否存在日志文件
├─> 打开并读取日志头
├─> 遍历日志记录，逐个恢复页
│   ├─> 读取日志中的原始页数据
│   ├─> 写回数据库文件
│   └─> 标记该页已恢复
│
├─> 恢复数据库文件大小
│   └─> 如果数据库被扩展，截断回原始大小
│
├─> 清空日志文件（或删除）
│
├─> 状态转换回 PAGER_READER
│
└─> 返回 SQLITE_OK
```

## 页面读取流程 (sqlite3PagerGet)

```c
sqlite3PagerGet(pPager, pgno, &pPage, flags)
├─> 确保 pager 处于 READER 或更高状态
│   └─> 需要时调用 sqlite3PagerSharedLock()
│
├─> 检查页是否在缓存中
│   ├─> YES: 直接返回缓存页
│   └─> NO:  继续
│
├─> 创建新的 PgHdr 对象
│
├─> 根据 flags 决定是否从磁盘读取
│   ├─> PAGER_GET_NOCONTENT: 创建空页（用于即将覆写的页）
│   └─> 正常情况: 从磁盘读取
│
├─> 如果在 WAL 模式
│   ├─> 尝试从 WAL 文件读取
│   └─> 如果 WAL 中无此页，则从主数据库读取
│
├─> 将页加入缓存
│
└─> 返回 pPage
```

## 关键算法

### 1. Overwriteable Page 检查

一个页可以被覆写，当且仅当满足以下任一条件：
- 页的原始内容已写入日志并同步到磁盘
- 页是空闲列表叶页（freelist leaf page）
- 页号大于事务开始时的最大页号（新增页）

### 2. Change-Counter 更新

为了让其他连接检测到数据库变化，SQLite 在数据库头部的字节24-39中维护一个变化计数器：
- 每次提交时递增
- 其他连接通过定期检查这个值来检测缓存失效

### 3. Sector Boundary Alignment

为避免部分写入导致的不一致，SQLite 尝试在扇区边界处进行 fsync：
```
- 计算下一个扇区边界 = (offset + sector_size - 1) / sector_size * sector_size
- 在该边界前 fsync
- 在边界后继续写入
```

## WAL vs 传统日志对比

| 方面 | WAL 模式 | 传统日志 |
|------|---------|--------|
| **日志位置** | 独立 WAL 文件 | 同一日志文件 |
| **写入顺序** | 先写 WAL，后回写主文件 | 先写日志，后修改主文件 |
| **Checkpoint** | 明确的 checkpoint 操作 | 事务提交时自动发生 |
| **读者影响** | 读者可以继续读，不影响提交 | 提交时可能影响读者 |
| **文件大小** | 可能更多文件（WAL + 主文件） | 只有主文件 + 日志 |
| **性能** | 通常更快（少 fsync） | 取决于同步模式 |
| **恢复** | WAL checkpoint 期间恢复 | 自动回滚日志 |

## 性能优化

### 1. 页面缓存大小
- 通过 PRAGMA cache_size 配置
- 缓存命中率越高性能越好

### 2. Synchronous 模式调优
- OFF: 最快，但数据不安全
- NORMAL: 平衡（默认）
- FULL: 最安全，但最慢

### 3. Journal Size Limit
- 通过 PRAGMA journal_size_limit 配置
- 防止日志文件无限增长

### 4. Batch-Atomic-Write
- 对于单页事务的优化
- 使用原子写指令，无需日志

## 常见错误处理

### 1. Hot Journal Recovery
在打开数据库时，如果发现存在"热日志"（未完成的日志），会自动执行回滚。

### 2. SQLITE_BUSY
当获取锁失败时，可以设置 busy_handler 进行重试。

### 3. SQLITE_IOERR
I/O 错误通常会导致 pager 进入 ERROR 状态，需要通过 rollback 恢复。

## 总结

Pager 的核心是通过**日志机制确保事务的原子性**：
1. **修改前**：页的原始内容写入日志
2. **修改时**：页在缓存中被修改
3. **提交时**：日志 fsync 后，修改写入数据库
4. **回滚时**：从日志恢复原始状态

WAL 模式优化了这个流程，通过延迟 checkpoint 和允许读写并发来提高性能。
