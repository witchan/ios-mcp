# 鎖定畫面保護開關

此 fork 以 iOS MCP v1.2.4 為基礎，新增可設定的鎖定畫面保護。原版會在裝置鎖定或熄屏時攔截點擊、文字輸入、Shell 及其他修改操作。

## 使用方式

安裝包含此修改的套件後，開啟 iOS「設定」中的 iOS MCP，調整「鎖定畫面保護」：

- 開啟：維持原版攔截行為。
- 關閉：MCP 可以在鎖定或熄屏時執行原本受攔截的操作。

設定即時讀取，可隨時重新開啟。此開關只控制 MCP 服務的攔截；iOS 密碼及資料保護仍然有效。進行一般 App UI 操作前，仍需確認裝置已喚醒及解鎖。

## 設定與讀回

Preference domain：`com.witchan.ios-mcp.preferences`。

Preference key：`lockScreenProtectionEnabled`，型別為 Boolean。未設定或型別不符時，保護維持開啟。

呼叫 `get_screen_info` 可讀取 `lock_screen_protection_enabled`：

```json
{
  "locked": true,
  "screen_on": true,
  "lock_screen_protection_enabled": false
}
```

`locked` 表示實際裝置狀態，與 MCP 保護開關是獨立欄位。範例只顯示相關欄位。

## 驗證範圍

已通過 preference header 與 `MCPServer.m` 的 `clang -fsyntax-only`、設定 plist 語法及 Git whitespace 檢查。

尚未完成完整套件建置與真機安裝；Settings 開關、跨程序即時更新、密碼輸入及重新啟用攔截仍需真機驗證。關閉此開關不保證系統密碼輸入一定成功。
