# 更新日志

本项目所有值得注意的变更都会记录在此文件。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

- 待补充。

## [0.1.0] — 2026-07-19

首个公开预览版：把小米蓝牙遥控器 2 Pro 变成 macOS 的全能控制台。

### 新增

- **语音输入**：按住语音键对遥控器说话，文字直接落进当前输入框。全链路走遥控器内置麦克风
  → ATVV 私有 GATT → IMA ADPCM 解码 → BlackHole 虚拟声卡 → 豆包输入法，自动完成。
- **13 键映射引擎**：每个物理键支持单击 / 长按 / 双击 / 层 / 手势（OK+方向）多种触发位，
  一颗遥控器压出数十个动作位；默认配置为「零同按组合」，单手拇指即可完成全部操作。
- **高级动作系统**：合成按键（含左右修饰键）、窗口切换、Ghostty / 浏览器标签跳转、
  自动聚焦输入框（三级兜底）、鼠标模式、宏与 shell 脚本。
- **App 控制模式**：TV 键进入 per-app 高级操作层并弹出 HUD 提示，方向 / OK / 返回 / 音量±
  在模式内执行当前 App 的专属动作。
- **AI 批准层**：终端 App 里 OK＝批准、返回＝拒绝、音量±＝切换 Agent、菜单＝Shift+Tab，
  为 AI Coding Agent 的确认流定制。
- **窗口选择器浮层**：菜单键弹出，左右选窗、上下扩范围（当前 App → 所有 App）。
- **批准提醒子系统**：Unix socket 事件链路 + Claude Code hooks 一键注入，Agent 需要确认时提醒。
- **预设库**：内置 Ghostty / 微信 / 浏览器 / 视频播放器等 profile，overlay 继承模型，
  支持一键导入与 JSON 导出分享。
- **SwiftUI 设置界面**：遥控器示意图 + 录制式绑定 + 语音页，不改 JSON 即可完成全部配置。
- **三步首启向导**：逐项引导蓝牙 / 输入监控 / 辅助功能授权。
- **健康自愈**：`--doctor` 一键体检并修复权限 / BlackHole / 残留映射等常见问题；
  单实例锁、残留 `hidutil` 映射自修复、健康状态机、开机自启。
- **逃生键**：长按菜单键 1.5 秒强制清空所有层、退出 App 控制模式并关闭全部浮层（硬编码兜底）。
- **打包与分发**：`build.sh`（swiftc 直编，只需 Command Line Tools）、固定自签证书、
  `.app` 组装、DMG / zip 打包与 `package-lint.sh` 校验。
- **CI/CD**：GitHub Actions 构建自检；打 `v*` tag 自动发布 Release（DMG + zip，ad-hoc 通道）。

### 已知限制

- App 未做 Apple 公证：首次打开需右键 → 打开，每次升级需重新授权一次（约 30 秒，配置不丢失）。
- 语音输入需另装 BlackHole 2ch 与豆包输入法。
- Secure Input（密码输入）期间方向键可能以中转键泄漏进前台，v1 接受此限制。

[未发布]: https://github.com/godarrenw/mi_remote_control/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/godarrenw/mi_remote_control/releases/tag/v0.1.0
