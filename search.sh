#!/bin/bash
# 快速内存搜索脚本
# 用法: ./search.sh <PID> <值> <类型>

if [ $# -ne 3 ]; then
    echo "用法: $0 <PID> <搜索值> <数据类型>"
    echo "示例: $0 65585 30 int32"
    echo "数据类型: int8, int16, int32, int64, float, double"
    exit 1
fi

PID=$1
VALUE=$2
TYPE=$3

echo "目标进程: $PID"
echo "搜索值: $VALUE"
echo "数据类型: $TYPE"
echo ""

# 编译并运行
if [ ! -f mem_search ]; then
    echo "编译搜索工具..."
    gcc -o mem_search mem_search.c
fi

sudo ./mem_search $PID $VALUE $TYPE
