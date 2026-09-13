// entry/src/main/ets/pages/AccountsPage.ets
// DAV 账号管理（由原 CalDAVSync 首页移植）
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, TYPE_KEYS, TYPE_CALDAV, TYPE_CARDDAV, TYPE_WEBDAV } from '../common/AccountStore';
import { SyncEngine } from '../common/SyncEngine';
import { EditNavParams } from './EditAccountPage';
import { EventDb } from '../common/EventDb';
import { LogUtil } from '../common/LogUtil';

@Entry
@Component
struct AccountsPage {
  @State accounts: DavAccount[] = [];
  @State showTypeMenu: boolean = false;
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
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      if (acc.type === TYPE_CALDAV) {
        await SyncEngine.withTimeout(
          SyncEngine.syncAccount(context as common.UIAbilityContext, acc), 120000);
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
    }
  }

  private openAddPage(type: string): void {
    this.showTypeMenu = false;
    AppStorage.setOrCreate<string>('pendingAccountType', type);
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

  /** 执行删除：账号配置 + 该账号全部本地日程/待办 */
  private async confirmDeleteAccount(acc: DavAccount): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    try {
      this.accounts = this.accounts.filter((a: DavAccount): boolean => a.id !== acc.id);
      await AccountStore.saveAll(context, this.accounts);
      await EventDb.deleteAccountEvents(context, acc.id);
      this.getUIContext().getPromptAction()
        .showToast({ message: `「${acc.name}」已删除` });
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

      if (this.showTypeMenu) {
        Column()
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.showTypeMenu = false;
          })
      }

      if (this.showTypeMenu) {
        Column({ space: 10 }) {
          this.menuItem('日', 'CalDAV', '日历同步', TYPE_CALDAV)
          this.menuItem('人', 'CardDAV', '通讯录同步', TYPE_CARDDAV)
          this.menuItem('文', 'WebDAV', '文件访问', TYPE_WEBDAV)
        }
        .width(220)
        .padding(10)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_bg'))
        .shadow({ radius: 16, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 4 })
        .margin({ right: 24, bottom: 156 })
      }

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
        this.showTypeMenu = !this.showTypeMenu;
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  emptyState() {
    Column({ space: 12 }) {
      Text('＋')
        .fontSize(30)
        .fontColor($r('app.color.text_hint'))
        .width(72)
        .height(72)
        .textAlign(TextAlign.Center)
        .borderRadius(20)
        .backgroundColor($r('app.color.card_bg'))
        .border({ width: 1.5, color: $r('app.color.shadow_color') })
      Text('还没有任何 DAV 账号')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('点击右下角 + 添加 CalDAV / CardDAV / WebDAV 账号')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  menuItem(badge: string, title: string, desc: string, type: string) {
    Row({ space: 12 }) {
      Text(badge)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.brand'))
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .borderRadius(10)
        .backgroundColor($r('app.color.input_bg'))
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(desc)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(8)
    .borderRadius(10)
    .onClick(() => {
      this.openAddPage(type);
    })
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