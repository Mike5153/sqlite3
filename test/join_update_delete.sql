-- Test script for Multi-table UPDATE and DELETE (JOIN / USING)

.echo on
.mode box
.header on

-- 1. Setup base tables
CREATE TABLE employees(id INT PRIMARY KEY, name TEXT, dept_id INT, salary REAL, bonus REAL);
CREATE TABLE departments(id INT PRIMARY KEY, name TEXT, performance TEXT);

INSERT INTO employees VALUES(1, 'Alice', 10, 1000, 0);
INSERT INTO employees VALUES(2, 'Bob', 20, 2000, 0);
INSERT INTO employees VALUES(3, 'Charlie', 10, 1500, 0);

INSERT INTO departments VALUES(10, 'Tech', 'A');
INSERT INTO departments VALUES(20, 'HR', 'B');

-- 2. MySQL-style UPDATE JOIN with table alias in SET
UPDATE employees e
JOIN departments d ON e.dept_id = d.id
SET e.bonus = e.salary * 0.1
WHERE d.performance = 'A';

SELECT * FROM employees;

-- 3. MySQL-style comma join in UPDATE
UPDATE employees e, departments d
SET e.salary = e.salary + 500
WHERE e.dept_id = d.id AND d.name = 'HR';

SELECT * FROM employees;

-- 4. MySQL-style DELETE JOIN with target alias
DELETE e FROM employees e
JOIN departments d ON e.dept_id = d.id
WHERE d.performance = 'B';

SELECT * FROM employees;

-- 5. Postgres-style DELETE FROM ... USING
DELETE FROM employees USING departments d
WHERE employees.dept_id = d.id AND employees.name = 'Charlie';

SELECT * FROM employees;

-- 6. 1-to-N Join Deduplication on DELETE
CREATE TABLE parent(id INT PRIMARY KEY, name TEXT);
CREATE TABLE child(id INT, parent_id INT, val TEXT);
INSERT INTO parent VALUES(1, 'P1'), (2, 'P2');
INSERT INTO child VALUES(101, 1, 'c1'), (102, 1, 'c2'), (103, 1, 'c3');

DELETE p FROM parent p JOIN child c ON p.id = c.parent_id;
SELECT * FROM parent;

-- 7. WITHOUT ROWID tables support
CREATE TABLE t_nr(a INT, b TEXT, PRIMARY KEY(a, b)) WITHOUT ROWID;
CREATE TABLE t_aux(a INT, status TEXT);
INSERT INTO t_nr VALUES(1, 'x'), (2, 'y'), (3, 'z');
INSERT INTO t_aux VALUES(1, 'done'), (3, 'done');

UPDATE t_nr nr JOIN t_aux aux ON nr.a = aux.a SET nr.b = 'updated_' || aux.status;
SELECT * FROM t_nr;

DELETE nr FROM t_nr nr JOIN t_aux aux ON nr.a = aux.a WHERE aux.status = 'done';
SELECT * FROM t_nr;

-- 8. RETURNING Clause
CREATE TABLE ret_test(id INT, v INT);
CREATE TABLE ret_aux(id INT, v INT);
INSERT INTO ret_test VALUES(1, 10), (2, 20);
INSERT INTO ret_aux VALUES(1, 100), (2, 200);

UPDATE ret_test t JOIN ret_aux a ON t.id = a.id SET t.v = a.v RETURNING id, v;
DELETE t FROM ret_test t JOIN ret_aux a ON t.id = a.id WHERE a.v = 100 RETURNING id;
SELECT * FROM ret_test;
