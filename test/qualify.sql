-- SQLite QUALIFY Clause Test Suite
-- Covers: alias resolution, direct window functions, top-N deduplication,
-- combined conditions, ORDER BY/LIMIT interaction, GROUP BY/HAVING interaction,
-- and semantic validation error handling.

CREATE TABLE employees(id INT, department TEXT, salary INT);
INSERT INTO employees VALUES
  (1, 'Engineering', 10000),
  (2, 'Engineering', 12000),
  (3, 'Engineering', 9000),
  (4, 'Engineering', 8000),
  (5, 'Sales', 7000),
  (6, 'Sales', 8500),
  (7, 'Sales', 6000);

.print === Test 1: QUALIFY using alias ===
SELECT id, department, salary,
       RANK() OVER (PARTITION BY department ORDER BY salary DESC) as rank
FROM employees
QUALIFY rank <= 2;

.print === Test 2: QUALIFY using direct window function ===
SELECT id, department, salary
FROM employees
QUALIFY RANK() OVER (PARTITION BY department ORDER BY salary DESC) <= 2;

.print === Test 3: Deduplication Top 1 without window func in SELECT ===
SELECT id, department, salary
FROM employees
QUALIFY ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) = 1;

.print === Test 4: Mixed condition ===
SELECT id, department, salary,
       RANK() OVER (PARTITION BY department ORDER BY salary DESC) as rk
FROM employees
QUALIFY rk <= 2 AND salary >= 8000;

.print === Test 5: QUALIFY + ORDER BY + LIMIT ===
SELECT id, salary, ROW_NUMBER() OVER (ORDER BY salary DESC) as rn
FROM employees
QUALIFY rn <= 5
ORDER BY salary ASC
LIMIT 3;

.print === Test 6: GROUP BY + HAVING + QUALIFY ===
SELECT department, avg(salary) as avgsal,
       RANK() OVER (ORDER BY avg(salary) DESC) as rk
FROM employees
GROUP BY department
HAVING count(*) >= 3
QUALIFY rk = 1;

.print === Test 7: Error test - QUALIFY without window functions ===
SELECT id FROM employees QUALIFY id > 1;
