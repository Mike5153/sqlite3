# SQLite 源码：事务处理逻辑解析

SQLite 的事务处理是其保证 ACID 特性（原子性、一致性、隔离性、持久性）的基石。在源码层面，事务的控制逻辑贯穿了 **VDBE（虚拟机层）**、**B-Tree（数据结构层）** 和 **Pager（页面缓存与并发控制层）**。

以下是基于 SQLite 源码结构的事务处理逻辑详细梳理：

## 1. 事务的发起与管理 (VDBE 层的触发)

在 SQLite 中，**任何读写操作都必须在事务中进行**。如果没有显式开启事务，SQLite 会默认进入自动提交（Auto-Commit）模式，即把单条语句包装成一个隐式事务。

*   **隐式事务：**
    *   在执行具体的读写指令前，VDBE 字节码中会包含 `OP_Transaction` 指令。
    *   当 `sqlite3VdbeExec()`（位于 `src/vdbe.c`）执行到 `OP_Transaction` 时，会调用 B-Tree 层的接口 `sqlite3BtreeBeginTrans()`，请求开启一个事务并获取初始的锁（对于读操作是 SHARED 锁，对于写操作准备申请 RESERVED 锁）。
*   **显式事务 (`BEGIN` / `COMMIT` / `ROLLBACK`)：**
    *   当用户执行 `BEGIN` 语句时，解析出的字节码核心是 `OP_AutoCommit`（操作数为 0）。它会将数据库连接对象的 `db->autoCommit` 标志位设为 0，意味着关闭自动提交。
    *   此时并不会立即去锁文件，真正的文件锁依然是推迟到执行具体 `OP_Transaction` 读写数据时才去按需申请（即所谓的“延迟事务 Deferred Transaction”，除非使用了 `BEGIN IMMEDIATE` 或 `EXCLUSIVE`）。

## 2. 写操作与写前日志 (Pager 层的脏页隔离)

**相关文件：`src/pager.c`**

当事务中包含写操作（如 `UPDATE`）时，修改并不会直接落到数据库文件中，而是经过严格的安全机制。以经典的 **Rollback Journal（回滚日志）** 模式为例：

1.  **升级锁级别：** Pager 会请求将文件锁从 SHARED 升级到 RESERVED，表示“我打算写数据了，其他人可以继续读，但别的人不能再申请写锁”。
2.  **备份原数据：** 在 B-Tree 修改某个页面之前，Pager 会把该页面的原始内容（Old Page）原封不动地写入到 `-journal` 日志文件中。
3.  **修改内存缓存：** 备份完成后，B-Tree 才会在内存中的 Page Cache 里修改这个页面。此时这个页面变成了“脏页 (Dirty Page)”。如果查询此时未提交，其他连接读不到脏页里的数据。

## 3. 两阶段提交流程 (Two-Phase Commit)

**相关文件：`src/vdbeaux.c` (VdbeHalt), `src/btree.c`, `src/pager.c`**

无论是执行了显式的 `COMMIT`（触发 `OP_AutoCommit` 重新将 `autoCommit` 设为 1），还是隐式单条语句执行结束。当 VDBE 停止运行并调用收尾函数 `sqlite3VdbeHalt()` 时，如果发现当前是自动提交模式且有未提交的改动，就会触发真正的提交流程。

SQLite 巧妙地使用了“两阶段提交”来保证原子性：

### Phase One（第一阶段：落盘准备）
*   **调用链：** `sqlite3VdbeHalt()` -> `sqlite3BtreeCommitPhaseOne()` -> `sqlite3PagerCommitPhaseOne()`
*   **锁升级：** Pager 尝试将文件锁升级为 **EXCLUSIVE（排他锁）**，此时任何其他连接都不能读也不能写。
*   **日志落盘：** 将 `-journal` 文件的内容强制刷入磁盘（调用 OS 层的 `fsync`），确保如果这时候断电，我们还有完美的旧数据用来恢复。
*   **脏页落盘：** 将内存中的脏页（修改过的新数据）刷入主数据库文件（Main DB）。
*   **主库落盘：** 对主数据库文件调用 `fsync`，确保新数据真的写到物理磁盘上了。

### Phase Two（第二阶段：宣告成功并清理）
*   **调用链：** `sqlite3VdbeHalt()` -> `sqlite3BtreeCommitPhaseTwo()` -> `sqlite3PagerCommitPhaseTwo()`
*   **关键动作（Commit Point）：** **将 `-journal` 文件删除（或清空、截断）**。在 SQLite 的设计中，只要 `-journal` 文件被成功删除，就标志着这个事务**已经永久提交成功**！这一步是原子的。
*   **释放资源：** 释放 EXCLUSIVE 锁，回到 UNLOCKED 状态，清空相关的事务状态，允许其他连接介入。

## 4. 事务的回滚 (Rollback)

如果事务中遇到错误（如外键冲突、UNIQUE 约束冲突），或者用户显式执行了 `ROLLBACK`：

*   **触发点：** `sqlite3VdbeHalt()` 检测到错误，或者解析到 `ROLLBACK` 语句导致执行相关的 Opcodes。
*   **调用链：** `sqlite3BtreeRollback()` -> `sqlite3PagerRollback()`
*   **恢复机制：** Pager 发现 `-journal` 文件存在，且当前事务宣告失败。它会打开 `-journal` 文件，把里面备份的所有老页面读取出来，**覆盖回主数据库文件和内存缓存中**，从而让数据库退回到事务开始前那一分那一秒的状态。
*   **清理：** 恢复完成后，同样删除 `-journal` 文件并释放锁。

## 5. WAL 模式下的事务 (Write-Ahead Logging)

从 SQLite 3.7.0 开始引入了 WAL 模式，虽然 VDBE 和 B-Tree 层的调度逻辑基本相同，但 Pager 层的实现有巨大变化：

*   在 WAL 模式下，**不再有 `-journal` 回滚文件**。
*   写操作时，修改后的脏页不再覆盖主库文件，而是直接**追加到 `-wal` 日志文件的末尾**。
*   **Commit 的原子性标志：** 提交时，仅仅是在 `-wal` 文件中写入一条 Commit Record 记录，并进行一次 `fsync`。这比传统的 Rollback Journal 快得多，因为它避免了两次写盘（不用既写日志又写主库）。
*   读操作时，Pager 会通过一套复杂的机制，从主库文件和 `-wal` 文件中拼凑出最新的视图。
