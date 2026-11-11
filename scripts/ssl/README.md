# SSL 证书批量自动签发 / 续期（Let's Encrypt + DNS-01）

用 **DNS-01 验证**给域名签发 Let's Encrypt 证书，**每个域名一张独立证书、各自管理到期时间**，
到期前自动续期、并在证书真的换新之后重启你的服务（Traefik / nginx）。

**只有一套代码**（就是本目录）。Traefik 机器和 nginx 机器的差别只有三项，
全部落在配置文件里，不靠维护两份脚本：

| 差异项 | Traefik 机器 | nginx 机器 | 写在哪 |
|---|---|---|---|
| 证书输出目录 | `/root/cert` | `/etc/nginx/ssl` | `ssl.conf` → `SSL_OUTPUT_DIR` |
| systemd unit 名 | `ssl-renew` | `ssl-nginx-renew` | `ssl.conf` → `SSL_UNIT_NAME` |
| 续期后置动作 | `renewpost.sh.example.docker` | `renewpost.sh.example.nginx` | 复制成 `renewpost.sh` |

- 支持泛域名（`*.example.com`）
- **支持多个 DNS 服务商**：腾讯云 DNSPod、GoDaddy，可混在一份列表里（见第五节）
- **支持每个服务商下多个账号**：域名分散在不同账号下，一次跑完（见第六节）
- **证书更新后自动重启服务**：`renewpost.sh` 里写你要做的事（见第九节）
- **每次运行留一行结果日志**，一眼看出续没续成（见第九节第 4 小节）
- 不需要 80 端口对外、不需要服务器上有 Web 服务
- 全程只用系统自带的 `bash / curl / openssl / tar`，**不装任何 rpm 包**
- 密钥、域名列表、策略、后置动作分四个文件存放，互不干扰

---

## 〇、一套代码，两种消费方（先读这一节）

以前是 `scripts/ssl/`（Traefik 版）和 `scripts/ssl-nginx/`（nginx 版）**两份目录**，
代码 99% 相同，只是三处不同。两份并排维护的代价是每次改逻辑都要改两遍、
并且**复制目录时一定会漏改某处**（真漏过：`ssl-status.sh` 里写死的 unit 名没跟着改，
状态检查一直去查另一套的 unit，报「未安装」，白误导了一轮排查）。

现在收敛成一套：**代码只此一份，差异全部外置成配置**。

```
                          ┌──────────────────────────────┐
                          │  scripts/ssl/  （唯一代码）  │
                          │  lib.sh / ssl-issue.sh / ... │
                          └───────────────┬──────────────┘
                                          │  读 ssl.conf
                        ┌─────────────────┴─────────────────┐
                        ▼                                   ▼
          SSL_OUTPUT_DIR=/root/cert            SSL_OUTPUT_DIR=/etc/nginx/ssl
          SSL_UNIT_NAME=ssl-renew              SSL_UNIT_NAME=ssl-nginx-renew
          renewpost.sh ← .example.docker       renewpost.sh ← .example.nginx
                        │                                   │
                        ▼                                   ▼
                 Traefik 机器 (docker)                nginx 机器 (systemd)
```

### 部署到第二台机器时，只需要改三行

```bash
# 1) ssl.conf
SSL_OUTPUT_DIR="/etc/nginx/ssl"      # 证书落到哪
SSL_UNIT_NAME="ssl-nginx-renew"      # systemd unit 名（同机装两套时**必须**不同）

# 2) 复制对应的钩子模板
cp renewpost.sh.example.nginx renewpost.sh && chmod +x renewpost.sh
```

其余 `lib.sh` / `ssl-issue.sh` / `ssl-status.sh` / `ssl-setup.sh` / `ssl-repair.sh`
**两台机器完全一样**，升级时逐文件覆盖即可。

> **脚本目录叫什么名字，现在完全不影响功能。** 判断"这台机器该装哪个 unit"的唯一依据
> 是 `ssl.conf` 里的 `SSL_UNIT_NAME`，不是目录名。所以你 **不需要**把服务器上
> `ssl-nginx` 这个目录改名 —— 直接把新脚本覆盖进去，保留它的 `ssl.conf` 就行。
>
> 具体到你的两台机器：
>
> | 机器 | 目录 | `ssl.conf` 里必须有 |
> |---|---|---|
> | Traefik（VM-12-2-centos） | `.../ssl/` | `SSL_OUTPUT_DIR="/root/cert"`、`SSL_UNIT_NAME="ssl-renew"` |
> | nginx（b919p4） | `.../ssl-nginx/` | `SSL_OUTPUT_DIR="/etc/nginx/ssl"`、`SSL_UNIT_NAME="ssl-nginx-renew"` |
>
> `secrets.env` / `domains.conf` **原样不动** —— 新版本对老配置是向后兼容的：
> 不写 `dns=` 默认就是 `tencent`，不写 `account=` 默认就是 `default`。

---

## 一、为什么拆成这些文件

这是刻意设计的，别合并：

| 文件 | 放什么 | 是否敏感 | 能否提交 Git |
|---|---|---|---|
| `secrets.env` | **只有** DNS 服务商的 API 凭据（腾讯云 + GoDaddy，各可多账号） | ★ 敏感 | ✗ 已 gitignore |
| `domains.conf` | 域名列表，**每行一张证书**，可标 `dns=` / `account=` | 否 | ✓ 可以 |
| `ssl.conf` | 全局策略（邮箱、算法、输出目录、unit 名、阈值…） | 否 | ✓ 可以 |
| `renewpost.sh` | 证书更新后干什么（重启 nginx / 重建容器） | 含服务器本地路径 | ✗ 已 gitignore（只提交 `.example.*` 模板） |

好处：密钥文件只放密钥、一眼能看出有没有泄露；域名列表可以放心进版本库，
加域名就是加一行，不用碰任何密钥。域名换服务商、换账号、调续期阈值也全在 `domains.conf` 里改。
后置动作单独一个脚本，因为机器之间的目录和服务名不一样，**它属于服务器，不属于仓库**。

---

## 二、目录结构

```
<项目根>/
├── .gitignore                     # 排除 secrets.env / renewpost.sh 与所有证书/私钥
├── .gitattributes                 # ★ 强制 *.sh 为 LF 行尾（Windows 开发必看第十二节）
└── scripts/ssl/                   # ★ 唯一的一套代码
    ├── README.md                  # 本文件
    ├── lib.sh                     # 共用函数库（不直接执行）
    │                              #   ★ 服务商规格表 PROVIDER_SPECS 在这里
    ├── ssl.conf                   # 全局策略  ← 每台机器改 2 处（输出目录 / unit 名）
    ├── secrets.env.example        # 凭据模板（腾讯云 + GoDaddy 两段）
    ├── secrets.env                # ★ 真实凭据        ← 复制后填，不进 Git
    ├── domains.conf               # ★ 域名列表 + dns=/account= 归属  ← 加域名改这里
    ├── renewpost.sh.example.nginx # 续期钩子模板：nginx -t → restart → 校验
    ├── renewpost.sh.example.docker# 续期钩子模板：docker compose --force-recreate → 校验
    ├── renewpost.sh               # ★ 服务器本地钩子  ← 复制后改，不进 Git
    ├── ssl-issue.sh               # 批量签发 / 续期
    ├── ssl-status.sh              # 每张证书的到期时间总览
    ├── ssl-setup.sh               # 一次性初始化 + 装 systemd timer
    └── ssl-repair.sh              # 定时器体检 / 收敛成一个（见第八节）
```

证书输出（按 `SSL_OUTPUT_DIR`，`flat` 布局）：

```
# Traefik 机器                              # nginx 机器
/root/cert/                                 /etc/nginx/ssl/
├── example.com.fullchain.pem                ├── example.com.fullchain.pem
├── example.com.privkey.pem                  ├── example.com.privkey.pem
├── example.com.cert.pem                     ├── example.com.cert.pem
├── example.com.chain.pem                    ├── example.com.chain.pem
└── renew.log   ★ 每次续期的一行结果摘要     └── renew.log
```

---

## 三、前置条件

| 项 | 要求 |
|---|---|
| 域名解析 | 必须托管在**支持的 DNS 服务商**下：腾讯云 DNSPod（NS 是 `*.dnspod.net`）或 GoDaddy（NS 是 `*.domaincontrol.com`）。用 `dig +short NS example.com` 确认 |
| DNS 凭据 | 腾讯云：CAM → API 密钥（建议子账号 + 只授 `QcloudDNSPodFullAccess`）<br>GoDaddy：Developer Portal → **Production** Key/Secret |
| 账号 | 域名可以分散在**多个服务商 / 多个账号**下，每个账号配一组凭据 → 见第五、六节 |
| 权限 | 写 `/root/.acme.sh`、证书目录、`/etc/systemd/system`、重启服务都需要 root，所以用 `sudo` |
| 消费方 | Traefik 或 nginx 已装好并作为服务运行（重启动作由 `renewpost.sh` 负责） |
| 系统命令 | `bash` `curl` `openssl` `tar`（CentOS 8 自带，无需安装） |

> **为什么刻意不装包？** CentOS 8 已于 2021-12-31 EOL，`yum` 官方源已下线，
> 任何"顺手装个依赖"都会失败。本套脚本因此只用系统自带二进制。

---

## 四、快速开始

### 第 0 步：上传到服务器

```bash
# 本地项目根目录
scp -r scripts/ssl root@<你的服务器IP>:/opt/your-project/scripts/

# 登录服务器后补上权限与行尾（scp 不保证这两项）
cd /opt/your-project/scripts/ssl
chmod +x ssl-issue.sh ssl-status.sh ssl-setup.sh ssl-repair.sh
[ -f renewpost.sh ] && chmod +x renewpost.sh
sed -i 's/\r$//' *.sh
```

> 用 `git clone` / `git pull` 的话，`.gitattributes` 已经帮你保证 LF，只需 `chmod +x`。
>
> **别把本地的 `secrets.env` 推上服务器** —— 服务器上那份才该有真实凭据。
> 它已在 `.gitignore` 里，`git push` 不会带上；但用 `scp -r` / 打压缩包时要自己留意。

### 第 1 步：填凭据

```bash
cp secrets.env.example secrets.env
chmod 600 secrets.env
vi secrets.env
```

只有一个腾讯云账号、且所有域名都在它下面时，填这两行就够了：

```bash
Tencent_SecretId="AKID..."
Tencent_SecretKey="..."
```

有 GoDaddy 域名就再加：

```bash
GD_Key="..."
GD_Secret="..."
```

多账号 / 多服务商见第五、六节。

### 第 2 步：写域名列表

```bash
vi domains.conf         # 把示例行前面的 # 去掉，改成你的域名
```

### 第 3 步：填邮箱 + 按这台机器改两行

```bash
vi ssl.conf
```

```conf
SSL_EMAIL="you@example.com"

# ↓ 按本机实际情况改（Traefik：/root/cert + ssl-renew；nginx：/etc/nginx/ssl + ssl-nginx-renew）
SSL_OUTPUT_DIR="/etc/nginx/ssl"
SSL_UNIT_NAME="ssl-nginx-renew"
```

> **`SSL_UNIT_NAME` 要和这台机器上"已经装好的那个 timer 名字"一致**，否则升级后
> `ssl-status.sh` 会去查一个不存在的 unit、报「未安装」。不确定就先跑 `./ssl-status.sh`，
> 它会告诉你本机到底装了哪个名字（也会检测"名字对不上"的情况）。

### 第 4 步：先体检，再正式跑

```bash
./ssl-status.sh                  # 看现状（此时应该全是"未签发"）
./ssl-issue.sh --check-only      # 看每张证书将要做什么，不改动任何东西

sudo ./ssl-setup.sh --staging    # 先用 LE 测试环境演练一遍全流程
sudo ./ssl-setup.sh              # 正式签发 + 自动生成钩子 + 装配每日定时器
```

> `--staging` 签出的证书浏览器不信任，只用来验证流程通不通。
> 正式跑之前建议删掉测试证书：`rm -rf <SSL_OUTPUT_DIR>/*/`（或直接等正式签发覆盖）。

### 第 5 步：让消费方用上证书

- **nginx** → 见第十一节第 1 小节（`<域名>.fullchain.pem` + `<域名>.privkey.pem`）
- **Traefik** → 见第十一节第 2 小节（改 `dynamic_conf.toml` 的 `certFile` / `keyFile`）

---

## 五、DNS 服务商：腾讯云 ／ GoDaddy

### 1. 先确认域名在谁家

**"域名在 GoDaddy 注册" ≠ "DNS 托管在 GoDaddy"。** DNS-01 是往"真正管这个 zone 的那家"写 TXT 记录，
所以要看 **NS 记录**，不是看注册商：

```bash
dig +short NS example.com
```

| NS 输出 | DNS 服务商 | 在 `domains.conf` 里写 |
|---|---|---|
| `xxx.dnspod.net` / `xxx.dnspod.com` | 腾讯云 DNSPod | `dns=tencent`（**不写也是它**） |
| `xxx.domaincontrol.com` | GoDaddy | `dns=godaddy` |
| 其它（阿里云/Cloudflare…） | 暂不支持 | 先把 NS 迁到上面两家之一，或自行扩展（见第 4 小节） |

### 2. `domains.conf` 里怎么选

```
格式：  <域名1> <域名2> ...        [ |  选项 ]

选项（可省略，多个用空格分隔）：
   dns=<服务商>      tencent（默认）或 godaddy
   account=<账号名>  该服务商下的哪个账号，默认 default
   renew=<天数>      这张证书自己的续期阈值，默认取 ssl.conf 的 SSL_RENEW_DAYS
   dir=<名称>        这张证书的输出子目录名（仅 subdir 布局有意义），默认取主域名
```

混装实例：

```conf
# 腾讯云 DNSPod，默认账号
example.com www.example.com *.example.com

# GoDaddy 域名
shop.com www.shop.com                | dns=godaddy

# GoDaddy 的第二个账号
pay.com *.pay.com                    | dns=godaddy account=GD2

# 腾讯云的第二个账号，并提前续期
api.example.com                      | dns=tencent account=ACC2 renew=45
```

`dns=` 写错会在启动时就被拦下，并列出合法取值：

```
✘ domains.conf 第 12 行：dns= 只支持 tencent godaddy，当前为 'cloudflare'
```

### 3. `secrets.env` 里的两个变量族

| 服务商 | 默认账号 | 第二个账号（示例 `ACC2`） |
|---|---|---|
| 腾讯云 | `Tencent_SecretId` / `Tencent_SecretKey` | `Tencent_SecretId_ACC2` / `Tencent_SecretKey_ACC2` |
| GoDaddy | `GD_Key` / `GD_Secret` | `GD_Key_ACC2` / `GD_Secret_ACC2` |

规则：账号名后缀只能用 **字母 / 数字 / 下划线**，**区分大小写**；
ID 与 KEY 必须成对、后缀完全一致，脚本启动时逐个校验，不配对直接报错。

### 4. GoDaddy 专章（坑比腾讯云多）

| 事项 | 说明 |
|---|---|
| **必须用 Production 密钥** | acme.sh 的 `dns_gd` 只打 `https://api.godaddy.com/v1`，**没有 staging 环境**。用 OTE（测试）密钥会一直 401。在 <https://developer.godaddy.com/keys> 建 **Production** Key + Secret |
| **NS 必须真的在 GoDaddy** | 否则 TXT 记录写不进去，表现为"校验超时 / not found in DNS"。`dig +short NS <域名>` 必须先确认 |
| **API 限流偏严** | GoDaddy 对 `GET/PUT` 记录限流，并且从 2024-05 起**对域名数少于 10 个的账号拒绝 `GET domains/<域名>`**。acme.sh 因此改用"探询一条 TXT 记录"的方式探测 zone（`GET domains/<h>/records/TXT/<probe>`），行为正常但会多花几个请求 |
| **生效慢一档** | `dns_gd` 钩子内部写完全部 TXT 后**自己会 sleep 10 秒**；再叠加本套的 `SSL_DNS_SLEEP`。批量签多张时建议把 `SSL_DNS_SLEEP` 提到 `60` |
| 一个 zone 多条记录 | 同一 zone 下多张证书共用一个 `_acme-challenge` 记录名时，acme.sh 会同时写入多条 TXT，属正常 |

### 5. 想再加一个服务商（阿里云 / Cloudflare …）

代码里**没有**任何 `if 服务商==...` 的散落判断，全部走 `lib.sh` 顶部的规格表。
新增一家只需在这 4 处各加一行（`lib.sh` 里都有「★ 新增服务商第 ①/②/③/④ 处」标记）：

```bash
PROVIDER_SPECS=(
  "tencent|dns_tencent|Tencent_SecretId|Tencent_SecretKey|腾讯云 DNSPod|dnspod|https://dnspod.tencentcloudapi.com"
  "godaddy|dns_gd|GD_Key|GD_Secret|GoDaddy|domaincontrol.com|https://api.godaddy.com/v1"
  # ① 规格表加一行：名称|acme钩子|ID变量|KEY变量|显示名|NS特征|探活URL
)
```

② `load_secrets` 的变量名扫描正则（多识别一个新前缀）、
③ `account_activate` 的写入 `case`、④ `provider_cred_help` 的获取指引。
其余（体检、连通性、报错、状态表、账号归属）都是数据驱动的，自动跟着走。

---

## 六、域名分散在多个服务商 / 多个账号下

**典型场景**：`aaa.com` 的 DNS 在腾讯云账号 A 下，`bbb.com` 在你 GoDaddy 账号里。
只要在 `secrets.env` 里填好各组凭据、在 `domains.conf` 里标好 `dns=` / `account=`，一次跑完。

```bash
# 腾讯云 —— 默认账号
Tencent_SecretId="AKID..."
Tencent_SecretKey="..."

# 腾讯云 —— 第二个账号，名字叫 ACC2
Tencent_SecretId_ACC2="AKID..."
Tencent_SecretKey_ACC2="..."

# GoDaddy —— 默认账号
GD_Key="..."
GD_Secret="..."

# GoDaddy —— 第二个账号，名字叫 GD2
GD_Key_GD2="..."
GD_Secret_GD2="..."
```

```conf
aaa.com www.aaa.com *.aaa.com                    # tencent:default
bbb.com www.bbb.com *.bbb.com | account=ACC2     # tencent:ACC2
shop.com www.shop.com         | dns=godaddy      # godaddy:default
pay.com *.pay.com             | dns=godaddy account=GD2
```

### ★ 一张证书里的域名必须同属一个服务商 + 同一账号（唯一的硬约束）

这条约束来自 ACME 本身，不是本脚本的限制：

> DNS-01 验证是**一次调用**把这张证书所有域名的 `_acme-challenge` TXT 记录写进去，
> 而 acme.sh 一次只能用**一套凭据**（一个钩子 + 一组密钥）。

所以同一行里的域名不能跨服务商、也不能跨账号 —— **跨了就必须拆成两行**：

```conf
aaa.com www.aaa.com *.aaa.com                   # 腾讯云账号 A 的三个域名，一张证书 ✔
bbb.com www.bbb.com *.bbb.com | account=ACC2    # 腾讯云账号 B 的，另做一张 ✔
shop.com www.shop.com         | dns=godaddy     # GoDaddy 的，再一张 ✔
```

硬塞进一行的后果是签发失败。脚本会明确指出这张证书用的是哪个组合：

```
! 这张证书用的是 GoDaddy 账号 'godaddy:GD2'（ID 尾号 …7f3a）
! 若这些域名并不在该账号下，GoDaddy 会报「记录不存在 / 权限不足」——
! 跨账号 / 跨服务商的域名必须拆成 domains.conf 里的两行（每行一张证书）
```

### 会不会串号？不会

每次处理**每一张证书**之前，脚本都会把当前生效的凭据重新指向该证书的
**(服务商, 账号)**，并且**先把所有服务商的槽位清空再写入目标那组**：

| 机制 | 说明 |
|---|---|
| 逐张显式覆盖 | 腾讯云的 `dns_tencent` 固定读 `Tencent_SecretId/Key`，GoDaddy 的 `dns_gd` 固定读 `GD_Key/GD_Secret`；脚本在每张证书签发前把对应变量导出成该证书的账号 |
| 全槽位先清 | `account_activate` 先 `export` 四个变量为空，再写目标服务商的那组 —— 避免"A 用完后 B 的槽位没被覆盖"这种跨服务商残留 |
| 环境变量优先 | 钩子内部是 `${GD_Key:-$(_readaccountconf_mutable GD_Key)}` —— 环境变量一定盖过 `account.conf` 里的旧值 |
| 清掉密钥副本 | 每张签发后自动删除 `~/.acme.sh/account.conf` 里的 `SAVED_*`（一把清，覆盖所有服务商），不留上一张证书的残影 |

还会做一次**归属预检**：`domains.conf` 里写了、但 `secrets.env` 里没定义的组合会被直接拦下，
并列出所有可用账号和完整的变量配方，绝不带着错配置往下跑：

```
✘ domains.conf：zzz.com 指定了 dns=godaddy account=NOPE，但 scripts/ssl/secrets.env 里没有这个组合
✘ 已定义的账号：tencent:default tencent:ACC2 godaddy:default
  在 scripts/ssl/secrets.env 里补一组配对的变量（后缀必须和 account= 完全一致）：
      tencent default ： Tencent_SecretId / Tencent_SecretKey
      tencent 其他    ： Tencent_SecretId_<账号名> / Tencent_SecretKey_<账号名>
      godaddy default ： GD_Key / GD_Secret
      godaddy 其他    ： GD_Key_<账号名> / GD_Secret_<账号名>
```

### 怎么看每个域名走哪个账号

```bash
./ssl-status.sh            # 表格里有一列就是「DNS 账号」，形如 godaddy:GD2
./ssl-status.sh --detail   # 每张证书单独一段，含凭据组合与服务商显示名
./ssl-issue.sh --check-only
```

`ssl-status.sh` **不需要凭据就能看到账号归属** —— 它只读 `secrets.env` 的**变量名**，
不读密钥值；顺手还能发现"账号名拼错了"这种问题。

---

## 七、每张证书的到期时间是怎么自动管理的

`ssl-issue.sh` 对列表中**每一张证书独立判断**，判定顺序写死在 `lib.sh` 的 `cert_decide()` 里：

| 顺序 | 条件 | 动作 |
|---|---|---|
| 1 | 证书不存在 | 签发 |
| 2 | 已过期 | 签发 |
| 3 | 剩余天数 **≤ 这张证书自己的阈值** | 续期 |
| 4 | 证书里的域名集合 ≠ `domains.conf` 里的配置 | 重签 |
| 5 | 其余 | **跳过**（不调用 acme.sh，不浪费额度） |

阈值来源：该行 `renew=` 优先，没有就用 `ssl.conf` 的 `SSL_RENEW_DAYS`。

> **为什么不用 acme.sh 自己的续期调度？**
> acme.sh 的 `DEFAULT_RENEW` 在不同版本里默认值不一致（30 / 60 都有），
> 续期时刻算法是 `创建时间 + N天 - 1天`，语义容易踩坑。
> 所以本套脚本**自己判定**，只有判定为"该续期"时才带 `--force` 去调 acme.sh。
> 结论：`renew=` 里写的天数就是实际生效的阈值，行为完全可预期。

随时查看每张证书的状态：

```bash
./ssl-status.sh              # 总览表：到期时间 / 剩余天数 / 阈值 / 状态 / 账号
./ssl-status.sh --detail     # 加上证书域名、私钥权限、凭据组合、acme.sh 记录的下次续期
./ssl-status.sh --quiet      # 只输出一行汇总，适合塞进监控
# certs=3 ok=1 due=1 expired=0 missing=1   （有 expired 或 missing 时退出码为 1）
```

---

## 八、自动续期（systemd timer）

`ssl-setup.sh` 会安装一个每日定时器，**unit 名取自 `ssl.conf` 的 `SSL_UNIT_NAME`**：

```
<SSL_UNIT_NAME>.timer    每天 03:17（±30 分钟随机抖动）触发 <SSL_UNIT_NAME>.service
<SSL_UNIT_NAME>.service  执行 <脚本目录>/ssl-issue.sh
```

于是：`SSL_UNIT_NAME="ssl-renew"` 的机器装 `ssl-renew.timer`，
`SSL_UNIT_NAME="ssl-nginx-renew"` 的机器装 `ssl-nginx-renew.timer` —— **互不覆盖**。

由于 `ssl-issue.sh` 逐张按各自阈值判断，所以**每张证书都在自己该续期的那天被续**，
不需要为每个域名配一条定时任务。`RandomizedDelaySec` 避开整点高峰，
`Persistent=true` 保证关机期间错过的任务开机后补跑。

```bash
systemctl list-timers <SSL_UNIT_NAME>.timer          # 看下次触发时间
systemctl start <SSL_UNIT_NAME>.service              # 立即手动触发一次
systemctl cat <SSL_UNIT_NAME>.timer                  # ★ 确认它装的到底是哪个 unit（见下方警告）
journalctl -u <SSL_UNIT_NAME>.service -n 100 --no-pager   # 看这一次的完整输出
```

> ⚠️ **时区**：`OnCalendar=*-*-* 03:17:00` 按**服务器本地时区**解释。
> 用 `timedatectl` 确认本机时区；若机器是 EDT/UTC，实际触发时间会和你直觉里的北京时间差好几小时。
> 想改成北京时间触发，先想清楚"这会连带影响全机日志时间"，再决定要不要 `set-timezone`。

> ⚠️ **别用 `systemctl list-unit-files <名>` 判断 unit 存不存在**：
> 名字匹配不到时，某些 systemd 版本**仍然返回 0**，接着跑
> `list-timers <不存在的unit>` 会输出 `0 timers listed.` + `Pass --all …` 两行 ——
> **和"从未安装"长得一模一样**，非常容易误判（已踩）。
> 可靠判据是 **`systemctl cat <名>` 的退出码**，再看 `is-enabled` / `is-active`。
> `ssl-status.sh` 的「自动续期」栏已经做了三段判断（未安装 / 未启用 / 未运行）。

> 如果不想用 systemd，加 `--no-timer`，然后自己挂 cron：
> `17 3 * * * /opt/your-project/scripts/ssl/ssl-issue.sh >/dev/null 2>&1`
> **但不要同时保留 acme.sh 自带的 crontab** —— 脚本会自动 `--uninstall-cronjob` 掉它，避免两套调度打架。

### 装重了怎么办：`ssl-repair.sh`

一台机器上如果**用不同的 `SSL_UNIT_NAME`** 跑过两遍 `ssl-setup.sh`，就会装上**两个**定时器，
两个都在跑、各续各的 `domains.conf`，事后很难分清谁管哪些域名。

`ssl-repair.sh` 就是来收这个场的：

```bash
sudo ./ssl-repair.sh                                   # ① 只读体检（默认，什么都不改）
sudo ./ssl-repair.sh --apply --keep ssl-renew.timer     # ② 确认无误后收敛成一个
```

体检会把机器上所有 `ssl*.timer` 摊开，逐个报告
**状态 / 服务 / 脚本路径 / 输出目录 / 日志路径 / 归属 / 管着哪几张证书 / 最近一条记录**，然后给出建议。

### 该留哪个？看 unit 名和脚本目录配不配

判断依据不是猜目录名，而是**读本目录 `ssl.conf` 里的 `SSL_UNIT_NAME`** ——
它就是"本目录本就该装哪个 unit"。体检会对每个 timer 打这个标记：

| 标记 | 含义 | 处置 |
|---|---|---|
| `✔ 自洽 —— 本目录该装的就是它` | 这套配置自己装的 | **留它** |
| `✘ 外来户 —— 本目录该装的是 X，不是这个` | 被**别的配置**误装进来的 | **删它** |

所以「保留哪个」是可以**确定**的：留标记为 `✔ 自洽` 的那个。
脚本给的建议也按同一优先级排序：**自洽 > 管的域名多 > 名字排序**。

> 如果两个 timer 指向**同一个**脚本目录（= 在同一份脚本上跑了两遍 `ssl-setup.sh`），
> 那它们读的是同一份 `domains.conf`、写的是同一个 `renew.log` ——
> **每次续期都会写 2 行日志**（两条时间戳完全相同，这就是最直接的证据）。
> 这种情况下删掉外来户**零风险**。

**它不会盲目把两个都删掉。** 两套的 `domains.conf` 可能管着**不同的域名**，
全删再重装会静默造成域名失去续期。所以删之前会做一次「域名丢失检查」：

| 检查结果 | 脚本行为 |
|---|---|
| 准备删掉那套的域名，在保留那套里**都有** | 允许执行，删多余的 timer（+ 无人引用的 service） |
| 有域名会因此**没人续期** | **直接拒绝执行**（退出码 1），列出缺哪几个 |

被拒绝时给出两条路：

- **A)** 先把缺的域名补进保留那套的 `domains.conf`，再看一遍、再删；
- **B)** 反过来保留另一套：`--apply --keep <另一个 unit>`。

> 只有当**没有其它定时器还引用同一个 `.service`** 时，脚本才会连 `.service` 一起删。

**如果你只是想确认"当初有没有装重"**，跑一次不带参数的 `./ssl-repair.sh` 就够了，
它什么都不会改：

| 体检结果 | 含义 |
|---|---|
| `只有一套定时器，无需修复` + 归属 `✔ 自洽` | 当初没装重，无需做任何事 |
| `没有冲突 —— 只有这 1 个续期定时器` + 归属 `✘ 外来户` | **只有一个**在跑、功能正常；只是 unit 名与本目录配置不配套 |
| `发现 2 个续期定时器` | 装重了，按提示收敛成一个 |

**"单套 + 外来户"是什么情况？** 机器上只有一个定时器，但它的 unit 名不是本目录
`ssl.conf` 里 `SSL_UNIT_NAME` 声明的那个 —— 通常是因为**这份目录是从别的机器/别的配置复制过来的**，
而 unit 是更早或手工装的。

功能上没影响（脚本只看 `ExecStart` 指向谁，不看 unit 名），但有两个后续坑：

1. 名字对不上，以后排障容易看糊涂；
2. **如果在这个目录直接跑 `./ssl-setup.sh`，它会再装一个（名字不同的）定时器** ——
   于是机器上就有两个 timer 指向同一份脚本，正是上面那种重复安装。

体检会给出改名的具体命令。**改名之前必须先确认 `ssl.conf` 的 `SSL_OUTPUT_DIR` 是本机原配**
（setup 装完会顺带跑一次签发，输出目录写错会把证书签错地方）。

> `--force` 可以在明知有域名会失去续期的情况下强行删 —— **不推荐**。
> 这个守卫本来就是为了拦住这种操作才存在的。

**可测试性**：单元目录和 `systemctl` 都能用环境变量顶掉
（`SSL_REPAIR_UNIT_DIR`、`SSL_REPAIR_SYSTEMCTL`），可以在不碰真实 systemd 的前提下验证。

---

## 九、证书更新后自动重启服务（`renewpost.sh`）＋ 运行日志

### 1. `renewpost.sh` 是什么

一个普通的 shell 脚本，**只在真的有证书被更新并部署之后**才执行。
如果所有证书都还没到期（本次全部跳过），它不会跑 —— 不会每天白重启一次服务。

脚本自动发现它，**`ssl.conf` 不用改任何东西**：

| 顺序 | 找什么 | 说明 |
|---|---|---|
| ① | `ssl.conf` 里的 `SSL_POST_HOOK=<路径>` | 想放别处时才用；相对路径按脚本目录解析 |
| ② | `<脚本目录>/renewpost.sh` | **默认走这个**，存在就用 |

两个都配了会告警，并且**只执行 `renewpost.sh`**（避免动作重复）。

仓库里带两个模板，**按你的消费方挑一个**：

| 模板 | 动作 | 用在 |
|---|---|---|
| `renewpost.sh.example.nginx` | `nginx -t` → `systemctl restart nginx` → 校验 `is-active` | nginx 机器 |
| `renewpost.sh.example.docker` | `docker compose up --force-recreate` → 校验容器 `running` | Traefik 机器（容器化） |

```bash
cp renewpost.sh.example.nginx renewpost.sh    # 或 .example.docker
chmod +x renewpost.sh
vi renewpost.sh                               # 改顶部几个变量
```

> **为什么不用 `ssl.conf` 的 `SSL_RELOAD_CMD`？**
> 它仍然可用（没配 `renewpost.sh` 时作为兜底），但它只能写一行命令，
> 没法"进目录 + 判断 compose 版本 + 校验结果"。所以推荐 `renewpost.sh`。
> 另外本套脚本**不再把 `SSL_RELOAD_CMD` 传给 acme.sh 的 `--reloadcmd`** ——
> 那会让 acme.sh 每装一张证书就跑一次，加上脚本结尾那次，等于重载 N+1 次。

### 2. nginx 版：为什么用 `restart` 而不是 `reload`

默认动作是三件事，**顺序很关键**：

```bash
nginx -t                  # ① 先验配置（这一步会真正去读证书和私钥）
systemctl restart nginx   # ② 重启
systemctl is-active nginx # ③ 校验服务真的起来了
```

- **① 放在重启之前**：`nginx -t` 会加载 `ssl_certificate` / `ssl_certificate_key`，
  证书缺失、路径写错、私钥读不了都会在这一步暴露。放在前面，就能在"服务被打断"之前发现问题 ——
  否则你会先把 nginx 重启坏，再回头查原因。**校验失败时脚本直接退出、不重启 nginx**，现有服务不受影响。
- **③ 是必须的**："命令返回 0"只代表指令发出去了，不代表服务在跑。
  证书换了但 nginx 没起来，是最难发现的失败模式 —— 监控看到的是"网站挂了"，
  根本不会往证书上想。所以状态不对就返回非 0，让续期日志记成失败。

**为什么不 `reload`？** `reload` 原理上也会重读证书，但**实测踩过坑：改 `reload` 之后证书没换过来，
改回 `restart` 才生效。** 两个原因：

| # | 原因 | 说明 |
|---|---|---|
| 1 | **旧 worker 迟迟不退出** | `reload` 是优雅关闭：老 worker 要等手上的长连接（keepalive / WebSocket / 长轮询 / 监控探活）处理完才退出，而 `worker_shutdown_timeout` **默认是 0（无限等）**。这些残留 worker 手里拿的还是**旧证书**，新连接一旦落到它们身上就还是老证书。 |
| 2 | **TLS 会话复用** | 配置里的 `ssl_session_cache shared:SSL:1m` 是**跨 worker 共享**的，`reload` 不会清它。客户端（尤其浏览器）复用已有会话时直接跳过证书交换，根本看不到新证书。 |

`restart` 会重建 master 并清空会话缓存，所以是**确定能看到新证书**的那个。代价是
中断通常 **< 1 秒**，对证书轮换（一天最多一次、且本来就是低频动作）完全值得。

确实要零中断就用 `reload`，但**换完必须实测**（改 `renewpost.sh` 顶部一行）：

```bash
NGINX_ACTION="reload"       # 默认是 restart
```

```bash
# ★ 验证：-no_ticket -no_reuse 强制完整握手，否则会被会话复用骗到
echo | openssl s_client -connect <域名>:443 -servername <域名> \
  -no_ticket -no_reuse 2>/dev/null | openssl x509 -noout -subject -dates
```

看到 `notAfter` 是新日期才算真生效。仍是旧日期 ⇒ 旧 worker 还没退，只能 `restart`。
nginx 服务名不是 `nginx` 时改 `NGINX_SERVICE`。

### 3. docker 版

模板顶部三个变量：

```bash
COMPOSE_DIR="/root/docker/api"     # 有 docker-compose.yml 的目录
COMPOSE_SERVICE="proxy"            # 要重建的服务名
COMPOSE_ARGS="--force-recreate -d --no-deps"
```

实际执行的就是：

```bash
cd /root/docker/api && docker compose up --force-recreate -d --no-deps proxy
```

> 命令形式会自动选：优先 `docker compose`（v2 插件），没有才退回 `docker-compose`。
> 两者都没有时会明确报错并告诉你怎么写死绝对路径，不会静默失败。

跑完还会检查容器的 `State.Status` 是不是 `running`；不是就以非 0 退出，
这样"证书换好了但服务挂了"不会被记成成功。

> ⚠️ **容器化消费方的两个坑**（Traefik 场景实测踩过）：
> ① `docker restart` **不会套用新的挂载**，必须 `docker compose up -d` 重建容器 ——
>   所以钩子里用 `--force-recreate` 而不是 `restart`；
> ② 如果证书目录挂在 `/root/` 下面，注意 `/root` 权限通常是 550，
>   非 root 的容器读不进去 —— 挂到 `/data/cert` 之类的位置更稳。

两个模板都能先空跑确认再真跑：

```bash
bash renewpost.sh --dry-run    # 只打印将要执行的命令，不碰服务
bash renewpost.sh              # 手工跑一次，确认服务能正常重启
```

### 4. 日志在哪、怎么判断成功

**这是关键：`<SSL_OUTPUT_DIR>/renew.log`。**
（Traefik 机器是 `/root/cert/renew.log`，nginx 机器是 `/etc/nginx/ssl/renew.log`。）

```bash
cat <SSL_OUTPUT_DIR>/renew.log          # 全部历史
tail -n 5 <SSL_OUTPUT_DIR>/renew.log    # 最近几次
./ssl-status.sh                         # 状态总览里直接显示最近 5 条
```

格式（每跑一次追加一行）：

```
2026-09-18 03:17:02  OK   处理=3   更新=1   跳过=2   失败=0    模式=定时  后置钩子=成功
```

| 字段 | 含义 |
|---|---|
| `OK` / `FAIL` | `OK` = 本次无失败；`FAIL` = 有失败项，或中途异常中止 |
| `处理` | 本次参与判断的证书数 |
| `更新` | 真正签发/续期并部署成功的张数（`0` 说明都在有效期内，正常） |
| `跳过` | 未到续期阈值，跳过的张数 |
| `失败` | 出错的张数（具体原因看 `journalctl`） |
| `模式` | `定时` = 由 **systemd** 启动（timer 到点触发，或你手工 `systemctl start` —— 两者都走系统通道）；`手动` = 你在终端直接执行脚本 |
| `后置钩子` | `成功` / `失败` / `未配置` / `文件不存在`；没更新证书时这一栏不出现 |

> ⚠️ **判断"是不是定时触发的"，不要只看 `$INVOCATION_ID`。**
> CentOS 8 的 systemd 239 **不把这个变量导出给 service 进程**（`InvocationID` 作为 journal 字段
> 确实早就有，但作为**环境变量**导出给进程是更晚的事，两者常被混为一谈）。
> 只用它会把**定时任务也错标成"手动"**。可靠的判据（任一命中即为 systemd 启动）：
> `${JOURNAL_STREAM:-}`（unit 配了 `StandardOutput=journal` 时由 systemd 注入）、
> `[ "${PPID:-0}" -eq 1 ]`（oneshot 服务由 systemd(pid 1) 直接 fork）、`$INVOCATION_ID`。

判断方法：

| 你看到的 | 结论 |
|---|---|
| 有 `OK` 行，`失败=0` | ✅ 正常 |
| 有 `FAIL` 行 | ❌ 有事，用 `journalctl -u <unit>.service -n 200 --no-pager` 看细节 |
| **某天完全没有记录** | ⚠️ 任务**没跑成**（timer 没启 / 机器没开机 / 脚本一启动就失败）。`./ssl-status.sh` 会把 timer 的触发时间与这里的记录**自动对账**，对不上直接告警 |

> **`list-timers` 里的 `LAST` 不等于「执行成功」。**
> 它只说明「到点触发了一次 job」—— 哪怕脚本一秒都没跑起来（`ExecStart` 路径失效、
> `WorkingDirectory` 不存在、进程一启动就退出），`LAST` 照样会刷新。
> 所以判断「到底跑没跑」，按这个顺序：
> 1. `./ssl-status.sh` —— 看「需要关注」里有没有**对账告警**；
> 2. `journalctl -u <unit>.service -n 200 --no-pager` —— 看那一次的完整输出；
> 3. `renew.log` 是唯一长期凭证：**有记录才算跑过**；空白、或与 timer 触发时间对不上 = 那一次没跑成。

> **为什么不用 `journalctl` 就够了？**
> CentOS 8 的 systemd journal **默认不持久化** —— 日志只写在 `/run/log/journal`（内存盘），
> 机器一重启，"上周那次到底续没续成"就查不到了。所以额外落一份文件日志。
> 另有 `<脚本目录>/renew-fallback.log`：只在「配置还没解析出来就失败」时才会出现
> —— 正常运行时不会有这个文件，见到它说明 `ssl.conf` 缺失或内容非法。

### 5. `ssl-setup.sh` 会帮你做

- 检测到 **nginx** → 从 `renewpost.sh.example.nginx` 生成 `renewpost.sh` 并 `chmod +x`；
- 没检测到 nginx、但检测到 `DEFAULT_COMPOSE_DIR`（默认 `/root/docker/api`）存在 →
  从 `renewpost.sh.example.docker` 生成；
- 两个都没检测到 → **只提示，不生成一个必然失败的钩子**，并给出两条 `cp` 命令让你自选；
- 已存在 `renewpost.sh` → **不动它**（那是你的文件）。

想改默认 compose 目录，改 `ssl-setup.sh` 顶部的 `DEFAULT_COMPOSE_DIR` 即可。

---

## 十、常用命令

```bash
./ssl-status.sh                              # 到期时间总览（含最近运行日志）
./ssl-status.sh --detail                     # 详情
./ssl-issue.sh --check-only                  # 只看会做什么，不改动
./ssl-issue.sh                               # 该续的续，该跳的跳
./ssl-issue.sh --domain api.example.com      # 只处理一张
./ssl-issue.sh --domain api.example.com --force   # 只强制重签一张
./ssl-issue.sh --list                        # 只看解析后的列表（含 dns=/account=）
./ssl-issue.sh --staging --debug             # 测试环境 + 详细日志
bash renewpost.sh --dry-run                  # 空跑一遍后置钩子，不碰服务
sudo ./ssl-repair.sh                         # 定时器体检（只读）
```

---

## 十一、消费方怎么引用证书

### 1. nginx

**只用到两个文件**：

| nginx 指令 | 用哪个文件 |
|---|---|
| `ssl_certificate` | `<域名>.fullchain.pem` ← **必须 fullchain** |
| `ssl_certificate_key` | `<域名>.privkey.pem` |

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name example.com www.example.com;

    ssl_certificate     /etc/nginx/ssl/example.com.fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/example.com.privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
}
```

⚠️ **别用 `.cert.pem`（只有叶子证书，缺中间 CA，部分客户端会报"证书链不完整"），
也别用 `.chain.pem`（只有中间 CA，没有叶子）。**

改完配置先验证，再重载：

```bash
nginx -t && systemctl reload nginx
```

> `nginx -t` 会真正去读证书文件和私钥 —— 路径写错、文件不存在、私钥权限不足，
> 它都会直接报出来。**养成"先 -t 再 reload"的习惯**，能避免把 nginx 改挂。
> 换证书轮换动作本身，见第九节第 2 小节（推荐 `restart`，不要 `reload`）。

### 2. Traefik

Traefik 的动态配置（`dynamic_conf.toml`）通过 `[tls.certificates]` 显式列出每张证书：

```toml
[[tls.certificates]]
  certFile = "/root/cert/example.com.fullchain.pem"
  keyFile  = "/root/cert/example.com.privkey.pem"
```

- **`certFile` 必须用 `fullchain.pem`**（叶子 + 中间 CA）、`keyFile` 用 `privkey.pem`。
  ✘ `.cert.pem` 缺中间 CA、✘ `.chain.pem` 缺叶子 —— 都不能用。
- **容器边界**：Traefik 若跑在 docker 里，`/root/cert/` 必须挂进容器
  （`- /root/cert:/root/cert:ro`），否则整份动态配置加载失败。
- ⚠️ **一条 `[[tls.certificates]]` 指向不存在的文件 → 整份动态配置加载失败**，
  不是只影响那一个域名。所以目录里还没有的域名，宁可先在配置里注释掉。
- **判据**：多个站点**同时**全变默认证书 ⇒ 必是"共同依赖"（挂载 / 权限）挂了，
  而非各张证书格式都坏。先查 `docker exec … ls -l <证书目录>` +
  `docker logs … | grep -i -E 'cert|tls|error'`。

### 3. 改证书输出目录

改 `ssl.conf` 一行，然后把消费方配置里的路径一起改：

```conf
SSL_OUTPUT_DIR="/etc/nginx/ssl"     # nginx 机器
# SSL_OUTPUT_DIR="/root/cert"       # Traefik 机器
SSL_OUTPUT_LAYOUT="flat"            # <目录>/<主域名>.fullchain.pem
```

> **布局两种**：
> `flat`（推荐）= `<目录>/<主域名>.fullchain.pem`，配置里一眼看出是哪张证书；
> `subdir` = `<目录>/<主域名>/fullchain.pem`，每个域名一个子目录。
>
> ⚠️ **SELinux 提醒**（nginx 机器）：CentOS 上 nginx 读证书受 SELinux 约束。
> `/etc/nginx/ssl` 在 nginx 的标准路径下，上下文天然正确；
> 换到 `/root/cert`、`/data/ssl` 这类位置可能需要额外处理：
> ```bash
> ausearch -m avc -ts recent | grep nginx          # 先看是否被拦
> chcon -R -t httpd_sys_content_t /root/cert      # 放大上下文
> ```
> 图省事就用默认的 `/etc/nginx/ssl`。

---

## 十二、Windows 开发 → Linux 部署的行尾陷阱（务必看）

本仓库已用 `.gitattributes` 把 `*.sh` 强制为 LF。如果**没有**这个文件而 Git 又开了
`core.autocrlf=true`（Windows 默认），shell 脚本会被检出成 CRLF 行尾，
上传到 CentOS 后执行会直接报：

```
bash: ./ssl-issue.sh: /bin/bash^M: bad interpreter: No such file or directory
```

> **关于 shebang**：本套脚本统一用 `#!/bin/bash`，**刻意不用** `#!/usr/bin/env bash`。
> 原因：`env` 多一层间接（内核先 exec `/usr/bin/env`，再由它去找 `bash`），
> 少一个依赖就少一类故障。
> ⚠️ 但报 `bad interpreter: Text file busy` 时，报错里的 `/usr/bin/env` 只是
> shebang 里写的解释器名，**不等于元凶** —— busy 的往往是脚本文件本身
> （`execve` 的写占用检查发生在解析 shebang **之前**），这种情况改 shebang **无效**，
> 详见下文「报 `Text file busy` 怎么办」。
> CentOS 8 上 `/bin` 是 `/usr/bin` 的符号链接，`/bin/bash` 与 `/usr/bin/bash` 同一个文件。
> 同理，`ssl-setup.sh` 生成的 systemd service 用的是
> `ExecStart=/bin/bash <脚本>`，连 shebang 都不依赖。

用 `scp` / 压缩包手工拷贝而不是 `git clone` 时，记得先修一次：

```bash
sed -i 's/\r$//' scripts/ssl/*.sh && chmod +x scripts/ssl/*.sh
```

---

## 十三、排障速查表

### 启动阶段（读配置就失败）

| 报错 | 原因 | 解决 |
|---|---|---|
| `找不到密钥文件` | 没建 `secrets.env` | `cp secrets.env.example secrets.env && chmod 600 secrets.env` |
| `没有在 secrets.env 里识别到任何 DNS 凭据` | 文件里还是空字符串 | 至少填一组：腾讯云 `Tencent_SecretId`/`Tencent_SecretKey`，或 GoDaddy `GD_Key`/`GD_Secret` |
| `账号 'xxx' 没填全` | ID 和 KEY 的后缀不配对 | `GD_Key_GD2` 必须配 `GD_Secret_GD2`；腾讯云同理 |
| `腾讯云账号 'xxx' 的 SecretId 看起来不完整` | 密钥被截断、复制漏了 | 重新完整复制 `AKID...` |
| `dns= 只支持 tencent godaddy，当前为 'xxx'` | `dns=` 写了个不存在的服务商 | 改成 `tencent` / `godaddy`（或不写，默认 tencent） |
| `以下变量被定义了多次：Tencent_SecretId` | `secrets.env` 里躺着**两组同名凭据**。文件是 source 进来的，同名变量**后者覆盖前者**；若 ID 与 KEY 的顺序错开，就会拿 A 的 SecretId 配 B 的 SecretKey → 腾讯云报 `AuthFailure.SignatureFailure`，而两组 Key 的长度/字符集都合法，从形状上查不出来 | 只保留一组，其余**整组**注释掉（行首加 `#`）。⚠️ 只删一半正是这个故障的成因 |
| `指定了 dns=X account=Y，但 secrets.env 里没有这个组合` | 账号名拼错，或那组密钥没填 | 对照报错里列出的可用账号；后缀**区分大小写** |
| `account= 只能用字母 / 数字 / 下划线` | 账号名里带了 `-` `.` 空格等 | `my-acct` → `my_acct`，并同步改 `secrets.env` 里的后缀 |
| `域名格式不合法 'xxx'` | 域名写错、少了点 | 检查 `domains.conf` 对应行 |
| `第一个域名不能是泛域名` | 行首写了 `*.xxx` | 把主域名提到最前面：`example.com *.example.com` |
| `未知选项 'xxx'` | 选项只支持 `dns=` / `account=` / `renew=` / `dir=` | 检查 `\|` 后面的内容 |
| `主域名 ... 重复出现` | 两行写了同一个主域名 | 删掉重复行，或把它合进同一行的 SAN |
| `输出目录 ... 重复` | 两行 `dir=` 撞了 | 改其中一个 `dir=` |
| `SSL_EMAIL 还没填` | `ssl.conf` 里邮箱为空 | 填上邮箱 |
| `SSL_OUTPUT_LAYOUT 只能是 subdir 或 flat` | 拼写错误 | 改回这两个值之一 |
| **`HOME: unbound variable`**（journal 里只有这一句、`renew.log` 全空） | root 的 systemd service **不注入 `HOME`**（是完全未定义，不是空串），而脚本开了 `set -u` —— nounset 下裸用 `${HOME}` 是**致命错误**，进程当场 exit 1。手动执行正常（登录 shell 有 HOME），所以只在定时任务里复现 | 换用带兜底的 `lib.sh`（开头会补 `HOME` 并 `export`，acme.sh 子进程也能用）；临时绕过：给 unit 加 `Environment=HOME=/root` |

### 签发阶段

| 报错 | 原因 | 解决 |
|---|---|---|
| `You don't specify tencent api SecretId and SecretKey yet.` | acme.sh 没拿到腾讯云密钥 | 确认用的是 `secrets.env` 里的**腾讯云 CAM 密钥**（`AKID...` 开头），不是 DNSPod 旧版 Token |
| `AuthFailure.SignatureFailure` / `403` | 密钥错误。**先别急着换密钥** —— 常见真因是 `secrets.env` 里有两组同名凭据（见启动阶段那条），`source` 后 ID 与 KEY 来自不同的组 | ① `grep -c '^Tencent_SecretId' secrets.env` 应为 **1**；② 确认 SecretKey 为 32 位纯字母数字；③ 仍不行再重新生成密钥 |
| `ResourceNotFound.NoDataOfDomain` | 域名不在该腾讯云账号下 | 确认该域名归属哪个账号，在 `domains.conf` 给这行加 `account=<账号名>` |
| GoDaddy `401 Unauthorized` / `ACCESS_DENIED` | 用的是 **OTE（测试）密钥**，或密钥无该域名的 DNS 权限 | 到 <https://developer.godaddy.com/keys> 建 **Production** Key/Secret；确认 NS 确实在 GoDaddy |
| 一张证书里混了不同服务商 / 不同账号的域名 | 违反"一行一服务商一账号"约束（见第六节） | 拆成两行，各自带 `dns=` / `account=` |
| `AuthFailure.UnauthorizedOperation` | 子账号权限不足 | 授予 `QcloudDNSPodFullAccess` |
| 体检提示 `NS 不是 DNSPod / GoDaddy` | 域名托管在别家（阿里云等） | 先把 NS 迁到支持的服务商，否则 DNS-01 无法自动完成 |
| 校验超时 / `not found in DNS` | TXT 传播慢（GoDaddy 尤其） | 把 `ssl.conf` 的 `SSL_DNS_SLEEP` 调到 60（GoDaddy 建议直接 60） |
| 已有 `_acme-challenge` 的 CNAME 记录 | 与 TXT 冲突 | 先删掉那条 CNAME |
| `CAA record` 相关报错 | 域名的 CAA 限制了签发机构 | `dig +short CAA example.com`，允许 `letsencrypt.org` |
| `too many certificates already issued` | LE 正式环境限流（同域名组每周 5 张） | 调试改用 `--staging`（⚠️ GoDaddy 的 `dns_gd` **没有 staging**，只能控制签发频率） |
| GitHub 拉不下来 | 服务器访问 GitHub 困难 | `ACME_REPO=/opt/src/acme.sh ./ssl-issue.sh`（先把源码 scp 上去），或用镜像 `ACME_TARBALL=<镜像地址>` |
| `bad interpreter: No such file or directory` | CRLF 行尾 | 见第十二节 |

### 运行阶段

| 现象 | 原因 | 解决 |
|---|---|---|
| 每天都被续期 | 阈值设得比证书有效期还大 | 检查该行 `renew=`，正常填 30 左右 |
| 证书续了但服务还用旧证书 | 没配 `renewpost.sh`（也没配 `SSL_RELOAD_CMD`） | 见第九节 |
| nginx 换了证书但浏览器还是旧的 | 用了 `reload`，旧 worker 没退 / 会话复用 | 改回 `restart`；验证加 `-no_ticket -no_reuse` |
| `renew.log` 里某天完全没记录，或 `ssl-status.sh` 报「触发过但没留下记录」 | 任务**没跑成** | `./ssl-status.sh`（自动对账）；`journalctl -u <unit>.service -n 200 --no-pager` |
| `renew.log` 空白，但脚本目录下有 `renew-fallback.log` | 配置还没解析出来就失败了（`ssl.conf` 缺失/非法） | 看 `renew-fallback.log` 最后一行的原因；`./ssl-issue.sh --check-only` |
| `ssl-status.sh` 报"不在域名列表里的证书" | `domains.conf` 删过域名，旧证书目录还在 | 确认无用后手动删除该目录 |
| `ssl-status.sh` 报 `ssl 定时器名字对不上：期望 X，但本机装的是 Y` | 本机装的是另一个 `SSL_UNIT_NAME` 的 timer | 改 `ssl.conf` 的 `SSL_UNIT_NAME` 为本机实际在用的那个 |
| 新加的域名没签发 | 只加了 `domains.conf` 没跑脚本 | 跑一次 `./ssl-issue.sh` |

### 后置钩子阶段（`renewpost.sh`）

| 报错 / 现象 | 原因 | 解决 |
|---|---|---|
| `bash: docker-compose: command not found` | systemd 触发时 PATH 被精简，找不到 docker | 顶部写死 `COMPOSE_BIN_OVERRIDE="/usr/local/bin/docker-compose"`（v2 用 `DOCKER_BIN_OVERRIDE`） |
| `compose 项目目录不存在：/root/docker/api` | `COMPOSE_DIR` 写错 | 改脚本顶部 `COMPOSE_DIR` |
| `没找到服务 xxx 的容器` | `COMPOSE_SERVICE` 与 compose 文件里的服务名不一致 | `cd` 到项目目录执行 `docker compose config --services` 看真实服务名 |
| 容器状态不是 `running` | 服务起不来（证书路径错、配置语法错…） | `docker compose logs --tail 50 <服务名>` |
| nginx `-t` 失败 | 证书路径写错 / 私钥权限 / SELinux | 手工跑 `nginx -t` 看具体行号；脚本此时**不会重启** nginx |
| 钩子失败但证书已更新 | 证书文件是好的，只是服务没切过去 | 手工跑 `bash renewpost.sh` 排查完，再 `systemctl start <unit>.service` |
| 日志里 `后置钩子=未配置` | 没有 `renewpost.sh` 也没配 `SSL_RELOAD_CMD` | 见第九节第 1 小节 |

---

## 十四、安全说明

- `secrets.env` 是**唯一**的敏感文件：只放 DNS 服务商的 API 凭据（可以多服务商、多账号），
  权限 600，已被 `.gitignore` 排除。脚本每次运行都会检查它的权限，过宽会告警。
  `.gitignore` 里还用了 `scripts/ssl*/secrets.env` 通配兜底 —— 以后新开的套件目录也自动覆盖。
- `renewpost.sh` 虽然不含密钥，但记录了你服务器的目录结构和服务名，同样已被 `.gitignore`
  排除；仓库里只放 `renewpost.sh.example.{nginx,docker}` 两个通用模板。
- `renew.log` 只记录张数、时间、模式，**不含任何密钥**，且位于证书目录（已被 gitignore）。
- **多账号之间的凭据是彼此隔离的**：脚本逐张切换凭据（且**先清空所有服务商的槽位**再写入目标），
  每张签发后自动清掉 acme.sh 在 `~/.acme.sh/account.conf` 里留下的密钥副本，
  不会出现"A 账号的密钥被用来签 B 账号的域名"。
- 所有证书和私钥都在输出目录下且已被 gitignore；私钥部署后自动 `chmod 600`。
- 日志里只出现 **ID 末 4 位**（例如 `尾号 …7f3a`）用于辨认账号，**从不打印 SecretKey**。
- 想手工确认没留副本：
  ```bash
  grep -c '^SAVED_' ~/.acme.sh/account.conf   # 应为 0
  ```
  不影响后续续期 —— 脚本每次签发前都会从 `secrets.env` 重新导出凭据。
- 强烈建议**每个账号都用子账号 + 仅 DNS 权限**的凭据，别用主账号密钥。
  这样一个账号的密钥泄露不会波及另一个账号。
- 验证凭据确实没进版本库：
  ```bash
  git check-ignore -v scripts/ssl/secrets.env   # 应输出忽略规则
  git check-ignore -v scripts/ssl/renewpost.sh  # 应输出忽略规则
  git grep -n 'AKID' $(git rev-list --all) 2>/dev/null   # 应无输出
  ```

---

## 十五、升级脚本：只换脚本，配置一律不许覆盖

| 类别 | 文件 | 升级时 |
|---|---|---|
| **脚本** | `lib.sh`、`ssl-issue.sh`、`ssl-status.sh`、`ssl-setup.sh`、`ssl-repair.sh`、`README.md` | ✅ 覆盖，随便传 |
| **模板**（可选） | `renewpost.sh.example.nginx`、`renewpost.sh.example.docker` | ✅ 覆盖；只在首次生成钩子时用一次 |
| **配置** | `secrets.env`、`domains.conf`、`ssl.conf`、`renewpost.sh` | ⛔ **绝不能覆盖** —— 传上去就把凭据/域名/unit 名/钩子清了 |
| 服务器本地 | `/etc/systemd/system/<SSL_UNIT_NAME>.{service,timer}`、输出目录下的证书、`renew.log` | ⛔ 不用管，也别重复 `ssl-setup.sh` |

```bash
# ① 先停 timer（一次签发可能跑几十秒，更新时正好被触发会很麻烦）
sudo systemctl stop <SSL_UNIT_NAME>.timer

# ② 本地传输（固定这几个脚本 + README）
scp lib.sh ssl-issue.sh ssl-status.sh ssl-setup.sh ssl-repair.sh README.md \
    root@<IP>:/opt/ssl/
#    若报 Text file busy：改成"传 .new 再原子替换"（见本节末「★ 治本」），别原地覆盖

# ③ 服务器上：修行尾 + 补执行位 + 语法检查（每次都要，别省）
cd /opt/ssl
sed -i 's/\r$//' *.sh
chmod +x ssl-issue.sh ssl-status.sh ssl-setup.sh ssl-repair.sh
bash -n lib.sh ssl-issue.sh ssl-status.sh ssl-setup.sh ssl-repair.sh && echo '语法 OK'

# ④ 确认配置还在（对一眼，确认没被覆盖）
ls -l secrets.env domains.conf ssl.conf renewpost.sh

# ⑤ 起 timer + 验收
sudo systemctl start <SSL_UNIT_NAME>.timer
systemctl list-timers <SSL_UNIT_NAME>.timer
./ssl-status.sh
```

### 报 `Text file busy` 怎么办

```
bash: ./ssl-status.sh: /usr/bin/env: bad interpreter: Text file busy
```

`ETXTBSY` 的机制：**`execve()` 的目标只要被任何进程以「写」方式打开，内核就拒绝执行它**
（`deny_write_access()` 保护，防止你执行一个"写到一半"的程序）。**和文件内容无关。**

> ⚠️ **报错里的 `/usr/bin/env` 是 bash 从 shebang 里读出来的解释器名，不等于元凶。**
> 这条检查**发生在解析 shebang 之前**，所以哪怕你把 shebang 改成 `#!/bin/bash`，
> 只要脚本文件本身被写占用，照样报 busy（只是报错里的解释器名换成了 `/bin/bash`）。
> 先判断 busy 的到底是**哪一级**，再对号入座：

```bash
/usr/bin/env bash -c 'echo env-ok'                              # env 本身正常吗
ls -l /proc/[0-9]*/fd/* 2>/dev/null | grep '/usr/bin/env'       # 有谁持有 env

ls -l /proc/[0-9]*/fd/* 2>/dev/null | grep 'ssl-status.sh'      # ★ 有谁持有脚本本身
cp ./ssl-status.sh /tmp/a.sh && chmod +x /tmp/a.sh && /tmp/a.sh # ★ 决定性：换 inode 后能否执行
```

| 实测结论 | 解法 |
|---|---|
| **`/tmp/a.sh` 能跑** + env 正常 ⇒ **脚本文件本身**被写占用 | **换 inode**（下面 ①）。**改 shebang 无效** —— 写占用检查发生在解析 shebang **之前** |
| env 那条就报 busy、或 `/proc` 里有人持有 env | 改 shebang 为 `#!/bin/bash` 绕开（下面 ⓪），再去揪持有 env 的进程 |

```bash
# ① 换 inode：解开"脚本文件被写占用"（首选，不必知道是谁占着）
cd /opt/ssl
for f in lib.sh ssl-issue.sh ssl-status.sh ssl-setup.sh ssl-repair.sh; do
  [ -f "$f" ] && cat "$f" > "$f.__new" && mv -f "$f.__new" "$f" && chmod +x "$f"
done
ls -l *.sh && bash -n *.sh && echo '语法 OK'

# ⓪ 顺带加固（治不了上面那种 busy）：shebang 换成 /bin/bash，少依赖一层 env
sed -i '1s|^#!/usr/bin/env bash|#!/bin/bash|' *.sh

# ② 临时救急：绕过 shebang（bash 用 open 读文件，不走 execve）
bash /opt/ssl/ssl-status.sh

# ③ 反查持有者（不依赖 lsof/fuser）
ls -l /proc/[0-9]*/fd/* 2>/dev/null | grep -E 'ssl-(status|issue)\.sh'
ps -ef | grep -E 'sftp|rsync|scp' | grep -v grep     # 没退干净的上传进程非常常见
```

**三个"为什么"**：

| 疑问 | 答案 |
|---|---|
| 换 inode 为什么有效？ | `mv` 同分区是**原子替换** —— 新文件是**新 inode**，旧 inode 连同它的写句柄一起留给还在用它的进程，互不干扰。 |
| `bash <脚本>` 为什么能跑？ | bash 用 `open(O_RDONLY)` **读**它再解释执行，**不调用 `execve`**，所以不触发写占用检查。 |
| 新开终端为什么没用？ | 占用是**内核里的 inode 状态**，与终端/会话无关；持有者不退出就永远不释放。 |

### "一直好好的，怎么突然就 busy 了？"——怎么推理

```
反复执行一直 OK   ⇒ 那之前根本不存在写句柄
从某一刻起开始报  ⇒ 写句柄是在那个时间段里出现的
```

先排除"是不是脚本自己写的"——本套脚本**从不以写方式打开 `.sh` 文件**
（`grep -n 'exec \|>>\|tee \|sed -i' *.sh` 只会命中 `>> "$SSL_RUN_LOG"` 和
`sed -i` 改 `~/.acme.sh/account.conf`）。所以持有者一定是**外部进程**：

| 常见持有者 | 为什么"恰好出现在某个时间段" |
|---|---|
| 上传工具（WinSCP / Xftp / MobaXterm / VS Code Remote 标签页） | **长期保持写句柄**；一旦你把文件拖进它的编辑器窗口，句柄就挂上了 —— 之后无论你做什么，`execve` 都被拒 |
| 上次 `scp` / `sftp` / `rz` 没退干净 | 传输进程残留，句柄没释放 |
| 安全软件 / 备份 agent 扫描 | 扫描期间短暂持有写句柄 |

**最容易踩的窗口是跑 `ssl-setup.sh` 那几十秒**：它要装 acme.sh、逐域名等 DNS 生效
（每张 `SSL_DNS_SLEEP` 秒），还会因为 `Timer` 带 `Persistent=true` 而**立刻触发一次 oneshot**
（`TimeoutStartSec=900`）。窗口越长，撞上外部写句柄的概率越大 —— 这就是
"`status` 反复跑都没事、`setup` 之后 `status` 就不行了"的典型成因。
恢复则是换 inode 之后：被占的旧 inode 留给了持有者，新 inode 干净可执行。

### 三条 30 秒定位实验（分清是哪一层出问题）

```bash
# A) 复制到别处再执行 —— 通过 ⇒ 内容没问题，就是"原 inode 被占"
cp /opt/ssl/ssl-status.sh /tmp/t.sh && chmod +x /tmp/t.sh && /tmp/t.sh | head -3

# B) 直接测解释器 —— 通过 ⇒ /usr/bin/env 本身没被占
/usr/bin/env bash -c 'echo env-ok'

# C) 绕过 shebang —— 通过 ⇒ 只是 exec 那一层的问题，文件内容是好的
bash /opt/ssl/ssl-status.sh | head -3
```

- **A 通过** ⇒ 用上面 ① 换 inode 即可，**不用管是谁占的**。
- **C 也失败** ⇒ 问题在 `/usr/bin/env`（或 `bash`）那头，用 ③ 的 greps 反查。
- **A/B/C 全失败** ⇒ 才轮到怀疑文件内容，用 `head -1 <文件> | od -c` 看 shebang 有没有 `\r`。

> ⚠️ 别把"多个脚本报同一个错"直接推断成"共同依赖坏了"。
> `execve` 的写占用检查是**逐文件**的：多个文件同时 busy，只能说明这些文件**同时**被写占用
> （同一次上传、同一个编辑器批量打开），**不能**推出"它们共用的解释器有问题"。
> 用上面 A/B/C 三条实验区分，别猜。

### ★ 治本：别直接覆盖正在使用的文件

`scp` 直接覆盖是"原地写"。**先传临时名、再原子替换**（`mv` 同分区原子，
旧 inode 留给还在用它的进程，互不干扰）：

```bash
scp ssl-status.sh root@<IP>:/opt/ssl/ssl-status.sh.new
cd /opt/ssl && mv -f ssl-status.sh.new ssl-status.sh && chmod +x ssl-status.sh
```

> **铁律**：不管怎么传，传完都要 `sed -i 's/\r$//' *.sh`（第十二节）。
