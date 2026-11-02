# NJUPT-net-KeepAlive

南京邮电大学（NJUPT）校园网 **后台保活 + 断网自动重连** 的轻量 PowerShell 方案。

面向的场景：Windows 常开、需要远程控制、每天晚上校园网会断、第二天早上恢复后需要重新认证。
脚本在后台静默运行，检测到没网就自动完成 Drcom Portal 认证。

> 只针对 NJUPT 的 Drcom 认证和 `NJUPT-CMCC` / `NJUPT-CHINANET` / `NJUPT` 三个 SSID。
> 其他学校请改 `PortalIP`、`SSID` 和认证参数。

## 特性

- **零额外依赖**：只用 Windows 自带的 PowerShell 5.1、`curl.exe` 和 `netsh`
- **占用小**：一个 PowerShell 进程常驻，内存约 30–50 MB
- **后台静默**：计划任务开机 / 登录自动启动，隐藏窗口
- **有线优先，断线切无线**：有线可用时认证有线；有线断开自动连校园 WiFi
- **NAT 感知**：自动从 Portal 页面读取服务器认定的客户端 IP，适配宿舍路由器 NAT
- **断网自愈**：60 秒检测一次，掉线自动重新认证
- **失败退避**：连续失败 3 次暂停 5 分钟，避免触发 Portal 的失败锁定
- **日志可查**：所有动作写入 `keepalive.log`，响应内容按 UTF-8 解码，中文不乱码

## 实测范围

已在南邮校园网实测通过：

- 有线 + `NJUPT-CMCC`（`@cmcc`）
- 无线 + `NJUPT-CMCC`（`@cmcc`）

以下按 Drcom 通用规则实现，但**未在真实账号上验证**：

- `@telecom`（电信）、`@unicom`（联通）、空后缀（通用）

如果你的运营商账号格式不同，改 `config.ps1` 的 `AccountSuffix` 即可，不需要动代码。

## 适用 / 不适用

适用：

- Windows 10/11，常开机器
- 校园网是 Drcom Web Portal 认证
- 有线 / 无线都需要自动重新认证
- 希望远程桌面、远程控制软件在断网后能自动恢复

不适用：

- 需要图形验证码 / 短信验证 / App 扫码的认证
- 802.1X 客户端认证
- Linux / macOS

## 工作原理

```
每 60 秒：
  ├─ 访问 msftconnecttest.com，内容必须等于 "Microsoft Connect Test"
  │    （被 Portal 劫持时内容不对，视为“没网”）
  ├─ 没网：
  │    ├─ 有线网卡 Up → 直接用有线认证
  │    └─ 有线断开   → netsh 连接校园 WiFi，再认证
  ├─ 认证前先 GET /a79.htm，解析 v46ip（服务器看到的客户端 IP）
  ├─ 用 curl 发认证请求（PowerShell 的 Invoke-WebRequest 处理不了 TLS 重协商）
  └─ 认证后 5 秒再探测一次，失败则退避
```

几个和 NJUPT 相关的关键点：

| 现象 | 原因 | 本项目的处理 |
|---|---|---|
| 未认证时域名解析失败 | DNS 被 Portal 阻断 | 认证地址用 IP `10.10.244.11` |
| `Invoke-WebRequest` 报“基础连接已关闭” | 服务器要求 TLS 重协商，.NET schannel 不支持 | 认证请求改用 `curl.exe` |
| 报“认证操作非本机终端” | 有线经路由器 NAT，本机私网 IP 与服务器看到的 IP 不一致 | 从 `a79.htm` 的 `v46ip` 取真实 IP |
| HTTPS 用 IP 访问证书不匹配 | 证书绑定域名 | `curl -k` 跳过校验 |

## 快速开始

### 1. 安装

右键 `install.bat` → **以管理员身份运行**，按提示：

1. 选择校园网：`1` = CMCC，`2` = CHINANET，`3` = NJUPT
2. 输入学号
3. 输入密码（不显示）
4. 自动生成 `config.ps1`、注册计划任务、后台启动

看到 `Done. Keepalive is running in background.` 即成功。

### 2. 验证

在项目目录运行：

```powershell
Get-Content .\keepalive.log -Tail 30
```

断网状态下应看到：

```
offline detected (wiredUp=True)
portal response: dr1003({"result":1,"msg":"Portal协议认证成功！"})
portal login attempted, ok=True, online=True
```

也可以手动跑单次调试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\portal.ps1 -Once -DebugMode
```

注意：`-Once` 在**在线状态**下会直接退出，只有断网/未认证时才会触发认证。

### 3. 卸载

右键 `uninstall.bat` → 以管理员身份运行。

## 配置项

`config.ps1` 由安装向导自动生成，也可以手动改：

| 键 | 说明 | 示例 |
|---|---|---|
| `Username` | 学号 | `your-student-id` |
| `Password` | 密码 | `your-password` |
| `AccountSuffix` | 运营商后缀 | `@cmcc` / `@telecom` / 空 |
| `SSID` | 校园 WiFi 名称 | `NJUPT-CMCC` |
| `WlanIface` | 无线网卡名 | `WLAN` |
| `PortalHost` | 认证页域名 | `p.njupt.edu.cn` |
| `PortalIP` | 认证服务器 IP（**关键**） | `10.10.244.11` |
| `PortalPort` | eportal 端口 | `804` |

`PortalIP` 可以通过在线时执行 `Resolve-DnsName p.njupt.edu.cn -Type A` 获取。

## 常见问题

**Q：认证返回“认证操作非本机终端”**
有线经过路由器 NAT 时，`wlan_user_ip` 必须填服务器看到的 IP。
脚本已自动从 `a79.htm` 的 `v46ip` 读取；如果该页面取不到，会退回本机 IP，可能失败。

**Q：日志里 `result:0`，msg 是密码错误**
检查 `config.ps1` 里的学号、密码、`AccountSuffix`。
可以先用浏览器登录 `https://p.njupt.edu.cn/a79.htm` 验证账号密码。

**Q：连上 WiFi 但流量还是走有线**
宿舍路由器有电但外网断了时，Windows 可能仍优先走有线。
可以把有线网卡 metric 调高，或临时禁用有线。

**Q：会不会违反学校规定**
自动登录等同于代替你本人操作登录页。请只用于自己的账号，并遵守学校网络管理规定。

**Q：密码安全吗**
密码只保存在本地 `config.ps1`，已在 `.gitignore` 中排除。
但 `curl` 命令行运行期间会短暂暴露含密码的 URL，单用户机器一般可接受。

## 目录结构

```
NJUPT-net-KeepAlive/
├── portal.ps1            # 主逻辑：探测、WiFi 切换、Portal 认证
├── config.example.ps1    # 配置模板
├── install.ps1           # 交互式安装 + 注册计划任务
├── install.bat           # 管理员一键安装
├── uninstall.bat         # 卸载计划任务
├── README.md
├── LICENSE
└── .gitignore
```

## 免责声明

本项目仅供学习与个人自用。使用者应自行承担以下风险：

- 自动化登录可能被视为违反学校网络使用规定
- Portal 接口变更导致脚本失效
- 账号因频繁失败重试被临时锁定

作者不对因使用本项目产生的任何后果负责。

## License

MIT