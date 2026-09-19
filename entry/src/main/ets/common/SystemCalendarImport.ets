// entry/src/main/ets/common/SystemCalendarImport.ets
// 系统日历备份：把手机"本地"系统日历（非 CalDAV 同步日历）的全部日程导入
// 用户选定的 CalDAV 日历本（置 dirty 待推送），随后随同步上传服务器。
// 价值：手机丢失/换机后，系统日历日程在用户自己的 CalDAV 服务器上仍有备份。
import { common } from '@kit.AbilityKit';
import { calendarManager } from '@kit.CalendarKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EventDb, LocalEvent } from './EventDb';
import { AppSettings } from './AppSettings';
import { LogUtil } from './LogUtil';
import { BookRef, SystemCalendarMirror } from './SystemCalendarMirror';

export class SystemCalendarImport {
  /**
   * 备份模式下的导入入口（display 模式直接返回 0）。
   * 幂等：uid = syscal-<系统日历id>-<事件id>，已存在则跳过，因此每次同步都可安全执行。
   * 只读取 calendarType = LOCAL 的系统日历（手机本地日历/应用创建的日程），
   * 系统 CalDAV 同步产生的账户日历一律跳过，避免死循环回灌。
   *
   * ⚠️ 另有两层防重复（09-18 补）：
   *   1. **跳过本应用镜像出去的账户**（`synccalendar.mirror.*`）——它们的 type 也是 LOCAL，
   *      但内容是我们从 CalDAV 写进去的，再导进备份本会让同一条日程在服务器出现两份。
   *   2. 导进备份本的 uid 统一带 `syscal-` 前缀，出站镜像会跳过该前缀 → 备份本不会被镜像回系统日历。
   *
   * ⚠️ 目标本用**稳定标识 bookId** 解析（`SystemCalendarMirror.backupTargetRef`）：
   *    用户「取消勾选」目标本后序号会整体前移，老版本按 `accId_序号` 定位会**导进另一个本**。
   *    现在解析不到即视为失效，并把「备份到 CalDAV」模式**自动关回仅显示**。
   */
  static async importIfNeeded(context: common.Context): Promise<number> {
    try {
      const mode: string = await AppSettings.getSysCalMode(context);
      if (mode !== 'backup') {
        return 0;
      }
      // ⭐ 目标本一律走 `backupTargetRef()`：内部用**稳定标识 bookId** 解析，
      //    并兼做「老 calKey 值 → bookId」的一次性迁移。
      //    解析不到时它会**自动把 sys_cal_mode 关回 display**（用户明确要求的行为）：
      //    目标本被取消同步/账号被删后，绝不能"随便挑一个本"把系统日历导进去。
      const ref: BookRef | undefined = await SystemCalendarMirror.backupTargetRef(context);
      if (ref === undefined) {
        // 未选择目标本（或刚被判失效并关闭）→ 跳过。原因已由 backupTargetRef 写进日志。
        LogUtil.write('系统日历备份：当前无有效目标日历本，跳过导入');
        return 0;
      }
      const calKey: string = ref.calKey; // 仅用于查本地库 / 落库
      const targetHref: string = ref.href;
      if (targetHref === '') {
        LogUtil.write(`系统日历备份：目标日历本 ${ref.bookId} 缺少集合 URL，跳过导入`);
        return 0;
      }
      const uiContext = context as common.UIAbilityContext;
      const mgr: calendarManager.CalendarManager = calendarManager.getCalendarManager(uiContext);
      const calendars: calendarManager.Calendar[] = await mgr.getAllCalendars();
      // 诊断：把 getAllCalendars() 实际能读到的账户全列出来。
      // 用于确认"是否只能读到本应用创建的 + 系统默认账户"，还是能读到其他应用自建的日历账户。
      const brief: string[] = [];
      for (const cal of calendars) {
        let acc: calendarManager.CalendarAccount;
        try {
          acc = cal.getAccount();
        } catch (err) {
          continue;
        }
        const tag: string = SystemCalendarMirror.isMirrorAccountName(acc.name) ? '(我们的镜像)' : '';
        brief.push(`${acc.name}[type=${acc.type}]${tag}`);
      }
      LogUtil.write(`系统日历账户清单：共 ${calendars.length} 个 → ${brief.join(' | ')}`);
      let imported: number = 0;
      let skippedCal: number = 0;
      let skippedMirror: number = 0; // 本应用镜像出去的账户（不能导进备份本，否则重复）
      for (const cal of calendars) {
        try {
          // 只处理"本地"类型系统日历；CalDAV/订阅等账户日历的数据源本来就在服务器上，跳过防回灌
          const account: calendarManager.CalendarAccount = cal.getAccount();
          if (account.type !== calendarManager.CalendarType.LOCAL) {
            skippedCal++;
            continue;
          }
          // ⚠️ 关键：跳过**本应用自己镜像出去的账户**（type 同样 LOCAL，但内容是我们从 CalDAV 写进去的）。
          //    若一并导入备份本，同一条日程会在服务器里出现两份（原始本一份、备份本一份）→ 数据非常乱。
          //    这些账户的改动由 MirrorInbound 负责回写到它**原本所属**的日历本，不走备份通道。
          if (SystemCalendarMirror.isMirrorAccountName(account.name)) {
            skippedMirror++;
            continue;
          }
          const events: calendarManager.Event[] = await cal.getEvents();
          for (const ev of events) {
            if (ev.id === undefined) {
              continue;
            }
            const uid: string = `syscal-${account.name}-${ev.id}`;
            if (await EventDb.uidExists(context, uid)) {
              continue;
            }
            const e = new LocalEvent();
            e.uid = uid;
            e.calKey = calKey;
            e.href = targetHref;
            e.remotePath = encodeURIComponent(uid) + '.ics';
            e.title = ev.title !== undefined ? ev.title : '';
            e.description = ev.description !== undefined ? ev.description : '';
            e.location = ev.location !== undefined && ev.location.location !== undefined
              ? ev.location.location : '';
            e.startTime = ev.startTime;
            e.endTime = ev.endTime;
            e.isAllDay = ev.isAllDay === true;
            e.kind = 'event';
            e.rrule = SystemCalendarImport.rruleOf(ev);
            e.recurring = e.rrule !== '';
            await EventDb.insertLocal(context, e); // insertLocal 置 dirty，随同步推送
            imported++;
          }
        } catch (err) {
          // 单个日历读取失败不影响其余
        }
      }
      if (imported > 0 || skippedCal > 0 || skippedMirror > 0) {
        LogUtil.write(
          `系统日历备份：新增 ${imported} 条 → ${calKey}（跳过非本地账户 ${skippedCal} 个、镜像账户 ${skippedMirror} 个）`);
      }
      return imported;
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`系统日历备份导入失败(忽略): ${e.message}`);
      return 0;
    }
  }

  /** 系统日程的 recurrenceRule → 尽力转换的 RRULE 字符串（仅 FREQ/INTERVAL，复杂规则服务器端可再完善） */
  private static rruleOf(ev: calendarManager.Event): string {
    try {
      const rr = ev.recurrenceRule;
      if (rr === undefined) {
        return '';
      }
      const freqMap: string[] = ['YEARLY', 'MONTHLY', 'WEEKLY', 'DAILY'];
      const fi: number = rr.recurrenceFrequency as number;
      if (Number.isNaN(fi) || fi < 0 || fi >= freqMap.length) {
        return '';
      }
      let rrule: string = `FREQ=${freqMap[fi]}`;
      if (rr.interval !== undefined && rr.interval > 1) {
        rrule += `;INTERVAL=${rr.interval}`;
      }
      return rrule;
    } catch (err) {
      return '';
    }
  }
}
