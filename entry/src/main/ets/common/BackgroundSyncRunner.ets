// entry/src/main/ets/common/BackgroundSyncRunner.ets
// ⭐ 后台同步的**唯一**执行体：延迟任务 / 短时任务 / 网络恢复 / 回到前台 都调它。
//
// 设计要点（2026-10-10 定时同步方案调研结论）：
//  - 不再依赖"进程常驻"（系统不允许，dataTransfer 长时任务会被强制取消）
//  - 而是让"最合适的机制在最合适的时机把数据对齐"
//  - 本类只负责"跑一次完整同步"，幂等（基于 etag 全量比对 + dirty 标记）
//
// ⚠️ 与 SyncEngine.syncAccount 的分工：本类不关心超时与互斥锁（由 SyncEngine 内部处理）。
import { common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, TYPE_CALDAV } from './AccountStore';
import { SyncEngine } from './SyncEngine';
import { CardDataService } from './CardDataService';
import { ReminderService } from './ReminderService';
import { SystemCalendarImport } from './SystemCalendarImport';
import { SystemCalendarMirror } from './SystemCalendarMirror';
import { MirrorInbound } from './MirrorInbound';
import { AppSettings } from './AppSettings';
import { LogUtil } from './LogUtil';

/** 一次后台同步的结果（供日志/埋点，不做 UI） */
export class BackgroundSyncResult {
  ok: number = 0;
  attempted: number = 0;
  failed: number = 0;
}

export class BackgroundSyncRunner {
  /**
   * ⭐ 卡片的系统定时刷新间隔（与 form_config.json 的 updateDuration=1 保持一致，单位 30 分钟）。
   * ⚠️ 两处必须同步修改：改这里也要改 form_config.json，否则节流窗口对不上。
   */
  static readonly CARD_TICK_MS: number = 30 * 60 * 1000;
  /** 距上次同步不足该时长则跳过（略小于卡片周期，避免系统刷新漂移导致被误跳过） */
  private static readonly CARD_MIN_GAP_MS: number = 25 * 60 * 1000;
  /**
   * 卡片进程的软超时（**未申请到短时任务时**）：官方规定 FormExtensionAbility
   * 生命周期回调后进程**仅存续 10 秒**，超过就被回收（异步任务被强制中止）。
   * 这里主动在 9 秒收手，让"这一次同步"**干净地放弃**而不是被硬杀在半途。
   */
  private static readonly CARD_SOFT_TIMEOUT_MS: number = 9 * 1000;
  /**
   * 申请到短时任务后的软超时：短时任务单次最长 3 分钟（低电量 1 分钟），
   * 但实际时长以 `actualDelayTime` 为准 → 留 15 秒余量提前收手，保证能干净地
   * `cancelSuspendDelay`（否则超时不取消会被系统强制终止进程、并浪费当日配额）。
   */
  private static readonly CARD_EXT_SOFT_RESERVE_MS: number = 15 * 1000;
  /**
   * 卡片驱动同步可用的**总时长上限**：即使申请到短时任务也不超过这个值。
   * 理由：短时任务**单日总配额仅 10 分钟**，30 分钟一次的话每次平均只能分到约 20 秒，
   * 全用光会让"退后台那一次同步"（EntryAbility.onBackground 申请）无配额可用。
   */
  private static readonly CARD_MAX_TOTAL_MS: number = 60 * 1000;

  /** 本次卡片同步申请的短时任务 requestId（0 = 未申请到） */
  private static cardTransientId: number = 0;

  /**
   * ⭐⭐ 由**服务卡片定时刷新**（`onUpdateForm`）驱动的后台同步（0.0.8）。
   *
   * 为什么用它：系统给普通应用的后台调度很受限 ——
   *   `workScheduler` 的周期被"应用活跃分组"压制到 **≥2 小时**；
   *   而服务卡片配置了 `updateDuration: 1`（**单位 30 分钟**），系统会**每 30 分钟**
   *   触发一次 `onUpdateForm()`，且不受活跃分组压制（每天上限 50 次）。
   *   借这个时机跑一次完整同步，即可得到"约 30 分钟一次"的定期后台同步。
   *
   * ⚠️ 节流：系统刷新本身可能有漂移、也可能因故重入 → 用时间戳挡一道，
   *    保证两次真实同步之间至少间隔 `CARD_MIN_GAP_MS`。
   * ⚠️ 本方法**永不抛错**（后台路径没有 UI 承担异常）。
   */
  static async runOnceThrottledByCard(context: common.Context): Promise<void> {
    try {
      const last: number = await AppSettings.getCardSyncAt(context);
      const now: number = Date.now();
      if (last > 0 && now - last < BackgroundSyncRunner.CARD_MIN_GAP_MS) {
        const mins: number = Math.round((now - last) / 60000);
        LogUtil.write(`卡片驱动同步：距上次仅 ${mins} 分钟，跳过（节流 ${BackgroundSyncRunner.CARD_MIN_GAP_MS / 60000} 分钟）`);
        return;
      }
      // 先写时间戳：避免同步执行期间卡片再次刷新导致并发重入
      await AppSettings.setCardSyncAt(context, now);
      // ⭐ 尝试申请**短时任务**，把 10 秒窗口延长到最多 3 分钟。
      //    ⚠️ 官方规定 requestSuspendDelay 应在"应用处于前台"或"onBackground 回调"里调用；
      //       卡片进程（FormExtensionAbility）是否符合**未知** → 故此处**容错尝试**：
      //       成功则按实际时长延长，失败（抛错/时长为 0）则退回 9 秒软超时。
      //    ⚠️ 配额：短时任务单日总配额 10 分钟、单次最长 3 分钟（低电量 1 分钟），
      //       且**被挂起后才计时**（10 秒内跑完不消耗）→ 对我们很划算。
      const windowMs: number = await BackgroundSyncRunner.acquireCardWindow();
      const budget: number = Math.min(windowMs, BackgroundSyncRunner.CARD_MAX_TOTAL_MS);
      LogUtil.write(`卡片驱动同步：开始（卡片 30 分钟定时刷新触发，可用窗口 ${Math.round(budget / 1000)} 秒）`);
      // 软超时：预算内没跑完就主动放弃（幂等同步，中断不损坏数据，下轮会重试）
      const worker: Promise<void> =
        BackgroundSyncRunner.runOnce(context, 'cardTick').then((): void => {});
      const guard: Promise<void> = new Promise<void>((_res: () => void, rej: (e: Error) => void) => {
        setTimeout((): void => rej(new Error('本次同步时间预算用尽，主动收手')),
          budget);
      });
      try {
        await Promise.race<void>([worker, guard]);
      } catch (err) {
        const e = err as Error;
        LogUtil.write(`卡片驱动同步提前收手：${e.message}（幂等，下轮会重试）`);
      } finally {
        // 无论成败都释放短时任务：① 归还当日配额 ② 避免超时不取消被系统强杀进程
        BackgroundSyncRunner.releaseCardWindow();
      }
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`卡片驱动同步异常: ${e.message}`);
    }
  }

  /**
   * 为卡片同步申请短时任务，返回**实际可用窗口（毫秒）**。
   * 申请失败/异常/时长为 0 → 返回 0，由调用方退回默认的 9 秒软超时（不阻塞流程）。
   */
  private static async acquireCardWindow(): Promise<number> {
    try {
      const info: backgroundTaskManager.DelaySuspendInfo =
        backgroundTaskManager.requestSuspendDelay('正在同步日历数据', (): void => {
          // 超时回调：配额即将用尽，清掉本地记录（系统会自行处理挂起）
          LogUtil.write('卡片同步的短时任务即将超时');
          BackgroundSyncRunner.cardTransientId = 0;
        });
      BackgroundSyncRunner.cardTransientId = info.requestId;
      const actual: number = info.actualDelayTime ?? 0;
      if (actual <= 0) {
        // 拿到了 requestId 但没有实际时长 → 视为不可用
        BackgroundSyncRunner.releaseCardWindow();
        LogUtil.write('卡片同步：短时任务时长为 0，退回 9 秒软超时');
        return BackgroundSyncRunner.CARD_SOFT_TIMEOUT_MS;
      }
      // 留 15 秒余量提前收手，保证能干净地取消
      const usable: number = Math.max(actual - BackgroundSyncRunner.CARD_EXT_SOFT_RESERVE_MS,
        BackgroundSyncRunner.CARD_SOFT_TIMEOUT_MS);
      LogUtil.write(`卡片同步：短时任务已获批，实际时长 ${Math.round(actual / 1000)} 秒`);
      return usable;
    } catch (err) {
      // 例如"未在前台/退后台时机申请"被拒 —— 退回 9 秒软超时，不影响流程
      const e = err as BusinessError;
      LogUtil.write(`卡片同步：短时任务申请失败(${e.code ?? ''} ${e.message})，退回 9 秒软超时`);
      return BackgroundSyncRunner.CARD_SOFT_TIMEOUT_MS;
    }
  }

  /** 释放卡片同步的短时任务（幂等） */
  private static releaseCardWindow(): void {
    if (BackgroundSyncRunner.cardTransientId === 0) {
      return;
    }
    try {
      backgroundTaskManager.cancelSuspendDelay(BackgroundSyncRunner.cardTransientId);
    } catch (err) {
      // 取消失败无需处理
    }
    BackgroundSyncRunner.cardTransientId = 0;
  }
  /**
   * 跑一次完整同步。全流程 try-catch，**永不抛错**（后台路径没有 UI 承担异常）。
   * @param context 应用上下文
   * @param tag 日志标签，用于区分触发来源（deferred/transient/netRecover/foreground）
   */
  static async runOnce(context: common.Context, tag: string): Promise<BackgroundSyncResult> {
    const r = new BackgroundSyncResult();
    try {
      const accounts: DavAccount[] = await AccountStore.loadAll(context);
      if (accounts.length === 0) {
        LogUtil.write(`后台同步[${tag}]：无账号，跳过`);
        return r;
      }
      // 备份模式：先导入系统本地日历（幂等），再随同步推送
      try {
        await SystemCalendarImport.importIfNeeded(context);
      } catch (err) {
        // 导入失败不影响正常同步
      }
      // 入站对账：把用户在系统日历里的改动读回来置 dirty（必须在同步之前）
      try {
        await MirrorInbound.reconcile(context);
      } catch (err) {
        // 对账失败不影响正常同步
      }
      for (const acc of accounts) {
        if (acc.type !== TYPE_CALDAV) {
          continue;
        }
        r.attempted++;
        try {
          await SyncEngine.syncAccount(context, acc);
          r.ok++;
        } catch (err) {
          const e = err as BusinessError;
          // "已有同步进行中"不算失败（前台可能正在同步）
          r.failed++;
          LogUtil.write(`后台同步[${tag}] id=${acc.id} 失败: ${e.message}`);
        }
      }
      // 全部账号同步成功才结束"一次性全量重拉"状态
      if (r.attempted > 0 && r.ok === r.attempted) {
        await AppSettings.markFullRefetchDone(context);
      }
      await SyncEngine.settleLocalEvents(context);
      await SyncEngine.pruneOrphanRows(context, accounts);
      // ⚠️ 必须回写账号：syncAccount 会就地更新 acc（服务器日历本颜色、写权限等）。
      // 缺了这一步，后台同步刷到的颜色只留在内存里、进程退出即丢失。
      await AccountStore.saveAll(context, accounts);
      // 出站镜像：把服务器最新状态写进系统日历（自动化，无需手点）
      try {
        if (await AppSettings.getMirrorEnabled(context) && await SystemCalendarMirror.hasPermission()) {
          const mr = await SystemCalendarMirror.syncNow(context);
          LogUtil.write(`后台同步[${tag}] 自动镜像：本=${mr.books} 新增=${mr.added} 更新=${mr.updated} 删除=${mr.deleted}`);
        }
      } catch (err) {
        // 镜像失败不影响同步
      }
      // 同步后刷新卡片 + 重建提醒，保证后台同步的成果直接可见
      try {
        await CardDataService.pushToAllForms(context);
        await ReminderService.refreshReminders(context as common.UIAbilityContext);
      } catch (err) {
        // 卡片/提醒刷新失败不影响同步结果
      }
      LogUtil.write(`后台同步[${tag}] 完成：${r.ok}/${r.attempted} 个账号`);
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`后台同步[${tag}] 流程异常: ${e.message}`);
    }
    return r;
  }
}