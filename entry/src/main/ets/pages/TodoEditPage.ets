// entry/src/main/ets/pages/TodoEditPage.ets
// 待办编辑页：新建 / 修改 / 删除待办（VTODO）
//
// ⭐ 为什么做成独立页面而不是弹层（用户明确要求）：
//    原来待办编辑是 Index 里的一个底部弹层（todoEditorOverlay）。字段越加越多
//    （日历本/标题/截止/循环/优先级/提醒/标签/地点/父任务/附件/备注），
//    弹层空间不够、要自己处理滚动和高度约束，与新建日程页（EventEditPage）
//    的交互形态也不一致 —— 用户要求「跟新建日程一样」。
//    所以整体迁移成独立页面：顶部「取消 · 标题 · 保存」，中间一整页可滚动表单。
//
// 传参：与 EventEditPage 一致，用 AppStorage 预置，页面自己读。
//   新建：pendingTodoId = 0，pendingTodoDate = 预填截止日（毫秒，0 = 不预填）
//   编辑：pendingTodoId = 本地库 id
import { router, KeyboardAvoidMode } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AccountStore, CalSource, DavAccount } from '../common/AccountStore';
import { EventDb, LocalEvent } from '../common/EventDb';
import { TodoService } from '../common/TodoService';
import { CalendarDataService, DisplayEvent, DraftTransfer } from '../common/CalendarDataService';
import { CardDataService } from '../common/CardDataService';
import { ReminderService } from '../common/ReminderService';
import { LogUtil } from '../common/LogUtil';
import { IcsUtil, AttachMeta } from '../common/IcsUtil';

/** 提醒选项（分钟） */
class ReminderOpt {
  v: number = 0;
  label: string = '';
}

/** 优先级选项 */
class PriorityOpt {
  v: number = 0;
  label: string = '';
  color: string = '';
}

/** 循环选项 */
class RecurOpt {
  v: string = '';
  label: string = '';
}

@Entry
@Component
struct TodoEditPage {
  // ---------- 基础 ----------
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State creating: boolean = true;      // true=新建 false=编辑
  @State editId: number = 0;
  @State writable: boolean = true;
  @State books: CalSource[] = [];
  @State bookKey: string = '';           // 新建时选中的本
  /** calKey → 集合 href（CalSource 没有 href 字段，需从账号里按 calKey 反解） */
  private bookHrefs: Map<string, string> = new Map<string, string>();
  @State bookName: string = '';          // 编辑时只读显示的本名

  // ---------- 表单字段 ----------
  @State title: string = '';
  @State desc: string = '';
  @State hasDue: boolean = false;
  @State dueMs: number = 0;
  @State recur: string = '';             // '' = 不循环
  @State priority: number = 0;
  @State categories: string = '';
  @State location: string = '';
  @State reminders: number[] = [];
  @State parentUid: string = '';
  @State attachments: string = '';       // 附件 JSON

  // ---------- 截止时间选择器 ----------
  @State pickShow: boolean = false;
  /**
   * ⭐ 页面唯一底部弹层（ArkUI 同一页面挂多个 bindSheet 会互相覆盖，
   *    实测表现为"白框一闪而过"）。用 sheetMode 切换内容：
   *      'due'    → 截止时间（日期 + 时间滚轮）
   *      'parent' → 父任务选择
   */
  @State sheetShow: boolean = false;
  @State sheetMode: string = 'due';
  @State pickDate: Date = new Date();
  @State pickHour: number = 9;
  @State pickMin: number = 0;

  // ---------- 父任务选择 ----------
  @State parentPickShow: boolean = false;
  @State allTodos: DisplayEvent[] = [];  // 用于父任务候选 + 显示名

  // ---------- 附件 ----------
  @State attachBusy: boolean = false;

  private formScroller: Scroller = new Scroller();

  // 选项表
  private reminderOpts: ReminderOpt[] = [
    { v: 0, label: '不提醒' },
    { v: -1, label: '准时' },
    { v: 5, label: '提前5分钟' },
    { v: 15, label: '提前15分钟' },
    { v: 60, label: '提前1小时' },
    { v: 180, label: '提前3小时' },
    { v: 1440, label: '提前1天' }
  ];
  private priorityOpts: PriorityOpt[] = [
    { v: 0, label: '无', color: '#9AA0A6' },
    { v: 1, label: '最高', color: '#FF3B30' },
    { v: 5, label: '中', color: '#FF9500' },
    { v: 9, label: '低', color: '#34C759' }
  ];
  private recurOpts: RecurOpt[] = [
    { v: '', label: '不循环' },
    { v: 'DAILY', label: '每天' },
    { v: 'WEEKLY', label: '每周' },
    { v: 'MONTHLY', label: '每月' }
  ];

  /** 键盘避让（与日程页一致）：RESIZE 模式，避免键盘遮挡底部字段 */
  private setupKeyboardAvoid(): void {
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (err) {
      // 低版本不支持，忽略（只是少一层校正）
    }
  }

  aboutToAppear(): void {
    this.setupKeyboardAvoid();
    this.initPage();
  }

  /** 读 AppStorage 参数并初始化表单 */
  private async initPage(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.loading = false;
      return;
    }
    const pendingId: number = AppStorage.get<number>('pendingTodoId') ?? 0;
    // 清理，避免下次误读
    AppStorage.setOrCreate<number>('pendingTodoId', 0);

    try {
      // 可写日历本（新建时供选择）
      // 只取可写 + dav 来源 + 能放待办的本（comps 不是 event）
      const sources: CalSource[] = await CalendarDataService.loadSources(ctx);
      const accounts: DavAccount[] = await AccountStore.loadAll(ctx);
      this.bookHrefs.clear();
      const writable: CalSource[] = [];
      for (const s of sources) {
        if (!s.writable || s.source !== 'dav') {
          continue;
        }
        // ⭐ 纯日历本（COMP_SET 只有 VEVENT）写不进 VTODO，排除。
        //    'both' / 'unknown' 保留（unknown 是服务器未声明或旧数据，不能武断排除）。
        if (s.comps === 'event') {
          continue;
        }
        const us: number = s.calKey.lastIndexOf('_');
        if (us <= 0) {
          continue;
        }
        const accId: string = s.calKey.substring(0, us);
        const idx: number = parseInt(s.calKey.substring(us + 1), 10);
        if (isNaN(idx)) {
          continue;
        }
        const acc: DavAccount | undefined = accounts.find(
          (a: DavAccount): boolean => String(a.id) === accId);
        if (acc === undefined || idx < 0 || idx >= acc.calendarHrefs.length) {
          continue;
        }
        this.bookHrefs.set(s.calKey, acc.calendarHrefs[idx]);
        writable.push(s);
      }
      this.books = writable;

      // 全部待办（父任务候选 + 名称显示）
      this.allTodos = await CalendarDataService.loadTodos(ctx, sources);

      if (pendingId > 0) {
        this.creating = false;
        this.editId = pendingId;
        await this.fillFromRow(ctx, pendingId);
      } else {
        this.creating = true;
        // 默认选第一个可写本
        if (this.books.length > 0) {
          this.bookKey = this.books[0].calKey;
        }
        // ⭐ 新建待办默认**无截止时间**（hasDue 保持 false）。
        //    待办是"要完成的事"，不是"发生在某天的事"，多数一开始不确定哪天截止。
        //    日期选择器只预置一个合理的初始值（明天），用户点了才会真正设置。
        const base = new Date();
        this.pickDate = new Date(base.getFullYear(), base.getMonth(), base.getDate() + 1);
        this.pickHour = 9;
        this.pickMin = 0;
        this.hasDue = false;
        this.dueMs = 0;

        const draft: DraftTransfer | undefined = AppStorage.get<DraftTransfer>('editDraftTransfer');
        if (draft !== undefined && draft !== null) {
          AppStorage.setOrCreate<DraftTransfer | null>('editDraftTransfer', null);
          this.title = draft.title;
          this.desc = draft.description;
          if (draft.chosenKey !== '' && this.books.some((b: CalSource) => b.calKey === draft.chosenKey)) {
            this.bookKey = draft.chosenKey;
          }
          if (draft.startTime > 0) {
            this.hasDue = true;
            this.dueMs = draft.startTime;
            this.pickDate = new Date(draft.startTime);
            const d = new Date(draft.startTime);
            this.pickHour = d.getHours();
            this.pickMin = d.getMinutes();
          }
          if (draft.reminders && draft.reminders.length > 0) {
            this.reminders = draft.reminders;
          }
        }
      }
    } catch (err) {
      LogUtil.write(`待办编辑页初始化失败: ${(err as BusinessError).message ?? ''}`);
    } finally {
      this.loading = false;
    }
  }

  /** 从本地库读一条待办填充表单 */
  private async fillFromRow(ctx: common.Context, id: number): Promise<void> {
    const row: LocalEvent | null = await EventDb.queryById(ctx, id);
    if (row === null) {
      return;
    }
    this.title = row.title;
    this.desc = row.description;
    this.hasDue = row.startTime > 0;
    this.dueMs = row.startTime > 0 ? row.startTime : 0;
    this.bookName = this.bookNameOf(row.calKey);
    this.writable = true;
    this.recur = row.rrule !== '' ? IcsUtil.freqOfRrule(row.rrule) : '';
    this.priority = row.priority > 0 ? row.priority : 0;
    this.categories = row.categories;
    this.location = row.location;
    this.reminders = row.reminders.slice();
    this.parentUid = row.parentUid;
    this.attachments = row.attachments;
    // 选择器初值
    const d = new Date(row.startTime > 0 ? row.startTime : Date.now());
    this.pickDate = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    this.pickHour = d.getHours();
    this.pickMin = d.getMinutes();
  }

  private bookNameOf(calKey: string): string {
    for (const b of this.books) {
      if (b.calKey === calKey) {
        return b.name;
      }
    }
    return '';
  }

  // ---------- 保存 ----------
  private async save(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined || this.busy) {
      return;
    }
    const t: string = this.title.trim();
    if (t === '') {
      this.getUIContext().getPromptAction().showToast({ message: '请填写待办标题' });
      return;
    }
    this.busy = true;
    try {
      const due: number = this.hasDue ? this.dueMs : 0;
      const dateOnly: boolean = due > 0 && due % 86400000 === 0;

      if (this.creating) {
        const href: string = this.hrefOf(this.bookKey);
        if (href === '') {
          this.getUIContext().getPromptAction().showToast({ message: '请选择日历本' });
          this.busy = false;
          return;
        }
        const newId: number = await TodoService.createTodo(ctx, href, t, this.desc,
          due, dateOnly, this.priority, this.categories, this.location,
          this.reminders, this.parentUid, this.attachments);
        if (newId > 0) {
          this.getUIContext().getPromptAction().showToast({ message: '待办已创建' });
          router.back();
          return;
        }
        this.getUIContext().getPromptAction().showToast({
          message: '创建失败：需联网，且该日历本需可写'
        });
      } else {
        const ok: boolean = await TodoService.updateTodo(ctx, this.editId, t, this.desc,
          due, this.priority, this.categories, this.location, this.reminders,
          this.parentUid, this.attachments, true, true);
        if (ok) {
          // 循环规则单独写（与弹层时代一致：要先有截止时间才有意义）
          const wantRule: string = this.recur !== '' ? `FREQ=${this.recur}` : '';
          if (due > 0) {
            await TodoService.setRecurrence(ctx, this.editId, wantRule, due);
          }
          this.getUIContext().getPromptAction().showToast({ message: '已保存' });
          router.back();
          return;
        }
        this.getUIContext().getPromptAction().showToast({
          message: '保存失败：需联网，且该日历本需可写'
        });
      }
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '保存失败，请稍后重试' });
    } finally {
      this.busy = false;
    }
  }

  private hrefOf(calKey: string): string {
    return this.bookHrefs.get(calKey) ?? '';
  }

  // ---------- 删除 ----------
  private askDelete(): void {
    this.getUIContext().showAlertDialog({
      title: '删除待办',
      message: '将从服务器删除这条待办，删除后无法撤销。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: (): void => {
          this.doDelete();
        }
      }
    });
  }

  private async doDelete(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ok: boolean = await TodoService.deleteTodo(ctx, this.editId);
      if (ok) {
        this.getUIContext().getPromptAction().showToast({ message: '已删除' });
        router.back();
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '删除失败，请稍后重试' });
      }
    } finally {
      this.busy = false;
    }
  }

  // ---------- 附件 ----------
  private attachList(): AttachMeta[] {
    return IcsUtil.jsonToAttachMeta(this.attachments);
  }

  private removeAttach(idx: number): void {
    const list: AttachMeta[] = this.attachList();
    if (idx < 0 || idx >= list.length) {
      return;
    }
    list.splice(idx, 1);
    this.attachments = IcsUtil.attachMetaToJson(list);
  }

  private async pickAttachment(ctx: common.Context): Promise<void> {
    if (this.attachBusy) {
      return;
    }
    this.attachBusy = true;
    try {
      const pw = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await pw.select({ maxSelectNumber: 3 });
      if (uris.length === 0) {
        return;
      }
      const existing: AttachMeta[] = this.attachList();
      if (existing.length + uris.length > 3) {
        this.getUIContext().getPromptAction().showToast({ message: '最多 3 个附件' });
        return;
      }
      const merged: AttachMeta[] = existing.slice();
      for (const uri of uris) {
        const m: AttachMeta | null = this.readAttach(uri);
        if (m !== null) {
          merged.push(m);
        }
      }
      this.attachments = IcsUtil.attachMetaToJson(merged);
    } catch (err) {
      // 用户取消也会走这里
    } finally {
      this.attachBusy = false;
    }
  }

  private readAttach(uri: string): AttachMeta | null {
    try {
      const f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const st = fs.statSync(f.fd);
      if (st.size <= 0 || st.size > 5 * 1024 * 1024) {
        fs.closeSync(f.fd);
        return null;
      }
      const buf: ArrayBuffer = new ArrayBuffer(st.size);
      const n: number = fs.readSync(f.fd, buf);
      fs.closeSync(f.fd);
      if (n <= 0) {
        return null;
      }
      const base64: string = new util.Base64Helper().encodeToStringSync(new Uint8Array(buf));
      let name: string = uri.substring(uri.lastIndexOf('/') + 1);
      const q: number = name.indexOf('?');
      if (q >= 0) {
        name = name.substring(0, q);
      }
      if (name === '') {
        name = '附件';
      }
      const m = new AttachMeta();
      m.name = name;
      m.mime = this.mimeOf(name);
      m.base64 = base64;
      return m;
    } catch (err) {
      return null;
    }
  }

  private mimeOf(name: string): string {
    const l: string = name.toLowerCase();
    if (l.endsWith('.pdf')) { return 'application/pdf'; }
    if (l.endsWith('.png')) { return 'image/png'; }
    if (l.endsWith('.jpg') || l.endsWith('.jpeg')) { return 'image/jpeg'; }
    if (l.endsWith('.txt')) { return 'text/plain'; }
    if (l.endsWith('.csv')) { return 'text/csv'; }
    if (l.endsWith('.zip')) { return 'application/zip'; }
    return 'application/octet-stream';
  }

  // ---------- 父任务 ----------
  private currentUid(): string {
    for (const t of this.allTodos) {
      if (t.id === this.editId) {
        return t.uid;
      }
    }
    return '';
  }

  private parentCandidates(): DisplayEvent[] {
    const self: string = this.currentUid();
    const exclude: Set<string> = new Set<string>();
    if (self !== '') {
      exclude.add(self);
      const q: string[] = [self];
      let guard = 0;
      while (q.length > 0 && guard < 200) {
        const cur: string = q.shift() as string;
        for (const t of this.allTodos) {
          if (t.parentUid === cur && !exclude.has(t.uid)) {
            exclude.add(t.uid);
            q.push(t.uid);
          }
        }
        guard++;
      }
    }
    const out: DisplayEvent[] = [];
    for (const t of this.allTodos) {
      if (t.completed || t.parentUid !== '') {
        continue;
      }
      if (exclude.has(t.uid)) {
        continue;
      }
      out.push(t);
    }
    return out;
  }

  private parentName(): string {
    if (this.parentUid === '') {
      return '无';
    }
    for (const t of this.allTodos) {
      if (t.uid === this.parentUid) {
        return t.title === '' ? '(无标题)' : t.title;
      }
    }
    return '（已不存在）';
  }

  // ---------- 显示 ----------
  private getWeekDayStr(d: Date): string {
    const w = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    return w[d.getDay()];
  }

  private fmtDateWithWeek(d: Date): string {
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    const w = this.getWeekDayStr(d);
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${w}`;
  }

  private fmtDue(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    const w = this.getWeekDayStr(d);
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${w} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  private reminderActive(v: number): boolean {
    if (v === 0) {
      return this.reminders.length === 0;
    }
    return this.reminders.indexOf(v) >= 0;
  }

  private toggleReminder(v: number): void {
    if (v === 0) {
      this.reminders = [];
      return;
    }
    const idx: number = this.reminders.indexOf(v);
    if (idx >= 0) {
      this.reminders = this.reminders.filter((n: number): boolean => n !== v);
    } else {
      this.reminders = this.reminders.concat([v]);
    }
  }

  // ---------- UI ----------
  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
      // ===== 固定顶部栏：取消 · 标题 · 保存 =====
      Row({ space: 6 }) {
        Text('取消')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
          .padding({ left: 4, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            router.back();
          })
        Blank()
        if (this.creating) {
          Row() {
            Text('日程')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 12, right: 12, top: 4, bottom: 4 })
              .onClick(() => {
                const draft = new DraftTransfer();
                draft.title = this.title;
                draft.description = this.desc;
                draft.chosenKey = this.bookKey;
                draft.startTime = this.hasDue ? this.dueMs : Date.now();
                draft.reminders = this.reminders;
                AppStorage.setOrCreate<DraftTransfer>('editDraftTransfer', draft);
                router.replaceUrl({ url: 'pages/EventEditPage' });
              })
            Text('待办')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(14)
              .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          }
          .padding(2)
          .borderRadius(16)
          .backgroundColor($r('app.color.chip_off_bg'))
        } else {
          Text('编辑待办')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        }
        Blank()
        Text(this.busy ? '保存中…' : '保存')
          .fontSize(16)
          .fontColor(this.busy ? $r('app.color.text_hint') : $r('app.color.brand'))
          .fontWeight(FontWeight.Medium)
          .padding({ left: 4, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      // ===== 中间表单：整页可滚动 =====
      Scroll(this.formScroller) {
        Column({ space: 14 }) {
          // 标题
          TextInput({ text: this.title, placeholder: '待办标题（必填）' })
            .height(46)
            .fontSize(16)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_hint'))
            .caretColor($r('app.color.brand'))
            .onChange((v: string) => {
              this.title = v;
            })

          // 日历本
          if (this.creating) {
            this.formLabel('日历本')
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.books, (b: CalSource) => {
                Row({ space: 6 }) {
                  Circle().width(8).height(8).fill(b.color)
                  Text(b.name)
                    .fontSize(13)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor(this.bookKey === b.calKey
                      ? $r('app.color.button_text') : $r('app.color.text_primary'))
                }
                .width('48%')
                .padding({ left: 10, right: 10, top: 9, bottom: 9 })
                .borderRadius(14)
                .margin({ bottom: 8 })
                .backgroundColor(this.bookKey === b.calKey ? b.color : $r('app.color.chip_off_bg'))
                .onClick(() => {
                  this.bookKey = b.calKey;
                })
              }, (b: CalSource) => `bk_${b.calKey}`)
            }
            .width('100%')
          } else if (this.bookName !== '') {
            this.formLabel('日历本')
            Row({ space: 6 }) {
              Text(this.bookName)
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Blank()
            }
            .width('100%')
            .padding(12)
            .borderRadius(10)
            .backgroundColor($r('app.color.card_bg'))
          }

          // 截止时间
          this.formLabel('截止时间')
          Row({ space: 8 }) {
            Row({ space: 6 }) {
              Text(this.hasDue ? this.fmtDue(this.dueMs) : '无截止时间')
                .fontSize(14)
                .fontColor(this.hasDue
                  ? $r('app.color.text_primary') : $r('app.color.text_hint'))
              Blank()
              // ⭐ 不再显示"修改"文字：整行可点，右侧放个箭头作为可点的视觉暗示
              //    （与日程页的「开始/结束时间」行一致）
              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_hint'))
            }
            .layoutWeight(1)
            .padding({ left: 12, right: 12, top: 12, bottom: 12 })
            .borderRadius(10)
            .backgroundColor($r('app.color.card_bg'))
            .onClick(() => {
              this.sheetMode = 'due';
              this.sheetShow = true;
            })
            if (this.hasDue) {
              Text('清除')
                .fontSize(13)
                .fontColor($r('app.color.brand_text'))
                .padding({ left: 8, right: 8, top: 12, bottom: 12 })
                .onClick(() => {
                  this.hasDue = false;
                  this.dueMs = 0;
                })
            }
          }
          .width('100%')

          // 循环
          this.formLabel('重复')
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.recurOpts, (o: RecurOpt) => {
              Text(o.label)
                .fontSize(13)
                .fontColor(this.recur === o.v
                  ? $r('app.color.button_text') : $r('app.color.text_primary'))
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .borderRadius(14)
                .margin({ right: 8, bottom: 8 })
                .backgroundColor(this.recur === o.v
                  ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
                .onClick(() => {
                  this.recur = o.v;
                })
            }, (o: RecurOpt) => `rc_${o.v}`)
          }
          .width('100%')
          if (this.recur !== '' && !this.hasDue) {
            Text('提示：循环任务需要有截止时间，才能算出下一次')
              .fontSize(11)
              .fontColor($r('app.color.error'))
              .width('100%')
          }

          // 优先级
          this.formLabel('优先级')
          Row({ space: 8 }) {
            ForEach(this.priorityOpts, (o: PriorityOpt) => {
              Row({ space: 4 }) {
                Circle().width(7).height(7).fill(o.color)
                Text(o.label)
                  .fontSize(13)
                  .fontColor(this.priority === o.v
                    ? $r('app.color.button_text') : $r('app.color.text_primary'))
              }
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .borderRadius(14)
              .backgroundColor(this.priority === o.v
                ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
              .onClick(() => {
                this.priority = o.v;
              })
            }, (o: PriorityOpt) => `pr_${o.v}`)
            Blank()
          }
          .width('100%')

          // 提醒
          this.formLabel('提醒')
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.reminderOpts, (o: ReminderOpt) => {
              Text(o.label)
                .fontSize(13)
                .fontColor(this.reminderActive(o.v)
                  ? $r('app.color.button_text') : $r('app.color.text_primary'))
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .borderRadius(14)
                .margin({ right: 8, bottom: 8 })
                .backgroundColor(this.reminderActive(o.v)
                  ? $r('app.color.brand') : $r('app.color.chip_off_bg'))
                .onClick(() => {
                  this.toggleReminder(o.v);
                })
            }, (o: ReminderOpt) => `rm_${o.v}`)
          }
          .width('100%')

          // 标签
          this.formLabel('标签')
          TextInput({ text: this.categories, placeholder: '多个用逗号分隔' })
            .height(46)
            .fontSize(14)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_hint'))
            .onChange((v: string) => {
              this.categories = v;
            })

          // 地点
          this.formLabel('地点')
          TextInput({ text: this.location, placeholder: '可选' })
            .height(46)
            .fontSize(14)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_hint'))
            .onChange((v: string) => {
              this.location = v;
            })

          // 父任务
          this.formLabel('父任务')
          Row({ space: 8 }) {
            Text(this.parentName())
              .fontSize(14)
              .fontColor(this.parentUid === ''
                ? $r('app.color.text_hint') : $r('app.color.text_primary'))
            Blank()
            if (this.parentUid !== '') {
              Text('清除')
                .fontSize(13)
                .fontColor($r('app.color.brand_text'))
                .onClick(() => {
                  this.parentUid = '';
                })
            } else {
              Text('选择')
                .fontSize(13)
                .fontColor($r('app.color.brand'))
                .onClick(() => {
                  this.sheetMode = 'parent';
                  this.sheetShow = true;
                })
            }
          }
          .width('100%')
          .padding(12)
          .borderRadius(10)
          .backgroundColor($r('app.color.card_bg'))
          .onClick(() => {
            this.sheetMode = 'parent';
            this.sheetShow = true;
          })

          // 附件
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Text('附件')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
              Blank()
              if (this.attachList().length < 3) {
                Text('添加文件')
                  .fontSize(13)
                  .fontColor($r('app.color.brand'))
                  .onClick(() => {
                    const c = this.getUIContext().getHostContext();
                    if (c !== undefined) {
                      this.pickAttachment(c);
                    }
                  })
              }
            }
            .width('100%')

            ForEach(this.attachList(), (m: AttachMeta, idx: number) => {
              Row({ space: 8 }) {
                Text(m.name)
                  .fontSize(13)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text('✕')
                  .fontSize(13)
                  .fontColor($r('app.color.text_hint'))
                  .onClick(() => {
                    this.removeAttach(idx);
                  })
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .borderRadius(8)
              .backgroundColor($r('app.color.card_bg'))
            }, (m: AttachMeta, idx: number) => `at_${idx}_${m.name}`)
          }
          .width('100%')

          // 备注
          this.formLabel('备注')
          TextArea({ text: this.desc, placeholder: '备注（可选）' })
            .fontSize(14)
            .height(100)
            .borderRadius(12)
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_hint'))
            .onChange((v: string) => {
              this.desc = v;
            })

          // 删除（编辑态，放表单最底部，与日程页一致）
          if (!this.creating && this.writable) {
            Button('删除待办')
              .width('100%')
              .height(46)
              .borderRadius(12)
              .fontSize(15)
              .fontColor($r('app.color.error'))
              .backgroundColor($r('app.color.chip_off_bg'))
              .margin({ top: 8 })
              .onClick(() => {
                this.askDelete();
              })
          }

          // 底部留白，避免最后一个字段贴屏幕边缘
          Blank().height(24)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 24 })
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
      // ⭐ 沉浸式：背景延伸到状态栏/导航条区域（与 EventEditPage 一致）
      //    只扩绘制范围、不移动子组件 → 状态栏区域同色，不再是割裂的白条
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // ===== 居中弹层（浮在内容之上）=====
      if (this.sheetShow) {
        // 遮罩：半透明，点空白关闭
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.sheetShow = false;
          })
        // 居中卡片
        this.centerDialog()
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 居中弹层（自绘覆盖层，不用 bindSheet）。
   *
   * 为什么不用 bindSheet：SDK 的 SheetOptions 没有 position/alignment，
   * 只能从底部弹，无法居中。而用户要求"在中间弹出来更方便"。
   * 本工程既有的 tipsOverlay 也是自绘覆盖层（系统弹层在本环境不可靠），
   * 这里沿用同一套做法。
   */
  @Builder
  centerDialog() {
    if (this.sheetMode === 'parent') {
      this.parentDialog()
    } else {
      this.dueDialog()
    }
  }

  /** 截止时间选择弹层（居中卡片：日期 + 时间） */
  @Builder
  dueDialog() {
    Column({ space: 10 }) {
      Column({ space: 4 }) {
        Text('选择截止时间')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.fmtDateWithWeek(this.pickDate))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
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
          // 滚轮文字显式指定颜色：默认取系统主题色，深色模式下会与弹层底色撞色
          .textStyle({ color: $r('app.color.text_secondary'), font: { size: 14 } })
          .selectedTextStyle({
            color: $r('app.color.text_primary'),
            font: { size: 16, weight: FontWeight.Medium }
          })
          .disappearTextStyle({ color: $r('app.color.text_hint'), font: { size: 14 } })
          .layoutWeight(1)
          .height(210)
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
      .width('100%')

      Button('确定')
        .width('100%')
        .height(44)
        .borderRadius(12)
        .fontSize(15)
        .fontColor($r('app.color.button_text'))
        .backgroundColor($r('app.color.brand'))
        .onClick(() => {
          this.confirmDue();
          this.sheetShow = false;
        })
    }
    .width('86%')
    .padding(18)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
  }

  /** 父任务选择弹层（居中卡片） */
  @Builder
  parentDialog() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('选择父任务')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('无父任务')
          .fontSize(14)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            this.parentUid = '';
            this.sheetShow = false;
          })
      }
      .width('100%')
      .padding({ top: 12 })

      if (this.parentCandidates().length === 0) {
        Text('没有可选的顶层任务')
          .fontSize(13)
          .fontColor($r('app.color.text_hint'))
          .padding(20)
      } else {
        List({ space: 6 }) {
          ForEach(this.parentCandidates(), (c: DisplayEvent) => {
            ListItem() {
              Row({ space: 8 }) {
                Circle().width(8).height(8).fill(c.color)
                Text(c.title === '' ? '(无标题待办)' : c.title)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                if (this.parentUid === c.uid) {
                  Text('✓')
                    .fontSize(14)
                    .fontColor($r('app.color.brand'))
                }
              }
              .width('100%')
              .padding(12)
              .borderRadius(10)
              .backgroundColor($r('app.color.chip_off_bg'))
            }
            .width('100%')
            .onClick(() => {
              this.parentUid = c.uid;
              this.sheetShow = false;
            })
          }, (c: DisplayEvent) => `pc_${c.uid}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }

      Button('取消')
        .width('100%')
        .height(44)
        .borderRadius(12)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.chip_off_bg'))
        .onClick(() => {
          this.sheetShow = false;
        })
    }
    .width('86%')
    .padding(18)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
  }

  /** 确认截止时间：把滚轮值合成毫秒 */
  private confirmDue(): void {
    const d: Date = this.pickDate;
    this.dueMs = new Date(d.getFullYear(), d.getMonth(), d.getDate(),
      this.pickHour, this.pickMin).getTime();
    this.hasDue = true;
  }

  /** 字段小标题 */
  @Builder
  formLabel(txt: string) {
    Text(txt)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .textAlign(TextAlign.Start)
  }
}