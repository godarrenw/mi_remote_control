# 发布操作卡

一页照做即可把 MiRemote 开源到 GitHub 并挂上 DMG。命令按顺序执行。

## 0. 一次性准备

```bash
gh auth login                    # 浏览器授权 GitHub CLI（选 SSH 或 HTTPS 均可）
./scripts/setup-signing.sh       # 创建固定签名证书 "MiRemote Dev"（按提示完成两个手动步骤）
```

## 1. 仓库元数据（一键设置 description / topics / homepage）

仓库已上线：https://github.com/godarrenw/mi_remote_control 。`gh auth login` 后跑一次即可
把描述、话题标签、主页补齐（GitHub 仓库右侧栏与搜索会用到）：

```bash
cd /Users/<you>/Code/remote-controller

gh repo edit godarrenw/mi_remote_control \
  --description "小米蓝牙遥控器 2 Pro → macOS 全能控制台：躺着指挥 AI 写代码" \
  --homepage "https://github.com/godarrenw/mi_remote_control#readme" \
  --add-topic macos \
  --add-topic swift \
  --add-topic remote-control \
  --add-topic xiaomi \
  --add-topic bluetooth \
  --add-topic voice-input \
  --add-topic ai \
  --add-topic claude-code \
  --add-topic accessibility \
  --add-topic hidutil \
  --enable-issues --enable-discussions
```

推送前确认 `.gitignore` 已排除 `dist/`、`.build/`、`*.wav` 等（本仓已配好）。

## 2. 打包产物

```bash
./scripts/package.sh             # → dist/MiRemote.app + dist/MiRemote-<ver>.zip
./scripts/make-dmg.sh            # → dist/MiRemote-<ver>.dmg
./scripts/package-lint.sh        # 验签 / DR / plist / zip 往返 / DMG 挂载 / DR 一致性
```

`package-lint.sh` 全绿再往下走。

## 3. 首个 Release（v0.1.0，Actions 自动出包）

推荐走 CI：打 `v0.1.0` tag 后 `.github/workflows/release.yml` 会自动构建、自检、组装
ad-hoc 签名的 DMG + zip 并创建 Release。无需本地打包。

```bash
# 确认工作区干净、自检全绿
./build.sh && .build/miremote --self-test

git tag v0.1.0 && git push origin v0.1.0     # 触发 Actions → 自动出 DMG Release
```

去 Actions 页看 Release 工作流跑完，产物会自动挂到
https://github.com/godarrenw/mi_remote_control/releases/tag/v0.1.0 。
随后编辑该 Release，把下面的 notes 模板贴进去（CHANGELOG.md 的 v0.1.0 段可直接复用）。

<details>
<summary>v0.1.0 Release notes 模板（亮点 / 安装 / 已知限制三段）</summary>

```markdown
## ✨ 亮点

首个公开预览版：把小米蓝牙遥控器 2 Pro 变成 macOS 的全能控制台。

- 语音输入：按住语音键说话，文字直接落进当前输入框（ATVV → ADPCM → BlackHole → 豆包）
- 13 键映射引擎：单击 / 长按 / 双击 / 层 / 手势，默认零同按组合，单手拇指全操作
- App 控制模式 + AI 批准层：终端里 OK 批准、返回拒绝，为 AI Coding Agent 定制
- 窗口选择器、鼠标模式、宏 / shell、预设库、SwiftUI 设置界面、三步向导、`--doctor` 自愈

## 📦 安装

1. 下载 `MiRemote-0.1.0.dmg`，打开后把 MiRemote.app 拖进「应用程序」
2. **首次打开右键 → 打开**（未做 Apple 公证，属正常）
3. 按向导授予蓝牙 / 输入监控 / 辅助功能三项权限
4. 语音打字额外需装 [BlackHole 2ch](https://existential.audio/blackhole/) 与豆包输入法

详见 [README](https://github.com/godarrenw/mi_remote_control#readme)。

## ⚠️ 已知限制

- 未公证：每次升级新版本需重新授权一次（约 30 秒，配置不丢失）
- Secure Input（密码输入）期间方向键可能以中转键泄漏进前台，v1 接受此限制
```

</details>

若要本地手动出包（无 Actions 时的兜底）：

```bash
VER=v0.1.0
git tag "$VER" && git push origin "$VER"
./scripts/package.sh && ./scripts/make-dmg.sh && ./scripts/package-lint.sh
gh release create "$VER" dist/MiRemote-*.dmg dist/MiRemote-*.zip \
  --title "MiRemote $VER" --notes-file RELEASE_NOTES.md
```

## 4. 后续每次发版

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
./scripts/package.sh && ./scripts/make-dmg.sh && ./scripts/package-lint.sh
gh release create vX.Y.Z dist/MiRemote-*.dmg dist/MiRemote-*.zip \
  --title "MiRemote vX.Y.Z" --notes-file RELEASE_NOTES.md
```

## 备注

- 没有 Apple 开发者账号时分发的是**自签名**包，用户首次打开要右键 → 打开（README 已写清）。
  将来买了账号做公证，签名脚本无需改动。
- 想在 README 里换掉 badge 上的仓库名，改 `README.md` 顶部 shields.io 链接即可。
- `make-dmg.sh --unsigned` 只用于本机预览验证，**不要**上传到 Release。
