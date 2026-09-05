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

2026-09-05 已在 iPhone 15、iOS 17.2.1、rootless 環境安裝並驗證。建置使用 Theos 的 rootless 方案，`arm64`／`arm64e` CodeDirectory hashes 已核對；安裝後的 binaries 亦與 DEB 一致。

- 設定頁開關可即時讀回開啟／關閉狀態，重啟 SpringBoard 後仍保留設定。
- 保護關閉且裝置鎖定／熄屏時，Shell、root helper，以及既有暫存檔案的寫入、讀回及刪除均通過。
- 喚醒並進入密碼畫面後，點按已觀測的數字鍵盤可成功解鎖。`input_text` 的成功回覆不代表密碼已輸入，應以 `locked=false` 讀回作準。
- rootless 路徑透過 Theos `rootless.h`／libroot 解析，避免僅使用 roothide stub 時找不到 Shell 或 helper。
- 套件 metadata 應以 `root:wheel`（uid/gid 0）封裝，`mcp-root` 必須是 `4755`；已安裝的 helper 以 `id` 驗證可取得 root。

本次沿用同版原始套件的未修改 helpers，只重新編譯 MCP 與設定頁。未測試 rootful／roothide 變種、全部 MCP 工具，以及開啟保護後再次鎖屏的完整攔截流程。`write_file` 不會自動建立父目錄。
