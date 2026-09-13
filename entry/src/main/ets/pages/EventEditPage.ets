// entry/src/main/ets/pages/EventEditPage.ets
// 日程编辑页：新建 / 修改 / 删除本地（DAV 或本机）日程
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, CalSource, BookPalette } from '../common/AccountStore';
import { EventDb, LocalEvent } from '../common/EventDb';
import { DavClient } from '../common/DavClient';
import { SyncEngine } from '../common/SyncEngine';

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
  private event: LocalEvent | null = null;

  aboutToAppear(): Promise<void> {
    return this.initPage();
  }

  private async initPage(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    // 收集可写入的日历本（DAV + 本机）
    const sources: CalSourceWithHref[] = await CalendarDataBridge.loadWritableSources(context);
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
        return;
      }
    }
    // 新建：默认时间 = 所选日期 9:00-10:00
    const base: number = AppStorage.get<number>('pendingEventDate') ?? Date.now();
    const dayStart = new Date(new Date(base).getFullYear(), new Date(base).getMonth(),
      new Date(base).getDate()).getTime();
    this.startMs = dayStart + 9 * 3600000;
    this.endMs = dayStart + 10 * 3600000;
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

  private pickStartDate(): void {
    const cur = new Date(this.startMs);
    DatePickerDialog.show({
      start: new Date(2000, 0, 1),
      end: new Date(2050, 11, 31),
      selected: cur,
      onDateAccept: (value: Date) => {
        const keep = new Date(this.startMs);
        const newStart: number = new Date(value.getFullYear(), value.getMonth(), value.getDate(),
          keep.getHours(), keep.getMinutes()).getTime();
        const dur: number = this.endMs - this.startMs;
        this.startMs = newStart;
        this.endMs = this.allDay ? newStart + 86399999 : newStart + dur;
      }
    });
  }

  private pickStartTime(): void {
    const cur = new Date(this.startMs);
    TimePickerDialog.show({
      selected: cur,
      onAccept: (value: TimePickerResult) => {
        const d = new Date(this.startMs);
        const newStart: number = new Date(d.getFullYear(), d.getMonth(), d.getDate(),
          value.hour, value.minute).getTime();
        const dur: number = this.endMs - this.startMs;
        this.startMs = newStart;
        this.endMs = newStart + dur;
      }
    });
  }

  private pickEndDate(): void {
    const cur = new Date(this.endMs);
    DatePickerDialog.show({
      start: new Date(2000, 0, 1),
      end: new Date(2050, 11, 31),
      selected: cur,
      onDateAccept: (value: Date) => {
        const keep = new Date(this.endMs);
        this.endMs = new Date(value.getFullYear(), value.getMonth(), value.getDate(),
          keep.getHours(), keep.getMinutes()).getTime();
      }
    });
  }

  private pickEndTime(): void {
    const cur = new Date(this.endMs);
    TimePickerDialog.show({
      selected: cur,
      onAccept: (value: TimePickerResult) => {
        const d = new Date(this.endMs);
        this.endMs = new Date(d.getFullYear(), d.getMonth(), d.getDate(),
          value.hour, value.minute).getTime();
      }
    });
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
    if (this.event !== null && this.event.recurring) {
      this.statusMsg = '重复日程（系列中的一天）暂不支持修改，请到服务器端调整重复规则';
      return;
    }
    this.isSaving = true;
    this.statusMsg = '';
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      const book = this.chosenBook();
      const e = this.event ?? new LocalEvent();
      const isNew: boolean = this.event === null;
      e.title = this.title.trim();
      e.location = this.location.trim();
      e.description = this.description.trim();
      e.startTime = this.startMs;
      e.endTime = this.allDay ? this.startMs + 86399999 : this.endMs;
      e.isAllDay = this.allDay;
      e.calKey = book !== null ? book.calKey : 'local';
      e.href = book !== null ? book.href : '';
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
      this.getUIContext().getPromptAction().showToast({ message: '日程已保存' });
      router.back();
    } catch (err) {
      const ex = err as BusinessError;
      console.error(`保存日程失败: ${ex.message}`);
      this.statusMsg = `保存失败：${ex.message}（已保存到本地，稍后同步会重试）`;
      // 数据仍在本地且带 dirty 标记，不会丢
      router.back();
    }
    this.isSaving = false;
  }

  private async removeEvent(): Promise<void> {
    if (this.event === null || this.isSaving) {
      return;
    }
    if (this.event.recurring) {
      this.statusMsg = '重复日程（系列中的一天）暂不支持删除，请到服务器端调整重复规则';
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
      // 顶部
      Row({ space: 6 }) {
        Text('取消')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
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
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')

      Scroll() {
        Column({ space: 14 }) {
          // 标题
          TextInput({ text: this.title, placeholder: '标题' })
            .height(46)
            .fontSize(16)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
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

          // 时间卡片
          Column({ space: 10 }) {
            this.timeRow('开始', true)
            Divider().color($r('app.color.shadow_color'))
            this.timeRow('结束', false)
          }
          .width('100%')
          .padding(6)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))

          // 日历本选择
          Column({ space: 8 }) {
            Text('日历本')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.books, (b: BookChoice) => {
                Row({ space: 5 }) {
                  Circle().width(8).height(8).fill(b.color)
                  Text(b.name)
                    .fontSize(12)
                    .fontColor(this.chosenKey === b.calKey
                      ? $r('app.color.button_text') : $r('app.color.text_primary'))
                }
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .borderRadius(14)
                .margin({ right: 8, bottom: 8 })
                .backgroundColor(this.chosenKey === b.calKey ? b.color : $r('app.color.chip_off_bg'))
                .onClick(() => {
                  this.chosenKey = b.calKey;
                })
              }, (b: BookChoice) => b.calKey)
            }
            .width('100%')
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
            .onChange((v: string) => {
              this.location = v;
            })

          // 描述
          TextArea({ text: this.description, placeholder: '备注（可选）' })
            .height(90)
            .fontSize(14)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
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
                this.removeEvent();
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
  }

  @Builder
  timeRow(label: string, isStart: boolean) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .width(36)
      Text(this.fmtDate(isStart ? this.startMs : this.endMs))
        .fontSize(15)
        .fontColor($r('app.color.brand'))
        .onClick(() => {
          if (isStart) {
            this.pickStartDate();
          } else {
            this.pickEndDate();
          }
        })
      if (!this.allDay) {
        Text(this.fmtTime(isStart ? this.startMs : this.endMs))
          .fontSize(15)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            if (isStart) {
              this.pickStartTime();
            } else {
              this.pickEndTime();
            }
          })
      }
      Blank()
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
  }
}

/** 桥接：从账号存储拿可写来源（DAV 日历本 + 本机），附上 href */
class CalendarDataBridge {
  static async loadWritableSources(context: common.Context): Promise<CalSourceWithHref[]> {
    const result: CalSourceWithHref[] = [];
    const accounts: DavAccount[] = await AccountStore.loadAll(context);
    for (const acc of accounts) {
      for (let i = 0; i < acc.calendarHrefs.length; i++) {
        const s = new CalSourceWithHref();
        s.calKey = `${acc.id}_${i}`;
        let name: string = i < acc.calendarNames.length ? acc.calendarNames[i] : '';
        if (name === '') {
          name = acc.calendarHrefs.length === 1 ? acc.name : `日历本 ${i + 1}`;
        }
        s.name = `${acc.name} · ${name}`;
        let color: string = i < acc.calendarColors.length ? AccountStore.normalizeColor(acc.calendarColors[i]) : '';
        s.color = color !== '' ? color : BookPalette.colorFor(i);
        s.href = acc.calendarHrefs[i];
        result.push(s);
      }
    }
    const local = new CalSourceWithHref();
    local.calKey = 'local';
    local.name = '本机（不同步）';
    local.color = '#5A6068';
    result.push(local);
    return result;
  }
}

class CalSourceWithHref extends CalSource {
  href: string = '';
}