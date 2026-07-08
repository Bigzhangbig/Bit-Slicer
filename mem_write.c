#include <stdio.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

int main(int argc, char *argv[]) {
    if (argc != 4) {
        printf("用法: %s <PID> <地址(hex)> <新值>\n", argv[0]);
        printf("示例: %s 72485 0xa9dd16f98 888\n", argv[0]);
        return 1;
    }

    pid_t pid = atoi(argv[1]);
    mach_vm_address_t address = strtoull(argv[2], NULL, 16);
    int32_t new_value = atoi(argv[3]);

    // 获取任务 port
    mach_port_t task;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "无法附加到进程 %d: %s\n", pid, mach_error_string(kr));
        return 1;
    }

    printf("已附加到进程 %d\n", pid);
    printf("目标地址: 0x%llx\n", address);
    printf("新值: %d\n", new_value);

    // 写入内存
    kr = mach_vm_write(task, address, (vm_offset_t)&new_value, sizeof(int32_t));
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "写入内存失败: %s\n", mach_error_string(kr));
        return 1;
    }

    // 验证写入
    int32_t verify_value;
    mach_vm_size_t bytes_read;
    kr = mach_vm_read_overwrite(task, address, sizeof(int32_t),
                               (mach_vm_address_t)&verify_value, &bytes_read);
    if (kr == KERN_SUCCESS && verify_value == new_value) {
        printf("\n✅ 写入成功！\n");
        printf("地址 0x%llx 的值已改为 %d\n", address, verify_value);
    } else {
        printf("\n⚠️  写入完成，但验证失败\n");
    }

    return 0;
}
