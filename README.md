# luci-app-eqosplus

OpenWrt 定时网速 / 连接数限制插件。

Fork 自 [sirpdboy/luci-app-eqosplus](https://github.com/sirpdboy/luci-app-eqosplus)，重构了底层架构，更适合低版本 OpenWrt。

> 当前版本：**2.3.0**

## 功能

### 限速（tc / HTB + IFB + flower）

- 按 **MAC / IP / IPv6 / 子网** 限速，支持 IPv4 和 IPv6
- 上行 / 下行独立配置（MB/s）
- MAC 规则同时覆盖 IPv4/IPv6；IP 规则仅针对对应协议族

### 连接数限制（v2.3 新增，conntrack-based）

- **入站连接数**（`Conn In`）：被外部连接到本设备的并发连接上限。适用于 PCDN、内网服务、端口转发后端等"被动接受连接"的设备
- **出站连接数**（`Conn Out`）：本设备主动发起的并发连接上限。适用于防 BT/P2P/扫描类滥用打爆 NAT 表
- **TCP-only 开关**（默认开）：勾选时只统计 TCP 连接；取消勾选则统计全部协议（TCP+UDP+ICMP+...）
- 双后端自适应：fw4（nftables）/ fw3（iptables + ipset）由安装时自动探测并落 UCI
- **MAC 标识符不支持限连接数**（FORWARD 链 L2 daddr 不可匹配 LAN 设备 MAC，机制限制）；UI 自动灰显

### 通用

- **定时调度**：按时间段 + 星期（多选）生效，支持跨午夜
- **多网络管理**：按防火墙区域自动分组（LAN / Guest / IoT …）
- **同区域免限速 / 免限连接**：同一防火墙区域内设备互访不受规则约束
- **fw3 reload / fw4 stop 自愈**：daemon 30 秒周期检测内核状态，丢失自动重建
- 内置日志、诊断、结构测试和真实流量测试工具
- 兼容 OpenWrt 19.07 ~ 24.10

## 安装

```bash
# 从源码编译（在 OpenWrt SDK 目录下）
git clone https://github.com/byl0561/luci-app-eqosplus.git package/luci-app-eqosplus
make package/luci-app-eqosplus/compile V=s

# 或直接安装 ipk
opkg install luci-app-eqosplus_*.ipk
```

依赖自动安装。测试功能所需的可选包（`kmod-dummy`、`ip-full`、`kmod-veth`）在点击测试按钮时自动检测并安装。

## 使用

1. 进入 **网络 → 定时限速**，勾选 **启用**
2. 在 **配置** 标签页选择要管理的防火墙区域（默认 LAN）
3. 添加规则

### 规则示例

| 场景 | IP/MAC | 下载 MB/s | 上传 MB/s | 入站连接 | 出站连接 | 仅 TCP | 时段 | 周期 |
|------|--------|----|----|----|----|----|------|------|
| 限制单个设备 | `AA:BB:CC:DD:EE:FF` | 10 | 5 | — | — | — | 00:00~00:00 | 一~日 |
| 限制单个 IP | `192.168.1.100` | 5 | 2 | 0 | 0 | ✓ | 08:00~22:00 | 一~五 |
| 子网共享带宽 | `192.168.10.0/24` | 20 | 10 | 0 | 0 | ✓ | 00:00~00:00 | 一~日 |
| 夜间限速 | `AA:BB:CC:DD:EE:FF` | 1 | 0.5 | — | — | — | 23:00~07:00 | 一~日 |
| **PCDN 入站限连** | `192.168.1.200` | 0 | 0 | 2000 | 200 | ✗ | 00:00~00:00 | 一~日 |
| **防 BT 出站滥用** | `192.168.1.150` | 0 | 0 | 0 | 100 | ✓ | 00:00~00:00 | 一~日 |

- 开始/结束均为 `00:00` = 全天生效
- 跨午夜时间（如 23:00→07:00）自动处理
- 速度单位为 **MB/秒**，连接数为整数，每个网络最多 50 条规则
- 选中 **MAC** 时，入站 / 出站连接数输入框自动变灰且锁定为 0；想限连接数请改用 IP/CIDR

### 连接数限制的语义

- **"一条连接" = conntrack 表里一条 5-tuple 记录**（每个流不论方向只算一次）
- 出站方向匹配"原始方向源 IP = 设备"——和 LuCI 自带的"按设备连接数显示"口径完全一致
- 入站方向匹配"原始方向目的 IP = 设备"——只对端口转发进来的流量生效
- 双栈设备：IPv4 入站和 IPv6 入站**独立计数**（每个家族各自限到 N，理论合计上限 2N）
- CIDR 标识符：限制是**子网级共享额度**（整个 CIDR 共用一个 N）

### 命令行

```bash
/etc/init.d/eqosplus start|stop|restart
eqosplus status         # 查看当前 tc 规则
eqosplus log            # 查看日志
eqosplus conn_reload    # 手动重建连接数限制（防火墙重启后自动调用）
```

> ⚠️ 与 TurboACC 软件流量卸载（sw_flow / sfe_flow）冲突，需先关闭。

## 部署形态

支持任意拓扑，规则都在 host 路由器的 FORWARD 链上生效：

- **主路由（旁路前置）**：CGNAT/PPPoE 上游，LAN 终端经它出网。MAC 限速 + IP 限连均可用。
- **单臂路由（PCDN 子路由）**：单一 LAN 口，流量通过该接口进出。`iifname == oifname` 仍走 FORWARD，规则正常生效。
- **跨 VLAN 路由**：不同 VLAN 间路由，FORWARD 双臂触发。同区域则被同区域 bypass 放行。

详见 [`ARCHITECTURE.md`](ARCHITECTURE.md) 第 5–7 节的拓扑图。

## 故障排查

| 现象 | 检查方向 |
|------|---------|
| 限速不生效 | `eqosplus status` 看 tc class；如冲 TurboACC 关掉 sw_flow/sfe_flow |
| 限连接数不生效 | fw4：`nft list table inet eqosplus`；fw3：`iptables -L eqos_forward -nv`；都没 → daemon 30s 内会自愈 |
| 选 MAC 后入站/出站连接数灰显 | 设计如此（MAC 不支持限连接数），改用 IP/CIDR |
| 防火墙重启后规则消失 | 等 30 秒，daemon 自动重建；或手动 `eqosplus conn_reload` |
| 连接数显示不一致 | LuCI 自带的"按设备连接数"只算出站；我们的 conn_in 是入站独立计数 |

## 文档

- [`ARCHITECTURE.md`](ARCHITECTURE.md)：组件架构图、各种数据流时序图、内核数据结构、代码-图对应表、Review 检查清单

## 版本历史

- **2.3.0**（current）—— 新增连接数限制（conn_in / conn_out + tcp_only），支持 fw3/fw4 双后端，UCI 字段 `mac` → `target` 重命名（向后兼容），UI 多选下拉色彩跨主题适配（含 luci-theme-argon 浅/深双模），daemon 周期 sanity probe 自愈防火墙重启，测试隔离改造（不再污染生产规则）
- **2.2.0** —— 重构底层架构，更适合低版本 OpenWrt
- 之前 —— 见 fork 源 [sirpdboy/luci-app-eqosplus](https://github.com/sirpdboy/luci-app-eqosplus)

## 许可证

GPL v2

## 致谢

- [sirpdboy](https://github.com/sirpdboy/luci-app-eqosplus) —— 原始项目作者
