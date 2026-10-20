# SQLite 源码：一次基本查询的处理流程

SQLite 是一个经典的嵌入式关系型数据库，它的查询处理流程设计得非常优雅，堪称编译器和虚拟机设计的教科书。

从源码（位于 `src/` 目录下）的角度来看，一次基本查询（如 `SELECT * FROM table WHERE id = 1;`）的处理流程可以分为 **三大阶段**：**编译阶段 (Prepare)**、**执行阶段 (Step)** 和 **清理阶段 (Finalize)**。

## 第一阶段：编译阶段 (Query Compilation)

这个阶段将人类可读的 SQL 字符串转换为 SQLite 内部的虚拟机字节码（VDBE Bytecode）。

**入口函数：** `sqlite3_prepare_v2()` （定义在 `src/prepare.c`）

1. **词法分析 (Tokenizer)**
   * **相关文件：** `src/tokenize.c`
   * **过程：** `sqlite3_prepare_v2()` 接收到 SQL 字符串后，会调用分词器（Tokenizer）。词法分析器从左到右扫描 SQL 文本，将其拆分成一个个的 Token（例如 `SELECT`、`*`、`FROM` 等关键字和标识符）。
2. **语法分析 (Parser)**
   * **相关文件：** `src/parse.y`
   * **过程：** SQLite 使用了自定义的 Lemon 解析器生成器（Lemon LALR(1) Parser Generator）。`parse.y` 中定义了 SQLite 的语法规则。Token 流会输入到语法分析器中，根据规则构建出一棵**抽象语法树 (AST - Abstract Syntax Tree)**。
3. **语义分析与代码生成 (Code Generation)**
   * **相关文件：** `src/select.c`、`src/expr.c`、`src/build.c` 等
   * **过程：** 生成 AST 后，SQLite 需要验证表名、列名是否存在（查 Schema），检查类型匹配等。之后，对于不同类型的语句，会调用不同的 C 文件进行处理（例如 `SELECT` 语句进入 `src/select.c`）。
4. **查询优化 (Query Optimizer / Planner)**
   * **相关文件：** `src/where.c`、`src/wherecode.c`、`src/whereexpr.c`
   * **过程：** 如果语句中包含 `WHERE`、`JOIN`、`ORDER BY` 等，查询优化器会被唤醒。它会分析可能的执行路径，计算哪种表连接顺序最好，是否能够走索引（B-Tree Index），从而规划出最优的数据访问路径。
5. **生成字节码 (VDBE Bytecode)**
   * **相关文件：** `src/vdbe.c`
   * **过程：** 优化后的 AST 会被翻译成**虚拟数据库引擎（VDBE - Virtual Database Engine）**能看懂的指令集。编译阶段的产出就是一个准备好的 `sqlite3_stmt` 对象（你可以把它看作是一个包含了多条机器指令的已编译程序）。

## 第二阶段：执行阶段 (Query Execution)

这个阶段执行第一阶段生成的 VDBE 字节码，并与底层的存储引擎交互来获取数据。执行阶段是 SQLite 数据库的核心，负责真正去磁盘（或内存）中搬运和计算数据。

**入口函数：** `sqlite3_step()` （定义在 `src/vdbeapi.c`）

### 1. 虚拟机的状态机机制（Yield & Resume）
`sqlite3_step()` 不是一次性把所有数据都取出来返回给你，它是一个**基于状态机的协程机制**。
* 当你调用 `sqlite3_step(stmt)` 时，VDBE 开始执行预编译好的字节码。
* 一旦执行到 `OP_ResultRow`（即成功凑齐了一行需要返回的数据），VDBE 会保存当前的执行状态（程序计数器 PC、各个寄存器的值、游标位置），然后**挂起（Yield）**，并向调用者返回 `SQLITE_ROW`。
* 当调用者处理完这一行数据，再次调用 `sqlite3_step(stmt)` 时，VDBE 会从上次挂起的地方**恢复（Resume）**，继续去寻找下一行数据。
* 如果找遍了也没有更多数据，就会返回 `SQLITE_DONE`。

### 2. VDBE 核心调度器：`sqlite3VdbeExec()`
**相关文件：`src/vdbe.c`**

当你调用 `sqlite3_step()` 时，经过一些外层封装（在 `vdbeapi.c` 中），最终会进入到 SQLite 最庞大也最重要的函数：`sqlite3VdbeExec(Vdbe *p)`。
* **架构：** 这个函数本质上是一个在一个巨大的 `for(;;)` 循环里包裹着的巨型 `switch(pOp->opcode)` 语句（有上百个 case）。
* **组件：** 
  * **指令数组（Program）：** 编译阶段生成的操作码（Opcode）数组，如 `OP_OpenRead`, `OP_Column`。
  * **程序计数器（PC - Program Counter）：** 记录当前执行到哪一条指令。
  * **寄存器数组（Registers / Memory Cells）：** VDBE 不是基于栈的虚拟机，而是基于寄存器的。它有一个数组 `p->aMem` 用来临时存放数据。比如从数据库读出的某个整数、浮点数或字符串，会暂存到某个 Mem 寄存器中，后续指令再从该寄存器取值进行比较或返回。

### 3. 一次全表扫描（SELECT *）的指令执行流
假设我们执行 `SELECT id, name FROM users;`，在 `sqlite3VdbeExec` 中大致会经历以下核心指令流：

1. **`OP_Init`**: 初始化虚拟机状态，跳转到主程序。
2. **`OP_OpenRead`**: 在 VDBE 中打开一个游标（Cursor），这个游标指向 `users` 表在 B-Tree 中的根节点。
3. **`OP_Rewind`**: 将游标移动到表的第一条记录。如果表是空的，它会直接跳转到结束指令。
4. **`OP_Column`** *(循环体开始)*: 通过游标，去 B-Tree 的当前叶子节点中，把记录中的第 0 列（id）提取出来，放入寄存器 Mem(1)。
5. **`OP_Column`**: 同样提取第 1 列（name），放入寄存器 Mem(2)。
6. **`OP_ResultRow`**: 告诉虚拟机：“寄存器 Mem(1) 和 Mem(2) 里的数据就是我们要返回的一行记录”。**此时虚拟机暂停**，`sqlite3_step` 返回 `SQLITE_ROW` 退出。
7. **`OP_Next`** *(再次调用 sqlite3_step 恢复后)*: 将游标在 B-Tree 中移动到下一条记录。如果移动成功，跳回到上面的 `OP_Column` 指令继续执行；如果没有下一条记录（遍历完了），则继续往下执行。
8. **`OP_Close`**: 关闭游标。
9. **`OP_Halt`**: 结束执行，`sqlite3_step` 返回 `SQLITE_DONE`。

### 4. VDBE 与 B-Tree 的交互
**相关文件：`src/btree.c`**

VDBE 只知道“提取第 N 列数据”或“跳到下一行”，它并不知道数据在磁盘上是怎么存的，这些由 B-Tree 层处理。
* **游标（Cursor）：** VDBE 中打开的“表”，在 B-Tree 层就是一个 `BtCursor` 结构体。它维护了当前遍历到了树的哪一层、哪一个页面（Page）、页面里的哪一个单元（Cell）。
* **数据解析（Record Format）：** SQLite 的每一行数据存放在一个 Cell 里。提取列时，B-Tree 会解析这个 Cell 的 Header（记录了每个列占用的字节数和数据类型），然后精准地切出你需要的那一列的字节流。

### 5. B-Tree 与 Pager 缓存的交互
**相关文件：`src/pager.c`**

当 B-Tree 要读取一个节点（Page）以移动游标时，它会向 Pager 层发送请求：`sqlite3PagerGet(pager, pgno, ...)`。
* **Page Cache（页面缓存）：** Pager 会先在内存的 Hash 表中查找，如果这个页面（通常是 4KB）已经在内存里，就直接返回指针，速度极快（内存命中）。
* **磁盘读取：** 如果内存中没有，Pager 就会调用底层系统接口，去磁盘中把这个 4KB 的块读到内存池里。
* **LRU 淘汰：** 如果查询涉及的数据量极大，导致缓存池满了，Pager 还要负责根据 LRU 算法把最久未使用的非脏页从内存中淘汰掉。

### 6. Pager 与 操作系统接口 (OS / VFS) 的交互
**相关文件：`src/os.c`, `src/os_unix.c`, `src/os_win.c`**

如果发生了真正的磁盘 I/O 操作（比如 Pager 发现缓存未命中），它会通过 SQLite 的 VFS（虚拟文件系统）抽象层来调用系统 API。
* 在 Linux 下，调用 `pread64()` 等函数。
* 在 Windows 下，调用 `ReadFile()` 等 API。
这样设计使得 SQLite 的核心执行逻辑（VDBE、B-Tree）完全不依赖于特定的操作系统。

**总结来说：**
执行阶段就是一个由 VDBE 发号施令的过程。VDBE 操作寄存器处理运算逻辑，通过调用 B-Tree API 实现游标在数据结构上的遍历，B-Tree 又通过 Pager 管理内存页缓冲，Pager 最终通过 OS VFS 实现磁盘 I/O。整个过程由于 `OP_ResultRow` 指令的存在，变成了一个可挂起、可恢复的流式数据泵。

## 第三阶段：清理阶段 (Finalization)

查询完毕，释放资源。

**入口函数：** `sqlite3_finalize()` （定义在 `src/vdbeapi.c`）

* **过程：** 当外部程序遍历完所有结果（或者发生异常中途退出）时，调用 `sqlite3_finalize()` 销毁 `sqlite3_stmt` 对象。它会停止 VDBE 的运行，关闭已经打开的游标，清理相关的内存分配，并释放内部持有的读写锁。

## 总结流程图

```text
[ SQL 字符串 ] 
      │
      v 
[ sqlite3_prepare_v2() ] -> src/prepare.c
      ├─ Tokenizer (词法分析) -> src/tokenize.c
      ├─ Parser (语法分析, AST) -> src/parse.y
      ├─ Query Planner (查询优化) -> src/where.c / src/select.c
      └─ VDBE Code Generator -> 生成字节码
      │
      v
[ 预编译对象 sqlite3_stmt ]
      │
      v
[ sqlite3_step() ] -> src/vdbeapi.c
      ├─ VDBE (执行指令: sqlite3VdbeExec) -> src/vdbe.c
      │      ↓
      ├─ B-Tree (操作树结构和游标) -> src/btree.c
      │      ↓
      ├─ Pager (事务、缓存、WAL) -> src/pager.c
      │      ↓
      └─ VFS (OS底层文件读写) -> src/os.c / src/os_win.c
      │
      v
[ 数据行 (SQLITE_ROW) 或 结束 (SQLITE_DONE) ]
      │
      v
[ sqlite3_finalize() ] -> 销毁 stmt，释放内存与锁
```
