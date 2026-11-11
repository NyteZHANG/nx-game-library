# NX 游戏库.app

nxnative 游戏的 Mac 原生启动器:双击打开 → 封面网格 → 点游戏 → 60fps 窗口。不启动服务器、不需要 Python、不用记网址。

## 安装

```
bash make_app.sh          # 编译并组装(首次几分钟)
open dist                  # 把「NX游戏库.app」拖进「应用程序」即安装
```

本地生成的 app 没有 quarantine 属性,双击直接运行,无需签名。

## 使用

- **玩**:双击卡片或点 ▶。首次对某游戏启动时若 Mac 宿主(dmhost)缺失会自动编译(1-2 分钟,进度看游戏目录下 `logs/dmhost_build.log`)
- **停止**:卡片上的「停止」按钮(优雅退出,5 秒未退强制结束)
- **构建新游戏**:工具栏「构建新游戏」——自动拉起网页前端并打开浏览器(127.0.0.1:8765),构建完成后回到 app 即可看到
- **设置**:游戏库路径 / 仓库路径 / 前端路径 / 游戏语言(下次启动生效,无需重建)。配置存于 `~/Library/Application Support/NXGameLibrary/config.json`,首次运行自动从网页前端的 config.json 继承游戏库与语言

## CLI(脚本/验证用)

```
NXGameLibrary --list-games          # JSON 游戏列表
NXGameLibrary --launch <文件夹>     # 前台启动并等待退出
NXGameLibrary --stop                # 停止游戏
```

二进制位置:`dist/NX游戏库.app/Contents/MacOS/NXGameLibrary`

## 已知边界

- 只管「玩」;构建永远走网页前端(工具链 Xcode/brew/Python 不可打包)
- 游戏数据不打进 app(4-22GB 资产留在游戏库),app 是薄壳,靠路径清单定位
- 启动契约与网页前端 `server.py` 保持一致(改一边记得同步另一边)
