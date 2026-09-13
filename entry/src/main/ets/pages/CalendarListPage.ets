// entry/src/main/ets/pages/CalendarListPage.ets
// 添加账号第二页：PROPFIND 列出日历本 → 勾选 → 命名 → 保存账号
import { http } from '@kit.NetworkKit';
import { router } from '@kit.ArkUI';
import { buffer } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, TYPE_CALDAV } from '../common/AccountStore';
import { LogUtil } from '../common/LogUtil';

/**
 * 日历本条目（@Observed 使勾选状态变化能刷新 UI）
 */
@Observed
export class CalendarItem {
  href: string;
  name: string;
  color: string; // 服务器定义的颜色（calendar-color），可能为空
  selected: boolean;

  constructor(href: string, name: string, color: string) {
    this.href = href;
    this.name = name;
    this.color = color;
    this.selected = false;
  }
}

@Entry
@Component
struct CalendarListPage {
  @State calendarList: CalendarItem[] = [];
  @State accountName: string = '';
  @State isLoading: boolean = true;
  @State statusMsg: string = '正在获取日历列表…';
  @State statusOk: boolean = false;
  @State isSaving: boolean = false;
  @State selectedCount: number = 0;
  @State allSelected: boolean = false;
  private serverUrl: string = '';
  private username: string = '';
  private password: string = '';

  aboutToAppear(): Promise<void> {
    return this.initPage();
  }

  private async initPage(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      LogUtil.init(ctx);
    }
    this.serverUrl = AppStorage.get<string>('pendingDavUrl') ?? '';
    this.username = AppStorage.get<string>('pendingDavUsername') ?? '';
    this.password = AppStorage.get<string>('pendingDavPassword') ?? '';
    LogUtil.write(`添加账号流程开始：服务器=${this.serverUrl} 用户名=${this.username}`);
    if (this.serverUrl === '') {
      this.isLoading = false;
      this.statusMsg = '尚未连接服务器，请先返回重新连接';
      this.statusOk = false;
      return;
    }
    await this.fetchCalendars();
  }

  private encodeBasicAuth(): string {
    try {
      return buffer.from(`${this.username}:${this.password}`).toString('base64');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`Base64 编码失败: ${e.message}`);
      return '';
    }
  }

  private async fetchCalendars(): Promise<void> {
    const token: string = this.encodeBasicAuth();
    if (token === '') {
      this.isLoading = false;
      this.statusMsg = '凭据编码失败：请在真机或模拟器上运行';
      this.statusOk = false;
      return;
    }
    const requestBody: string = '<?xml version="1.0" encoding="utf-8"?>' +
      '<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/" ' +
      'xmlns:ical="http://apple.com/ns/ical/"><d:prop>' +
      '<d:displayname/><d:resourcetype/><cs:getcolor/><ical:calendar-color/>' +
      '</d:prop></d:propfind>';
    const httpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(this.serverUrl, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': 'Basic ' + token,
          'Content-Type': 'application/xml; charset=utf-8',
          'Depth': '1',
          'User-Agent': 'SyncCalendar/1.0'
        },
        extraData: requestBody,
        connectTimeout: 10000,
        readTimeout: 15000
      });
      console.info(`PROPFIND 响应码: ${resp.responseCode}`);
      if (resp.responseCode === 401) {
        this.isLoading = false;
        this.statusMsg = '登录已失效，请返回重新连接';
        this.statusOk = false;
        return;
      }
      if (resp.responseCode !== 207 && resp.responseCode !== 200) {
        this.isLoading = false;
        this.statusMsg = `获取日历列表失败，服务器返回：${resp.responseCode}`;
        this.statusOk = false;
        return;
      }
      const xml: string = resp.result as string;
      LogUtil.write(`添加账号 PROPFIND → ${resp.responseCode}，响应体 ${xml.length} 字符`);
      const list: CalendarItem[] = this.parseCalendarList(xml);
      for (const item of list) {
        LogUtil.write(`发现日历本：「${item.name}」${item.href} 颜色=${item.color === '' ? '(无)' : item.color}`);
      }
      this.isLoading = false;
      if (list.length === 0) {
        this.statusMsg = '该路径下未发现日历本（没有包含 calendar 资源类型的集合）';
        this.statusOk = false;
      } else {
        this.calendarList = list;
        this.updateSelectionState();
        this.statusMsg = `发现 ${list.length} 个日历本，请勾选要同步的日历`;
        this.statusOk = true;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`获取日历列表失败: ${e.code} - ${e.message}`);
      this.isLoading = false;
      this.statusMsg = `获取日历列表失败：${e.message}`;
      this.statusOk = false;
    } finally {
      httpRequest.destroy();
    }
  }

  private extractTag(xml: string, tag: string): string {
    const pattern: string = '<([\\w-]+:)?' + tag + '(?:\\s[^>]*)?>([\\s\\S]*?)<\\/([\\w-]+:)?' + tag + '>';
    const regex: RegExp = new RegExp(pattern, 'i');
    const match = regex.exec(xml);
    return match !== null ? match[2].trim() : '';
  }

  private parseCalendarList(xml: string): CalendarItem[] {
    const items: CalendarItem[] = [];
    const originMatch = /https?:\/\/[^/]+/i.exec(this.serverUrl);
    const origin: string = originMatch !== null ? originMatch[0] : '';
    const blocks: string[] = xml.split(/<\/[\w-]*:?response>/i);
    for (const block of blocks) {
      if (!/<[\w-]*:?response[\s>]/i.test(block)) {
        continue;
      }
      const href: string = this.extractTag(block, 'href');
      if (href === '') {
        continue;
      }
      const resourcetype: string = this.extractTag(block, 'resourcetype');
      if (!/calendar/i.test(resourcetype)) {
        continue;
      }
      let name: string = this.extractTag(block, 'displayname');
      if (name === '') {
        const segs: string[] = href.split('/').filter((s: string) => s !== '');
        if (segs.length > 0) {
          try {
            name = decodeURIComponent(segs[segs.length - 1]);
          } catch (err) {
            name = segs[segs.length - 1];
          }
        } else {
          name = href;
        }
      }
      // 服务器端颜色：cs:getcolor 或 ical:calendar-color，带 Alpha 时转成 #RRGGBB
      let color: string = AccountStore.normalizeColor(this.extractTag(block, 'getcolor'));
      if (color === '') {
        color = AccountStore.normalizeColor(this.extractTag(block, 'calendar-color'));
      }
      const fullHref: string = href.startsWith('http') ? href : origin + href;
      items.push(new CalendarItem(fullHref, name, color));
    }
    return items;
  }

  private async saveSelection(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    if (this.accountName.trim() === '') {
      this.statusMsg = '请先给这个日历账户起一个名字';
      this.statusOk = false;
      return;
    }
    const selectedItems: CalendarItem[] = this.calendarList.filter((c: CalendarItem) => c.selected);
    if (selectedItems.length === 0) {
      this.statusMsg = '请至少勾选一个日历本';
      this.statusOk = false;
      return;
    }
    this.isSaving = true;
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        this.statusMsg = '无法获取应用上下文';
        this.statusOk = false;
        this.isSaving = false;
        return;
      }
      const acc = new DavAccount();
      acc.id = String(Date.now());
      const accType: string | undefined = AppStorage.get<string>('pendingAccountType');
      acc.type = (accType === undefined || accType === '') ? TYPE_CALDAV : accType;
      acc.name = this.accountName.trim();
      acc.serverUrl = this.serverUrl;
      acc.username = this.username;
      acc.password = this.password;
      acc.calendarHrefs = selectedItems.map((c: CalendarItem): string => c.href);
      acc.calendarNames = selectedItems.map((c: CalendarItem): string => c.name);
      acc.calendarColors = selectedItems.map((c: CalendarItem): string => c.color);
      LogUtil.write(`保存账号「${acc.name}」：id=${acc.id}，勾选 ${selectedItems.length}/${this.calendarList.length} 个日历本`);
      await AccountStore.addAccount(context, acc);
      AppStorage.setOrCreate<string>('pendingSyncAccountId', acc.id);
      this.getUIContext().getPromptAction()
        .showToast({ message: `账号已保存，共 ${selectedItems.length} 个日历本` });
      this.statusMsg = '保存成功';
      this.statusOk = true;
      router.back({ url: 'pages/AccountsPage' });
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存失败: ${e.code} - ${e.message}`);
      this.statusMsg = `保存失败：${e.message}`;
      this.statusOk = false;
    }
    this.isSaving = false;
  }

  private updateSelectionState(): void {
    const count: number = this.calendarList.filter((c: CalendarItem): boolean => c.selected).length;
    this.selectedCount = count;
    this.allSelected = this.calendarList.length > 0 && count === this.calendarList.length;
  }

  private handleItemToggle(item: CalendarItem): void {
    item.selected = !item.selected;
    this.updateSelectionState();
  }

  private toggleAll(): void {
    const target: boolean = !this.allSelected;
    this.calendarList.forEach((c: CalendarItem) => {
      c.selected = target;
    });
    this.updateSelectionState();
  }

  build() {
    Column({ space: 14 }) {
      Row({ space: 6 }) {
        Text('←')
          .fontSize(18)
          .fontColor($r('app.color.brand'))
        Text('返回')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
      }
      .width('100%')
      .onClick(() => {
        router.back();
      })

      Column({ space: 6 }) {
        Text('选择日历本')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('勾选需要同步的日历本，并为账户命名')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column({ space: 8 }) {
        Row({ space: 4 }) {
          Text('日历账户名称')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Medium)
          Text('*')
            .fontSize(15)
            .fontColor($r('app.color.error'))
        }
        TextInput({ text: this.accountName, placeholder: '例如：我的群晖日历' })
          .height(46)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_hint'))
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(10)
          .border({ width: 1.5, color: $r('app.color.brand') })
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.accountName = value;
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(14)
      .borderRadius(14)
      .backgroundColor($r('app.color.card_bg'))
      .border({ width: 1, color: $r('app.color.shadow_color') })

      Row({ space: 8 }) {
        Text(this.calendarList.length > 0
          ? `已选 ${this.selectedCount} / ${this.calendarList.length}` : ' ')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        if (this.calendarList.length > 0) {
          Button(this.allSelected ? '取消全选' : '全选')
            .fontSize(13)
            .fontColor($r('app.color.brand'))
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: $r('app.color.brand'), radius: 14 })
            .height(30)
            .padding({ left: 14, right: 14 })
            .onClick(() => {
              this.toggleAll();
            })
        }
      }
      .width('100%')

      Scroll() {
        Column({ space: 4 }) {
          if (this.isLoading) {
            Column({ space: 12 }) {
              LoadingProgress()
                .width(36)
                .height(36)
                .color($r('app.color.brand'))
              Text('正在从服务器获取日历列表…')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding(32)
          } else if (this.calendarList.length === 0) {
            Text(this.statusMsg)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding(24)
              .textAlign(TextAlign.Center)
          } else {
            ForEach(this.calendarList, (item: CalendarItem) => {
              CalendarRow({
                item: item,
                onSelect: (selectedItem: CalendarItem): void => {
                  this.handleItemToggle(selectedItem);
                }
              })
            }, (item: CalendarItem) => item.href)
          }
        }
        .width('100%')
        .padding(8)
        .constraintSize({ minHeight: '100%' })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
      .borderRadius(16)
      .backgroundColor($r('app.color.card_bg'))
      .shadow({ radius: 12, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 4 })

      if (this.statusMsg !== '' && !this.isLoading) {
        Row({ space: 6 }) {
          Text(this.statusOk ? '✓' : '✕')
            .fontSize(14)
            .fontColor(this.statusOk ? $r('app.color.success') : $r('app.color.error'))
          Text(this.statusMsg)
            .fontSize(14)
            .fontColor(this.statusOk ? $r('app.color.success') : $r('app.color.error'))
        }
        .width('100%')
        .padding(12)
        .borderRadius(8)
        .backgroundColor(this.statusOk ? $r('app.color.success_bg') : $r('app.color.error_bg'))
      }

      Button() {
        Text(this.isSaving ? '保存中…' : '保存并完成')
          .fontSize(17)
          .fontColor($r('app.color.button_text'))
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .height(48)
      .borderRadius(24)
      .backgroundColor(this.isSaving ? $r('app.color.brand_disabled') : $r('app.color.brand'))
      .enabled(!this.isSaving && !this.isLoading)
      .onClick(() => {
        this.saveSelection();
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 24 })
    .backgroundColor($r('app.color.page_bg'))
    .alignItems(HorizontalAlign.Center)
  }
}

@Component
struct CalendarRow {
  @ObjectLink item: CalendarItem;
  onSelect: (item: CalendarItem) => void = (selectedItem: CalendarItem): void => {};

  build() {
    Row({ space: 12 }) {
      Text(this.item.name)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Blank()
      if (this.item.selected) {
        Text('✓')
          .fontSize(14)
          .fontColor($r('app.color.button_text'))
          .width(24)
          .height(24)
          .textAlign(TextAlign.Center)
          .borderRadius(12)
          .backgroundColor($r('app.color.brand'))
      } else {
        Text('')
          .width(24)
          .height(24)
          .borderRadius(12)
          .border({ width: 1.5, color: $r('app.color.text_hint') })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 14, bottom: 14 })
    .borderRadius(8)
    .onClick(() => {
      this.onSelect(this.item);
    })
  }
}