// entry/src/main/ets/pages/AccountsPage.ets
// DAV 账号管理（由原 CalDAVSync 首页移植）
import { curves, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, TYPE_KEYS, TYPE_CALDAV, TYPE_CARDDAV } from '../common/AccountStore';
import { SyncEngine } from '../common/SyncEngine';
import { EditNavParams } from './EditAccountPage';
import { EventDb } from '../common/EventDb';
import { LogUtil } from '../common/LogUtil';
import { AppSettings } from '../common/AppSettings';
import { ScreenKeeper } from '../common/ScreenKeeper';
import { SystemCalendarMirror } from '../common/SystemCalendarMirror';

@Entry
@Component
struct AccountsPage {
  @State accounts: DavAccount[] = [];
  @State syncing: boolean = false;
  @State syncingId: string = '';

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      LogUtil.init(ctx);
      LogUtil.write('---- 打开 DAV 账号页 ----');
    }
    this.reloadAccounts();
  }

  onPageShow(): void {
    this.reloadAccounts();
  }

  private async reloadAccounts(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    this.accounts = await AccountStore.loadAll(context);
    const pendingId: string | undefined = AppStorage.get<string>('pendingSyncAccountId');
    if (pendingId !== undefined && pendingId !== '') {
      AppStorage.setOrCreate<string>('pendingSyncAccountId', '');
      const found = this.accounts.find((a: DavAccount): boolean => a.id === pendingId);
      if (found !== undefined) {
        this.syncSingleAccount(found);
      }
    }
  }

  private typeLabel(type: string): string {
    if (type === TYPE_CALDAV) {
      return 'CalDAV 日历';
    }
    if (type === TYPE_CARDDAV) {
      return 'CardDAV 通讯录';
    }
    return 'WebDAV 文件';
  }

  private formatNow(): string {
    const d = new Date();
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  private async syncSingleAccount(acc: DavAccount): Promise<void> {
    if (this.syncing) {
      return;
    }
    this.syncing = true;
    this.syncingId = acc.id;
    // 同步期间保持屏幕常亮：熄屏会挂起进程导致请求停摆、同步超时
    const uiCtx = this.getUIContext().getHostContext();
    if (uiCtx !== undefined) {
      await ScreenKeeper.acquire(uiCtx as common.UIAbilityContext);
    }
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      if (acc.type === TYPE_CALDAV) {
        // 超时保护由 syncAccount 内部处理（全量重拉 10 分钟 / 常规 2 分钟），不再套外层超时
        await SyncEngine.syncAccount(context as common.UIAbilityContext, acc);
        await SyncEngine.pruneOrphanRows(context, this.accounts);
      }
      acc.itemCount = acc.calendarHrefs.length;
      acc.lastSyncTime = this.formatNow();
      await AccountStore.saveAll(context, this.accounts);
      this.getUIContext().getPromptAction()
        .showToast({ message: `「${acc.name}」同步完成` });
    } catch (err) {
      const e = err as BusinessError;
      this.getUIContext().getPromptAction()
        .showToast({ message: `「${acc.name}」同步失败：${e.message}` });
    } finally {
      this.syncing = false;
      this.syncingId = '';
      if (uiCtx !== undefined) {
        await ScreenKeeper.release(uiCtx as common.UIAbilityContext);
      }
    }
  }

  private openAddPage(): void {
    // 目前只支持 CalDAV：点 + 直接进入添加 CalDAV 账号页（不再弹类型选择菜单）
    AppStorage.setOrCreate<string>('pendingAccountType', TYPE_CALDAV);
    router.pushUrl({ url: 'pages/AddAccountPage' });
  }

  /** 点击账号 → 进入编辑页（查看/重选日历本） */
  private openEditPage(acc: DavAccount): void {
    if (acc.type !== TYPE_CALDAV) {
      this.getUIContext().getPromptAction()
        .showToast({ message: '该类型账号暂不支持编辑日历本' });
      return;
    }
    AppStorage.setOrCreate<string>('pendingEditAccountId', acc.id);
    const params = new EditNavParams();
    params.accId = acc.id;
    router.pushUrl({ url: 'pages/EditAccountPage', params: params });
  }

  /** 长按账号 → 弹出删除确认 */
  private askDeleteAccount(acc: DavAccount): void {
    this.getUIContext().showAlertDialog({
      title: '删除账号',
      message: `确定删除「${acc.name}」吗？\n\n该账号下的所有日历本、日程与待办的本地数据将一并删除。\n服务器上的数据不受影响。`,
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
          this.confirmDeleteAccount(acc);
        }
      }
    });
  }

  /** 执行删除：账号配置 + 该账号全部本地日程/待办 + 该系统日历中该账号的全部镜像日历本 */
  private async confirmDeleteAccount(acc: DavAccount): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    try {
      // ⭐ 先清系统日历里属于**本账号**的镜像日历本（按 bookId 里的 accId 前缀匹配，
      //    绝不按显示名 → 不同账号的同名日历本不会误删）。
      //    必须在改账号配置**之前**做：一旦账号配置被删，bookId 就再也解析不出来，
      //    那些幽灵账户就永远清不掉了（这正是本次要修的 bug）。
      let mirrored: number = 0;
      try {
        mirrored = await SystemCalendarMirror.removeByAccount(context, acc.id);
      } catch (err) {
        // 系统日历清理失败不阻断账号删除（用户至少能删掉账号）
        LogUtil.write(`删除账号 ${acc.id}：清理系统日历镜像失败 ${(err as BusinessError).message}`);
      }
      this.accounts = this.accounts.filter((a: DavAccount): boolean => a.id !== acc.id);
      // force=true：删除最后一个账号时列表为空是合法场景，允许覆盖
      await AccountStore.saveAll(context, this.accounts, true);
      // 删除该账号全部本地日程/待办，并清理只读/静音/备份目标等关联设置
      await EventDb.deleteAccountEvents(context, acc.id);
      await AppSettings.cleanupAccountSettings(context, acc.id);
      this.getUIContext().getPromptAction()
        .showToast({
          message: mirrored > 0
            ? `「${acc.name}」已删除，并清除系统日历中 ${mirrored} 个镜像日历本`
            : `「${acc.name}」已删除`
        });
    } catch (err) {
      const e = err as BusinessError;
      this.getUIContext().getPromptAction()
        .showToast({ message: `删除失败：${e.message}` });
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        // 顶部
        Row({ space: 10 }) {
          Text('←')
            .fontSize(20)
            .fontColor($r('app.color.brand'))
            .onClick(() => {
              router.back();
            })
          Text('DAV 账号')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Blank()
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 12, bottom: 8 })

        if (this.accounts.length === 0) {
          this.emptyState()
        } else {
          Scroll() {
            Column({ space: 16 }) {
              ForEach(TYPE_KEYS, (type: string) => {
                if (this.accounts.some((a: DavAccount): boolean => a.type === type)) {
                  Column({ space: 8 }) {
                    Text(this.typeLabel(type))
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_secondary'))
                    ForEach(this.accounts.filter((a: DavAccount): boolean => a.type === type),
                      (acc: DavAccount) => {
                        AccountRow({
                          acc: acc,
                          isSyncing: this.syncingId === acc.id,
                          onSelect: (selected: DavAccount): void => {
                            this.openEditPage(selected);
                          },
                          onLongPress: (selected: DavAccount): void => {
                            this.askDeleteAccount(selected);
                          }
                        })
                      }, (acc: DavAccount) => acc.id)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .width('100%')
                }
              }, (type: string) => type)
            }
            .width('100%')
            .padding({ left: 20, right: 20, bottom: 100 })
            .constraintSize({ minHeight: '100%' })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))

      Button() {
        Text('＋')
          .fontSize(26)
          .fontColor($r('app.color.button_text'))
          .fontWeight(FontWeight.Medium)
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .backgroundColor($r('app.color.brand'))
      .shadow({ radius: 8, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 2 })
      .margin(24)
      .onClick(() => {
        this.openAddPage();
      })
    }
    .width('100%')
    .height('100%')
    // 沉浸式：背景延伸到状态栏/导航条区域（只扩绘制、不移动子组件）
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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
  emptyState() {
    Column({ space: 12 }) {
      // ⭐ 空状态的「＋」本身可点击 → 直接进入添加账号页（此前只是个静态图标，点了没反应）
      Button() {
        Text('＋')
          .fontSize(34)
          .fontColor($r('app.color.brand'))
          .fontWeight(FontWeight.Medium)
      }
      .width(84)
      .height(84)
      .borderRadius(24)
      .backgroundColor($r('app.color.card_bg'))
      .border({ width: 1.5, color: $r('app.color.brand') })
      .shadow({ radius: 8, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 2 })
      .onClick(() => {
        this.openAddPage();
      })
      Text('还没有任何 CalDAV 账号')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('点击上方 + 或右下角 + 添加 CalDAV 账号')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
}

@Component
struct AccountRow {
  @ObjectLink acc: DavAccount;
  @Prop isSyncing: boolean = false;
  onSelect: (acc: DavAccount) => void = (selected: DavAccount): void => {};
  onLongPress: (acc: DavAccount) => void = (selected: DavAccount): void => {};

  build() {
    Row({ space: 12 }) {
      Text(this.acc.name !== '' ? this.acc.name.substring(0, 1) : 'D')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.button_text'))
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .borderRadius(10)
        .backgroundColor($r('app.color.brand'))
      Column({ space: 4 }) {
        Text(this.acc.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.acc.serverUrl)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.acc.lastSyncTime === ''
          ? '尚未同步'
          : `上次同步 ${this.acc.lastSyncTime} · ${this.acc.calendarHrefs.length} 个日历本`)
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.isSyncing) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color($r('app.color.brand'))
      } else {
        Text('›')
          .fontSize(20)
          .fontColor($r('app.color.text_hint'))
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 1, color: $r('app.color.shadow_color') })
    .onClick(() => {
      this.onSelect(this.acc);
    })
    .gesture(LongPressGesture({ repeat: false })
      .onAction((event: GestureEvent) => {
        this.onLongPress(this.acc);
      }))
  }
}