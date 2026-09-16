# 收藏文件夹与导入导出

## 使用

资料库 → 收藏 → 右上角 `…`：新建文件夹、导入、导出（全部收藏）。

- 导入 Chrome、Edge 等浏览器导出的书签 HTML；在系统文件选择器选择 `.html` / `.htm` 文件。
- 导入到当前文件夹，保留嵌套目录、空目录、名称、URL 和收藏时间（HTML 为秒精度）。同位置同名文件夹合并，同文件夹同 URL 跳过；相同 URL 可以存在于不同文件夹。
- 完成后显示新增收藏、文件夹、重复及不支持链接数量。读取/解析失败不会留下部分数据，持久化失败回滚本次导入。
- 导出全部收藏为 UTF-8 Netscape Bookmark HTML，可保存到系统文件并在浏览器中导入。
- 文件夹长按可重命名、移动、删除；收藏长按或左滑可移动。禁止把文件夹移动到自身或后代。
- 删除文件夹只删除容器：收藏和子目录移到上一级。设置中清除全部收藏则同时清除文件夹。
- 旧收藏通过可选 `folderID` 轻量迁移，默认在收藏根目录；保留 ID、日期、平台和 favicon。

## 边界

- 导入最多 20 MB / 50,000 条记录 / 64 层。解析在后台，不渲染 HTML、不执行脚本、不加载 ICON 等资源。
- 接受 HTTP、HTTPS、FTP 链接；脚本书签、浏览器内部 URL 和本机 file URL 计入不支持链接。非 HTML 的浏览器内部数据库、账号云同步不在此功能范围。
- 浏览器导出的 HTML 常用 UTF-8，兼容 BOM UTF-16、Windows-1252；处理标准导出的实体、数字实体、大小写和单双引号属性。
- 收藏和文件夹仍为本机数据，沿用现有收藏的设置云同步排除规则。

格式参考：[Chrome 官方导入导出说明](https://support.google.com/chrome/answer/96816?hl=en-GB)、[Edge 官方导入说明](https://support.microsoft.com/en-us/edge/import-your-favorites-and-passwords-in-microsoft-edge)。

## 验证

`BookmarkImportExportTests` 8 项通过：嵌套 Chrome/Edge 数据、UTF-16、实体、空目录、危险/无效输入、超限、导出再导入、去重、指定目录、删除容器保留内容，真实磁盘旧 Schema 的数据迁移，以及深层/失去父目录引用时导出不丢失内容。

- `/tmp/soulo-bookmarks-regression.xcresult`：新增 8 项全部通过；全量 374 项中 373 项通过，已有 `WebMediaPlaybackBridgeTests.testRealVideoTimelineAdvancesFasterAtTwoTimes` 在 2x 播放阶段进度暂时停滞，失败一次。
- `/tmp/soulo-bookmarks-media-recheck.xcresult`：单独复测该媒体测试类 7 项全部通过，实测 1x 前进 1.03 秒、2x 前进 1.95 秒。未改动媒体实现或放宽断言；保留全量首次失败记录。
- `/tmp/soulo-bookmarks-ui2.xcresult` 中 `testImportMoveAndDuplicateHandling`：实际系统选择器导入、重复导入、嵌套目录、移动收藏通过。
- `/tmp/soulo-bookmarks-ui4.xcresult`：新建/嵌套/重命名文件夹、系统文件保存导出、删除容器保留内容通过。导出的 HTML 实际检查具有 Netscape 声明、目录和链接。
- UI 重试原因：系统保存弹窗不总有可访问的“取消”按钮，改为真实保存；长按步骤改为左滑以等待列表更新；测试运行器出现旧步骤日志后仅重装 QA Runner。未删除 Soulo 数据，也未用降低产品测试断言的方式规避问题。
- `python3 scripts/check_localization.py --strict`：862 keys × 50 locales，通过。
- `python3 scripts/export_metadata_json.py --check`：50 locales，通过；版本未修改。
- 公共夹具 `docs/qa/fixtures/chromium-bookmarks.html`；仅包含 example.com/example.org 测试链接。

- `/tmp/soulo-bookmarks-cleanup-ui.xcresult`：通过 UI 清理本次创建的测试收藏和目录；临时导入/导出文件也已移除，保留原有用户数据。
