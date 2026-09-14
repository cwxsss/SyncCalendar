# SyncCalendar（同步日历）

一款以**同步为核心**的鸿蒙原生日历应用，基于 HarmonyOS NEXT（ArkTS / Stage 模型）开发。对接标准 CalDAV 服务器（群晖、Nextcloud、Radicale 等），让你的日程真正掌握在自己手里——不经过第三方云服务，数据始终同步在你自己的 NAS 上。

## ✨ 功能特性

### CalDAV 同步
- 支持 CalDAV 协议的完整同步：PROPFIND 发现日历本、REPORT 全量拉取、ETag 增量比对、PUT/DELETE 双向推送
- 一个账号可挂载多个日历本，按需勾选同步范围，支持在线编辑账号、重选日历本、删除账号
- 全链路同步引擎：拉取 → 解析（VEVENT / VTODO / VALARM / RRULE / EXDATE / RECURRENCE-ID）→ 本地库落库 → 推送变更

### 日历视图
- **月 / 周 / 日 / 列表 / 待办** 五种视图自由切换
- 月视图支持左右滑动翻月、农历显示（初一显示月名）、点击查看当日日程
- 重复日程（RRULE）按规则完整展开，支持 DAILY / WEEKLY / MONTHLY / YEARLY 及 INTERVAL、BYDAY、UNTIL、EXDATE 等
- 列表视图按天分组、今日置顶，配合 List 虚拟化保证流畅滚动
- VTODO 待办独立展示，未完成 / 已完成分组，勾选框颜色跟随日历本
- 可选**混合显示系统日历**，并与 DAV 数据自动去重

### 服务卡片
- 四种规格：**2x2 / 2x4 / 4x4 / 6x4**，时间轴样式设计
- 按天分组展示未来日程，组内全天事件置顶；跨天日程智能归入"今天"，标注"全天"
- 每条日程左侧竖条颜色与日历本一致，右侧显示所属日历本名
- 同步完成后自动刷新，formId 持久化保证 App 重启后推送不丢

### 日程提醒
- 自动读取服务器端 VALARM 提醒（如"开始前 10 分钟"）
- 基于**系统级代理提醒**（reminderAgentManager）发送通知，App 被杀、手机重启后依然生效，通知可右滑删除

## 🛠 技术要点

- **架构**：SyncEngine 同步引擎 + DavClient（HTTP/WebDAV）+ EventDb（relationalStore 本地库）+ CalendarDataService（多源合并展示）
- **服务卡片**：FormExtensionAbility + FormBindingData，JSON 数据驱动卡片渲染
- **农历算法**：1901–2099 压缩表推算
- **权限**：INTERNET / READ_CALENDAR / WRITE_CALENDAR / PUBLISH_AGENT_REMINDER

## 📦 快速开始

1. 使用 DevEco Studio 打开项目，连接鸿蒙真机或模拟器
2. 编译安装后进入「≡ → 账号管理」，添加你的 CalDAV 服务器地址、用户名和密码
3. 选择要同步的日历本，等待首次同步完成
4. 长按桌面空白处 → 添加服务卡片，选择 SyncCalendar 的卡片规格

## 📄 开源说明

本项目仅供学习交流使用。

该项目使用人工智能辅助完成。
