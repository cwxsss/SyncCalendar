// entry/src/main/ets/syncwork/SyncWorkAbility.ets
// 延迟任务兜底同步：App 进程被杀/设备重启后，系统在满足条件（有网络）时拉起本扩展执行同步
// 注意：必须幂等——同步本身基于 ETag 全量比对，天然幂等；执行完必须 stopWork，否则系统按超时处理
import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, TYPE_CALDAV } from '../common/AccountStore';
import { SyncEngine } from '../common/SyncEngine';
import { CardDataService } from '../common/CardDataService';
import { ReminderService } from '../common/ReminderService';
import { SystemCalendarImport } from '../common/SystemCalendarImport';
import { AppSettings } from '../common/AppSettings';
import { LogUtil } from '../common/LogUtil';

export default class SyncWorkAbility extends WorkSchedulerExtensionAbility {
  onWorkStart(workInfo: workScheduler.WorkInfo): void {
    LogUtil.init(this.context);
    LogUtil.write(`延迟任务触发：workId=${workInfo.workId}`);
    this.doSync(workInfo);
  }

  onWorkStop(workInfo: workScheduler.WorkInfo): void {
    LogUtil.write(`延迟任务结束：workId=${workInfo.workId}`);
  }

  private async doSync(workInfo: workScheduler.WorkInfo): Promise<void> {
    try {
      const context = this.context;
      const accounts: DavAccount[] = await AccountStore.loadAll(context);
      // 备份模式：先导入系统本地日历（幂等），再随同步推送
      try {
        await SystemCalendarImport.importIfNeeded(context);
      } catch (err) {
        // 导入失败不影响正常同步
      }
      let ok: number = 0;
      let attempted: number = 0;
      for (const acc of accounts) {
        if (acc.type !== TYPE_CALDAV) {
          continue;
        }
        attempted++;
        try {
          // 超时保护由 syncAccount 内部处理（全量重拉 10 分钟 / 常规 5 分钟），不再套外层超时
          await SyncEngine.syncAccount(context, acc);
          ok++;
        } catch (err) {
          const e = err as BusinessError;
          LogUtil.write(`延迟任务同步 id=${acc.id} 失败: ${e.message}`);
        }
      }
      // 全部账号同步成功才结束"一次性全量重拉"状态
      if (attempted > 0 && ok === attempted) {
        await AppSettings.markFullRefetchDone(context);
      }
      await SyncEngine.settleLocalEvents(context);
      await SyncEngine.pruneOrphanRows(context, accounts);
      // ⚠️ 必须回写账号：syncAccount 会就地更新 acc（服务器日历本颜色、写权限等）。
      // 缺了这一步，后台同步刷到的颜色只留在内存里、进程退出即丢失，
      // 界面下次冷启动仍用旧颜色（表现为"同步之后颜色还是不对"）。
      await AccountStore.saveAll(context, accounts);
      // 同步后刷新卡片 + 重建提醒，保证后台同步的成果直接可见
      await CardDataService.pushToAllForms(context);
      await ReminderService.refreshReminders(context);
      LogUtil.write(`延迟任务同步完成：${ok} 个账号`);
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`延迟任务同步失败: ${e.message}`);
    } finally {
      // 必须主动结束，否则系统按 120 秒超时处理
      workScheduler.stopWork(workInfo);
    }
  }
}
