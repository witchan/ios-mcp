# Postman Assets

Files:
- `ios-mcp.postman_collection.json`: collection with one dedicated request per ios-mcp tool, plus `Health`, `Initialize`, `Tools List`, and `Generic Tool Call`
- `ios-mcp.postman_environment.json`: environment variables for the device address, upload samples, and all sample arguments used by the collection
- `ios-mcp_runner_safe.json`: safe read-only runner data
- `ios-mcp_runner_all_examples.json`: full tool example data, including state-changing actions

Recommended usage:
1. Import the collection and environment into Postman.
2. Select the `ios-mcp Local` environment.
3. Start with `Health`, `Initialize`, and `Tools List`.
4. Click the dedicated tool request you want to test directly.
5. For computer-local file uploads, set `sample_upload_file_path` and `sample_upload_filename`, then send `File Transfer / upload_file`.
6. For IPA install, send `upload_file` first, then send `App Management / install_app` with the captured `uploaded_file_path`.
7. If needed, adjust the sample environment variables before sending requests.
8. Keep `Generic Tool Call` as a fallback for ad-hoc testing or newly added tools.

Notes:
- Most requests use shared sample variables such as `sample_x`, `sample_y`, `sample_bundle_id`, and `sample_text`.
- `tool_args_json` in `Generic Tool Call` must stay as raw JSON, not a quoted string.
- `upload_file` is a plain HTTP upload endpoint, not an MCP tool call. Its successful response contains only `path`, `filename`, and `size`; the collection test script stores those as `uploaded_file_path`, `uploaded_file_name`, and `uploaded_file_size`.
- `install_app` expects an IPA path that already exists on the device. Use `upload_file` first for a computer-local IPA.
- `screenshot` returns MCP image content, not text: `result.content[0].type` is `image`, `mimeType` is usually `image/jpeg`, and `data` contains the base64 JPEG payload.
- Some tools are stateful or disruptive, such as `press_power`, `kill_app`, `install_app`, `uninstall_app`, `open_url`, and text input tools.
- `long_press`, `double_tap`, and `drag_and_drop` call the same HID event path as tap/swipe and may change the foreground app state.
- If the device IP changes, update `baseUrl` in the environment before testing.
