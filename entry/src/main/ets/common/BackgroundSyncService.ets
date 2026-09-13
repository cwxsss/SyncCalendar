// entry/src/main/ets/common/BackgroundSyncService.ets
// 后台同步管理：
// 1) 长时任务（DATA_TRANSFER）：进程不被挂起，前台定时器在后台继续跑（需用户在设置中开启）
// 2) 延迟任务（workScheduler）：App 被杀/重启后由系统按条件拉起兜底同步（最小周期 20 分钟）
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, common } from '@kit.AbilityKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppSettings } from './AppSettings';
import { LogUtil } from './LogUtil';

const WORK_ID: number = 1001;

export class BackgroundSyncService {
  /** 申请长时任务（DATA_TRANSFER）：申请成功后进程在后台不被挂起 */
  static async startContinuousTask(context: common.UIAbilityContext): Promise<void> {
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      LogUtil.write('长时任务已申请：后台持续同步开启');
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`长时任务申请失败: ${e.code} - ${e.message}`);
    }
  }

  /** 停止长时任务 */
  static async stopContinuousTask(context: common.UIAbilityContext): Promise<void> {
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      LogUtil.write('长时任务已停止');
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`长时任务停止失败: ${e.code} - ${e.message}`);
    }
  }

  /**
   * 注册延迟任务兜底同步：无论长时任务开关与否都注册。
   * 条件：有任意网络即执行；周期重复；重启后自动恢复。
   * 注：repeatCycleTime 各版本下限不同（20 分钟 ~ 2 小时），先用 20 分钟，
   * 被系统拒绝（9700003 条件无效）时降级为 2 小时再试。
   */
  static scheduleDeferredSync(context: common.UIAbilityContext): void {
    const build = (cycleMs: number): workScheduler.WorkInfo => {
      const info: workScheduler.WorkInfo = {
        workId: WORK_ID,
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'SyncWorkAbility',
        networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
        isRepeat: true,
        isPersisted: true,
        repeatCycleTime: cycleMs
      };
      return info;
    };
    try {
      workScheduler.startWork(build(20 * 60 * 1000));
      LogUtil.write('延迟任务已注册：20 分钟兜底同步');
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 9700003) {
        try {
          workScheduler.startWork(build(2 * 60 * 60 * 1000));
          LogUtil.write('延迟任务降级注册：2 小时兜底同步');
          return;
        } catch (err2) {
          const e2 = err2 as BusinessError;
          LogUtil.write(`延迟任务注册失败(2h): ${e2.code} - ${e2.message}`);
          return;
        }
      }
      LogUtil.write(`延迟任务注册失败: ${e.code} - ${e.message}`);
    }
  }

  /** App 启动时统一入口：注册延迟任务 + 按设置恢复长时任务 */
  static async initOnLaunch(context: common.UIAbilityContext): Promise<void> {
    BackgroundSyncService.scheduleDeferredSync(context);
    const enabled: boolean = await AppSettings.getBackgroundSync(context);
    if (enabled) {
      await BackgroundSyncService.startContinuousTask(context);
    }
  }

  /** 设置页开关切换 */
  static async setBackgroundSync(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
    await AppSettings.setBackgroundSync(context, enabled);
    if (enabled) {
      await BackgroundSyncService.startContinuousTask(context);
    } else {
      await BackgroundSyncService.stopContinuousTask(context);
    }
  }
}
