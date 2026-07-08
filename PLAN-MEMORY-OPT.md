# PLAN: 内存扫描内存占用优化 — 实现计划

## 优化策略总览（CP2077 10GB 进程）

| 策略 | 场景 | 当前峰值 | 优化后 | 优先级 |
|------|------|---------|--------|--------|
| B. mach_vm_remap CoW | 首次扫描 | 5.8 GB | ~300 MB | 🔴 P0 |
| I. 流式扫描 | 首次扫描 | 5.8 GB | ~数百 MB | 🔴 P0 |
| F. 指针表分块处理 | 间接指针 | 5.8-6.7 GB | ~1 GB | 🔴 P0 |
| D. 存储值磁盘化 | 存储值 | **11.3 GB** | ~300 MB | 🔴 P0 |
| G. calloc→malloc | 所有 | 零初始化浪费 | — | 🟡 P1 |
| H. NSCache 动态限制 | 间接指针 | 10GB 硬编码 | 物理内存/4 | 🟡 P1 |

**推荐优先级：B/I > F > D > G > H**

---

## 策略 B：mach_vm_remap CoW（最优方案）

### CP2077 效果
- 首次扫描：5.8 GB → ~300 MB（只建页表，不复制物理内存）
- 存储值：11.3 GB → ~5.5 GB（savedData 仍需一份，但 storedData 变成 CoW）
- 间接指针：5.8 GB → ~数百 MB（region 映射 + 指针表）

---

## 策略 I：流式扫描（备选，不依赖 Mach 私有 API）

### 原理

将 `ZGSearchForDataHelper` 从"预读全部 → 并行扫描"改为"逐 region 读取 → 扫描 → 释放"。

### CP2077 效果
- 首次扫描：5.8 GB → ~数百 MB（只持有当前扫描的 region）
- 代价：失去 `dispatch_apply` 并行，扫描时间增加 2-4x

### 实现

```cpp
// 旧代码（line 391-457）：
// 预读所有 regions → dispatch_apply 并行扫描

// 新代码：
dispatch_apply(regionCount, queue, ^(size_t regionIndex) {
    @autoreleasepool {
        ZGRegion *region = regions[regionIndex];
        void *bytes = nullptr;
        ZGMemorySize size = region.size;

        // 串行读取（mutex 保护 mach_vm_read_overwrite）
        @synchronized(readLock) {
            ZGReadBytes(processTask, region.address, &bytes, &size);
        }

        if (bytes != nullptr) {
            // 扫描这个 region
            NSData *results = helper(regionIndex, region.address, size, bytes, ...);
            // 立即释放
            ZGFreeBytes(bytes, size);
        }
    }
});
```

### 权衡
- **优势**：不依赖 Mach 私有 API，实现简单
- **劣势**：`@synchronized` 串行化读取会降低并行度
- **折中**：可以用读取队列（串行 queue 读取 + 并行 queue 扫描）

### 文件
- `ZGSearchFunctions.mm`：修改 `ZGSearchForDataHelper`

---

## 策略 B：mach_vm_remap CoW（最优方案）

### 原理

使用 `mach_vm_remap` 将目标进程的内存区域以 **Copy-on-Write（写时复制）** 方式映射到 Bit Slicer 的地址空间。这实现零拷贝访问——不分配物理内存，只建立虚拟地址映射。

### 优势
- **零拷贝**：不复制目标进程的内存页
- **O(1) 额外内存**：只消耗页表条目，不消耗物理内存
- **透明访问**：扫描代码无需修改，像读普通内存一样
- **安全性**：CoW 保证 Bit Slicer 的写入不影响目标进程

### 风险
- `mach_vm_remap` 是 Mach 私有 API，但 Bit Slicer 已经使用其他 Mach API
- 目标进程的 region 在 remap 后如果被 unmap，访问会 SIGBUS
- 需要处理 remap 失败的情况（fallback 到 ZGReadBytes）

### 实现步骤

#### 步骤 B1：新增 ZGRemapRegion 函数

**文件**：`Bit Slicer/ZGVirtualMemory.h` + `Bit Slicer/ZGVirtualMemory.c`

```c
// 新增 API：将目标进程的 region 以 CoW 方式映射到当前进程
// 返回的 bytes 指针指向映射区域，size 为实际映射大小
// 失败时返回 false（调用方应 fallback 到 ZGReadBytes）
bool ZGRemapRegion(ZGMemoryMap processTask, ZGMemoryAddress address,
                   ZGMemorySize size, void **outBytes, ZGMemorySize *outSize);

// 释放 remap 映射（对应 ZGRemapRegion）
bool ZGFreeRemappedRegion(void *bytes, ZGMemorySize size);
```

实现要点：
- 调用 `mach_vm_remap(mach_task_self(), &remapAddress, size, 0, VM_FLAGS_ANYWHERE, processTask, address, TRUE, &curProt, &maxProt, VM_INHERIT_SHARE)`
- `is_return = TRUE` 表示 CoW
- 记录映射地址和大小，用于后续 `mach_vm_deallocate`
- 失败时返回 false，不崩溃

#### 步骤 B2：新增 ZGRegionBuffer 结构

**文件**：`Bit Slicer/ZGVirtualMemory.h`

```c
// 统一的 region buffer 管理，支持 remap 和 read 两种模式
typedef struct {
    void *bytes;
    ZGMemorySize size;
    bool isRemapped;  // true = 用 ZGFreeRemappedRegion 释放，false = 用 ZGFreeBytes 释放
} ZGRegionBuffer;

// 尝试 remap，失败则 fallback 到 read
bool ZGRegionBufferCreate(ZGMemoryMap processTask, ZGMemoryAddress address,
                          ZGMemorySize size, ZGRegionBuffer *buffer);

// 释放 buffer（根据 isRemapped 选择释放方式）
void ZGRegionBufferFree(ZGRegionBuffer *buffer);
```

#### 步骤 B3：修改 ZGSearchForDataHelper 使用 remap

**文件**：`Bit Slicer/ZGSearchFunctions.mm`

修改 line 391-415 的 region 读取循环：

```cpp
// 旧代码：
void *newRegionBytes = nullptr;
if (ZGReadBytes(processTask, address, &newRegionBytes, &size))
{
    ZGRegionValue regionValue = {address, size, newRegionBytes};
    newRegionValues[regionIndex] = regionValue;
}

// 新代码：
ZGRegionBuffer buffer = {};
if (ZGRegionBufferCreate(processTask, address, size, &buffer))
{
    ZGRegionValue regionValue = {address, buffer.size, buffer.bytes, buffer.isRemapped};
    newRegionValues[regionIndex] = regionValue;
}
```

修改 ZGRegionValue 结构（line 263-268）：
```cpp
struct ZGRegionValue
{
    ZGMemoryAddress address;
    ZGMemorySize size;
    void *bytes;
    bool isRemapped;  // 新增
};
```

修改释放逻辑（line 459-472）：
```cpp
// 旧代码：
ZGFreeBytes(bytes, newRegionValue.size);

// 新代码：
ZGRegionBuffer buffer = {bytes, newRegionValue.size, newRegionValue.isRemapped};
ZGRegionBufferFree(&buffer);
```

#### 步骤 B4：修改 ZGStoredData 使用 remap

**文件**：`Bit Slicer/ZGStoredData.m`

修改 `storedDataFromProcessTask:`（line 47-59）：
```objc
// 旧代码：
if (ZGReadBytes(processTask, region.address, &bytes, &size))

// 新代码：
ZGRegionBuffer buffer = {};
if (ZGRegionBufferCreate(processTask, region.address, region.size, &buffer))
```

修改 dealloc（line 74-80）：
```objc
// 旧代码：
ZGFreeBytes(region.bytes, region.size);

// 新代码：
ZGRegionBuffer buffer = {region.bytes, region.size, region.isRemapped};
ZGRegionBufferFree(&buffer);
```

需要在 ZGRegion.h 中新增 `BOOL _isRemapped` ivar。

#### 步骤 B5：修改间接指针搜索使用 remap

**文件**：`Bit Slicer/ZGSearchFunctions.mm`

修改 `ZGSearchForIndirectPointer`（line 2428-2435）和其他读取 region 的路径。

#### 步骤 B6：修改窄化搜索使用 remap

**文件**：`Bit Slicer/ZGSearchFunctions.mm`

修改 `ZGNarrowSearchWithFunctionType`（line 3052）中的 `ZGReadBytes` 调用。

---

## 策略 A：流式扫描（备选方案）

### 原理

不一次性读取所有 regions，而是逐个读取、扫描、释放。

### 实现

修改 `ZGSearchForDataHelper`，将：
```
读取所有 regions → 并行扫描所有 regions → 异步释放
```
改为：
```
串行：读取 region → 扫描 region → 释放 region → 下一个 region
```

### 代价

- 失去 `dispatch_apply` 并行扫描的优势
- 扫描时间可能增加 2-4x

### 实现步骤

删除 line 389-415 的批量读取，改为在 `dispatch_apply` 内部读取：

```cpp
dispatch_apply(regionCount, queue, ^(size_t regionIndex) {
    @autoreleasepool
    {
        ZGRegion *region = regions[regionIndex];
        void *bytes = nullptr;
        ZGMemorySize size = region.size;

        if (ZGReadBytes(processTask, region.address, &bytes, &size))
        {
            // 扫描这个 region
            NSData *results = helper(regionIndex, region.address, size, bytes, ...);
            // 立即释放
            ZGFreeBytes(bytes, size);
        }
    }
});
```

**注意**：这会与 `dispatch_apply` 并行冲突（多个线程同时读取不同 regions）。需要限制并发数或改为串行。

---

## 策略 C：madvise(MADV_FREE)

### 原理

在扫描完每个 region 后，调用 `madvise(MADV_FREE)` 告诉内核这些页面可以回收。

### 实现

在 `ZGSearchForDataHelper` 的 `dispatch_apply` 块中，扫描完一个 region 后：

```cpp
madvise(bytes, size, MADV_FREE);
```

### 效果

不减少峰值内存，但加速内存回收（内核可以在内存压力时回收这些页面）。

---

## 策略 D：快照压缩

### 原理

对 `ZGStoredData` 的 region bytes 进行压缩存储。

### 实现

使用 `compression_encode_buffer`（macOS 内置压缩框架）：
- 存储时压缩
- 读取时解压

### 代价

- 压缩/解压 CPU 开销
- 随机访问需要解压整个 region

---

## 策略 F：指针表分块处理（间接指针搜索优化）

### 原因

`ZGSearchForIndirectPointer`（line 2376+）的指针表问题：
- 每个 `ZGPointerValueEntry` = 16 字节
- 1GB 进程按 4B 对齐 → 256M 个指针 × 16B = **4GB 指针表**
- `NSCache` 硬编码 10GB 限制（line 2625）

### 实现

**选项 1：分 region 构建指针表**
```
for each region:
    构建该 region 的指针表
    排序
    递归搜索该 region 的指针链
    释放指针表
```

**选项 2：按需构建**
- 只在递归搜索需要时才构建指针表
- 使用 LRU 缓存最近访问的 region 指针表

**选项 3：限制 NSCache**
```cpp
// line 2625: 动态限制
visitedSearchResults.totalCostLimit = NSProcessInfo.processInfo.physicalMemory / 4;
```

### 文件
- `ZGSearchFunctions.mm`：修改 `ZGSearchForIndirectPointer`

---

## 策略 G：calloc → malloc 优化

### 原因

`ZGReadBytes`（`ZGVirtualMemory.c:83-104`）使用 `calloc`：
```c
void *data = calloc(1, requestedSize);
mach_vm_read_overwrite(processTask, address, requestedSize, (mach_vm_address_t)data, size);
```

`calloc` 的零初始化完全浪费——`mach_vm_read_overwrite` 会覆盖全部内容。

### 实现

```c
// 旧代码：
void *data = calloc(1, requestedSize);

// 新代码：
void *data = malloc(requestedSize);
```

### 文件
- `ZGVirtualMemory.c`：修改 `ZGReadBytes`

---

## 策略 H：NSCache 动态限制

### 原因

`ZGSearchForIndirectPointer` 中（line 2625）：
```cpp
visitedSearchResults.totalCostLimit = 10000000000; // 10GB
```

硬编码 10GB 会导致在内存不足时系统 OOM。

### 实现

```cpp
// 根据可用物理内存动态设置
uint64_t physicalMemory = NSProcessInfo.processInfo.physicalMemory;
visitedSearchResults.totalCostLimit = physicalMemory / 4;
```

### 文件
- `ZGSearchFunctions.mm`：修改 `ZGSearchForIndirectPointer`

---

## 策略 E：延迟区域读取

### 原理

对间接指针搜索，不预先读取所有 regions，而是在需要时按需读取。

### 实现

修改 `ZGSearchForIndirectPointer`，使用 region 缓存表：
- 初始时只记录 region 地址范围，不读取 bytes
- 访问时按需读取并缓存
- 使用 LRU 策略淘汰

---

## 文件清单

| 文件 | 策略 | 改动量 |
|------|------|--------|
| `ZGVirtualMemory.h` | B | +20 行 |
| `ZGVirtualMemory.c` | B+G | +60 行 |
| `ZGSearchFunctions.mm` | B+F+H | +100/-50 行 |
| `ZGRegion.h` | B | +2 行 |
| `ZGStoredData.m` | B+D | +30/-10 行 |

**总计：~210 行新代码，~60 行修改。**

## 实施顺序

```
阶段 1：低风险快速收益
  1. ZGVirtualMemory.c — calloc→malloc (策略G)
  2. ZGSearchFunctions.mm — NSCache 动态限制 (策略H)

阶段 2：首次扫描优化（二选一）
  3a. ZGVirtualMemory.h/c + ZGRegion.h — remap API (策略B)
  3b. ZGSearchFunctions.mm — 流式扫描 (策略I，不依赖 Mach API)

阶段 3：间接指针优化
  4. ZGSearchFunctions.mm — 指针表分块处理 (策略F)

阶段 4：存储值优化
  5. ZGStoredData.m — 快照 remap/磁盘化 (策略B+D)

阶段 5：验证
  6. 构建 & 测试
  7. 用 CP2077 实测 RSS
```

## 风险缓解

1. **remap 失败**：所有路径都 fallback 到 `ZGReadBytes`，功能不受影响
2. **SIGBUS 风险**：在 remap 前检查 region 是否仍然有效
3. **性能回归**：remap 的页表建立开销 vs 内存拷贝开销，需要 benchmark
4. **私有 API 风险**：`mach_vm_remap` 是 Mach 微内核 API，不是 Apple 私有框架 API，风险较低
