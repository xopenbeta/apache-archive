# apache-archive

为 macOS / Linux / Windows 预编译的 Apache HTTP Server（httpd）二进制包，支持 x86_64 与 arm64（Windows 仅 x86_64）。

## 触发构建

```bash
git tag v202610312330
git push
git push origin v202610312330
```

构建完成后，GitHub Release 页面会自动发布全部支持平台与架构的二进制包及 SHA256 校验文件。

也可以在 Actions 页面手动触发 `workflow_dispatch`：只构建并上传 artifact，不会创建 Release。

## 支持版本

| 系列 | 最新版本 | 类型 |
|------|---------|------|
| 2.4 | 2.4.69 | GA（当前唯一受支持分支） |

## 构建环境

| 平台 | 架构 | Runner |
|------|------|--------|
| macOS | arm64 (Apple Silicon) | `macos-15` |
| macOS | x86_64 (Intel) | `macos-15-intel` |
| Linux | x86_64 | `ubuntu-22.04` |
| Linux | arm64 | `ubuntu-22.04-arm` |
| Windows | x86_64 | `windows-2022` + MSVC 2022 |

说明：

- macOS 产物最低支持 macOS 12.0。
- Linux 产物在 Ubuntu 22.04 上构建，要求 glibc 2.35 或更高版本。
- Windows 只提供 x86_64：httpd 的官方 Windows 构建仅支持 MSVC，没有可用的 arm64 构建路径。

## 构建配置

| 组件 | 版本 | 说明 |
|------|------|------|
| httpd | 2.4.69 | 从 [dlcdn.apache.org](https://dlcdn.apache.org/httpd/) 下载 |
| APR / APR-util | 1.7.6 / 1.6.5 | 从 [dlcdn.apache.org](https://dlcdn.apache.org/apr/) 下载 |
| OpenSSL | 3.5.9 (LTS) | 静态链接（macOS/Linux） |
| PCRE2 | 10.48 | 8-bit + Unicode |
| zlib | 1.3.1 | 静态链接 |
| Expat | 2.9.0 | 静态链接，供 APR-util / mod_dav 使用 |
| nghttp2 | 1.70.0 | 静态链接（macOS/Linux），用于 mod_http2 |

- **MPM**: `event`
- **模块**: `most` + `ssl` + `http2` + `proxy_http2`
- **默认端口**: HTTP `8080`（非 root 可直接启动），HTTPS 配置中的默认端口为 `443`
- **macOS / Linux**: 所有依赖源码编译、静态链接，产物不依赖 Homebrew 或发行版软件包；模块全部编译进 `bin/httpd`，不支持第三方 DSO 模块
- **Windows**: 采用 MSVC + CMake 构建，模块为 `modules/*.so`，依赖 DLL 与 VC 运行时随包放入 `bin/`
- **打包格式**: macOS / Linux 为 `.tar.gz`，Windows 为 `.zip`

启用的模块包括：`ssl`、`http2`、`proxy`、`proxy_http`、`proxy_fcgi`、`proxy_connect`、`proxy_wstunnel`、`rewrite`、`headers`、`deflate`、`expires`、`cache`、`dav`、`cgi`、`autoindex`、`status`、`authn_*`、`authz_*`、`mime`、`log_config` 等常用模块。

## 使用方法

从 [Releases](../../releases) 页面下载对应平台和架构的压缩包。

### macOS / Linux

```bash
# 解压
tar xzf httpd-2.4.69-macos-arm64.tar.gz
cd httpd-2.4.69-macos-arm64

# 测试配置
./bin/apachectl -t

# 启动服务（默认监听 8080）
./bin/apachectl -k start
curl http://127.0.0.1:8080/

# 停止服务
./bin/apachectl -k stop

# 重启 / 平滑重载配置
./bin/apachectl -k restart
./bin/apachectl -k graceful
```

### Windows

```powershell
# 解压
Expand-Archive httpd-2.4.69-windows-x86_64.zip -DestinationPath .
cd httpd-2.4.69-windows-x86_64

# 测试配置
.\bin\apachectl.cmd -t

# 前台运行（Ctrl+C 停止）
.\bin\apachectl.cmd
```

Windows 版以控制台方式运行；如需注册为服务，请先把压缩包解压到固定路径，并在 `conf\httpd.conf` 中把 `ServerRoot` 改为该路径（服务启动时不经过 `apachectl.cmd` 计算路径）。

### 自定义配置

- 主配置：`conf/httpd.conf`
- 站点根目录：`htdocs/`
- 访问日志与错误日志：`logs/`
- 修改监听端口：编辑 `conf/httpd.conf` 中的 `Listen 8080`

`bin/apachectl`（Windows 为 `bin\apachectl.cmd`）会在启动时把 `ServerRoot` 设置为压缩包所在目录，因此整个目录可以解压到任意位置。若直接运行 `bin/httpd`，需要自行传入：

```bash
./bin/httpd -d "$(pwd)" -C "Define SRVROOT \"$(pwd)\"" -f conf/httpd.conf
```

## 校验文件完整性

每个压缩包附带 SHA256 校验文件：

```bash
# macOS / Linux
shasum -a 256 -c httpd-2.4.69-macos-arm64.tar.gz.sha256
sha256sum -c httpd-2.4.69-linux-x86_64.tar.gz.sha256

# Windows (PowerShell)
(Get-FileHash httpd-2.4.69-windows-x86_64.zip -Algorithm SHA256).Hash
Get-Content httpd-2.4.69-windows-x86_64.zip.sha256
```

## 许可证

本仓库的构建脚本使用仓库根目录的 `LICENSE`。每个压缩包内的 `licenses/` 目录包含 httpd、APR、APR-util、OpenSSL、PCRE2、zlib、Expat、nghttp2 的许可证与 NOTICE 文件。

## 已知限制

- macOS / Linux 产物为静态模块构建，不支持通过 `LoadModule` 加载第三方 DSO 模块；需要 PHP 时建议使用 `mod_proxy_fcgi` + PHP-FPM。
- 不启用 `mod_md`、`mod_lua`、`mod_brotli`、`mod_ldap` 等需要额外依赖的模块。
- Windows 产物使用 DSO 模块，`mod_dav` 等模块是否包含取决于 Expat/APR-util 的构建结果；可通过 `bin\apachectl.cmd -M` 查看。
- 默认端口为 8080；如需 80 端口，请修改 `conf/httpd.conf` 并以具备绑定权限的用户启动。
