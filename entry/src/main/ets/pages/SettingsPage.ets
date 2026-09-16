// entry/src/main/ets/pages/SettingsPage.ets
// 设置页：系统日历模式（仅显示/备份到 CalDAV）+ 混合显示开关 + 自动同步间隔 + 后台同步
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { AppSettings } from '../common/AppSettings';
import { CardDataService } from '../common/CardDataService';
import { BackgroundSyncService } from '../common/BackgroundSyncService';
import { AccountStore, DavAccount } from '../common/AccountStore';
import { ReminderService } from '../common/ReminderService';
import { DocViewer } from '../common/DocViewer';

const INTERVAL_OPTIONS: number[] = [1, 5, 15, 30, 60];

/** 日历本选项（备份目标 / 只读标记 / 静音标记共用） */
class BackupTarget {
  calKey: string = '';
  label: string = '';
  serverWritable: boolean = true; // 服务器探测结果
}

@Entry
@Component
struct SettingsPage {
  @State showSystem: boolean = true;
  @State intervalMinutes: number = 1;
  @State backgroundSync: boolean = false;
  @State sysMode: string = 'display'; // display | backup
  @State backupKey: string = '';
  @State backupTargets: BackupTarget[] = [];
  @State allBooks: BackupTarget[] = []; // 全部 DAV 日历本（只读/静音标记管理用）
  @State manualKeys: string[] = [];     // 手动标记只读的 calKey
  @State mutedKeys: string[] = [];      // 提醒静音的 calKey
  @State notifyEnabled: boolean = true; // 通知权限状态（提醒依赖）
  @State showLegal: boolean = false;    // 隐私政策与用户协议弹层
  // 内置文档浏览器（《隐私政策》/《用户服务协议》/《软件特性》/《使用帮助》）：整页 Web 覆盖层
  @State showDoc: boolean = false;
  @State docTitle: string = '';
  @State docUrl: string = '';
  @State defaultView: string = 'month';  // 打开 App 默认视图：month | week | agenda
  @State displayStyle: string = 'timeline'; // 日程显示方式：timeline（时间轴）| list（列表）
  private context?: common.Context;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    this.context = ctx;
    AppSettings.getShowSystemCalendar(ctx).then((v: boolean): void => {
      this.showSystem = v;
    });
    AppSettings.getSyncIntervalMinutes(ctx).then((v: number): void => {
      this.intervalMinutes = v;
    });
    AppSettings.getBackgroundSync(ctx).then((v: boolean): void => {
      this.backgroundSync = v;
    });
    AppSettings.getSysCalMode(ctx).then((v: string): void => {
      this.sysMode = v;
    });
    AppSettings.getManualReadonlyKeys(ctx).then((v: string[]): void => {
      this.manualKeys = v;
    });
    AppSettings.getMutedReminderKeys(ctx).then((v: string[]): void => {
      this.mutedKeys = v;
    });
    AppSettings.getDefaultView(ctx).then((v: string): void => {
      this.defaultView = v;
    });
    AppSettings.getDisplayStyle(ctx).then((v: string): void => {
      this.displayStyle = v;
    });
    this.refreshNotifyState();
    this.loadBackupSettings();
    this.loadAllBooks();
  }

  /** 重新检测通知权限状态 */
  private refreshNotifyState(): void {
    notificationManager.isNotificationEnabled()
      .then((v: boolean): void => {
        this.notifyEnabled = v;
      })
      .catch((): void => {
        this.notifyEnabled = false;
      });
  }

  /** 加载全部 DAV 日历本（含探测到的写权限，只读/静音标记管理用） */
  private async loadAllBooks(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const accounts: DavAccount[] = await AccountStore.loadAll(this.context);
    const books: BackupTarget[] = [];
    for (const acc of accounts) {
      if (acc.type !== 'caldav') {
        continue;
      }
      for (let i = 0; i < acc.calendarHrefs.length; i++) {
        const b = new BackupTarget();
        b.calKey = `${acc.id}_${i}`;
        const bookName: string = i < acc.calendarNames.length ? acc.calendarNames[i] : `日历本 ${i + 1}`;
        b.label = `${acc.name} · ${bookName}`;
        b.serverWritable = acc.calendarWritable.length > i ? acc.calendarWritable[i] !== '0' : true;
        books.push(b);
      }
    }
    this.allBooks = books;
  }

  /** 该日历本是否只读：服务器无写权限（探测结果）或用户手动标记只读 —— 与首页色块/只读标记同一口径 */
  private isBookReadonly(b: BackupTarget): boolean {
    return !b.serverWritable || this.manualKeys.includes(b.calKey);
  }

  /** 手动标记/取消只读 */
  private async toggleManualBook(b: BackupTarget): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const list: string[] = [...this.manualKeys];
    const idx: number = list.indexOf(b.calKey);
    if (idx >= 0) {
      list.splice(idx, 1);
    } else {
      list.push(b.calKey);
    }
    this.manualKeys = list;
    await AppSettings.setManualReadonlyKeys(this.context, list);
    await this.loadBackupSettings(); // 备份目标候选同步排除
    this.getUIContext().getPromptAction().showToast({
      message: idx >= 0 ? '已恢复为可写，返回首页生效' : '已标记为只读，返回首页生效'
    });
  }

  /** 切换日历本提醒静音：静音后该本所有日程不再发布系统提醒 */
  private async toggleMuteBook(b: BackupTarget): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const list: string[] = [...this.mutedKeys];
    const idx: number = list.indexOf(b.calKey);
    if (idx >= 0) {
      list.splice(idx, 1);
    } else {
      list.push(b.calKey);
    }
    this.mutedKeys = list;
    await AppSettings.setMutedReminderKeys(this.context, list);
    // 立即重建提醒（全量取消后按新静音规则重发），无需等下次同步
    try {
      await ReminderService.refreshReminders(this.context as common.UIAbilityContext);
    } catch (err) {
      // 重建失败不影响设置保存，下次同步时会再刷新
    }
    this.getUIContext().getPromptAction().showToast({
      message: idx >= 0
        ? '已恢复提醒'
        : '已静音：该日历本的所有日程不再提醒'
    });
  }

  /** 加载备份目标候选（可写 DAV 日历本）+ 当前选择 */
  private async loadBackupSettings(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const accounts: DavAccount[] = await AccountStore.loadAll(this.context);
    const targets: BackupTarget[] = [];
    for (const acc of accounts) {
      if (acc.type !== 'caldav') {
        continue;
      }
      for (let i = 0; i < acc.calendarHrefs.length; i++) {
        const writable: boolean = acc.calendarWritable.length > i
          ? acc.calendarWritable[i] !== '0' : true;
        if (!writable) {
          continue;
        }
        const t = new BackupTarget();
        t.calKey = `${acc.id}_${i}`;
        const bookName: string = i < acc.calendarNames.length ? acc.calendarNames[i] : `日历本 ${i + 1}`;
        t.label = `${acc.name} · ${bookName}`;
        t.serverWritable = writable;
        targets.push(t);
      }
    }
    // 手动标记只读的本不可作为备份目标
    const manual: string[] = await AppSettings.getManualReadonlyKeys(this.context);
    this.backupTargets = targets.filter((t: BackupTarget): boolean => !manual.includes(t.calKey));
    const saved: string = await AppSettings.getBackupCalKey(this.context);
    this.backupKey = targets.some((t: BackupTarget): boolean => t.calKey === saved) ? saved : '';
  }

  private async saveSysMode(mode: string): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    this.sysMode = mode;
    await AppSettings.setSysCalMode(this.context, mode);
    if (mode === 'backup' && this.backupKey === '') {
      if (this.backupTargets.length > 0) {
        this.backupKey = this.backupTargets[0].calKey;
        await AppSettings.setBackupCalKey(this.context, this.backupKey);
      }
    }
    this.getUIContext().getPromptAction().showToast({
      message: mode === 'backup'
        ? '已开启备份：下次同步时把系统本地日程导入所选日历本'
        : '已切换为仅显示：不再把系统日程备份到 CalDAV'
    });
  }

  private async saveBackupTarget(calKey: string): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    this.backupKey = calKey;
    await AppSettings.setBackupCalKey(this.context, calKey);
    this.getUIContext().getPromptAction()
      .showToast({ message: '备份目标已更新，下次同步生效' });
  }

  private async saveShowSystem(value: boolean): Promise<void> {    if (this.context === undefined) {
      return;
    }
    await AppSettings.setShowSystemCalendar(this.context, value);
    this.getUIContext().getPromptAction()
      .showToast({ message: value ? '已开启系统日历混合显示，返回首页生效' : '已关闭系统日历混合显示，返回首页生效' });
  }

  private async saveInterval(minutes: number): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    await AppSettings.setSyncIntervalMinutes(this.context, minutes);
    AppStorage.setOrCreate('syncIntervalMinutes', minutes);
    this.getUIContext().getPromptAction()
      .showToast({ message: `自动同步间隔已设为 ${minutes} 分钟` });
  }

  private async saveBackgroundSync(value: boolean): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    try {
      await BackgroundSyncService.setBackgroundSync(
        this.context as common.UIAbilityContext, value);
      this.getUIContext().getPromptAction().showToast({
        message: value
          ? '后台持续同步已开启，通知栏将显示常驻通知'
          : '后台持续同步已关闭'
      });
    } catch (err) {
      this.backgroundSync = !value; // 失败回滚 UI
      const msg: string = (err as BusinessError).message !== ''
        ? (err as BusinessError).message : '请重试';
      this.getUIContext().getPromptAction().showToast({ message: `开启失败：${msg}` });
    }
  }

  private async saveDefaultView(view: string): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    this.defaultView = view;
    await AppSettings.setDefaultView(this.context, view);
    const label: string = view === 'month' ? '月视图' : (view === 'week' ? '周视图' : '列表视图');
    this.getUIContext().getPromptAction()
      .showToast({ message: `默认视图已设为「${label}」，下次打开 App 生效` });
  }

  private defaultViewLabel(): string {
    return this.defaultView === 'month' ? '月视图'
      : (this.defaultView === 'week' ? '周视图' : '列表视图');
  }

  private async saveDisplayStyle(style: string): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    this.displayStyle = style;
    await AppSettings.setDisplayStyle(this.context, style);
    // 同步刷桌面卡片：让 4×4 / 6×4 卡片立刻按新方式重绘（列表模式去掉红线）
    try {
      await CardDataService.pushToAllForms(this.context);
    } catch (err) {
      // 卡片刷新失败不影响设置保存，下次同步或卡片自刷新时会生效
    }
    this.getUIContext().getPromptAction().showToast({
      message: style === 'list'
        ? '已切换为列表显示（不显示当前时间红线）'
        : '已切换为时间轴显示'
    });
  }

  private intervalLabel(minutes: number): string {
    return minutes >= 60 ? `${minutes / 60} 小时` : `${minutes} 分钟`;
  }

  /** 确认后重置全量重拉标记，下次同步重建全部日程数据 */
  private askRebuildData(): void {
    this.getUIContext().showAlertDialog({
      title: '重建日程数据',
      message: '将重新从服务器拉取所有日程的完整数据（包括提醒），本地已修改未同步的内容不受影响。\n\n全量拉取可能需要几分钟，期间请保持 App 在前台、不要熄屏。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '开始重建',
        action: (): void => {
          this.doRebuildData();
        }
      }
    });
  }

  private async doRebuildData(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    await AppSettings.resetFullRefetch(this.context);
    this.getUIContext().getPromptAction().showToast({
      message: '已开启，返回首页后点一次同步即可，请保持屏幕常亮'
    });
  }

  /** 确认后清空本地账号库（密码一并删除不可恢复；服务器日程不受影响） */
  private askResetVault(): void {
    this.getUIContext().showAlertDialog({
      title: '重置账号库',
      message: '将删除本机保存的全部账号、服务器地址与密码，回到"还没添加过账号"的状态。\n\n'
        + '日历数据保存在你的 CalDAV 服务器上，不受影响：重新添加账号并同步一次即可恢复。\n\n'
        + '本操作不可撤销（本地密码会一并删除），仅在账号读不出来、也无法新增账号时使用。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '确认重置',
        action: (): void => {
          this.doResetVault();
        }
      }
    });
  }

  private async doResetVault(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    try {
      await AccountStore.resetVault(this.context);
      this.getUIContext().getPromptAction().showToast({
        message: '账号库已重置，请重新添加账号'
      });
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({
        message: '重置失败，请稍后重试'
      });
    }
  }

  /** 去系统设置开启本应用通知 */
  private async openNotifySettings(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    try {
      await notificationManager.requestEnableNotification(this.context as common.UIAbilityContext);
      this.refreshNotifyState(); // 返回后重新检测状态
    } catch (err) {
      // 用户取消或未跳转，状态保持原样
    }
  }

  /**
   * 打开外部链接（隐私政策 / 用户服务协议 / 开源仓库）。
   * 仅放行 http(s)：避免 URL 被篡改或误传为 file://、自定义 scheme、intent 类 URI 时，
   * 拉起本地文件或任意第三方应用 —— 把"打开网页"严格限定在预期范围内。
   */
  private async openUrl(url: string): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    if (!url.startsWith('https://') && !url.startsWith('http://')) {
      this.getUIContext().getPromptAction().showToast({ message: '仅支持打开 http(s) 链接' });
      return;
    }
    try {
      await (context as common.UIAbilityContext).openLink(url);
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开链接' });
    }
  }

  /**
   * 用内置浏览器（整页 Web 覆盖层）打开法律文档 —— 不跳出应用、随时可关闭。
   * 先收起"隐私政策与用户协议"弹层，再显示覆盖层，避免两层叠在一起看不清。
   */
  private openDoc(title: string, url: string): void {
    if (!url.startsWith('https://') && !url.startsWith('http://')) {
      this.getUIContext().getPromptAction().showToast({ message: '仅支持打开 http(s) 链接' });
      return;
    }
    this.showLegal = false;
    this.docTitle = title;
    this.docUrl = url;
    this.showDoc = true;
  }

  build() {
    Stack() {
      Column() {
      // 顶部
      Row({ space: 10 }) {
        Text('←')
          .fontSize(20)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            router.back();
          })
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // 系统日历模式：仅显示 / 备份到 CalDAV
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('系统日历')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('选择手机系统日历日程的处理方式')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            Select([{ value: '仅显示（不做备份）' }, { value: '备份到 CalDAV 日历本' }] as SelectOption[])
              .selected(this.sysMode === 'backup' ? 1 : 0)
              .value(this.sysMode === 'backup' ? '备份到 CalDAV 日历本' : '仅显示（不做备份）')
              .fontColor($r('app.color.text_primary'))
              .font({ size: 14 })
              .optionFont({ size: 14 })
              .selectedOptionFont({ size: 14 })
              .width('100%')
              .onSelect((index: number) => {
                const mode: string = index === 1 ? 'backup' : 'display';
                if (mode !== this.sysMode) {
                  this.saveSysMode(mode);
                }
              })
            if (this.sysMode === 'backup') {
              Text(this.backupTargets.length > 0
                ? '备份目标（可写日历本）：导入后随同步上传服务器，换机/丢失也有备份'
                : '没有可写的 CalDAV 日历本，请先添加账号或检查日历本权限')
                .fontSize(12)
                .fontColor(this.backupTargets.length > 0
                  ? $r('app.color.text_secondary') : $r('app.color.error'))
                .width('100%')
              if (this.backupTargets.length > 0) {
                Select(this.backupTargets.map((t: BackupTarget): SelectOption => {
                  return { value: t.label } as SelectOption;
                }) as SelectOption[])
                  .selected(this.backupTargets.findIndex((t: BackupTarget): boolean => t.calKey === this.backupKey))
                  .value(this.backupTargets.find((t: BackupTarget): boolean => t.calKey === this.backupKey)?.label
                    ?? '请选择日历本')
                  .fontColor($r('app.color.text_primary'))
                  .font({ size: 14 })
                  .optionFont({ size: 14 })
                  .selectedOptionFont({ size: 14 })
                  .width('100%')
                  .onSelect((index: number) => {
                    if (index >= 0 && index < this.backupTargets.length) {
                      this.saveBackupTarget(this.backupTargets[index].calKey);
                    }
                  })
              }
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 默认视图：打开 App 后默认展示的视图（月/周/列表）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('默认视图')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('打开 App 后默认展示的视图（月 / 周 / 列表）')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Select([{ value: '月视图' }, { value: '周视图' }, { value: '列表视图' }] as SelectOption[])
                .selected(this.defaultView === 'month' ? 0 : (this.defaultView === 'week' ? 1 : 2))
                .value(this.defaultViewLabel())
                .fontColor($r('app.color.text_primary'))
                .font({ size: 14 })
                .optionFont({ size: 14 })
                .selectedOptionFont({ size: 14 })
                .onSelect((index: number) => {
                  const v: string = index === 0 ? 'month' : (index === 1 ? 'week' : 'agenda');
                  if (v !== this.defaultView) {
                    this.saveDefaultView(v);
                  }
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 日程显示方式：时间轴 / 列表（同时作用于主界面与桌面卡片）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('日程显示方式')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('时间轴：按时间刻度看一天的占用与冲突；列表：快速扫读、适合长标题。列表模式不显示当前时间红线')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Select([{ value: '时间轴' }, { value: '列表' }] as SelectOption[])
                .selected(this.displayStyle === 'list' ? 1 : 0)
                .value(this.displayStyle === 'list' ? '列表' : '时间轴')
                .fontColor($r('app.color.text_primary'))
                .font({ size: 14 })
                .optionFont({ size: 14 })
                .selectedOptionFont({ size: 14 })
                .onSelect((index: number) => {
                  const v: string = index === 1 ? 'list' : 'timeline';
                  if (v !== this.displayStyle) {
                    this.saveDisplayStyle(v);
                  }
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 数据修复：手动触发一次性全量重拉（重建提醒等本地残缺字段）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('重建日程数据')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('同步时重新从服务器拉取全部日程的完整数据，修复提醒丢失等本地数据问题。耗时段落请保持 App 在前台、屏幕常亮')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button('重建')
                .fontSize(13)
                .backgroundColor($r('app.color.brand'))
                .onClick(() => {
                  this.askRebuildData();
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 逃生舱：账号库读不出来（密钥丢失/失效）时，只清账号，不动设置与日程
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('重置账号库')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('清空本机保存的账号、服务器地址与密码。服务器上的日程不受影响，重新添加账号并同步即可恢复。仅在账号读不出来、也无法新增账号时使用')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button('重置')
                .fontSize(13)
                .backgroundColor($r('app.color.error'))
                .onClick(() => {
                  this.askResetVault();
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 混合显示系统日历
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('混合显示系统日历')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('关闭后只显示 DAV 账号的日程')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.showSystem })
                .selectedColor($r('app.color.brand'))
                .onChange((isOn: boolean) => {
                  if (isOn !== this.showSystem) {
                    this.showSystem = isOn;
                    this.saveShowSystem(isOn);
                  }
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 自动同步间隔
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('自动同步间隔')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('应用打开期间按此间隔自动同步')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Select([{ value: '1 分钟' }, { value: '5 分钟' }, { value: '15 分钟' },
                { value: '30 分钟' }, { value: '1 小时' }] as SelectOption[])
                .selected(INTERVAL_OPTIONS.indexOf(this.intervalMinutes))
                .value(this.intervalLabel(this.intervalMinutes))
                .fontColor($r('app.color.text_primary'))
                .font({ size: 14 })
                .optionFont({ size: 14 })
                .selectedOptionFont({ size: 14 })
                .onSelect((index: number) => {
                  if (index >= 0 && index < INTERVAL_OPTIONS.length) {
                    this.intervalMinutes = INTERVAL_OPTIONS[index];
                    this.saveInterval(INTERVAL_OPTIONS[index]);
                  }
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 后台持续同步（长时任务）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('后台持续同步')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('开启后申请后台长时任务，App 退到后台也按设定间隔继续同步（通知栏会显示常驻通知）')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.backgroundSync })
                .selectedColor($r('app.color.brand'))
                .onChange((isOn: boolean) => {
                  if (isOn !== this.backgroundSync) {
                    this.backgroundSync = isOn;
                    this.saveBackgroundSync(isOn);
                  }
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 通知权限：仅检测是否开启，未开启则引导去设置
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Row({ space: 6 }) {
                  Text('通知权限')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text(this.notifyEnabled ? '已开启' : '未开启')
                    .fontSize(11)
                    .fontColor(this.notifyEnabled ? $r('app.color.success') : $r('app.color.error'))
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .borderRadius(10)
                    .backgroundColor(this.notifyEnabled ? $r('app.color.success_bg') : $r('app.color.error_bg'))
                }
                Text(this.notifyEnabled
                  ? '日程提醒将正常以系统通知弹出'
                  : '未开启系统通知，日程提醒无法弹出')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            if (!this.notifyEnabled) {
              Button('去开启通知')
                .fontSize(13)
                .backgroundColor($r('app.color.brand'))
                .onClick(() => {
                  this.openNotifySettings();
                })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 软件特性（打开内置浏览器；内容为在线文档 sf.html，便于随时更新）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('软件特性')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('了解这个应用的特点与隐私理念')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_hint'))
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })
          .onClick(() => {
            this.openDoc(AppSettings.FEATURES_TITLE, AppSettings.FEATURES_URL);
          })

          // 使用帮助（打开内置浏览器；内容为在线文档 uh.html，便于随时更新）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('使用帮助')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('查看交互逻辑与使用方法')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_hint'))
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })
          .onClick(() => {
            this.openDoc(AppSettings.HELP_TITLE, AppSettings.HELP_URL);
          })

          // 隐私政策与用户协议（点击弹层；bindSheet 挂在本卡片上，避免与其它弹层冲突）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('隐私政策与用户协议')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('查看本应用如何处理你的信息，以及使用条款')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_hint'))
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })
          .onClick(() => {
            this.showLegal = true;
          })
          .bindSheet($$this.showLegal, this.legalSheet(), {
            height: 400,
            dragBar: true,
            showClose: true,
            title: { title: '隐私政策与用户协议' }
          })

          // 日历本只读 / 静音（放在最下方；本多时列表较长）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('日历本只读 / 静音')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('只读：标记后该本日程仅可查看、不再可新建；静音：该本所有日程不再提醒')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            if (this.allBooks.length === 0) {
              Text('暂无 CalDAV 日历本')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .width('100%')
            }
            ForEach(this.allBooks, (b: BackupTarget) => {
              Row({ space: 8 }) {
                // 日历本色点：只读本变中性灰 —— 相当于给这个本盖了一层灰蒙板
                Column()
                  .width(8)
                  .height(8)
                  .borderRadius(4)
                  .backgroundColor(this.isBookReadonly(b)
                    ? '#B0B4BA' : $r('app.color.brand'))
                Text(b.label)
                  .fontSize(13)
                  .fontColor(this.isBookReadonly(b)
                    ? $r('app.color.text_hint') : $r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Button(this.manualKeys.includes(b.calKey) ? '已只读' : '只读')
                  .fontSize(11)
                  .height(28)
                  .fontColor(this.manualKeys.includes(b.calKey)
                    ? $r('app.color.button_text') : $r('app.color.text_secondary'))
                  .backgroundColor(this.manualKeys.includes(b.calKey)
                    ? $r('app.color.brand') : $r('app.color.card_bg'))
                  .border({
                    width: this.manualKeys.includes(b.calKey) ? 0 : 1,
                    color: $r('app.color.shadow_color')
                  })
                  .onClick(() => {
                    this.toggleManualBook(b);
                  })
                Button(this.mutedKeys.includes(b.calKey) ? '已静音' : '静音')
                  .fontSize(11)
                  .height(28)
                  .fontColor(this.mutedKeys.includes(b.calKey)
                    ? $r('app.color.button_text') : $r('app.color.text_secondary'))
                  .backgroundColor(this.mutedKeys.includes(b.calKey)
                    ? $r('app.color.error') : $r('app.color.card_bg'))
                  .border({
                    width: this.mutedKeys.includes(b.calKey) ? 0 : 1,
                    color: $r('app.color.shadow_color')
                  })
                  .onClick(() => {
                    this.toggleMuteBook(b);
                  })
              }
              .width('100%')
              .padding({ left: 6, right: 6, top: 6, bottom: 6 })
              .borderRadius(8)
            }, (b: BackupTarget) => `book_${b.calKey}_r${this.manualKeys.includes(b.calKey) ? 1 : 0}_m${this.mutedKeys.includes(b.calKey) ? 1 : 0}_w${b.serverWritable ? 1 : 0}`)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 8, bottom: 20 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))

      // 内置文档浏览器（《隐私政策》/《用户服务协议》/《软件特性》/《使用帮助》）：
      // 整页覆盖层，点"✕"即刻返回设置页
      if (this.showDoc) {
        DocViewer({
          title: this.docTitle,
          url: this.docUrl,
          onClose: (): void => {
            this.showDoc = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 隐私政策与用户协议弹层 */
  @Builder
  legalSheet() {
    Scroll() {
      Column({ space: 12 }) {
        Text('我们遵循"数据自持、最小必要"原则：开发者不保存你的日程与账号数据，不收集通讯录、相册、剪贴板等信息，不含任何第三方统计或广告 SDK。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Button('查看《隐私政策》')
          .width('100%')
          .fontSize(15)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            this.openDoc(AppSettings.PRIVACY_TITLE, AppSettings.PRIVACY_URL);
          })
        Button('查看《用户服务协议》')
          .width('100%')
          .fontSize(15)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            this.openDoc(AppSettings.AGREEMENT_TITLE, AppSettings.AGREEMENT_URL);
          })
        Text('《隐私政策》说明本应用如何收集、使用与保护你的信息（日历、位置等）；《用户服务协议》说明使用本应用的权利与义务。两份文件随功能调整更新，最新版本以上述链接为准。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .width('100%')
      .align(Alignment.Top)
      .padding(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
