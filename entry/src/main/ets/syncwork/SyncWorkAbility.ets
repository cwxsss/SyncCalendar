// entry/src/main/ets/syncwork/SyncWorkAbility.ets
// 延迟任务兜底同步：App 进程被杀/设备重启后，系统在满足条件（有网络）时拉起本扩展执行同步。
//
// ⚠️ 约束（勿改）：
//  - 单次回调**上限 2 分钟**，超时进程被系统终止 → 逻辑必须轻量（本类只调 Runner，不做事后处理）。
//  - 周期由 BackgroundSyncService 设为 2 小时（系统活跃分组下限），此处不再重复设置。
//  - 必须幂等：同步基于 etag 全量比对 + dirty 标记，天然幂等。
//  - 必须主动 stopWork，否则系统按超时处理。
import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { BackgroundSyncRunner } from '../common/BackgroundSyncRunner';
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
      // 完整的后台同步流程（导入/对账/逐账号同步/镜像/卡片/提醒）统一由 Runner 实现，
      // 与"网络恢复补同步"、"回到前台补同步"共用同一套逻辑，避免三处实现漂移。
      await BackgroundSyncRunner.runOnce(this.context, 'deferred');
    } finally {
      // 必须主动结束，否则系统按 120 秒超时处理
      workScheduler.stopWork(workInfo);
    }
  }
}