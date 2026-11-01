# optional/ —— 不随仓库分发的二进制载荷

仓库只放**源码级**的东西。下面两个目录是"放二进制的地方",`.gitignore` 已排除它们的内容,
你本地放进去、构建时用 `--payload-dir` 注入,**不会进 git**。

## 1. `optional/linux-tty/` —— TUI 控制台菜单(免 root / 免密运维菜单)

目录布局 = 目标机的根目录布局,`build.sh --payload-dir optional/linux-tty` 会整树并进 ISO 的
`files/`,再由 kickstart 的 `%post --nochroot` 拷进目标机。

```
optional/linux-tty/
├── usr/local/sbin/linux-tty            ← ★ 需要你自备的二进制(约 2.6 MB),仓库不含
├── usr/local/sbin/linux-root-shell     ← 已给
├── usr/local/bin/666                   ← 已给(快捷入口: exec linux-tty start)
└── etc/systemd/system/
    ├── linux-tty@.service              ← 已给
    └── getty@tty1.service.d/override.conf  ← 已给
```

把二进制放进去再构建:

```bash
install -m 0755 /path/to/linux-tty optional/linux-tty/usr/local/sbin/linux-tty
./build.sh CentOS-7-x86_64-Minimal-2009.iso out.iso --payload-dir optional/linux-tty
```

没有这个二进制也能正常构建安装 —— kickstart 的 console 段会检查
`/usr/local/sbin/linux-tty` 是否存在,不存在就打一行 `WARNING` 并跳过 enable,
tty1 保持系统的普通 getty(不会把控制台搞死)。

> 注意:只放 `linux-tty@.service` + getty override **而不放二进制**会让 tty1 起不来,
> 所以这两个 unit 才被放在 `optional/` 而不是 `overlay/`,避免"默认载荷缺件"。

## 2. `optional/vendor-rpm/` —— 阵列卡 / 硬盘健康度工具

布局对应目标机 `/tmp`(kickstart 的 `%post` 从 `/tmp/*.rpm` 装,装完删掉):

```
optional/vendor-rpm/tmp/
├── perccli-<ver>.noarch.rpm      Dell PERC(perccli64)
├── storcli-<ver>.noarch.rpm      LSI/Broadcom(STORCLI64)
├── ssacli-<ver>.x86_64.rpm       HPE Smart Array(ssacli)
├── smartmontools-<ver>.x86_64.rpm
├── mailx-<ver>.x86_64.rpm        smartmontools 的硬依赖
└── libcap-ng-<ver>.x86_64.rpm    mailx 的依赖
```

```bash
cp /path/to/*.rpm optional/vendor-rpm/tmp/
./build.sh CentOS-7-x86_64-Minimal-2009.iso out.iso --payload-dir optional/vendor-rpm
```

这些 rpm 都是厂商签名,安装时走"本地文件 `rpm -Uvh`",不经过 `gpgcheck=1` 的安装源。
缺哪个都不影响装机,对应的 `%post` 段会打印 `WARNING ... not found` 后继续。

## 3. 想注入别的东西?

`--payload-dir` 接受**任意**目录,只要按目标机根目录布局摆文件即可,例如自带监控 agent:

```
my-payload/
├── opt/myagent/myagent
└── etc/systemd/system/myagent.service
```

然后在 `overlay/isolinux/ks.cfg` 里加一段 `%post`(仓库版预留了注释位置)做
`systemctl enable myagent.service`。

> 载荷会被 `cp -rvpf /mnt/install/repo/files/. /mnt/sysimage/` 原样拷进目标机,
> 所以**权限要在源目录里就设好**(`install -m 0700`),别指望装完再 chmod。
