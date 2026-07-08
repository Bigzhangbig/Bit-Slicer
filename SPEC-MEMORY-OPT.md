# SPEC: 内存扫描内存占用优化

## 概述

优化 Bit Slicer 内存扫描时的 RSS（Resident Set Size）占用，使扫描大型进程（1GB+）时不会导致 Bit Slicer 自身内存暴涨。

## 当前问题（以 CP2077 10GB 进程为例）

### 问题 1：首次扫描峰值 ~5.8 GB

`ZGSearchForDataHelper`（`ZGSearchFunctions.mm:347-519`）：
1. 枚举所有 VM regions（~3000-5000 个）
2. **一次性读取所有 ~5.5 GB region bytes 到内存**（line 391-415）
3. 用 `dispatch_apply` 并行扫描（line 420-457）
4. 异步释放（line 459-472）

**峰值 RSS ≈ 5.5 GB（区域数据）+ 300 MB（自身）≈ 5.8 GB**

### 问题 2：存储值比较峰值 ~11.3 GB（最危险）

`ZGStoredData`（`ZGStoredData.m:39-62`）保存全量快照：
- 已有 savedData: 5.5 GB
- 新读 storedData: 5.5 GB
- **峰值 RSS ≈ 11.3 GB** — 16GB Mac 几乎 OOM

### 问题 3：间接指针搜索指针表 ~220 MB - 1.1 GB

`ZGSearchForIndirectPointer`（`ZGSearchFunctions.mm:2376+`）：
- 5.5 GB / 4B 对齐 = ~1.375G 个候选
- 1-5% 有效 → 13.75M-68.75M 个 `ZGPointerValueEntry`（16B each）
- **指针表 220 MB - 1.1 GB**
- NSCache 硬编码 10GB（line 2625）
- 极端情况：22 GB → OOM

### 问题 4：calloc 零初始化浪费

`ZGReadBytes`（`ZGVirtualMemory.c:83-104`）使用 `calloc`，`mach_vm_read_overwrite` 会覆盖全部内容，零初始化完全浪费。

### 已优化：窄化搜索 ✅

`ZGNarrowSearchWithFunctionType`（`ZGSearchFunctions.mm:2965-3103`）已采用按需读取 + `lastUsedRegion` 缓存，额外峰值仅 ~256 KB。

### 综合对比

| 场景 | 峰值 RSS | 问题 |
|------|---------|------|
| 首次扫描 | ~5.8 GB | 全量预读 |
| 存储值比较 | **~11.3 GB** | 两个全量快照 |
| 间接指针 | ~5.8-6.7 GB | 全量扫描 + 指针表 |
| 窄化搜索 | ~5.5 GB | savedData 固定成本 |
| **16GB Mac 可用** | **~12 GB** | 场景 2 会 OOM |

### 与 Cheat Engine 对比

| | Bit Slicer | Cheat Engine |
|---|---|---|
| 首次扫描 | 预读全部 5.5GB | 分块读取，每块 64KB-1MB |
| 存储值 | 全量 RAM 快照 | 写临时文件，按需读回 |
| 指针搜索 | 全量指针表 RAM | 分块扫描 + 外部排序 |
| 窄化扫描 | ✅ 按需读取 | ✅ 按需读取 |
| 峰值 RSS | 5.5-11.3 GB | 通常 < 1 GB |

## 设计目标

1. **首次扫描峰值内存从 ~2x 降到 ~O(page_size * num_threads)**
2. **存储值快照内存从 ~1x 降到 ~0.5x 或更低**
3. **不影响搜索性能（或可接受的性能损失）**
4. **搜索引擎 API 不变**（调用方无感知）

## 约束

- 只修改搜索引擎层（`ZGSearchFunctions.mm`、`ZGVirtualMemory.h/c`、`ZGRegion.h/m`、`ZGStoredData.m`）
- 不修改 `ZGDocumentSearchController`、`ZGDocumentWindowController` 等上层代码
- 不改变搜索结果的正确性
- 保持 `ZGSearchProgressDelegate` 回调机制不变
