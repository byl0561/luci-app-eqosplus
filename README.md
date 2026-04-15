# luci-app-eqosplus

OpenWrt 定时网速限制插件。支持按 MAC/IP/IPv6/子网 限速，支持定时调度。

Fork 自 [sirpdboy/luci-app-eqosplus](https://github.com/sirpdboy/luci-app-eqosplus)，重构了底层架构，更适合低版本 OpenWrt。

## 与上游的区别

| | 上游 (sirpdboy) | 本项目 |
|--|----------------|--------|
| 流量分类 | nftables + tc u32 | **tc flower**（无防火墙依赖，VLAN 兼容，支持 IPv6） |
| 网络支持 | 单网络 | 多网络（按防火墙 zone 自动分区） |
| 旁路策略 | 无 | 同 zone 内不限速，跨 zone 限速 |
| 调试工具 | 无 | 日志 + 诊断 + 结构/流量测试 |
| 最低要求 | nftables (OpenWrt 22.03+) | **tc flower (OpenWrt 19.07+)** |

## 兼容性

| OpenWrt 版本 | 内核 | tc flower | 兼容性 |
|-------------|------|-----------|--------|
| 19.07 | 4.14 | cls_flower 可用 | 理论兼容 |
| 21.02 | 5.4 | cls_flower 可用 | **已测试** |
| 22.03 | 5.10 | cls_flower 可用 | 兼容 |
| 23.05 | 5.15 | cls_flower 可用 | 兼容 |
| 24.10 | 6.6 | cls_flower 可用 | 兼容 |

## 安装

### 从源码编译

```bash
# 在 OpenWrt SDK 目录下
git clone https://github.com/byl0561/luci-app-eqosplus.git package/luci-app-eqosplus
make package/luci-app-eqosplus/compile V=s
```

### 安装 ipk

```bash
opkg install luci-app-eqosplus_*.ipk
```

### 依赖

自动安装：`bash` `tc` `kmod-sched-core` `kmod-ifb` `kmod-sched` `kmod-sched-flower` `luci` `luci-base` `luci-compat`

可选（测试用）：`kmod-dummy`（结构测试）、`ip-full` + `kmod-veth`（流量测试）— 点击测试按钮时自动检测并安装

## 使用

### 基本操作

1. 进入 **网络 → 定时限速**
2. 勾选 **启用**
3. 在 **Configuration** 标签页下，选择需要管理的防火墙区域（默认仅 LAN）
4. 在对应网络接口下添加规则

> ⚠️ 如果安装了 turboacc 且开启了 `sw_flow` 或 `sfe_flow`（软件流量卸载），eqosplus 会拒绝启动并在界面显示冲突提示。请先关闭流量卸载功能。

### 区域选择

页面顶部的 **Visible Networks** 多选框列出所有非 WAN 防火墙区域。勾选后对应区域下的网络接口会显示配置表格。

- 默认仅勾选 **LAN** 区域
- 如需管理 Guest、IoT 等区域的设备，勾选对应区域即可
- WAN 区域不会出现在选项中
- 没有配置防火墙区域的虚拟网络（VPN、Docker 等）也不会出现

### 规则示例

| 场景 | IP/MAC 填写 | 下载(MB/s) | 上传(MB/s) | 时间 | 星期 | 备注 |
|------|------------|-----------|-----------|------|------|------|
| 限制单个设备 | `AA:BB:CC:DD:EE:FF` | 10 | 5 | 00:00-00:00 | 每天 | 孩子手机 |
| 限制单个 IP | `192.168.1.100` | 5 | 2 | 08:00-22:00 | 工作日 | |
| 限制 IPv6 地址 | `fd00::a1` | 5 | 2 | 00:00-00:00 | 每天 | |
| 限制 IPv4 子网(共享) | `192.168.10.0/24` | 20 | 10 | 00:00-00:00 | 每天 | |
| 限制 IPv6 子网(共享) | `fd00::/64` | 20 | 10 | 00:00-00:00 | 每天 | |
| 夜间限速 | `AA:BB:CC:DD:EE:FF` | 1 | 0.5 | 23:00-07:00 | 每天 | |

- 时间 `00:00-00:00` 表示全天生效
- 时间支持跨午夜（如 `23:00-07:00`），星期自动调整为起始日
- 下载/上传单位为 **MB/秒**（非 Mbit/秒）
- 子网规则下所有设备共享带宽
- MAC 限速同时覆盖 IPv4 和 IPv6 流量；IP/IPv6 限速仅针对指定协议
- 备注字段可选，用于标记规则用途
- 每个网络最多 50 条规则

### 调试

切换到 **Debug** 标签页：

- **日志级别**：选择 Info 或 Debug，实时查看日志输出
- **运行诊断**：查看当前 tc 规则状态（无活跃网络时会提示）
- **结构测试**：验证内核 tc 模块功能（需 kmod-dummy，自动安装）
- **流量测试**：验证端到端限速效果（需 ip-full + kmod-veth，自动安装）

### 命令行

```bash
/etc/init.d/eqosplus start|stop|restart   # 服务控制
eqosplus status                            # 查看 tc 规则
eqosplus log                               # 查看日志
```

## 技术说明

### 限速原理

```
下载: 互联网 → 路由 → FORWARD → br-lan egress → HTB(flower dst_mac/dst_ip/dst_ipv6 分类) → 设备
上传: 设备 → br-lan ingress → mirred → IFB egress → HTB(flower src_mac/src_ip/src_ipv6 分类) → 路由 → 互联网
```

- 下载方向：tc 挂在 br-lan 出口，flower 匹配目标 MAC/IP/IPv6
- 上传方向：仅受控设备的流量被 mirred 到 IFB，flower 匹配源 MAC/IP/IPv6
- 不受控设备：下载走 default class (fq_codel)，上传不经过 IFB

### 旁路策略（zone-based bypass）

启动时根据防火墙 zone 配置添加旁路规则：

- **同 zone 内**：自动检测同区域所有网络的 IPv4/IPv6 子网，添加 bypass 规则，互访不限速
- **跨 zone**：不同防火墙区域之间的流量正常限速
- **同子网设备互访**：二层直接转发，不经过 tc，天然不限速
- **设备访问路由器**（DHCP/DNS/LuCI）：bypass 规则通过 src_ip/dst_ip 匹配本地子网，不限速
- **设备通过路由器访问外网**：外网 IP 不在本地子网内，不匹配 bypass，正常限速

### 多设备共享

当多个网络绑定同一物理设备时：
- tc 基础设施（HTB qdisc/IFB）只创建一次，后续网络复用
- 每个网络的限速规则（class/filter）独立，互不冲突
- 最后一个网络停止时才拆除基础设施

### 启动时自动清理

每次服务启动会校验 UCI 中的限速规则，自动删除引用了已不存在网络的孤儿配置。

### 文件结构

```
/usr/lib/eqosplus/core.sh           共享 tc 操作库（init/teardown/add/del/bypass）
/usr/lib/eqosplus/sched.sh          调度判定（时间段 + 星期校验）
/usr/lib/eqosplus/idlist_helpers.sh  IDLIST 文件原子增删操作
/usr/lib/eqosplus/uci_helpers.sh     UCI 值反引号解析
/usr/lib/eqosplus/testlib.sh        测试断言框架（assert/assert_fail/tc_has）
/usr/bin/eqosplus              主脚本（UCI 读取 + 调用 core.sh）
/usr/bin/eqosplusctrl          定时守护进程（30秒轮询）
/usr/bin/eqosplus_test         结构测试（调用 core.sh，dummy 设备）
/usr/bin/eqosplus_traffic_test 流量测试（调用 core.sh，veth + namespace）
/etc/init.d/eqosplus           服务管理（procd，含 reload_service）
/etc/hotplug.d/iface/10-eqosplus  接口变化时按接口 resync（非全量重启）
/etc/config/eqosplus           配置文件
/tmp/eqosplus.log              运行日志
```

## 许可证

GPL v2

## 致谢

- [sirpdboy](https://github.com/sirpdboy/luci-app-eqosplus) — 原始项目作者
