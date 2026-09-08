# CLAUDE.md — 开发与安全须知

## 项目结构
- `lib/` — Flutter 游戏主项目（拼图游戏核心逻辑与 UI）
- `studio/` — 素材处理工作室（图片切割、资源导出等工具）
- `scripts/` — 通用构建/部署/维护脚本（Python/Shell/Dart）
- `deploy/` — 部署相关脚本与配置
- `integration_test/` — 集成测试
- `test/` — 单元/Widget 测试
- `docs/` — 项目文档与变更日志
- `assets/` — 静态资源（图片、字体、音频）
- `data/` — 本地数据/配置文件
- `temp/` — 临时脚本和代码和数据
## 环境路径
- `PUB_CACHE`: Flutter|Dart包缓存路径看这里 `./dart_tool/package_config.json`
- 查找工具和开发环境和软件包用 Everything Cli工具 `es.exe` 直接搜索，禁止大范围find
- 如果要使用`python`可以用这里的 `C:\Home\Develop\venv` 可自由安装pip包

## 开发测试
- 代码格式：对有改动的代码运行 `dart format` ，禁止全仓库运行格式化工具
- 普通测试: 改代码后运行 `flutter analyze` 和 `flutter test` 测试通过
- 编译验证: 运行 `flutter build windows --debug` 验证编译无错误
- 运行验证：运行 `flutter test .\integration_test\app_test.dart -d windows` 无错误


## 注意事项
- 翻译语言资源只需要添加 `zh-CN` 和 `en-US` 就行
- 未经用户明确允许，禁止 `git commit` ，任何情况下都禁止 `git push`
- commit msg使用英文，commit可以用临时文件或改用 -m 多行参数
- 主项目代码变更的改动概要记入 `docs/CHANGES-YYYYMMDD.md` 顶部
- studio代码变更的改动概要记入 `studio/docs/CHANGES-YYYYMMDD.md` 顶部
- 禁止对 `markdown` 文档运行任何格式化工具
