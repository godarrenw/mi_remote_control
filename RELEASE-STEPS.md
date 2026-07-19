# 发布操作卡

一页照做即可把 MiRemote 开源到 GitHub 并挂上 DMG。命令按顺序执行。

## 0. 一次性准备

```bash
gh auth login                    # 浏览器授权 GitHub CLI（选 SSH 或 HTTPS 均可）
./scripts/setup-signing.sh       # 创建固定签名证书 "MiRemote Dev"（按提示完成两个手动步骤）
```

## 1. 建仓并首次推送

```bash
cd /Users/<you>/Code/remote-controller
git add -A && git commit -m "chore: open-source release prep"   # 若主会话尚未提交

gh repo create miremote --public --source=. --push --description \
  "小米蓝牙遥控器 2 Pro → macOS 全能控制台：躺着指挥 AI 写代码"
```

推送前确认 `.gitignore` 已排除 `dist/`、`.build/`、`*.wav` 等（本仓已配好）。

## 2. 打包产物

```bash
./scripts/package.sh             # → dist/MiRemote.app + dist/MiRemote-<ver>.zip
./scripts/make-dmg.sh            # → dist/MiRemote-<ver>.dmg
./scripts/package-lint.sh        # 验签 / DR / plist / zip 往返 / DMG 挂载 / DR 一致性
```

`package-lint.sh` 全绿再往下走。

## 3. 发布 Release 并上传 DMG

```bash
VER="$(git describe --tags --always)"    # 或手动定 tag：VER=v0.1.0
git tag "$VER" && git push origin "$VER"

gh release create "$VER" \
  dist/MiRemote-*.dmg dist/MiRemote-*.zip \
  --title "MiRemote $VER" \
  --notes "首个公开预览版。安装说明见 README。语音需 BlackHole 2ch + 豆包输入法。"
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
