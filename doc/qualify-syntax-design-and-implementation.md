# SQLite `QUALIFY` 窗口函数过滤子句设计与实现文档

## 1. 背景与核心痛点

在 SQL 标准执行生命周期中，`WHERE` 和 `HAVING` 的计算时机均早于窗口函数（Window Functions）：
$$\text{FROM/JOIN} \longrightarrow \mathbf{WHERE} \longrightarrow \mathbf{GROUP\ BY} \longrightarrow \mathbf{HAVING} \longrightarrow \mathbf{WINDOW} \longrightarrow \text{DISTINCT} \longrightarrow \text{ORDER BY} \longrightarrow \text{LIMIT}$$

### 传统 SQLite 的痛点：
在 SQLite 中，若要基于窗口函数的结果（例如 `ROW_NUMBER()`、`RANK()`、`DENSE_RANK()`）进行过滤（如分组 Top-N、分页、分组去重），**必须外套一层嵌套子查询或 CTE**：

```sql
-- 传统繁琐写法：必须嵌套一层子查询
SELECT id, department, salary, rank
FROM (
    SELECT id, department, salary,
           RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS rank
    FROM employees
)
WHERE rank <= 3;
```

这带来了以下痛点：
1. **语法结构冗长**：每次做窗口过滤都必须多一层外层包装与缩进，降低 SQL 可读性与组合性。
2. **多余投影与列维护成本**：外层子查询需要显式重复声明投影列，当表字段众多或动态增删时，极易漏写字段。
3. **隐藏列泄露问题**：当只需要基于窗口函数过滤、但输出中不需要展示该窗口计算列时，嵌套子查询必须在外层逐个枚举不需要的列，无法简洁使用 `SELECT id, department, salary`。

为了彻底解决此问题，本项目在 SQLite 编译器与内核层面引入了 **`QUALIFY` 子句**。

---

## 2. 语法规范与设计目标

### 2.1 语法形式
`QUALIFY` 子句位于 `HAVING` / `WINDOW` 之后、`ORDER BY` / `LIMIT` 之前：

```sql
SELECT [DISTINCT] <result_columns>
FROM <tables>
[WHERE <where_condition>]
[GROUP BY <group_expressions>]
[HAVING <having_condition>]
[WINDOW <window_definitions>]
QUALIFY <qualify_condition>
[ORDER BY <order_expressions>]
[LIMIT <n> [OFFSET <m>]];
```

### 2.2 支持的过滤特性
1. **支持引用 SELECT 输出列别名**：
   ```sql
   SELECT id, department, salary,
          RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS rank
   FROM employees
   QUALIFY rank <= 3;
   ```
2. **支持直接编写窗口函数（无需在 SELECT 列表中投影）**：
   ```sql
   SELECT id, department, salary
   FROM employees
   QUALIFY ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) = 1;
   ```
3. **支持复合条件过滤（窗口条件 + 普通基表列条件）**：
   ```sql
   SELECT id, department, salary,
          RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS rank
   FROM employees
   QUALIFY rank <= 3 AND salary >= 8000;
   ```
4. **与 GROUP BY / HAVING / ORDER BY / LIMIT 完整联动**：
   `QUALIFY` 过滤严格在聚合后、窗口计算后执行，并在写入 Sorter 排序器与 LIMIT 计数器前提前过滤。
5. **合规性校验**：
   若查询包含 `QUALIFY` 子句但没有任何窗口函数，编译器自动抛出语义错误：
   `QUALIFY clause requires at least one window function`。

---

## 3. 架构与执行原理

```
                            SQL 文本 (含 QUALIFY)
                                      │
                       ┌──────────────┴──────────────┐
                       ▼                             ▼
               [tool/mkkeywordhash.c]          [src/parse.y]
               注册 QUALIFY 关键字           扩展 oneselect 与 qualify_opt
                       │                             │
                       └──────────────┬──────────────┘
                                      ▼
                              [src/sqliteInt.h]
                              Select.pQualify 节点
                                      │
                                      ▼
                              [src/resolve.c]
                           resolveSelectStep()
            开启 NC_UEList | NC_AllowWin 符号与别名解析
            校验 QUALIFY 必须依赖窗口函数 (p->pWin != 0)
                                      │
                                      ▼
                              [src/window.c]
                          sqlite3WindowRewrite()
            保留 pQualify 于外层，自动将基表列重定向至 iEphCsr 游标
                                      │
                                      ▼
                              [src/select.c]
                             selectInnerLoop()
            ┌─────────────────────────────────────────────────┐
            │ 窗口计算引擎计算完成 (pWin->regResult 就绪)        │
            │ 执行: sqlite3ExprIfFalse(pParse, pQualify, ...) │
            │ 若不满足: 立即 OP_IfFalse 跳转至 iContinue 剪枝!   │
            └─────────────────────────────────────────────────┘
                                      │ (仅通过 QUALIFY 的行)
                                      ▼
                        Sorter 写入 / DISTINCT / LIMIT / 结果发射
```

---

## 4. 源码修改清单

### 4.1 关键字词法：`tool/mkkeywordhash.c`
在关键字表中按字母序加入 `QUALIFY`：
```c
  { "PRIMARY",          "TK_PRIMARY",      ALWAYS,           1      },
  { "QUALIFY",          "TK_QUALIFY",      WINDOWFUNC,       3      },
  { "QUERY",            "TK_QUERY",        EXPLAIN,          0      },
```

### 4.2 语法分析与 AST 挂载：`src/parse.y`
1. 定义 `qualify_opt` 规则与析构器：
   ```lemon
   %type qualify_opt {Expr*}
   %destructor qualify_opt {sqlite3ExprDelete(pParse->db, $$);}
   qualify_opt(A) ::= .                {A = 0;}
   qualify_opt(A) ::= QUALIFY expr(X). {A = X;}
   ```
2. 在 `oneselect` 产生式中挂载 `qualify_opt`：
   ```lemon
   oneselect(A) ::= SELECT distinct(D) selcollist(W) from(X) where_opt(Y)
                    groupby_opt(P) having_opt(Q) qualify_opt(QL)
                    orderby_opt(Z) limit_opt(L). {
     A = sqlite3SelectNew(pParse,W,X,Y,P,Q,Z,D,L);
     if( A ){
       A->pQualify = QL;
     }else{
       sqlite3ExprDelete(pParse->db, QL);
     }
   }
   %ifndef SQLITE_OMIT_WINDOWFUNC
   oneselect(A) ::= SELECT distinct(D) selcollist(W) from(X) where_opt(Y)
                    groupby_opt(P) having_opt(Q) window_clause(R) qualify_opt(QL)
                    orderby_opt(Z) limit_opt(L). {
     A = sqlite3SelectNew(pParse,W,X,Y,P,Q,Z,D,L);
     if( A ){
       A->pWinDefn = R;
       A->pQualify = QL;
     }else{
       sqlite3WindowListDelete(pParse->db, R);
       sqlite3ExprDelete(pParse->db, QL);
     }
   }
   %endif
   ```

### 4.3 核心数据结构与遍历器：`src/sqliteInt.h`, `src/walker.c`, `src/treeview.c`
1. `src/sqliteInt.h`：在 `struct Select` 中增加 `Expr *pQualify;`。
2. `src/walker.c`：在 `sqlite3WalkSelectExpr` 中增加遍历 `sqlite3WalkExpr(pWalker, p->pQualify)`。
3. `src/treeview.c`：在 `sqlite3TreeViewSelect` 中增加 `QUALIFY` 项的树状打印支持。
4. `src/expr.c`：在 `heightOfSelect` 与 `sqlite3SelectDup` 中完成深度与深拷贝支持。
5. `src/whereexpr.c`：在 `exprSelectUsage` 中跟踪 `pQualify` 的掩码使用。

### 4.4 符号解析与别名联动：`src/resolve.c`
1. 别名与窗口函数共享机制（`resolveAlias`）：
   ```c
   if( ExprHasProperty(pExpr, EP_WinFunc) ){
     if( ALWAYS(pExpr->y.pWin!=0) ){
       pExpr->y.pWin->pOwner = pExpr;
   #ifndef SQLITE_OMIT_WINDOWFUNC
       if( pSelect ){
         sqlite3WindowLink(pSelect, pExpr->y.pWin);
       }
   #endif
     }
   }
   ```
2. 解析 `pQualify` 并进行语义校验（`resolveSelectStep`）：
   ```c
   #ifndef SQLITE_OMIT_WINDOWFUNC
       if( p->pQualify ){
         sNC.ncFlags |= NC_UEList | NC_AllowAgg | NC_AllowWin;
         sNC.uNC.pEList = p->pEList;
         sNC.pWinSelect = p;
         if( sqlite3ResolveExprNames(&sNC, p->pQualify) ) return WRC_Abort;
         sNC.ncFlags &= ~NC_AllowWin;
         if( p->pWin==0 ){
           sqlite3ErrorMsg(pParse, "QUALIFY clause requires at least one window function");
           return WRC_Abort;
         }
       }
   #endif
   ```

### 4.5 窗口重写子查询联动：`src/window.c`
实现 `sqlite3WindowRewriteExpr`，在 `sqlite3WindowRewrite` 中重写 `pQualify` 中的基表列：
```c
selectWindowRewriteEList(pParse, pMWin, pSrc, p->pEList, pTab, &pSublist);
selectWindowRewriteEList(pParse, pMWin, pSrc, p->pOrderBy, pTab, &pSublist);
if( p->pQualify ){
  sqlite3WindowRewriteExpr(pParse, pMWin, pSrc, p->pQualify, pTab, &pSublist);
}
```

### 4.6 虚拟机提前剪枝：`src/select.c`
在 `selectInnerLoop` 最早时机插入判断，未命中行立即跳过：
```c
#ifndef SQLITE_OMIT_WINDOWFUNC
  if( p->pQualify ){
    sqlite3ExprIfFalse(pParse, p->pQualify, iContinue, SQLITE_JUMPIFNULL);
  }
#endif
```

---

## 5. 验证与演示用例

数据准备：
```sql
CREATE TABLE employees(id INT, department TEXT, salary INT);
INSERT INTO employees VALUES
  (1, 'Engineering', 10000),
  (2, 'Engineering', 12000),
  (3, 'Engineering', 9000),
  (4, 'Engineering', 8000),
  (5, 'Sales', 7000),
  (6, 'Sales', 8500),
  (7, 'Sales', 6000);
```

### 用例 1：使用别名过滤 Top-2
```sql
SELECT id, department, salary,
       RANK() OVER (PARTITION BY department ORDER BY salary DESC) as rank
FROM employees
QUALIFY rank <= 2;
```
**输出**：
```text
2|Engineering|12000|1
1|Engineering|10000|2
6|Sales|8500|1
5|Sales|7000|2
```

### 用例 2：分组去重（窗口函数无需在 SELECT 中投影）
```sql
SELECT id, department, salary
FROM employees
QUALIFY ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) = 1;
```
**输出**：
```text
2|Engineering|12000
6|Sales|8500
```

### 用例 3：复合过滤 + ORDER BY + LIMIT
```sql
SELECT id, salary, ROW_NUMBER() OVER (ORDER BY salary DESC) as rn
FROM employees
QUALIFY rn <= 5
ORDER BY salary ASC
LIMIT 3;
```
**输出**：
```text
4|8000|5
6|8500|4
3|9000|3
```

### 用例 4：误用拦截校验
```sql
SELECT id FROM employees QUALIFY id > 1;
```
**输出**：
```text
Parse error: QUALIFY clause requires at least one window function
```
