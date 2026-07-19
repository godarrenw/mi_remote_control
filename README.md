# MiRemote — 小米蓝牙遥控器 → macOS 控制台

把小米蓝牙遥控器 2 Pro 变成 Mac 的万能遥控：按键映射（方向/OK/返回/主页/菜单/TV）、
长按/双击/层/手势、窗口切换、鼠标模式，以及**按住语音键直接对 Mac 说话打字**（配合豆包输入法）。

系统要求：macOS 14.0+，蓝牙。

---

## 一、首次打开（重要）

这个 app 没有经过 Apple 公证（个人小范围分发），第一次打开需要手动放行：

1. 解压 zip，把 `MiRemote.app` 拖到「应用程序」文件夹。
2. **右键（或按住 Control 点击）MiRemote.app → 打开 → 再点「打开」**。
   - 直接双击会提示"无法打开，因为无法验证开发者"，属正常，用右键打开即可。
   - 如果右键打开也被拦，去「系统设置 → 隐私与安全性」页面底部点「仍要打开」。
3. 之后就可以正常双击启动了。

## 二、权限授予（三步）

首次运行会引导你授权，也可以手动在「系统设置 → 隐私与安全性」里操作：

1. **蓝牙**：首次连接遥控器时系统自动弹窗，点「允许」。
2. **输入监控**：系统设置 → 隐私与安全性 → 输入监控 → 打开 MiRemote 开关。
3. **辅助功能**：系统设置 → 隐私与安全性 → 辅助功能 → 打开 MiRemote 开关。

改完权限如果没生效，退出 MiRemote 重新打开一次。

### 更新后通常无需重新授权

项目的正式分发包使用固定 `MiRemote Dev` 证书与固定 bundle id 签名，正常重编译和覆盖更新会保留
输入监控/辅助功能授权。只有证书、bundle id 或安装身份发生变化时，才需要删除旧条目并重新授权。

## 三、语音打字配置（豆包 + BlackHole）

按住遥控器的语音键对着遥控器说话，松开即出字。需要一次性配置：

1. 安装 [BlackHole 2ch 虚拟声卡](https://existential.audio/blackhole/)（免费，选 2ch 版本）。
   安装后如提示重启音频服务，允许即可，不用重启电脑。
2. 安装并启用 [豆包输入法](https://www.doubao.com/)，在其设置里把**麦克风选为 BlackHole 2ch**。
3. 切到豆包输入法，按住遥控器语音键说话 → 松开 → 文字出现。

说话时 MiRemote 会临时把系统默认麦克风切到 BlackHole，松开约 1 秒后自动还原。

## 四、故障排查

| 现象 | 处理 |
|---|---|
| 按键没反应 / 部分键失灵 | 多半是权限失效（尤其刚更新版本后）。去「隐私与安全性」把 MiRemote 从「输入监控」「辅助功能」里删掉重新添加，重启 app。 |
| 遥控器连不上 | 长按遥控器 **主页+返回 3 秒**至指示灯闪烁进入配对模式，在系统蓝牙里点连接。别同时运行官方「小米遥控器助手」（会抢设备）。 |
| 语音不出字 | 检查：① BlackHole 已安装（系统设置→声音里能看到 BlackHole 2ch）；② 豆包输入法麦克风选了 BlackHole 2ch；③ 当前输入法是豆包。 |
| **退出 MiRemote 后键盘/遥控器按键异常** | MiRemote 退出时会自动清理按键中转映射；若异常退出没清干净，终端执行 `hidutil property --get "UserKeyMapping"` 查看残留，执行 `hidutil property --set '{"UserKeyMapping":[]}'` 清空即可恢复。 |
| 权限明明开了还是不工作 | 终端执行 `tccutil reset Accessibility com.miremote.controller` 清掉旧记录，重新授权。 |

## 五、开发者：从源码构建分发包

```bash
./scripts/setup-signing.sh   # 一次性：创建 "MiRemote Dev" 自签证书（按提示完成两个手动步骤）
./scripts/package.sh         # 构建 + 组装 .app + 签名 + 打 zip（产物在 dist/）
./scripts/package-lint.sh    # 验证签名/DR/plist/zip 往返/两次构建 DR 一致性
```

必须先建证书——`package.sh` 在证书缺失时会硬失败，不会回退临时签名
（临时签名会导致每次重编译都丢 TCC 权限）。

常用开发命令：

```bash
./build.sh
.build/miremote --self-test
.build/miremote --ui-preview     # 只看 GUI，不启动蓝牙/HID 引擎
.build/miremote --doctor         # 一键体检并修复可自动处理的项目
```
