// entry/src/main/ets/common/SystemCalendarMirror.ets
// 出站镜像：把用户选中的 CalDAV 日历本写进「系统日历」中**本应用自己的日历账户**。
//
// 目的：本应用是 CalDAV 客户端，日程不进系统日历，导致小艺 / 桌面日历卡片 / 手表看到的是空的
//      （甚至给出"今天没有日程"的错误答案）。把选中的日历本镜像过去后，这些系统入口就能看到。
//
// 设计要点：
//  1. 每个选中的 DAV 日历本 → 系统日历中一个独立账户（displayName = "同步日历 · <日历本名>"），
//     这样每个本能有自己的颜色，避免"多个本挤一个颜色"的问题。
//     ✅ 2026-09-17 用户实测：**系统日历能显示应用写入的自定义颜色**（只有手动建本时才给固定色板）。
//  2. `Event.identifier` 存 `<bookId>|<uid>`（重复系列再加 `@<发生时刻>`）作为映射键，用于幂等更新与删除。
//     ⭐ 一律用稳定标识 **bookId**（由服务器 href 派生），绝不用于会变的 calKey
//     —— calKey 里的序号会因日历本重排而变，曾导致"重复账户 + 串本"（2026-09-19 事故）。
//     **只删除 identifier 命中我们格式的条目** —— 用户在系统日历里自己往这个账户加的日程不会被误删
//     （这也是后续做"系统日历 → CalDAV 回写"的输入来源）。✅ 用户实测确认不会被删。
//  3. 全天日程的时间语义差异：
//     - 本工程 LocalEvent：全天日程 endTime = 排他结束日前一毫秒（iCal 约定）
//     - Calendar Kit：全天日程 endTime = 当天 24:00
//     → 见 allDayEndTime()。⚠️ 比较时**不能逐毫秒比**：系统会把全天 endTime 归一化成
//       23:59:59.999 之类，导致"每次镜像都更新同一批、永不收敛" → 见 diffOf()。
//  4. **重复日程由我们自己按窗口展开后逐条写入**，绝不把 master + RRULE 交给系统日历去展开。
//     原因：Calendar Kit 的 RecurrenceRule 表达力很弱（BYDAY / BYMONTHDAY / BYMONTH / EXDATE 极易丢），
//     与 App 的 RruleUtil.expand 口径不一致 → 出现"App 里没有、系统日历里一堆"的幽灵重复日程
//     （2026-09-19 事故，用户实测）。展开一律用 **RruleUtil.expand**，与显示口径完全一致。
//     ⚠️ 本工程 `recurring` 的语义是"属于某个重复系列"（master 与 RECURRENCE-ID 覆盖行都是 true），
//     不是"展开实例"；对它们 identifier 统一加 `@<发生时刻>` 才唯一，否则同一 uid 的多条覆盖行互相覆盖。
//  5. **窗口镜像**：窗口 = 过去 1 年 ~ 未来 2 年（对齐到月边界），只写窗口内的发生；
//     窗口外的单点日程跳过（App 也不会显示）。注：RruleUtil.expand 自带 −40 天 / +1 天边界余量。
//  6. **防回灌**：系统日历备份进 CalDAV 的日程（uid 前缀 `syscal-`）不能再镜像回系统日历，
//     否则就是自我复制；备份目标本整体也不参与镜像。
//     ⭐ 备份目标一律用 **bookId** 记录与解析（`checkBackupTarget`）。老版本存的是 calKey，
//     用户「取消勾选」某个本后序号前移 → 目标会悄悄变成另一个本，把系统日历导进没选过的本；
//     现在解析不到就**直接关闭备份功能**并提示用户重选。
//
// ⚠️ 合规：WRITE_CALENDAR 只能在用户主动点击"开启镜像"开关时申请，严禁启动时申请。

import { common, abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { calendarManager } from '@kit.CalendarKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AccountStore, BookPalette, DavAccount } from './AccountStore';
import { EventDb, LocalEvent } from './EventDb';
import { IcsTime, IcsUtil } from './IcsUtil';
import { RruleUtil } from './RruleUtil';
import { LogUtil } from './LogUtil';
import { AppSettings } from './AppSettings';
import { MirrorSnapshot } from './MirrorSnapshot';

/** 一次镜像执行的统计 */
export class MirrorResult {
  books: number = 0;   // 处理的日历本数
  added: number = 0;
  updated: number = 0;
  deleted: number = 0;
  skipped: number = 0; // 重复实例 / 已删除 / 系统日历备份导入项 等跳过项
  failed: number = 0;
  // 诊断用
  totalRows: number = 0; // 本地库读到的总行数
  dupOcc: number = 0;    // 同一 (uid, 发生时刻) 重复、被合并掉的发生数（本地库冗余行导致）
  winOut: number = 0;    // 因"落在窗口外"被跳过的条数
  syscal: number = 0;    // 因 uid 前缀 syscal-（系统日历备份来的）被跳过的条数
  markDel: number = 0;   // 因已标记删除/无 uid 被跳过的条数
}

/** 一次孤儿账户清理的结果 */
export class PurgeResult {
  removed: number = 0;          // 成功删除的账户数
  failed: number = 0;           // 删除失败的账户数
  failedNames: string[] = [];   // 删除失败的账户名
  remaining: number = 0;        // 清理后仍然残留的镜像账户数
  remainingNames: string[] = [];
  detail: string[] = [];        // 账户清单诊断行（`#id [KEEP/MINE/other] name=… display=… type=…`）
}

export class SystemCalendarMirror {
  /** 镜像只需要读写"本应用创建的账户"，用普通级权限即可；WHOLE_CALENDAR 是 system_basic，拿不到也不需要 */
  private static readonly MIRROR_PERMISSIONS: Permissions[] = [
    'ohos.permission.READ_CALENDAR',
    'ohos.permission.WRITE_CALENDAR'
  ];
  /** 系统日历账户 name 前缀。name 是开发者定义且 readonly，必须稳定可复现才能找到已有账户 */
  private static readonly ACCOUNT_PREFIX: string = 'synccalendar.mirror.';
  /**
   * 系统日历账户 displayName 中「同步日历」字面量 —— **仅供"兜底识别"使用**。
   * ⚠️ 0.0.8 起 displayName 变为可切换（三种格式），本常量**不再用于生成名字**，
   *    只用于判断"这个名字是否含我们的归属标识"（格式 1/2 含、格式 3 不含）。
   */
  private static readonly DISPLAY_MARK: string = '同步日历';
  /** 旧版固定前缀（`同步日历 · `，半角点 U+00B7 带空格）——仅用于识别/迁移历史账户 */
  private static readonly LEGACY_DISPLAY_PREFIX: string = '同步日历 · ';
  private static readonly DAY: number = 86400000;
  /** getEvents() 显式指定返回字段：identifier 只在 API20+ 的默认字段里，写死更保险 */
  private static readonly QUERY_FIELDS: (keyof calendarManager.Event)[] = [
    'id', 'type', 'title', 'startTime', 'endTime', 'isAllDay',
    'description', 'location', 'identifier', 'reminderTime', 'recurrenceRule'
  ];
  /**
   * SystemCalendarImport 写入本地库的 uid 前缀（`syscal-<系统账户名>-<系统事件id>`）。
   * 这些日程**本来就是从系统日历导进来的**，再镜像回系统日历 = 自我复制，必须跳过。
   */
  private static readonly SYSCAL_UID_PREFIX: string = 'syscal-';
  /** 批量新增每批条数 */
  private static readonly CHUNK: number = 50;
  /**
   * ⭐ 单条重复日程最多展开多少条"发生"。
   * 我们自己按窗口展开（不再让系统日历展开），"每天重复 × 3 年"会有上千条，
   * 必须设上限防止把系统日历撑爆；达到上限会记日志。
   */
  private static readonly MAX_OCC: number = 500;

  /* ==================== 权限 ==================== */

  /** **只检查、绝不弹窗** —— 供界面判断状态（合规要求：不得在未主动操作时申请） */
  static async hasPermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId: number = info.appInfo.accessTokenId;
      for (const p of SystemCalendarMirror.MIRROR_PERMISSIONS) {
        const status = await atManager.checkAccessToken(tokenId, p);
        if (status !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return false;
        }
      }
      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * 申请镜像所需权限。
   * ⚠️ 只能在用户主动点击"开启镜像到系统日历"开关时调用（已授权则直接返回，不再弹窗）。
   */
  static async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    if (await SystemCalendarMirror.hasPermission()) {
      return true;
    }
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(
        context, SystemCalendarMirror.MIRROR_PERMISSIONS);
      for (const r of result.authResults) {
        if (r !== 0) {
          return false;
        }
      }
      return true;
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`镜像权限申请失败: ${e.code} - ${e.message}`);
      return false;
    }
  }

  /* ==================== 账户显示名（0.0.8 可切换） ==================== */

  /**
   * ⭐ 生成系统日历账户的 displayName。
   *
   * 三种格式（分隔符统一为**半角点 `·`（U+00B7）+ 无空格**，尽量短）：
   *   1 = `同步日历·<本名>`            —— 保留应用名
   *   2 = `同步日历·<账号>·<本名>`      —— 平板/大屏，信息最全
   *   3 = `<账号>·<本名>`  ★默认        —— 短、能区分账号
   *
   * ⚠️ **不提供"仅本名"**：用户原系统日历里可能有同名日历本，裸本名无法与之区分 → 有误删风险。
   *    每个镜像账户名**至少要带一个归属标识**（`同步日历` / `账号名` / 两者）。
   *
   * ⚠️ displayName 上限 64 字符（系统限制）→ 超长时截断，避免 createCalendar 失败。
   */
  static displayNameFor(ref: BookRef, format: number): string {
    const sep: string = '·';
    const book: string = ref.name !== '' ? ref.name : '日历本';
    const acc: string = ref.accountName !== '' ? ref.accountName : '账号';
    let out: string;
    if (format === 1) {
      out = `${SystemCalendarMirror.DISPLAY_MARK}${sep}${book}`;
    } else if (format === 2) {
      out = `${SystemCalendarMirror.DISPLAY_MARK}${sep}${acc}${sep}${book}`;
    } else {
      out = `${acc}${sep}${book}`;
    }
    // displayName 系统上限 64 字符：超长截断（保留前面的归属标识，它比本名更重要）
    if (out.length > 64) {
      out = out.substring(0, 64);
    }
    return out;
  }

  /** 某个 displayName 是否**含我们的归属标识**（用于兜底识别；格式 1/2 含、格式 3 不含） */
  static displayNameHasMark(display: string): boolean {
    return display.startsWith(SystemCalendarMirror.DISPLAY_MARK);
  }

  /** 某个 displayName 是否是**旧版固定格式**（`同步日历 · xxx`，用于提示用户可更换） */
  static isLegacyDisplayName(display: string): boolean {
    return display.startsWith(SystemCalendarMirror.LEGACY_DISPLAY_PREFIX);
  }

  /**
   * 是否还存在"旧格式"镜像账户 —— 设置页据此给出"可更换显示名称"的弱提示（只读，不修改）。
   * 判据：`name` 是我们的前缀 + `displayName` 是旧格式。
   */
  static async hasLegacyDisplayName(context: common.Context): Promise<boolean> {
    try {
      const cm: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
      const all: calendarManager.Calendar[] = await cm.getAllCalendars();
      for (const cal of all) {
        const acc: calendarManager.CalendarAccount = cal.getAccount();
        if (acc.name.startsWith(SystemCalendarMirror.ACCOUNT_PREFIX) &&
          SystemCalendarMirror.isLegacyDisplayName(acc.displayName ?? '')) {
          return true;
        }
      }
      return false;
    } catch (err) {
      return false;
    }
  }

  /* ==================== 主入口 ==================== */

  /**
   * ⚠️ **已废弃**：账户名必须以 BookRef.sysAccountName（由 href 派生的稳定 bookId）为准。
   * 保留仅为兼容引用；用 calKey 拼账户名会导致重复账户与串本（09-19 事故）。
   */
  static accountNameOf(calKey: string): string {
    return SystemCalendarMirror.ACCOUNT_PREFIX + calKey;
  }

  /**
   * 某个系统日历账户是不是**本应用镜像出去的**？
   * ⚠️ `SystemCalendarImport`（系统日历 → 备份本）必须跳过这些账户：
   *    它们的 type 也是 LOCAL，但内容是我们从 CalDAV 写进去的，
   *    再导进备份本就会让同一条日程在服务器里出现两份。
   */
  static isMirrorAccountName(name: string): boolean {
    return name.startsWith(SystemCalendarMirror.ACCOUNT_PREFIX);
  }

  /**
   * ⭐⭐ 取"**确实已经镜像到系统日历**"的日历本 calKey 集合（按镜像账户的**真实存在性**判定）。
   *
   * 与"用户勾选了要镜像的本"不同 —— 后者只是**意图**，本可能还没被真正写进系统日历
   * （如刚勾选但没点「立即执行镜像」、或根本没开镜像开关）。
   * 若按"意图"跳过 App 提醒，而系统日历里其实还没有 → **两边都不提醒 = 漏提醒**。
   * 故这里只认**镜像账户真实存在**这一条。
   *
   * ⚠️ 返回**空集**＝不跳过任何本（读不到账户时保守处理，宁可多提醒）。
   * ⚠️ 未开启镜像开关时直接返回空集（省一次系统查询）。
   */
  static async mirroredCalKeys(context: common.Context): Promise<Set<string>> {
    const out: Set<string> = new Set<string>();
    try {
      if (!await AppSettings.getMirrorEnabled(context)) {
        return out; // 未开启镜像 → 没有任何本由系统日历负责
      }
      if (!await SystemCalendarMirror.hasPermission()) {
        return out; // 无权限 → 系统日历里不可能有我们的条目
      }
      const cm: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
      const all: calendarManager.Calendar[] = [];
      const cals: calendarManager.Calendar[] = await cm.getAllCalendars();
      for (const c of cals) {
        all.push(c);
      }
      // 存在镜像账户 → 其 bookId 对应的本由系统日历负责
      const presentBookIds: Set<string> = new Set<string>();
      for (const c of all) {
        const name: string = c.getAccount().name;
        if (name.startsWith(SystemCalendarMirror.ACCOUNT_PREFIX)) {
          presentBookIds.add(name.substring(SystemCalendarMirror.ACCOUNT_PREFIX.length));
        }
      }
      if (presentBookIds.size === 0) {
        return out;
      }
      // bookId → calKey（从当前账号配置解析）
      const refs: BookRef[] = await SystemCalendarMirror.listBooks(context);
      for (const r of refs) {
        if (presentBookIds.has(r.bookId) && r.calKey !== '') {
          out.add(r.calKey);
        }
      }
    } catch (err) {
      LogUtil.write(`判定"已镜像本"失败（按未镜像处理）: ${(err as BusinessError).message}`);
    }
    return out;
  }

  /* ==================== 账户身份判定（0.0.8） ==================== */

  /**
   * 取当前 App 里真实存在的账号 id 集合（用于识别"我们的镜像账户"的身份）。
   * ⚠️ 读取失败返回**空集**，调用方据此**跳过清理**（宁可不清，也不误删）。
   */
  private static async currentAccountIds(context: common.Context): Promise<Set<string>> {
    const ids: Set<string> = new Set<string>();
    try {
      const accounts: DavAccount[] = await AccountStore.loadAll(context);
      for (const a of accounts) {
        if (a.id !== '') {
          ids.add(a.id);
        }
      }
    } catch (err) {
      LogUtil.write(`读取账号列表失败（清理将保守跳过）: ${(err as BusinessError).message}`);
    }
    return ids;
  }

  /**
   * ⭐ 某个系统日历账户是不是**本应用镜像出去的**（身份级判定）。
   *
   * 两道闸：
   *   ① `name` 以 `synccalendar.mirror.` 开头 —— 挡掉所有"别人家的账户"；
   *   ② 从 `name` 切出 `accId`（`<accId>-<href哈希>`，取**最后一个** `-` 之前的部分），
   *      并确认它在当前账号库里 —— 精准识别"账号已删的孤儿"，**与显示名完全解耦**。
   *
   * ⚠️ 为什么不能只靠 displayName：显示名现在**可切换**（格式 3 不含"同步日历"），
   *    且格式 3（`账号·本名`）可能与别的 App 的账户同名 → 只按名字判定会**误删用户数据**。
   *
   * @param knownIds        当前真实账号 id 集合（**空集 = 读不到账号 → 一律返回 false**，保守）
   * @param allowDisplayMark 是否允许"仅 displayName 含归属标识"兜底（**仅格式 1/2 可用**）
   */
  static isOurMirrorAccount(
    name: string,
    display: string,
    knownIds: Set<string>,
    allowDisplayMark: boolean
  ): boolean {
    if (knownIds.size === 0) {
      return false; // 安全阀：拿不到账号身份就不认为任何账户是我们的
    }
    if (name.startsWith(SystemCalendarMirror.ACCOUNT_PREFIX)) {
      // ① name 前缀命中 → 切出 accId 做身份校验
      const bookId: string = name.substring(SystemCalendarMirror.ACCOUNT_PREFIX.length);
      const cut: number = bookId.lastIndexOf('-');
      const accId: string = cut > 0 ? bookId.substring(0, cut) : bookId;
      // ② accId 在库里 → 确认是我们的；
      //    不在库里 → 视作"账号已删的孤儿/历史脏数据"（仍需清理）→ 也返回 true
      if (knownIds.has(accId)) {
        return true;
      }
      LogUtil.write(`镜像账户 name=${name} 的 accId=${accId} 不在账号库 → 按孤儿处理`);
      return true;
    }
    // ③ name 不像我们 → 仅当 displayName 带归属标识、且允许兜底时，才认为是我们的
    return allowDisplayMark && SystemCalendarMirror.displayNameHasMark(display);
  }

  /* ==================== 孤儿账户清理 ==================== */

  /**
   * ⭐ 清理孤儿镜像账户：凡是"我们建的"但不属于本次选中本的，全部删掉。
   *
   * ⚠️ 关键教训（09-19 第二次）：**每个账户必须独立 try/catch**。
   *    旧写法把整段循环包在一个 try 里，任意一个 `deleteCalendar` 抛错就会跳出整个 try，
   *    后面所有账户都不再处理 → 表现为"只删掉一部分、还有残留"。
   *
   * 降级策略：直接删账户失败 → 先 `deleteEvents` 清空其中所有日程，再删一次。
   *
   * @param validNames 本次要保留的账户名集合（当前选中本的 sysAccountName）
   * @param aggressive 是否连"只有 displayName 命中、name 被系统改写"的账户一起清（历史脏数据兜底）
   */
  static async purgeOrphans(
    context: common.Context,
    cm: calendarManager.CalendarManager,
    validNames: Set<string>,
    aggressive: boolean
  ): Promise<PurgeResult> {
    const out: PurgeResult = new PurgeResult();
    let all: calendarManager.Calendar[] = [];
    try {
      all = await cm.getAllCalendars();
    } catch (err) {
      LogUtil.write(`清理镜像账户失败：读不到系统日历账户列表 ${(err as BusinessError).message}`);
      return out;
    }
    // ⭐ 0.0.8 身份校验：拿"当前真实账号 id"当判据 —— 读不到就保守跳过，绝不误删
    const knownIds: Set<string> = await SystemCalendarMirror.currentAccountIds(context);
    if (knownIds.size === 0) {
      LogUtil.write('⚠️ 清理跳过：读不到任何账号 id（安全阀，避免误删）');
      return out;
    }
    // displayName 兜底**仅格式 1/2 可用**（含"同步日历"，可与他人区分）；格式 3 不参与兜底
    const fmt: number = await AppSettings.getMirrorDisplayFormat(context);
    const allowDisplayMark: boolean = aggressive && (fmt === 1 || fmt === 2);
    // ① 诊断：把**全部**账户列一遍（不只是我们的），才能看出残留账户到底是什么名字
    for (const cal of all) {
      out.detail.push(SystemCalendarMirror.describeCal(cal, validNames, allowDisplayMark));
    }
    LogUtil.write(`系统日历账户清单（共 ${all.length}）：`);
    for (const line of out.detail) {
      LogUtil.write(`  ${line}`);
    }

    // ② 逐个清理
    for (const cal of all) {
      const acc: calendarManager.CalendarAccount = cal.getAccount();
      const name: string = acc.name;
      const display: string = acc.displayName ?? '';
      const mineByName: boolean = name.startsWith(SystemCalendarMirror.ACCOUNT_PREFIX);
      // ⭐ 身份级判定：name 前缀 → 切出 accId → 必须匹配当前真实账号（详见 isOurMirrorAccount）
      if (!SystemCalendarMirror.isOurMirrorAccount(name, display, knownIds, allowDisplayMark)) {
        continue; // 身份不符 → 绝不碰（可能用户原有的日历本 / 别的 App 建的）
      }
      if (validNames.has(name)) {
        continue; // 本次还要用，保留
      }
      const bucket: string = mineByName
        ? name.substring(SystemCalendarMirror.ACCOUNT_PREFIX.length)
        : name;
      try {
        await cm.deleteCalendar(cal);
        out.removed++;
        LogUtil.write(`已删除镜像账户: id=${cal.id} name=${name} display=${display}`);
      } catch (err) {
        const e1 = err as BusinessError;
        LogUtil.write(`删除镜像账户失败(1次) id=${cal.id} name=${name}: ${e1.code ?? ''} ${e1.message}`);
        // 降级：先清空该账户下所有日程，再删一次
        try {
          const evs: calendarManager.Event[] = await cal.getEvents();
          const ids: number[] = [];
          for (const ev of evs) {
            if (ev.id !== undefined) {
              ids.push(ev.id);
            }
          }
          if (ids.length > 0) {
            await cal.deleteEvents(ids);
          }
        } catch (err2) {
          LogUtil.write(`清空镜像账户日程失败 id=${cal.id}: ${(err2 as BusinessError).message}`);
        }
        try {
          await cm.deleteCalendar(cal);
          out.removed++;
          LogUtil.write(`已删除镜像账户(清空后重试成功): id=${cal.id} name=${name}`);
        } catch (err3) {
          const e3 = err3 as BusinessError;
          out.failed++;
          out.failedNames.push(name);
          LogUtil.write(`删除镜像账户失败(最终) id=${cal.id} name=${name}: ${e3.code ?? ''} ${e3.message}`);
        }
      }
      await MirrorSnapshot.removeByCalKey(context, bucket);
    }

    // ③ 复查：清理后还剩几个"我们的"账户
    try {
      const after: calendarManager.Calendar[] = await cm.getAllCalendars();
      for (const cal of after) {
        const acc: calendarManager.CalendarAccount = cal.getAccount();
        if (acc.name.startsWith(SystemCalendarMirror.ACCOUNT_PREFIX) &&
          !validNames.has(acc.name)) {
          out.remaining++;
          out.remainingNames.push(`id=${cal.id} name=${acc.name}`);
        }
      }
    } catch (err) {
      // 复查失败不影响结果
    }
    return out;
  }

  /**
   * ⭐ 删除指定的若干镜像账户（按 bookId 精确定位，用于"一键重命名"前清空旧账户）。
   *
   * ⚠️ 调用方**必须**已先回读（`MirrorInbound.reconcile`），否则会丢掉用户手动加的日程。
   * ⚠️ 只需 `name` 精确匹配即可 —— 不需要 displayName 判定（bookId 是身份，名字已无关）。
   * 每个账户独立 try/catch + "清空日程后重试"降级，与 purgeOrphans 同策略。
   */
  static async removeAccountsByBookIds(context: common.Context, bookIds: string[]): Promise<number> {
    if (bookIds.length === 0) {
      return 0;
    }
    const cm: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
    const targets: Set<string> = new Set<string>();
    for (const b of bookIds) {
      targets.add(SystemCalendarMirror.ACCOUNT_PREFIX + b);
    }
    let removed: number = 0;
    let all: calendarManager.Calendar[] = [];
    try {
      all = await cm.getAllCalendars();
    } catch (err) {
      LogUtil.write(`重命名-删除旧账户失败：读不到账户列表 ${(err as BusinessError).message}`);
      return 0;
    }
    for (const cal of all) {
      const acc: calendarManager.CalendarAccount = cal.getAccount();
      const name: string = acc.name;
      if (!targets.has(name)) {
        continue;
      }
      try {
        await cm.deleteCalendar(cal);
        removed++;
        LogUtil.write(`重命名：已删除旧账户 id=${cal.id} name=${name}`);
      } catch (err) {
        const e1 = err as BusinessError;
        LogUtil.write(`重命名：删除账户失败，尝试清空后重试 name=${name}: ${e1.message}`);
        try {
          const evs: calendarManager.Event[] = await SystemCalendarMirror.queryEvents(cal);
          const ids: number[] = [];
          for (const ev of evs) {
            if (ev.id !== undefined) {
              ids.push(ev.id);
            }
          }
          if (ids.length > 0) {
            await cal.deleteEvents(ids);
          }
          await cm.deleteCalendar(cal);
          removed++;
          LogUtil.write(`重命名：清空后删除成功 name=${name}`);
        } catch (err2) {
          LogUtil.write(`重命名：删除账户最终失败 name=${name}: ${(err2 as BusinessError).message}`);
        }
      }
      // 快照按键是 bookId（与账户名无关），账户删了但快照应保留 → 重建后仍幂等，故不动快照
    }
    return removed;
  }

  /** 一个账户的诊断行：`#id [KEEP/MINE/other] name=… display=… type=…` */
  private static describeCal(
    cal: calendarManager.Calendar,
    validNames: Set<string>,
    allowDisplayMark: boolean
  ): string {
    const acc: calendarManager.CalendarAccount = cal.getAccount();
    const name: string = acc.name;
    const display: string = acc.displayName ?? '';
    const mineByName: boolean = name.startsWith(SystemCalendarMirror.ACCOUNT_PREFIX);
    const mineByDisplay: boolean = allowDisplayMark &&
      display.startsWith(SystemCalendarMirror.DISPLAY_MARK);
    let tag: string = 'other ';
    if (mineByName || mineByDisplay) {
      tag = validNames.has(name) ? 'KEEP  ' : 'MINE  ';
    }
    return `#${cal.id} [${tag}] name=${name} display=${display} type=${acc.type}`;
  }

  /**
   * 供设置页「清理残留镜像账户」按钮调用：
   * 列出全部账户到日志，并把"我们建的、但不属于当前选中本"的账户全部清掉（含 displayName 兜底）。
   */
  static async forceCleanup(context: common.Context): Promise<PurgeResult> {
    if (!await SystemCalendarMirror.hasPermission()) {
      throw new Error('未获得系统日历读写权限');
    }
    const cm: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
    const refs: BookRef[] = await SystemCalendarMirror.selectedBookRefs(context);
    const valid: Set<string> = new Set<string>();
    for (const ref of refs) {
      valid.add(ref.sysAccountName);
    }
    return SystemCalendarMirror.purgeOrphans(context, cm, valid, true);
  }

  /** 执行一次性镜像（幂等，可重复调用；**全量**，不设时间窗口） */
  static async syncNow(context: common.Context): Promise<MirrorResult> {
    const res: MirrorResult = new MirrorResult();
    if (!await SystemCalendarMirror.hasPermission()) {
      LogUtil.write('镜像中止：未获得系统日历读写权限');
      throw new Error('未获得系统日历读写权限');
    }
    // ⭐ 选中项一律走**稳定标识** bookId（由服务器 href 派生），并顺带迁移历史 calKey 选中项
    const refs: BookRef[] = await SystemCalendarMirror.selectedBookRefs(context);
    // ⭐ 兜底：无论有没有选中本，都顺手清掉"账号已删除"的孤儿镜像账户。
    //    否则"删掉一个账号后系统日历里还留着它的日历本"永远不会被自动修掉
    //    （旧代码在这里 return 之前根本不做清理，这正是本次要修的 bug）。
    try {
      await SystemCalendarMirror.purgeOrphanAccountMirrors(context);
    } catch (err) {
      // 兜底清理失败不影响正常镜像
    }
    if (refs.length === 0) {
      LogUtil.write('镜像中止：未选择要镜像的日历本（或全部是备份目标本）');
      return res;
    }
    const cm: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);

    // ⭐ 清理孤儿账户：系统日历里凡是本应用镜像出去、但不属于本次选中本的，全删。
    //    这是清理历史脏数据（旧版用 calKey 建的账户）的关键一步，否则重复账户会一直堆积。
    const valid: Set<string> = new Set<string>();
    for (const ref of refs) {
      valid.add(ref.sysAccountName);
    }
    const purge: PurgeResult = await SystemCalendarMirror.purgeOrphans(context, cm, valid, false);
    LogUtil.write(
      `镜像前清理：删除 ${purge.removed} 个孤儿镜像账户，失败 ${purge.failed} 个，清理后仍剩余 ${purge.remaining} 个`);

    const winStart: number = SystemCalendarMirror.windowStart();
    const winEnd: number = SystemCalendarMirror.windowEnd();
    // ⭐ 0.0.8：读取用户所选的显示名格式（仅影响**新建**账户的名字；已有账户不在此处改名）
    const format: number = await AppSettings.getMirrorDisplayFormat(context);
    const plans: Map<string, MirrorOcc[]> = new Map<string, MirrorOcc[]>();
    for (const ref of refs) {
      try {
        const plan: MirrorOcc[] =
          await SystemCalendarMirror.planFor(context, ref, winStart, winEnd, res);
        plans.set(ref.bookId, plan);
        await SystemCalendarMirror.syncBook(context, cm, ref, plan, winStart, winEnd, res, format);
        res.books++;
      } catch (err) {
        const e = err as BusinessError;
        res.failed++;
        LogUtil.write(`镜像失败 bookId=${ref.bookId}: ${e.code ?? ''} ${e.message}`);
      }
    }
    // ⭐ 每次镜像后自动导出一份对照诊断，便于"系统日历里有、App 里没有"这类问题逐条比对
    await SystemCalendarMirror.dumpDiagnosis(context, cm, refs, plans, winStart, winEnd);
    LogUtil.write(
      `镜像完成：本=${res.books} 新增=${res.added} 更新=${res.updated} 删除=${res.deleted} 失败=${res.failed} ` +
      `跳过=${res.skipped}（窗口外单点=${res.winOut} 已删除=${res.markDel} 系统备份=${res.syscal}）` +
      ` 本地总行=${res.totalRows} 重复发生合并=${res.dupOcc}`);
    return res;
  }

  /** 清空镜像：删除本应用创建的所有镜像账户（关闭开关时调用） */
  static async removeAll(context: common.Context): Promise<number> {
    if (!await SystemCalendarMirror.hasPermission()) {
      return 0;
    }
    let n: number = 0;
    try {
      const cm: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
      // ⭐ 复用 purgeOrphans：保留集合为空 = 全删；aggressive = 连 displayName 命中的历史脏账户一起清
      const purge: PurgeResult =
        await SystemCalendarMirror.purgeOrphans(context, cm, new Set<string>(), true);
      await MirrorSnapshot.clearAll(context); // 快照整体清空，顺带清掉历史 calKey 键的残留
      n = purge.removed;
      LogUtil.write(
        `镜像已清除：删除 ${purge.removed} 个镜像账户，失败 ${purge.failed} 个，仍剩余 ${purge.remaining} 个`);
      if (purge.failed > 0) {
        LogUtil.write(`删除失败的账户：${purge.failedNames.join(' , ')}`);
      }
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`清除镜像失败: ${e.message}`);
    }
    return n;
  }

  /**
   * 取消单个日历本的镜像：删除它对应的系统日历账户（幂等；不存在则什么也不做）。
   * ⚠️ 参数必须是 **bookId**（稳定标识），不是 calKey。
   */
  static async removeById(context: common.Context, bookId: string): Promise<boolean> {
    if (!await SystemCalendarMirror.hasPermission()) {
      return false;
    }
    const accountName: string = SystemCalendarMirror.ACCOUNT_PREFIX + bookId;
    try {
      const cm: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
      const calendars: calendarManager.Calendar[] = await cm.getAllCalendars();
      for (const cal of calendars) {
        if (cal.getAccount().name === accountName) {
          await cm.deleteCalendar(cal);
          await MirrorSnapshot.removeByCalKey(context, bookId);
          LogUtil.write(`已删除镜像账户: ${accountName}`);
          return true;
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`删除镜像账户失败 ${accountName}: ${e.message}`);
    }
    return false;
  }

  /** 兼容旧调用：传 calKey 也能删（内部解析成 bookId，两种账户名都清） */
  static async removeBook(context: common.Context, calKey: string): Promise<boolean> {
    const refs: Map<string, BookRef> = await SystemCalendarMirror.resolveBookRefs(context, [calKey]);
    const ref: BookRef | undefined = refs.get(calKey);
    const bookId: string = ref !== undefined ? ref.bookId : calKey;
    return SystemCalendarMirror.removeById(context, bookId);
  }

  /**
   * ⭐ 删除**某一个 DAV 账号**名下的全部镜像账户（在 App 里删除该账号时调用）。
   *
   * 背景（用户反馈）：删掉一个 CalDAV 账号后，之前镜像进系统日历的那些"日历本"
   * 仍然留在系统日历里（幽灵账户 + 幽灵日程）。旧代码只清了账号配置与本地库，
   * 完全没碰系统日历侧；而自动兜底（syncNow 里的 purgeOrphans）在"解析不到任何选中本"时
   * **会提前 return**，所以删完账号后根本不会触发兜底清理。
   *
   * ⭐ **绝不按日历本显示名匹配**：镜像账户名是 `synccalendar.mirror.<bookId>`，
   *    而 bookId = `<accId>-<href哈希>` 天然带账号前缀。因此这里只按
   *    `synccalendar.mirror.<accId>-` 前缀匹配 —— 即使**不同账号下有同名日历本**
   *    （比如两个账号各有一个「工作」），它们的 bookId 不同、账户名也不同，绝不会删错。
   *
   * 幂等；未授权 / 无匹配时返回 0。每个账户独立 try/catch，一个失败不影响其它。
   *
   * @returns 成功删除的镜像账户数
   */
  static async removeByAccount(context: common.Context, accId: string): Promise<number> {
    if (accId === '' || !await SystemCalendarMirror.hasPermission()) {
      return 0;
    }
    // ⭐ 账户名前缀 = 公共前缀 + accId + '-'（bookId 里的分隔符）。
    //    带尾随 '-' 才不会把 accId「123」错配到 accId「1234」的账户上。
    //    同时兼容**历史**账户名（旧版用 calKey 做桶 → `synccalendar.mirror.<accId>_<序号>`），
    //    同样带尾随 '_' 分隔符，宁可多清一批脏账户，也不按显示名乱删。
    const prefix: string = `${SystemCalendarMirror.ACCOUNT_PREFIX}${accId}-`;
    const legacyPrefix: string = `${SystemCalendarMirror.ACCOUNT_PREFIX}${accId}_`;
    let removed: number = 0;
    const buckets: string[] = [];
    try {
      const cm: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
      const all: calendarManager.Calendar[] = await cm.getAllCalendars();
      for (const cal of all) {
        const name: string = cal.getAccount().name;
        if (!name.startsWith(prefix) && !name.startsWith(legacyPrefix)) {
          continue; // 不属于本账号（含其它账号的同名日历本）→ 绝不动
        }
        const bucket: string = name.substring(SystemCalendarMirror.ACCOUNT_PREFIX.length);
        try {
          await cm.deleteCalendar(cal);
          removed++;
          buckets.push(bucket);
          LogUtil.write(`删除账号 ${accId}：已删除镜像账户 id=${cal.id} name=${name}`);
        } catch (err) {
          const e1 = err as BusinessError;
          LogUtil.write(`删除账号 ${accId}：删除镜像账户失败(重试) id=${cal.id} name=${name}: ${e1.message}`);
          // 降级：先清空账户内全部日程，再删一次（与 purgeOrphans 同策略）
          try {
            const evs: calendarManager.Event[] = await cal.getEvents();
            const ids: number[] = [];
            for (const ev of evs) {
              if (ev.id !== undefined) {
                ids.push(ev.id);
              }
            }
            if (ids.length > 0) {
              await cal.deleteEvents(ids);
            }
          } catch (err2) {
            LogUtil.write(`删除账号 ${accId}：清空镜像账户日程失败 id=${cal.id}: ${(err2 as BusinessError).message}`);
          }
          try {
            await cm.deleteCalendar(cal);
            removed++;
            buckets.push(bucket);
            LogUtil.write(`删除账号 ${accId}：已删除镜像账户(清空后重试成功) id=${cal.id} name=${name}`);
          } catch (err3) {
            LogUtil.write(`删除账号 ${accId}：镜像账户删除失败(最终) id=${cal.id} name=${name}: ${(err3 as BusinessError).message}`);
          }
        }
      }
    } catch (err) {
      LogUtil.write(`删除账号 ${accId}：读取系统日历账户列表失败 ${(err as BusinessError).message}`);
    }
    // 清掉这些本在镜像快照里的残留（bucket = bookId）
    for (const b of buckets) {
      await MirrorSnapshot.removeByCalKey(context, b);
    }
    // 清掉"镜像选中项"里属于本账号的条目（防止残留脏 bookId 干扰下次选择/迁移）。
    // ⚠️ 用 `${accId}-` / `${accId}_` 前缀过滤（同样带分隔符，避免误伤相似 accId）。
    try {
      const ids: string[] = await AppSettings.getMirrorBookIds(context);
      const kept: string[] = ids.filter((id: string): boolean => !id.startsWith(`${accId}-`));
      if (kept.length !== ids.length) {
        await AppSettings.setMirrorBookIds(context, kept);
      }
      const legacy: string[] = await AppSettings.getMirrorKeys(context);
      const keptLegacy: string[] = legacy.filter((k: string): boolean => !k.startsWith(`${accId}_`));
      if (keptLegacy.length !== legacy.length) {
        await AppSettings.setMirrorKeys(context, keptLegacy);
      }
    } catch (err) {
      // 设置清理失败不影响账户删除结果，下次同步会再兜底
    }
    LogUtil.write(`删除账号 ${accId}：系统日历镜像清理完成，共删除 ${removed} 个镜像账户`);
    return removed;
  }

  /**
   * ⭐ 兜底：清理"账号已不存在"的孤儿镜像账户（同步时调用，防止删除路径万一漏掉）。
   *
   * ⚠️ **安全阀**：当前账号列表为空时**直接跳过** —— 无法区分"用户删光了账号"与
   *    "账号存储临时读失败返回空"，后者若照常清理会把所有镜像账户误删。
   *    "删光账号"这种场景已由 `removeByAccount` / 重置账号库两条显式路径覆盖。
   * 只要还剩至少一个账号，就只清"accId 前缀不在当前账号集合里"的那些 —— 精准、不会误伤。
   *
   * @returns 删除的账户数
   */
  static async purgeOrphanAccountMirrors(context: common.Context): Promise<number> {
    if (!await SystemCalendarMirror.hasPermission()) {
      return 0;
    }
    let accounts: DavAccount[] = [];
    try {
      accounts = await AccountStore.loadAll(context);
    } catch (err) {
      return 0; // 读失败一律不动
    }
    if (accounts.length === 0) {
      return 0; // 安全阀：见注释
    }
    const validAccIds: Set<string> = new Set<string>();
    for (const a of accounts) {
      validAccIds.add(a.id);
    }
    let removed: number = 0;
    try {
      const cm: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
      const all: calendarManager.Calendar[] = await cm.getAllCalendars();
      for (const cal of all) {
        const name: string = cal.getAccount().name;
        if (!name.startsWith(SystemCalendarMirror.ACCOUNT_PREFIX)) {
          continue;
        }
        const bucket: string = name.substring(SystemCalendarMirror.ACCOUNT_PREFIX.length);
        // bucket 形如 `<accId>-<hash>`；也兼容历史 `<accId>_<序号>`
        const dash: number = bucket.indexOf('-');
        const under: number = bucket.indexOf('_');
        let sep: number = -1;
        if (dash >= 0 && under >= 0) {
          sep = Math.min(dash, under);
        } else {
          sep = dash >= 0 ? dash : under;
        }
        if (sep <= 0) {
          continue; // 解析不出 accId → 不动（宁可留，不误删）
        }
        const accId: string = bucket.substring(0, sep);
        if (validAccIds.has(accId)) {
          continue;
        }
        try {
          await cm.deleteCalendar(cal);
          removed++;
          LogUtil.write(`兜底清理孤儿镜像账户(账号 ${accId} 已删除) id=${cal.id} name=${name}`);
        } catch (err) {
          LogUtil.write(`兜底删除孤儿镜像账户失败 id=${cal.id} name=${name}: ${(err as BusinessError).message}`);
        }
        await MirrorSnapshot.removeByCalKey(context, bucket);
      }
    } catch (err) {
      LogUtil.write(`兜底清理孤儿镜像账户：读取系统日历账户失败 ${(err as BusinessError).message}`);
    }
    if (removed > 0) {
      LogUtil.write(`兜底清理孤儿镜像账户完成：删除 ${removed} 个`);
    }
    return removed;
  }

  /* ==================== 单个日历本 ==================== */

  /**
   * ⭐ 算出"某个日历本在窗口内应该有哪些发生" —— **唯一的口径来源**。
   * 实际写入（syncBook）与诊断导出（dumpDiagnosis）都用它，保证诊断看到的就是真正写进去的。
   */
  private static async planFor(
    context: common.Context,
    ref: BookRef,
    winStart: number,
    winEnd: number,
    res: MirrorResult
  ): Promise<MirrorOcc[]> {
    const calKey: string = ref.calKey;
    const all: LocalEvent[] = await EventDb.queryByCalKey(context, calKey, 'event');
    res.totalRows += all.length;
    const seen: Set<string> = new Set<string>();

    // RECURRENCE-ID 覆盖行（对某一次发生的单独修改）：自己单独成条，
    // 同时让主事件在展开时跳过对应发生，避免同一次发生出现两条（口径同 CalendarDataService）。
    const overrideKeys: Set<string> = new Set<string>();
    for (const e of all) {
      if (!e.deleted && e.rrule === '' && e.recurring) {
        overrideKeys.add(EventDb.overrideKey(e.calKey, e.uid, e.recurrenceId, e.startTime));
      }
    }

    const out: MirrorOcc[] = [];
    for (const e of all) {
      if (e.deleted || e.uid === '') {
        res.skipped++;
        res.markDel++;
        continue;
      }
      // 防回灌：来自系统日历备份的日程不再写回系统日历
      if (e.uid.startsWith(SystemCalendarMirror.SYSCAL_UID_PREFIX)) {
        res.skipped++;
        res.syscal++;
        continue;
      }
      const dur: number = Math.max(0, e.endTime - e.startTime);
      let times: number[] = [];
      if (e.rrule !== '') {
        const exNums: number[] = SystemCalendarMirror.exdateNums(e.exdate);
        const occs: number[] = RruleUtil.expand(
          e.rrule, e.startTime, winStart, winEnd, exNums, SystemCalendarMirror.MAX_OCC);
        if (occs.length >= SystemCalendarMirror.MAX_OCC) {
          LogUtil.write(`⚠️ 重复日程展开达上限 ${SystemCalendarMirror.MAX_OCC} 条：${e.title} [${e.rrule}]`);
        }
        times = occs.filter((occ: number): boolean =>
          !overrideKeys.has(EventDb.overrideKey(e.calKey, e.uid, 0, occ)));
      } else if (e.startTime >= winStart && e.startTime <= winEnd) {
        times = [e.startTime];
      } else {
        res.skipped++; // 窗口外的单点日程 → 不写（App 里也不显示）
        res.winOut++;
        continue;
      }
      for (const t of times) {
        const o: MirrorOcc = new MirrorOcc();
        // ⭐ 凡是"重复系列"里的（master 的每次发生、以及 RECURRENCE-ID 覆盖行）
        //    都要带上自己的发生时刻，否则同一 uid 的多条覆盖行会挤在同一个 identifier 上互相覆盖。
        //    （实测：轻舟本计划 984 条、实际只写出 975 条，就是这么丢的）
        o.identifier = e.recurring
          ? `${ref.bookId}|${e.uid}@${t}`
          : `${ref.bookId}|${e.uid}`;
        if (seen.has(o.identifier)) {
          // 同一 (uid, 发生时刻) 出现两次（本地库冗余行）→ 系统日历里同一 identifier 只能存一条，
          // 明确跳过并计数；否则会出现"计划 984 条、实际只写出 983 条"的口径差。
          res.dupOcc++;
          continue;
        }
        seen.add(o.identifier);
        o.start = t;
        o.end = t + dur;
        o.isAllDay = e.isAllDay;
        o.title = e.title;
        o.src = e;
        out.push(o);
      }
    }
    return out;
  }

  private static async syncBook(
    context: common.Context,
    cm: calendarManager.CalendarManager,
    ref: BookRef,
    plan: MirrorOcc[],
    winStart: number,
    winEnd: number,
    res: MirrorResult,
    format: number
  ): Promise<void> {
    // ⭐ 账户名与 identifier 一律用 **bookId**（由 href 派生、稳定），绝不用 calKey
    const cal: calendarManager.Calendar =
      await SystemCalendarMirror.ensureCalendar(cm, ref.sysAccountName, ref, format);

    // 现有镜像条目：identifier -> Event
    const existing: Map<string, calendarManager.Event> = new Map<string, calendarManager.Event>();
    const sysEvents: calendarManager.Event[] = await SystemCalendarMirror.queryEvents(cal);
    for (const ev of sysEvents) {
      const id: string = ev.identifier ?? '';
      if (id === '' || ev.id === undefined) {
        continue;
      }
      existing.set(id, ev);
    }

    // 期望存在的条目
    const want: Set<string> = new Set<string>();
    const toAdd: calendarManager.Event[] = [];
    let logged: number = 0;
    for (const occ of plan) {
      want.add(occ.identifier);
      const desired: calendarManager.Event =
        SystemCalendarMirror.toSystemEvent(occ.src, occ.identifier, occ.start, occ.end);
      const cur: calendarManager.Event | undefined = existing.get(occ.identifier);
      if (cur === undefined) {
        toAdd.push(desired);
        continue;
      }
      const diff: string = SystemCalendarMirror.diffOf(cur, desired);
      if (diff !== '') {
        desired.id = cur.id;
        await cal.updateEvent(desired);
        res.updated++;
        if (logged < 5) { // 只记前 5 条，避免刷屏
          LogUtil.write(`镜像更新[${ref.name}] ${occ.identifier}: 差异=${diff}`);
          logged++;
        }
      }
    }

    if (toAdd.length > 0) {
      await SystemCalendarMirror.addInChunks(cal, toAdd, res);
    }

    // 删除：本地已没有，但系统日历里还在的**我们写进去的**条目
    for (const id of want) {
      existing.delete(id);
    }
    for (const id of existing.keys()) {
      if (!id.startsWith(`${ref.bookId}|`)) {
        continue; // 不是本日历本写进去的（可能是用户在系统日历里手动加的）→ 保留
      }
      const ev: calendarManager.Event | undefined = existing.get(id);
      if (ev !== undefined && ev.id !== undefined) {
        await cal.deleteEvent(ev.id);
        res.deleted++;
      }
    }

    // ⭐ 落成快照：出站写完后重新读一遍系统日历，整体重建该本的快照。
    // 这是"防回灌"的地基 —— 下一轮入站对账靠它区分"用户改的"还是"我们自己写的"。
    // 快照按 **bookId** 存（与系统日历侧标识一致），不按会变的 calKey。
    const after: calendarManager.Event[] = await SystemCalendarMirror.queryEvents(cal);
    const snapN: number = await MirrorSnapshot.replaceAll(context, ref.bookId, after);

    LogUtil.write(
      `镜像[${ref.name}] bookId=${ref.bookId} 计划=${plan.length} 系统已有=${sysEvents.length} ` +
      `新增=${toAdd.length} 快照=${snapN} ` +
      `窗口=${SystemCalendarMirror.fmt(winStart)}~${SystemCalendarMirror.fmt(winEnd)}`);
  }

  /**
   * ⭐ 诊断导出：把"App 侧计划写入"与"系统日历里实际存在"的完整对照写到
   * `${filesDir}/mirror_diag.txt`（可用 hdc 直接取出分析）。
   *
   * 为什么需要它：用户反馈"系统日历里有、App 里没有"这种问题靠描述很难定位，
   * 必须把两侧的清单原样摆在一起逐条比。每次镜像后自动重写一份。
   */
  private static async dumpDiagnosis(
    context: common.Context,
    cm: calendarManager.CalendarManager,
    refs: BookRef[],
    plans: Map<string, MirrorOcc[]>,
    winStart: number,
    winEnd: number
  ): Promise<void> {
    try {
      const lines: string[] = [];
      lines.push(`镜像诊断 ${new Date().toLocaleString()}`);
      lines.push(`窗口 ${SystemCalendarMirror.fmt(winStart)} ~ ${SystemCalendarMirror.fmt(winEnd)} ` +
        `(${winStart} ~ ${winEnd})`);
      const cals: calendarManager.Calendar[] = await cm.getAllCalendars();
      // ⭐ 全设备日历账户清单：一眼看出有没有"本应用建的、但不属于当前选中本"的残留账户
      //    （历史 calKey 命名的账户、重复账户）。每次镜像都导出一份，省得再靠按钮抓。
      const keepNames: Set<string> = new Set<string>();
      for (const r of refs) {
        keepNames.add(r.sysAccountName);
      }
      let mineN: number = 0;
      let keepN: number = 0;
      lines.push('');
      lines.push(`[全设备日历账户] 共 ${cals.length} 个日历本：`);
      for (const c of cals) {
        let accName: string = '';
        let disp: string = '';
        let n: number = -1;
        try {
          accName = c.getAccount().name;
          disp = c.getAccount().displayName ?? '';
        } catch (err) {
          // 忽略
        }
        try {
          n = (await SystemCalendarMirror.queryEvents(c)).length;
        } catch (err) {
          // 忽略
        }
        let tag: string = 'other';
        if (accName.startsWith(SystemCalendarMirror.ACCOUNT_PREFIX)) {
          if (keepNames.has(accName)) {
            tag = 'KEEP';
            keepN++;
          } else {
            tag = 'MINE(残留)';
            mineN++;
          }
        }
        lines.push(`  [${tag}] #${c.id} acc=${accName} display=${disp} 条目=${n}`);
      }
      lines.push(`  小结：本应用账户 ${keepN + mineN} 个（本次保留 ${keepN}，残留 ${mineN}）`);
      for (const ref of refs) {
        const plan: MirrorOcc[] | undefined = plans.get(ref.bookId);
        const list: MirrorOcc[] = plan !== undefined ? plan : [];
        let cal: calendarManager.Calendar | undefined = undefined;
        for (const c of cals) {
          if (c.getAccount().name === ref.sysAccountName) {
            cal = c;
            break;
          }
        }
        lines.push('');
        lines.push(`[本] ${ref.name} | bookId=${ref.bookId} | calKey=${ref.calKey} | 账户=${ref.sysAccountName} | 账户存在=${cal !== undefined}`);
        if (cal === undefined) {
          continue;
        }
        const sysEvents: calendarManager.Event[] = await SystemCalendarMirror.queryEvents(cal);
        const sysMap: Map<string, calendarManager.Event> = new Map<string, calendarManager.Event>();
        for (const ev of sysEvents) {
          const id: string = ev.identifier ?? '';
          if (id !== '') {
            sysMap.set(id, ev);
          }
        }
        lines.push(`  计划写入=${list.length}  系统日历实际=${sysEvents.length}（其中带 identifier=${sysMap.size}）`);

        // ① 系统日历里有、计划里没有 → 多出来的（正常会被删掉；删不掉就是残留）
        const planIds: Set<string> = new Set<string>();
        for (const o of list) {
          planIds.add(o.identifier);
        }
        const extra: string[] = [];
        for (const id of sysMap.keys()) {
          if (planIds.has(id)) {
            continue;
          }
          const ev: calendarManager.Event | undefined = sysMap.get(id);
          if (ev === undefined) {
            continue;
          }
          extra.push(`    ${SystemCalendarMirror.stamp(ev.startTime)} ${ev.title ?? ''} [${id}]`);
        }
        lines.push(`  ① 系统多出（${extra.length}）：`);
        for (let i: number = 0; i < extra.length && i < 120; i++) {
          lines.push(extra[i]);
        }

        // ② 计划里有、系统日历没有 → 漏写
        const miss: string[] = [];
        for (const o of list) {
          if (!sysMap.has(o.identifier)) {
            miss.push(`    ${SystemCalendarMirror.stamp(o.start)} ${o.title} [${o.identifier}]`);
          }
        }
        lines.push(`  ② 漏写（${miss.length}）：`);
        for (let i: number = 0; i < miss.length && i < 60; i++) {
          lines.push(miss[i]);
        }

        // ③ 系统日历里该账户的**全部**条目（供逐条核对，最多 400 行）
        lines.push(`  ③ 系统日历条目（${sysEvents.length}，最多列 400）：`);
        const sorted: calendarManager.Event[] = sysEvents.slice().sort(
          (a: calendarManager.Event, b: calendarManager.Event): number => a.startTime - b.startTime);
        for (let i: number = 0; i < sorted.length && i < 400; i++) {
          const ev: calendarManager.Event = sorted[i];
          lines.push(`    ${SystemCalendarMirror.stamp(ev.startTime)}~${SystemCalendarMirror.stamp(ev.endTime)} ` +
            `${ev.isAllDay === true ? '[全天]' : ''}${ev.title ?? ''} [${ev.identifier ?? ''}]`);
        }
      }
      const path: string = `${context.filesDir}/mirror_diag.txt`;
      const text: string = lines.join('\n') + '\n';
      const file: fs.File = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      fs.closeSync(file.fd);
      LogUtil.write(`镜像诊断已导出：${path}（${lines.length} 行）`);
    } catch (err) {
      LogUtil.write(`导出镜像诊断失败: ${(err as BusinessError).message}`);
    }
  }

  /** 时间戳 → `MM-DD HH:mm` */
  private static stamp(ts: number): string {
    const d: Date = new Date(ts);
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  /* ==================== 镜像窗口 ==================== */

  /**
   * ⭐ 镜像窗口：**过去 1 年 ~ 未来 2 年**，且两端都对齐到"月份边界"。
   *
   * 为什么要窗口：App 首页显示的是"窗口内展开的发生"，而系统日历如果拿到 master + RRULE
   * 会自己无限展开 —— 两套口径不一致就会出现"App 里没有、系统日历里一堆"的幽灵日程。
   * 改成我们自己按窗口展开后，两边口径完全一致。
   *
   * 为什么对齐到月：镜像每天都会跑，若窗口按"今天±N天"滑动，每天都在增删边界上的条目。
   * 对齐到月初后，只有跨月时边界才动。
   */
  private static windowStart(): number {
    const d: Date = new Date();
    d.setHours(0, 0, 0, 0);
    d.setDate(1);
    d.setMonth(d.getMonth() - 12);
    return d.getTime();
  }

  private static windowEnd(): number {
    const d: Date = new Date();
    d.setHours(0, 0, 0, 0);
    d.setDate(1);
    d.setMonth(d.getMonth() + 25);
    return d.getTime() - 1;
  }

  private static fmt(ts: number): string {
    const d: Date = new Date(ts);
    return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
  }

  /** EXDATE（分号分隔的 iCal 时间值）→ 时间戳数组，供 RruleUtil 排除 */
  private static exdateNums(exdate: string): number[] {
    const out: number[] = [];
    if (exdate === '') {
      return out;
    }
    for (const raw of exdate.split(';')) {
      const t: IcsTime | null = IcsUtil.parseTime(raw, !raw.includes('T'));
      if (t !== null) {
        out.push(t.time);
      }
    }
    return out;
  }

  /** 批量新增（每批 CHUNK 条）；整批失败则退回逐条，避免一条脏数据拖垮一批 */
  private static async addInChunks(
    cal: calendarManager.Calendar,
    list: calendarManager.Event[],
    res: MirrorResult
  ): Promise<void> {
    for (let i: number = 0; i < list.length; i += SystemCalendarMirror.CHUNK) {
      const end: number = Math.min(i + SystemCalendarMirror.CHUNK, list.length);
      const part: calendarManager.Event[] = list.slice(i, end);
      try {
        await cal.addEvents(part);
        res.added += part.length;
      } catch (err) {
        for (const ev of part) {
          try {
            await cal.addEvent(ev);
            res.added++;
          } catch (e2) {
            res.failed++;
            LogUtil.write(`镜像新增失败: ${(e2 as BusinessError).message}`);
          }
        }
      }
    }
  }

  /**
   * 取回该账户下已有日程。
   *
   * ⚠️ 09-19 实测：`getEvents(undefined, 字段数组)` 在这个版本上报 `type error!`，
   *    每次调用都先抛一次异常、再退回无参，既慢又把日志刷满（一次镜像几十行）。
   *    而无参调用返回的 Event 里 identifier 是有值的（诊断已验证）→ 直接用无参。
   */
  private static async queryEvents(cal: calendarManager.Calendar): Promise<calendarManager.Event[]> {
    try {
      return await cal.getEvents();
    } catch (err) {
      LogUtil.write(`getEvents()失败，退回带字段: ${(err as BusinessError).message}`);
      return await cal.getEvents(undefined, SystemCalendarMirror.QUERY_FIELDS);
    }
  }

  /**
   * 幂等地取得本应用自己的镜像账户（已存在则复用，不存在则创建并设色）。
   *
   * ⭐ 0.0.8：displayName 按用户所选格式生成。
   *   ⚠️ **已存在的账户不会被改名**（平台无"改账户名"API；改名是破坏性操作，
   *      必须由用户显式触发 `reapplyDisplayNames`）。此处仅保证**新建**时用对格式。
   */
  private static async ensureCalendar(
    cm: calendarManager.CalendarManager,
    accountName: string,
    ref: BookRef,
    format: number
  ): Promise<calendarManager.Calendar> {
    const calendars: calendarManager.Calendar[] = await cm.getAllCalendars();
    for (const cal of calendars) {
      if (cal.getAccount().name === accountName) {
        // 每次都尝试同步一次颜色（用户可能改过日历本色）
        // ⚠️ displayName 不在此处改：改账户名需删账户重建（破坏性），由用户显式触发
        try {
          await cal.setConfig({ enableReminder: true, color: ref.color });
        } catch (err) {
          // 设色失败不影响镜像本身
        }
        return cal;
      }
    }
    const cal: calendarManager.Calendar = await cm.createCalendar({
      name: accountName,
      type: calendarManager.CalendarType.LOCAL,
      displayName: SystemCalendarMirror.displayNameFor(ref, format)
    });
    try {
      await cal.setConfig({ enableReminder: true, color: ref.color });
    } catch (err) {
      // 同上
    }
    return cal;
  }

  /* ==================== 转换 ==================== */

  /**
   * 构造一条写进系统日历的日程。
   * ⚠️ 传入的是**某一次发生**的起止时刻 —— 重复日程由我们自己展开成多条，
   *     **不再设置 recurrenceRule**（交给系统日历展开就会出现幽灵日程，见窗口说明）。
   */
  private static toSystemEvent(
    e: LocalEvent,
    identifier: string,
    startTs: number,
    endTs: number
  ): calendarManager.Event {
    const ev: calendarManager.Event = {
      type: calendarManager.EventType.NORMAL,
      title: e.title !== '' ? e.title : '(无标题)',
      startTime: startTs,
      endTime: e.isAllDay ? SystemCalendarMirror.dayStart(endTs) + SystemCalendarMirror.DAY : endTs,
      isAllDay: e.isAllDay,
      identifier: identifier
    };
    if (e.description !== '') {
      ev.description = e.description;
    }
    if (e.location !== '') {
      ev.location = { location: e.location };
    }
    const reminders: number[] = SystemCalendarMirror.remindersOf(e);
    // ⭐⭐ 只写"提醒时刻尚未到"的提醒（0.0.8 修复"已过日程仍提醒"）。
    //   原因：写进系统日历的 reminderTime 一旦其时刻已过，系统会在**任何一次覆写**时
    //   立即补发一条通知 → 表现为"日程都过去了还提醒"。这类提醒已无意义，索性不写。
    const future: number[] = SystemCalendarMirror.futureReminders(
      reminders, startTs, e.isAllDay, Date.now());
    if (future.length > 0) {
      ev.reminderTime = future;
    }
    // ⚠️ 这里**故意不设 recurrenceRule**：重复日程由我们自己按窗口展开成多条实例，
    //    交给系统日历展开会因 RecurrenceRule 表达不全而出现错误的重复（09-19 事故）。
    return ev;
  }

  /**
   * 提醒时刻的"基准时刻"（系统口径）：
   *  - 普通日程：以**开始时刻**为基准（提前 N 分钟 = start - N）；
   *  - 全天日程：系统文档规定以**当日 09:00**为基准（提前 N 分钟 = 当天 09:00 - N）。
   */
  private static reminderBaseMs(startTs: number, isAllDay: boolean): number {
    if (isAllDay) {
      const d: Date = new Date(startTs);
      d.setHours(9, 0, 0, 0);
      return d.getTime();
    }
    return startTs;
  }

  /** 过滤出"提醒时刻还没到"的提醒（用于避免写入已过期的提醒而触发补发） */
  private static futureReminders(
    reminders: number[],
    startTs: number,
    isAllDay: boolean,
    now: number
  ): number[] {
    const base: number = SystemCalendarMirror.reminderBaseMs(startTs, isAllDay);
    const kept: number[] = [];
    for (const r of reminders) {
      if (r > 0 && base - r * 60000 > now) {
        kept.push(r);
      }
    }
    return kept;
  }

  /** 提醒数组的规范化字符串（排序去重后拼接），用于比较 */
  private static reminderKey(reminders: number[]): string {
    const s: number[] = reminders.slice().sort((a: number, b: number): number => a - b);
    const out: string[] = [];
    for (const n of s) {
      if (out.indexOf(String(n)) < 0) {
        out.push(String(n));
      }
    }
    return out.join(',');
  }

  /** 本地时区当天 0 点的时间戳 */
  private static dayStart(ts: number): number {
    const d: Date = new Date(ts);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  private static remindersOf(e: LocalEvent): number[] {
    if (e.reminders.length > 0) {
      return e.reminders;
    }
    if (e.reminder > 0) {
      return [e.reminder];
    }
    return [];
  }

  /**
   * 比对现有条目与期望条目：**返回空串表示相同**，否则返回首个差异描述（用于诊断"每次都更新"）。
   *
   * ⚠️ 全天日程**不能逐毫秒比**。实测（09-19 真机）系统日历对全天 endTime 有三种写法，
   *    差值时区偏移（+8h）或 1 毫秒都会让"每次镜像都更新同一批、永不收敛"：
   *      · 我们写入：          次日 00:00（本地）
   *      · 系统读回 A：        当日 23:59:59.999
   *      · 系统读回 B：        次日 00:00 + 时区偏移（如 08:00）
   *    → 全天一律先折成"日"再比，三种写法都要能认出来。
   */
  private static diffOf(cur: calendarManager.Event, want: calendarManager.Event): string {
    if (cur.title !== want.title) {
      return `title "${cur.title}" != "${want.title}"`;
    }
    const curAllDay: boolean = cur.isAllDay ?? false;
    const wantAllDay: boolean = want.isAllDay ?? false;
    if (curAllDay !== wantAllDay) {
      return `isAllDay ${curAllDay} != ${wantAllDay}`;
    }
    if (curAllDay) {
      if (SystemCalendarMirror.dayStart(cur.startTime) !== SystemCalendarMirror.dayStart(want.startTime)) {
        return `全天start ${cur.startTime} != ${want.startTime}`;
      }
      const wantEndDay: number = SystemCalendarMirror.dayStart(want.endTime - 1);
      // 写法 A：当日 23:59:59.999
      const curEndDayA: number = SystemCalendarMirror.dayStart(cur.endTime - 1);
      // 写法 B：次日 00:00（含被时区偏移推后到次日 08:00 的情况）
      const curEndDayB: number = SystemCalendarMirror.dayStart(cur.endTime) - SystemCalendarMirror.DAY;
      if (curEndDayA !== wantEndDay && curEndDayB !== wantEndDay) {
        return `全天end ${cur.endTime} != ${want.endTime}`;
      }
    } else {
      if (cur.startTime !== want.startTime) {
        return `start ${cur.startTime} != ${want.startTime}`;
      }
      if (cur.endTime !== want.endTime) {
        return `end ${cur.endTime} != ${want.endTime}`;
      }
    }
    if ((cur.description ?? '') !== (want.description ?? '')) {
      return 'description';
    }
    if ((cur.location?.location ?? '') !== (want.location?.location ?? '')) {
      return 'location';
    }
    // ⭐ 0.0.8：提醒也要比较 —— 否则用户改了提醒时间，系统日历侧**永远不会更新**
    //   （旧版 diffOf 不比 reminderTime，改动被判定为"无差异" → 不触发 updateEvent）。
    //   ⚠️ 写入侧已过滤掉"已过期"的提醒（见 toSystemEvent / futureReminders），
    //      所以这里的比较也用同一口径，避免"每轮都因提醒不同而重写"。
    const curRem: number[] = cur.reminderTime ?? [];
    const wantRem: number[] = want.reminderTime ?? [];
    if (SystemCalendarMirror.reminderKey(curRem) !== SystemCalendarMirror.reminderKey(wantRem)) {
      return `reminder ${SystemCalendarMirror.reminderKey(curRem) || '(无)'} != ${SystemCalendarMirror.reminderKey(wantRem) || '(无)'}`;
    }
    return '';
  }

  /* ==================== 日历本信息 ==================== */

  /**
   * 由 calKey（accId_序号）解析出日历本名与颜色。
   * 颜色优先用服务器定义的 calendar-color，缺失时退回本应用调色板。
   */
  private static bookInfo(calKey: string): BookInfo {
    const info: BookInfo = new BookInfo();
    info.calKey = calKey;
    const pos: number = calKey.lastIndexOf('_');
    if (pos <= 0) {
      info.name = calKey;
      info.color = BookPalette.colorFor(0);
      return info;
    }
    const accId: string = calKey.substring(0, pos);
    const idx: number = Number.parseInt(calKey.substring(pos + 1), 10);
    info.name = `日历本 ${idx + 1}`;
    info.color = BookPalette.colorFor(idx);
    info.accId = accId;
    info.index = idx;
    return info;
  }

  /**
   * ⭐ 解析出每个日历本的**稳定**引用。
   *
   * ⚠️ 血的教训（09-19）：`calKey` 是 `<账号ID>_<序号>`，**序号会变** ——
   *    `EventDb.remapCalKeys()` 就是专门在日历本重排时把日程从旧 calKey 搬到新 calKey 的。
   *    早期版本拿 calKey 当系统日历账户名 + identifier 前缀，序号一变就：
   *      · 旧账户还在，但 identifier 全对不上 → 旧条目不删、新条目全插 → 系统日历出现重复；
   *      · 某个账户被当成另一个本 → 日程串本。
   *    → 一律改用**服务器分配的 href**（稳定不变）派生 bookId。
   */
  static async resolveBookRefs(
    context: common.Context,
    keys: string[]
  ): Promise<Map<string, BookRef>> {
    const all: BookRef[] = await SystemCalendarMirror.listBooks(context);
    const out: Map<string, BookRef> = new Map<string, BookRef>();
    for (const calKey of keys) {
      for (const ref of all) {
        if (ref.calKey === calKey) {
          out.set(calKey, ref);
          break;
        }
      }
    }
    return out;
  }

  /** ⭐ 列出**全部** DAV 日历本的稳定引用（账号 × 序号） */
  static async listBooks(context: common.Context): Promise<BookRef[]> {
    const out: BookRef[] = [];
    let accounts: DavAccount[] = [];
    try {
      accounts = await AccountStore.loadAll(context);
    } catch (err) {
      accounts = [];
    }
    for (const acc of accounts) {
      const n: number = Math.max(
        acc.calendarHrefs.length,
        Math.max(acc.calendarNames.length, acc.calendarColors.length)
      );
      for (let i: number = 0; i < n; i++) {
        const ref: BookRef = new BookRef();
        ref.accId = acc.id;
        ref.index = i;
        ref.calKey = `${acc.id}_${i}`;
        ref.href = i < acc.calendarHrefs.length ? acc.calendarHrefs[i] : '';
        ref.name = (i < acc.calendarNames.length && acc.calendarNames[i] !== '')
          ? acc.calendarNames[i]
          : `日历本 ${i + 1}`;
        ref.color = (i < acc.calendarColors.length && acc.calendarColors[i] !== '')
          ? acc.calendarColors[i]
          : BookPalette.colorFor(i);
        ref.accountName = acc.name;
        // 稳定标识：href 由服务器分配、不随序号变动（href 缺失时退回 calKey 并记日志）
        ref.bookId = ref.href !== ''
          ? `${ref.accId}-${SystemCalendarMirror.stableHash(ref.href)}`
          : ref.calKey;
        if (ref.href === '') {
          LogUtil.write(`⚠️ 日历本 ${ref.calKey} 缺少 href，退回用 calKey 做镜像标识（序号变动会导致重复）`);
        }
        ref.sysAccountName = SystemCalendarMirror.ACCOUNT_PREFIX + ref.bookId;
        out.push(ref);
      }
    }
    return out;
  }

  /** 按 bookId 选出要处理的本（顺序跟随 ids；同一 bookId 只会出现一次，避免同名账户） */
  static async resolveByIds(context: common.Context, ids: string[]): Promise<BookRef[]> {
    const all: BookRef[] = await SystemCalendarMirror.listBooks(context);
    const out: BookRef[] = [];
    const seen: Set<string> = new Set<string>();
    for (const id of ids) {
      if (seen.has(id)) {
        continue;
      }
      for (const ref of all) {
        if (ref.bookId === id) {
          out.push(ref);
          seen.add(id);
          break;
        }
      }
    }
    return out;
  }

  /** 禁止镜像的 bookId（备份目标本） */
  static async blockedBookIds(context: common.Context): Promise<string[]> {
    try {
      const check: BackupTargetCheck = await SystemCalendarMirror.checkBackupTarget(context);
      if (check.ref !== undefined) {
        return [check.ref.bookId];
      }
    } catch (err) {
      // 读设置失败不阻断镜像
    }
    return [];
  }

  /* ==================== 系统日历备份目标（稳定标识 + 失效即关闭） ==================== */

  /**
   * ⭐ 解析「系统日历 → CalDAV」的备份目标本；解析不到就**直接关掉这个功能**。
   *
   * 背景（用户实测）：老版本把目标存成 calKey（`accId_序号`）。用户在「编辑账号」里
   * **取消勾选**某个日历本后，`calendarHrefs` 收缩、后面的本序号整体前移，
   * 于是原 `accId_2` 悄悄指向了**另一个本** → 系统日历被导进用户根本没选过的本里。
   * 这与镜像侧的"串本"是同一类 bug，修法也一样：改用由 href 派生的 bookId。
   *
   * 失效判据（任一成立即视为失效）：
   *   - 存的 bookId 在**当前日历本集合**（= 各账号已勾选的本）里找不到
   *     → 该本被取消勾选、或账号/日历本被删除；
   *   - 老 calKey 值存在 → **不可信**（见下方 ①）；
   *   - 模式为 backup 却根本没有目标 → 不一致状态。
   *
   * 失效的动作：清空备份目标；**若功能正开着则置回 `display`（= 关掉这个功能）**，并留日志。
   * 这样就不会出现"开关显示备份中，实际却导进了别的本 / 或什么都没导"的假象。
   *
   * ⚠️ 目标本有效时返回 `ref`；用户**从未选择**过目标（且功能没开）时返回空且不关闭。
   */
  static async checkBackupTarget(context: common.Context): Promise<BackupTargetCheck> {
    const out: BackupTargetCheck = new BackupTargetCheck();
    try {
      const mode: string = await AppSettings.getSysCalMode(context);
      const bookId: string = await AppSettings.getBackupBookId(context);
      const legacy: string = await AppSettings.getBackupCalKey(context);

      // ① 老值（calKey，形如 `accId_序号`）**一律不可信**：
      //    从写下它到现在的这段时间里，序号有没有漂移过、漂移了几次，都无从判断；
      //    "乐观迁移"会把漂移后的另一个本**固化成新的目标** —— 等于把错误目标洗白。
      //    所以直接作废，让用户重新显式选一次（一次性成本，换取永久消除静默写错本）。
      if (bookId === '' && legacy !== '') {
        await SystemCalendarMirror.invalidateBackupTarget(context, out, mode,
          `旧版备份目标（${legacy}）无法确认对应哪个日历本`);
        return out;
      }

      // ② 从未配置过目标本
      if (bookId === '') {
        if (mode === 'backup') {
          // 模式开着却没有目标 = 不一致状态（正常流程不允许出现）→ 一并关掉，别让它空转
          await SystemCalendarMirror.invalidateBackupTarget(context, out, mode,
            '未选择备份目标日历本');
        }
        return out;
      }

      // ③ 用稳定标识解析目标本；解析不到 = 该本被取消勾选 / 账号或本被删除
      const all: BookRef[] = await SystemCalendarMirror.listBooks(context);
      for (const r of all) {
        if (r.bookId === bookId) {
          out.ref = r;
          return out;
        }
      }
      await SystemCalendarMirror.invalidateBackupTarget(context, out, mode,
        `目标日历本（${bookId}）已被取消同步或删除`);
      return out;
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`解析系统日历备份目标失败: ${e.message}`);
      return out;
    }
  }

  /**
   * 目标不可用时的统一处置：清掉目标 + 留日志；**若备份功能正开着，则一并关闭**。
   *
   * ⚠️ 抽出来是为了让所有调用方口径一致 —— 尤其是"只清目标、不关开关"这种半吊子处理：
   *    那会留下"开关显示着备份中、实际什么都没导"的假象。
   *
   * @param mode 当前 sys_cal_mode；只有它本来就是 'backup' 时才算"自动关闭"，才需要提示用户
   */
  private static async invalidateBackupTarget(
    context: common.Context,
    out: BackupTargetCheck,
    mode: string,
    reason: string
  ): Promise<void> {
    out.ref = undefined;
    out.closed = (mode === 'backup');
    out.reason = reason; // 无论功能是否开着都要带上原因，UI 才能告诉用户"为什么没了"
    await AppSettings.clearBackupTarget(context);
    if (out.closed) {
      await AppSettings.setSysCalMode(context, 'display');
      LogUtil.write(
        `⚠️ 系统日历备份已自动关闭：${reason}。` +
        `为避免把系统日程导进别的日历本，已把「系统日历 → CalDAV」重置为仅显示；` +
        `如需继续备份，请在设置页重新选择目标日历本。`);
    } else {
      LogUtil.write(`已清除失效的备份目标设置：${reason}（备份功能本就未开启，无需关闭）`);
    }
  }

  /** 只要目标本（不需要失效信息）时的便捷入口 */
  static async backupTargetRef(context: common.Context): Promise<BookRef | undefined> {
    const check: BackupTargetCheck = await SystemCalendarMirror.checkBackupTarget(context);
    return check.ref;
  }

  /**
   * ⭐ 读取"用户选中要镜像的日历本"，返回稳定引用，并顺带完成历史迁移。
   *
   * 迁移：老版本把选中项存成 calKey（`accId_序号`）。序号一变，选中的本就串成另一个本，
   *      系统日历账户名也跟着变 → 重复账户 + 串本。这里首次读到旧值时，
   *      把当前 calKey 对应的 bookId 记下来并改用 bookId 存储，之后不再受序号影响。
   */
  static async selectedBookRefs(context: common.Context): Promise<BookRef[]> {
    let ids: string[] = await AppSettings.getMirrorBookIds(context);
    if (ids.length === 0) {
      const legacy: string[] = await AppSettings.getMirrorKeys(context);
      if (legacy.length > 0) {
        const refs: Map<string, BookRef> =
          await SystemCalendarMirror.resolveBookRefs(context, legacy);
        ids = [];
        for (const k of legacy) {
          const ref: BookRef | undefined = refs.get(k);
          if (ref !== undefined) {
            ids.push(ref.bookId);
          }
        }
        await AppSettings.setMirrorBookIds(context, ids);
        LogUtil.write(`镜像选中项已迁移为稳定标识：${legacy.join(',')} → ${ids.join(',')}`);
      }
    }
    if (ids.length === 0) {
      return [];
    }
    const blocked: string[] = await SystemCalendarMirror.blockedBookIds(context);
    return await SystemCalendarMirror.resolveByIds(context, ids.filter((id: string): boolean =>
      !blocked.includes(id)));
  }

  /** href → 短且稳定的字符串（避免 href 里的特殊字符进账户名） */
  private static stableHash(s: string): string {
    let h1: number = 0;
    let h2: number = 5381;
    for (let i: number = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      h1 = ((h1 << 5) + h1 + c) | 0;
      h2 = ((h2 << 5) + h2 + c) | 0;
    }
    return `${(h1 >>> 0).toString(36)}${(h2 >>> 0).toString(36)}`;
  }

  /**
   * ⭐ 由 `<accId> + href` 算出稳定标识 bookId（= `<accId>-<href哈希>`）。
   * 与 `listBooks()` 内部算法**完全一致**，供编辑账号页在"取消勾选某个日历本"时
   * 立即算出它的 bookId 并删掉对应镜像账户用（此时账号配置已被改写，listBooks 已查不到它）。
   * href 为空时退回 calKey（与 listBooks 的兜底口径一致）。
   */
  static bookIdOf(accId: string, href: string, fallbackCalKey: string): string {
    return href !== ''
      ? `${accId}-${SystemCalendarMirror.stableHash(href)}`
      : fallbackCalKey;
  }

  /** 用账号信息补全日历本名与颜色（需要异步加载账号） */
  static async loadBookLabels(context: common.Context, keys: string[]): Promise<BookInfo[]> {
    const out: BookInfo[] = [];
    let accounts: DavAccount[] = [];
    try {
      accounts = await AccountStore.loadAll(context);
    } catch (err) {
      accounts = [];
    }
    for (const calKey of keys) {
      const info: BookInfo = SystemCalendarMirror.bookInfo(calKey);
      for (const acc of accounts) {
        if (acc.id === info.accId) {
          if (info.index >= 0 && info.index < acc.calendarNames.length &&
            acc.calendarNames[info.index] !== '') {
            info.name = acc.calendarNames[info.index];
          }
          if (info.index >= 0 && info.index < acc.calendarColors.length &&
            acc.calendarColors[info.index] !== '') {
            info.color = acc.calendarColors[info.index];
          }
          info.accountName = acc.name;
          break;
        }
      }
      out.push(info);
    }
    return out;
  }
}

/**
 * 一次"发生"（写进系统日历的一条）。
 * 重复日程会被展开成多条 MirrorOcc，每条对应一次发生。
 */
class MirrorOcc {
  identifier: string = '';
  title: string = '';
  start: number = 0;
  end: number = 0;
  isAllDay: boolean = false;
  src: LocalEvent = new LocalEvent();
}

/** 一个日历本的展示信息 */
export class BookInfo {
  calKey: string = '';
  accId: string = '';
  index: number = -1;
  name: string = '';
  color: string = '#007DFF';
  accountName: string = '';
}

/**
 * 日历本的**稳定**引用（镜像专用）。
 * calKey 会随序号变动，bookId 由服务器 href 派生、不会变 —— 系统日历账户名与
 * Event.identifier 一律用 bookId，绝不用 calKey。
 */
export class BookRef {
  calKey: string = '';        // 工程内部标识（会变，只用于查本地库）
  bookId: string = '';        // ⭐ 稳定标识（`<accId>-<href哈希>`）—— 系统日历侧一律用它
  sysAccountName: string = ''; // 系统日历账户名 = 前缀 + bookId
  accId: string = '';
  index: number = -1;
  href: string = '';
  name: string = '';
  color: string = '#007DFF';
  accountName: string = '';   // 所属 DAV 账号名（仅展示用）
}

/**
 * 「系统日历备份目标」的检查结果（供 UI 与同步流程共用）。
 *
 * 只有三种状态：
 *   - `ref != undefined`              → 目标有效，正常导入
 *   - `ref == undefined && !closed`   → 用户**从未选择**过目标本（功能待配置，不算故障）
 *   - `ref == undefined && closed`    → 目标本**原来存在、现在没了** → 已自动关闭备份功能
 */
export class BackupTargetCheck {
  /** 解析到的目标日历本（稳定引用）；undefined = 无可用目标 */
  ref: BookRef | undefined = undefined;
  /** 是否因目标失效而**自动关闭**了「备份到 CalDAV」（sys_cal_mode 置回 display） */
  closed: boolean = false;
  /** 自动关闭的原因（UI 提示用） */
  reason: string = '';
}
