// entry/src/main/ets/pages/ContactListPage.ets
// 联系人列表：展示 CardDAV 同步下来的联系人，支持搜索、同步、进入详情
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, TYPE_CARDDAV } from '../common/AccountStore';
import { ContactDb, ContactRow } from '../common/ContactDb';
import { ContactService, ContactSyncResult } from '../common/ContactService';
import { VCardUtil } from '../common/VCardUtil';
import { LogUtil } from '../common/LogUtil';
import { ScreenKeeper } from '../common/ScreenKeeper';

@Entry
@Component
struct ContactListPage {
  @State rows: ContactRow[] = [];
  @State keyword: string = '';
  @State syncing: boolean = false;
  @State statusMsg: string = '';
  @State noAccount: boolean = false;
  @State totalCount: number = 0;

  aboutToAppear(): Promise<void> {
    return this.reload();
  }

  onPageShow(): void {
    // 从详情页返回后刷新（可能编辑或删除了）
    this.reload();
  }

  private async reload(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    LogUtil.init(ctx);
    try {
      const accounts: DavAccount[] = await AccountStore.loadAll(ctx);
      const cardAccounts: DavAccount[] = accounts.filter((a: DavAccount): boolean =>
        a.type === TYPE_CARDDAV);
      this.noAccount = cardAccounts.length === 0;
      this.rows = await ContactDb.listAll(ctx);
      this.totalCount = this.rows.length;
      if (this.noAccount) {
        this.statusMsg = '还没有 CardDAV 通讯录账号';
      } else if (this.rows.length === 0) {
        this.statusMsg = '点右上角「同步」拉取联系人';
      } else {
        this.statusMsg = '';
      }
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`加载联系人失败：${e.message}`);
      this.statusMsg = `加载失败：${e.message}`;
    }
  }

  private filtered(): ContactRow[] {
    const k: string = this.keyword.trim().toLowerCase();
    if (k === '') {
      return this.rows;
    }
    return this.rows.filter((r: ContactRow): boolean => {
      if (r.displayName.toLowerCase().indexOf(k) >= 0) {
        return true;
      }
      if (r.org.toLowerCase().indexOf(k) >= 0) {
        return true;
      }
      // 电话也参与搜索（用户常按号码找人）
      if (r.phonesJson.toLowerCase().indexOf(k) >= 0) {
        return true;
      }
      return false;
    });
  }

  private async doSync(): Promise<void> {
    if (this.syncing) {
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    this.syncing = true;
    this.statusMsg = '正在同步…';
    const uiCtx = ctx as common.UIAbilityContext;
    // 同步期间保持屏幕常亮（与日历同步一致，熄屏会挂起进程）
    await ScreenKeeper.acquire(uiCtx);
    try {
      const accounts: DavAccount[] = await AccountStore.loadAll(ctx);
      const cardAccounts: DavAccount[] = accounts.filter((a: DavAccount): boolean =>
        a.type === TYPE_CARDDAV);
      if (cardAccounts.length === 0) {
        this.statusMsg = '还没有 CardDAV 通讯录账号，请先在账号页添加';
        this.syncing = false;
        await ScreenKeeper.release(uiCtx);
        return;
      }
      // 先探测本构建有没有"写系统通讯录"的能力：
      //   unsupported = 清单里没声明 system_basic 的通讯录权限（默认构建就是这样）
      //   denied      = 声明了但用户还没同意 → 可以申请
      //   granted     = 已授权
      let cap: string = await ContactService.detectContactCapability(ctx);
      let writeSystem: boolean = (cap === 'granted');
      if (cap === 'denied') {
        writeSystem = await ContactService.requestContactPermission(ctx);
      }
      let total: number = 0;
      let failMsg: string = '';
      let pushedUp: number = 0;
      let conflicts: number = 0;
      for (const acc of cardAccounts) {
        LogUtil.write(`开始同步 CardDAV 账号「${acc.name}」（写系统通讯录=${writeSystem}）`);
        const r: ContactSyncResult = await ContactService.syncAccount(ctx, acc, writeSystem);
        if (!r.ok) {
          failMsg = r.message;
        }
        total += r.total;
        pushedUp += r.pushedUp;
        conflicts += r.conflicts;
      }
      this.rows = await ContactDb.listAll(ctx);
      this.totalCount = this.rows.length;
      // 反向同步的补充说明（有才拼，避免平时文案变长）
      let extra: string = '';
      if (pushedUp > 0) {
        extra += `；已上行系统改动 ${pushedUp} 条`;
      }
      if (conflicts > 0) {
        extra += `；${conflicts} 条因远端也改动而按远端优先`;
      }
      if (failMsg !== '') {
        this.statusMsg = failMsg;
      } else if (writeSystem) {
        this.statusMsg = `同步完成，共 ${this.rows.length} 位联系人（已写入手机通讯录）${extra}`;
      } else if (cap === 'unsupported') {
        this.statusMsg = `同步完成，共 ${this.rows.length} 位联系人。\n`
          + '当前版本仅在本应用内查看（写入手机通讯录需要系统级权限，本版本未包含）';
      } else {
        this.statusMsg = `同步完成，共 ${this.rows.length} 位联系人（未授予通讯录权限，仅本应用内可见）`;
      }
      LogUtil.write(`联系人同步结束：${this.statusMsg}`);
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`联系人同步异常：${e.message}`);
      this.statusMsg = `同步失败：${e.message}`;
    }
    await ScreenKeeper.release(uiCtx);
    this.syncing = false;
  }

  private subtitle(r: ContactRow): string {
    try {
      const phones = JSON.parse(r.phonesJson) as string[];
      if (phones.length > 0) {
        return phones[0];
      }
    } catch (err) {
      // 忽略
    }
    if (r.org !== '') {
      return r.org;
    }
    try {
      const emails = JSON.parse(r.emailsJson) as string[];
      if (emails.length > 0) {
        return emails[0];
      }
    } catch (err) {
      // 忽略
    }
    return '';
  }

  private initialOf(r: ContactRow): string {
    const name: string = r.displayName.trim();
    if (name === '') {
      return '#';
    }
    const first: string = name.charAt(0);
    if (/[\u4e00-\u9fff]/.test(first)) {
      return first;
    }
    return first.toUpperCase();
  }

  @Builder
  contactRow(r: ContactRow) {
    Row({ space: 12 }) {
      // 头像占位：姓名首字
      Text(this.initialOf(r))
        .width(42)
        .height(42)
        .borderRadius(21)
        .backgroundColor($r('app.color.brand'))
        .fontColor(Color.White)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)

      Column({ space: 3 }) {
        Text(r.displayName === '' ? '(未命名)' : r.displayName)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subtitle(r) !== '') {
          Text(this.subtitle(r))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(18)
        .fontColor($r('app.color.text_hint'))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor($r('app.color.card_bg'))
    .onClick(() => {
      AppStorage.setOrCreate<number>('pendingContactId', r.id);
      router.pushUrl({ url: 'pages/ContactDetailPage' });
    })
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 6 }) {
        Text('←')
          .fontSize(18)
          .fontColor($r('app.color.brand'))
        Text('返回')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
        Blank()
        if (!this.noAccount) {
          Text(this.syncing ? '同步中…' : '同步')
            .fontSize(15)
            .fontColor(this.syncing ? $r('app.color.text_hint') : $r('app.color.brand'))
            .onClick(() => {
              if (!this.syncing) {
                this.doSync();
              }
            })
        }
      }
      .width('100%')

      Column({ space: 4 }) {
        Text('联系人')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.totalCount > 0 ? `共 ${this.totalCount} 位` : '通讯录同步')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      if (this.rows.length > 0) {
        TextInput({ text: this.keyword, placeholder: '搜索姓名、公司或电话' })
          .height(42)
          .fontSize(15)
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((v: string) => {
            this.keyword = v;
          })
      }

      if (this.statusMsg !== '') {
        Text(this.statusMsg)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding(10)
          .borderRadius(10)
          .backgroundColor($r('app.color.card_bg'))
      }

      if (this.noAccount) {
        Column({ space: 8 }) {
          Text('还没有 CardDAV 通讯录账号')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
          Text('去「账号」页添加时选择「CardDAV 通讯录」，填服务器地址和账号密码即可')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Button('去添加')
            .fontSize(15)
            .height(40)
            .onClick(() => {
              AppStorage.setOrCreate<string>('pendingAccountType', TYPE_CARDDAV);
              router.pushUrl({ url: 'pages/AddAccountPage' });
            })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(16)
        .borderRadius(14)
        .backgroundColor($r('app.color.card_bg'))
      }

      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.filtered(), (r: ContactRow) => {
            this.contactRow(r)
          }, (r: ContactRow) => String(r.id))
        }
        .width('100%')
        .padding({ bottom: 20 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 12 })
    .backgroundColor($r('app.color.page_bg'))
  }
}