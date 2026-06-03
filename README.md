# claude-termux

在 Termux 里安装并运行 Claude Code 的脚本。

## 一键安装

```sh
curl -fsSL https://raw.githubusercontent.com/androidly/claude-termux/main/install.sh | bash
```

## 说明

- 适用于 Android Termux 环境。
- 脚本会安装 `glibc-runner`、`nodejs-lts`，再安装 Claude Code 并写入 Termux 启动包装。
- 默认安装最新版；如果要指定版本，可以先设置环境变量：

```sh
CLAUDE_CODE_VERSION=latest curl -fsSL https://raw.githubusercontent.com/androidly/claude-termux/main/install.sh | bash
```

## 手动运行

```sh
bash install.sh
```
