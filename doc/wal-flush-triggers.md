# SQLite WAL 落盘（Flush/Sync）触发机制

## 概览
SQLite WAL 模式下，数据落盘主要通过 `fsync` 操作实现。落盘的触发点取决于事务的提交阶段和同步模式。

## 核心函数调用链

```
sqlite3WalFrames()  [src/wal.c:4252]
    └─> walFrames()  [src/wal.c:4015]
        ├─> 写入 WAL header（如果需要）
        │   └─> sqlite3OsSync() [行4099] (PRAGMA synchronous=FULL 时)
        │
        ├─> 循环写入每个 frame
        │   └─> walWriteOneFrame()  [行4145]
        │       └─> walWriteToLog()  [src/wal.c:3915]
        │           └─> sqlite3OsSync() (在 iSyncPoint 时) [行3930]
        │
        └─> 提交时的最终同步
            └─> sqlite3OsSync()  [行4189] (isCommit && WAL_SYNC_FLAGS 时)
```

## 关键落盘触发点

### 1. **WAL Header 写入后** (src/wal.c:4098-4101)
```c
if( pWal->syncHeader ){
  rc = sqlite3OsSync(pWal->pWalFd, CKPT_SYNC_FLAGS(sync_flags));
  if( rc ) return rc;
}
```
- 触发条件：`pWal->syncHeader` 为真（通常在 PRAGMA synchronous=FULL 时）
- 作用：确保新的 WAL 文件头不会在乱序写之后被破坏

### 2. **Frame 写入过程中的增量同步** (src/wal.c:3915-3935)
`walWriteToLog()` 函数在跨越 `iSyncPoint` 边界时触发同步：

```c
if( iOffset < p->iSyncPoint && iOffset + iAmt >= p->iSyncPoint ){
    // 1. 写入 iSyncPoint 前的部分
    rc = sqlite3OsWrite(p->pFd, pContent, iFirstAmt, iOffset);
    
    // 2. **在此触发 fsync**
    rc = sqlite3OsSync(p->pFd, WAL_SYNC_FLAGS(p->syncFlags));
    
    // 3. 写入剩余部分
    rc = sqlite3OsWrite(p->pFd, pContent, iAmt, iOffset);
}
```

- 触发条件：`iSyncPoint` 由 `walFrames()` 计算，通常设置为扇区边界 (sector boundary)
- 目的：实现原子写入，防止部分frame在磁盘上不一致

### 3. **事务提交时的最终同步** (src/wal.c:4172-4191)
```c
if( isCommit && WAL_SYNC_FLAGS(sync_flags) != 0 ){
    // 处理 sector padding（可选）
    if( pWal->padToSectorBoundary ){
        int sectorSize = sqlite3SectorSize(pWal->pWalFd);
        w.iSyncPoint = ((iOffset + sectorSize - 1) / sectorSize) * sectorSize;
        // 重复最后一个 frame 直到达到扇区边界
    }
    
    // **最终提交时的 fsync**
    if( bSync ){
        rc = sqlite3OsSync(w.pFd, WAL_SYNC_FLAGS(sync_flags));
    }
}
```

- 触发条件：
  - `isCommit == true`（这是一个提交）
  - `WAL_SYNC_FLAGS(sync_flags) != 0`（根据 PRAGMA synchronous 设置）
- 作用：确保所有提交的数据已安全落盘

### 4. **Checkpoint 时的同步** (src/wal.c 在 walCheckpoint 函数中)
在执行 checkpoint 操作时：
```
walCheckpoint() -> walChecksumBytes() -> sqlite3OsSync()
```
- 作用：将 WAL 数据回写到主数据库文件并同步

## Sync Flags 详解

### 宏定义 (src/wal.c)
```c
WAL_SYNC_FLAGS(x)     // 提取同步标志位
CKPT_SYNC_FLAGS(x)    // Checkpoint 同步标志位
```

### 由 PRAGMA synchronous 控制
- **SYNCHRONOUS=OFF** (0): 无同步
- **SYNCHRONOUS=NORMAL** (1): 部分同步（只在提交时）
- **SYNCHRONOUS=FULL** (2): 完全同步（多个检查点）

## 性能影响

| 阶段 | 同步点 | 成本 |
|------|-------|------|
| Header | 一次（WAL 新建时） | 低 |
| Frame 写入 | 每个扇区边界 | 中 |
| 提交 | 一次 | 高 |
| Checkpoint | 多次 | 高 |

## 总结

**WAL 落盘的三大时刻：**

1. **WAL Header 初始化** → `sqlite3OsSync()` @ 行4099
2. **增量 Frame 写入** → `sqlite3OsSync()` @ 行3930（walWriteToLog 中）
3. **事务提交** → `sqlite3OsSync()` @ 行4189（walFrames 中）

关键参数：
- `sync_flags`：从上层传递下来，受 PRAGMA synchronous 影响
- `iSyncPoint`：通常是扇区对齐的偏移量，避免部分写入问题
- `isCommit`：标记是否为事务提交，提交时必须同步
