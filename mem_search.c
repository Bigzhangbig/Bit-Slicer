#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

#define INITIAL_CAPACITY 1000000
#define ADDRESS_FILE "/tmp/mem_search_addresses.txt"

// 保存搜索结果的地址（动态分配）
static mach_vm_address_t *saved_addresses = NULL;
static int saved_count = 0;
static int saved_capacity = 0;

// 初始化地址数组
void init_addresses() {
    if (saved_addresses == NULL) {
        saved_capacity = INITIAL_CAPACITY;
        saved_addresses = malloc(saved_capacity * sizeof(mach_vm_address_t));
        if (saved_addresses == NULL) {
            fprintf(stderr, "内存分配失败\n");
            exit(1);
        }
    }
}

// 扩展地址数组
void expand_addresses() {
    int new_capacity = saved_capacity * 2;
    mach_vm_address_t *new_addresses = realloc(saved_addresses, new_capacity * sizeof(mach_vm_address_t));
    if (new_addresses == NULL) {
        fprintf(stderr, "内存扩展失败\n");
        exit(1);
    }
    saved_addresses = new_addresses;
    saved_capacity = new_capacity;
}

// 添加地址
void add_address(mach_vm_address_t addr) {
    if (saved_count >= saved_capacity) {
        expand_addresses();
    }
    saved_addresses[saved_count++] = addr;
}

// 从文件加载地址
void load_addresses() {
    init_addresses();
    FILE *f = fopen(ADDRESS_FILE, "r");
    if (f) {
        saved_count = 0;
        mach_vm_address_t addr;
        while (fscanf(f, "%llx", &addr) == 1) {
            add_address(addr);
        }
        fclose(f);
        printf("从文件加载了 %d 个地址\n", saved_count);
    }
}

// 保存地址到文件
void save_addresses() {
    FILE *f = fopen(ADDRESS_FILE, "w");
    if (f) {
        for (int i = 0; i < saved_count; i++) {
            fprintf(f, "%llx\n", saved_addresses[i]);
        }
        fclose(f);
        printf("保存了 %d 个地址到文件\n", saved_count);
    } else {
        fprintf(stderr, "无法创建地址文件\n");
    }
}

// 搜索指定进程内存中的值
int main(int argc, char *argv[]) {
    if (argc < 4) {
        printf("用法: %s <PID> <搜索值> <数据类型> [命令]\n", argv[0]);
        printf("命令:\n");
        printf("  search  - 搜索并保存地址（第一次搜索）\n");
        printf("  filter  - 从已保存的地址中筛选（后续搜索）\n");
        printf("  list    - 列出已保存的地址\n");
        printf("  clear   - 清空已保存的地址\n");
        printf("示例:\n");
        printf("  %s 65585 15 int32 search    # 第一次搜索\n", argv[0]);
        printf("  %s 65585 21 int32 filter    # 第二次搜索（筛选）\n", argv[0]);
        printf("  %s 65585 26 int32 filter    # 第三次搜索（筛选）\n", argv[0]);
        return 1;
    }

    pid_t pid = atoi(argv[1]);
    int32_t search_value = atoi(argv[2]);
    const char *data_type = argv[3];
    const char *command = (argc > 4) ? argv[4] : "search";

    // 获取任务 port
    mach_port_t task;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "无法附加到进程 %d: %s\n", pid, mach_error_string(kr));
        return 1;
    }

    printf("已附加到进程 %d\n", pid);
    printf("搜索值: %d\n", search_value);
    printf("数据类型: %s\n", data_type);
    printf("命令: %s\n\n", command);

    // 处理 list 命令
    if (strcmp(command, "list") == 0) {
        load_addresses();
        if (saved_count == 0) {
            printf("没有已保存的地址\n");
        } else {
            printf("已保存的地址 (%d 个):\n", saved_count);
            for (int i = 0; i < saved_count && i < 100; i++) {
                printf("  %d. 0x%llx\n", i + 1, saved_addresses[i]);
            }
            if (saved_count > 100) {
                printf("  ... 还有 %d 个地址\n", saved_count - 100);
            }
        }
        return 0;
    }

    // 处理 clear 命令
    if (strcmp(command, "clear") == 0) {
        if (saved_addresses) {
            free(saved_addresses);
            saved_addresses = NULL;
        }
        saved_count = 0;
        saved_capacity = 0;
        remove(ADDRESS_FILE);
        printf("已清空所有保存的地址\n");
        return 0;
    }

    // 如果是 filter 模式，先加载地址
    if (strcmp(command, "filter") == 0) {
        load_addresses();
    }

    int found_count = 0;
    int scanned_regions = 0;
    unsigned long long total_scanned = 0;

    printf("开始搜索...\n");

    if (strcmp(command, "filter") == 0 && saved_count > 0) {
        // 筛选模式：只检查已保存的地址
        printf("从 %d 个已保存的地址中筛选...\n", saved_count);

        int new_count = 0;
        mach_vm_address_t *new_addresses = malloc(saved_count * sizeof(mach_vm_address_t));
        if (new_addresses == NULL) {
            fprintf(stderr, "内存分配失败\n");
            return 1;
        }

        for (int i = 0; i < saved_count; i++) {
            mach_vm_address_t addr = saved_addresses[i];
            int32_t value;
            mach_vm_size_t bytes_read;

            kr = mach_vm_read_overwrite(task, addr, sizeof(int32_t),
                                       (mach_vm_address_t)&value, &bytes_read);
            if (kr == KERN_SUCCESS && bytes_read == sizeof(int32_t)) {
                if (value == search_value) {
                    printf("匹配: 地址 0x%llx = %d\n", addr, value);
                    new_addresses[new_count++] = addr;
                    found_count++;
                }
            }
        }

        // 更新保存的地址列表
        free(saved_addresses);
        saved_addresses = new_addresses;
        saved_count = new_count;
        saved_capacity = new_count;

    } else {
        // 搜索模式：遍历所有内存区域
        init_addresses();
        mach_vm_address_t address = 0;
        mach_vm_size_t size;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object_name;

        while (1) {
            kr = mach_vm_region(task, &address, &size, VM_REGION_BASIC_INFO_64,
                               (vm_region_info_t)&info, &info_count, &object_name);
            if (kr != KERN_SUCCESS) break;

            // 只搜索可读且可写的区域
            if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE)) {
                // 跳过小区域（< 4KB）
                if (size < 4096) {
                    address += size;
                    continue;
                }

                // 通过地址范围判断是否为游戏数据区域
                mach_vm_address_t end_addr = address + size;

                // 跳过游戏主程序的 __TEXT 段（0x1029c0000 - 0x1097a4000）
                if (address >= 0x1029c0000 && end_addr <= 0x1097a4000) {
                    address += size;
                    continue;
                }

                // 不跳过任何区域，搜索所有可读写区域

                scanned_regions++;
                total_scanned += size;

                void *buffer = malloc(size);
                if (buffer) {
                    mach_vm_size_t bytes_read;
                    kr = mach_vm_read_overwrite(task, address, size, (mach_vm_address_t)buffer, &bytes_read);
                    if (kr == KERN_SUCCESS) {
                        for (mach_vm_size_t i = 0; i <= bytes_read - 4; i++) {
                            int32_t *ptr = (int32_t *)((char *)buffer + i);
                            if (*ptr == search_value) {
                                mach_vm_address_t found_addr = address + i;

                                // 保存地址
                                add_address(found_addr);
                                found_count++;

                                // 只输出前50个地址
                                if (found_count <= 50) {
                                    printf("找到: 地址 0x%llx = %d\n", found_addr, search_value);
                                } else if (found_count == 51) {
                                    printf("... 继续搜索中，不再输出更多地址 ...\n");
                                }
                            }
                        }
                    }
                    free(buffer);
                }
            }

            address += size;
        }
    }

done:
    // 保存地址到文件
    save_addresses();

    printf("\n搜索完成\n");
    printf("扫描区域: %d\n", scanned_regions);
    printf("扫描内存: %.2f MB\n", total_scanned / 1024.0 / 1024.0);
    printf("本次找到: %d\n", found_count);
    printf("已保存地址: %d\n", saved_count);

    // 释放内存
    if (saved_addresses) {
        free(saved_addresses);
        saved_addresses = NULL;
    }

    return 0;
}
