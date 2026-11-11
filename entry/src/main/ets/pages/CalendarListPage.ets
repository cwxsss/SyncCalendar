// entry/src/main/ets/pages/CalendarListPage.ets
// 添加账号第二页：PROPFIND 列出日历本 → 勾选 → 命名 → 保存账号
import { curves, router } from '@kit.ArkUI';
import { buffer } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, TYPE_CALDAV, TYPE_CARDDAV } from '../common/AccountStore';
import { DavClient, DavCalendarDiscovery, DavCalendarEntry, DavAddressBookDiscovery,
  DavAddressBookEntry } from '../common/DavClient';
import { ContactService } from '../common/ContactService';
import { DavDiscovery, DiscoverResult, DavCapability } from '../common/DavDiscovery';
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
  /** 本次添加的是 CalDAV 日历还是 CardDAV 通讯录 */
  private accountType: string = TYPE_CALDAV;

  aboutToAppear(): Promise<void> {
    return this.initPage();
  }

  private async initPage(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      LogUtil.init(ctx);
    }
    const t: string | undefined = AppStorage.get<string>('pendingAccountType');
    this.accountType = (t === undefined || t === '') ? TYPE_CALDAV : t;
    this.serverUrl = AppStorage.get<string>('pendingDavUrl') ?? '';
    this.username = AppStorage.get<string>('pendingDavUsername') ?? '';
    this.password = AppStorage.get<string>('pendingDavPassword') ?? '';
    // 日志不记录用户名（可能是邮箱等个人标识），只留服务器地址以便定位问题
    LogUtil.write(`添加账号流程开始：服务器=${this.serverUrl}`);
    if (this.serverUrl === '') {
      this.isLoading = false;
      this.statusMsg = '尚未连接服务器，请先返回重新连接';
      this.statusOk = false;
      return;
    }
    if (this.accountType === TYPE_CARDDAV) {
      await this.fetchAddressBooks();
    } else {
      await this.fetchCalendars();
    }
  }

  /**
   * 清除跨页传递的明文凭据。
   * 这些值原本通过 AppStorage 在页面间传递，AppStorage 是全局单例，若不清除，
   * 明文密码会在**整个进程生命周期**内一直可读 —— 属于不必要的凭据驻留。
   */
  private clearPendingCredentials(): void {
    AppStorage.setOrCreate<string>('pendingDavPassword', '');
    AppStorage.setOrCreate<string>('pendingDavUsername', '');
    AppStorage.setOrCreate<string>('pendingDavUrl', '');
    this.password = '';
  }

  /** 离开页面即清理凭据（覆盖用户按返回键放弃添加这条路径） */
  aboutToDisappear(): void {
    this.clearPendingCredentials();
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

  /**
   * CardDAV：发现地址簿并填充列表。
   * 与日历侧最大的不同：地址簿没有颜色概念，且必须先把家目录找对
   * （群晖是 /carddav/，Nextcloud 是 /remote.php/dav/addressbooks/<user>/）。
   */
  private async fetchAddressBooks(): Promise<void> {
    const token: string = this.encodeBasicAuth();
    if (token === '') {
      this.isLoading = false;
      this.statusMsg = '凭据编码失败：请在真机或模拟器上运行';
      this.statusOk = false;
      return;
    }
    const auth: string = 'Basic ' + token;
    this.isLoading = true;
    this.statusMsg = '正在查找通讯录地址簿…';
    try {
      const disc: DavAddressBookDiscovery = await ContactService.discoverAddressBooks(
        this.serverUrl, this.username, auth);
      this.isLoading = false;
      if (disc.statusCode === 401) {
        this.statusMsg = '服务器拒绝凭据（401）：请返回检查用户名与密码。若服务器开启了二次验证，请使用「应用密码」';
        this.statusOk = false;
        return;
      }
      if (disc.entries.length === 0) {
        // ⚠️ 207 但零地址簿，与 405「不是 DAV 端点」是两回事，提示要分开写，
        //    否则用户会照着 405 的思路去改地址，白折腾。
        const body: string = disc.statusCode === 207
          ? `服务器接受了请求但没返回地址簿（207）。\n\n`
            + '常见原因：\n'
            + '1) 地址层级不对 —— 群晖要填到「用户名」那一层：\n'
            + '   https://你的域名/carddav/你的用户名/\n'
            + '2) 该账号下确实还没有地址簿（在 Synology Contacts 里新建一个）'
          : `没有找到地址簿（服务器返回 ${disc.statusCode}）。\n\n`
            + '请确认：\n'
            + '1) 该服务器开启了 CardDAV（群晖需安装「Synology Contacts」）\n'
            + '2) 地址可填域名，本页会自动尝试 /carddav/<用户名>/ 等常见路径';
        this.statusMsg = body;
        this.statusOk = false;
        return;
      }
      const list: CalendarItem[] = disc.entries.map((e: DavAddressBookEntry): CalendarItem =>
        new CalendarItem(e.href, e.displayName, ''));
      for (const item of list) {
        LogUtil.write(`发现地址簿：「${item.name}」${item.href}`);
      }
      this.calendarList = list;
      this.updateSelectionState();
      this.statusMsg = `发现 ${list.length} 个地址簿，请勾选要同步的通讯录`;
      this.statusOk = true;
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`查找地址簿失败：${e.message}`);
      this.isLoading = false;
      this.statusMsg = `查找地址簿失败：${e.message}`;
      this.statusOk = false;
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
    const auth: string = 'Basic ' + token;
    // ⭐ 0.0.7：先做地址自动发现/智能补全 —— 用户常只填域名或 DAV 根，
    //    而 Nextcloud 等要求填「日历家目录」。此处自动找对端点，避免"读不出日历"。
    try {
      const resolved: DiscoverResult = await DavDiscovery.resolve(
        this.serverUrl,
        this.username,
        auth,
        async (u: string): Promise<boolean> => {
          const d: DavCalendarDiscovery = await DavClient.listCalendars(u, auth);
          return d.entries !== undefined && d.entries.length > 0;
        });
      if (resolved.ok && resolved.url !== '' && resolved.url !== this.serverUrl) {
        LogUtil.write(`服务地址已自动修正：${this.serverUrl} → ${resolved.url}（来源 ${resolved.via}）`);
        this.serverUrl = resolved.url;
      } else if (!resolved.ok && resolved.hint !== '') {
        // 自动发现彻底失败 → 直接把"人话原因"给用户，不再只报一个状态码
        this.isLoading = false;
        this.statusMsg = resolved.hint;
        this.statusOk = false;
        return;
      }
    } catch (err) {
      // 发现阶段异常不阻塞：继续用原地址走既有流程（保持旧行为兜底）
      LogUtil.write(`地址发现阶段异常，回退原地址：${(err as BusinessError).message}`);
    }
    // PROPFIND 与解析统一走 DavClient.listCalendars（与「编辑账号」页共用同一实现，避免重复正则逻辑）
    try {
      const disc: DavCalendarDiscovery = await DavClient.listCalendars(this.serverUrl, auth);
      this.isLoading = false;
      if (disc.statusCode === 401) {
        this.statusMsg = '服务器拒绝凭据（401）：请返回检查用户名与密码。若服务器开启了二次验证，请使用「应用密码」';
        this.statusOk = false;
        return;
      }
      if (disc.statusCode !== 207 && disc.statusCode !== 200) {
        // ⭐ 0.0.7：把生硬的状态码换成人话 + 可操作指引
        this.statusMsg = DavDiscovery.statusHint(disc.statusCode);
        this.statusOk = false;
        return;
      }
      const list: CalendarItem[] = disc.entries.map((e: DavCalendarEntry): CalendarItem =>
        new CalendarItem(e.href, e.displayName, e.color));
      for (const item of list) {
        LogUtil.write(`发现日历本：「${item.name}」${item.href} 颜色=${item.color === '' ? '(无)' : item.color}`);
      }
      if (list.length === 0) {
        // ⭐ 0.0.7：区分"地址层级不对"与"确实没有日历"，并给出正确填法示例
        this.statusMsg = DavDiscovery.emptyHint(this.serverUrl, this.username);
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
    }
  }

  private async saveSelection(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    if (this.accountName.trim() === '') {
      this.statusMsg = this.accountType === TYPE_CARDDAV ? '请先给这个通讯录账户起一个名字' : '请先给这个日历账户起一个名字';
      this.statusOk = false;
      return;
    }
    const selectedItems: CalendarItem[] = this.calendarList.filter((c: CalendarItem) => c.selected);
    if (selectedItems.length === 0) {
      this.statusMsg = this.accountType === TYPE_CARDDAV ? '请至少勾选一个地址簿' : '请至少勾选一个日历本';
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
      LogUtil.write(`保存账号 id=${acc.id}：勾选 ${selectedItems.length}/${this.calendarList.length} 个日历本`);
      await AccountStore.addAccount(context, acc);
      AppStorage.setOrCreate<string>('pendingSyncAccountId', acc.id);
      this.getUIContext().getPromptAction()
        .showToast({ message: this.accountType === TYPE_CARDDAV
          ? `账号已保存，共 ${selectedItems.length} 个地址簿`
          : `账号已保存，共 ${selectedItems.length} 个日历本` });
      this.statusMsg = '保存成功';
      this.statusOk = true;
      this.clearPendingCredentials();
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
    // 选中状态已在 CalendarRow 内部直接翻转，这里只刷新计数
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
          .caretColor($r('app.color.brand'))
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
    // 沉浸式：背景延伸到状态栏/导航条区域（只扩绘制、不移动子组件）
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .alignItems(HorizontalAlign.Center)
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
      // 直接翻转 @ObjectLink 属性，子组件自身即可触发刷新
      this.item.selected = !this.item.selected;
      this.onSelect(this.item);
    })
  }
}