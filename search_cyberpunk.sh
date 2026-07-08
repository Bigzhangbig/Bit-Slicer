#!/bin/bash
# 搜索赛博朋克2077内存中的数值30

GAME_PID=$(pgrep -x Cyberpunk2077)
if [ -z "$GAME_PID" ]; then
    echo "错误: 赛博朋克2077未运行"
    exit 1
fi

echo "目标进程: Cyberpunk2077 (PID: $GAME_PID)"
echo "搜索值: 30"
echo "数据类型: int32"
echo ""

# 使用 lldb 附加到进程并搜索内存
# 注意：这需要 root 权限或开发工具权限

# 先获取内存区域信息
echo "获取内存区域信息..."
vmmap $GAME_PID 2>/dev/null | rg "MALLOC_SMALL|VM_ALLOCATE|__DATA" | head -20

echo ""
echo "注意: 直接内存搜索需要使用 Bit Slicer GUI 或 root 权限"
echo "建议: 在 Bit Slicer 中打开进程 $GAME_PID，搜索 int32 值 30"
