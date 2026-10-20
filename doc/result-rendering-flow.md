# SQLite 源码：查询结果的渲染与排版流程 (Result Rendering Flow)

在 SQLite 中，“查询结果的渲染与排版”主要由两个层次协作完成：
1. **上层展示层（CLI Shell 渲染）**：位于 `src/shell.c.in`，负责将查询结果在终端或输出流中进行排版、对齐、加框、折行，以及转换为各种格式（如 table、box、column、markdown、csv、json、html、insert 等）。
2. **下层数据层（VDBE 内核结果产出）**：位于 `src/vdbe.c` 与 `src/vdbeapi.c`，负责虚拟机执行到行结果时挂起，并通过 C 语言 API 提供类型提取与即时格式化。

---

## 整体架构与执行流程图

```mermaid
flowchart TD
    A["用户输入 SQL"] --> B["process_input()"]
    B --> C["runOneSqlLine()"]
    C --> D["shell_exec()"]
    D --> E["sqlite3_prepare_v2() 编译获得 pStmt"]
    E --> F["exec_prepared_stmt()"]

    F -->|列式/表格模式\n(MODE_Column, Table, Box, Markdown)| G["exec_prepared_stmt_columnar()"]
    F -->|流式行模式\n(MODE_List, Line, Csv, Json, Html, Insert...)| H["循环 sqlite3_step() + 调用 shell_callback()"]

    subgraph VDBE["底层 VDBE 引擎 (src/vdbe.c)"]
        I["执行字节码到 OP_ResultRow"]
        I --> J["挂起虚拟机，返回 SQLITE_ROW"]
        J --> K["sqlite3_column_*() 提取数据并按需转换"]
    end

    G -.->|驱动步进| I
    G -.->|批量收集行| K
    H -.->|驱动步进| I
    H -.->|提取单行| K

    G --> L["终端排版输出 (pArg->out)"]
    H --> L
```

---

## 第一阶段：执行与渲染路由分发

**核心源码文件**：`src/shell.c.in`

当用户在交互式终端或通过脚本输入 SQL 语句后，进入以下调度流程：

1. **输入解析**：`process_input(ShellState *p)` 逐行收集输入，当检测到完整语句（`sqlite3_complete()`）后，调用 `runOneSqlLine()`。
2. **SQL 执行**：`runOneSqlLine()` 调用 `shell_exec(ShellState *pArg, const char *zSql, ...)`。
3. **预编译**：`shell_exec()` 调用 `sqlite3_prepare_v2(db, zSql, -1, &pStmt, &zLeftover)` 将 SQL 编译为字节码句柄 `pStmt`。
4. **渲染路由**：调用 `exec_prepared_stmt(pArg, pStmt)`。该函数根据当前的输出模式 `pArg->cMode`（对应 `.mode` 命令设置），路由到两条完全不同的渲染路径：
   - **双阶段列式渲染器**：`exec_prepared_stmt_columnar()`（适用于需要提前探测整列最大宽度、画网格线框的模式）。
   - **单行流式回调渲染器**：`shell_callback()`（适用于不需要全局缓冲、产生一行即打印一行的流式模式）。

---

## 第二阶段：列式与表格网格渲染（Columnar Rendering）

**对应函数**：`exec_prepared_stmt_columnar()`  
**适用模式**：
- `MODE_Column`：经典列对齐模式
- `MODE_Table`：类似 MySQL 的 ASCII 表格（`+---+---+`）
- `MODE_Box`：现代化 Unicode 细线/双线边框（`┌─┬─┐`、`├─┼─┤`、`└─┴─┘`）
- `MODE_Markdown`：GitHub 风格 Markdown 表格（`|---|---|`）

为了在终端中画出严丝合缝的表格和对齐列，程序必须**预先知道每一列在全部数据行中的最大字符占位宽度**。因此该函数采用了经典的 **Two-Pass（双阶段）渲染机制**。

### 阶段 1：数据全量收集与列宽动态探测

1. **获取元数据**：
   - 调用 `sqlite3_column_count(pStmt)` 获取结果集总列数 `nColumn`。
   - 初始化动态数据指针数组 `azData`（容量为 `nAlloc = nColumn * 4`，后续自动加倍扩容）。
   - 分配行分割标记数组 `abRowDiv`。
2. **收集表头并预处理**：
   - 通过 `sqlite3_column_name(pStmt, i)` 获取所有列名。
   - 调用 `translateForDisplayAndDup()` 处理表头字符串。
3. **循环拉取与文本转换**：
   ```c
   do {
       // 动态扩容 azData 和 abRowDiv
       nRow++;
       for(i=0; i<nColumn; i++){
           uz = (const unsigned char*)sqlite3_column_text(pStmt, i);
           // 对单元格内容进行转义、折行和展示转换
           azData[nRow*nColumn + i] = translateForDisplayAndDup(p, uz, &azNextLine[i], wx, bw);
           if( azNextLine[i] ){
               bNextLine = 1; // 单元格超宽或包含换行，需要在下一行继续输出
               abRowDiv[nRow-1] = 0;
               bMultiLineRowExists = 1;
           }
       }
   } while( bNextLine || sqlite3_step(pStmt)==SQLITE_ROW );
   ```
4. **显示宽度计算（重点）**：
   - 内存收集完毕后，遍历 `azData` 中的所有单元格。
   - 调用 `strlenChar(z)` 计算每个单元格在终端的字符宽度（通过 `decodeUtf8` 和 `cli_wcwidth()` 正确计算东亚宽字符、Emoji 等多字节 UTF-8 字符的终端实际列宽，而非简单字节数）。
   - 取每列全部行内容的最大宽度，记录至 `p->actualWidth[j]`。

#### 核心辅助函数：`translateForDisplayAndDup()`
负责将原始文本转换为适合终端可视化的安全字符串：
- 将制表符 `\t` 展开为对齐的定长空格。
- 过滤非打印控制字符，或根据配置保留 VT100 终端转义序列。
- 当开启自动换行（`bWordWrap`）时，在单词边界处折行，并将未展示完的剩余内容指针存入 `pzTail` 供下一次循环继续渲染。

---

### 阶段 2：网格排版与结构化输出

根据当前激活的具体模式，进行终端绘图与输出：

#### 1. 顶线与表头渲染
- **`MODE_Table`**：调用 `print_row_separator(p, nColumn, "+")` 打印形如 `+------+------+` 的分隔线；表头文字居中输出；再次打印 `+------+------+`。
- **`MODE_Box`**：调用 `print_box_row_separator(p, nColumn, BOX_23, BOX_234, BOX_34)` 打印顶部边框（`┌──────┬──────┐`）；居中打印表头；调用 `print_box_row_separator(..., BOX_123, BOX_1234, BOX_134)` 打印表头底部分隔线（`├──────┼──────┤`）。
- **`MODE_Markdown`**：打印 `| col1 | col2 |`，接着输出对齐虚线 `|------|------|`。
- **`MODE_Column`**：打印表头名称，并在其下方打印下划线短横线（`print_dashes()`）。

#### 2. 数据行与单元格内容渲染
- 循环输出每个单元格数据：
  ```c
  for(i=nColumn, j=0; i<nTotal; i++, j++){
      if( j==0 && p->cMode!=MODE_Column ){
          sqlite3_fputs(p->cMode==MODE_Box ? BOX_13" " : "| ", p->out);
      }
      z = azData[i];
      w = p->actualWidth[j];
      // 按照计算好的列宽输出定长字符，不足部分用空格补齐
      utf8_width_print(p->out, w, z);
      ...
  }
  ```
- **多行单元格处理**：如果单元格内有折行（`bMultiLineRowExists`），在行与行之间根据 `abRowDiv` 打印行内部分隔符或保持边框连续。

#### 3. 底部分隔线与内存释放
- 数据打印完毕后，输出底边框（如 Box 模式的 `└──────┴──────┘`）。
- 释放 `azData`、`azNextLine`、`abRowDiv` 等全部暂存内存。

---

## 第三阶段：行级流式回调渲染（Streaming Callback Rendering）

**对应函数**：`shell_callback()`  
**适用模式**：
- `MODE_List`（默认管道符分割列表）
- `MODE_Line`（键值对垂直列表）
- `MODE_Csv`（CSV 格式）
- `MODE_Json`（JSON 数组）
- `MODE_Html` / `MODE_Www`（HTML 表格标签）
- `MODE_Insert`（反向生成 SQL INSERT 语句）
- `MODE_Explain`（字节码反汇编展示）

当数据量极其庞大，或者输出不需要预先计算整列对齐宽度时，采用流式渲染模式。

### 调度机制

在 `exec_prepared_stmt()` 中，每通过 `sqlite3_step(pStmt)` 获得一行结果（`SQLITE_ROW`），就会立即收集当前行的列值与列名指针数组，并直接触发一次 `shell_callback()`：

```c
do {
    nRow++;
    for(i=0; i<nCol; i++){
        aiTypes[i] = sqlite3_column_type(pStmt, i);
        azVals[i]  = (char*)sqlite3_column_text(pStmt, i);
    }
    // 即时回调渲染当前单行数据
    if( shell_callback(pArg, nCol, azVals, azCols, aiTypes) ){
        rc = SQLITE_ABORT;
    } else {
        rc = sqlite3_step(pStmt);
    }
} while( SQLITE_ROW == rc );
```

### 各模式的渲染特化实现

| 模式 | 实现逻辑与特征 |
| :--- | :--- |
| **`MODE_List`** | 首行按需打印列名；后续每行字段间输出 `colSeparator`（默认 `\|`），行尾输出 `rowSeparator`（默认 `\n`）。 |
| **`MODE_Line`** | 计算当前记录中最长的列名长度 `w`，逐行输出键值对：`sqlite3_fprintf(p->out, "%*s = %s\n", w, azCol[i], val)`。记录之间以空行分隔。 |
| **`MODE_Csv`** | 调用 `output_csv()`。如果字段中包含逗号 `,`、双引号 `"` 或换行符，自动在外层包裹双引号，并将内部双引号转义为 `""`（符合 RFC 4180）。 |
| **`MODE_Json`** | 首行输出 `[\n`；每条记录输出为 JSON 对象格式 `{"col1": val1, ...}`，正确转义字符串中的特殊控制字符；流式结束时闭合 `]\n`。 |
| **`MODE_Html`** | 首行打印 `<TABLE border='1'><TR><TH>col</TH>...</TR>`；数据行打印 `<TR><TD>val</TD>...</TR>`，调用 `output_html_string()` 转义 `&`、`<`、`>`。 |
| **`MODE_Insert`** | 反向重构为 SQL 插入语句：`INSERT INTO <table> (col1, col2) VALUES ('val1', 123);`。根据列类型自动区分 `NULL`、数字字面量、浮点特殊值（`Inf`/`NaN`）及加引号字符串。 |

---

## 第四阶段：内核引擎层的结果产出机制

**核心源码文件**：`src/vdbe.c`、`src/vdbemem.c`

无论外层 Shell 是列式缓冲还是单行流式渲染，所有数据均由底层的 VDBE（Virtual Database Engine）虚拟机驱动产生。

### 1. `OP_ResultRow` 指令
当 SQL 查询执行到需要对外返回一行数据的时刻，编译阶段生成的 VDBE 字节码会运行到 `OP_ResultRow`：

```c
case OP_ResultRow: {
    // pOp->p1 为结果列寄存器的起始索引，pOp->p2 为返回列数
    p->pResultRow = &aMem[pOp->p1];
    p->pc = (int)(pOp - aOp) + 1;  // 保存下一条指令计数器
    rc = SQLITE_ROW;               // 设置状态码
    goto vdbe_return;              // 挂起虚拟机并返回
}
```
`sqlite3_step()` 捕获到 `SQLITE_ROW` 后立即返回到外层调用者，保持当前游标与寄存器上下文不变。

### 2. 列数据提取与类型渲染
外层通过 `sqlite3_column_*` 获取对应列的值：
- `sqlite3_column_text()`：若寄存器内部为整数（`MEM_Int`）或浮点数（`MEM_Real`），底层会调用 `vdbeMemRenderNum()`，将其即时格式化渲染为十进制 ASCII 字符串并缓存在 `Mem` 对象中返回。
- `sqlite3_column_blob()` / `sqlite3_column_type()`：直接获取二进制数据及列的亲和类型（`SQLITE_INTEGER`、`SQLITE_FLOAT`、`SQLITE_TEXT`、`SQLITE_BLOB`、`SQLITE_NULL`）。

---

## 第五阶段：特殊渲染 —— 执行计划树（EXPLAIN QUERY PLAN）

如果在 SQLite Shell 中通过 `.eqp on` 开启了解释模式，查询在执行前还会走特殊的图形化渲染：

1. **收集树状节点**：
   Shell 临时改写查询为 `EXPLAIN QUERY PLAN <sql>` 并执行，每行返回包含 `(id, parentId, notUsed, detail)`。
   调用 `eqp_append(pArg, iEqpId, iParentId, zEQPLine)` 在内存中建立父子关系树。
2. **递归渲染树结构**：
   调用 `eqp_render()` -> `eqp_render_level()` 进行递归深度优先遍历，根据层级和是否为最后一个子节点，拼接输出终端连线符号：
   ```text
   QUERY PLAN
   `--SEARCH table users USING INDEX idx_user_id (id=?)
      |--SEARCH table orders USING INDEX idx_order_uid (uid=?)
      `--SCALAR SUBQUERY 1
   ```

---

## 核心函数与源码定位速查

| 核心函数 / 结构体 | 所在文件及位置 | 功能职责 |
| :--- | :--- | :--- |
| `exec_prepared_stmt` | `src/shell.c.in` | 查询执行与输出模式分发总入口 |
| `exec_prepared_stmt_columnar` | `src/shell.c.in` | Table/Box/Column/Markdown 的全量列式对齐渲染器 |
| `translateForDisplayAndDup` | `src/shell.c.in` | 字符转义、Tab 展开、宽度截断与多行自动折行处理 |
| `shell_callback` | `src/shell.c.in` | List/Line/Csv/Json/Html/Insert 等流式行级格式化渲染器 |
| `utf8_width_print` | `src/shell.c.in` | 针对 UTF-8 多字节字符在指定列宽下进行空格对齐打印 |
| `print_box_row_separator` | `src/shell.c.in` | Unicode 边框绘制（连接符与线段排版） |
| `eqp_render` / `eqp_render_level` | `src/shell.c.in` | 执行计划树状图（ASCII 连接线）递归渲染 |
| `OP_ResultRow` | `src/vdbe.c` | VDBE 字节码结果行产生与虚拟机中断挂起指令 |
| `vdbeMemRenderNum` | `src/vdbemem.c` | 内核将数值型寄存器数据即时渲染为 ASCII 文本 |
