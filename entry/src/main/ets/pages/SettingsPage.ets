// entry/src/main/ets/pages/SettingsPage.ets
// 设置页：系统日历模式（仅显示/备份到 CalDAV）+ 混合显示开关 + 自动同步间隔 + 后台同步
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppSettings } from '../common/AppSettings';
import { BackgroundSyncService } from '../common/BackgroundSyncService';
import { AccountStore, DavAccount } from '../common/AccountStore';
import { ReminderService } from '../common/ReminderService';
import { LogUtil } from '../common/LogUtil';

const INTERVAL_OPTIONS: number[] = [1, 5, 15, 30, 60];

/** 日历本选项（备份目标 / 只读标记共用） */
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
  @State allBooks: BackupTarget[] = []; // 全部 DAV 日历本（只读标记管理用）
  @State manualKeys: string[] = [];     // 手动标记只读的 calKey
  @State mutedKeys: string[] = [];      // 提醒静音的 calKey
  private context?: common.Context;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    this.context = ctx;
    LogUtil.init(ctx);
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
    this.loadBackupSettings();
    this.loadAllBooks();
  }

  /** 加载全部 DAV 日历本（含探测到的写权限，只读标记管理用） */
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

  /** 日历本当前只读状态文案 */
  private bookStateLabel(b: BackupTarget): string {
    if (this.manualKeys.includes(b.calKey)) {
      return '只读（手动）';
    }
    return b.serverWritable ? '可写' : '只读';
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
    this.backupTargets = targets;
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
      // 自动选中第一个可写日历本
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

  private async saveShowSystem(value: boolean): Promise<void> {
    if (this.context === undefined) {
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
      this.getUIContext().getPromptAction().showToast({ message: '设置失败，请重试' });
    }
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

          // 日历本只读标记（部分服务器不在 CalDAV 层拒绝写入，自动探测无法区分时手动标记）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('日历本只读标记')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('点击日历本切换只读标记：标记后其中日程仅可查看详情，新建日程时不再显示')
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
                Text(this.bookStateLabel(b))
                  .fontSize(11)
                  .fontColor(this.bookStateLabel(b) === '可写'
                    ? $r('app.color.success') : $r('app.color.error'))
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .borderRadius(10)
                  .backgroundColor(this.bookStateLabel(b) === '可写'
                    ? $r('app.color.success_bg') : $r('app.color.error_bg'))
              }
              .width('100%')
              .padding({ top: 6, bottom: 6 })
              .onClick(() => {
                this.toggleManualBook(b);
              })
            }, (b: BackupTarget) => `${b.calKey}_${this.manualKeys.includes(b.calKey) ? 1 : 0}`)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 日历本提醒静音（如别人分享的日历本，静音后其中所有日程不再提醒）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('日历本提醒静音')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('点击日历本切换静音：静音后该日历本的所有日程都不再提醒（日程仍正常显示）')
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
                Text(this.mutedKeys.includes(b.calKey) ? '已静音' : '提醒中')
                  .fontSize(11)
                  .fontColor(this.mutedKeys.includes(b.calKey)
                    ? $r('app.color.error') : $r('app.color.success'))
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .borderRadius(10)
                  .backgroundColor(this.mutedKeys.includes(b.calKey)
                    ? $r('app.color.error_bg') : $r('app.color.success_bg'))
              }
              .width('100%')
              .padding({ top: 6, bottom: 6 })
              .onClick(() => {
                this.toggleMuteBook(b);
              })
            }, (b: BackupTarget) => `mute_${b.calKey}_${this.mutedKeys.includes(b.calKey) ? 1 : 0}`)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 数据修复：手动触发一次性全量重拉（重建提醒等本地残缺字段）
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
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 混合显示系统日历
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
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 自动同步间隔
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
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 后台持续同步（长时任务）
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
}
