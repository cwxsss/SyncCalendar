// entry/src/main/ets/pages/EditAccountPage.ets
// 编辑账号：查看/重选该账号下的日历本、修改账户名
// 保存后清理失效日历本的本地数据，并触发一次重新同步
//
// ⚠️ 取消勾选某个日历本会改变**后面所有本的序号**（calKey = accId_序号）。因此保存时还要检查：
//    被取消的那个本是不是「系统日历 → CalDAV」的备份目标 —— 是的话当场把该功能关闭，
//    否则用户会以为备份还在工作，实际却可能把系统日程导进别的本（用户实测反馈）。
import { curves, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore } from '../common/AccountStore';
import { DavClient, DavCalendarDiscovery, DavCalendarEntry } from '../common/DavClient';
import { EventDb } from '../common/EventDb';
import { BackupTargetCheck, SystemCalendarMirror } from '../common/SystemCalendarMirror';
import { LogUtil } from '../common/LogUtil';

/**
 * 日历本条目（@Observed 使勾选状态变化能刷新 UI）
 */
@Observed
export class EditCalendarItem {
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

/**
 * 路由参数（AppStorage 的兜底通道）
 */
export class EditNavParams {
  accId: string = '';
}

@Entry
@Component
struct EditAccountPage {
  @State accountName: string = '';
  @State serverUrl: string = '';
  @State username: string = '';
  @State calendarList: EditCalendarItem[] = [];
  @State isLoading: boolean = true;
  @State statusMsg: string = '正在获取日历列表…';
  @State statusOk: boolean = false;
  @State isSaving: boolean = false;
  @State selectedCount: number = 0;
  @State allSelected: boolean = false;
  private acc: DavAccount = new DavAccount();
  private found: boolean = false;

  aboutToAppear(): Promise<void> {
    return this.initPage();
  }

  private async initPage(): Promise<void> {
    try {
      // 1) 读取目标账号 id（AppStorage 为主，路由参数兜底）
      let accId: string | undefined = AppStorage.get<string>('pendingEditAccountId');
      if (accId === undefined || accId === '') {
        const rawParams: Object | undefined = router.getParams();
        if (rawParams instanceof EditNavParams && rawParams.accId !== '') {
          accId = rawParams.accId;
        }
      }
      console.info(`编辑账号 initPage: accId=${accId ?? '(undefined)'}`);
      if (accId === undefined || accId === '') {
        this.isLoading = false;
        this.statusMsg = '未指定要编辑的账号，请返回账号列表重新点击';
        this.statusOk = false;
        return;
      }
      // 2) 获取应用上下文（getHostContext 过早调用可能为 undefined，getContext 兜底）
      let context: common.Context | undefined = undefined;
      try {
        context = this.getUIContext().getHostContext();
      } catch (err) {
        console.info('getHostContext 异常，使用 getContext 兜底');
      }
      if (context === undefined) {
        context = getContext(this);
      }
      if (context === undefined) {
        this.isLoading = false;
        this.statusMsg = '无法获取应用上下文';
        this.statusOk = false;
        return;
      }
      // 3) 从账号列表里找到该账号
      const accounts: DavAccount[] = await AccountStore.loadAll(context);
      const foundAcc = accounts.find((a: DavAccount): boolean => a.id === accId);
      if (foundAcc === undefined) {
        this.isLoading = false;
        this.statusMsg = `账号不存在（id=${accId}），可能已被删除`;
        this.statusOk = false;
        return;
      }
      this.acc = foundAcc;
      this.found = true;
      this.accountName = foundAcc.name;
      this.serverUrl = foundAcc.serverUrl;
      this.username = foundAcc.username;
      LogUtil.write(`编辑账号 id=${foundAcc.id}：当前已选 ${foundAcc.calendarHrefs.length} 个日历本`);
      for (let i = 0; i < foundAcc.calendarHrefs.length; i++) {
        const nm: string = i < foundAcc.calendarNames.length ? foundAcc.calendarNames[i] : '';
        LogUtil.write(`  已选日历本[${i}]「${nm}」${foundAcc.calendarHrefs[i]}`);
      }
      await this.fetchCalendars();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`编辑账号初始化失败: ${e.code} - ${e.message}`);
      this.isLoading = false;
      this.statusMsg = `页面初始化失败：${e.message}`;
      this.statusOk = false;
    }
  }

  private encodeBasicAuth(): string {
    try {
      return buffer.from(`${this.acc.username}:${this.acc.password}`).toString('base64');
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
    // PROPFIND 与解析统一走 DavClient.listCalendars（与「添加账号」页共用同一实现）
    try {
      const disc: DavCalendarDiscovery = await DavClient.listCalendars(this.acc.serverUrl, 'Basic ' + token);
      this.isLoading = false;
      if (disc.statusCode === 401) {
        this.statusMsg = '登录已失效，请检查账号密码';
        this.statusOk = false;
        return;
      }
      if (disc.statusCode !== 207 && disc.statusCode !== 200) {
        this.statusMsg = `获取日历列表失败，服务器返回：${disc.statusCode}`;
        this.statusOk = false;
        return;
      }
      const list: EditCalendarItem[] = disc.entries.map((e: DavCalendarEntry): EditCalendarItem =>
        new EditCalendarItem(e.href, e.displayName, e.color));
      if (list.length === 0) {
        LogUtil.write('编辑账号：未发现任何日历本');
        this.statusMsg = '该路径下未发现日历本';
        this.statusOk = false;
      } else {
        // 已勾选的日历本按账号当前配置预选
        for (const item of list) {
          item.selected = this.acc.calendarHrefs.includes(item.href);
          LogUtil.write(`编辑账号发现日历本：「${item.name}」${item.href} 颜色=${item.color === '' ? '(无)' : item.color} 预选=${item.selected}`);
        }
        this.calendarList = list;
        this.updateSelectionState();
        this.statusMsg = `该账号共 ${list.length} 个日历本，当前已选 ${this.selectedCount} 个`;
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

  /** 保存：更新账号的日历本选择与名称，清理失效数据，触发重新同步 */
  private async saveSelection(): Promise<void> {
    if (this.isSaving || !this.found) {
      return;
    }
    if (this.accountName.trim() === '') {
      this.statusMsg = '账户名不能为空';
      this.statusOk = false;
      return;
    }
    const selectedItems: EditCalendarItem[] = this.calendarList.filter((c: EditCalendarItem) => c.selected);
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
      const accounts: DavAccount[] = await AccountStore.loadAll(context);
      const target = accounts.find((a: DavAccount): boolean => a.id === this.acc.id);
      if (target === undefined) {
        this.statusMsg = '账号不存在，可能已被删除';
        this.statusOk = false;
        this.isSaving = false;
        return;
      }
      // 保存前的旧序号（calKey = accId_序号，序号=勾选顺序）：
      // 服务器上新增日历本后，新本可能插在列表中间导致后续序号整体位移，
      // 若不迁移，已落库的日程会挂错日历本（表现为色块颜色不对）。
      const oldHrefs: string[] = target.calendarHrefs.slice();
      target.name = this.accountName.trim();
      const newHrefs: string[] = selectedItems.map((c: EditCalendarItem): string => c.href);
      target.calendarHrefs = newHrefs;
      target.calendarNames = selectedItems.map((c: EditCalendarItem): string => c.name);
      target.calendarColors = selectedItems.map((c: EditCalendarItem): string => c.color);
      LogUtil.write(`编辑账号保存：id=${target.id}，新勾选 ${selectedItems.length}/${this.calendarList.length} 个日历本`);
      // 按 href 求出「旧序号 → 新序号」，迁移已落库日程到正确的 calKey
      const remapPairs: Array<[string, string]> = [];
      for (let oi: number = 0; oi < oldHrefs.length; oi++) {
        const oldNorm: string = DavClient.normalizeHref(oldHrefs[oi]);
        let ni: number = -1;
        for (let k: number = 0; k < newHrefs.length; k++) {
          if (DavClient.normalizeHref(newHrefs[k]) === oldNorm) {
            ni = k;
            break;
          }
        }
        if (ni >= 0 && ni !== oi) {
          remapPairs.push([`${target.id}_${oi}`, `${target.id}_${ni}`]);
        }
      }
      if (remapPairs.length > 0) {
        const moved: number = await EventDb.remapCalKeys(context, remapPairs);
        LogUtil.write(`编辑账号保存：日历本序号变动，迁移日程 ${moved} 行（${remapPairs.length} 个日历本）`);
      }
      await AccountStore.saveAll(context, accounts);
      // 重选后 calKey（accId_序号）会变化，清理已取消勾选的日历本数据
      const validKeys: string[] =
        selectedItems.map((c: EditCalendarItem, i: number): string => `${target.id}_${i}`);
      await EventDb.pruneAccountEvents(context, target.id, validKeys);
      AppStorage.setOrCreate<string>('pendingSyncAccountId', target.id);
      // ⭐ 若刚被取消勾选的本正是「系统日历 → CalDAV」的备份目标，**当场**判它失效并关闭备份功能。
      //    不这么做的话，要等下一次同步才会发现目标没了；这期间开关还显示"备份到 CalDAV"，
      //    用户会以为备份仍在正常工作，而实际已经导不进去（或更糟：导进了别的本）。
      const backupCheck: BackupTargetCheck = await SystemCalendarMirror.checkBackupTarget(context);
      this.getUIContext().getPromptAction().showToast({
        message: backupCheck.closed
          ? '原系统日历备份目标已被取消同步，备份功能已自动关闭'
          : `已保存，同步 ${selectedItems.length} 个日历本`
      });
      router.back();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`保存失败: ${e.code} - ${e.message}`);
      this.statusMsg = `保存失败：${e.message}`;
      this.statusOk = false;
    }
    this.isSaving = false;
  }

  private updateSelectionState(): void {
    const count: number = this.calendarList.filter((c: EditCalendarItem): boolean => c.selected).length;
    this.selectedCount = count;
    this.allSelected = this.calendarList.length > 0 && count === this.calendarList.length;
  }

  private handleItemToggle(item: EditCalendarItem): void {
    // 选中状态已在 EditCalendarRow 内部直接翻转，这里只刷新计数
    this.updateSelectionState();
  }

  private toggleAll(): void {
    const target: boolean = !this.allSelected;
    this.calendarList.forEach((c: EditCalendarItem) => {
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
        Text('编辑账号')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.username !== '' ? `${this.serverUrl} · ${this.username}` : this.serverUrl)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
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
            ForEach(this.calendarList, (item: EditCalendarItem) => {
              EditCalendarRow({
                item: item,
                onSelect: (selectedItem: EditCalendarItem): void => {
                  this.handleItemToggle(selectedItem);
                }
              })
              // key 只用 href（稳定标识）：若把选中态也拼进 key，勾选一次就会导致整行销毁重建
            }, (item: EditCalendarItem) => item.href)
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
        Text(this.isSaving ? '保存中…' : '保存并同步')
          .fontSize(17)
          .fontColor($r('app.color.button_text'))
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .height(48)
      .borderRadius(24)
      .backgroundColor(this.isSaving ? $r('app.color.brand_disabled') : $r('app.color.brand'))
      .enabled(!this.isSaving && !this.isLoading && this.found)
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
struct EditCalendarRow {
  @ObjectLink item: EditCalendarItem;
  onSelect: (item: EditCalendarItem) => void = (selectedItem: EditCalendarItem): void => {};

  build() {
    Row({ space: 12 }) {
      if (this.item.color !== '') {
        Circle()
          .width(12)
          .height(12)
          .fill(this.item.color)
      }
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
