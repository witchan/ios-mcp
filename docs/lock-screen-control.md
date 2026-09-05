# 锁定画面保护开关

此 fork 基于 iOS MCP v1.2.4，新增可配置的锁定画面保护。原版会在设备锁定或熄屏时拦截点击、文字输入、Shell 及其他修改操作。

## 使用方式

安装包含此修改的软件包后，打开 iOS「设置」中的 iOS MCP，调整「锁定画面保护」：

- 开启：保持原版拦截行为。
- 关闭：MCP 可以在锁定或熄屏时执行原本受拦截的操作。

设置实时读取，可随时重新开启。此开关只控制 MCP 服务的拦截；iOS 密码和数据保护仍然有效。执行一般 App UI 操作前，仍需确认设备已唤醒并解锁。

## 配置与状态查询

Preference domain：`com.witchan.ios-mcp.preferences`。

Preference key：`lockScreenProtectionEnabled`，类型为 Boolean。未设置或类型不符时，保护保持开启。

调用 `get_screen_info` 可读取 `lock_screen_protection_enabled`：

```json
{
  "locked": true,
  "screen_on": true,
  "lock_screen_protection_enabled": false
}
```

`locked` 表示设备实际状态，与 MCP 保护开关是独立字段。示例仅显示相关字段。

## 验证范围

2026-09-05 已在 iPhone 15、iOS 17.2.1、rootless 环境安装并验证。构建采用 Theos 的 rootless 方案，`arm64`／`arm64e` CodeDirectory hashes 已核对；安装后的二进制文件与 DEB 中的文件一致。

- 设置页开关可实时回读开启／关闭状态，重启 SpringBoard 后仍保留配置。
- 保护关闭且设备锁定／熄屏时，Shell、root helper，以及已有临时文件的写入、回读和删除均通过。
- 唤醒并进入密码画面后，依次点击已确认的数字按键可以成功解锁。`input_text` 的成功响应不代表密码已输入，应以读取到 `locked=false` 为准。
- rootless 路径通过 Theos `rootless.h`／libroot 解析，避免仅使用 roothide stub 时找不到 Shell 或 helper。
- 软件包 metadata 应以 `root:wheel`（uid/gid 0）打包，`mcp-root` 必须是 `4755`；已安装的 helper 通过 `id` 验证可以取得 root。

本次沿用同版原始软件包中未修改的 helpers，仅重新编译 MCP 和设置页。尚未测试 rootful／roothide 变体、全部 MCP 工具，以及开启保护后再次锁屏的完整拦截流程。`write_file` 不会自动创建父目录。
