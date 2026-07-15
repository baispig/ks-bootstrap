# KXSW Bootstrap

这是私有仓库 `baispig/ks` 的最小公开引导器。此仓库不包含 KXSW 完整源码、GitHub Token 或服务器信息。

## 安装稳定版

```bash
curl -fsSLO https://raw.githubusercontent.com/baispig/ks-bootstrap/v0.6.0/bootstrap.sh
curl -fsSLO https://raw.githubusercontent.com/baispig/ks-bootstrap/v0.6.0/SHA256SUMS
sha256sum -c SHA256SUMS
sudo bash bootstrap.sh
```

脚本会在当前终端明文读取并完整显示 Fine-grained Token。请勿在录屏、直播、屏幕共享或旁人可见的环境中输入。

Token 应只授权私有仓库 `baispig/ks`，权限为 `Contents: Read-only`。引导器不会把 Token 写入 Git URL、`.git/config` 或持久凭据文件；终端滚动记录和系统审计不受引导器控制。

开发测试可以明确使用私有仓库的 `main` 分支：

```bash
sudo bash bootstrap.sh --ref main
```
