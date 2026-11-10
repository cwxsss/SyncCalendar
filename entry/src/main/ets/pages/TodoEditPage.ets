// entry/src/main/ets/pages/TodoEditPage.ets
// 待办事项编辑页：新建 / 修改 / 删除待办事项（支持具体时间、详细描述、提醒功能与 CalDAV 同步）
import { router, curves } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { DavAccount, AccountStore, CalSource } from '../common/AccountStore';
import { EventDb, LocalEvent } from '../common/EventDb';
import { SyncEngine } from '../common/SyncEngine';
import { DavClient } from '../common/DavClient';
import { ReminderService } from '../common/ReminderService';
import { CardDataService } from '../common/CardDataService';
import { CalendarDataService, DraftTransfer } from '../common/CalendarDataService';
import { LogUtil } from '../common/LogUtil';
import { SmartDateParser, ParsedEventInfo } from '../common/SmartDateParser';
import { AppSettings } from '../common/AppSettings';
import { SystemCalendarMirror } from '../common/SystemCalendarMirror';

/** 可选的日历清单 */
class TodoBookChoice {
  calKey: string = '';
  href: string = '';
  name: string = '';
  color: string = '#007DFF';
}

@Entry
@Component
struct TodoEditPage {
  @State isExisting: boolean = false;
  @State original: LocalEvent | null = null;
  @State title: string = '';
  @State smartInput: string = '';
  @State description: string = '';
  @State hasDueDate: boolean = true; // 截止时间默认打开
  @State dueDateMs: number = 0; // 选中的年月日当天 00:00:00，默认今天
  @State hasSpecificTime: boolean = false; // 是否精确到具体时间点
  @State dueHour: number = 18;
  @State dueMinute: number = 0;
  @State reminderList: number[] = [-1]; // 提醒提前分钟数：默认到期时(-1)
  @State customReminderMinutes: number = 10;
  @State customReminderInput: string = '10';
  @State customSheetShow: boolean = false;
  @State repeatMode: string = 'none'; // none | daily | workday | weekly | monthly | yearly | custom
  @State rrule: string = '';
  @State books: TodoBookChoice[] = [];
  @State chosenKey: string = '';
  @State isSaving: boolean = false;
  @State errorField: string = '';
  @State bookSheetOpen: boolean = false;

  async aboutToAppear(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }

    // 默认日期为今天
    const now = new Date();
    this.dueDateMs = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();

    // 加载可写的 CalDAV 日历本集合
    await this.loadBooks(ctx);

    // 检查是否为编辑已有待办
    const todoId = AppStorage.get<number>('pendingTodoId') ?? 0;
    AppStorage.setOrCreate<number>('pendingTodoId', 0);
    if (todoId > 0) {
      const loaded = await EventDb.getById(ctx, todoId);
      if (loaded !== null) {
        this.isExisting = true;
        this.original = loaded;
        this.title = loaded.title;
        this.description = loaded.description;
        this.chosenKey = loaded.calKey;

        if (loaded.startTime > 0) {
          this.hasDueDate = true;
          const d = new Date(loaded.startTime);
          this.dueDateMs = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
          if (!loaded.isAllDay) {
            this.hasSpecificTime = true;
            this.dueHour = d.getHours();
            this.dueMinute = d.getMinutes();
          }
        } else {
          this.hasDueDate = false;
        }

        this.reminderList = loaded.reminders.length > 0 ? loaded.reminders : (loaded.reminder !== 0 ? [loaded.reminder] : []);
        const customFound = this.reminderList.find((m: number): boolean => m > 0 && m !== 5 && m !== 1440);
        if (customFound !== undefined) {
          this.customReminderMinutes = customFound;
          this.customReminderInput = String(customFound);
        }
        this.rrule = loaded.rrule;
        this.repeatMode = this.modeFromRrule(loaded.rrule);
      }
    } else {
      // 新建待办：截止时间默认打开，默认选择今天，默认提醒为到期时(-1)
      this.hasDueDate = true;
      this.dueDateMs = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
      this.reminderList = [-1];

      // 检查是否有草稿转换传入（从日程编辑页切换过来）
      const draft: DraftTransfer | undefined = AppStorage.get<DraftTransfer>('editDraftTransfer');
      if (draft !== undefined && draft !== null) {
        AppStorage.setOrCreate<DraftTransfer | null>('editDraftTransfer', null);
        this.title = draft.title;
        this.smartInput = draft.smartInput;
        this.description = draft.description;
        if (draft.chosenKey !== '') {
          this.chosenKey = draft.chosenKey;
        }
        if (draft.repeatMode !== '') {
          this.repeatMode = draft.repeatMode;
        }
        if (draft.reminders.length > 0) {
          this.reminderList = draft.reminders;
        }
        if (draft.startTime > 0) {
          this.hasDueDate = true;
          const d = new Date(draft.startTime);
          this.dueDateMs = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
          if (!draft.allDay) {
            this.hasSpecificTime = true;
            this.dueHour = d.getHours();
            this.dueMinute = d.getMinutes();
          } else {
            this.hasSpecificTime = false;
          }
        }
      }
    }
  }

  /** 判断当前快捷截止日期是否处于选中状态（增加颜色提示） */
  private isQuickDateActive(type: string): boolean {
    if (!this.hasDueDate) {
      return false;
    }
    const now = new Date();
    const todayZero = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    if (type === 'today') {
      return this.dueDateMs === todayZero;
    }
    if (type === 'tomorrow') {
      return this.dueDateMs === todayZero + 86400000;
    }
    if (type === 'after_tomorrow') {
      return this.dueDateMs === todayZero + 86400000 * 2;
    }
    if (type === 'weekend') {
      const day = now.getDay();
      const diff = (6 - day + 7) % 7 || 7; // 周六
      return this.dueDateMs === todayZero + 86400000 * diff;
    }
    return false;
  }

  /** 加载可用日历清单 */
  private async loadBooks(context: common.Context): Promise<void> {
    const accounts: DavAccount[] = await AccountStore.loadAll(context);
    const list: TodoBookChoice[] = [];
    for (const acc of accounts) {
      for (let i = 0; i < acc.calendarHrefs.length; i++) {
        const writable = i < acc.calendarWritable.length ? acc.calendarWritable[i] : '1';
        if (writable === '0') {
          continue; // 跳过只读日历本
        }
        const b = new TodoBookChoice();
        b.calKey = `${acc.id}_${i}`;
        b.href = acc.calendarHrefs[i];
        b.name = i < acc.calendarNames.length ? acc.calendarNames[i] : `日历本${i}`;
        b.color = i < acc.calendarColors.length ? acc.calendarColors[i] : '#007DFF';
        list.push(b);
      }
    }
    this.books = list;
    if (this.chosenKey === '' && list.length > 0) {
      // 优先匹配 CalDAV 的 inbox / 收件箱 作为默认日历本
      const inboxBook = list.find((b: TodoBookChoice): boolean => {
        const n = b.name.toLowerCase();
        const h = b.href.toLowerCase();
        return n.includes('inbox') || h.includes('inbox') || b.name.includes('收件箱');
      });
      if (inboxBook !== undefined) {
        this.chosenKey = inboxBook.calKey;
      } else {
        this.chosenKey = list[0].calKey;
      }
    }
  }

  /** 智能解析输入 */
  private applySmartParse(): void {
    if (this.smartInput.trim() === '') {
      return;
    }
    const res: ParsedEventInfo = SmartDateParser.parse(this.smartInput);
    if (res.title !== '') {
      this.title = res.title;
    }
    if (res.confidence && res.startTime > 0) {
      this.hasDueDate = true;
      const d = new Date(res.startTime);
      this.dueDateMs = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
      if (!res.isAllDay) {
        this.hasSpecificTime = true;
        this.dueHour = d.getHours();
        this.dueMinute = d.getMinutes();
      } else {
        this.hasSpecificTime = false;
      }
      this.getUIContext().getPromptAction().showToast({ message: '已自动识别截止时间' });
    } else {
      this.getUIContext().getPromptAction().showToast({ message: '已填入标题' });
    }
  }

  /** 格式化日期显示 */
  private formatDateCn(ms: number): string {
    const d = new Date(ms);
    const weekMap = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    const pad = (n: number) => n < 10 ? '0' + n : String(n);
    return `${d.getFullYear()}年${pad(d.getMonth() + 1)}月${pad(d.getDate())}日 ${weekMap[d.getDay()]}`;
  }

  /** 格式化时分显示 */
  private formatTime(h: number, m: number): string {
    const pad = (n: number) => n < 10 ? '0' + n : String(n);
    return `${pad(h)}:${pad(m)}`;
  }

  /** 切换快捷截止日期 */
  private setQuickDate(type: string): void {
    const now = new Date();
    const todayZero = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    this.hasDueDate = true;
    if (type === 'today') {
      this.dueDateMs = todayZero;
    } else if (type === 'tomorrow') {
      this.dueDateMs = todayZero + 86400000;
    } else if (type === 'after_tomorrow') {
      this.dueDateMs = todayZero + 86400000 * 2;
    } else if (type === 'weekend') {
      const day = now.getDay();
      const diff = (6 - day + 7) % 7 || 7; // 周六
      this.dueDateMs = todayZero + 86400000 * diff;
    }
  }

  /** 切换提醒 */
  private toggleReminder(min: number): void {
    if (min === 0) {
      this.reminderList = [];
      return;
    }
    const idx = this.reminderList.indexOf(min);
    if (idx >= 0) {
      this.reminderList.splice(idx, 1);
    } else {
      this.reminderList.push(min);
    }
  }

  /** 后台推送待办到对应账号 */
  private async triggerPush(ctx: common.Context, targetHref: string): Promise<void> {
    try {
      const accounts: DavAccount[] = await AccountStore.loadAll(ctx);
      const eNorm: string = DavClient.normalizeHref(targetHref);
      const acc: DavAccount | undefined = accounts.find((a: DavAccount): boolean =>
        a.calendarHrefs.some((h: string): boolean => DavClient.normalizeHref(h) === eNorm));
      if (acc !== undefined) {
        const auth: string = DavClient.authHeader(acc.username, acc.password);
        await SyncEngine.pushDirtyForAccount(ctx, acc, auth);
      }
    } catch (err) {
      LogUtil.write('后台推送待办失败: ' + (err as Error).message);
    }
  }

  /** 保存待办事项 */
  private async save(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    const trimmedTitle = this.title.trim();
    if (trimmedTitle === '') {
      this.errorField = 'title';
      this.getUIContext().getPromptAction().showToast({ message: '请填写待办内容后再保存' });
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }

    this.isSaving = true;

    // 计算截止毫秒数
    let finalDueTime = 0;
    let isAllDay = true;
    if (this.hasDueDate) {
      if (this.hasSpecificTime) {
        finalDueTime = this.dueDateMs + this.dueHour * 3600000 + this.dueMinute * 60000;
        isAllDay = false;
      } else {
        finalDueTime = this.dueDateMs;
        isAllDay = true;
      }
    }

    const curBook = this.books.find(b => b.calKey === this.chosenKey) || (this.books.length > 0 ? this.books[0] : null);
    const targetKey = curBook !== null ? curBook.calKey : '';
    const targetHref = curBook !== null ? curBook.href : '';

    try {
      if (this.isExisting && this.original !== null) {
        const e = this.original;
        e.title = trimmedTitle;
        e.description = this.description;
        e.startTime = finalDueTime;
        e.endTime = finalDueTime;
        e.isAllDay = isAllDay;
        e.calKey = targetKey;
        e.href = targetHref;
        const effectiveRrule: string = this.modeToRrule(this.repeatMode);
        e.rrule = effectiveRrule;
        e.recurring = effectiveRrule !== '';
        e.reminders = this.reminderList;
        e.reminder = this.reminderList.length > 0 ? this.reminderList[0] : 0;
        e.dirty = true;
        await EventDb.updateLocal(ctx, e);
        LogUtil.write(`待办已更新: id=${e.id} title=${e.title}`);
      } else {
        const uid = `syncal-todo-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
        const e = new LocalEvent();
        e.uid = uid;
        e.calKey = targetKey;
        e.href = targetHref;
        e.remotePath = `${encodeURIComponent(uid)}.ics`;
        e.title = trimmedTitle;
        e.description = this.description;
        e.startTime = finalDueTime;
        e.endTime = finalDueTime;
        e.isAllDay = isAllDay;
        e.kind = 'todo';
        e.completed = false;
        e.dirty = true;
        const effectiveRrule: string = this.modeToRrule(this.repeatMode);
        e.rrule = effectiveRrule;
        e.recurring = effectiveRrule !== '';
        e.reminders = this.reminderList;
        e.reminder = this.reminderList.length > 0 ? this.reminderList[0] : 0;
        await EventDb.insertLocal(ctx, e);
        LogUtil.write(`待办已新建: uid=${uid} title=${e.title}`);
      }

      // 刷新后台提醒
      try {
        await ReminderService.refreshReminders(ctx as common.UIAbilityContext);
      } catch (err) {}

      // 联动刷新桌面及副屏小组件
      try {
        await CardDataService.pushToAllForms(ctx);
      } catch (err) {}

      // 后台触发 CalDAV 实时推送
      this.triggerPush(ctx, targetHref);

      AppStorage.setOrCreate<number>('eventModifiedTimestamp', Date.now());
      this.getUIContext().getPromptAction().showToast({ message: '待办已保存并同步' });
      router.back();
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: `保存失败: ${(err as Error).message}` });
      this.isSaving = false;
    }
  }

  /** 转换为日程 */
  private askConvertToEvent(): void {
    if (!this.isExisting || this.original === null || this.original.id <= 0 || this.isSaving) {
      return;
    }
    const label: string = this.title.trim() === '' ? '该待办事项' : `「${this.title.trim()}」`;
    this.getUIContext().showAlertDialog({
      title: '转换为日程',
      message: `确定要将${label}转换为日程吗？\n\n转换后该项将显示在日历与日程视图中。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '确定转换',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.doConvertToEvent(this.original!.id);
        }
      }
    });
  }

  private async doConvertToEvent(id: number): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    this.isSaving = true;
    const ok = await CalendarDataService.convertTodoToEvent(ctx, id);
    if (ok) {
      try {
        if (await AppSettings.getMirrorEnabled(ctx) && await SystemCalendarMirror.hasPermission()) {
          SystemCalendarMirror.syncNow(ctx).catch((err: Error) => {
            LogUtil.write(`转日程后同步镜像至系统日历失败: ${err.message}`);
          });
        }
      } catch (err) {}
      try {
        await CardDataService.pushToAllForms(ctx);
      } catch (err) {}
      AppStorage.setOrCreate<number>('eventModifiedTimestamp', Date.now());
      this.getUIContext().getPromptAction().showToast({ message: '已成功转换为日程' });
      router.back();
    } else {
      this.isSaving = false;
      this.getUIContext().getPromptAction().showToast({ message: '转换失败' });
    }
  }

  /** 删除待办事项 */
  private askDelete(): void {
    if (!this.isExisting || this.original === null) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除待办',
      message: `确定要删除待办「${this.title}」吗？\n删除后将从云端服务器彻底移除。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E64545',
        action: async () => {
          const ctx = this.getUIContext().getHostContext();
          if (ctx !== undefined && this.original !== null) {
            await EventDb.markDeleted(ctx, this.original.id);
            this.triggerPush(ctx, this.original.href);
            try {
              await CardDataService.pushToAllForms(ctx);
            } catch (err) {}
            AppStorage.setOrCreate<number>('eventModifiedTimestamp', Date.now());
            this.getUIContext().getPromptAction().showToast({ message: '待办已删除' });
            router.back();
          }
        }
      }
    });
  }

  /**
   * 页面转场：淡入淡出（与 EventEditPage 保持一致，无跳动感）。
   */
  pageTransition() {
    PageTransitionEnter({ type: RouteType.None, duration: 300, curve: curves.springMotion(0.35, 0.75) })
      .opacity(0);
    PageTransitionExit({ type: RouteType.None, duration: 250, curve: curves.springMotion(0.35, 0.75) })
      .opacity(0);
  }

  build() {
    Column({ space: 14 }) {
      // 顶部导航栏（与日程编辑页左右、高度、按钮完全对齐）
      Row({ space: 6 }) {
        Text('取消')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
          .padding({ left: 4, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            router.back();
          })

        Blank()

        if (this.isExisting) {
          Text('编辑待办')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        } else {
          Row({ space: 4 }) {
            Text('日程')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.chip_off_bg'))
              .borderRadius(14)
              .padding({ left: 14, right: 14, top: 5, bottom: 5 })
              .onClick(() => {
                const draft = new DraftTransfer();
                draft.title = this.title;
                draft.smartInput = this.smartInput;
                draft.description = this.description;
                let finalStart = 0;
                let isAllDay = true;
                if (this.hasDueDate) {
                  if (this.hasSpecificTime) {
                    finalStart = this.dueDateMs + this.dueHour * 3600000 + this.dueMinute * 60000;
                    isAllDay = false;
                  } else {
                    finalStart = this.dueDateMs;
                    isAllDay = true;
                  }
                }
                draft.startTime = finalStart;
                draft.endTime = finalStart > 0 ? (isAllDay ? finalStart + 86400000 - 1000 : finalStart + 3600000) : 0;
                draft.allDay = isAllDay;
                draft.chosenKey = this.chosenKey;
                draft.reminders = this.reminderList;
                draft.repeatMode = this.repeatMode;
                AppStorage.setOrCreate<DraftTransfer>('editDraftTransfer', draft);
                router.replaceUrl({ url: 'pages/EventEditPage' });
              })
            Text('待办')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.button_text'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(14)
              .padding({ left: 14, right: 14, top: 5, bottom: 5 })
          }
          .padding(2)
          .borderRadius(16)
          .backgroundColor($r('app.color.chip_off_bg'))
        }

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

      // 表单滚动区
      Scroll() {
        Column({ space: 8 }) {
          // ⚡ 智能解析条（仅新建待办时展示，与日程编辑页样式统一）
          if (!this.isExisting) {
            Row({ space: 8 }) {
              TextInput({ text: this.smartInput, placeholder: '⚡ 粘贴整句智能识别，如：明天下午3点提交报销' })
                .layoutWeight(1)
                .height(40)
                .fontSize(13)
                .backgroundColor(Color.Transparent)
                .placeholderColor($r('app.color.text_hint'))
                .fontColor($r('app.color.text_primary'))
                .onChange((v: string) => {
                  this.smartInput = v;
                })
                .onSubmit(() => {
                  this.applySmartParse();
                })

              Button('智能解析')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.button_text'))
                .backgroundColor($r('app.color.brand'))
                .height(32)
                .borderRadius(8)
                .padding({ left: 10, right: 10 })
                .onClick(() => {
                  this.applySmartParse();
                })
            }
            .width('100%')
            .padding({ left: 10, right: 8, top: 4, bottom: 4 })
            .borderRadius(10)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 1, color: $r('app.color.shadow_color') })
          }

          // 待办标题卡片（高度与视觉与日程输入框对齐）
          TextInput({ text: this.title, placeholder: '准备做什么？（必填）' })
            .height(46)
            .fontSize(16)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_hint'))
            .caretColor($r('app.color.brand'))
            .padding({ left: 14, right: 14 })
            .border({
              width: this.errorField === 'title' ? 1.5 : 0,
              color: $r('app.color.error')
            })
            .onChange((v: string) => {
              this.title = v;
              if (v.trim() !== '' && this.errorField === 'title') {
                this.errorField = '';
              }
            })

          if (this.errorField === 'title') {
            Text('请填写待办内容后再保存')
              .fontSize(12)
              .fontColor($r('app.color.error'))
              .width('100%')
              .padding({ left: 4 })
          }

          // 截止时间卡片（具体的时间）
          Column({ space: 8 }) {
            Row() {
              Text('截止时间')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.hasDueDate })
                .selectedColor($r('app.color.brand'))
                .onChange((isOn: boolean) => {
                  this.hasDueDate = isOn;
                })
            }
            .width('100%')

            if (this.hasDueDate) {
              Divider().color($r('app.color.shadow_color'))

              // 快捷日期选择（当选择今天、明天、后天时，增加颜色提示）
              Row({ space: 8 }) {
                Button('今天')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor(this.isQuickDateActive('today') ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
                  .fontColor(this.isQuickDateActive('today') ? $r('app.color.button_text') : $r('app.color.text_primary'))
                  .borderRadius(14)
                  .onClick(() => { this.setQuickDate('today'); })
                Button('明天')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor(this.isQuickDateActive('tomorrow') ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
                  .fontColor(this.isQuickDateActive('tomorrow') ? $r('app.color.button_text') : $r('app.color.text_primary'))
                  .borderRadius(14)
                  .onClick(() => { this.setQuickDate('tomorrow'); })
                Button('后天')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor(this.isQuickDateActive('after_tomorrow') ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
                  .fontColor(this.isQuickDateActive('after_tomorrow') ? $r('app.color.button_text') : $r('app.color.text_primary'))
                  .borderRadius(14)
                  .onClick(() => { this.setQuickDate('after_tomorrow'); })
                Button('本周末')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor(this.isQuickDateActive('weekend') ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
                  .fontColor(this.isQuickDateActive('weekend') ? $r('app.color.button_text') : $r('app.color.text_primary'))
                  .borderRadius(14)
                  .onClick(() => { this.setQuickDate('weekend'); })
              }
              .width('100%')

              // 截止日期行（点击呼出系统 DatePickerDialog）
              Row() {
                Text('日期')
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
                Blank()
                Text(this.formatDateCn(this.dueDateMs))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.brand'))
                Text(' ›')
                  .fontSize(14)
                  .fontColor($r('app.color.text_hint'))
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })
              .onClick(() => {
                const cur = new Date(this.dueDateMs);
                this.getUIContext().showDatePickerDialog({
                  start: new Date(2020, 0, 1),
                  end: new Date(2035, 11, 31),
                  selected: cur,
                  onAccept: (val: DatePickerResult) => {
                    if (val.year !== undefined && val.month !== undefined && val.day !== undefined) {
                      this.dueDateMs = new Date(val.year, val.month, val.day).getTime();
                    }
                  }
                });
              })

              // 具体时间点开关
              Row() {
                Text('设定具体时刻')
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.hasSpecificTime })
                  .selectedColor($r('app.color.brand'))
                  .onChange((isOn: boolean) => {
                    this.hasSpecificTime = isOn;
                  })
              }
              .width('100%')

              // 时刻选择行（点击呼出系统 TimePickerDialog）
              if (this.hasSpecificTime) {
                Row() {
                  Text('时刻')
                    .fontSize(14)
                    .fontColor($r('app.color.text_secondary'))
                  Blank()
                  Text(this.formatTime(this.dueHour, this.dueMinute))
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.brand'))
                  Text(' ›')
                    .fontSize(14)
                    .fontColor($r('app.color.text_hint'))
                }
                .width('100%')
                .padding({ top: 4, bottom: 4 })
                .onClick(() => {
                  this.getUIContext().showTimePickerDialog({
                    selected: new Date(2026, 0, 1, this.dueHour, this.dueMinute),
                    useMilitaryTime: true,
                    onAccept: (val: TimePickerResult) => {
                      if (val.hour !== undefined && val.minute !== undefined) {
                        this.dueHour = val.hour;
                        this.dueMinute = val.minute;
                      }
                    }
                  });
                })
              }
            }
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 重复功能卡片（显示到一行，顺序与日程编辑页统一）
          Column({ space: 6 }) {
            Text('重复')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))

            Scroll() {
              Row({ space: 8 }) {
                this.repeatChip('none', '不重复')
                this.repeatChip('daily', '每天')
                this.repeatChip('workday', '工作日')
                this.repeatChip('weekly', '每周')
                this.repeatChip('monthly', '每月')
                this.repeatChip('yearly', '每年')
                if (this.repeatMode === 'custom') {
                  this.repeatChip('custom', '自定义')
                }
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 提醒功能卡片（显示到一行，顺序与日程编辑页统一）
          Column({ space: 6 }) {
            Text('提醒（可多选）')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))

            Scroll() {
              Row({ space: 8 }) {
                this.reminderChip(0, '不提醒')
                this.reminderChip(-1, '到期时')
                this.reminderChip(5, '提前5分钟')
                this.customReminderChip()
                this.reminderChip(1440, '提前1天')
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 所属日历本卡片（采用与日程编辑页相同的两列等宽48%卡片，风格完全统一）
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
              Text('没有可写入的 CalDAV 日历本。请先到「更多 → 账号管理」添加账号；'
                + '这条待办需要同步到服务器。')
                .fontSize(12)
                .fontColor($r('app.color.error'))
                .width('100%')
            } else {
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                ForEach(this.books, (b: TodoBookChoice) => {
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
                }, (b: TodoBookChoice) => b.calKey)
              }
              .width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 备注
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

          // 编辑已有待办时的转换为日程按钮
          if (this.isExisting) {
            Button('转换为日程')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.brand'))
              .backgroundColor($r('app.color.chip_off_bg'))
              .width('100%')
              .height(44)
              .borderRadius(12)
              .enabled(!this.isSaving)
              .onClick(() => {
                this.askConvertToEvent();
              })
          }

          // 编辑已有待办时的删除按钮
          if (this.isExisting) {
            Button('删除待办事项')
              .fontSize(15)
              .fontColor($r('app.color.error'))
              .backgroundColor($r('app.color.error_bg'))
              .width('100%')
              .height(44)
              .borderRadius(12)
              .enabled(!this.isSaving)
              .onClick(() => {
                this.askDelete();
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 30 })
        .constraintSize({ minHeight: '100%' })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ top: 12 })
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.customSheetShow, this.customReminderSheet(), {
      height: 360,
      showClose: false,
      dragBar: true,
      backgroundColor: $r('app.color.card_bg')
    })
  }

  @Builder
  reminderChip(min: number, label: string) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.isReminderSelected(min) ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.isReminderSelected(min) ? $r('app.color.button_text') : $r('app.color.text_primary'))
      .backgroundColor(this.isReminderSelected(min) ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
      .borderRadius(14)
      .height(28)
      .padding({ left: 10, right: 10 })
      .onClick(() => {
        this.toggleReminder(min);
      })
  }

  private isReminderSelected(min: number): boolean {
    if (min === 0) {
      return this.reminderList.length === 0;
    }
    return this.reminderList.includes(min);
  }

  private chosenBookName(): string {
    const found = this.books.find(b => b.calKey === this.chosenKey);
    return found !== undefined ? found.name : '默认日历';
  }

  private chosenBookColor(): string {
    const found = this.books.find(b => b.calKey === this.chosenKey);
    return found !== undefined ? found.color : '#007DFF';
  }

  private modeFromRrule(rrule: string): string {
    if (rrule === '') {
      return 'none';
    }
    const u = rrule.toUpperCase();
    if (u.includes('BYDAY=MO,TU,WE,TH,FR')) {
      return 'workday';
    }
    if (u.includes('FREQ=DAILY')) {
      return 'daily';
    }
    if (u.includes('FREQ=WEEKLY')) {
      return 'weekly';
    }
    if (u.includes('FREQ=MONTHLY')) {
      return 'monthly';
    }
    if (u.includes('FREQ=YEARLY')) {
      return 'yearly';
    }
    return 'custom';
  }

  private modeToRrule(mode: string): string {
    if (mode === 'none') {
      return '';
    }
    if (mode === 'daily') {
      return 'FREQ=DAILY;INTERVAL=1';
    }
    if (mode === 'workday') {
      return 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR';
    }
    if (mode === 'weekly') {
      return 'FREQ=WEEKLY;INTERVAL=1';
    }
    if (mode === 'monthly') {
      return 'FREQ=MONTHLY;INTERVAL=1';
    }
    if (mode === 'yearly') {
      return 'FREQ=YEARLY;INTERVAL=1';
    }
    return this.rrule;
  }

  private repeatLabel(mode: string): string {
    if (mode === 'none') return '不重复';
    if (mode === 'daily') return '每天重复';
    if (mode === 'workday') return '工作日重复';
    if (mode === 'weekly') return '每周重复';
    if (mode === 'monthly') return '每月重复';
    if (mode === 'yearly') return '每年重复';
    return '自定义重复';
  }

  @Builder
  repeatChip(mode: string, label: string) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.repeatMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.repeatMode === mode ? $r('app.color.button_text') : $r('app.color.text_primary'))
      .backgroundColor(this.repeatMode === mode ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
      .borderRadius(14)
      .height(28)
      .padding({ left: 10, right: 10 })
      .onClick(() => {
        this.repeatMode = mode;
        if (mode !== 'none' && !this.hasDueDate) {
          this.hasDueDate = true;
        }
      })
  }

  @Builder
  customReminderChip() {
    Row({ space: 4 }) {
      Text(this.reminderList.some((m: number): boolean => m > 0 && m !== 5 && m !== 1440)
        ? `提前${this.customReminderMinutes}分钟 ✎` : '提前X分钟')
        .fontSize(12)
        .fontWeight(this.reminderList.some((m: number): boolean => m > 0 && m !== 5 && m !== 1440)
          ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.reminderList.some((m: number): boolean => m > 0 && m !== 5 && m !== 1440)
          ? $r('app.color.button_text') : $r('app.color.text_primary'))
    }
    .backgroundColor(this.reminderList.some((m: number): boolean => m > 0 && m !== 5 && m !== 1440)
      ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
    .borderRadius(14)
    .height(28)
    .padding({ left: 10, right: 10 })
    .onClick(() => {
      this.customSheetShow = true;
    })
  }

  @Builder
  customReminderSheet() {
    Column({ space: 14 }) {
      Text('自定义提前提醒')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12 })

      Text('设置在待办截止前多少分钟发出提醒')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)

      // 步进调节与输入框
      Row({ space: 10 }) {
        Button('-5')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.chip_off_bg'))
          .width(44)
          .height(40)
          .borderRadius(8)
          .onClick(() => {
            const cur = Math.max(1, (parseInt(this.customReminderInput, 10) || 10) - 5);
            this.customReminderInput = String(cur);
          })

        Row() {
          TextInput({ text: this.customReminderInput })
            .type(InputType.Number)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)
            .width(90)
            .height(40)
            .backgroundColor(Color.Transparent)
            .onChange((val: string) => {
              this.customReminderInput = val;
            })
          Text('分钟')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .margin({ right: 8 })
        }
        .padding({ left: 4, right: 4 })
        .borderRadius(8)
        .backgroundColor($r('app.color.chip_off_bg'))
        .border({ width: 1, color: $r('app.color.shadow_color') })

        Button('+5')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.chip_off_bg'))
          .width(44)
          .height(40)
          .borderRadius(8)
          .onClick(() => {
            const cur = Math.min(10080, (parseInt(this.customReminderInput, 10) || 10) + 5);
            this.customReminderInput = String(cur);
          })
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')

      // 快捷预设胶囊
      Column({ space: 6 }) {
        Text('常用预设')
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
          .width('100%')
        Flex({ wrap: FlexWrap.Wrap, space: { main: { value: 6, unit: 1 }, cross: { value: 6, unit: 1 } } }) {
          this.quickPresetChip(10, '10分钟')
          this.quickPresetChip(15, '15分钟')
          this.quickPresetChip(20, '20分钟')
          this.quickPresetChip(30, '30分钟')
          this.quickPresetChip(45, '45分钟')
          this.quickPresetChip(120, '2小时')
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Blank()

      // 底部按钮栏
      Row({ space: 12 }) {
        if (this.reminderList.some((m: number): boolean => m > 0 && m !== 5 && m !== 1440)) {
          Button('移除此项')
            .fontSize(14)
            .fontColor('#E64545')
            .backgroundColor($r('app.color.chip_off_bg'))
            .layoutWeight(1)
            .height(38)
            .borderRadius(19)
            .onClick(() => {
              this.reminderList = this.reminderList.filter((m: number): boolean => m === -1 || m === 5 || m === 1440);
              this.customSheetShow = false;
            })
        } else {
          Button('取消')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.chip_off_bg'))
            .layoutWeight(1)
            .height(38)
            .borderRadius(19)
            .onClick(() => {
              this.customSheetShow = false;
            })
        }

        Button('确定')
          .fontSize(14)
          .fontColor($r('app.color.button_text'))
          .backgroundColor($r('app.color.brand'))
          .layoutWeight(1)
          .height(38)
          .borderRadius(19)
          .onClick(() => {
            const val = parseInt(this.customReminderInput.trim(), 10);
            if (Number.isNaN(val) || val <= 0 || val > 10080) {
              this.getUIContext().getPromptAction().showToast({ message: '请输入1至10080之间的分钟数' });
              return;
            }
            const list: number[] = this.reminderList.filter((m: number): boolean => m === -1 || m === 5 || m === 1440);
            list.push(val);
            this.reminderList = list;
            this.customReminderMinutes = val;
            this.customSheetShow = false;
            this.getUIContext().getPromptAction().showToast({ message: `已设置提前 ${val} 分钟提醒` });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  quickPresetChip(minutes: number, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor((parseInt(this.customReminderInput, 10) === minutes) ? $r('app.color.brand') : $r('app.color.text_secondary'))
      .backgroundColor((parseInt(this.customReminderInput, 10) === minutes) ? $r('app.color.chip_off_bg') : Color.Transparent)
      .border({ width: 1, color: (parseInt(this.customReminderInput, 10) === minutes) ? $r('app.color.brand') : $r('app.color.shadow_color') })
      .borderRadius(12)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .onClick(() => {
        this.customReminderInput = String(minutes);
      })
  }
}
