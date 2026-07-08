# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

Bit Slicer 是 macOS 通用游戏修改器 —— Cocoa + Mach 内核 API，用于扫描/修改目标进程虚拟内存、下断点、注入汇编，并以嵌入式 Python 脚本自动化。仅 macOS，纯 Objective-C（含少量 C/C++/Objective-C++），无 Swift。

## 构建、运行、测试

Xcode 项目，无 CLI 元项目文件（无 Package.swift、Makefile、pod/carthage/spm）。SDK：`macosx`。部署目标：`15.6`。架构：`arm64`。签名：ad-hoc（`CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_STYLE = Manual`），入 sandbox 只在 Release entitlements 中启用。

```sh
# 构建 app (Debug)
xcodebuild -project "Bit Slicer.xcodeproj" -scheme "Bit Slicer" -configuration Debug build

# 构建 Release
xcodebuild -project "Bit Slicer.xcodeproj" -scheme "Bit Slicer" -configuration Release build

# 跑全部测试（XCTest）
xcodebuild -project "Bit Slicer.xcodeproj" -scheme "Bit Slicer" -destination 'platform=macOS' test

# 跑单个测试类或方法
xcodebuild -project "Bit Slicer.xcodeproj" -scheme "Bit Slicer" \
  -destination 'platform=macOS' \
  -only-testing:"Bit Slicer Tests/SearchVirtualMemoryTest" test

xcodebuild -project "Bit Slicer.xcodeproj" -scheme "Bit Slicer" \
  -destination 'platform=macOS' \
  -only-testing:"Bit Slicer Tests/SearchVirtualMemoryTest/testInt32Search" test
```

日常开发直接用 Xcode（`open "Bit Slicer.xcodeproj"`）。app 需要 `task_for_pid` 权限调其他进程 → 用 Debug entitlements 或授予开发工具权限；Release entitlements 已 sandbox 化。

## 顶层结构

- `Bit Slicer/` —— 全部应用源码（~230 个 `.h/.m/.mm/.c/.cpp`，`ZG` 前缀）。入口 `main.m` → `NSApplicationMain` → `ZGAppController`（`NSApplicationDelegate`，管全部窗口控制器、进程任务、更新器、脚本解释器）。
- `Bit Slicer Tests/` —— XCTest 测试目标（`BinarySearchTest`, `ByteArraySearchTest.mm`, `LinearExpressionParsingTest`, `PointerFunctionSubstitutionTest`, `SearchVirtualMemoryTest`, `VariableDisplayTest`）。
- `Bit Slicer.xcodeproj/` —— 共享 scheme 在 `xcshareddata/`。
- `deps/` —— **不用包管理器**。预编译 framework + vendor 源码。`source.txt` 记录每个依赖的上游 URL + commit + 配置说明。改依赖前先读对应 `source.txt`。

### `deps/` 内容

| 目录 | 用途 |
|---|---|
| `HexFiend/` | 十六进制编辑器视图 + 数据检查器（framework + 头文件） |
| `capstone/` | 反汇编（`ZGCapstoneDisassemblerObject`） |
| `keystone/` | 汇编（动态库） |
| `DDMathParser/` | 表达式求值（搜索时 `58 * 8` 之类） |
| `python/` | 内嵌 `Python.framework`（3.14.3）供脚本 |
| `CoreSymbolication/` | Apple 私有框架头 —— 符号解析（Debugger 用） |
| `Sparkle/` | 自动更新 |
| `ShortcutRecorder/` | 全局快捷键 UI |
| `mach_exc/` | `mach_exc.defs` MIG 生成的 server/user stub（异常处理） |
| `AGScopeBar`, `OSCSingleThreadQueue`, `VDKQueue` | 散装 vendored 源（直接放 `deps/` 根） |

Framework search paths：`$(PROJECT_DIR)/deps/DDMathParser`, `$(PROJECT_DIR)/deps/HexFiend`, `$(PROJECT_DIR)/deps/Sparkle`, 以及 `$(SYSTEM_LIBRARY_DIR)/PrivateFrameworks`（`CoreSymbolication` 私有 API）。

## 架构大图

前缀约定：所有工程源 `ZG*` 前缀。类聚成以下子系统：

### 1. 进程 & 虚拟内存
- `ZGProcess`, `ZGProcessList`, `ZGProcessTaskManager` —— 枚举 running processes，用 `task_for_pid` 拿 mach task port，追踪其存活期。
- `ZGVirtualMemory.c/.h`（纯 C 快速路径）+ `ZGVirtualMemoryStringReading.m`, `ZGVirtualMemoryUserTags.m` —— 读/写/保护属性/字符串探测/region 枚举。
- `ZGRegion`, `ZGMemoryTypes.h` —— 地址/大小/保护标志类型别名。
- `ZGRootlessConfiguration` —— SIP 保护进程识别（写 root 保护 app 需知道跳过）。

### 2. 搜索引擎
- `ZGSearchFunctions.mm`（Obj-C++ 模板化搜索核） + `ZGSearchData`（用户搜索条件） + `ZGSearchResults`（迭代结果） + `ZGSearchProgress`/`ZGSearchProgressDelegate`（异步进度回调）。
- `ZGDataValueExtracting` —— 各数据类型（int8-64、float、double、string、pointer、byte array）编解码。
- `ZGDocumentSearchController` —— 把 UI/文档 hook 到搜索引擎。
- `HFByteArray_FindReplace.cpp` —— HexFiend 侧字节数组查找。

### 3. 文档（`.slicer` 文件）
- `ZGDocument`, `ZGDocumentController`, `ZGDocumentData`, `ZGDocumentWindowController` —— `NSDocument` 生态；一个文档 = 一个附加进程 + 变量列表 + 搜索状态。
- `ZGDocumentTableController`, `ZGDocumentOptionsViewController` —— 表格 + 搜索选项 UI。
- `ZGVariable`, `ZGVariableController` —— 一行变量的模型 + 操作（编辑地址、值、大小、冻结、undo/redo）。
- 相关对话框：`ZGEdit(Address|Description|Label|Size|Value)WindowController`, `ZGWatchVariableWindowController`。

### 4. 调试器 & 断点
- `ZGDebuggerController` —— 反汇编视图控制器。
- `ZGDebuggerUtilities`, `ZGDisassemblerObject` (+ `ZGCapstoneDisassemblerObject`, `ZGInstruction`) —— 反汇编抽象层（Capstone 后端）。
- `ZGBreakPoint`, `ZGBreakPointController`, `ZGBreakPointDelegate`, `ZGBreakPointCondition(ViewController)` —— 硬件/软件断点，含条件。
- `ZGBacktrace(ViewController)`, `ZGRegistersState`, `ZGRegistersViewController` —— 命中断点后的调用栈 + 寄存器编辑。
- `ZGDebugThread`, `ZGCodeInjectionHandler`, `ZGCodeInjectionWindowController` —— 单步、注入汇编（Keystone 编译）。
- 底层：`mach_exc/mach_exc*.c`（MIG 生成的 mach 异常 server）+ `CoreSymbolication` 私有 API。

### 5. 内存查看器
- `ZGMemoryViewerController` —— 附 HexFiend 的十六进制窗口。
- `ZGMemoryProtectionWindowController`, `ZGMemoryDumpAllWindowController`, `ZGMemoryDumpRangeWindowController`, `ZGMemoryDumpFunctions` —— 保护属性对话、dump 到磁盘。
- `ZGMemoryNavigationWindowController`, `ZGMemoryWindowController` —— 内存导航共基类。

### 6. 表达式 & 指针
- `ZGCalculator` + `ZGMemoryAddressExpressionParsing` —— 用 DDMathParser 求值地址表达式（含 `base + offset` 指针链）。

### 7. Python 脚本子系统
- `ZGScriptingInterpreter` —— 单例，进程内 Python 解释器生命周期。
- `ZGScriptManager` —— 追踪每个变量的脚本、编辑器（外部 `$EDITOR`）、执行。
- `ZGPyScript` —— 一个脚本的原生表示。
- `ZGPyMainModule`, `ZGPyVirtualMemory`, `ZGPyDebugger`, `ZGPyArchModule`, `ZGPyKeyCodeModule`, `ZGPyKeyModModule`, `ZGPyVMProtModule`, `ZGPyModuleAdditions` —— 暴露给 Python 的原生模块（`bitslicer.*`）。
- `ZGScriptPrompt(Delegate|WindowController)` —— 脚本触发的用户对话。
- `ZGScriptPreferencesViewController` —— 编辑器路径、缩进偏好。
- `pythonlib.h` —— 集中 `<Python.h>` include（依赖 `deps/python/Python.framework/Headers`）。

### 8. UI 底层
- `ZGAppController` —— `NSApplicationDelegate`，装配所有 controller（memory viewer / debugger / logger 单例，process task manager，脚本解释器，Sparkle updater）。
- `ZGHotKeyCenter` + `ZGHotKey` + ShortcutRecorder —— 全局暂停/恢复热键。
- `ZGDeliverUserNotifications` —— `UNUserNotificationCenter` 封装。
- `ZGAppUpdaterController` —— Sparkle 集成。
- 本地化：`Base.lproj/*.xib`（UI） + `{en,es,ru,zh}.lproj/Localizable.strings`（`zh.lproj` = 简中，见 `44c13e8d` commit）。加新字符串时同步全部 lproj。

## 常见改动的落脚点

- 新增数据类型 → `ZGDataValueExtracting.*` + `ZGVariableTypes.h` + `ZGSearchFunctions.mm`。
- 新增 Python 模块函数 → 找对应 `ZGPy*Module.m`，加 `PyMethodDef` 表项。
- 新增搜索选项 UI → `Search Options.xib` + `ZGDocumentOptionsViewController` + `ZGSearchData` 属性 + `ZGDocumentSearchController` 传参。
- 新断点/调试 UX → 起点是 `ZGDebuggerController` + `ZGBreakPointController`。
- 改本地化 → **不要只改 `zh.lproj`**，四种语言 + `Base.lproj` xib 都要跟上。

## 测试

XCTest。全部 test 只在 `Bit Slicer Tests/` 里，含随机 fixture 数据（`random_data/`）用于 byte-array 搜索。测试直连生产源（`Bit Slicer Tests-Prefix.pch` + Xcode 显式引用）而非 host app 注入。加新测试放同目录，加入 `Bit Slicer Tests` target 成员。

## 依赖工作流

依赖不用包管理器 —— 全部 vendored。升级路径：

1. 读 `deps/<lib>/source.txt`，按 `Config:` 章节说明操作（例如 capstone 需 macOS 15.6 target + `evm.h` 手动加入 Xcode 项目）。
2. 从上游拉源码，用 `source.txt` 记的 scheme/配置本地构建。
3. 把新生成的 `.framework`（含 `.dSYM`）或 `.dylib` 覆盖到 `deps/<lib>/`。
4. 更新 `source.txt` 的 URL/commit。

Python 3.14 framework 是完整嵌入版本，`Info.plist` + rpath 已配置从 app bundle 加载 → 别直接删 `deps/python/Python.framework/` 内文件。

## 语言 & 代码风格

Objective-C ARC（工程默认开启）+ nullability 标注（`_Nonnull`/`_Nullable`）。类命名前缀 `ZG`。搜索热路径用 C（`.c`）或 Obj-C++ 模板（`.mm`）避 Obj-C 派发开销。私有 API（`CoreSymbolication`）只在 Debugger/Backtrace 路径调用。修改现有文件跟已有风格（BSD 3-clause 版权头、tab 缩进、`#pragma mark`）。
