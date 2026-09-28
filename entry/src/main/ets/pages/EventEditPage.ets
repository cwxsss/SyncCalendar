// entry/src/main/ets/pages/EventEditPage.ets
// 日程编辑页：新建 / 修改 / 删除日程（一律属于某个 CalDAV 日历本，不再支持"本机"日程）
import { curves, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { DavAccount, AccountStore, CalSource, BookPalette, LOCAL_CAL_KEY } from '../common/AccountStore';
import { EventDb, LocalEvent } from '../common/EventDb';
import { AppSettings } from '../common/AppSettings';
import { DavClient } from '../common/DavClient';
import { SyncEngine } from '../common/SyncEngine';
import { ReminderService } from '../common/ReminderService';
import { LogUtil } from '../common/LogUtil';

/** 可选的日历本 */
class BookChoice {
  calKey: string = '';
  href: string = '';
  name: string = '';
  color: string = '#007DFF';
}

@Entry
@Component
struct EventEditPage {
  @State title: string = '';
  @State location: string = '';
  @State description: string = '';
  @State allDay: boolean = false;
  @State startMs: number = 0;
  @State endMs: number = 0;
  @State books: BookChoice[] = [];
  @State chosenKey: string = '';
  @State isSaving: boolean = false;
  @State statusMsg: string = '';
  @State isExisting: boolean = false;
  @State repeatMode: string = 'none'; // none|daily|workday|weekly|monthly|yearly|custom
  @State reminderList: number[] = []; // 提前提醒分钟数（多选），空 = 不提醒
  @State pickerShow: boolean = false; // 开始/结束时间选择底部弹层（日期+时间一次选完）
  @State pickerIsEnd: boolean = false;
  @State pickDate: Date = new Date();
  @State pickHour: number = 9;
  @State pickMin: number = 0;
  private event: LocalEvent | null = null;

  aboutToAppear(): Promise<void> {
    return this.initPage();
  }

  private async initPage(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    // 收集可写入的日历本：只取 **CalDAV** 可写日历本（"本机"不再出现在选择里）；
    // 只读日历本同样不出现
    const sources: CalSourceWithHref[] = await CalendarDataBridge.loadWritableDavSources(context);
    const choices: BookChoice[] = [];
    for (const s of sources) {
      const b = new BookChoice();
      b.calKey = s.calKey;
      b.href = s.href;
      b.name = s.name;
      b.color = s.color;
      choices.push(b);
    }
    this.books = choices;
    if (choices.length === 0) {
      // 没有可写入的 CalDAV 日历本 → 日程无处可写，给明确指引（保存时也会再拦一次）
      this.statusMsg = '还没有可写入的 CalDAV 日历本，请先到「更多 → 账号管理」添加账号';
    }

    // 编辑既有事件
    const pendingId: number | undefined = AppStorage.get<number>('pendingEventId');
    if (pendingId !== undefined && pendingId > 0) {
      const loaded = await EventDb.getById(context, pendingId);
      if (loaded !== null) {
        this.event = loaded;
        this.isExisting = true;
        this.title = loaded.title;
        this.location = loaded.location;
        this.description = loaded.description;
        this.allDay = loaded.isAllDay;
        this.startMs = loaded.startTime;
        this.endMs = loaded.endTime;
        this.chosenKey = loaded.calKey;
        // 历史遗留的"本机"日程：本应用已不再支持本机日程，改为引导用户挑一个 CalDAV 日历本
        // （保存时 calKey/href 会改写为该日历本，事件随后被推送到服务器）
        if (loaded.calKey === LOCAL_CAL_KEY) {
          this.statusMsg = '这条日程原先只存在「本机」（不同步）。请选一个 CalDAV 日历本，保存后即会同步到服务器。';
        }
        this.repeatMode = loaded.rrule !== '' ? this.modeFromRrule(loaded.rrule) : 'none';
        this.reminderList = loaded.reminders.length > 0 ? loaded.reminders
          : (loaded.reminder > 0 ? [loaded.reminder] : []);
        return;
      }
    }
    // 新建：日期取所选日（未选则今天），时间取当前时刻；结束 = 开始 + 1 小时
    const base: number = AppStorage.get<number>('pendingEventDate') ?? Date.now();
    const dayStart = new Date(new Date(base).getFullYear(), new Date(base).getMonth(),
      new Date(base).getDate()).getTime();
    const now = new Date();
    this.startMs = dayStart + now.getHours() * 3600000 + now.getMinutes() * 60000;
    this.endMs = this.startMs + 3600000;
    if (choices.length > 0) {
      this.chosenKey = choices[0].calKey;
    }
  }

  private chosenBook(): BookChoice | null {
    return this.books.find((b: BookChoice): boolean => b.calKey === this.chosenKey) ?? null;
  }

  private fmtDate(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  }

  private fmtTime(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  /** 重复模式 → RRULE 字符串（RruleUtil 已支持这些规则） */
  private rruleForMode(mode: string): string {
    if (mode === 'daily') {
      return 'FREQ=DAILY';
    }
    if (mode === 'workday') {
      return 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR';
    }
    if (mode === 'weekly') {
      return 'FREQ=WEEKLY';
    }
    if (mode === 'monthly') {
      return 'FREQ=MONTHLY';
    }
    if (mode === 'yearly') {
      return 'FREQ=YEARLY';
    }
    return '';
  }

  /** RRULE → 重复模式（无法识别的规则归为 custom，保存时保留原规则） */
  private modeFromRrule(rrule: string): string {
    const u: string = rrule.toUpperCase();
    if (u.includes('FREQ=DAILY')) {
      return 'daily';
    }
    if (u.includes('FREQ=WEEKLY')) {
      const hasWeekday: boolean = u.includes('MO') && u.includes('TU') && u.includes('WE')
        && u.includes('TH') && u.includes('FR');
      return hasWeekday ? 'workday' : 'weekly';
    }
    if (u.includes('FREQ=MONTHLY')) {
      return 'monthly';
    }
    if (u.includes('FREQ=YEARLY')) {
      return 'yearly';
    }
    return 'custom';
  }

  private reminderLabel(m: number): string {
    if (m === 0) {
      return '不提醒';
    }
    if (m < 60) {
      return `提前${m}分钟`;
    }
    if (m < 1440) {
      return `提前${m / 60}小时`;
    }
    return `提前${m / 1440}天`;
  }

  /** 打开时间选择弹层：日期 + 时间一次选完 */
  private openPicker(isEnd: boolean): void {
    this.pickerIsEnd = isEnd;
    const base = new Date(isEnd ? this.endMs : this.startMs);
    this.pickDate = new Date(base.getFullYear(), base.getMonth(), base.getDate());
    this.pickHour = base.getHours();
    this.pickMin = base.getMinutes();
    this.pickerShow = true;
  }

  private applyPicker(): void {
    const d = this.pickDate;
    const picked: number = new Date(d.getFullYear(), d.getMonth(), d.getDate(),
      this.pickHour, this.pickMin).getTime();
    if (this.pickerIsEnd) {
      // 全天日程的结束存为"当天 23:59:59.999"（排他日期前 1 毫秒）
      this.endMs = this.allDay ? picked + 86399999 : picked;
    } else {
      // 设定开始时间后，结束时间自动跟随 = 开始 + 1 小时
      this.startMs = picked;
      this.endMs = this.allDay ? picked + 86399999 : picked + 3600000;
    }
  }

  private toggleAllDay(): void {
    this.allDay = !this.allDay;
    if (this.allDay) {
      const s = new Date(this.startMs);
      const dayStart: number = new Date(s.getFullYear(), s.getMonth(), s.getDate()).getTime();
      this.startMs = dayStart;
      this.endMs = dayStart + 86399999;
    } else {
      const s = new Date(this.startMs);
      this.startMs = s.getTime() + 9 * 3600000;
      this.endMs = this.startMs + 3600000;
    }
  }

  private validate(): boolean {
    if (this.title.trim() === '') {
      this.statusMsg = '请输入日程标题';
      return false;
    }
    if (this.endMs < this.startMs) {
      this.statusMsg = '结束时间不能早于开始时间';
      return false;
    }
    return true;
  }

  private async save(): Promise<void> {
    if (this.isSaving || !this.validate()) {
      return;
    }
    // 仅阻止"单次覆盖实例"（RECURRENCE-ID）的修改；重复主事件（含 RRULE）允许编辑
    if (this.event !== null && this.event.recurring && this.event.rrule === '') {
      this.statusMsg = '重复日程的单次修改暂不支持，请到服务器端调整重复规则';
      return;
    }
    // 日程必须落在某个 CalDAV 日历本上（"本机"不再是可选目标）——没选到就直接拦下
    const book = this.chosenBook();
    if (book === null) {
      this.statusMsg = this.books.length === 0
        ? '还没有可写入的 CalDAV 日历本，请先到「更多 → 账号管理」添加账号'
        : '请选择要同步到的 CalDAV 日历本';
      return;
    }
    this.isSaving = true;
    this.statusMsg = '';
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      const e = this.event ?? new LocalEvent();
      const isNew: boolean = this.event === null;
      e.title = this.title.trim();
      e.location = this.location.trim();
      e.description = this.description.trim();
      e.startTime = this.startMs;
      e.endTime = this.allDay ? this.startMs + 86399999 : this.endMs;
      e.isAllDay = this.allDay;
      // 一律写入所选 CalDAV 日历本（新建/编辑/从「本机」迁过来都一样）
      e.calKey = book.calKey;
      e.href = book.href;
      // 重复规则与提醒
      if (this.repeatMode === 'custom') {
        // 无法识别的既有规则原样保留
        e.rrule = this.event !== null ? this.event.rrule : '';
      } else {
        e.rrule = this.rruleForMode(this.repeatMode);
      }
      e.recurring = e.rrule !== '';
      e.reminders = EventDb.normalizeReminders(this.reminderList);
      e.reminder = e.reminders.length > 0 ? e.reminders[0] : 0;
      if (isNew) {
        e.uid = `syncal-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
        e.remotePath = encodeURIComponent(e.uid) + '.ics';
        await EventDb.insertLocal(context, e);
      } else {
        await EventDb.updateLocal(context, e);
      }
      // 立即推送（尽力而为，失败不打断，下次同步会再推）
      if (e.href !== '') {
        const accounts: DavAccount[] = await AccountStore.loadAll(context);
        const acc = accounts.find((a: DavAccount): boolean => a.calendarHrefs.includes(e.href));
        if (acc !== undefined) {
          const auth: string = DavClient.authHeader(acc.username, acc.password);
          await SyncEngine.pushDirtyForAccount(context, acc, auth);
        }
      } else {
        await SyncEngine.settleLocalEvents(context);
      }
      // 日志仅记录 uid 与提醒/重复设置，不落盘日程标题（避免隐私内容进入可备份的 sync.log）
      LogUtil.write(`本地保存日程（标题已脱敏）uid=${e.uid} 提醒=${e.reminders.join('/')}分钟 重复=${e.rrule === '' ? '否' : e.rrule}`);
      // 设置了提醒 → 此刻才申请通知权限（用户刚主动使用了依赖通知的功能，
      // 符合《审核指南》7.17"在用户主动点击对应功能时申请"，不随 App 启动自动弹窗）
      if (e.reminders.length > 0) {
        await this.ensureNotifyPermission();
      }
      // 立即刷新提醒（不等下一轮同步），保证刚保存的提醒马上生效
      try {
        await ReminderService.refreshReminders(context as common.UIAbilityContext);
      } catch (err) {
        // 刷新失败不影响保存
      }
      this.getUIContext().getPromptAction().showToast({ message: '日程已保存' });
      router.back();
    } catch (err) {
      const ex = err as BusinessError;
      LogUtil.write(`保存日程流程失败（数据已存本地待重试）：${ex.message}`);
      this.statusMsg = `保存失败：${ex.message}（已保存到本地，稍后同步会重试）`;
      // 数据仍在本地且带 dirty 标记，不会丢
      router.back();
    }
    this.isSaving = false;
  }

  /**
   * 确认通知权限已开启 —— 仅"用户保存了带提醒的日程"这条路径会调用。
   * 日程提醒依赖系统通知，用户刚主动设置了提醒，此时申请权限与其使用目的完全一致。
   * ⚠️ 严禁在 App 启动 / 首次打开时调用（《审核指南》7.17：不得提前弹窗申请权限）。
   */
  private async ensureNotifyPermission(): Promise<void> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (enabled) {
        return;
      }
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      await notificationManager.requestEnableNotification(context as common.UIAbilityContext);
    } catch (err) {
      // 用户拒绝或未弹窗：日程照常保存，只是提醒可能不弹出（设置页可再开启）
    }
  }

  /**
   * 删除前二次确认。
   * 删除日程不可撤销，且会同时从本地库与服务器（DAV）移除，故破坏性操作前必须显式确认，
   * 避免"删除日程"按钮点击即删的误触。
   */
  private askRemoveEvent(): void {
    if (this.event === null || this.isSaving) {
      return;
    }
    const label: string = this.title.trim() === '' ? '该日程' : `「${this.title.trim()}」`;
    this.getUIContext().showAlertDialog({
      title: '删除日程',
      message: `确定删除${label}吗？\n\n删除后该日程将从本地与服务器日历中一并移除，且不可撤销。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.error'),
        action: (): void => {
          this.removeEvent();
        }
      }
    });
  }

  private async removeEvent(): Promise<void> {
    if (this.event === null || this.isSaving) {
      return;
    }
    if (this.event !== null && this.event.recurring && this.event.rrule === '') {
      this.statusMsg = '重复日程的单次删除暂不支持，请到服务器端调整重复规则';
      return;
    }
    this.isSaving = true;
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      await EventDb.markDeleted(context, this.event.id);
      if (this.event.href !== '') {
        const accounts: DavAccount[] = await AccountStore.loadAll(context);
        const acc = accounts.find((a: DavAccount): boolean => a.calendarHrefs.includes(this.event?.href ?? ''));
        if (acc !== undefined) {
          const auth: string = DavClient.authHeader(acc.username, acc.password);
          await SyncEngine.pushDirtyForAccount(context, acc, auth);
        }
      } else {
        await SyncEngine.settleLocalEvents(context);
      }
      // 日志不落盘日程标题，仅以 uid 追踪
      LogUtil.write(`本地删除日程（标题已脱敏）uid=${this.event?.uid ?? ''}`);
      // 立即刷新提醒（取消已发布但日程已删的提醒）
      try {
        await ReminderService.refreshReminders(context as common.UIAbilityContext);
      } catch (err) {
        // 刷新失败不影响删除
      }
      this.getUIContext().getPromptAction().showToast({ message: '日程已删除' });
      router.back();
    } catch (err) {
      const ex = err as BusinessError;
      this.statusMsg = `删除失败：${ex.message}`;
    }
    this.isSaving = false;
  }

  build() {
    Column({ space: 14 }) {
      // 顶部（与内容区左右对齐，避免贴边误触）
      Row({ space: 6 }) {
        Text('取消')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
          .padding({ left: 4, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            router.back();
          })
        Blank()
        Text(this.isExisting ? '编辑日程' : '新建日程')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('保存')
          .fontSize(16)
          .fontColor(this.isSaving ? $r('app.color.text_hint') : $r('app.color.brand'))
          .fontWeight(FontWeight.Medium)
          .padding({ left: 4, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Scroll() {
        Column({ space: 14 }) {
          // 标题
          TextInput({ text: this.title, placeholder: '标题' })
            .height(46)
            .fontSize(16)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
            // 显式指定文字/提示/光标颜色：TextInput 默认取系统主题色，
            // 深色模式下会变成浅色文字 → 与卡片底色撞色而"看不清"
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_hint'))
            .caretColor($r('app.color.brand'))
            .onChange((v: string) => {
              this.title = v;
            })

          // 全天
          Row() {
            Text('全天')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.allDay })
              .selectedColor($r('app.color.brand'))
              .onChange(() => {
                this.toggleAllDay();
              })
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 时间卡片（单击任一行：底部弹层中日期+时间一次选完）
          Column({ space: 10 }) {
            this.timeRow('开始', true)
            Divider().color($r('app.color.shadow_color'))
            this.timeRow('结束', false)
          }
          .width('100%')
          .padding(6)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 重复
          Column({ space: 8 }) {
            Text('重复')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              this.repeatChip('none', '不重复')
              this.repeatChip('daily', '每天')
              this.repeatChip('workday', '工作日')
              this.repeatChip('weekly', '每周')
              this.repeatChip('monthly', '每月')
              this.repeatChip('yearly', '每年')
              if (this.repeatMode === 'custom') {
                // 服务器来的复杂规则（INTERVAL/COUNT 等）标记为自定义，保存时原样保留
                this.repeatChip('custom', '自定义')
              }
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 提醒
          Column({ space: 8 }) {
            Text('提醒（可多选）')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              this.reminderChip(0)
              this.reminderChip(5)
              this.reminderChip(10)
              this.reminderChip(15)
              this.reminderChip(30)
              this.reminderChip(60)
              this.reminderChip(1440)
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 日历本选择：两列等宽对齐（每项固定 48% 宽 + 两端对齐），只列 CalDAV 可写日历本
          Column({ space: 8 }) {
            Row({ space: 6 }) {
              Text('日历本')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Text('同步到 CalDAV')
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
            }
            .width('100%')

            if (this.books.length === 0) {
              // 没有可写入的 CalDAV 日历本：说明原因 + 给替代方案（本机日程请用系统「日历」）
              Text('没有可写入的 CalDAV 日历本。请先到「更多 → 账号管理」添加账号；'
                + '这条日程需要同步到服务器。若只想记在本机，请使用系统「日历」应用。')
                .fontSize(12)
                .fontColor($r('app.color.error'))
                .width('100%')
            } else {
              if (this.chosenBook() === null) {
                // 未选中任何日历本（如历史遗留的"本机"日程）→ 就地提示，别让用户找不到原因
                Text(this.chosenKey === LOCAL_CAL_KEY
                  ? '这条日程原先只存在「本机」（不同步）。请选一个日历本，保存后即会同步到服务器。'
                  : '请选择一个日历本，日程会同步到服务器。')
                  .fontSize(12)
                  .fontColor($r('app.color.brand_text'))
                  .width('100%')
              }
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                ForEach(this.books, (b: BookChoice) => {
                  Row({ space: 6 }) {
                    Circle().width(8).height(8).fill(b.color)
                    Text(b.name)
                      .fontSize(12)
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontColor(this.chosenKey === b.calKey
                        ? $r('app.color.button_text') : $r('app.color.text_primary'))
                  }
                  .width('48%')
                  .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                  .borderRadius(14)
                  .margin({ bottom: 8 })
                  .backgroundColor(this.chosenKey === b.calKey ? b.color : $r('app.color.chip_off_bg'))
                  .onClick(() => {
                    this.chosenKey = b.calKey;
                  })
                }, (b: BookChoice) => b.calKey)
              }
              .width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 地点
          TextInput({ text: this.location, placeholder: '地点（可选）' })
            .height(44)
            .fontSize(14)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_hint'))
            .caretColor($r('app.color.brand'))
            .onChange((v: string) => {
              this.location = v;
            })

          // 描述
          TextArea({ text: this.description, placeholder: '备注（可选）' })
            .height(90)
            .fontSize(14)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_hint'))
            .caretColor($r('app.color.brand'))
            .onChange((v: string) => {
              this.description = v;
            })

          if (this.statusMsg !== '') {
            Text(this.statusMsg)
              .fontSize(13)
              .fontColor($r('app.color.error'))
              .width('100%')
          }

          // 删除
          if (this.isExisting) {
            Button('删除日程')
              .fontSize(15)
              .fontColor($r('app.color.error'))
              .backgroundColor($r('app.color.error_bg'))
              .width('100%')
              .height(44)
              .borderRadius(12)
              .enabled(!this.isSaving)
              .onClick(() => {
                // 二次确认后再执行删除
                this.askRemoveEvent();
              })
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 30 })
        .constraintSize({ minHeight: '100%' })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ top: 12 })
    .backgroundColor($r('app.color.page_bg'))
    // 沉浸式：背景延伸到状态栏/导航条区域（只扩绘制、不移动子组件）
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.pickerShow, this.dateTimePickerSheet(), {
      height: 380,
      showClose: false,
      dragBar: true,
      backgroundColor: $r('app.color.card_bg')
    })
  }

  /**
   * 页面转场：淡入淡出。
   * 不做左右平移 / 上下位移（不调用 .slide() / .translate()），只做透明度变化，
   * 避免单帧直接切换；曲线使用弹簧曲线（springMotion）。
   */
  pageTransition() {
    PageTransitionEnter({ type: RouteType.None, duration: 300, curve: curves.springMotion(0.35, 0.75) })
      .opacity(0);
    PageTransitionExit({ type: RouteType.None, duration: 250, curve: curves.springMotion(0.35, 0.75) })
      .opacity(0);
  }


  @Builder
  timeRow(label: string, isStart: boolean) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .width(36)
      Text(this.allDay
        ? this.fmtDate(isStart ? this.startMs : this.endMs)
        : `${this.fmtDate(isStart ? this.startMs : this.endMs)} ${this.fmtTime(isStart ? this.startMs : this.endMs)}`)
        .fontSize(15)
        .fontColor($r('app.color.brand'))
        .layoutWeight(1)
      Text('›')
        .fontSize(16)
        .fontColor($r('app.color.text_hint'))
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 10, bottom: 10 })
    .onClick(() => {
      // 注意：timeRow 的参数是 isStart，openPicker 的参数是 isEnd，语义相反必须取反
      this.openPicker(!isStart);
    })
  }

  @Builder
  repeatChip(mode: string, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.repeatMode === mode
        ? $r('app.color.button_text') : $r('app.color.text_primary'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(14)
      .margin({ right: 8, bottom: 8 })
      .backgroundColor(this.repeatMode === mode ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
      .onClick(() => {
        this.repeatMode = mode;
      })
  }

  /** 提醒 chip 是否选中：0 = 不提醒（列表为空时选中）；其余按是否已选 */
  private chipOn(minutes: number): boolean {
    if (minutes === 0) {
      return this.reminderList.length === 0;
    }
    return this.reminderList.includes(minutes);
  }

  /** 切换提醒：0 = 清空全部；其余多选切换 */
  private toggleReminder(minutes: number): void {
    if (minutes === 0) {
      this.reminderList = [];
      return;
    }
    const list: number[] = [...this.reminderList];
    const idx: number = list.indexOf(minutes);
    if (idx >= 0) {
      list.splice(idx, 1);
    } else {
      list.push(minutes);
    }
    this.reminderList = list;
  }

  @Builder
  reminderChip(minutes: number) {
    Text(this.reminderLabel(minutes))
      .fontSize(12)
      .fontColor(this.chipOn(minutes)
        ? $r('app.color.button_text') : $r('app.color.text_primary'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(14)
      .margin({ right: 8, bottom: 8 })
      .backgroundColor(this.chipOn(minutes) ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
      .onClick(() => {
        this.toggleReminder(minutes);
      })
  }

  /** 开始/结束时间选择弹层：左侧日期、右侧时间（全天时只有日期），一次确定 */
  @Builder
  dateTimePickerSheet() {
    Column({ space: 14 }) {
      Text(this.pickerIsEnd ? '选择结束时间' : '选择开始时间')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12 })
      Row({ space: 6 }) {
        DatePicker({
          start: new Date(2000, 0, 1),
          end: new Date(2050, 11, 31),
          selected: this.pickDate
        })
          .onDateChange((value: Date) => {
            this.pickDate = value;
          })
          // 滚轮文字显式指定颜色：默认取系统主题色，深色模式下与弹层底色撞色会"看不清"
          .textStyle({ color: $r('app.color.text_secondary'), font: { size: 14 } })
          .selectedTextStyle({
            color: $r('app.color.text_primary'),
            font: { size: 16, weight: FontWeight.Medium }
          })
          .disappearTextStyle({ color: $r('app.color.text_hint'), font: { size: 14 } })
          .layoutWeight(1)
          .height(210)
        if (!this.allDay) {
          TimePicker({
            selected: new Date(2000, 0, 1, this.pickHour, this.pickMin)
          })
            .onChange((value: TimePickerResult) => {
              this.pickHour = value.hour;
              this.pickMin = value.minute;
            })
            .textStyle({ color: $r('app.color.text_secondary'), font: { size: 14 } })
            .selectedTextStyle({
              color: $r('app.color.text_primary'),
              font: { size: 16, weight: FontWeight.Medium }
            })
            .disappearTextStyle({ color: $r('app.color.text_hint'), font: { size: 14 } })
            .layoutWeight(1)
            .height(210)
        }
      }
      .width('100%')

      Button(this.allDay ? '确定日期' : '确定')
        .width('100%')
        .height(44)
        .borderRadius(12)
        .fontSize(15)
        .backgroundColor($r('app.color.brand'))
        .onClick(() => {
          this.applyPicker();
          this.pickerShow = false;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
  }
}

/**
 * 桥接：从账号存储拿**可写入且能同步**的日历本（只取 CalDAV 日历本），并附上 href。
 *
 * ⚠️ 刻意**不返回"本机"（calKey='local'）**：本应用新建/编辑的日程一律写入某个 CalDAV
 *    日历本并同步到服务器；纯本机日程请用户改用系统「日历」应用完成
 *    （本应用也没有申请写系统日历本地的权限，做不到）。
 */
class CalendarDataBridge {
  static async loadWritableDavSources(context: common.Context): Promise<CalSourceWithHref[]> {
    const result: CalSourceWithHref[] = [];
    const accounts: DavAccount[] = await AccountStore.loadAll(context);
    const manualKeys: string[] = await AppSettings.getManualReadonlyKeys(context);
    for (const acc of accounts) {
      for (let i = 0; i < acc.calendarHrefs.length; i++) {
        // 只读日历本（服务器无写权限，或用户手动标记只读）不可选
        const detected: boolean = acc.calendarWritable.length > i
          ? acc.calendarWritable[i] !== '0' : true;
        if (!detected || manualKeys.includes(`${acc.id}_${i}`)) {
          continue;
        }
        const s = new CalSourceWithHref();
        s.calKey = `${acc.id}_${i}`;
        let name: string = i < acc.calendarNames.length ? acc.calendarNames[i] : '';
        if (name === '') {
          name = acc.calendarHrefs.length === 1 ? acc.name : `日历本 ${i + 1}`;
        }
        s.name = `${acc.name} · ${name}`;
        let color: string = i < acc.calendarColors.length ? AccountStore.normalizeColor(acc.calendarColors[i]) : '';
        s.color = color !== '' ? color : BookPalette.colorForHref(acc.calendarHrefs[i]);
        s.href = acc.calendarHrefs[i];
        s.writable = true;
        result.push(s);
      }
    }
    return result;
  }
}

class CalSourceWithHref extends CalSource {
  href: string = '';
}