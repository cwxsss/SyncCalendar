// entry/src/main/ets/common/BackgroundSyncService.ets
// ⭐ 后台同步调度（2026-10-10 重构，依据《定时同步方案调研.md》）
//
// 为什么不再用长时任务（重要）：
//   旧版申请 `dataTransfer` 长时任务想让进程常驻，但系统对 DATA_TRANSFER 有**一致性校验**——
//   "超过 10 分钟未更新传输进度 → 任务被强制取消"。日历同步是"间歇跑、平时无进度"，
//   本质不符合"持续传输中"的语义 → 必被取消（常驻通知消失就是这个原因），
//   且频繁触发校验失败可能被系统列入管控名单。故**彻底移除**。
//
// 现在的分层调度（每层各司其职）：
//   ① 前台：Index 里的 setInterval 按用户设定间隔同步（最准，已在前台实现）
//   ② 退后台瞬间：**短时任务**（requestSuspendDelay）兜住"退后台后那一次"
//   ③ 长期后台：**延迟任务**（workScheduler，≥2 小时，对齐系统活跃分组下限）
//   ④ 网络恢复 / 回到前台：各补一次（性价比最高，见 NetworkSyncWatcher / Index.onForeground）
//
// ⚠️ 关键约束（踩过的坑，勿改）：
//  - workScheduler 的 repeatCycleTime **不得低于 2 小时**：系统按"应用活跃分组"压制
//    （活跃≥2h / 经常使用≥4h / 常用≥24h / 极少使用≥48h / 受限·从未使用禁止调度），
//    请求更短不报错但会被压制，形同虚设。
//  - WorkSchedulerExtensionAbility 单次回调**上限 2 分钟**，超时进程被杀。
//  - 短时任务配额：单日 10 分钟、单次最长 3 分钟（低电量 1 分钟）→ 只做短收尾，用完必须 cancel。
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common } from '@kit.AbilityKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppSettings } from './AppSettings';
import { LogUtil } from './LogUtil';

const WORK_ID: number = 1001;
/** 延迟任务周期：2 小时（系统"活跃分组"下限，不可再短） */
const DEFERRED_CYCLE_MS: number = 2 * 60 * 60 * 1000;

export class BackgroundSyncService {
  /** 当前短时任务的 requestId（0 = 无）；退后台申请、回前台取消 */
  private static transientId: number = 0;

  /**
   * 注册延迟任务兜底同步：周期 2 小时、重启后自动恢复（isPersisted）。
   * 条件：有任意网络即执行。
   * ⚠️ 周期**不得低于 2 小时**（系统按"应用活跃分组"压制：活跃≥2h / 经常使用≥4h / 常用≥24h /
   *    极少使用≥48h / 受限·从未使用禁止调度）。请求更短不报错但会被压制，形同虚设。
   */
  static scheduleDeferredSync(context: common.UIAbilityContext): void {
    const info: workScheduler.WorkInfo = {
      workId: WORK_ID,
      bundleName: context.abilityInfo.bundleName,
      abilityName: 'SyncWorkAbility',
      networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
      isRepeat: true,
      isPersisted: true,
      repeatCycleTime: DEFERRED_CYCLE_MS
    };
    try {
      workScheduler.startWork(info);
      LogUtil.write('延迟任务已注册：2 小时兜底同步（系统活跃分组下限）');
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`延迟任务注册失败: ${e.code} - ${e.message}`);
    }
  }

  /** 取消延迟任务（用户关闭"后台自动同步"时调用） */
  static cancelDeferredSync(context: common.UIAbilityContext): void {
    const info: workScheduler.WorkInfo = {
      workId: WORK_ID,
      bundleName: context.abilityInfo.bundleName,
      abilityName: 'SyncWorkAbility',
      networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
      isRepeat: true,
      isPersisted: true,
      repeatCycleTime: DEFERRED_CYCLE_MS
    };
    try {
      workScheduler.stopWork(info, true);
      LogUtil.write('延迟任务已取消（后台自动同步关闭）');
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`延迟任务取消失败: ${e.code} - ${e.message}`);
    }
  }

  /**
   * ⭐ 退到后台时申请**短时任务**：让"刚退后台的这一次同步"能跑完。
   * 必须在**前台或退后台 5 秒内**调用，否则申请失败。
   * 单次最长 3 分钟（实际申请到的时长以返回值为准），单日总配额 10 分钟。
   */
  static requestTransientSync(reason: string): void {
    if (BackgroundSyncService.transientId !== 0) {
      return; // 已有短时任务在跑，不重复申请（重复申请会浪费配额）
    }
    try {
      const info: backgroundTaskManager.DelaySuspendInfo =
        backgroundTaskManager.requestSuspendDelay(reason, (): void => {
          // 超时回调：配额用完，系统即将挂起；清状态，等下次前台/退后台再申请
          LogUtil.write('短时任务超时（配额用尽），后台同步将被挂起');
          BackgroundSyncService.transientId = 0;
        });
      BackgroundSyncService.transientId = info.requestId;
      LogUtil.write(`短时任务已申请：requestId=${info.requestId}，可用 ${Math.round(info.actualDelayTime / 1000)} 秒`);
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`短时任务申请失败: ${e.code} - ${e.message}`);
    }
  }

  /** 回到前台时取消短时任务：不占用当日配额（很重要，配额只有 10 分钟） */
  static cancelTransientSync(): void {
    if (BackgroundSyncService.transientId === 0) {
      return;
    }
    try {
      backgroundTaskManager.cancelSuspendDelay(BackgroundSyncService.transientId);
      LogUtil.write('短时任务已取消（回到前台，归还配额）');
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`短时任务取消失败: ${e.code} - ${e.message}`);
    }
    BackgroundSyncService.transientId = 0;
  }

  /** 查询短时任务剩余时间（毫秒）；无任务或无配额返回 0 */
  static async remainingTransientMs(): Promise<number> {
    if (BackgroundSyncService.transientId === 0) {
      return 0;
    }
    try {
      return await backgroundTaskManager.getRemainingDelayTime(BackgroundSyncService.transientId);
    } catch (err) {
      return 0;
    }
  }

  /** App 启动时统一入口：按用户设置注册/不注册延迟任务兜底同步 */
  static async initOnLaunch(context: common.UIAbilityContext): Promise<void> {
    const enabled: boolean = await AppSettings.getBackgroundSync(context);
    if (enabled) {
      BackgroundSyncService.scheduleDeferredSync(context);
    } else {
      LogUtil.write('后台自动同步未开启：不注册延迟任务');
    }
  }

  /** 设置页开关切换：控制"后台自动同步"（延迟任务注册与否） */
  static async setBackgroundSync(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
    await AppSettings.setBackgroundSync(context, enabled);
    if (enabled) {
      BackgroundSyncService.scheduleDeferredSync(context);
    } else {
      BackgroundSyncService.cancelDeferredSync(context);
    }
  }
}