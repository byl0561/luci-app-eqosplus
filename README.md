# luci-app-eqosplus - OpenWrt 定时限速插件

[![License](https://img.shields.io/badge/license-GPL%20v2-blue.svg)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-Compatible-green.svg)](https://openwrt.org/)

一个功能强大的 OpenWrt LuCI 定时限速插件，支持基于 MAC 地址和 IP 地址的智能网速控制，具备定时调度和多种时间模式。

## 📋 功能特性

### 🚀 核心功能
- **多接口支持**: 支持多个网络接口上的设备同时进行限速控制
- **双重识别**: 支持 MAC 地址和 IP 地址两种设备识别方式
- **定时控制**: 精确的时间调度，支持自定义起控和停控时间
- **灵活时间模式**: 支持每日、工作日、休息日、自定义星期等多种时间模式
- **IPv4/IPv6 兼容**: 同时支持 IPv4 和 IPv6 网络环境
- **实时状态监控**: Web 界面实时显示服务运行状态

### ⏰ 定时功能
- **精确时间控制**: 支持 HH:MM 格式的时间设置
- **多星期模式**:
  - 每日 (0)
  - 单日 (1-7: 周一到周日)
  - 工作日 (1,2,3,4,5)
  - 休息日 (6,7)
  - 自定义组合 (如: 1,3,5)
- **自动调度**: 后台守护进程每30秒检查一次时间条件

### 🎯 限速特性
- **双向限速**: 独立设置上传和下载速度限制
- **单位灵活**: 速度单位支持 MB/秒
- **零限速支持**: 支持设置为0来取消限速
- **智能过滤**: 使用 Linux TC (Traffic Control) 和 iptables 实现精确流量控制

## 🛠️ 技术架构

### 核心组件
- **eqosplus**: 主控制脚本，负责 TC 规则管理
- **eqosplusctrl**: 定时控制守护进程
- **LuCI 界面**: Web 管理界面
- **UCI 配置**: 基于 OpenWrt 统一配置接口

### 依赖组件
- `bash`: Shell 脚本执行环境
- `tc`: Linux 流量控制工具
- `kmod-sched-core`: 内核调度模块
- `kmod-ifb`: 中间功能块模块
- `iptables-mod-filter`: iptables 过滤模块
- `iptables-mod-nat-extra`: iptables NAT 扩展模块

## 📦 安装说明

### 从源码编译
```bash
# 克隆仓库
git clone https://github.com/byl0561/luci-app-eqosplus.git

# 进入项目目录
cd luci-app-eqosplus

# 编译安装
make package/luci-app-eqosplus/compile V=s
```

### 手动安装
1. 下载对应的 `.ipk` 安装包
2. 通过 LuCI 界面或命令行安装：
```bash
opkg install luci-app-eqosplus_*.ipk
```

## 🎮 使用指南

### 基本配置
1. 登录 OpenWrt Web 管理界面
2. 导航至 `服务` → `定时限速`
3. 启用服务开关
4. 为每个网络接口配置限速规则

### 规则配置
- **设备识别**: 输入 MAC 地址或 IP 地址
- **速度限制**: 设置上传/下载速度 (MB/秒)
- **时间控制**: 设置起控时间和停控时间
- **星期选择**: 选择适用的星期模式
- **备注**: 添加规则描述便于管理

### 高级功能
- **多接口管理**: 支持 LAN、WAN 等多个接口独立配置
- **实时监控**: 查看当前运行状态和统计信息
- **自动重启**: 系统每天凌晨1点自动重启服务

## ⚙️ 配置示例

### 配置文件位置
- 主配置: `/etc/config/eqosplus`
- 状态文件: `/var/eqosplus.idlist`
- 网络列表: `/var/eqosplus.networks`

### 典型配置
```bash
# 启用服务
config eqosplus
    option service_enable '1'

# LAN 接口限速规则
config network_lan 'rule1'
    option enable '1'
    option mac 'AA:BB:CC:DD:EE:FF'
    option download '5'
    option upload '2'
    option timestart '08:00'
    option timeend '18:00'
    option week '1,2,3,4,5'
    option comment '工作日限速'
```

## 🔧 命令行工具

### 服务控制
```bash
# 启动服务
/etc/init.d/eqosplus start

# 停止服务
/etc/init.d/eqosplus stop

# 重启服务
/etc/init.d/eqosplus restart
```

### 手动控制
```bash
# 添加限速规则
eqosplus add network_lan[0]

# 删除限速规则
eqosplus del network_lan[0]

# 查看状态
eqosplus status
```

## 🐛 故障排除

### 常见问题
1. **服务无法启动**: 检查依赖模块是否已安装
2. **限速不生效**: 确认设备 MAC/IP 地址正确
3. **时间控制异常**: 检查系统时间是否正确
4. **多接口冲突**: 确保不同接口使用不同的网络配置

### 调试模式
启用调试输出：
```bash
# 编辑 eqosplus 脚本，设置 DEBUG=1
DEBUG=1
```

### 日志查看
```bash
# 查看服务状态
logread | grep eqosplus

# 查看 TC 规则
tc -s qdisc show
tc -s class show
```

## 🤝 贡献指南

欢迎提交 Issue 和 Pull Request！

1. Fork 本仓库
2. 创建功能分支
3. 提交更改
4. 发起 Pull Request

## 📄 许可证

本项目基于 GPL v2 许可证开源。详见 [LICENSE](LICENSE) 文件。

## 👥 维护者

- **lava** <byl0561@gmail.com>
- **sirpdboy** <herboy2008@gmail.com> (原始作者)

## 🔗 相关链接

- [GitHub 仓库](https://github.com/byl0561/luci-app-eqosplus)
- [OpenWrt 官方文档](https://openwrt.org/docs)
- [LuCI 开发指南](https://openwrt.org/docs/guide-developer/luci)

---

**注意**: 使用前请仔细阅读配置说明，错误的配置可能影响网络连接。建议在测试环境中先行验证。