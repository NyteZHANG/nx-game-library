# NX 游戏库(nxnative 图形前端 + 启动器)

在 Mac 上打包并**原生**运行你自己拥有的 Nintendo Switch 游戏:这是 [nxnative](https://github.com/seedds/nxnative) 的图形前端与启动器。两个入口、一套逻辑:

- **原生 app**(`app/`,SwiftUI + SwiftPM,日常主入口):按 [DESIGN.md](DESIGN.md)(Apple 设计契约)打造的游戏库封面墙——导入 NSP、点 ▶ 一键构建(app 内实时进度,不打开浏览器)、建完自动开玩、时长统计、引擎在线更新。玩已构建的游戏不需要 Python。
- **网页控制台**(`server.py` + `static/`,调试/高级入口):纯 Python 标准库的本地构建后端,零 pip 依赖、只监听本机。**构建编排的唯一实现**——app 的一键构建就是隐式拉起它完成的;需要看完整流水线/原始日志时用 `./start.command` 打开。

> **仅用于你合法拥有的游戏备份。** 本仓库不包含任何游戏文件、密钥或任天堂版权内容,与 Nintendo 及任何游戏发行商均无关联。

> **维护者/接手请先读 [交接文档.md](交接文档.md)**——架构决策、启动契约、踩坑记录、红线与待办,一文全含。

## English summary

A macOS graphical frontend and launcher for [nxnative](https://github.com/seedds/nxnative), which runs your own legally-owned Nintendo Switch game backups natively (not emulated) on Apple silicon. The main entry is an Apple-style SwiftUI library app (`.app`): import your NSPs, press ▶ to build in-app with live progress (no browser), and it launches the game when done. A zero-dependency, localhost-only Python server (`server.py`) does the actual build orchestration and also serves a web console for debugging. It contains no game files, no keys, and is not affiliated with Nintendo.

## 架构

```
┌──────────────────┐     扫描/构建/启动      ┌──────────────────────┐
│  app/(SwiftUI)   │ ───────────────────────▶ │  nxnative(独立仓库) │
│  薄壳启动器       │   读 dm/、调构建脚本      │  构建器 + 游戏宿主    │
└──────────────────┘                          └──────────────────────┘
┌──────────────────┐     构建脚本/启动契约     ┌──────────────────────┐
│ server.py(控制台)│ ───────────────────────▶ │  你的游戏库(NSP/XCI)│
│  网页构建 + 启动  │                          │  prod.keys(自备)    │
└──────────────────┘                          └──────────────────────┘
```

- **app = 日常主入口**:扫描游戏库、定位构建产物、拉起游戏进程;**构建也在 app 内完成**——按 ▶ 遇到未构建的游戏会自动开建(隐式拉起本地 server,进度面板实时展示,建完自动启动)。Xcode/brew/Python 是构建期依赖,装不进 app。
- **server = 构建编排**:打包流水线 + 启动器的唯一实现,与 app 共享同一套扫描/配对着色器逻辑(契约以 `server.py` 为准);附带网页控制台作调试入口。
- **nxnative = 独立仓库,并排克隆**:本仓库不含 nxnative 任何代码;把它克隆到本仓库旁边,双方按同级目录自动互相定位(也可用环境变量/配置指定,见下)。

## 前置条件

- macOS(Apple silicon)+ [Xcode](https://apps.apple.com/app/xcode/id497799835)+ [Homebrew](https://brew.sh)
- Python **3.12+**(构建脚本用到嵌套引号 f-string;`start.command` 优先用仓库内 `.venv`)
- 把 nxnative 克隆到**本仓库旁边**(并排布局自动被识别):

  ```bash
  git clone https://github.com/seedds/nxnative.git
  git clone <本仓库地址>
  # 期望布局:
  #   某目录/
  #     nxnative/
  #     本仓库/
  ```

- 按 nxnative README 装一次构建依赖:

  ```bash
  brew install xcodegen zstd spirv-cross glslang
  brew install --cask dotnet-sdk
  python3 -m pip install lz4 capstone fonttools "backports.zstd; python_version < '3.14'"
  ```

- **自备** `prod.keys`(你自己的主机导出的密钥)与游戏备份(NSP/XCI,含更新/DLC)。**仅用于你合法拥有的游戏备份;不要提交进任何仓库。** `.gitignore` 已挡住 `*.keys / *.nsp / *.xci / *.ipa / 游戏库/`。

## 用法

### 一次性配置(首次)

1. 按上面「前置条件」装好依赖、克隆好 nxnative。
2. 运行 `./start.command` 打开网页控制台,在「设置」里填 **`prod.keys` 路径**与**游戏库目录**(或直接编辑 `config.json`,结构见 `config.example.json`)。这一步只需要做一次,之后 app 会自动读同一份配置。

### 原生 app(NX游戏库.app)——日常入口

**安装**:从 [Releases](../../releases) 下载 `NX游戏库.app.zip` 解压拖进「应用程序」;或从源码构建(需 Xcode):

```bash
cd app
bash make_app.sh --install   # 编译 + 直接覆盖安装到 /Applications(无权限时退到 ~/Applications)
```

> Release 的 app **未签名**:首次打开若被 Gatekeeper 拦,右键 → 打开,或执行 `xattr -cr /Applications/NX游戏库.app`。

日常操作全在 app 里,不需要再开网页:

- **导入**:把 NSP/XCI 直接拖进窗口,或点顶栏 ↓ 选择文件——自动解析、复制进游戏库、配对本体/更新/DLC。
- **构建 + 游玩**:点封面选中 → 按 ▶。未构建的游戏会**自动开始构建**(app 内进度面板:阶段/进度/剩余时间/日志尾行,可取消),建完**自动启动**;已构建的直接开玩。
- **进度面板的「日志」按钮**:打开完整构建日志(等价于以前的网页控制台)。
- **设置页**:路径与语言、**nxnative 引擎检查更新**(有新版一键拉取;更新后已构建的游戏需按 ▶ 重建,app 会自动提示)。
- **个人资料**:点头像自定义名字与头像;每张卡片显示该游戏的累计时长;亮暗外观随系统。
- Mac 宿主(dmhost)缺失或引擎更新后过期时,启动会自动重编(1-2 分钟)。

app CLI(脚本/验证用):

```
NXGameLibrary --list-games          # JSON 游戏列表
NXGameLibrary --launch <文件夹>     # 前台启动并等待退出
NXGameLibrary --stop                # 停止游戏
```

### 网页控制台(调试/高级)

```bash
./start.command          # 或: python3 server.py
```

浏览器自动打开 `http://127.0.0.1:8765`。日常玩 app 就够了;排查构建问题、看七阶段完整流水线时再用它。app 顶栏不再有跳转网页的入口(构建进度、日志都已在 app 内)。

命令行参数:`--port <端口>`(默认 8765)、`--no-open`。环境变量:

| 变量 | 作用 |
| --- | --- |
| `NXFE_REPO` | 覆盖 nxnative 仓库路径(优先于一切自动探测) |
| `NXFE_CONFIG` | 覆盖 `config.json` 路径(测试/多实例用) |
| `NXFE_PYTHON` | 指定构建用的 Python ≥3.12 |
| `PORT` | 等价 `--port` |

`config.json` 里也可加可选的 `"repo"` 键指定 nxnative 路径(缺键不影响;优先级低于 `NXFE_REPO`)。

### 路径自动探测

- `server.py` 找 nxnative:`NXFE_REPO` → `config.json` 的 `repo` 键 → 前端同级的 `../nxnative`。
- app 找仓库/前端:从可执行文件位置向上探测(nxnative 目录、含 `server.py` 的目录);装在 `/Applications` 时通常探测不到,留空后在设置页填即可。

## 安全说明

- 服务只监听 `127.0.0.1`,不对局域网/公网开放;前端无任何外部 CDN、无网络请求。
- 所有请求里的文件夹路径都会校验必须位于游戏库之下,防路径穿越;子进程一律用列表参数启动,不经 shell。
- 本仓库不包含、也永不要求你提交 `prod.keys` 或任何游戏文件。

## 测试

```bash
python3 test_smoke.py        # 冒烟测试:临时游戏库 + 假 NSP,无需 prod.keys/Xcode
cd app && swift build -c release
```

## 致谢

本项目是 [**nxnative**](https://github.com/seedds/nxnative)(MIT)的一个前端/启动器,不含 nxnative 本体代码。没有 nxnative 及其依赖就没有本项目,致谢它们的作者与贡献者:

- **[nxnative](https://github.com/seedds/nxnative)**(MIT)— 原生执行引擎;其自身的上游致谢见其 [README](https://github.com/seedds/nxnative#acknowledgements)(d2r-mobile、Ryujinx、Atmosphère、yuzu、LibHac、SPIRV-Cross、glslang、deko3d、libvpx、stb_vorbis、Capstone、lz4、fontTools、XcodeGen 等,各依其许可证)。

**本项目与 Nintendo 无任何关联,不含任何游戏文件或密钥。** Switch 是 Nintendo 的商标。

## License

[MIT](./LICENSE) © NX 游戏库 contributors。nxnative 及其依赖依各自的许可证,版权归原作者所有。
