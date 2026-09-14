// entry/src/main/ets/pages/SettingsPage.ets
// 设置页：系统日历模式（仅显示/备份到 CalDAV）+ 混合显示开关 + 自动同步间隔 + 后台同步
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { AppSettings } from '../common/AppSettings';
import { BackgroundSyncService } from '../common/BackgroundSyncService';
import { AccountStore, DavAccount } from '../common/AccountStore';
import { ReminderService } from '../common/ReminderService';

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
  @State showFeatures: boolean = false; // 软件特性弹层
  @State showHelp: boolean = false;     // 使用帮助弹层
  @State defaultView: string = 'month';  // 打开 App 默认视图：month | week | agenda
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

  /** 打开外部链接（如开源仓库） */
  private async openUrl(url: string): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    try {
      await (context as common.UIAbilityContext).openLink(url);
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开链接' });
    }
  }

  build() {
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

          // 软件特性（点击弹层；bindSheet 挂在本卡片上，避免与其它弹层冲突）
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
            this.showFeatures = true;
          })
          .bindSheet($$this.showFeatures, this.featureSheet(), {
            height: 560,
            dragBar: true,
            showClose: true,
            title: { title: '软件特性' }
          })

          // 使用帮助（点击弹层；bindSheet 挂在本卡片上）
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
            this.showHelp = true;
          })
          .bindSheet($$this.showHelp, this.helpSheet(), {
            height: 560,
            dragBar: true,
            showClose: true,
            title: { title: '使用帮助' }
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
                Text(b.label)
                  .fontSize(13)
                  .fontColor($r('app.color.text_primary'))
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
              .padding({ top: 6, bottom: 6 })
            }, (b: BackupTarget) => `book_${b.calKey}_r${this.manualKeys.includes(b.calKey) ? 1 : 0}_m${this.mutedKeys.includes(b.calKey) ? 1 : 0}`)
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
  }

  @Builder
  featureSheet() {
    Scroll() {
      Column({ space: 12 }) {
        Text('隐私与数据')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('• 数据自持：你的所有日程、待办只存放在你自己（或所在机构）的 CalDAV 服务器上，我们（开发者）不保存你的任何日程或账户数据。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('• 账户加密：CalDAV 账号的密码在本地以 AES-256-GCM 加密保存，只有发起同步时才临时解密使用，不会以明文留存。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('• 开源透明：本项目完全开源，代码可自行查看与审计，不藏任何后台上传逻辑。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Button('打开开源仓库')
          .fontSize(13)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            this.openUrl('https://gitee.com/dryangyq/SyncCalendar');
          })
        Text('同步能力')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ top: 4 })
        Text('• 双向同步：本地新建/修改会自动推送到服务器，服务器上的变更也会自动拉取，多设备保持一致。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('• 多账号多日历本统一管理，并可与手机系统日历混合展示。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('• 完整重复规则（RRULE）与多种提前提醒（可多选：5/10/15/30/60 分钟/1 天等）。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('• 只读日历本标记、他人分享日历本一键静音免打扰。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('• 后台持续同步（长时任务），退到后台也按设定间隔继续同步。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('• 日程地址一键拉起高德地图导航（系统地理编码定位，无需额外配置）。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('• 提醒走系统本地通知，不依赖厂商云推送；在系统无代理提醒配额时自动降级为应用内通知（需 App 在前台或开启后台同步）。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
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

  @Builder
  helpSheet() {
    Scroll() {
      Column({ space: 12 }) {
        Text('一、添加账号')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('在「账号」页填写你的 CalDAV 服务器地址（如群晖 https://域名:5006）、用户名与密码。账号信息在本地加密保存，不会上传给开发者。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Text('二、查看与新建日程')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ top: 4 })
        Text('首页支持月 / 周 / 日 / 列表视图。点「＋」新建日程：选择所属日历本、开始/结束时间、重复规则、提醒（可多选），并可填写地址用于导航。点列表中任意日程都会弹出详情；详情中若有地址，点「导航 ›」即可拉起高德地图；可写日程还能点「编辑日程」修改。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Text('三、同步')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ top: 4 })
        Text('App 处于打开状态时按设定间隔自动同步。开启「后台持续同步」后，退到后台也会继续同步（通知栏有常驻通知）。同步期间会保持屏幕常亮，避免熄屏中断。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Text('四、只读与静音')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ top: 4 })
        Text('把某个日历本标记为「只读」后，其中日程只能查看、不再可新建（适用于他人共享给你、或服务器侧不让改的本）。把分享来的日历本「静音」，其中所有日程都不再弹提醒，避免被打扰。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Text('五、提醒')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ top: 4 })
        Text('日程会在开始前按设定提前量弹出系统通知。请在系统设置中开启本应用「通知」权限（设置页可检测并一键前往开启）。提醒依赖系统代理提醒配额；若系统额度为 0，将自动改用应用内通知。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Text('六、系统日历与数据修复')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ top: 4 })
        Text('可开启「混合显示系统日历」，把手机自带日历也一并展示；或开启「备份到 CalDAV」，把系统本地日程导入所选日历本，换机/丢失也有备份。若发现提醒丢失等异常，可点「重建日程数据」让下次同步重新拉取完整数据。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
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
