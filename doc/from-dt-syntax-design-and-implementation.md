# SQLite `FROM DT` 毫秒时间戳语法糖设计与实现文档

## 1. 背景与核心痛点

在很多业务系统和数据库设计中，时间通常以 **13 位毫秒时间戳**（Unix Epoch Milliseconds，`INTEGER` 类型）存储。这种设计带来了两大日常使用痛点：

1. **显示端（SELECT）繁琐**：
   - 原始查询返回的是 13 位纯数字（如 `1789984800000`），人眼极难阅读。
   - 每次查询都要手动编写复杂的格式转换：
     ```sql
     SELECT id, datetime(create_time / 1000, 'unixepoch', 'localtime') AS create_time FROM sys_log;
     ```
2. **搜索端（WHERE）易丢索引（SARGable 失效）**：
   - 如果在 WHERE 中对字段套用函数：
     ```sql
     -- 错误做法：导致 create_time 上的 B-Tree 索引完全失效，引发全表扫描！
     WHERE datetime(create_time / 1000, 'unixepoch', 'localtime') >= '2026-09-21 00:00:00'
     ```
   - 如果手动计算毫秒数字：
     ```sql
     -- 繁琐且极易出错（时区、起止边界精度等）
     WHERE create_time >= 1789984800000
     ```

为了彻底解决以上问题，本项目在 **SQLite 语法与编译器层面** 引入了 **`FROM DT <tablename>`** 语法糖。

---

## 2. 语法规范与设计目标

### 2.1 语法形式
在查询语句的 `FROM` 子句中，在表名前添加 `DT` 关键字修饰符：
```sql
SELECT ... FROM DT <table_name> [AS <alias>] [WHERE ...];
```

### 2.2 核心特性
- **自动识别时间戳字段**：
  若字段名符合时间戳命名惯例（后缀为 `_time`、`_at`、`timestamp`、`_date` 或全名为 `time`、`ts`），系统自动判定为毫秒时间戳列。
- **显示端自动格式化**：
  `SELECT *` 或显式 `SELECT col` 时，时间戳列自动转换为 `YYYY-MM-DD HH:MM:SS` 格式的本地时间字符串输出，且**保持原始列名不变**。
- **搜索端自动折叠走索引**：
  在 `WHERE` 条件中直接编写自然时间字符串（如 `'2026-09-21 00:00:00'`），编译器在生成抽象语法树（AST）时将其**逆向折叠为 64 位毫秒整数常量**，左侧列保持纯净，**100% 命中原表 B-Tree 索引**。
- **向后完全兼容**：
  不加 `DT` 的普通查询（`FROM table_name`）行为完全不受影响。

---

## 3. 架构与实现原理

```
                           SQL 文本
                              │
               ┌──────────────┴──────────────┐
               ▼                             ▼
       [tool/mkkeywordhash.c]          [src/parse.y]
       注册 DT 关键字 (TK_DT)        扩展 seltablist 规则
               │                             │
               └──────────────┬──────────────┘
                              ▼
                      [src/sqliteInt.h]
                   SrcItem.fg.isDt = 1
                              │
                              ▼
                      [src/resolve.c]
               sqlite3ApplyDtTransform()
            （在名称解析 resolveSelectStep 后触发）
         ┌────────────────────┴────────────────────┐
         ▼                                         ▼
   【显示转换】                               【搜索转换】
p->pEList 中的时间戳列                 p->pWhere 递归遍历
包装为 AST 节点:                      遇到 =, <, <=, >, >=, BETWEEN, IN:
datetime(col/1000,                    将右侧时间字符串常量折叠为
'unixepoch', 'localtime')             64 位整数节点 (TK_INTEGER)
         │                                         │
         └────────────────────┬────────────────────┘
                              ▼
                      [VDBE 代码生成器]
             左侧列纯净，直接命中 B-Tree 索引！
```

---

## 4. 源码修改清单

### 4.1 数据结构扩展：`src/sqliteInt.h`
在 `struct SrcItem` 的 `fg` 位域结构体中添加 `isDt` 标记位：
```c
struct SrcItem {
  char *zName;
  char *zAlias;
  Table *pSTab;
  struct {
    u8 jointype;
    unsigned notIndexed :1;
    unsigned isIndexedBy :1;
    // ...
    unsigned fromExists :1;
    unsigned isDt :1;          /* 新增：True 表示该表启用了 FROM DT 模式 */
  } fg;
  ...
};
```

### 4.2 关键字注册：`tool/mkkeywordhash.c`
在关键字哈希表 `aKeywordTable` 中按字母序加入 `DT`：
```c
  { "DO",               "TK_DO",           UPSERT,           2      },
  { "DT",               "TK_DT",           ALWAYS,           1      },
  { "DROP",             "TK_DROP",         ALWAYS,           1      },
```

### 4.3 语法规则扩展：`src/parse.y`
1. 将 `DT` 加入 `%fallback ID`，确保向后兼容性（当 `DT` 用作普通列名或别名时不会报错）：
   ```lemon
   %fallback ID
     ABORT ACTION AFTER ANALYZE ASC ATTACH BEFORE BEGIN BY CASCADE CAST COLUMNKW
     CONFLICT DATABASE DEFERRED DESC DETACH DO DT
   ```
2. 在 `seltablist` 产生式中增加支持 `DT` 的匹配规则：
   ```lemon
   seltablist(A) ::= stl_prefix(A) DT nm(Y) dbnm(D) as(Z) on_using(N). {
     A = sqlite3SrcListAppendFromTerm(pParse,A,&Y,&D,&Z,0,&N);
     if( A ) A->a[A->nSrc-1].fg.isDt = 1;
   }
   seltablist(A) ::= stl_prefix(A) DT nm(Y) dbnm(D) as(Z) indexed_by(I) on_using(N). {
     A = sqlite3SrcListAppendFromTerm(pParse,A,&Y,&D,&Z,0,&N);
     if( A ) A->a[A->nSrc-1].fg.isDt = 1;
     sqlite3SrcListIndexedBy(pParse, A, &I);
   }
   ```

### 4.4 转换引擎实现：`src/resolve.c`
在 `src/resolve.c` 中实现了核心的转换逻辑：

1. **时间戳列判定**（`sqlite3IsTimestampColumn`）：
   ```c
   static int sqlite3IsTimestampColumn(Column *pCol){
     const char *zName;
     int n;
     if( pCol==0 ) return 0;
     zName = pCol->zCnName;
     if( zName==0 ) return 0;
     n = sqlite3Strlen30(zName);
     if( (n >= 5 && sqlite3StrNICmp(zName + n - 5, "_time", 5) == 0) ||
         (n >= 3 && sqlite3StrNICmp(zName + n - 3, "_at", 3) == 0) ||
         (n >= 9 && sqlite3StrNICmp(zName + n - 9, "timestamp", 9) == 0) ||
         (n >= 5 && sqlite3StrNICmp(zName + n - 5, "_date", 5) == 0) ||
         (sqlite3StrICmp(zName, "time") == 0) ||
         (sqlite3StrICmp(zName, "ts") == 0) ){
       return 1;
     }
     return 0;
   }
   ```

2. **时间字符串转本地纪元毫秒**（`sqlite3DateStringToEpochMillis`）：
   支持 `YYYY-MM-DD HH:MM:SS[.SSS]`、`YYYY-MM-DDTHH:MM:SS` 以及纯日期 `YYYY-MM-DD`（对 `<=` 自动补齐为 `23:59:59.999`）。使用 `mktime` 完成本地时区到纪元毫秒的精准映射。

3. **结果列 AST 包装**（`sqlite3WrapColumnWithDatetime`）：
   将裸列重写为：`datetime(col / 1000, 'unixepoch', 'localtime')`，并保留列别名 `zEName` 为原始字段名。

4. **WHERE 条件常量折叠**（`applyDtToWhereExpr` & `convertExprToMillis`）：
   利用 `sqlite3Expr(db, TK_INTEGER, zBuf)` 构造 64 位整数节点，安全释放原字符串节点，避免内存泄漏，且确保数值不会因 32 位整型溢出。

5. **触发时机**：
   在 `resolveSelectStep` 完成 `pWhere` 名称解析后调用 `sqlite3ApplyDtTransform(pParse, &sNC, p);`。

---

## 5. 完整使用演示与验证

### 5.1 数据准备（标准 INSERT）
```sql
-- 创建测试表和索引
CREATE TABLE sys_log (
    id          INTEGER PRIMARY KEY,
    content     TEXT,
    create_time INTEGER   -- 存储 13 位毫秒时间戳
);
CREATE INDEX idx_create_time ON sys_log(create_time);

-- 插入三条测试数据
INSERT INTO sys_log (id, content, create_time) VALUES 
  (1, '用户登录', 1789905600000),  -- 对应: 2026-09-20 20:00:00
  (2, '支付订单', 1789984800000),  -- 对应: 2026-09-21 18:00:00
  (3, '申请退款', 1790089200000);  -- 对应: 2026-09-22 23:00:00
```

### 5.2 查询显示对比

#### 原生查询（普通 FROM，显示原始毫秒数字）
```sql
SELECT * FROM sys_log;
```
**结果**：
```text
id  content   create_time  
--  -------   -------------
1   用户登录  1789905600000
2   支付订单  1789984800000
3   申请退款  1790089200000
```

#### DT 查询（添加 DT，自动转换为格式化时间）
```sql
SELECT * FROM DT sys_log;
-- 或显式指定列：
SELECT id, create_time FROM DT sys_log;
```
**结果**：
```text
id  content   create_time        
--  -------   -------------------
1   用户登录  2026-09-20 20:00:00
2   支付订单  2026-09-21 18:00:00
3   申请退款  2026-09-22 23:00:00
```

---

### 5.3 条件过滤搜索（直接输入时间字符串）

#### 范围比较查询
```sql
SELECT * FROM DT sys_log 
WHERE create_time >= '2026-09-21 00:00:00' 
  AND create_time <  '2026-09-22 00:00:00';
```

#### BETWEEN 范围查询
```sql
SELECT * FROM DT sys_log 
WHERE create_time BETWEEN '2026-09-21 00:00:00' AND '2026-09-21 23:59:59';
```
**结果**：
```text
id  content   create_time        
--  -------   -------------------
2   支付订单  2026-09-21 18:00:00
```

---

### 5.4 索引命中验证（EXPLAIN QUERY PLAN）
```sql
EXPLAIN QUERY PLAN 
SELECT * FROM DT sys_log WHERE create_time >= '2026-09-21 00:00:00';
```
**输出**：
```text
QUERY PLAN
`--SEARCH sys_log USING INDEX idx_create_time (create_time>?)
```
> **结论**：验证表明，左侧列未被任何函数包装，右侧时间字符串在编译期被折叠为毫秒数字，**原生 B-Tree 索引完全生效**。

---

### 5.5 多表 JOIN 与别名支持
```sql
CREATE TABLE sys_user (id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO sys_user VALUES (1, 'Alice'), (2, 'Bob');

SELECT l.id, u.name, l.create_time 
FROM DT sys_log AS l 
JOIN sys_user AS u ON l.id = u.id 
WHERE l.create_time >= '2026-09-21 00:00:00';
```
**结果**：
```text
id  name  l.create_time      
--  ----  -------------------
2   Bob   2026-09-21 18:00:00
```

---

## 6. 构建与测试说明

在 WSL / Linux 构建环境中执行：
```bash
# 1. 重新生成关键字表与语法解析器
make -B parse.c keywordhash.h

# 2. 编译 sqlite3 命令行工具
make sqlite3

# 3. 运行测试验证
./sqlite3 :memory: < target/test_dt.sql
```
测试通过，内存检查无泄漏（`sqlite3LookasideUsed == 0`），所有断言正常。
