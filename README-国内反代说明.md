# Multi-EasyGost（国内反代版）

gost 一键安装管理脚本。原脚本里那个所谓阿里云 OSS 大陆镜像实测已 404 失效，本版改成自动测速的国内反代，并在下载失败时自动换镜像重试。

这个版本把项目里"从 GitHub 下载"的地址全部改成了可切换的国内反代，
反代的选择逻辑在同目录的 `ghcn.sh` 里。**请保留 ghcn.sh 与本项目在同目录**，
脚本会自动找到它；找不到时行为与原始版本一致（直连 GitHub）。

## 用法

```bash
chmod +x ghcn.sh
./ghcn.sh test      # 实测所有反代，自动选最快的并记住（首次约 10 秒）
./ghcn.sh list      # 看清单
./ghcn.sh use 3     # 手动固定用第 3 个
./ghcn.sh off       # 改回直连 GitHub
```

选好之后正常使用本项目即可，所有 GitHub 下载会自动走这个反代。

临时指定（不改配置）：

```bash
GHCN_PROXY=https://ghfast.top/ <正常命令>
```

完整说明、反代实测清单、以及"怎么上传到自己的 GitHub 仓库"请看完整包
`cn-github-pack.zip` 里的 README.md。

原项目版权归原作者所有，请保留项目内的 LICENSE。
