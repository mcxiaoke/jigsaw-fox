# CLAUDE.md — 开发与安全须知

## 环境路径
- `PUB_CACHE`: Flutter|Dart包缓存路径看这里 `./dart_tool/package_config.json`
- 查找工具和开发环境和软件包用 Everything Cli工具 `es.exe` 直接搜索，禁止大范围find
- 如果要使用`python`可以用这里的 `C:\Home\Develop\venv` 可自由安装pip包

## 开发测试
- 普通测试: 改代码后运行 `flutter analyze` 和 `flutter test` 测试通过
- 编译验证: 运行 `flutter build windows --debug` 验证编译无错误


## 注意事项
- 翻译语言资源只需要添加 `zh-CN` 和 `en-US` 就行
- 未经用户明确允许，禁止 `git commit` ，任何情况下都禁止 `git push`
- commit msg使用英文，commit可以用临时文件或改用 -m 多行参数
- 关键代码变更的改动概要记入 `docs/CHANGES-YYYYMMDD.md` 顶部
