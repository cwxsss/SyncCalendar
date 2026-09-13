// entry/src/main/ets/common/ReminderService.ets
// 日程提醒：基于后台代理提醒（reminderAgentManager），
// 在日程开始前 N 分钟（来自服务器 VALARM TRIGGER）发系统通知，可右滑删除
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EventDb, LocalEvent } from './EventDb';
import { AppSettings } from './AppSettings';
import { LogUtil } from './LogUtil';

export class ReminderService {
  private static readonly MAX_REMINDERS: number = 30; // 系统对单应用代理提醒数量有限制
  private static readonly WINDOW: number = 7 * 86400000; // 只排未来 7 天

  /** 全量重建提醒：先取消本应用全部代理提醒，再按当前数据重新发布 */
  static async refreshReminders(context: common.Context): Promise<void> {
    try {
      await reminderAgentManager.cancelAllReminders();
      const now: number = Date.now();
      const rows: LocalEvent[] =
        await EventDb.queryRemindable(context, now, now + ReminderService.WINDOW);
      // 提醒静音的日历本（如别人分享的本）：其中所有日程都不再提醒
      const muted: string[] = await AppSettings.getMutedReminderKeys(context);
      let published: number = 0;
      for (const e of rows) {
        if (muted.includes(e.calKey)) {
          continue;
        }
        if (published >= ReminderService.MAX_REMINDERS) {
          break;
        }
        const remindAt: number = e.startTime - e.reminder * 60000;
        if (remindAt <= now) {
          continue; // 提醒时间已过
        }
        const d = new Date(remindAt);
        const startTimeText: string = ReminderService.fmt(e.startTime);
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
          content: `「${e.title}」将于 ${startTimeText} 开始（提前 ${e.reminder} 分钟）`,
          notificationId: e.id % 100000,
          expiredContent: '该日程已开始',
          ringDuration: 5,
          snoozeTimes: 0,
          timeInterval: 0
        };
        await reminderAgentManager.publishReminder(request);
        published++;
      }
      LogUtil.write(`提醒刷新完成：发布 ${published} 个提醒（窗口 7 天，静音日历本 ${muted.length} 个）`);
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`提醒刷新失败: ${e.code} - ${e.message}`);
    }
  }

  private static fmt(ms: number): string {
    const d = new Date(ms);
    const p = (n: number): string => n < 10 ? '0' + n : String(n);
    return `${d.getMonth() + 1}月${d.getDate()}日 ${p(d.getHours())}:${p(d.getMinutes())}`;
  }
}
