// entry/src/main/ets/syncwork/SyncWorkAbility.ets
// 延迟任务兜底同步：App 进程被杀/设备重启后，系统在满足条件（有网络）时拉起本扩展执行同步
// 注意：必须幂等——同步本身基于 ETag 全量比对，天然幂等；执行完必须 stopWork，否则系统按超时处理
import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, TYPE_CALDAV } from '../common/AccountStore';
import { SyncEngine } from '../common/SyncEngine';
import { CardDataService } from '../common/CardDataService';
import { ReminderService } from '../common/ReminderService';
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
      let ok: number = 0;
      for (const acc of accounts) {
        if (acc.type !== TYPE_CALDAV) {
          continue;
        }
        try {
          await SyncEngine.withTimeout(
            SyncEngine.syncAccount(context, acc), 100000);
          ok++;
        } catch (err) {
          const e = err as BusinessError;
          LogUtil.write(`延迟任务同步「${acc.name}」失败: ${e.message}`);
        }
      }
      await SyncEngine.settleLocalEvents(context);
      await SyncEngine.pruneOrphanRows(context, accounts);
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
