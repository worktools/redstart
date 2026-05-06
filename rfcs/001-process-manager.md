# RFC 001: Redstart Process Manager

## 概述

Redstart 是一个轻量级的本地进程管理命令行工具，专为 Web 应用开发场景设计。
它允许开发者通过语义化的接口管理多个持续运行的服务进程，并为 LLM Agents 提供
结构化的查询接口，避免依赖 `ps`、`grep` 等传统系统命令。

---

## 核心设计原则

1. **单文件状态** — 所有进程定义与运行状态均保存在 `redstart.json5`，极端情况下可直接阅读该文件了解系统状态。
2. **目录隔离日志** — 每个进程的 stdout/stderr 日志、PID 文件单独存放在 `.redstart-monitor/<alias>/` 目录中。
3. **幂等操作** — 重复执行 `start`、`stop` 等命令应安全无副作用。
4. **失败重试** — 启动失败时自动重试最多 3 次，每次间隔 1 秒。
5. **Native 优先** — 面向 MoonBit native 后端，通过 C FFI 调用 POSIX 系统接口。

---

## 目录结构

```
redstart.json5               # 进程定义 + 运行状态（不含日志）
.redstart-monitor/
  <alias>/
    stdout.log               # 标准输出日志（追加模式）
    stderr.log               # 标准错误日志（追加模式）
    pid                      # 当前 PID（运行时写入）
```

---

## 配置文件格式 (redstart.json5)

```json5
{
  version: "1",
  processes: [
    {
      id: "a1b2c3d4", // 8 位随机 ID
      alias: "web", // 人类可读别名，唯一
      command: "node server.js", // shell 命令字符串
      cwd: "/path/to/project", // 工作目录，null 表示当前目录
      env: {
        // 额外环境变量
        NODE_ENV: "development",
      },
      created_at: "1746576000", // Unix 时间戳字符串
      status: "running", // running | stopped | failed | unknown
      pid: 12345, // 运行时 PID，null 表示未运行
      started_at: "1746576060", // 最近一次启动时间
      stopped_at: null, // 最近一次停止时间
      exit_code: null, // 最近一次退出码
      retry_count: 0, // 当前重试次数
    },
  ],
}
```

---

## CLI 命令规范

### 进程定义管理

| 命令                                            | 描述                                |
| ----------------------------------------------- | ----------------------------------- |
| `redstart init`                                 | 在当前目录创建空的 `redstart.json5` |
| `redstart add <alias> <command...>`             | 添加进程定义                        |
| `redstart add <alias> <command...> --cwd <dir>` | 添加时指定工作目录                  |
| `redstart remove <id\|alias>`                   | 删除进程定义（需先停止）            |

### 进程生命周期

| 命令                           | 描述                                   |
| ------------------------------ | -------------------------------------- |
| `redstart start <id\|alias>`   | 启动进程（失败重试 3 次）              |
| `redstart start`               | 启动所有已停止的进程                   |
| `redstart stop <id\|alias>`    | 停止进程（先 SIGTERM，5 秒后 SIGKILL） |
| `redstart stop`                | 停止所有运行中的进程                   |
| `redstart restart <id\|alias>` | 重启进程                               |

### 状态查询

| 命令                                   | 描述                                  |
| -------------------------------------- | ------------------------------------- |
| `redstart list`                        | 列出所有进程及状态（表格格式）        |
| `redstart status`                      | 同 `list`                             |
| `redstart status <id\|alias>`          | 显示特定进程的详细状态                |
| `redstart logs <id\|alias>`            | 显示最近 50 行日志（stdout + stderr） |
| `redstart logs <id\|alias> --stdout`   | 仅显示 stdout                         |
| `redstart logs <id\|alias> --stderr`   | 仅显示 stderr                         |
| `redstart logs <id\|alias> -n <lines>` | 显示最近 N 行                         |

---

## 进程启动流程

```
start(alias)
  ├─ 检查 redstart.json5 中是否存在该进程定义
  ├─ 如果已在运行（PID 存在且进程存活），返回错误
  ├─ 创建 .redstart-monitor/<alias>/ 目录
  ├─ 循环重试（最多 3 次）:
  │    ├─ fork + exec /bin/sh -c <command>
  │    ├─ 重定向 stdout → .redstart-monitor/<alias>/stdout.log
  │    ├─ 重定向 stderr → .redstart-monitor/<alias>/stderr.log
  │    ├─ 等待 500ms 检查进程是否存活
  │    ├─ 如果存活：更新状态为 running，写入 PID 文件，返回成功
  │    └─ 如果失败：记录 retry_count，等待 1 秒后重试
  └─ 3 次均失败：更新状态为 failed
```

## 进程停止流程

```
stop(alias)
  ├─ 读取 PID
  ├─ 发送 SIGTERM
  ├─ 等待最多 5 秒，轮询检查进程是否退出
  ├─ 如果仍存活，发送 SIGKILL
  └─ 更新状态为 stopped，清除 PID
```

---

## 错误码

| 情况           | 输出                                                         |
| -------------- | ------------------------------------------------------------ |
| 找不到进程     | `error: process '<alias>' not found`                         |
| 进程已在运行   | `error: process '<alias>' is already running (pid: <n>)`     |
| 进程未在运行   | `error: process '<alias>' is not running`                    |
| 配置文件不存在 | `error: redstart.json5 not found, run 'redstart init' first` |
| 别名已存在     | `error: alias '<alias>' already exists`                      |

---

## 监控文件格式

### `.redstart-monitor/<alias>/pid`

```
12345
```

### `.redstart-monitor/<alias>/stdout.log`

追加模式，包含进程 stdout 输出。每次启动时追加（不清空），便于历史排查。

---

## 安全考虑

- 命令通过 `/bin/sh -c` 执行，继承父进程权限
- 不支持以 root 身份运行（无特权提升）
- 配置文件权限应为 `0600`（仅所有者读写）
- 日志目录权限应为 `0700`

---

## 未来扩展（Out of Scope for v0.1）

- 进程健康检查（HTTP ping 或自定义脚本）
- 日志轮转与大小限制
- 依赖排序（进程 A 等待进程 B 就绪后再启动）
- Windows 支持
- 远程监控 API
- 进程组管理
