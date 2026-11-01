// entry/src/main/ets/common/ReminderService.ets
// 日程提醒，双模式：
// 1) 系统代理提醒（reminderAgentManager）：需要华为审批的"代理提醒使用权限"，
//    未申请的普通应用配额为 0（发布报 1700002 且池内为 0）
// 2) 应用内通知（notificationManager）：配额为 0 时的降级方案。
//    依赖应用进程存活（前台或"后台持续同步"长时任务），由自动同步定时器驱动，
//    每次检查把"提醒时刻刚好已到"的日程用本地通知发出。
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EventDb, LocalEvent } from './EventDb';
import { AppSettings } from './AppSettings';
import { AccountStore } from './AccountStore';
import { SystemCalendarMirror } from './SystemCalendarMirror';
import { LogUtil } from './LogUtil';

export class ReminderService {
  // 系统对单应用代理提醒上限 30 条，留 5 个余量给测试提醒等临时请求
  private static readonly MAX_REMINDERS: number = 25;
  private static readonly WINDOW: number = 7 * 86400000; // 只排未来 7 天

  /** 代理提醒可用性：null=未探测（每次进程启动重新探测），false=配额为0（走应用内通知），true=可用 */
  static agentAvailable: boolean | null = null;

  /** calKey → 日历本名称缓存（通知文案用），60 秒刷新一次 */
  private static calNameCache: Map<string, string> = new Map();
  private static calNameLoadedAt: number = 0;

  /** 已镜像到系统日历的 calKey 集合缓存（避免重复排提醒），30 秒刷新一次 */
  private static mirroredCalKeys: Set<string> = new Set();
  private static mirroredLoadedAt: number = 0;

  /**
   * ⭐⭐ 取"已镜像到系统日历"的日历本 calKey 集合（0.0.8 修复双通道重复提醒）。
   *
   * 镜像到系统日历后，**系统日历自己会提醒**（条目的 reminderTime）；
   * 若 App 再为同一个本排代理提醒 → 同一条日程提醒两次。
   * 因此这里返回"该由系统日历负责提醒"的本，App 侧**完全不再提醒**它们。
   *
   * ⚠️ 判据是"**镜像账户真实存在**"（`SystemCalendarMirror.mirroredCalKeys`），
   *    而不是"用户勾选了要镜像"—— 后者只是意图，本可能还没被真正写进系统日历；
   *    按意图跳过会导致"两边都不提醒"（漏提醒）。
   * ⚠️ 返回空集 = 不跳过任何本（保守：宁可多提醒，不可漏提醒）。
   */
  private static async mirroredKeys(context: common.Context): Promise<Set<string>> {
    if (Date.now() - ReminderService.mirroredLoadedAt < 30000
      && ReminderService.mirroredCalKeys.size > 0) {
      return ReminderService.mirroredCalKeys;
    }
    const out: Set<string> = await SystemCalendarMirror.mirroredCalKeys(context);
    ReminderService.mirroredCalKeys = out;
    ReminderService.mirroredLoadedAt = Date.now();
    return out;
  }

  /** 镜像开关变化后调用，让缓存立即失效（如用户关闭镜像 → 立刻恢复 App 提醒） */
  static invalidateMirrorCache(): void {
    ReminderService.mirroredLoadedAt = 0;
    ReminderService.mirroredCalKeys = new Set();
  }

  /** 日历本名称（通知文案用）：缓存 60 秒，'local' = 本机日历 */
  private static async calName(context: common.Context, calKey: string): Promise<string> {
    if (Date.now() - ReminderService.calNameLoadedAt > 60000
      || ReminderService.calNameCache.size === 0) {
      const map: Map<string, string> = new Map();
      map.set('local', '本机日历');
      try {
        const accounts = await AccountStore.loadAll(context);
        for (const acc of accounts) {
          for (let i: number = 0; i < acc.calendarHrefs.length; i++) {
            const bookName: string = i < acc.calendarNames.length
              ? acc.calendarNames[i] : `日历本${i + 1}`;
            map.set(`${acc.id}_${i}`, `${acc.name}·${bookName}`);
          }
        }
      } catch (err) {
        // 读取失败用旧缓存
      }
      ReminderService.calNameCache = map;
      ReminderService.calNameLoadedAt = Date.now();
    }
    const name: string | undefined = ReminderService.calNameCache.get(calKey);
    return name !== undefined ? name : '日历';
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /** 当前系统里本应用的有效提醒条数 */
  private static async poolCount(): Promise<number> {
    try {
      const all = await reminderAgentManager.getValidReminders();
      return all.length;
    } catch (err) {
      return -1;
    }
  }

  /**
   * 发布单条代理提醒，1700002（池满/配额0）时清空后等待释放再重试，最多 3 轮。
   * 3 轮后仍满且池内为 0 → 判定配额为 0（需华为邮件申请权限），抛出标记错误。
   */
  private static async publishWithRetry(request: reminderAgentManager.ReminderRequestCalendar): Promise<void> {
    try {
      await reminderAgentManager.publishReminder(request);
      ReminderService.agentAvailable = true;
      return;
    } catch (err) {
      const e = err as BusinessError;
      if (e.code !== 1700002) {
        // ArkTS 只允许抛 Error：错误码编入消息，调用方从 message 解析
        throw new Error(`${e.code}:${e.message}`);
      }
    }
    for (let attempt: number = 1; attempt <= 3; attempt++) {
      // 已触发的代理提醒会残留为通知，一并清理
      try {
        await notificationManager.cancelAll();
      } catch (err) {
        // 忽略
      }
      await reminderAgentManager.cancelAllReminders();
      await ReminderService.delay(1500);
      const remain: number = await ReminderService.poolCount();
      LogUtil.write(`提醒池满（第 ${attempt} 次腾位）：清空后剩余 ${remain} 条，重试发布`);
      try {
        await reminderAgentManager.publishReminder(request);
        ReminderService.agentAvailable = true;
        return;
      } catch (err) {
        const e = err as BusinessError;
        if (e.code !== 1700002) {
          throw new Error(`${e.code}:${e.message}`);
        }
      }
    }
    throw new Error('1700002:提醒池腾位 3 轮后仍满');
  }

  /** 判定"配额为 0"：1700002 且系统内有效提醒为 0（没有超额却报超额 = 没有配额） */
  private static async isQuotaZero(): Promise<boolean> {
    const remain: number = await ReminderService.poolCount();
    return remain <= 0;
  }

  /** 全量重建代理提醒（仅在代理提醒可用时调用）。返回发布条数 */
  static async refreshReminders(context: common.Context): Promise<number> {
    let published: number = 0;
    if (ReminderService.agentAvailable === false) {
      return 0; // 应用内通知模式接管，不再请求代理提醒
    }
    try {
      await reminderAgentManager.cancelAllReminders();
      const before: number = await ReminderService.poolCount();
      if (before > 0) {
        LogUtil.write(`取消全部提醒后系统仍剩 ${before} 条`);
      }
      const now: number = Date.now();
      const rows: LocalEvent[] =
        await EventDb.queryRemindable(context, now, now + ReminderService.WINDOW);
      // 提醒静音的日历本（如别人分享的本）：其中所有日程都不再提醒
      const muted: string[] = await AppSettings.getMutedReminderKeys(context);
      // ⭐⭐ 已镜像到系统日历的本：由系统日历负责提醒，App 不再重复排（消除"提醒两次"）
      const mirrored: Set<string> = await ReminderService.mirroredKeys(context);
      if (mirrored.size > 0) {
        LogUtil.write(`提醒跳过 ${mirrored.size} 个已镜像到系统日历的日历本（交由系统日历提醒）`);
      }
      for (const e of rows) {
        if (muted.includes(e.calKey)) {
          continue;
        }
        if (mirrored.has(e.calKey)) {
          continue; // ⭐ 已镜像 → 系统日历会提醒，这里跳过避免重复
        }
        if (published >= ReminderService.MAX_REMINDERS) {
          break;
        }
        // 多提醒：每个提前量各发一条（含旧单提醒数据回退）
        const rems: number[] = e.reminders.length > 0 ? e.reminders
          : (e.reminder > 0 || e.reminder === -1 ? [e.reminder] : []);
        for (const rem of rems) {
          if (published >= ReminderService.MAX_REMINDERS) {
            break;
          }
          const remMin: number = (rem === -1 ? 0 : rem);
          const remindAt: number = e.startTime - remMin * 60000;
          if (remindAt <= now) {
            continue; // 提醒时间已过
          }
          const d = new Date(remindAt);
          const calName: string = await ReminderService.calName(context, e.calKey);
          const request: reminderAgentManager.ReminderRequestCalendar = {
            reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
            dateTime: {
              year: d.getFullYear(),
              month: d.getMonth() + 1,
              day: d.getDate(),
              hour: d.getHours(),
              minute: d.getMinutes(),
              second: 0
            },
            title: '日程提醒',
            content: (rem === -1 || rem === 0)
              ? `「${calName}」中的「${e.title}」现在开始`
              : `「${calName}」中的「${e.title}」将在 ${rem} 分钟后开始`,
            notificationId: (e.id * 10 + (rem === -1 ? 9 : rem)) % 100000,
            expiredContent: '该日程已开始',
            ringDuration: 5,
            snoozeTimes: 0,
            timeInterval: 0
          };
          await ReminderService.publishWithRetry(request);
          published++;
        }
      }
      const after: number = await ReminderService.poolCount();
      LogUtil.write(`提醒刷新完成：发布 ${published} 个提醒（窗口 7 天，静音日历本 ${muted.length} 个，池内现有 ${after} 条）`);
      return published;
    } catch (err) {
      const e = err as Error;
      if (e.message.startsWith('1700002') && await ReminderService.isQuotaZero()) {
        // 配额为 0：普通应用未获代理提醒权限，降级为应用内通知模式
        ReminderService.agentAvailable = false;
        await AppSettings.setReminderTick(context, Date.now());
        LogUtil.write('代理提醒配额为 0（需向华为邮件申请权限），已自动切换为应用内通知模式');
        return 0;
      }
      LogUtil.write(`提醒刷新失败: ${e.message}`);
      return published;
    }
  }

  /**
   * 应用内提醒检查（降级模式）：由自动同步定时器高频调用。
   * 把"提醒时刻落在上次检查~现在之间"的日程用本地通知发出。
   * App 进程被杀期间的提醒会错过（超过 2 分钟不补发），长时任务可避免。
   */
  static async tickReminders(context: common.Context): Promise<number> {
    if (ReminderService.agentAvailable !== false) {
      return 0; // 代理提醒可用或未判定，不需要降级
    }
    try {
      const now: number = Date.now();
      const last: number = await AppSettings.getReminderTick(context);
      if (last <= 0) {
        await AppSettings.setReminderTick(context, now); // 首次运行：只记基线不补发
        return 0;
      }
      const from: number = Math.max(last, now - 2 * 60000); // 最多补发 2 分钟内的错过提醒
      await AppSettings.setReminderTick(context, now);
      const rows: LocalEvent[] =
        await EventDb.queryRemindable(context, now, now + ReminderService.WINDOW);
      const muted: string[] = await AppSettings.getMutedReminderKeys(context);
      // ⭐⭐ 已镜像到系统日历的本：由系统日历负责提醒，App 侧不再补发（消除"提醒两次"）
      const mirrored: Set<string> = await ReminderService.mirroredKeys(context);
      let fired: number = 0;
      for (const e of rows) {
        if (muted.includes(e.calKey)) {
          continue;
        }
        if (mirrored.has(e.calKey)) {
          continue; // ⭐ 已镜像 → 交由系统日历提醒
        }
        const rems: number[] = e.reminders.length > 0 ? e.reminders
          : (e.reminder > 0 || e.reminder === -1 ? [e.reminder] : []);
        for (const rem of rems) {
          const remMin: number = (rem === -1 ? 0 : rem);
          const remindAt: number = e.startTime - remMin * 60000;
          if (remindAt <= from || remindAt > now) {
            continue; // 不在本次检查窗口内
          }
          const calName: string = await ReminderService.calName(context, e.calKey);
          const minLeft: number = Math.max(0,
            Math.ceil((e.startTime - Date.now()) / 60000));
          const text: string = (rem === -1 || minLeft === 0)
            ? `「${calName}」中的「${e.title}」现在开始`
            : `「${calName}」中的「${e.title}」将在 ${minLeft} 分钟后开始`;
          const fired2: number = await ReminderService.notifyNow(
            '日程提醒', text,
            (e.id * 10 + (rem === -1 ? 9 : rem)) % 100000);
          if (fired2 === 0) {
            fired++;
          }
        }
      }
      if (fired > 0) {
        LogUtil.write(`应用内提醒：本次发出 ${fired} 条到点提醒`);
      }
      return fired;
    } catch (err) {
      const e = err as Error;
      LogUtil.write(`应用内提醒检查失败: ${e.message}`);
      return 0;
    }
  }

  /** 日历本通知渠道（SOCIAL_COMMUNICATION 默认横幅+锁屏+响铃振动），只注册一次 */
  private static slotReady: boolean = false;

  private static async ensureSlot(): Promise<void> {
    if (ReminderService.slotReady) {
      return;
    }
    try {
      // 本 SDK 无锁屏可见性 API（已废弃），锁屏显示由系统"锁屏通知"设置 + 渠道默认行为决定
      await notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
    } catch (err) {
      // 渠道已存在等情况忽略
    }
    ReminderService.slotReady = true;
  }

  /** 立即发一条本地通知。返回 0 表示成功 */
  private static async notifyNow(title: string, text: string, id: number): Promise<number> {
    await ReminderService.ensureSlot();
    try {
      const request: notificationManager.NotificationRequest = {
        id: id,
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
            additionalText: ''
          }
        }
      };
      await notificationManager.publish(request);
      return 0;
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`本地通知发布失败: ${e.code} - ${e.message}`);
      return -1;
    }
  }

  /** 测试入口：代理可用时发 1 分钟后的代理提醒；降级模式发立即本地通知 */
  static async publishTestReminder(context: common.Context): Promise<string> {
    if (ReminderService.agentAvailable === false) {
      const r: number = await ReminderService.notifyNow(
        '测试通知（应用内模式）', '如果你看到这条通知，说明应用内提醒链路正常', 99998);
      return r === 0
        ? '已发出测试通知（应用内模式：代理提醒配额为 0，由 App 进程在提醒时刻发通知）'
        : '本地通知发布失败，详见日志';
    }
    // request 构造放在 try 外：腾位重试也要用到
    const t: number = Date.now() + 60 * 1000;
    const d = new Date(t);
    const request: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: d.getFullYear(),
        month: d.getMonth() + 1,
        day: d.getDate(),
        hour: d.getHours(),
        minute: d.getMinutes(),
        second: 0
      },
      title: '测试提醒',
      content: '这是一条测试提醒：如果你看到它，说明提醒链路正常',
      notificationId: 99999,
      expiredContent: '测试提醒已过期',
      ringDuration: 5,
      snoozeTimes: 0,
      timeInterval: 0
    };
    const before: number = await ReminderService.poolCount();
    LogUtil.write(`测试提醒发布前池内提醒 ${before} 条`);
    try {
      await ReminderService.publishWithRetry(request);
      LogUtil.write('测试提醒已发布：1 分钟后应弹出通知');
      return `已发布（发布前池内 ${before} 条），1 分钟后应弹出通知`;
    } catch (err) {
      const e = err as Error;
      if (e.message.startsWith('1700002') && await ReminderService.isQuotaZero()) {
        ReminderService.agentAvailable = false;
        await AppSettings.setReminderTick(context, Date.now());
        LogUtil.write('代理提醒配额为 0（需向华为邮件申请权限），已切换为应用内通知模式');
        const r: number = await ReminderService.notifyNow(
          '测试通知（应用内模式）', '如果你看到这条通知，说明应用内提醒链路正常', 99998);
        return r === 0
          ? '代理提醒配额为 0（需邮件向华为申请），已切换为应用内通知模式并发出测试通知'
          : '代理提醒配额为 0，已切换应用内模式，但测试通知发布失败（详见日志）';
      }
      LogUtil.write(`测试提醒发布失败: ${e.message}`);
      const sep: number = e.message.indexOf(':');
      return sep > 0
        ? `发布失败：错误码 ${e.message.substring(0, sep)}（${e.message.substring(sep + 1)}）`
        : `发布失败：${e.message}`;
    }
  }

  private static fmt(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${d.getMonth() + 1}月${d.getDate()}日 ${p(d.getHours())}:${p(d.getMinutes())}`;
  }
}
