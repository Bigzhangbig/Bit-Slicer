# PLAN: Cheat Engine 式扫描工作流 — 实现计划

## 实现概览

改动范围：~400 行新代码，0 行搜索引擎改动。主要涉及 5 个文件 + 4 个本地化文件。

---

## 第 1 步：新建 ZGSearchSnapshot 数据类

**新建文件：**
- `Bit Slicer/ZGSearchSnapshot.h`
- `Bit Slicer/ZGSearchSnapshot.m`

**内容：**
```objc
@interface ZGSearchSnapshot : NSObject
@property (nonatomic, readonly) NSArray<ZGVariable *> *variables;
@property (nonatomic, readonly, nullable) ZGSearchResults *searchResults;
- (instancetype)initWithVariables:(NSArray<ZGVariable *> *)variables searchResults:(nullable ZGSearchResults *)searchResults;
@end
```

**作用：** 保存一轮扫描的完整状态（变量列表 + 搜索结果），用于多级撤销栈。

**Xcode 操作：** 将两个文件加入 `Bit Slicer` target。

---

## 第 2 步：修改 ZGDocumentSearchController

**文件：** `Bit Slicer/ZGDocumentSearchController.h` + `.m`

### 2a. 新增属性（.h）

```objc
@property (nonatomic, readonly) NSUInteger scanRound;        // 当前轮次，0 = idle
@property (nonatomic, readonly) BOOL hasScanHistory;          // 是否可撤销
```

### 2b. 新增方法（.h）

```objc
- (void)newScanWithString:(NSString *)searchStringValue dataType:(ZGVariableType)dataType pointerAddressSearch:(BOOL)pointerAddressSearch functionType:(ZGFunctionType)functionType storeValuesAfterSearch:(BOOL)storeValuesAfterSearch;
- (void)nextScanWithString:(NSString *)searchStringValue dataType:(ZGVariableType)dataType pointerAddressSearch:(BOOL)pointerAddressSearch functionType:(ZGFunctionType)functionType storeValuesAfterSearch:(BOOL)storeValuesAfterSearch;
- (void)undoScan;
- (void)resetScanState;
```

### 2c. 新增 ivar（.m）

```objc
NSUInteger _scanRound;
NSMutableArray<ZGSearchSnapshot *> *_scanHistory;  // 撤销栈
```

### 2d. 实现逻辑（.m）

**`newScanWithString:`：**
1. 调用 `resetScanState` 清空历史
2. 清空 `_documentData.variables`
3. 调用现有 `searchVariablesWithString:...` 执行首次扫描
4. 在搜索完成回调中：`_scanRound = 1`，push snapshot 到 `_scanHistory`

**`nextScanWithString:`：**
1. 保存当前状态到 `_scanHistory`（push snapshot）
2. 调用现有 `searchVariablesWithString:...` 执行 narrow 搜索
3. 在搜索完成回调中：`_scanRound++`

**`undoScan`：**
1. 调用 `[[windowController.undoManager] undo]`
2. NSUndoManager 恢复 `oldVariables` + `oldSearchResults`（通过现有 `updateVariables:searchResults:`）
3. 在 `updateVariables:searchResults:` 中增加逻辑：如果正在 undo，且 `_scanRound > 0`，则 `_scanRound--` 并 pop `_scanHistory`
4. 刷新按钮状态和状态栏

这样 NSUndoManager 的 Cmd+Z 和我们的「撤销扫描」按钮共享同一套 undo 栈，不会出现状态不一致。

**`resetScanState`：**
1. `_scanHistory = [NSMutableArray array]`
2. `_scanRound = 0`

**关键：** 搜索完成后的回调需要区分"来自 newScan/nextScan"还是"来自普通搜索"，以便正确管理 scanRound 和 scanHistory。最简方案是在搜索前设置一个 `_pendingScanType` 标志（枚举：none / newScan / nextScan），搜索完成回调中检查该标志。

**undoScan 与 NSUndoManager 的交互：**
- `searchVariablesWithString:` 已有 NSUndoManager 注册（line 1341-1342），Cmd+Z 可撤销搜索
- `undoScan` 需要同步更新 `_scanRound` 和 `_scanHistory`
- 实现方式：在 `updateVariables:searchResults:` 中检查是否正在 undo，如果是且 `_scanRound > 0`，则 `_scanRound--` 并 pop history
- `undoScan` 按钮调用 `[[undoManager] undo]` 而非自定义恢复，这样 NSUndoManager 和 scanHistory 保持同步

### 2e. 搜索完成回调修改

在 `searchVariablesWithString:` 的完成 block 中，line 1341-1342（NSUndoManager 注册）之后，增加 scanRound/scanHistory 管理：

```objc
// 现有代码（line 1341-1342）：
windowController.undoManager.actionName = ZGLocalizableSearchDocumentString(@"undoSearchAction");
[(ZGDocumentWindowController *)[windowController.undoManager prepareWithInvocationTarget:windowController] updateVariables:oldVariables searchResults:self->_searchResults];

// 新增代码：
if (self->_pendingScanType == ZGPendingScanTypeNew) {
    self->_scanRound = 1;
    [self->_scanHistory removeAllObjects];
    ZGSearchSnapshot *snapshot = [[ZGSearchSnapshot alloc] initWithVariables:oldVariables searchResults:previousSearchResults];
    [self->_scanHistory addObject:snapshot];
} else if (self->_pendingScanType == ZGPendingScanTypeNext) {
    ZGSearchSnapshot *snapshot = [[ZGSearchSnapshot alloc] initWithVariables:oldVariables searchResults:previousSearchResults];
    [self->_scanHistory addObject:snapshot];
    self->_scanRound++;
}
self->_pendingScanType = ZGPendingScanTypeNone;
[windowController updateScanButtons];
```

---

## 第 3 步：修改 ZGDocumentWindowController

**文件：** `Bit Slicer/ZGDocumentWindowController.h` + `.m`

### 3a. 不需要 IBOutlet

按钮状态通过 `validateUserInterfaceItem:` 控制（见 3d），不需要 IBOutlet。

### 3b. 新增 IBAction（.h/.m）

```objc
- (IBAction)newScan:(id)sender;
- (IBAction)rescan:(id)sender;    // 再次扫描
- (IBAction)undoScan:(id)sender;
```

### 3c. 实现（.m）

**`newScan:`：**
```objc
- (IBAction)newScan:(id)sender {
    NSString *searchValue = _searchValueTextField.stringValue;
    if (searchValue.length == 0 || !_searchController.canStartTask || !self.currentProcess.valid) return;

    ZGFunctionType functionType = [self selectedFunctionType];
    [_searchController newScanWithString:searchValue
                                dataType:[self selectedDataType]
                     pointerAddressSearch:(_documentData.searchType == ZGSearchTypeAddress)
                             functionType:functionType
                   storeValuesAfterSearch:_storeValuesAfterSearch];
}
```

**`nextScan:` — 同上，调用 `nextScanWithString:`**

**`undoScan:`：**
```objc
- (IBAction)undoScan:(id)sender {
    [_searchController undoScan];
}
```

### 3d. 按钮状态 — validateUserInterfaceItem:

在 `validateUserInterfaceItem:` 中增加 3 个 case（现有方法在 line 1223）：

```objc
else if (menuItem.action == @selector(newScan:)) {
    return _searchController.canStartTask && self.currentProcess.valid;
}
else if (menuItem.action == @selector(rescan:)) {
    return _searchController.canStartTask && self.currentProcess.valid && _searchController.scanRound > 0;
}
else if (menuItem.action == @selector(undoScan:)) {
    return _searchController.hasScanHistory;
}
```

macOS 自动调用此方法控制 toolbar item 的 enabled 状态，无需手动 `updateScanButtons`。

**额外**：搜索完成/撤销后，调用 `[self.window.toolbar validateVisibleItems]` 强制刷新。

### 3e. Enter 键行为修改

修改 `searchValue:` 方法（line 1678）：

```objc
- (IBAction)searchValue:(id)sender {
    // ... 现有验证逻辑 ...

    if (_searchController.scanRound == 0) {
        // 无历史 → 等效新扫描
        [_searchController newScanWithString:...];
    } else {
        // 有历史 → 等效再次扫描
        [_searchController nextScanWithString:...];
    }
}
```

### 3f. 状态栏轮次显示

修改 `updateNumberOfValuesDisplayedStatus` 或 `setStatusString` 调用处，在状态文本后追加轮次：

```objc
NSString *roundText = @"";
if (_searchController.scanRound > 0) {
    roundText = [NSString stringWithFormat:@"  |  %@", [NSString stringWithFormat:ZGLocalizableSearchDocumentString(@"scanRoundFormat"), _searchController.scanRound]];
}
```

---

## 第 4 步：修改 XIB

**文件：** `Base.lproj/Search Document Window.xib`

### 4a. 工具栏结构分析

工具栏（`ZGNoSmallSizeToolbar`）完全在 XIB 中静态定义，**无 NSToolbarDelegate 方法**。
当前 defaultToolbarItems（line 794-802）：
```
Target ▾ → Data Type ▾ → Search Type ▾ → Operator ▾ → <flexible space> → Store Values → Search
```

Store Values 按钮定义（line 774-778）— 新按钮的模板：
```xml
<toolbarItem implicitItemIdentifier="3AA9F85D-6EB6-40EF-8A55-7B78A1C5F61E"
    label="Store Values" paletteLabel="Store Values" tag="-1"
    image="app" catalog="system" bordered="YES" sizingBehavior="auto"
    id="sEk-qL-hC6" userLabel="Store Values">
    <connections>
        <action selector="storeAllValues:" target="-1" id="WwG-PD-Z3V"/>
    </connections>
</toolbarItem>
```

### 4b. 新增 3 个 toolbarItem

在 `<allowedToolbarItems>` 中增加 3 个定义（与 Store Values 同风格）：

```xml
<!-- 新扫描 -->
<toolbarItem implicitItemIdentifier="A1B2C3D4-NEW-SCAN-UUID"
    label="New Scan" paletteLabel="New Scan"
    image="magnifyingglass" catalog="system"
    bordered="YES" sizingBehavior="auto"
    id="nScan-tI-tem1" userLabel="New Scan">
    <connections>
        <action selector="newScan:" target="-1" id="..."/>
    </connections>
</toolbarItem>

<!-- 再次扫描 -->
<toolbarItem implicitItemIdentifier="E5F6G7HI-RESCAN-UUID"
    label="Re-scan" paletteLabel="Re-scan"
    image="arrow.clockwise" catalog="system"
    bordered="YES" sizingBehavior="auto"
    id="rScan-tI-tem2" userLabel="Re-scan">
    <connections>
        <action selector="rescan:" target="-1" id="..."/>
    </connections>
</toolbarItem>

<!-- 撤销扫描 -->
<toolbarItem implicitItemIdentifier="J8K9L0MN-UNDO-SCAN-UUID"
    label="Undo Scan" paletteLabel="Undo Scan"
    image="arrow.uturn.backward" catalog="system"
    bordered="YES" sizingBehavior="auto"
    id="uScan-tI-tem3" userLabel="Undo Scan">
    <connections>
        <action selector="undoScan:" target="-1" id="..."/>
    </connections>
</toolbarItem>
```

### 4c. defaultToolbarItems 排列

在 Store Values 之前插入 3 个引用：
```xml
<defaultToolbarItems>
    <toolbarItem reference="jO3-Z2-Pv7"/>        <!-- Target -->
    <toolbarItem reference="70m-RL-vim"/>         <!-- Data Type -->
    <toolbarItem reference="D2T-dX-W9r"/>         <!-- Search Type -->
    <toolbarItem reference="moB-Wu-fvx"/>         <!-- Operator -->
    <toolbarItem reference="cbr-z0-cak"/>         <!-- FlexibleSpace -->
    <toolbarItem reference="nScan-tI-tem1"/>      <!-- New Scan ← 新增 -->
    <toolbarItem reference="rScan-tI-tem2"/>      <!-- Re-scan ← 新增 -->
    <toolbarItem reference="uScan-tI-tem3"/>      <!-- Undo Scan ← 新增 -->
    <toolbarItem reference="sEk-qL-hC6"/>         <!-- Store Values -->
    <searchToolbarItem reference="tHJ-Bh-ZVW"/>  <!-- Search -->
</defaultToolbarItems>
```

最终布局：
```
[Target ▾] [Type ▾] [Search ▾] [Op ▾] <---flex---> [🔍New] [🔄Re] [↩Undo] [📦Store] [🔍 Search Field]
```

### 4d. SF Symbols 图标

| 按钮 | SF Symbol | 说明 |
|------|-----------|------|
| New Scan | `magnifyingglass` | 放大镜，表示新搜索 |
| Re-scan | `arrow.clockwise` | 顺时针箭头，表示再次扫描 |
| Undo Scan | `arrow.uturn.backward` | U型回退箭头，表示撤销 |

### 4e. 不需要 IBOutlet

Store Values 有 IBOutlet 是因为需要动态切换图标（`app` / `app.fill` / `app.badge.fill`）。
新按钮**不需要动态图标**，状态通过 `validateUserInterfaceItem:` 控制 enabled/disabled。
因此**不需要 IBOutlet**，只需 IBAction + validate 逻辑。

---

## 第 5 步：本地化

**现有文件：** `en.lproj/Localizable.strings`、`es.lproj/Localizable.strings`、`ru.lproj/Localizable.strings`

**注意：** `zh.lproj` 目前不存在。CLAUDE.md 提到过 zh.lproj（commit `44c13e8d`），但实际目录中没有。如果需要简中支持，需新建 `zh.lproj/Localizable.strings`。

新增键值对：

**en:**
```
"newScanButton" = "New Scan";
"nextScanButton" = "Next Scan";
"undoScanButton" = "Undo Scan";
"scanRoundFormat" = "Round %lu";
```

**es:**
```
"newScanButton" = "Nuevo escaneo";
"nextScanButton" = "Siguiente escaneo";
"undoScanButton" = "Deshacer escaneo";
"scanRoundFormat" = "Ronda %lu";
```

**ru:**
```
"newScanButton" = "Новое сканирование";
"nextScanButton" = "Следующее сканирование";
"undoScanButton" = "Отменить сканирование";
"scanRoundFormat" = "Раунд %lu";
```

---

## 第 6 步：修改 updateVariables:searchResults: 支持 undo 时同步 scanRound

**文件：** `Bit Slicer/ZGDocumentWindowController.m`

现有方法（line 1199-1214）：
```objc
- (void)updateVariables:(NSArray<ZGVariable *> *)newWatchVariablesArray searchResults:(ZGSearchResults *)searchResults
{
    if ([self undoManager].isUndoing || [self undoManager].isRedoing)
    {
        [(ZGDocumentWindowController *)[[self undoManager] prepareWithInvocationTarget:self] updateVariables:_documentData.variables searchResults:_searchController.searchResults];
    }
    _documentData.variables = newWatchVariablesArray;
    _searchController.searchResults = searchResults;
    [_tableController updateWatchVariablesTimer];
    [_variablesTableView reloadData];
    [self updateNumberOfValuesDisplayedStatus];
    [self updateSearchAddressOptions];
}
```

在 undo/redo 分支中增加 scanRound 同步：
```objc
if ([self undoManager].isUndoing || [self undoManager].isRedoing)
{
    // 现有 undo 注册...

    // 新增：同步 scanRound
    if ([self undoManager].isUndoing && _searchController.scanRound > 0) {
        [_searchController popScanHistory];
    }
}
```

在 `ZGDocumentSearchController` 中增加 `popScanHistory` 方法：
```objc
- (void)popScanHistory {
    if (_scanHistory.count > 0) {
        [_scanHistory removeLastObject];
        _scanRound--;
    }
}
```

---

## 第 7 步：状态重置逻辑

在以下场景调用 `[_searchController resetScanState]`：

- `ZGDocumentWindowController` 切换进程时
- 切换数据类型时（`selectedDataType` 变化）
- `searchValue:` 中 `_documentData.variables.count == 0` 时（现有逻辑 line 1702-1704，已清除 undoManager）

---

## 文件清单

| 文件 | 操作 | 改动量 |
|------|------|--------|
| `ZGSearchSnapshot.h` | 新建 | ~15 行 |
| `ZGSearchSnapshot.m` | 新建 | ~30 行 |
| `ZGDocumentSearchController.h` | 修改 | +20 行 |
| `ZGDocumentSearchController.m` | 修改 | +130 行 |
| `ZGDocumentWindowController.h` | 修改 | +5 行 |
| `ZGDocumentWindowController.m` | 修改 | +80 行 |
| `Base.lproj/Search Document Window.xib` | 修改 | +3 toolbarItem |
| `en.lproj/Localizable.strings` | 修改 | +4 行 |
| `es.lproj/Localizable.strings` | 修改 | +4 行 |
| `ru.lproj/Localizable.strings` | 修改 | +4 行 |

**总计：** 2 个新文件，8 个修改文件，~290 行新代码。

**可选（如需简中）：** 新建 `zh.lproj/Localizable.strings`。

---

## 实施顺序

```
1. ZGSearchSnapshot.h/m                    ← 新建，无依赖
2. ZGDocumentSearchController.h/m          ← 修改，依赖 1
3. ZGDocumentWindowController.h/m          ← 修改，依赖 2（含 updateVariables: 修改）
4. Base.lproj/Search Document Window.xib   ← 修改，依赖 3
5. Localizable.strings (×3)                ← 独立，可并行
6. 构建 & 测试
```

---

## 测试计划

### 手动测试

1. **基本流程**：新扫描 → 输入值 → 再次扫描 → 再次扫描 → 撤销 → 撤销
2. **Enter 键**：无历史时 Enter = 新扫描，有历史时 Enter = 再次扫描
3. **按钮状态**：搜索中全部禁用，idle 时只有新扫描可用
4. **进程切换**：切换进程后历史清空
5. **数据类型切换**：切换类型后历史清空
6. **搜索取消**：取消搜索不影响历史
7. **无结果搜索**：搜索无结果仍计入轮次
8. **表达式搜索**：`58 * 8`、`$variable` 等正常工作
9. **多级撤销**：连续撤销 5+ 轮，验证每轮结果正确

### XCTest 扩展

在 `Bit Slicer Tests/` 中增加 `ScanWorkflowTest`：
- 测试 `ZGSearchSnapshot` 的初始化和属性
- 测试 `scanRound` 在 new/next/undo 后的值
- 测试 `scanHistory` 的 push/pop 行为
- 测试 `resetScanState` 清空所有状态
