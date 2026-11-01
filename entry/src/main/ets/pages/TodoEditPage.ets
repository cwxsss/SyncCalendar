// entry/src/main/ets/pages/TodoEditPage.ets
// 待办事项编辑页：新建 / 修改 / 删除待办事项（支持具体时间、详细描述、提醒功能与 CalDAV 同步）
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { DavAccount, AccountStore, CalSource } from '../common/AccountStore';
import { EventDb, LocalEvent } from '../common/EventDb';
import { SyncEngine } from '../common/SyncEngine';
import { DavClient } from '../common/DavClient';
import { ReminderService } from '../common/ReminderService';
import { LogUtil } from '../common/LogUtil';
import { SmartDateParser, ParsedEventInfo } from '../common/SmartDateParser';

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
  @State hasDueDate: boolean = false;
  @State dueDateMs: number = 0; // 选中的年月日当天 00:00:00
  @State hasSpecificTime: boolean = false; // 是否精确到具体时间点
  @State dueHour: number = 18;
  @State dueMinute: number = 0;
  @State reminderList: number[] = []; // 提醒提前分钟数：空=不提醒，-1=到期时，5/15/30/60/1440
  @State books: TodoBookChoice[] = [];
  @State chosenKey: string = '';
  @State isSaving: boolean = false;
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
        }

        this.reminderList = loaded.reminders.length > 0 ? loaded.reminders : (loaded.reminder !== 0 ? [loaded.reminder] : []);
      }
    }
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
      this.getUIContext().getPromptAction().showToast({ message: '请输入待办事项内容' });
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
        e.reminders = this.reminderList;
        e.reminder = this.reminderList.length > 0 ? this.reminderList[0] : 0;
        await EventDb.insertLocal(ctx, e);
        LogUtil.write(`待办已新建: uid=${uid} title=${e.title}`);
      }

      // 刷新后台提醒
      try {
        await ReminderService.refreshReminders(ctx as common.UIAbilityContext);
      } catch (err) {}

      // 后台触发 CalDAV 实时推送
      this.triggerPush(ctx, targetHref);

      this.getUIContext().getPromptAction().showToast({ message: '待办已保存并同步' });
      router.back();
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: `保存失败: ${(err as Error).message}` });
      this.isSaving = false;
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
            this.getUIContext().getPromptAction().showToast({ message: '待办已删除' });
            router.back();
          }
        }
      }
    });
  }

  build() {
    Column() {
      // 顶部导航栏
      Row() {
        Text('取消')
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 4, right: 8, top: 4, bottom: 4 })
          .onClick(() => {
            router.back();
          })

        Blank()

        Text(this.isExisting ? '编辑待办' : '新建待办')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Blank()

        Button(this.isSaving ? '保存中' : '保存')
          .height(32)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .backgroundColor($r('app.color.brand'))
          .borderRadius(16)
          .padding({ left: 16, right: 16 })
          .enabled(!this.isSaving)
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      // 表单滚动区
      Scroll() {
        Column({ space: 14 }) {
          // ⚡ 智能解析条（仅新建待办时展示）
          if (!this.isExisting) {
            Row({ space: 8 }) {
              Text('⚡')
                .fontSize(14)
              TextInput({ text: this.smartInput, placeholder: '粘贴自然语言，如：明天下午3点提交报销' })
                .layoutWeight(1)
                .height(36)
                .fontSize(13)
                .backgroundColor(Color.Transparent)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_hint'))
                .onChange((v: string) => {
                  this.smartInput = v;
                })
                .onSubmit(() => {
                  this.applySmartParse();
                })

              Button('解析')
                .height(28)
                .fontSize(12)
                .backgroundColor($r('app.color.brand'))
                .borderRadius(14)
                .padding({ left: 10, right: 10 })
                .onClick(() => {
                  this.applySmartParse();
                })
            }
            .width('100%')
            .padding({ left: 12, right: 10, top: 4, bottom: 4 })
            .borderRadius(10)
            .backgroundColor($r('app.color.chip_off_bg'))
          }

          // 待办标题卡片
          Column() {
            TextInput({ text: this.title, placeholder: '准备做什么？' })
              .width('100%')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_hint'))
              .onChange((v: string) => {
                this.title = v;
              })
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 截止时间卡片（具体的时间）
          Column({ space: 12 }) {
            Row() {
              Column({ space: 2 }) {
                Text('截止时间')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text(this.hasDueDate ? (this.hasSpecificTime ? '精确到时分' : '全天') : '未设置截止时间')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)

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

              // 快捷日期选择
              Row({ space: 8 }) {
                Button('今天')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor($r('app.color.chip_off_bg'))
                  .fontColor($r('app.color.text_primary'))
                  .borderRadius(14)
                  .onClick(() => { this.setQuickDate('today'); })
                Button('明天')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor($r('app.color.chip_off_bg'))
                  .fontColor($r('app.color.text_primary'))
                  .borderRadius(14)
                  .onClick(() => { this.setQuickDate('tomorrow'); })
                Button('后天')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor($r('app.color.chip_off_bg'))
                  .fontColor($r('app.color.text_primary'))
                  .borderRadius(14)
                  .onClick(() => { this.setQuickDate('after_tomorrow'); })
                Button('本周末')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor($r('app.color.chip_off_bg'))
                  .fontColor($r('app.color.text_primary'))
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
                DatePickerDialog.show({
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
                  TimePickerDialog.show({
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
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 提醒功能卡片
          Column({ space: 10 }) {
            Row() {
              Text('提醒')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Blank()
              Text(this.reminderList.length === 0 ? '不提醒' : `已设 ${this.reminderList.length} 项提醒`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')

            Flex({ wrap: FlexWrap.Wrap, space: { main: { value: 8, unit: 1 }, cross: { value: 8, unit: 1 } } }) {
              this.reminderChip(0, '不提醒')
              this.reminderChip(-1, '到期时')
              this.reminderChip(5, '提前5分钟')
              this.reminderChip(15, '提前15分钟')
              this.reminderChip(30, '提前30分钟')
              this.reminderChip(60, '提前1小时')
              this.reminderChip(1440, '提前1天')
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 所属日历本卡片
          if (this.books.length > 0) {
            Column({ space: 10 }) {
              Row() {
                Text('日历本')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                Row({ space: 6 }) {
                  Circle()
                    .width(10)
                    .height(10)
                    .fill(this.chosenBookColor())
                  Text(this.chosenBookName())
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                }
              }
              .width('100%')

              if (this.books.length > 1) {
                Flex({ wrap: FlexWrap.Wrap, space: { main: { value: 8, unit: 1 }, cross: { value: 8, unit: 1 } } }) {
                  ForEach(this.books, (b: TodoBookChoice) => {
                    Row({ space: 4 }) {
                      Circle().width(8).height(8).fill(b.color)
                      Text(b.name)
                        .fontSize(12)
                        .fontColor(this.chosenKey === b.calKey ? $r('app.color.brand') : $r('app.color.text_secondary'))
                    }
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                    .borderRadius(14)
                    .backgroundColor(this.chosenKey === b.calKey ? Color.Transparent : $r('app.color.chip_off_bg'))
                    .border({ width: 1, color: this.chosenKey === b.calKey ? $r('app.color.brand') : Color.Transparent })
                    .onClick(() => {
                      this.chosenKey = b.calKey;
                    })
                  })
                }
                .width('100%')
              }
            }
            .width('100%')
            .padding(14)
            .borderRadius(12)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 1, color: $r('app.color.shadow_color') })
          }

          // 详细描述卡片
          Column({ space: 8 }) {
            Text('详细描述')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            TextArea({ text: this.description, placeholder: '添加待办事项的详细说明、备忘要点…' })
              .width('100%')
              .height(100)
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_hint'))
              .onChange((v: string) => {
                this.description = v;
              })
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 编辑已有待办时的删除按钮
          if (this.isExisting) {
            Button('删除待办事项')
              .width('100%')
              .height(44)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#E64545')
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(22)
              .border({ width: 1, color: '#E64545' })
              .margin({ top: 10, bottom: 20 })
              .onClick(() => {
                this.askDelete();
              })
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 4, bottom: 40 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.page_bg'))
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
}
