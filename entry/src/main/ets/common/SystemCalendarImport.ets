// entry/src/main/ets/common/SystemCalendarImport.ets
// 系统日历备份：把手机"本地"系统日历（非 CalDAV 同步日历）的全部日程导入
// 用户选定的 CalDAV 日历本（置 dirty 待推送），随后随同步上传服务器。
// 价值：手机丢失/换机后，系统日历日程在用户自己的 CalDAV 服务器上仍有备份。
import { common } from '@kit.AbilityKit';
import { calendarManager } from '@kit.CalendarKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AccountStore, DavAccount } from './AccountStore';
import { EventDb, LocalEvent } from './EventDb';
import { AppSettings } from './AppSettings';
import { LogUtil } from './LogUtil';

export class SystemCalendarImport {
  /**
   * 备份模式下的导入入口（display 模式直接返回 0）。
   * 幂等：uid = syscal-<系统日历id>-<事件id>，已存在则跳过，因此每次同步都可安全执行。
   * 只读取 calendarType = LOCAL 的系统日历（手机本地日历/应用创建的日程），
   * 系统 CalDAV 同步产生的账户日历一律跳过，避免死循环回灌。
   */
  static async importIfNeeded(context: common.Context): Promise<number> {
    try {
      const mode: string = await AppSettings.getSysCalMode(context);
      if (mode !== 'backup') {
        return 0;
      }
      const calKey: string = await AppSettings.getBackupCalKey(context);
      if (calKey === '') {
        LogUtil.write('系统日历备份：未选择目标日历本，跳过导入');
        return 0;
      }
      // 定位目标 CalDAV 日历本
      const accounts: DavAccount[] = await AccountStore.loadAll(context);
      let targetHref: string = '';
      for (const acc of accounts) {
        for (let i = 0; i < acc.calendarHrefs.length; i++) {
          if (`${acc.id}_${i}` === calKey) {
            targetHref = acc.calendarHrefs[i];
          }
        }
      }
      if (targetHref === '') {
        LogUtil.write(`系统日历备份：目标日历本 ${calKey} 不存在（账号可能已删除），跳过导入`);
        return 0;
      }
      const uiContext = context as common.UIAbilityContext;
      const mgr: calendarManager.CalendarManager = calendarManager.getCalendarManager(uiContext);
      const calendars: calendarManager.Calendar[] = await mgr.getAllCalendars();
      let imported: number = 0;
      let skippedCal: number = 0;
      for (const cal of calendars) {
        try {
          // 只处理"本地"类型系统日历；CalDAV/订阅等账户日历的数据源本来就在服务器上，跳过防回灌
          const account: calendarManager.CalendarAccount = cal.getAccount();
          if (account.type !== calendarManager.CalendarType.LOCAL) {
            skippedCal++;
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
      if (imported > 0 || skippedCal > 0) {
        LogUtil.write(`系统日历备份：新增 ${imported} 条 → ${calKey}（跳过账户日历 ${skippedCal} 个）`);
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
