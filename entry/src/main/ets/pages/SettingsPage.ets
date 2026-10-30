// entry/src/main/ets/pages/SettingsPage.ets
// 设置页：系统日历模式（仅显示/备份到 CalDAV）+ 混合显示开关 + 自动同步间隔 + 后台同步
import { curves, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { AppSettings } from '../common/AppSettings';
import { CardDataService } from '../common/CardDataService';
import { CalendarDataService } from '../common/CalendarDataService';
import { BackgroundSyncService } from '../common/BackgroundSyncService';
import { AccountStore, DavAccount } from '../common/AccountStore';
import { ReminderService } from '../common/ReminderService';
import { BusinessError } from '@kit.BasicServicesKit';
import { BackupTargetCheck, BookRef, MirrorResult, PurgeResult, SystemCalendarMirror } from '../common/SystemCalendarMirror';
import { MirrorRenamer, RenameResult } from '../common/MirrorRenamer';
import { DocViewer } from '../common/DocViewer';

const INTERVAL_OPTIONS: number[] = [1, 5, 15, 30, 60];

/** 日历本选项（备份目标 / 只读标记 / 静音标记共用） */
class BackupTarget {
  calKey: string = '';
  bookId: string = '';   // ⭐ 稳定标识（由服务器 href 派生）：镜像选中项用它存，不随序号变
  label: string = '';
  serverWritable: boolean = true; // 服务器探测结果
}

@Entry
@Component
struct SettingsPage {
  @State showSystem: boolean = true;
  @State intervalMinutes: number = 15; // ⭐ 0.0.8：默认 15 分钟（原 1 分钟会烧光短时任务配额）
  @State backgroundSync: boolean = false;
  @State sysMode: string = 'display'; // display | backup
  @State backupKey: string = '';       // ⭐ 备份目标本的**稳定标识** bookId（不再用会漂移的 calKey）
  @State backupTargets: BackupTarget[] = [];
  @State backupNotice: string = '';    // 备份目标失效/未选择时的提示文案
  @State allBooks: BackupTarget[] = []; // 全部 DAV 日历本（只读/静音标记管理用）
  @State manualKeys: string[] = [];     // 手动标记只读的 calKey
  @State mutedKeys: string[] = [];      // 提醒静音的 calKey
  @State notifyEnabled: boolean = true; // 通知权限状态（提醒依赖）
  @State showLegal: boolean = false;    // 隐私政策与用户协议弹层
  // 内置文档浏览器（《隐私政策》/《用户服务协议》/《软件特性》/《使用帮助》）：整页 Web 覆盖层
  @State showDoc: boolean = false;
  @State docTitle: string = '';
  @State docUrl: string = '';
  @State defaultView: string = 'month';  // 打开 App 默认视图：month | week | agenda
  @State displayStyle: string = 'timeline'; // 日程显示方式：timeline（时间轴）| list（列表）
  @State mirrorEnabled: boolean = false;    // 是否把选中 CalDAV 日历本镜像到系统日历（默认关）
  @State mirrorKeys: string[] = [];         // 要镜像的 DAV 日历本 **bookId**（稳定标识，不用会变的 calKey）
  @State mirrorRunning: boolean = false;    // 正在执行镜像
  @State purgeRunning: boolean = false;     // 正在清理残留镜像账户
  @State wipeAllRunning: boolean = false;   // 正在清除全部镜像（卸载前清干净）
  @State mirrorCandidates: BackupTarget[] = []; // 可镜像的本（已排除"系统日历备份目标本"，防回灌）
  @State mirrorInbound: boolean = false;         // 是否把系统日历的改动回写 CalDAV（默认关）
  @State accountDump: string = '';               // 系统日历账户清单（诊断用，清理后填充）
  // ⭐ 系统日历账户显示名格式：1=`同步日历·本名` 2=`同步日历·账号·本名` 3=`账号·本名`（默认）
  @State displayFormat: number = 3;
  @State displayFormatApplied: number = 3;       // 已生效的格式（用于判断"应用"按钮是否可点）
  @State formatRunning: boolean = false;         // 正在按新格式重建镜像
  @State hasLegacyNames: boolean = false;        // 是否还有旧格式账户（给出"可更换"弱提示）
  @State formatPreview: string = '';             // 实时预览示例
  private context?: common.Context;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    this.context = ctx;
    AppSettings.getShowSystemCalendar(ctx).then((v: boolean): void => {
      this.showSystem = v;
      // 状态自洽：若记录为"开"，但权限已被用户在系统设置里回收 → 自动回落为"关"，避免开关与实际不符
      if (v) {
        CalendarDataService.hasSystemCalendarPermission().then((granted: boolean): void => {
          if (!granted) {
            this.showSystem = false;
            AppSettings.setShowSystemCalendar(ctx, false);
          }
        });
      }
    });
    AppSettings.getSyncIntervalMinutes(ctx).then((v: number): void => {
      this.intervalMinutes = v;
    });
    AppSettings.getBackgroundSync(ctx).then((v: boolean): void => {
      this.backgroundSync = v;
    });
    AppSettings.getSysCalMode(ctx).then((v: string): void => {
      this.sysMode = v;
    });
    AppSettings.getManualReadonlyKeys(ctx).then((v: string[]): void => {
      this.manualKeys = v;
    });
    AppSettings.getMutedReminderKeys(ctx).then((v: string[]): void => {
      this.mutedKeys = v;
    });
    AppSettings.getDefaultView(ctx).then((v: string): void => {
      this.defaultView = v;
    });
    AppSettings.getDisplayStyle(ctx).then((v: string): void => {
      this.displayStyle = v;
    });
    this.refreshNotifyState();
    this.loadBackupSettings();
    this.loadAllBooks();
    AppSettings.getMirrorEnabled(ctx).then((v: boolean): void => {
      this.mirrorEnabled = v;
      // 状态自洽：记录为"开"但权限已被系统回收 → 自动回落为"关"
      if (v) {
        SystemCalendarMirror.hasPermission().then((ok: boolean): void => {
          if (!ok && this.context !== undefined) {
            this.mirrorEnabled = false;
            AppSettings.setMirrorEnabled(this.context, false);
            // 权限被回收 → 镜像失效 → 提醒应交回 App 负责
            ReminderService.invalidateMirrorCache();
          }
        });
      }
    });
    // ⭐ 走 selectedBookRefs：它兼做历史迁移（老版本存的是 calKey）与"排除备份目标本"过滤
    SystemCalendarMirror.selectedBookRefs(ctx).then((refs: BookRef[]): void => {
      const ids: string[] = [];
      for (const r of refs) {
        ids.push(r.bookId);
      }
      this.mirrorKeys = ids;
    });
    AppSettings.getMirrorInbound(ctx).then((v: boolean): void => {
      this.mirrorInbound = v;
    });
    // ⭐ 显示名格式：加载当前值 + 实时预览 + 检查是否还有旧格式账户
    AppSettings.getMirrorDisplayFormat(ctx).then((v: number): void => {
      this.displayFormat = v;
      this.displayFormatApplied = v;
      this.refreshFormatPreview();
    });
    MirrorRenamer.hasLegacyNamedAccounts(ctx).then((v: boolean): void => {
      this.hasLegacyNames = v;
    });
  }

  /** 用用户**实际的第一个账号名 + 第一个本名**拼出示例，让他所见即所得 */
  private refreshFormatPreview(): void {
    const ctx = this.context;
    if (ctx === undefined) {
      return;
    }
    const f: number = this.displayFormat;
    SystemCalendarMirror.selectedBookRefs(ctx).then((refs: BookRef[]): void => {
      if (refs.length > 0) {
        this.formatPreview = SystemCalendarMirror.displayNameFor(refs[0], f);
      } else {
        // 没有可用本时用占位示例
        const dummy = new BookRef();
        dummy.name = '个人日程';
        dummy.accountName = '工作';
        this.formatPreview = SystemCalendarMirror.displayNameFor(dummy, f);
      }
    });
  }

  /** ⭐ 按新格式重建镜像（回读→删→重建），期间日程短暂消失几秒 */
  private async applyDisplayFormat(): Promise<void> {
    const ctx = this.context;
    if (ctx === undefined || this.formatRunning) {
      return;
    }
    if (this.displayFormat === this.displayFormatApplied) {
      return; // 未变化，不需要重建
    }
    this.formatRunning = true;
    try {
      // 先落盘（reapplyDisplayNames 会按现有配置重建）
      await AppSettings.setMirrorDisplayFormat(ctx, this.displayFormat);
      const res: RenameResult = await MirrorRenamer.reapplyDisplayNames(
        ctx as common.UIAbilityContext);
      if (res.ok) {
        this.displayFormatApplied = this.displayFormat;
        this.hasLegacyNames = false;
        this.getUIContext().getPromptAction().showToast({
          message: `已更新系统日历中的名称（${res.mirrored} 个日历本）`
        });
      } else {
        // 失败 → 回滚选项与配置，避免"设置显示已改、实际没改"的错觉
        this.displayFormat = this.displayFormatApplied;
        await AppSettings.setMirrorDisplayFormat(ctx, this.displayFormatApplied);
        this.getUIContext().getPromptAction().showToast({ message: res.message });
      }
    } catch (err) {
      const e = err as BusinessError;
      this.displayFormat = this.displayFormatApplied;
      this.getUIContext().getPromptAction().showToast({ message: `更新失败：${e.message}` });
    }
    this.formatRunning = false;
    this.refreshFormatPreview();
  }

  /** 重新检测通知权限状态 */
  private refreshNotifyState(): void {
    notificationManager.isNotificationEnabled()
      .then((v: boolean): void => {
        this.notifyEnabled = v;
      })
      .catch((): void => {
        this.notifyEnabled = false;
      });
  }

  /**
   * 确认通知权限已开启 —— **只在用户主动使用依赖通知的功能时调用**
   * （保存带提醒的日程 / 开启后台持续同步 / 点击设置页"去开启通知"）。
   * ⚠️ 严禁在 App 启动、首次打开等用户未操作的时机调用（《审核指南》7.17）。
   */
  private async ensureNotifyPermission(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        await notificationManager.requestEnableNotification(
          this.context as common.UIAbilityContext);
      }
    } catch (err) {
      // 用户拒绝或系统未弹窗：不阻断功能，仅状态仍显示为未开启
    }
    this.refreshNotifyState();
  }

  /** 加载全部 DAV 日历本（含探测到的写权限，只读/静音标记管理用） */
  private async loadAllBooks(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const accounts: DavAccount[] = await AccountStore.loadAll(this.context);
    const books: BackupTarget[] = [];
    for (const acc of accounts) {
      if (acc.type !== 'caldav') {
        continue;
      }
      for (let i = 0; i < acc.calendarHrefs.length; i++) {
        const b = new BackupTarget();
        b.calKey = `${acc.id}_${i}`;
        const bookName: string = i < acc.calendarNames.length ? acc.calendarNames[i] : `日历本 ${i + 1}`;
        b.label = `${acc.name} · ${bookName}`;
        b.serverWritable = acc.calendarWritable.length > i ? acc.calendarWritable[i] !== '0' : true;
        books.push(b);
      }
    }
    // ⭐ 补上稳定标识 bookId（由服务器 href 派生）。镜像的"选中状态"必须按它存，
    //    否则日历本重排后序号一变，选中的本就串成另一个本。
    if (this.context !== undefined) {
      const refs: BookRef[] = await SystemCalendarMirror.listBooks(this.context);
      for (const b of books) {
        for (const ref of refs) {
          if (ref.calKey === b.calKey) {
            b.bookId = ref.bookId;
            break;
          }
        }
      }
    }
    this.allBooks = books;
    await this.refreshMirrorCandidates();
  }

  /**
   * 可镜像的日历本 = 全部 DAV 本 **去掉「系统日历备份目标本」**。
   * 备份目标本里的日程本来就来自系统日历（uid 前缀 syscal-），再镜像回系统日历就是自我复制。
   */
  private async refreshMirrorCandidates(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const ctx: common.Context = this.context;
    const blocked: string[] = await SystemCalendarMirror.blockedBookIds(ctx);
    this.mirrorCandidates =
      this.allBooks.filter((b: BackupTarget): boolean => b.bookId === '' || !blocked.includes(b.bookId));
    // 已选中的本若被改成备份目标 → 自动剔除并删掉它在系统日历里的镜像账户
    const kept: string[] = this.mirrorKeys.filter((k: string): boolean => !blocked.includes(k));
    if (kept.length !== this.mirrorKeys.length) {
      for (const k of this.mirrorKeys) {
        if (blocked.includes(k)) {
          await SystemCalendarMirror.removeById(ctx, k);
        }
      }
      this.mirrorKeys = kept;
      await AppSettings.setMirrorBookIds(ctx, kept);
    }
  }

  /** 因"是备份目标本"而被隐藏、不能镜像的本的数量 */
  private mirrorHiddenCount(): number {
    return this.allBooks.length - this.mirrorCandidates.length;
  }

  /** 已勾选的可镜像本数量（mirrorKeys 里可能残留已不在候选里的 bookId，按候选口径统计） */
  private mirrorSelectedCount(): number {
    return this.mirrorCandidates.filter((b: BackupTarget): boolean =>
      this.mirrorKeys.indexOf(b.bookId) >= 0).length;
  }

  /**
   * 「全选 / 全不选」要镜像的日历本。
   * ⭐ 批量落盘只写一次 preferences、缓存只失效一次（与逐个 toggle 的关键区别）；
   *    全不选时逐本删除对应系统日历账户（与取消单个勾选同一语义）。
   * 半选状态下点按 = 全选。
   */
  private async toggleMirrorAll(): Promise<void> {
    if (this.context === undefined || this.mirrorCandidates.length === 0) {
      return;
    }
    const selectAll: boolean = this.mirrorSelectedCount() < this.mirrorCandidates.length;
    if (selectAll) {
      const ids: string[] = this.mirrorCandidates.map((b: BackupTarget): string => b.bookId);
      this.mirrorKeys = ids;
      await AppSettings.setMirrorBookIds(this.context, ids);
      this.getUIContext().getPromptAction().showToast({
        message: `已全选 ${ids.length} 个日历本，点「立即执行镜像」写入系统日历`
      });
    } else {
      // 逐本删除系统日历账户；逐个独立 try，失败不影响其余
      for (const k of this.mirrorKeys) {
        try {
          await SystemCalendarMirror.removeById(this.context, k);
        } catch (err) {
          const e = err as BusinessError;
          console.error(`全不选：删除镜像账户失败 bookId=${k}: ${e.message}`);
        }
      }
      this.mirrorKeys = [];
      await AppSettings.setMirrorBookIds(this.context, []);
      this.getUIContext().getPromptAction().showToast({
        message: '已取消全部勾选，并清除对应的系统日历账户'
      });
    }
    // ⭐ 勾选本集合变化 → 提醒侧"已镜像本"缓存失效并重排提醒
    ReminderService.invalidateMirrorCache();
    await ReminderService.refreshReminders(this.context as common.UIAbilityContext);
  }

  /** 该日历本是否只读：服务器无写权限（探测结果）或用户手动标记只读 —— 与首页色块/只读标记同一口径 */
  private isBookReadonly(b: BackupTarget): boolean {
    return !b.serverWritable || this.manualKeys.includes(b.calKey);
  }

  /** 手动标记/取消只读 */
  private async toggleManualBook(b: BackupTarget): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const list: string[] = [...this.manualKeys];
    const idx: number = list.indexOf(b.calKey);
    if (idx >= 0) {
      list.splice(idx, 1);
    } else {
      list.push(b.calKey);
    }
    this.manualKeys = list;
    await AppSettings.setManualReadonlyKeys(this.context, list);
    await this.loadBackupSettings(); // 备份目标候选同步排除
    this.getUIContext().getPromptAction().showToast({
      message: idx >= 0 ? '已恢复为可写，返回首页生效' : '已标记为只读，返回首页生效'
    });
  }

  /** 切换日历本提醒静音：静音后该本所有日程不再发布系统提醒 */
  private async toggleMuteBook(b: BackupTarget): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const list: string[] = [...this.mutedKeys];
    const idx: number = list.indexOf(b.calKey);
    if (idx >= 0) {
      list.splice(idx, 1);
    } else {
      list.push(b.calKey);
    }
    this.mutedKeys = list;
    await AppSettings.setMutedReminderKeys(this.context, list);
    // 立即重建提醒（全量取消后按新静音规则重发），无需等下次同步
    try {
      await ReminderService.refreshReminders(this.context as common.UIAbilityContext);
    } catch (err) {
      // 重建失败不影响设置保存，下次同步时会再刷新
    }
    this.getUIContext().getPromptAction().showToast({
      message: idx >= 0
        ? '已恢复提醒'
        : '已静音：该日历本的所有日程不再提醒'
    });
  }

  /**
   * 加载备份目标候选（可写 DAV 日历本）+ 当前选择。
   *
   * ⭐ 当前选择用**稳定标识 bookId** 记录（老版本存 calKey，序号会漂移 → 曾把系统日历
   *    导进用户没选过的本）。这里统一走 `checkBackupTarget()`：
   *    - 老值自动迁移为 bookId；
   *    - 目标本已不存在（被取消勾选/账号删除）→ 它会把备份模式**自动关回 display**，
   *      这里只负责把结果反映到 UI 并给出提示。
   */
  private async loadBackupSettings(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    const ctx: common.Context = this.context;
    const accounts: DavAccount[] = await AccountStore.loadAll(ctx);
    const targets: BackupTarget[] = [];
    for (const acc of accounts) {
      if (acc.type !== 'caldav') {
        continue;
      }
      for (let i = 0; i < acc.calendarHrefs.length; i++) {
        const writable: boolean = acc.calendarWritable.length > i
          ? acc.calendarWritable[i] !== '0' : true;
        if (!writable) {
          continue;
        }
        const t = new BackupTarget();
        t.calKey = `${acc.id}_${i}`;
        const bookName: string = i < acc.calendarNames.length ? acc.calendarNames[i] : `日历本 ${i + 1}`;
        t.label = `${acc.name} · ${bookName}`;
        t.serverWritable = writable;
        targets.push(t);
      }
    }
    // 手动标记只读的本不可作为备份目标
    const manual: string[] = await AppSettings.getManualReadonlyKeys(ctx);
    this.backupTargets = targets.filter((t: BackupTarget): boolean => !manual.includes(t.calKey));
    // 补 bookId（稳定标识）—— 选择状态必须按它存
    const refs: BookRef[] = await SystemCalendarMirror.listBooks(ctx);
    for (const t of this.backupTargets) {
      for (const r of refs) {
        if (r.calKey === t.calKey) {
          t.bookId = r.bookId;
          break;
        }
      }
    }
    // 解析当前目标（可能触发失效清理，并在功能开着时自动关闭）
    const check: BackupTargetCheck = await SystemCalendarMirror.checkBackupTarget(ctx);
    this.backupKey = check.ref === undefined ? '' : check.ref.bookId;
    if (check.reason !== '') {
      this.backupNotice = check.closed
        ? `${check.reason}，已自动关闭系统日历备份。如需继续备份，请在下方重新选择目标日历本。`
        : `${check.reason}。请重新选择备份目标日历本后再开启备份。`;
    } else {
      this.backupNotice = '';
    }
    // 最后再以"落盘值"为准刷新一次选择器：aboutToAppear 里另有一条 getSysCalMode 的异步读取，
    // 若 checkBackupTarget 刚刚把模式关成了 display，就以这里读到的为准（避免旧值把 UI 覆盖回去）
    this.sysMode = await AppSettings.getSysCalMode(ctx);
  }

  /**
   * 切换「系统日历日程的处理方式」。
   *
   * ⚠️ 顺序很重要：**先校验备份目标、再申请权限、最后才落盘**。
   *   - 没有目标本就不允许开启备份（绝不替用户"随便挑一个本"——
   *     那样会把系统日程导进他没选过的日历本，用户实测反馈的问题）；
   *   - 校验不过就不申请「读取全部日程」权限，避免为一次注定失败的开启弹权限框。
   */
  private async saveSysMode(mode: string): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    if (mode !== 'backup') {
      this.sysMode = 'display';
      await AppSettings.setSysCalMode(this.context, 'display');
      this.backupNotice = '';
      await this.refreshMirrorCandidates(); // 备份模式变化 → 重算可镜像的本（防回灌）
      this.getUIContext().getPromptAction().showToast({
        message: '已切换为仅显示：不再把系统日程备份到 CalDAV'
      });
      return;
    }
    // ① 必须先有明确的备份目标本（见上方 loadBackupSettings / saveBackupTarget）
    if (this.backupKey === '') {
      this.sysMode = 'display'; // 回弹，且**不写 preferences**：宁可不开启，也不默认挑一个本
      this.backupNotice = this.backupTargets.length > 0
        ? '请先选择备份目标日历本：未选定目标前不会开启备份，也不会导入任何系统日程。'
        : '没有可写的 CalDAV 日历本，请先添加账号或检查日历本权限。';
      this.getUIContext().getPromptAction().showToast({
        message: '请先选择备份目标日历本，再开启备份'
      });
      return;
    }
    // ② "备份到 CalDAV" 需要读取手机系统（本地）日历 → 只在用户主动选择该模式时申请权限
    const granted: boolean = await CalendarDataService.requestSystemCalendarPermission(
      this.context as common.UIAbilityContext);
    if (!granted) {
      this.sysMode = 'display'; // 回弹选择，保持与实际授权状态一致
      this.getUIContext().getPromptAction().showToast({
        message: '未获得"读取全部日程"权限，无法开启系统日历备份'
      });
      return;
    }
    this.sysMode = mode;
    await AppSettings.setSysCalMode(this.context, mode);
    this.backupNotice = '';
    await this.refreshMirrorCandidates(); // 备份模式/目标变化 → 重算可镜像的本（防回灌）
    this.getUIContext().getPromptAction().showToast({
      message: '已开启备份：下次同步时把系统本地日程导入所选日历本'
    });
  }

  /** 保存备份目标（入参为 **bookId**，稳定标识，不再是会漂移的 calKey） */
  private async saveBackupTarget(bookId: string): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    this.backupKey = bookId;
    await AppSettings.setBackupBookId(this.context, bookId);
    this.backupNotice = ''; // 用户显式选定了目标 → 清掉"失效/未选择"提示
    await this.refreshMirrorCandidates(); // 备份目标变了 → 可镜像的本也要跟着变（防回灌）
    this.getUIContext().getPromptAction()
      .showToast({ message: '备份目标已更新，下次同步生效' });
  }

  /**
   * 保存「混合显示系统日历」开关。
   * ⚠️ 合规约束（《审核指南》7.17）：读取系统日历依赖"读取全部日程"敏感权限，
   * **只有在用户主动打开该开关时才申请**；未授权则开关回弹、不保存设置。
   */
  private async saveShowSystem(value: boolean): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    if (value) {
      const granted: boolean = await CalendarDataService.requestSystemCalendarPermission(
        this.context as common.UIAbilityContext);
      if (!granted) {
        this.showSystem = false; // 回弹开关，保持与实际授权状态一致
        this.getUIContext().getPromptAction().showToast({
          message: '未获得"读取全部日程"权限，无法混合显示系统日历'
        });
        return;
      }
    }
    await AppSettings.setShowSystemCalendar(this.context, value);
    this.getUIContext().getPromptAction()
      .showToast({ message: value ? '已开启系统日历混合显示，返回首页生效' : '已关闭系统日历混合显示，返回首页生效' });
  }

  /**
   * 「镜像到系统日历」开关。
   * ⚠️ 合规约束（《审核指南》7.17）：写入系统日历依赖 WRITE_CALENDAR 权限，
   * **只在用户主动打开这个开关时申请**；未授权则开关回弹、不保存设置。
   * 关闭时会把之前镜像出去的账户一并删掉，避免系统日历里留下"幽灵日程"。
   */
  private async saveMirrorEnabled(isOn: boolean): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    if (isOn) {
      const granted: boolean = await SystemCalendarMirror.requestPermission(
        this.context as common.UIAbilityContext);
      if (!granted) {
        this.mirrorEnabled = false; // 回弹开关，保持与实际授权状态一致
        this.getUIContext().getPromptAction().showToast({
          message: '未获得"写入系统日历"权限，无法开启镜像'
        });
        return;
      }
    }
    this.mirrorEnabled = isOn;
    await AppSettings.setMirrorEnabled(this.context, isOn);
    // ⭐ 镜像开关变化 → 立即失效提醒侧的"已镜像本"缓存，并重排提醒
    //    （开启：这些本改由系统日历提醒，App 不再重复；关闭：必须立刻恢复 App 提醒，避免漏提醒）
    ReminderService.invalidateMirrorCache();
    if (isOn) {
      this.getUIContext().getPromptAction().showToast({
        message: '已开启镜像：勾选要同步的日历本后点「立即执行镜像」'
      });
      await ReminderService.refreshReminders(this.context as common.UIAbilityContext);
      return;
    }
    const n: number = await SystemCalendarMirror.removeAll(this.context);
    // 关闭镜像后，这些本的提醒要交回 App 负责
    await ReminderService.refreshReminders(this.context as common.UIAbilityContext);
    this.getUIContext().getPromptAction().showToast({
      message: n > 0 ? `已关闭镜像，并清除系统日历中的 ${n} 个镜像账户` : '已关闭镜像'
    });
  }

  /** 勾选/取消勾选要镜像的日历本；取消勾选会顺手删掉对应的系统日历账户。⚠️ 传的是 bookId */
  private async toggleMirrorKey(bookId: string, on: boolean): Promise<void> {
    if (this.context === undefined || bookId === '') {
      return;
    }
    const idx: number = this.mirrorKeys.indexOf(bookId);
    if (on && idx < 0) {
      this.mirrorKeys = [...this.mirrorKeys, bookId];
    } else if (!on && idx >= 0) {
      this.mirrorKeys = this.mirrorKeys.filter((k: string): boolean => k !== bookId);
      await SystemCalendarMirror.removeById(this.context, bookId);
    } else {
      return;
    }
    await AppSettings.setMirrorBookIds(this.context, this.mirrorKeys);
    // ⭐ 勾选本变化 → 提醒侧"已镜像本"集合变化：失效缓存并重排提醒
    ReminderService.invalidateMirrorCache();
    await ReminderService.refreshReminders(this.context as common.UIAbilityContext);
  }

  /**
   * 「把系统日历的改动回写」开关（双向闭环的回程）。
   * 依赖镜像快照（MirrorSnapshot）防回灌：只把"和上次写入值不一样"的当成用户改动。
   * ⚠️ 默认关，因为它会写用户的服务器数据 —— 建议先单向观察一轮再打开。
   */
  private async saveMirrorInbound(isOn: boolean): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    this.mirrorInbound = isOn;
    await AppSettings.setMirrorInbound(this.context, isOn);
    this.getUIContext().getPromptAction().showToast({
      message: isOn
        ? '已开启回写：系统日历里的新建/修改/删除，下次同步时传回服务器'
        : '已关闭回写：系统日历的改动不再传回服务器'
    });
  }

  /** 手动执行一次镜像（幂等，可反复点） */
  private async runMirrorNow(): Promise<void> {
    if (this.context === undefined || this.mirrorRunning) {
      return;
    }
    if (this.mirrorKeys.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请先勾选要镜像的日历本' });
      return;
    }
    this.mirrorRunning = true;
    try {
      const res: MirrorResult = await SystemCalendarMirror.syncNow(this.context);
      const skip: string = res.skipped > 0 ? ` / 跳过 ${res.skipped}` : '';
      this.getUIContext().getPromptAction().showToast({
        message: `镜像完成：${res.books} 个本，新增 ${res.added} / 更新 ${res.updated} / 删除 ${res.deleted}${skip}`
      });
    } catch (err) {
      const e = err as BusinessError;
      const msg: string = e.message !== undefined && e.message !== ''
        ? e.message : '请确认已授予"写入系统日历"权限';
      this.getUIContext().getPromptAction().showToast({ message: `镜像失败：${msg}` });
    } finally {
      this.mirrorRunning = false;
    }
  }

  /**
   * 「清理残留镜像账户（诊断）」按钮：
   * ① 读系统日历里**全部**账户（含 id / name / displayName / type）并显示在下方清单里；
   * ② 把"我们建的、但不属于当前选中本"的账户全部删掉（逐个独立 try，失败也继续）；
   * ③ Toast 汇总成功/失败/残留数量，残留账户名直接显示出来。
   */
  private async runPurgeOrphans(): Promise<void> {
    if (this.context === undefined || this.purgeRunning) {
      return;
    }
    this.purgeRunning = true;
    try {
      const r: PurgeResult = await SystemCalendarMirror.forceCleanup(this.context);
      this.accountDump = r.detail.join('\n');
      let msg: string = `已清理 ${r.removed} 个残留账户`;
      if (r.failed > 0) {
        msg += `，失败 ${r.failed} 个`;
      }
      if (r.remaining > 0) {
        msg += `；仍残留 ${r.remaining} 个：${r.remainingNames.join(' , ')}`;
      }
      // ⭐ 0.0.8：不再写同步日志 → 提示语改为指向页面下方那份清单（accountDump）
      msg += '（完整账户清单见下方）';
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 6000 });
    } catch (err) {
      const e = err as BusinessError;
      this.getUIContext().getPromptAction().showToast({
        message: `清理失败：${e.message ?? '请确认已授予"写入系统日历"权限'}`
      });
    } finally {
      this.purgeRunning = false;
    }
  }

  /**
   * ⭐「彻底清除全部镜像数据」（卸载前清干净用）。
   *
   * 为什么需要它：鸿蒙**没有**「应用即将被卸载」的回调，系统日历属于**沙箱外**数据，
   * 卸载时不会自动清理。用户卸载后，系统日历里会永久留着一堆
   * 「同步日历·xxx」账户（还会继续提醒），只有重装并重新同步才能被当孤儿清掉。
   * ⇒ 提供显式入口，让用户在卸载前主动清干净。
   *
   * ⚠️ 清除范围（务必与文案一致）：
   *   - 只删**系统日历里本应用建立的镜像账户及其日程**
   *   - **不动** CalDAV 账号配置（账号密码仍保留，重装后可直接用）
   *   - **不动** 服务器上的任何日程（同步过去的内容一条都不会少）
   */
  private confirmWipeAllMirrors(): void {
    if (this.context === undefined || this.wipeAllRunning) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '彻底清除系统日历镜像数据',
      message: '将删除本应用写入系统日历的全部镜像日历本及其日程。\n\n'
        + '只影响系统日历：你的 CalDAV 账号与服务器上的日程完全不受影响。\n'
        + '清除后系统日历里不再显示这些日程，也不再提醒；镜像开关会一并关闭。\n\n'
        + '准备卸载本应用时，请先点这里清干净（卸载时系统不会自动清除）。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '确认清除',
        action: (): void => {
          this.doWipeAllMirrors();
        }
      }
    });
  }

  private async doWipeAllMirrors(): Promise<void> {
    if (this.context === undefined || this.wipeAllRunning) {
      return;
    }
    this.wipeAllRunning = true;
    try {
      const n: number = await SystemCalendarMirror.removeAll(this.context);
      // ⭐ 必须同时把"镜像开关"关掉并落库：否则下一轮同步会立刻按勾选重新建回来，
      //    用户会以为"清了等于没清"。
      this.mirrorEnabled = false;
      await AppSettings.setMirrorEnabled(this.context, false);
      // 镜像本没了 → 提醒要交回 App 负责，否则这些本会既没系统提醒、也没 App 提醒（漏提醒）
      ReminderService.invalidateMirrorCache();
      await ReminderService.refreshReminders(this.context as common.UIAbilityContext);
      // ⭐ 清空结果必须说清楚：用户点这个按钮就是为了"确认卸载后不留东西"，
      //    所以"0 个"也要区分是权限没给（没清成）还是本来就干净（放心）
      const granted: boolean = await SystemCalendarMirror.hasPermission();
      let msg: string = '';
      if (n > 0) {
        msg = `已清除 ${n} 个镜像日历本，系统日历中不再有本应用的日程；镜像开关已关闭`;
      } else if (!granted) {
        msg = '未授予"写入系统日历"权限，无法清除。请先在设置中允许本应用读写日历后重试';
      } else {
        msg = '系统日历中已没有本应用的镜像数据，无需清除';
      }
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 5000 });
    } catch (err) {
      const e = err as BusinessError;
      this.getUIContext().getPromptAction().showToast({
        message: `清除失败：${e.message ?? '请确认已授予"写入系统日历"权限'}`
      });
    } finally {
      this.wipeAllRunning = false;
    }
  }

  private async saveInterval(minutes: number): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    await AppSettings.setSyncIntervalMinutes(this.context, minutes);
    AppStorage.setOrCreate('syncIntervalMinutes', minutes);
    this.getUIContext().getPromptAction()
      .showToast({ message: `自动同步间隔已设为 ${minutes} 分钟` });
  }

  private async saveBackgroundSync(value: boolean): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    try {
      await BackgroundSyncService.setBackgroundSync(
        this.context as common.UIAbilityContext, value);
      this.getUIContext().getPromptAction().showToast({
        message: value ? '后台自动同步已开启' : '后台自动同步已关闭'
      });
    } catch (err) {
      this.backgroundSync = !value; // 失败回滚 UI
      const msg: string = (err as BusinessError).message !== ''
        ? (err as BusinessError).message : '请重试';
      this.getUIContext().getPromptAction().showToast({ message: `设置失败：${msg}` });
    }
  }

  private async saveDefaultView(view: string): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    this.defaultView = view;
    await AppSettings.setDefaultView(this.context, view);
    const label: string = view === 'month' ? '月视图' : (view === 'week' ? '周视图' : '列表视图');
    this.getUIContext().getPromptAction()
      .showToast({ message: `默认视图已设为「${label}」，下次打开 App 生效` });
  }

  private defaultViewLabel(): string {
    return this.defaultView === 'month' ? '月视图'
      : (this.defaultView === 'week' ? '周视图' : '列表视图');
  }

  private async saveDisplayStyle(style: string): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    this.displayStyle = style;
    await AppSettings.setDisplayStyle(this.context, style);
    // 同步刷桌面卡片：让 4×4 / 6×4 卡片立刻按新方式重绘（列表模式去掉红线）
    try {
      await CardDataService.pushToAllForms(this.context);
    } catch (err) {
      // 卡片刷新失败不影响设置保存，下次同步或卡片自刷新时会生效
    }
    this.getUIContext().getPromptAction().showToast({
      message: style === 'list'
        ? '已切换为列表显示（不显示当前时间红线）'
        : '已切换为时间轴显示'
    });
  }

  private intervalLabel(minutes: number): string {
    return minutes >= 60 ? `${minutes / 60} 小时` : `${minutes} 分钟`;
  }

  /** 确认后重置全量重拉标记，下次同步重建全部日程数据 */
  private askRebuildData(): void {
    this.getUIContext().showAlertDialog({
      title: '重建日程数据',
      message: '将重新从服务器拉取所有日程的完整数据（包括提醒），本地已修改未同步的内容不受影响。\n\n全量拉取可能需要几分钟，期间请保持 App 在前台、不要熄屏。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '开始重建',
        action: (): void => {
          this.doRebuildData();
        }
      }
    });
  }

  private async doRebuildData(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    await AppSettings.resetFullRefetch(this.context);
    this.getUIContext().getPromptAction().showToast({
      message: '已开启，返回首页后点一次同步即可，请保持屏幕常亮'
    });
  }

  /** 确认后清空本地账号库（密码一并删除不可恢复；服务器日程不受影响） */
  private askResetVault(): void {
    this.getUIContext().showAlertDialog({
      title: '重置账号库',
      message: '将删除本机保存的全部账号、服务器地址与密码，回到"还没添加过账号"的状态。\n\n'
        + '日历数据保存在你的 CalDAV 服务器上，不受影响：重新添加账号并同步一次即可恢复。\n\n'
        + '本操作不可撤销（本地密码会一并删除），仅在账号读不出来、也无法新增账号时使用。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '确认重置',
        action: (): void => {
          this.doResetVault();
        }
      }
    });
  }

  private async doResetVault(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    try {
      // ⭐ 账号库整体重置 = 所有账号都没了 → 系统日历里的全部镜像账户也应一并清除
      //    （否则会留下一堆无主的幽灵日历本，且再无人能对应回账号）。
      //    未授权/无镜像时返回 0，不影响重置本身。
      let mirrored: number = 0;
      try {
        mirrored = await SystemCalendarMirror.removeAll(this.context);
      } catch (err) {
        // 清理失败不阻断重置
      }
      await AccountStore.resetVault(this.context);
      this.getUIContext().getPromptAction().showToast({
        message: mirrored > 0
          ? `账号库已重置，并清除系统日历中 ${mirrored} 个镜像日历本`
          : '账号库已重置，请重新添加账号'
      });
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({
        message: '重置失败，请稍后重试'
      });
    }
  }

  /** 去系统设置开启本应用通知 */
  private async openNotifySettings(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    try {
      await notificationManager.requestEnableNotification(this.context as common.UIAbilityContext);
      this.refreshNotifyState(); // 返回后重新检测状态
    } catch (err) {
      // 用户取消或未跳转，状态保持原样
    }
  }

  /**
   * 打开外部链接（隐私政策 / 用户服务协议 / 开源仓库）。
   * 仅放行 http(s)：避免 URL 被篡改或误传为 file://、自定义 scheme、intent 类 URI 时，
   * 拉起本地文件或任意第三方应用 —— 把"打开网页"严格限定在预期范围内。
   */
  private async openUrl(url: string): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    if (!url.startsWith('https://') && !url.startsWith('http://')) {
      this.getUIContext().getPromptAction().showToast({ message: '仅支持打开 http(s) 链接' });
      return;
    }
    try {
      await (context as common.UIAbilityContext).openLink(url);
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开链接' });
    }
  }

  /**
   * 用内置浏览器（整页 Web 覆盖层）打开法律文档 —— 不跳出应用、随时可关闭。
   * 先收起"隐私政策与用户协议"弹层，再显示覆盖层，避免两层叠在一起看不清。
   */
  private openDoc(title: string, url: string): void {
    if (!url.startsWith('https://') && !url.startsWith('http://')) {
      this.getUIContext().getPromptAction().showToast({ message: '仅支持打开 http(s) 链接' });
      return;
    }
    this.showLegal = false;
    this.docTitle = title;
    this.docUrl = url;
    this.showDoc = true;
  }

  build() {
    Stack() {
      Column() {
      // 顶部
      Row({ space: 10 }) {
        Text('←')
          .fontSize(20)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            router.back();
          })
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // 系统日历模式：仅显示 / 备份到 CalDAV
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('系统日历')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('选择手机系统日历日程的处理方式（需授权读取系统日历）')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            Select([{ value: '仅显示（不做备份）' }, { value: '备份到 CalDAV 日历本' }] as SelectOption[])
              .selected(this.sysMode === 'backup' ? 1 : 0)
              .value(this.sysMode === 'backup' ? '备份到 CalDAV 日历本' : '仅显示（不做备份）')
              .fontColor($r('app.color.text_primary'))
              .font({ size: 14 })
              .optionFont({ size: 14 })
              .selectedOptionFont({ size: 14 })
              .width('100%')
              .onSelect((index: number) => {
                const mode: string = index === 1 ? 'backup' : 'display';
                if (mode !== this.sysMode) {
                  this.saveSysMode(mode);
                }
              })
            // ⭐ 备份目标**始终可配置**（不再只在 backup 模式下显示）：
            //    否则"先选目标才能开启备份"会变成死锁（Select 只在 backup 模式下渲染）。
            Text(this.backupTargets.length > 0
              ? '备份目标（可写日历本）：导入后随同步上传服务器，换机/丢失也有备份'
              : '没有可写的 CalDAV 日历本，请先添加账号或检查日历本权限')
              .fontSize(12)
              .fontColor(this.backupTargets.length > 0
                ? $r('app.color.text_secondary') : $r('app.color.error'))
              .width('100%')
            if (this.backupTargets.length > 0) {
              Select(this.backupTargets.map((t: BackupTarget): SelectOption => {
                return { value: t.label } as SelectOption;
              }) as SelectOption[])
                .selected(this.backupTargets.findIndex((t: BackupTarget): boolean => t.bookId === this.backupKey))
                .value(this.backupTargets.find((t: BackupTarget): boolean => t.bookId === this.backupKey)?.label
                  ?? '请选择日历本')
                .fontColor($r('app.color.text_primary'))
                .font({ size: 14 })
                .optionFont({ size: 14 })
                .selectedOptionFont({ size: 14 })
                .width('100%')
                .onSelect((index: number) => {
                  if (index >= 0 && index < this.backupTargets.length) {
                    this.saveBackupTarget(this.backupTargets[index].bookId);
                  }
                })
            }
            // 失效/未选择提示：目标本没了时功能已被自动关闭，必须让用户看得见原因
            if (this.backupNotice !== '') {
              Row({ space: 6 }) {
                Text('⚠️')
                  .fontSize(12)
                  .fontColor($r('app.color.error'))
                Text(this.backupNotice)
                  .fontSize(12)
                  .fontColor($r('app.color.error'))
                  .layoutWeight(1)
              }
              .width('100%')
              .padding(8)
              .borderRadius(8)
              .backgroundColor($r('app.color.error_bg'))
            } else if (this.backupTargets.length > 0 && this.backupKey === '') {
              Text('尚未选择备份目标：请先选择要把系统日历备份到哪个 CalDAV 日历本，否则无法开启备份')
                .fontSize(12)
                .fontColor($r('app.color.error'))
                .width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 镜像到系统日历：把选中的 CalDAV 日历本写入系统日历，让小艺 / 桌面卡片 / 手表也能看到
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('镜像到系统日历')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('把选中的 CalDAV 日历本写入系统日历，这样小艺、桌面日历卡片和手表也能看到你的日程（需授权写入系统日历）')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.mirrorEnabled })
                .selectedColor($r('app.color.brand'))
                .onChange((isOn: boolean) => {
                  this.saveMirrorEnabled(isOn);
                })
            }
            .width('100%')

            if (this.mirrorEnabled) {
              if (this.mirrorCandidates.length === 0) {
                Text('没有可镜像的 CalDAV 日历本，请先添加账号')
                  .fontSize(12)
                  .fontColor($r('app.color.error'))
                  .width('100%')
              } else {
                Text('选择要镜像的日历本：每个本在系统日历里是独立账户，可单独设色与隐藏')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                if (this.mirrorHiddenCount() > 0) {
                  Text(`另有 ${this.mirrorHiddenCount()} 个本被设为「系统日历备份目标」，其日程本就来自系统日历，已自动排除以免重复`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_hint'))
                    .width('100%')
                }
                // ⭐ 全选 / 全不选：半选状态下点按 = 全选
                Row({ space: 6 }) {
                  Text(`全选（已选 ${this.mirrorSelectedCount()}/${this.mirrorCandidates.length}）`)
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                    .maxLines(1)
                  Toggle({
                    type: ToggleType.Checkbox,
                    isOn: this.mirrorCandidates.length > 0
                      && this.mirrorSelectedCount() === this.mirrorCandidates.length
                  })
                    .selectedColor($r('app.color.brand'))
                    .onChange((on: boolean): void => {
                      // 半选时勾选框显示为关，onChange(on=true) 走全选；全选时取消走全不选
                      if (on === (this.mirrorSelectedCount() === this.mirrorCandidates.length)) {
                        return; // 状态未变化（个别系统会重复回调），忽略
                      }
                      this.toggleMirrorAll();
                    })
                }
                .width('100%')
                .padding({ top: 2, bottom: 2 })
                .onClick(() => {
                  // 整行可点：直接按"是否已全选"翻转，比依赖 Checkbox 的 onChange 更可靠
                  this.toggleMirrorAll();
                })

                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                  ForEach(this.mirrorCandidates, (b: BackupTarget): void => {
                    Row({ space: 6 }) {
                      Text(b.label)
                        .fontSize(13)
                        .fontColor($r('app.color.text_primary'))
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Toggle({ type: ToggleType.Checkbox, isOn: this.mirrorKeys.indexOf(b.bookId) >= 0 })
                        .selectedColor($r('app.color.brand'))
                        .onChange((on: boolean) => {
                          this.toggleMirrorKey(b.bookId, on);
                        })
                    }
                    .width('48%')
                    .padding({ left: 2, right: 2, top: 4, bottom: 4 })
                  }, (b: BackupTarget): string => b.calKey)
                }
                .width('100%')

                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Text('把系统日历的改动回写')
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                    Text('你在系统日历里新建、修改、删除的日程，同步回 CalDAV 服务器')
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.mirrorInbound })
                    .selectedColor($r('app.color.brand'))
                    .onChange((isOn: boolean) => {
                      this.saveMirrorInbound(isOn);
                    })
                }
                .width('100%')
                .padding({ top: 4 })

                // ⭐ 系统日历中的显示名称（0.0.8）：三种格式，切换需重建镜像
                Column({ space: 6 }) {
                  Text('系统日历中的显示名称')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                  if (this.hasLegacyNames) {
                    Text('当前名称是旧格式，你可以在下方更换显示方式')
                      .fontSize(12)
                      .fontColor($r('app.color.brand_text'))
                      .width('100%')
                  }
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach([
                      { v: 1, label: '同步日历·本名' },
                      { v: 2, label: '同步日历·账号·本名' },
                      { v: 3, label: '账号·本名' }
                    ], (opt: Record<string, string | number>): void => {
                      Text(opt.label as string)
                        .fontSize(12)
                        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                        .margin({ right: 8, bottom: 6 })
                        .borderRadius(14)
                        .backgroundColor(this.displayFormat === (opt.v as number)
                          ? $r('app.color.brand') : $r('app.color.card_bg'))
                        .fontColor(this.displayFormat === (opt.v as number)
                          ? $r('app.color.button_text') : $r('app.color.text_primary'))
                        .border({
                          width: 1,
                          color: this.displayFormat === (opt.v as number)
                            ? $r('app.color.brand') : $r('app.color.shadow_color')
                        })
                        .onClick(() => {
                          this.displayFormat = opt.v as number;
                          this.refreshFormatPreview();
                        })
                    }, (opt: Record<string, string | number>): string => `fmt_${opt.v}`)
                  }
                  .width('100%')
                  Text(`示例：${this.formatPreview}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                  Text('修改后需重新写入系统日历，期间日程会短暂消失几秒')
                    .fontSize(11)
                    .fontColor($r('app.color.text_hint'))
                    .width('100%')
                  Button(this.formatRunning ? '正在应用…'
                    : (this.displayFormat === this.displayFormatApplied ? '已应用' : '应用'))
                    .fontSize(13)
                    .width('100%')
                    .enabled(!this.formatRunning && this.displayFormat !== this.displayFormatApplied)
                    .onClick(() => {
                      this.applyDisplayFormat();
                    })
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding({ top: 8 })

                Button(this.mirrorRunning ? '正在执行…' : '立即执行镜像')
                  .fontSize(14)
                  .width('100%')
                  .enabled(!this.mirrorRunning)
                  .onClick(() => {
                    this.runMirrorNow();
                  })


                Button(this.purgeRunning ? '正在清理…' : '清理残留镜像账户（诊断）')
                  .fontSize(13)
                  .fontColor($r('app.color.brand_text'))
                  .backgroundColor(Color.Transparent)
                  .width('100%')
                  .enabled(!this.purgeRunning)
                  .onClick(() => {
                    this.runPurgeOrphans();
                  })

                if (this.accountDump !== '') {
                  Column({ space: 4 }) {
                    Text('系统日历账户清单（MINE=我们建的，KEEP=本次保留；长按可复制）：')
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                      .width('100%')
                    Scroll() {
                      Text(this.accountDump)
                        .fontSize(10)
                        .lineHeight(14)
                        .fontColor($r('app.color.text_primary'))
                        .copyOption(CopyOptions.LocalDevice)
                        .width('100%')
                    }
                    .height(150)
                    .width('100%')
                    .backgroundColor($r('app.color.page_bg'))
                    .borderRadius(8)
                    .padding(6)
                  }
                  .width('100%')
                  .padding({ top: 4 })
                }
              }
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // ⭐ WIPE_CARD_MOVED：数据清除独立成卡（不依赖镜像开关是否开启）
          //    鸿蒙没有"应用即将被卸载"的回调，而系统日历属于沙箱外的系统数据，
          //    卸载时不会自动清理 ⇒ 必须提供显式入口，让用户卸载前主动清干净。
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('清除系统日历数据')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('卸载本应用前请先清除，否则系统日历里会一直留着这些日程（还会提醒）')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')

            Button(this.wipeAllRunning ? '正在清除…' : '彻底清除系统日历镜像数据')
              .fontSize(14)
              .fontColor($r('app.color.error'))
              .backgroundColor(Color.Transparent)
              .border({ width: 1, color: $r('app.color.error') })
              .width('100%')
              .enabled(!this.wipeAllRunning)
              .onClick(() => {
                this.confirmWipeAllMirrors();
              })

            Text('只删系统日历里的镜像本；CalDAV 账号与服务器上的日程一条都不会少。清除后镜像开关会自动关闭。')
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
              .width('100%')

            Button(this.purgeRunning ? '正在清理…' : '清理残留镜像账户（诊断）')
              .fontSize(13)
              .fontColor($r('app.color.brand_text'))
              .backgroundColor(Color.Transparent)
              .width('100%')
              .enabled(!this.purgeRunning)
              .onClick(() => {
                this.runPurgeOrphans();
              })

            if (this.accountDump !== '') {
              Column({ space: 4 }) {
                Text('系统日历账户清单（MINE=我们建的，KEEP=本次保留；长按可复制）：')
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                Scroll() {
                  Text(this.accountDump)
                    .fontSize(10)
                    .lineHeight(14)
                    .fontColor($r('app.color.text_primary'))
                    .copyOption(CopyOptions.LocalDevice)
                    .width('100%')
                }
                .height(150)
                .width('100%')
                .backgroundColor($r('app.color.page_bg'))
                .borderRadius(8)
                .padding(6)
              }
              .width('100%')
              .padding({ top: 4 })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 默认视图：打开 App 后默认展示的视图（月/周/列表）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('默认视图')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('打开 App 后默认展示的视图（月 / 周 / 列表）')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Select([{ value: '月视图' }, { value: '周视图' }, { value: '列表视图' }] as SelectOption[])
                .selected(this.defaultView === 'month' ? 0 : (this.defaultView === 'week' ? 1 : 2))
                .value(this.defaultViewLabel())
                .fontColor($r('app.color.text_primary'))
                .font({ size: 14 })
                .optionFont({ size: 14 })
                .selectedOptionFont({ size: 14 })
                .onSelect((index: number) => {
                  const v: string = index === 0 ? 'month' : (index === 1 ? 'week' : 'agenda');
                  if (v !== this.defaultView) {
                    this.saveDefaultView(v);
                  }
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 日程显示方式：时间轴 / 列表（同时作用于主界面与桌面卡片）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('日程显示方式')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('时间轴：按时间刻度看一天的占用与冲突；列表：快速扫读、适合长标题。列表模式不显示当前时间红线')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Select([{ value: '时间轴' }, { value: '列表' }] as SelectOption[])
                .selected(this.displayStyle === 'list' ? 1 : 0)
                .value(this.displayStyle === 'list' ? '列表' : '时间轴')
                .fontColor($r('app.color.text_primary'))
                .font({ size: 14 })
                .optionFont({ size: 14 })
                .selectedOptionFont({ size: 14 })
                .onSelect((index: number) => {
                  const v: string = index === 1 ? 'list' : 'timeline';
                  if (v !== this.displayStyle) {
                    this.saveDisplayStyle(v);
                  }
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 数据修复：手动触发一次性全量重拉（重建提醒等本地残缺字段）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('重建日程数据')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('同步时重新从服务器拉取全部日程的完整数据，修复提醒丢失等本地数据问题。耗时段落请保持 App 在前台、屏幕常亮')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button('重建')
                .fontSize(13)
                .backgroundColor($r('app.color.brand'))
                .onClick(() => {
                  this.askRebuildData();
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 逃生舱：账号库读不出来（密钥丢失/失效）时，只清账号，不动设置与日程
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('重置账号库')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('清空本机保存的账号、服务器地址与密码。服务器上的日程不受影响，重新添加账号并同步即可恢复。仅在账号读不出来、也无法新增账号时使用')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button('重置')
                .fontSize(13)
                .backgroundColor($r('app.color.error'))
                .onClick(() => {
                  this.askResetVault();
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 混合显示系统日历
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('混合显示系统日历')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('关闭后只显示 DAV 账号的日程')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.showSystem })
                .selectedColor($r('app.color.brand'))
                .onChange((isOn: boolean) => {
                  if (isOn !== this.showSystem) {
                    this.showSystem = isOn;
                    this.saveShowSystem(isOn);
                  }
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 自动同步间隔
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('自动同步间隔')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('应用打开期间按此间隔自动同步')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Select([{ value: '1 分钟' }, { value: '5 分钟' }, { value: '15 分钟' },
                { value: '30 分钟' }, { value: '1 小时' }] as SelectOption[])
                .selected(INTERVAL_OPTIONS.indexOf(this.intervalMinutes))
                .value(this.intervalLabel(this.intervalMinutes))
                .fontColor($r('app.color.text_primary'))
                .font({ size: 14 })
                .optionFont({ size: 14 })
                .selectedOptionFont({ size: 14 })
                .onSelect((index: number) => {
                  if (index >= 0 && index < INTERVAL_OPTIONS.length) {
                    this.intervalMinutes = INTERVAL_OPTIONS[index];
                    this.saveInterval(INTERVAL_OPTIONS[index]);
                  }
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 后台自动同步
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('后台自动同步')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('开启后，退到后台仍会定时同步（系统最短约 2 小时一次）；回到前台或网络恢复时会立即补同步一次')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.backgroundSync })
                .selectedColor($r('app.color.brand'))
                .onChange((isOn: boolean) => {
                  if (isOn !== this.backgroundSync) {
                    this.backgroundSync = isOn;
                    this.saveBackgroundSync(isOn);
                  }
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 通知权限：仅检测是否开启，未开启则引导去设置
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Row({ space: 6 }) {
                  Text('通知权限')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text(this.notifyEnabled ? '已开启' : '未开启')
                    .fontSize(11)
                    .fontColor(this.notifyEnabled ? $r('app.color.success') : $r('app.color.error'))
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .borderRadius(10)
                    .backgroundColor(this.notifyEnabled ? $r('app.color.success_bg') : $r('app.color.error_bg'))
                }
                Text(this.notifyEnabled
                  ? '日程提醒将正常以系统通知弹出'
                  : '未开启系统通知，日程提醒无法弹出')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            if (!this.notifyEnabled) {
              Button('去开启通知')
                .fontSize(13)
                .backgroundColor($r('app.color.brand'))
                .onClick(() => {
                  this.openNotifySettings();
                })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })

          // 软件特性（打开内置浏览器；内容为在线文档 sf.html，便于随时更新）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('软件特性')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('了解这个应用的特点与隐私理念')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_hint'))
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })
          .onClick(() => {
            this.openDoc(AppSettings.FEATURES_TITLE, AppSettings.FEATURES_URL);
          })

          // 使用帮助（打开内置浏览器；内容为在线文档 uh.html，便于随时更新）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('使用帮助')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('查看交互逻辑与使用方法')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_hint'))
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })
          .onClick(() => {
            this.openDoc(AppSettings.HELP_TITLE, AppSettings.HELP_URL);
          })

          // 隐私政策与用户协议（点击弹层；bindSheet 挂在本卡片上，避免与其它弹层冲突）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('隐私政策与用户协议')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('查看本应用如何处理你的信息，以及使用条款')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_hint'))
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })
          .onClick(() => {
            this.showLegal = true;
          })
          .bindSheet($$this.showLegal, this.legalSheet(), {
            height: 400,
            dragBar: true,
            showClose: true,
            title: { title: '隐私政策与用户协议' }
          })

          // 日历本只读 / 静音（放在最下方；本多时列表较长）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('日历本只读 / 静音')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('只读：标记后该本日程仅可查看、不再可新建；静音：该本所有日程不再提醒')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            if (this.allBooks.length === 0) {
              Text('暂无 CalDAV 日历本')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .width('100%')
            }
            ForEach(this.allBooks, (b: BackupTarget) => {
              Row({ space: 8 }) {
                // 日历本色点：只读本变中性灰 —— 相当于给这个本盖了一层灰蒙板
                Column()
                  .width(8)
                  .height(8)
                  .borderRadius(4)
                  .backgroundColor(this.isBookReadonly(b)
                    ? '#B0B4BA' : $r('app.color.brand'))
                Text(b.label)
                  .fontSize(13)
                  .fontColor(this.isBookReadonly(b)
                    ? $r('app.color.text_hint') : $r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Button(this.manualKeys.includes(b.calKey) ? '已只读' : '只读')
                  .fontSize(11)
                  .height(28)
                  .fontColor(this.manualKeys.includes(b.calKey)
                    ? $r('app.color.button_text') : $r('app.color.text_secondary'))
                  .backgroundColor(this.manualKeys.includes(b.calKey)
                    ? $r('app.color.brand') : $r('app.color.card_bg'))
                  .border({
                    width: this.manualKeys.includes(b.calKey) ? 0 : 1,
                    color: $r('app.color.shadow_color')
                  })
                  .onClick(() => {
                    this.toggleManualBook(b);
                  })
                Button(this.mutedKeys.includes(b.calKey) ? '已静音' : '静音')
                  .fontSize(11)
                  .height(28)
                  .fontColor(this.mutedKeys.includes(b.calKey)
                    ? $r('app.color.button_text') : $r('app.color.text_secondary'))
                  .backgroundColor(this.mutedKeys.includes(b.calKey)
                    ? $r('app.color.error') : $r('app.color.card_bg'))
                  .border({
                    width: this.mutedKeys.includes(b.calKey) ? 0 : 1,
                    color: $r('app.color.shadow_color')
                  })
                  .onClick(() => {
                    this.toggleMuteBook(b);
                  })
              }
              .width('100%')
              .padding({ left: 6, right: 6, top: 6, bottom: 6 })
              .borderRadius(8)
            }, (b: BackupTarget) => `book_${b.calKey}_r${this.manualKeys.includes(b.calKey) ? 1 : 0}_m${this.mutedKeys.includes(b.calKey) ? 1 : 0}_w${b.serverWritable ? 1 : 0}`)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.shadow_color') })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 8, bottom: 20 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))

      // 内置文档浏览器（《隐私政策》/《用户服务协议》/《软件特性》/《使用帮助》）：
      // 整页覆盖层，点"✕"即刻返回设置页
      if (this.showDoc) {
        DocViewer({
          title: this.docTitle,
          url: this.docUrl,
          onClose: (): void => {
            this.showDoc = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
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


  /** 隐私政策与用户协议弹层 */
  @Builder
  legalSheet() {
    Scroll() {
      Column({ space: 12 }) {
        Text('我们遵循"数据自持、最小必要"原则：开发者不保存你的日程与账号数据，不收集通讯录、相册、剪贴板等信息，不含任何第三方统计或广告 SDK。')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Button('查看《隐私政策》')
          .width('100%')
          .fontSize(15)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            this.openDoc(AppSettings.PRIVACY_TITLE, AppSettings.PRIVACY_URL);
          })
        Button('查看《用户服务协议》')
          .width('100%')
          .fontSize(15)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            this.openDoc(AppSettings.AGREEMENT_TITLE, AppSettings.AGREEMENT_URL);
          })
        Text('《隐私政策》说明本应用如何收集、使用与保护你的信息（日历、位置等）；《用户服务协议》说明使用本应用的权利与义务。两份文件随功能调整更新，最新版本以上述链接为准。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .width('100%')
      .align(Alignment.Top)
      .padding(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    // 沉浸式：背景延伸到状态栏/导航条区域（只扩绘制、不移动子组件）
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
